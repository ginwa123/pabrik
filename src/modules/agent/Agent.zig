const std = @import("std");
const json = std.json;
const Reader = std.Io.Reader;
const bashTool = @import("tools/bash.zig").bash_tool;
const bashMod = @import("tools/bash.zig");
const schemas = @import("tools/schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
pub const AgentTool = schemas.AgentTool;
pub const prompt = @import("prompts.zig");
pub const LLMModels = @import("LLMModels.zig");
const helpers = @import("helpers");
const custom_http_client = @import("kabelweb").client;
const args_repair = @import("tools/tools_args_repair.zig");
const file_attachments = @import("../../agentic_loop/file_attachments.zig");
const logger_mod = @import("../logger/Logger.zig");

/// Log level for agent logging
const LogLevel = enum { err, warn, info, debug };

/// Get current timestamp in milliseconds since epoch
fn timestampMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
}

/// Calculate elapsed time in milliseconds
fn elapsedMs(io: std.Io, start: i64) i64 {
    return timestampMs(io) - start;
}

/// Format duration for human-readable output
fn formatDuration(ms: i64) struct { value: i64, unit: []const u8 } {
    if (ms < 1000) return .{ .value = ms, .unit = "ms" };
    if (ms < 60000) return .{ .value = @divTrunc(ms, 1000), .unit = "s" };
    return .{ .value = @divTrunc(ms, 60000), .unit = "min" };
}

pub const UnresolvedIntentResult = struct {
    has_unresolved: bool,
    reason: ?[]const u8,
};

/// Content part types for multimodal messages (text, image_url, video_url, or file)
pub const ContentPart = struct {
    part_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
    video_url: ?VideoUrl = null,
    /// A document the model reads as a file. The wire shape differs per
    /// provider, so every request builder maps this part itself.
    file: ?FilePart = null,
};

/// A document the model reads as a file: a PDF, or a rich binary document.
/// The bytes ride as base64 in `b64` (no data-URL prefix).
pub const FilePart = struct {
    filename: []const u8,
    mime: []const u8,
    b64: []const u8,

    /// The payload as a data URL — what OpenAI's `file_data` wants.
    pub fn dataUrl(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ self.mime, self.b64 });
    }
};

/// The Chat Completions wire shape of a content part. A file rides as
/// `{"type":"file","file":{"filename":…,"file_data":"data:…;base64,…"}}`.
const ChatContentPart = struct {
    part_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,
    video_url: ?VideoUrl = null,
    file: ?OpenAiFile = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.part_type);
        if (self.text) |t| {
            try stringify.objectField("text");
            try stringify.write(t);
        }
        if (self.image_url) |img| {
            try stringify.objectField("image_url");
            try img.jsonStringify(stringify);
        }
        if (self.video_url) |vid| {
            try stringify.objectField("video_url");
            try vid.jsonStringify(stringify);
        }
        if (self.file) |f| {
            try stringify.objectField("file");
            try f.jsonStringify(stringify);
        }
        try stringify.endObject();
    }
};

/// Map a file part to the Chat Completions wire shape. Chat Completions
/// takes a PDF only, so a rich binary document is a hard error here —
/// never a silently dropped attachment.
fn chatFilePart(allocator: std.mem.Allocator, file: FilePart) !OpenAiFile {
    const kind = file_attachments.classify(file.filename, file.mime);
    if (!file_attachments.styleCarriesFile("openai", kind)) return error.UnsupportedFileType;
    return .{ .filename = file.filename, .file_data = try file.dataUrl(allocator) };
}

/// The OpenAI Chat Completions shape of a file part:
/// `{"type":"file","file":{"filename":…,"file_data":"data:…;base64,…"}}`.
pub const OpenAiFile = struct {
    filename: []const u8,
    file_data: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("filename");
        try stringify.write(self.filename);
        try stringify.objectField("file_data");
        try stringify.write(self.file_data);
        try stringify.endObject();
    }
};

/// The Anthropic shape of a document part:
/// `{"type":"document","source":{"type":"base64","media_type":…,"data":…}}`.
pub const AnthropicDocument = struct {
    media_type: []const u8,
    data: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("base64");
        try stringify.objectField("media_type");
        try stringify.write(self.media_type);
        try stringify.objectField("data");
        try stringify.write(self.data);
        try stringify.endObject();
    }
};

/// Image URL content for vision support
pub const ImageUrl = struct {
    url: ?[]const u8 = null,
    detail: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.url) |u| {
            try stringify.objectField("url");
            try stringify.write(u);
        }
        if (self.detail) |d| {
            try stringify.objectField("detail");
            try stringify.write(d);
        }
        try stringify.endObject();
    }
};

/// Video URL content for video understanding.
pub const VideoUrl = struct {
    url: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.url) |u| {
            try stringify.objectField("url");
            try stringify.write(u);
        }
        try stringify.endObject();
    }
};

/// Allowlisted video MIME suffixes (after `data:video/`). Locked 2026-09-18:
/// full video/* v1 = mp4, webm, quicktime (mov), x-msvideo (avi), x-matroska
/// (mkv).
pub fn isSupportedVideoMime(mime: []const u8) bool {
    if (std.mem.eql(u8, mime, "video/mp4")) return true;
    if (std.mem.eql(u8, mime, "video/webm")) return true;
    if (std.mem.eql(u8, mime, "video/quicktime")) return true;
    if (std.mem.eql(u8, mime, "video/x-msvideo")) return true;
    if (std.mem.eql(u8, mime, "video/x-matroska")) return true;
    return false;
}

/// Extract the `video/<suffix>` mime from a `data:video/...;base64,...` URL.
/// Returns null when the URL is not a video data URL.
pub fn videoMimeFromDataUrl(url: []const u8) ?[]const u8 {
    const prefix = "data:video/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const after = url[prefix.len..];
    const sep = std.mem.indexOf(u8, after, ";base64,") orelse return null;
    if (sep == 0) return null;
    // Slice `video/<suffix>` out of the input (skip the `data:` scheme).
    return url["data:".len .. prefix.len + sep];
}

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const FinishReason = enum {
    stop,
    length,
    tool_calls,
    content_filter,
    tool,
    null,
    assistant,
    /// Not a provider value: persisted by the agentic loop when the
    /// assistant message ended with an `ask_user` block.
    awaiting_user,

    pub fn from_str(s: ?[]const u8) ?FinishReason {
        if (s == null) return .null;
        const str = s.?;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "length")) return .length;
        if (std.mem.eql(u8, str, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
        if (std.mem.eql(u8, str, "tool")) return .tool;
        if (std.mem.eql(u8, str, "assistant")) return .assistant;
        if (std.mem.eql(u8, str, "awaiting_user")) return .awaiting_user;
        return null;
    }

    pub fn to_str(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_calls => "tool_calls",
            .content_filter => "content_filter",
            .tool => "tool",
            .null => "null",
            .assistant => "assistant",
            .awaiting_user => "awaiting_user",
        };
    }
};

const JsonFunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

const JsonToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: JsonFunctionCall,
};

const JsonMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    content_parts: ?[]const ChatContentPart = null,
    tool_calls: ?[]const JsonToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        if (self.content) |c| {
            try stringify.objectField("content");
            try stringify.write(c);
        } else if (self.content_parts) |parts| {
            try stringify.objectField("content");
            try stringify.write(parts);
        }
        if (self.tool_calls) |tc| {
            try stringify.objectField("tool_calls");
            try stringify.write(tc);
        }
        if (self.tool_call_id) |id| {
            try stringify.objectField("tool_call_id");
            try stringify.write(id);
        }
        if (self.reasoning_content) |rc| {
            try stringify.objectField("reasoning_content");
            try stringify.write(rc);
        }
        try stringify.endObject();
    }
};

const JsonToolParameters = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const JsonToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonToolParameters,
};

const JsonTool = struct {
    type: []const u8,
    function: JsonToolFunction,
};

const JsonStreamOptions = struct {
    include_usage: bool,
};

const JsonRequest = struct {
    model: []const u8,
    messages: []const JsonMessage,
    temperature: f32,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const JsonTool = null,
    tool_choice: ?[]const u8 = null,

    /// Optional end-user identifier. Omitted from the JSON body when null
    /// or empty. Maps to OpenAI's `user` request-body parameter. See
    /// https://platform.openai.com/docs/api-reference/chat/create.
    user: ?[]const u8 = null,

    /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1). One of
    /// "low" | "medium" | "high" | "auto". Mirrors the
    /// `Agent.reasoningEffort` field directly.
    reasoning_effort: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("temperature");
        try stringify.write(self.temperature);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            try stringify.objectField("tool_choice");
            try stringify.write(self.tool_choice.?);
        }
        if (self.user) |u| {
            if (u.len > 0) {
                try stringify.objectField("user");
                try stringify.write(u);
            }
        }
        // reasoning_effort: only emitted when non-null AND non-empty.
        if (self.reasoning_effort) |re| {
            if (re.len > 0) {
                try stringify.objectField("reasoning_effort");
                try stringify.write(re);
            }
        }
        try stringify.endObject();
    }
};

const AnthropicContentBlock = struct {
    text: ?[]const u8 = null,
    tool_use: ?AnthropicToolUse = null,
    tool_result: ?AnthropicToolResult = null,
    /// Anthropic vision image source.
    image: ?AnthropicImage = null,
    video: ?AnthropicVideo = null,
    /// Anthropic document source — a PDF the model reads as a file.
    document: ?AnthropicDocument = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.text) |t| {
            try stringify.objectField("type");
            try stringify.write("text");
            try stringify.objectField("text");
            try stringify.write(t);
        } else if (self.tool_use) |tu| {
            try stringify.objectField("type");
            try stringify.write("tool_use");
            try stringify.objectField("id");
            try stringify.write(tu.id);
            try stringify.objectField("name");
            try stringify.write(tu.name);
            try stringify.objectField("input");
            try stringify.write(tu.input);
        } else if (self.tool_result) |tr| {
            try stringify.objectField("type");
            try stringify.write("tool_result");
            try stringify.objectField("tool_use_id");
            try stringify.write(tr.tool_use_id);
            try stringify.objectField("content");
            try stringify.write(tr.content);
        } else if (self.image) |img| {
            try stringify.objectField("type");
            try stringify.write("image");
            try stringify.objectField("source");
            try img.jsonStringify(stringify);
        } else if (self.video) |vid| {
            try stringify.objectField("type");
            try stringify.write("video");
            try stringify.objectField("source");
            try vid.jsonStringify(stringify);
        } else if (self.document) |doc| {
            try stringify.objectField("type");
            try stringify.write("document");
            try stringify.objectField("source");
            try doc.jsonStringify(stringify);
        }
        try stringify.endObject();
    }
};

const AnthropicImage = struct {
    /// Either "url" (for an `https://` URL or a `data:` URL) or
    /// "base64" (for a broken-out `media_type` + `data` payload).
    /// Matches Anthropic's `image.source.type` enum.
    source_type: []const u8,
    /// For `source_type = "url"`, the full URL or `data:` URI. For
    /// `source_type = "base64"`, the raw base64 payload.
    url_or_data: []const u8,
    /// Only populated when `source_type = "base64"`, e.g. "image/png".
    /// Null for `url` sources (Anthropic's strict API infers media_type
    /// from the URL extension; OpenAI-compatible relays don't care).
    media_type: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.source_type);
        if (std.mem.eql(u8, self.source_type, "base64")) {
            try stringify.objectField("media_type");
            try stringify.write(self.media_type orelse "image/png");
            try stringify.objectField("data");
            try stringify.write(self.url_or_data);
        } else {
            try stringify.objectField("url");
            try stringify.write(self.url_or_data);
        }
        try stringify.endObject();
    }
};

/// Anthropic video source. Same `url` vs `base64` split as AnthropicImage,
/// but defaults to `video/mp4` and carries video mimes.
const AnthropicVideo = struct {
    source_type: []const u8,
    url_or_data: []const u8,
    media_type: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.source_type);
        if (std.mem.eql(u8, self.source_type, "base64")) {
            try stringify.objectField("media_type");
            try stringify.write(self.media_type orelse "video/mp4");
            try stringify.objectField("data");
            try stringify.write(self.url_or_data);
        } else {
            try stringify.objectField("url");
            try stringify.write(self.url_or_data);
        }
        try stringify.endObject();
    }
};

const AnthropicToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

const AnthropicToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
};

const AnthropicMessageContent = union(enum) {
    single: struct {
        text: []const u8 = "",
    },
    array: []const AnthropicContentBlock,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        switch (self) {
            .single => |s| try stringify.write(s.text),
            .array => |arr| try stringify.write(arr),
        }
    }
};

const AnthropicMessage = struct {
    role: []const u8,
    content: AnthropicMessageContent,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        try stringify.objectField("content");
        try stringify.write(self.content);
        try stringify.endObject();
    }
};

const AnthropicThinking = struct {
    /// "enabled" (with budget_tokens) or "adaptive" (Anthropic picks its own
    /// budget — recommended for Sonnet 4.5+).
    type: []const u8,
    /// Required only when `type == "enabled"`.
    budget_tokens: ?usize = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        if (self.budget_tokens) |bt| {
            try stringify.objectField("budget_tokens");
            try stringify.write(bt);
        }
        try stringify.endObject();
    }
};

const AnthropicToolInputSchema = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const AnthropicTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: AnthropicToolInputSchema,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write(self.name);
        try stringify.objectField("description");
        try stringify.write(self.description);
        try stringify.objectField("input_schema");
        try stringify.write(self.input_schema);
        try stringify.endObject();
    }
};

/// Anthropic `metadata` block. Currently only `user_id` is supported —
/// Anthropic's Messages API accepts arbitrary key/value metadata but
/// pabrik only uses `user_id` for the LLM-API end-user identifier.
const AnthropicMetadata = struct {
    user_id: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("user_id");
        try stringify.write(self.user_id);
        try stringify.endObject();
    }
};

const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const AnthropicTool = null,
    thinking: ?AnthropicThinking = null,
    temperature: ?f32 = null,
    /// Top-level system prompt. Anthropic rejects `role: "system"` inside
    /// `messages` (400s) — system instructions belong here.
    system: ?[]const u8 = null,

    /// Optional metadata block. Currently emits `{"user_id": "..."}`
    /// from `Agent.userIdentifier`. See
    /// https://docs.claude.com/en/api/messages.
    metadata: ?AnthropicMetadata = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        // Anthropic accepts `system` as a plain string or as an array
        // of content blocks; a string is sufficient for the
        // `role == .system` join the builder does today.
        if (self.system) |s| {
            try stringify.objectField("system");
            try stringify.write(s);
        }
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
        }
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            // NOTE: do NOT emit `stream_options` here.
        }
        if (self.metadata) |m| {
            try stringify.objectField("metadata");
            try stringify.write(m);
        }
        try stringify.endObject();
    }
};

/// --- OpenAI Responses API (url_style = "openai-response") -----------------
/// Request shape for POST /v1/responses
/// (https://developers.openai.com/api/reference/resources/responses) Mirrors
const ResponsesInputContent = struct {
    /// "input_text" | "input_image" | "input_video" | "input_file"
    content_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    video_url: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    file_data: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.content_type);
        if (std.mem.eql(u8, self.content_type, "input_text")) {
            if (self.text) |t| {
                try stringify.objectField("text");
                try stringify.write(t);
            }
        } else if (std.mem.eql(u8, self.content_type, "input_image")) {
            if (self.image_url) |u| {
                try stringify.objectField("image_url");
                try stringify.write(u);
            }
            if (self.detail) |d| {
                try stringify.objectField("detail");
                try stringify.write(d);
            }
        } else if (std.mem.eql(u8, self.content_type, "input_video")) {
            if (self.video_url) |u| {
                try stringify.objectField("video_url");
                try stringify.write(u);
            }
        } else if (std.mem.eql(u8, self.content_type, "input_file")) {
            if (self.filename) |name| {
                try stringify.objectField("filename");
                try stringify.write(name);
            }
            if (self.file_data) |data| {
                try stringify.objectField("file_data");
                try stringify.write(data);
            }
        } else {
            if (self.text) |t| {
                try stringify.objectField("text");
                try stringify.write(t);
            }
        }
        try stringify.endObject();
    }
};

const ResponsesReasoningSummary = struct {
    type: []const u8 = "summary_text",
    text: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.objectField("text");
        try stringify.write(self.text);
        try stringify.endObject();
    }
};

const ResponsesInputItem = struct {
    /// "message" | "function_call" | "function_call_output" | "reasoning"
    item_type: []const u8,
    role: ?[]const u8 = null,
    content: ?[]const ResponsesInputContent = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
    id: ?[]const u8 = null,
    summary: ?[]const ResponsesReasoningSummary = null,
    encrypted_content: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.item_type);
        if (std.mem.eql(u8, self.item_type, "reasoning")) {
            if (self.id) |rid| {
                if (rid.len > 0) {
                    try stringify.objectField("id");
                    try stringify.write(rid);
                }
            }
            if (self.summary) |s| {
                try stringify.objectField("summary");
                try stringify.write(s);
            }
            if (self.encrypted_content) |ec| {
                if (ec.len > 0) {
                    try stringify.objectField("encrypted_content");
                    try stringify.write(ec);
                }
            }
        } else if (std.mem.eql(u8, self.item_type, "message")) {
            if (self.role) |r| {
                try stringify.objectField("role");
                try stringify.write(r);
            }
            if (self.content) |c| {
                try stringify.objectField("content");
                try stringify.write(c);
            }
        } else if (std.mem.eql(u8, self.item_type, "function_call")) {
            if (self.call_id) |cid| {
                try stringify.objectField("call_id");
                try stringify.write(cid);
            }
            if (self.name) |n| {
                try stringify.objectField("name");
                try stringify.write(n);
            }
            if (self.arguments) |a| {
                try stringify.objectField("arguments");
                try stringify.write(a);
            }
        } else if (std.mem.eql(u8, self.item_type, "function_call_output")) {
            if (self.call_id) |cid| {
                try stringify.objectField("call_id");
                try stringify.write(cid);
            }
            if (self.output) |o| {
                try stringify.objectField("output");
                try stringify.write(o);
            }
        }
        try stringify.endObject();
    }
};

const ResponsesToolParameters = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

const ResponsesTool = struct {
    type: []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: ResponsesToolParameters,
    strict: ?bool = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.objectField("name");
        try stringify.write(self.name);
        try stringify.objectField("description");
        try stringify.write(self.description);
        try stringify.objectField("parameters");
        try stringify.write(self.parameters);
        if (self.strict) |s| {
            try stringify.objectField("strict");
            try stringify.write(s);
        }
        try stringify.endObject();
    }
};

const ResponsesReasoning = struct {
    effort: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("effort");
        try stringify.write(self.effort);
        try stringify.endObject();
    }
};

const ResponsesRequest = struct {
    model: []const u8,
    input: []const ResponsesInputItem,
    instructions: ?[]const u8 = null,
    max_output_tokens: usize,
    stream: bool,
    temperature: ?f32 = null,
    reasoning: ?ResponsesReasoning = null,
    tools: ?[]const ResponsesTool = null,
    tool_choice: ?[]const u8 = null,
    store: bool = false,
    user: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        if (self.instructions) |ins| {
            try stringify.objectField("instructions");
            try stringify.write(ins);
        }
        try stringify.objectField("input");
        try stringify.write(self.input);
        try stringify.objectField("max_output_tokens");
        try stringify.write(self.max_output_tokens);
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }
        if (self.reasoning) |r| {
            try stringify.objectField("reasoning");
            try stringify.write(r);
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            if (self.tool_choice) |tc| {
                try stringify.objectField("tool_choice");
                try stringify.write(tc);
            }
        }
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
        }
        // store=false keeps the API stateless like chat/completions (no previous_response_id)
        try stringify.objectField("store");
        try stringify.write(self.store);
        if (self.user) |u| {
            if (u.len > 0) {
                try stringify.objectField("user");
                try stringify.write(u);
            }
        }
        try stringify.endObject();
    }
};

pub const AgentResponse = struct {
    choices: []Choice,
};

pub const Choice = struct {
    index: usize = 0,
    message: Message,
    finish_reason: ?FinishReason = null,
};

pub const Message = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    reasoning_content: ?[]const u8 = null,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn from_str(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn to_str(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const AgentMessage = struct {
    /// DB primary key from `llm_history.id` (19-digit timestamp string). NULL
    /// for messages synthesized in-memory (e.g. system prompts at
    /// workflow.zig:1046-1064).
    id: ?[]const u8 = null,
    role: Role,
    content: ?[]const u8,
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.id) |i| allocator.free(i);
        if (self.content) |c| allocator.free(c);
        if (self.content_parts) |parts| {
            for (parts) |part| {
                if (part.text) |t| allocator.free(t);
                if (part.image_url) |img| {
                    if (img.url) |u| allocator.free(u);
                    if (img.detail) |d| allocator.free(d);
                }
                if (part.video_url) |vid| {
                    if (vid.url) |u| allocator.free(u);
                }
                if (part.file) |f| {
                    allocator.free(f.filename);
                    allocator.free(f.mime);
                    allocator.free(f.b64);
                }
            }
            allocator.free(parts);
        }
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.reasoning_content) |rc| allocator.free(rc);
        if (self.reasoning_id) |rid| allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| allocator.free(rec);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.function.name);
                allocator.free(tool_call.function.arguments);
            }
            allocator.free(tc);
        }
    }
};

pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Anthropic-only: tokens used to write a cache entry on this call.
    /// Billed at the cache-write rate (typically ~1.25× input rate), so
    /// DO add this to any billing formula. 0 for non-Anthropic profiles.
    cache_creation_input_tokens: usize = 0,
    /// Anthropic-only: tokens read from a cache entry on this call.
    cache_read_input_tokens: usize = 0,
};

pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    function_name: ?[]const u8 = null,
    function_arguments: ?[]const u8 = null,
};

pub const StreamChunk = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    tool_calls_delta: ?[]const ToolCallDelta = null,
    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    done: bool = false,
};

pub const StreamCallback = *const fn (ctx: ?*anyopaque, chunk: StreamChunk) void;

pub const StreamingAggregator = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    reasoning_content: std.ArrayList(u8),
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    usage: Usage = .{},

    // Per-LLM-tool-call intermediate buffer.
    tool_call_buffers: std.AutoHashMap(usize, struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: std.ArrayList(u8),
    }),

    pub fn init(allocator: std.mem.Allocator) StreamingAggregator {
        return .{
            .allocator = allocator,
            .content = .empty,
            .reasoning_content = .empty,
            .tool_call_buffers = .init(allocator),
        };
    }

    /// NO-OP. Lifetime is arena-owned by the caller (see `CallResponse` doc).
    pub fn deinit(_: *StreamingAggregator) void {}

    pub fn process_chunk(self: *StreamingAggregator, chunk: StreamChunk) !void {
        if (chunk.done) return;

        if (chunk.content) |c| {
            try self.content.appendSlice(self.allocator, c);
        }
        if (chunk.reasoning_content) |rc| {
            // Terminal chunks (finish_reason or reasoning_id present) carry
            // summary[] as fallback — only use if no delta reasoning arrived.
            const is_terminal = chunk.finish_reason != null or chunk.reasoning_id != null or chunk.reasoning_encrypted_content != null;
            if (is_terminal) {
                if (self.reasoning_content.items.len == 0 and rc.len > 0) {
                    try self.reasoning_content.appendSlice(self.allocator, rc);
                }
            } else {
                try self.reasoning_content.appendSlice(self.allocator, rc);
            }
        }

        if (chunk.tool_calls_delta) |deltas| {
            for (deltas) |delta| {
                const gop = try self.tool_call_buffers.getOrPut(delta.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = null,
                        .name = null,
                        .arguments = .empty,
                    };
                }
                if (delta.id) |id| {
                    if (gop.value_ptr.id) |old| self.allocator.free(old);
                    gop.value_ptr.id = try self.allocator.dupe(u8, id);
                }
                if (delta.function_name) |name| {
                    if (gop.value_ptr.name) |old| self.allocator.free(old);
                    gop.value_ptr.name = try self.allocator.dupe(u8, name);
                }
                if (delta.function_arguments) |args| {
                    try gop.value_ptr.arguments.appendSlice(self.allocator, args);
                }
            }
        }

        if (chunk.reasoning_id) |rid| {
            if (self.reasoning_id) |old| self.allocator.free(old);
            self.reasoning_id = try self.allocator.dupe(u8, rid);
        }
        if (chunk.reasoning_encrypted_content) |rec| {
            if (self.reasoning_encrypted_content) |old| self.allocator.free(old);
            self.reasoning_encrypted_content = try self.allocator.dupe(u8, rec);
        }

        if (chunk.finish_reason) |fr| {
            self.finish_reason = fr;
        }

        if (chunk.usage) |usage| {
            if (usage.total_tokens > 0) {
                self.usage = usage;
            }
        }
    }

    pub fn finalize(self: *StreamingAggregator) !CallResponse {
        var sorted_indices: std.ArrayList(usize) = .empty;
        defer sorted_indices.deinit(self.allocator);

        var iter = self.tool_call_buffers.iterator();
        while (iter.next()) |entry| {
            try sorted_indices.append(self.allocator, entry.key_ptr.*);
        }
        std.sort.pdq(usize, sorted_indices.items, {}, std.sort.asc(usize));

        // Allocate the final `[]ToolCall` slice ONCE on `self.allocator` (the
        // caller's arena) and copy each inner slice header into it.
        var tool_calls_out: ?[]ToolCall = null;
        if (sorted_indices.items.len > 0) {
            const count = sorted_indices.items.len;
            const tool_call_slice = try self.allocator.alloc(ToolCall, count);
            var out_i: usize = 0;
            for (sorted_indices.items) |idx| {
                const buffer = self.tool_call_buffers.get(idx).?;
                if (buffer.id) |id| {
                    tool_call_slice[out_i] = .{
                        .id = id,
                        .function = .{
                            .name = if (buffer.name) |n| n else "",
                            .arguments = buffer.arguments.items,
                        },
                    };
                    out_i += 1;
                }
            }
            tool_calls_out = tool_call_slice[0..out_i];
        }

        var content_copy: ?[]const u8 = null;
        if (self.content.items.len > 0) {
            content_copy = try self.allocator.dupe(u8, std.mem.trim(u8, self.content.items, &std.ascii.whitespace));
        }

        var reasoning_copy: ?[]const u8 = null;
        if (self.reasoning_content.items.len > 0) {
            reasoning_copy = try self.allocator.dupe(u8, self.reasoning_content.items);
        }

        var reasoning_id_copy: ?[]const u8 = null;
        if (self.reasoning_id) |rid| {
            reasoning_id_copy = try self.allocator.dupe(u8, rid);
        }
        var reasoning_enc_copy: ?[]const u8 = null;
        if (self.reasoning_encrypted_content) |rec| {
            reasoning_enc_copy = try self.allocator.dupe(u8, rec);
        }

        return .{
            .allocator = self.allocator,
            .content = content_copy,
            .tool_calls = tool_calls_out,
            .finish_reason = self.finish_reason,
            .reasoning_content = reasoning_copy,
            .reasoning_id = reasoning_id_copy,
            .reasoning_encrypted_content = reasoning_enc_copy,
            .usage = self.usage,
        };
    }
};

pub const AgentCall = struct {
    tools: []const AgentTool,
    messages: []const AgentMessage,
    temperature: ?f32 = null,
    max_tokens: ?usize = null,
    /// Polled between SSE chunks so a caller can abort an in-flight turn.
    cancel_fn: ?*const fn () bool = null,
};

pub const HttpOptions = struct {
    /// Overall deadline for the entire streaming read (response head + body).
    /// Triggers `error.StreamTimeout` if exceeded. Default 5 minutes.
    read_timeout_ms: u32 = 300_000,
    /// Idle window: if no new bytes arrive for this long after readSliceShort
    /// returns, the stream is considered hung.
    idle_timeout_ms: u32 = 180_000,
    /// Buffer size for reading HTTP response body
    response_buffer_size: usize = 256 * 1024,
    /// Buffer size for HTTP headers
    header_buffer_size: usize = 16 * 1024,
};

pub const CallResponse = struct {
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall,
    finish_reason: ?FinishReason,
    reasoning_content: ?[]const u8 = null,
    reasoning_id: ?[]const u8 = null,
    reasoning_encrypted_content: ?[]const u8 = null,
    usage: Usage = .{},

    pub fn deinit(self: *const CallResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.reasoning_content) |rc| self.allocator.free(rc);
        if (self.reasoning_id) |rid| self.allocator.free(rid);
        if (self.reasoning_encrypted_content) |rec| self.allocator.free(rec);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                self.allocator.free(tool_call.id);
                self.allocator.free(tool_call.function.name);
                self.allocator.free(tool_call.function.arguments);
            }
            self.allocator.free(tc);
        }
    }
};

/// Writes the UrlStyle-specific auth headers for one streaming request into
/// `out` and returns how many it wrote.
pub fn authHeaders(
    allocator: std.mem.Allocator,
    style: []const u8,
    api_key: []const u8,
    out: []custom_http_client.Header,
    auth_value: *?[]u8,
) !usize {
    if (!std.mem.eql(u8, style, "anthropic")) {
        const bearer = try std.mem.concat(allocator, u8, &.{ "Bearer ", api_key });
        auth_value.* = bearer;
        out[0] = .{ .name = "authorization", .value = bearer };
        return 1;
    }
    var n: usize = 0;
    out[n] = .{ .name = "anthropic-version", .value = "2023-06-01" };
    n += 1;
    if (api_key.len > 0) {
        out[n] = .{ .name = "x-api-key", .value = api_key };
        n += 1;
    }
    return n;
}

pub const Agent = struct {
    name: []const u8 = "",
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
    temperature: f32 = 0.4,
    maxTokens: usize = 4096,
    client: custom_http_client.Client,
    io: std.Io,
    thinkingEnabled: bool = true,
    /// Anthropic-only: override for `thinking.budget_tokens`. When set,
    /// `buildJsonAnthropicRequest` uses it directly (clamped to >=1024 and
    /// <max_tokens).
    thinkingBudgetTokens: ?u32 = null,
    /// Anthropic-only: when true AND `thinkingBudgetTokens` is null,
    /// `buildJsonAnthropicRequest` emits `thinking: {type: "adaptive"}`
    /// instead of the 50%-of-max heuristic.
    thinkingAdaptive: bool = false,
    /// OpenAI-style reasoning effort knob (o1 / o3 / GPT-5 / DeepSeek-R1).
    /// One of "low" | "medium" | "high" | "auto".
    reasoningEffort: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    httpOptions: HttpOptions = .{},
    UrlStyle: []const u8 = "openai",
    /// Which TRANSPORT this call uses: `"http"` (default) | `"claude-code"`.
    /// Deliberately NOT a `UrlStyle` value.
    backend: []const u8 = "http",
    userIdentifier: []const u8 = "AnakMagang",
    /// Stable per-conversation session id for OpenCode Go / Zen routing. Sent
    /// as the `x-opencode-session` HTTP header on every LLM request when
    /// non-empty.
    sessionId: []const u8 = "",
    /// Most recent server/transporter error detail (e.g. the JSON error body
    /// the LLM provider returned for HTTP >=400, or a synthesized reason for
    /// mid-stream failures like scanner errors / missing finish_reason).
    last_error_message: ?[]const u8 = null,

    /// Anthropic-only: cached input_tokens from the `message_start` event.
    _anthropic_input_tokens: u32 = 0,
    /// Anthropic-only: guard so the cached input_tokens are sent exactly
    /// once per call (on the first delta). Reset to false at the top of
    /// every `callStreaming` invocation.
    _anthropic_usage_emitted: bool = false,
    /// Anthropic-only: cached `cache_read_input_tokens` from message_start.
    _anthropic_cache_read_tokens: u32 = 0,
    /// Anthropic-only: cached `cache_creation_input_tokens` from
    /// message_start.
    _anthropic_cache_creation_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
        };
    }

    pub fn init_with_options(allocator: std.mem.Allocator, io: std.Io, options: HttpOptions) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
            .httpOptions = options,
        };
    }

    pub fn log_msg(_: Agent, level: LogLevel, message: []const u8) void {
        logger_mod.debugPrint("[{s}] {s}\n", .{ @tagName(level), message });
    }

    pub fn log_fmt(self: Agent, comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            logger_mod.debugPrint("fmt alloc failed\n", .{});
            return;
        };
        defer self.allocator.free(msg);
        self.log_msg(level, msg);
    }

    pub fn log_error(self: Agent, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |d| {
            self.log_fmt(.err, "{s} failed: {s} - {s}", .{ operation, @errorName(err), d });
        } else {
            self.log_fmt(.err, "{s} failed: {s}", .{ operation, @errorName(err) });
        }
    }

    pub fn log_api_error(self: Agent, operation: []const u8, err: anyerror, body: []const u8) void {
        const max_body_len = 500;
        const truncated = body.len > max_body_len;
        const body_to_log = if (truncated) body[0..max_body_len] else body;
        if (truncated) {
            self.log_fmt(.err, "{s} failed: {s}\nResponse (truncated): {s}...", .{ operation, @errorName(err), body_to_log });
        } else {
            self.log_fmt(.err, "{s} failed: {s}\nResponse: {s}", .{ operation, @errorName(err), body_to_log });
        }
    }

    pub fn log_request(self: Agent, method: []const u8, url: []const u8, body_len: usize) void {
        self.log_fmt(.debug, "HTTP {s} {s} (body: {} bytes)", .{ method, url, body_len });
    }

    pub fn buildJsonAnthropicRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
        }
        const json_messages = try arena_alloc.alloc(AnthropicMessage, params.messages.len);
        // `params.messages` may contain entries with `role == .system`.
        var json_message_count: usize = 0;
        var system_text: std.ArrayList(u8) = .empty;
        for (params.messages) |msg| {
            if (msg.role == .system) {
                if (msg.content) |c| {
                    if (system_text.items.len > 0) {
                        try system_text.appendSlice(arena_alloc, "\n\n");
                    }
                    try system_text.appendSlice(arena_alloc, c);
                }
                continue; // skip — already joined into top-level "system"
            }
            if (msg.role == .assistant and msg.tool_calls != null) {
                var content_blocks: []AnthropicContentBlock = &.{};
                // NOTE: content_blocks is stored into
                // json_messages[json_message_count].content below and must
                // stay alive until the whole request has been serialized by

                if (msg.reasoning_content) |rc| {
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    // CRITICAL: explicitly set ALL three optional fields.
                    content_blocks[content_blocks.len - 1] = .{
                        .text = rc,
                        .tool_use = null,
                        .tool_result = null,
                    };
                }

                for (msg.tool_calls.?) |tc| {
                    const input_value = blk: {
                        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, tc.function.arguments, .{}) catch {
                            break :blk std.json.Value{ .null = {} };
                        };
                        break :blk parsed.value;
                    };
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{
                        .text = null,
                        .tool_use = .{
                            .id = tc.id,
                            .name = tc.function.name,
                            .input = input_value,
                        },
                        .tool_result = null,
                    };
                }

                json_messages[json_message_count] = .{
                    .role = "assistant",
                    .content = .{ .array = content_blocks },
                };
            } else if (msg.role == .tool) {
                const tool_content = try arena_alloc.alloc(AnthropicContentBlock, 1);
                tool_content[0] = .{
                    .text = null,
                    .tool_use = null,
                    .tool_result = .{
                        .tool_use_id = msg.tool_call_id orelse "",
                        .content = msg.content orelse "",
                    },
                };
                json_messages[json_message_count] = .{
                    .role = "user",
                    .content = .{ .array = tool_content },
                };
            } else {
                // User messages (or any role whose `content_parts` carries
                // multimodal content, e.g. an attached image).
                const parts = msg.content_parts;
                const has_parts = parts != null and parts.?.len > 0;
                if (has_parts) {
                    var non_assistant_blocks: []AnthropicContentBlock = &.{};
                    // Contents live until `defer arena.deinit()` (top of fn)
                    // — same lifetime as the assistant branch's blocks.
                    const part_count = parts.?.len;
                    non_assistant_blocks = try arena_alloc.alloc(
                        AnthropicContentBlock,
                        part_count,
                    );
                    for (parts.?, 0..) |part, j| {
                        // CRITICAL: explicitly set ALL optional fields (see
                        // comment above about 0xAA arena poison → SEGV).
                        non_assistant_blocks[j] = .{
                            .text = null,
                            .tool_use = null,
                            .tool_result = null,
                            .image = null,
                            .video = null,
                            .document = null,
                        };
                        if (part.image_url) |img| {
                            const url_str = img.url orelse "";
                            non_assistant_blocks[j].image = .{
                                .source_type = "url",
                                .url_or_data = url_str,
                                .media_type = null,
                            };
                        } else if (part.video_url) |vid| {
                            const url_str = vid.url orelse "";
                            if (url_str.len == 0) return error.UnsupportedVideoModel;
                            const mime = videoMimeFromDataUrl(url_str);
                            if (mime) |m| {
                                if (!isSupportedVideoMime(m)) return error.UnsupportedVideoModel;
                            }
                            non_assistant_blocks[j].video = .{
                                .source_type = "url",
                                .url_or_data = url_str,
                                .media_type = null,
                            };
                        } else if (part.file) |f| {
                            const kind = file_attachments.classify(f.filename, f.mime);
                            if (!file_attachments.styleCarriesFile("anthropic", kind)) {
                                return error.UnsupportedFileType;
                            }
                            non_assistant_blocks[j].document = .{
                                .media_type = f.mime,
                                .data = f.b64,
                            };
                        } else if (part.text) |t| {
                            non_assistant_blocks[j].text = t;
                        } else {
                            // Hard error: never silently drop an unknown part
                            // (locked 2026-09-18). A video part from a future
                            // mime or a malformed part must surface, not coerce to "".
                            return error.UnsupportedContentPart;
                        }
                    }
                    json_messages[json_message_count] = .{
                        .role = msg.role.to_str(),
                        .content = .{ .array = non_assistant_blocks },
                    };
                } else {
                    json_messages[json_message_count] = .{
                        .role = msg.role.to_str(),
                        .content = .{ .single = .{ .text = msg.content orelse "" } },
                    };
                }
            }
            json_message_count += 1;
        }

        var json_tools: ?[]AnthropicTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(AnthropicTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                    .input_schema = .{
                        .properties = json_props,
                        .required = tool.function.parameters.required,
                    },
                };
            }
            json_tools = tool_slice;
        }

        const resolved_max_tokens: usize = params.max_tokens orelse self.maxTokens;

        // Anthropic requires `budget_tokens` to be >= 1024 AND strictly less
        // than `max_tokens`.
        const thinking_on: bool = blk: {
            if (!self.thinkingEnabled) break :blk false;
            if (resolved_max_tokens < 1025) {
                self.log_fmt(.warn, "buildJsonAnthropicRequest: thinkingEnabled=true but max_tokens={d} (<1025) — Anthropic requires budget_tokens >= 1024 AND < max_tokens, so thinking is forced off for this request. Raise max_tokens to >=1025 to re-enable.", .{resolved_max_tokens});
                break :blk false;
            }
            break :blk true;
        };

        const thinking_budget: ?usize = blk: {
            if (!thinking_on) break :blk null;
            // Three sources, in priority order (plan
            // 2026-08-23-model-thinking): 1. Explicit
            // `Agent.thinkingBudgetTokens` override.
            if (self.thinkingBudgetTokens) |explicit| {
                const floor_constrained: usize = if (explicit < 1024) 1024 else explicit;
                const ceiling: usize = resolved_max_tokens -| 1;
                break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
            }
            if (self.thinkingAdaptive) {
                break :blk null;
            }
            const half = resolved_max_tokens / 2;
            const floor_constrained: usize = if (half < 1024) 1024 else half;
            const ceiling: usize = resolved_max_tokens -| 1;
            break :blk if (floor_constrained < ceiling) floor_constrained else ceiling;
        };

        // Anthropic requires `temperature` to be omitted (or exactly 1) when
        // `thinking.type == "enabled"`.
        if (thinking_on) {
            if (params.temperature) |t| {
                if (t != 1.0) {}
            }
        }

        const thinking_value: ?AnthropicThinking = blk: {
            if (!thinking_on) break :blk null;
            if (thinking_budget) |bt| break :blk .{ .type = "enabled", .budget_tokens = bt };
            // Adaptive mode — Anthropic picks the budget itself.
            // Triggered by profile.thinking == "auto" with no
            // explicit budget override.
            break :blk .{ .type = "adaptive" };
        };

        const json_request = AnthropicRequest{
            .model = self.model,
            .messages = json_messages[0..json_message_count],
            .max_tokens = resolved_max_tokens,
            .stream = stream,
            .tools = json_tools,
            .thinking = thinking_value,
            .temperature = if (thinking_on) null else params.temperature,
            .system = if (system_text.items.len > 0) system_text.items else null,
            .metadata = if (self.userIdentifier.len > 0)
                .{ .user_id = self.userIdentifier }
            else
                null,
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    pub fn buildJsonOpenAIRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
            if (msg.reasoning_content) |rc| total_content_size += rc.len;
        }
        var total_props: usize = 0;
        for (params.tools) |tool| {
            total_props += tool.function.parameters.properties.len;
        }
        // Reasoning-echo backfill (task_1789091513563_0): DeepSeek-style
        // providers in thinking mode REQUIRE every assistant message to carry
        // `reasoning_content` ("must be passed back to the API").
        const history_has_reasoning = blk: {
            for (params.messages) |m| {
                if (m.reasoning_content != null) break :blk true;
            }
            break :blk false;
        };
        const backfill_empty_reasoning = self.thinkingEnabled or history_has_reasoning;

        const json_messages = try arena_alloc.alloc(JsonMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            var json_tool_calls: ?[]JsonToolCall = null;
            if (msg.tool_calls) |tcs| {
                const tc_slice = try arena_alloc.alloc(JsonToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    // Repair before falling back to "{}": a Windows path
                    // written with raw backslashes is invalid JSON, and
                    // substituting "{}" here would both hide that and echo
                    const normalized_args = blk: {
                        const raw = tc.function.arguments;
                        if (raw.len == 0) break :blk "{}";
                        const repaired = args_repair.repairToolCallArguments(arena_alloc, raw) catch break :blk "{}";
                        break :blk if (repaired) |r| r.slice() else "{}";
                    };
                    tc_slice[j] = .{
                        .id = tc.id,
                        .type = tc.type,
                        .function = .{
                            .name = tc.function.name,
                            .arguments = normalized_args,
                        },
                    };
                }
                json_tool_calls = tc_slice;
            }

            var json_content_parts: ?[]const ChatContentPart = null;
            if (msg.content_parts) |parts| {
                const parts_copy = try arena_alloc.alloc(ChatContentPart, parts.len);
                for (parts, 0..) |part, j| {
                    parts_copy[j] = .{
                        .part_type = part.part_type,
                        .text = part.text,
                        .image_url = part.image_url,
                        .video_url = part.video_url,
                        .file = if (part.file) |f| try chatFilePart(arena_alloc, f) else null,
                    };
                }
                json_content_parts = parts_copy;
            }

            json_messages[i] = .{
                .role = msg.role.to_str(),
                .content = msg.content,
                .content_parts = json_content_parts,
                .tool_calls = json_tool_calls,
                .tool_call_id = msg.tool_call_id,
                // See backfill comment above: null → "" for assistant
                // messages in thinking conversations (satisfies the
                // provider's echo validator); null stays null otherwise so
                .reasoning_content = msg.reasoning_content orelse (if (backfill_empty_reasoning and msg.role == .assistant) "" else null),
            };
        }

        var json_tools: ?[]JsonTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(JsonTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .type = tool.type,
                    .function = .{
                        .name = tool.function.name,
                        .description = tool.function.description,
                        .parameters = .{
                            .properties = json_props,
                            .required = tool.function.parameters.required,
                        },
                    },
                };
            }
            json_tools = tool_slice;
        }

        const json_request = JsonRequest{
            .model = self.model,
            .messages = json_messages,
            .temperature = params.temperature orelse self.temperature,
            .max_tokens = params.max_tokens orelse self.maxTokens,
            .stream = stream,
            .tools = json_tools,
            .tool_choice = if (json_tools != null) "auto" else null,
            .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
            // OpenAI reasoning effort (plan 2026-08-23-model-thinking).
            // Borrowed from Agent.reasoningEffort (lifetime tied to the
            // workflow's LlmConfig singleton).
            .reasoning_effort = self.reasoningEffort,
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    /// Build JSON body for OpenAI Responses API (`url_style =
    /// "openai-response"`).
    pub fn buildJsonResponsesRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
            if (msg.reasoning_content) |rc| total_content_size += rc.len;
        }
        // Join system messages into top-level `instructions`.
        var instructions_buf: std.ArrayList(u8) = .empty;
        for (params.messages) |msg| {
            if (msg.role == .system) {
                if (msg.content) |c| {
                    if (instructions_buf.items.len > 0) try instructions_buf.appendSlice(arena_alloc, "\n\n");
                    try instructions_buf.appendSlice(arena_alloc, c);
                }
            }
        }
        const instructions: ?[]const u8 = if (instructions_buf.items.len > 0) instructions_buf.items else null;

        // Build heterogeneous `input` array.
        var total_tool_calls: usize = 0;
        for (params.messages) |msg| {
            if (msg.tool_calls) |tcs| total_tool_calls += tcs.len;
        }
        const max_input_len = params.messages.len * 2 + total_tool_calls;
        var input_items = try arena_alloc.alloc(ResponsesInputItem, max_input_len);
        var input_count: usize = 0;

        for (params.messages) |msg| {
            if (msg.role == .system) continue; // already in `instructions` (§6)
            if (msg.role == .user) {
                // Build content array from content_parts or plain text.
                const parts = msg.content_parts;
                const has_parts = parts != null and parts.?.len > 0;
                if (has_parts) {
                    const part_count = parts.?.len;
                    var contents = try arena_alloc.alloc(ResponsesInputContent, part_count);
                    for (parts.?, 0..) |part, j| {
                        if (part.image_url) |img| {
                            contents[j] = .{
                                .content_type = "input_image",
                                .image_url = img.url orelse "",
                                .detail = img.detail orelse "auto",
                            };
                        } else if (part.video_url) |vid| {
                            const url_str = vid.url orelse "";
                            if (url_str.len == 0) return error.UnsupportedVideoModel;
                            const mime = videoMimeFromDataUrl(url_str);
                            if (mime) |m| {
                                if (!isSupportedVideoMime(m)) return error.UnsupportedVideoModel;
                            }
                            contents[j] = .{
                                .content_type = "input_video",
                                .video_url = url_str,
                            };
                        } else if (part.file) |f| {
                            const kind = file_attachments.classify(f.filename, f.mime);
                            if (!file_attachments.styleCarriesFile("openai-response", kind)) {
                                return error.UnsupportedFileType;
                            }
                            contents[j] = .{
                                .content_type = "input_file",
                                .filename = f.filename,
                                .file_data = try f.dataUrl(arena_alloc),
                            };
                        } else if (part.text) |t| {
                            contents[j] = .{ .content_type = "input_text", .text = t };
                        } else {
                            return error.UnsupportedContentPart;
                        }
                    }
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "user",
                        .content = contents,
                    };
                } else {
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "input_text", .text = msg.content orelse "" };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "user",
                        .content = contents,
                    };
                }
                input_count += 1;
            } else if (msg.role == .assistant) {
                // Responses reasoning is a separate top-level `type:"reasoning"`
                // item, NOT merged into the assistant `type:"message"` content.
                const has_tool_calls = msg.tool_calls != null and msg.tool_calls.?.len > 0;
                const c = msg.content;
                const rc = msg.reasoning_content;
                const has_c = c != null and c.?.len > 0;
                const has_rc = rc != null and rc.?.len > 0;
                const has_rid = msg.reasoning_id != null and msg.reasoning_id.?.len > 0;
                const has_enc = msg.reasoning_encrypted_content != null and msg.reasoning_encrypted_content.?.len > 0;
                const has_reasoning = has_rc or has_rid or has_enc;
                if (has_reasoning) {
                    // Provider (Console Go → upstream) requires `summary` to
                    // be present on every `type:"reasoning"` item.
                    var summary: ?[]const ResponsesReasoningSummary = null;
                    if (has_rc) {
                        var s = try arena_alloc.alloc(ResponsesReasoningSummary, 1);
                        s[0] = .{ .text = rc.? };
                        summary = s;
                    } else {
                        summary = try arena_alloc.alloc(ResponsesReasoningSummary, 0);
                    }
                    input_items[input_count] = .{
                        .item_type = "reasoning",
                        .id = msg.reasoning_id,
                        .summary = summary,
                        .encrypted_content = msg.reasoning_encrypted_content,
                    };
                    input_count += 1;
                }
                if (has_c) {
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "output_text", .text = c.? };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "assistant",
                        .content = contents,
                    };
                    input_count += 1;
                } else if (!has_reasoning and !has_tool_calls) {
                    // Empty assistant message without tools/reasoning — still emit empty message to preserve turn.
                    var contents = try arena_alloc.alloc(ResponsesInputContent, 1);
                    contents[0] = .{ .content_type = "output_text", .text = "" };
                    input_items[input_count] = .{
                        .item_type = "message",
                        .role = "assistant",
                        .content = contents,
                    };
                    input_count += 1;
                }
                if (has_tool_calls) {
                    for (msg.tool_calls.?) |tc| {
                        input_items[input_count] = .{
                            .item_type = "function_call",
                            .call_id = tc.id,
                            .name = tc.function.name,
                            .arguments = tc.function.arguments,
                        };
                        input_count += 1;
                    }
                }
            } else if (msg.role == .tool) {
                // Gateway (Console Go → upstream,
                // url_style="openai-response") validates
                // `function_call_output` strictly: it rejects the request
                const raw_output = msg.content orelse "";
                const clean_output = helpers.sanitize.sanitizeUtf8(arena_alloc, raw_output) catch raw_output;
                // Bound oversize outputs (ls -R + binary dumps). Cap is
                // approximate: 20k content bytes + short marker suffix.
                const max_tool_output_len: usize = 20_000;
                var final_output = clean_output;
                if (clean_output.len > max_tool_output_len) {
                    var keep: usize = max_tool_output_len;
                    // Back off to a UTF-8 char boundary (clean_output is
                    // valid UTF-8 here, so a start byte is always found).
                    while (keep > 0 and clean_output[keep] & 0xC0 == 0x80) keep -= 1;
                    const dropped = clean_output.len - keep;
                    const suffix = std.fmt.allocPrint(arena_alloc, "\n...[truncated {d} of {d} bytes]", .{ dropped, clean_output.len }) catch "";
                    final_output = std.fmt.allocPrint(arena_alloc, "{s}{s}", .{ clean_output[0..keep], suffix }) catch clean_output[0..keep];
                }
                const cid = msg.tool_call_id orelse "";
                if (cid.len == 0) {
                    // An empty call_id can never pair with a function_call —
                    // emitting it poisons the whole request, so skip + log.
                    self.log_fmt(.err, "[RESPONSES] skipping function_call_output with empty call_id (output len={d})", .{final_output.len});
                    continue;
                }
                input_items[input_count] = .{
                    .item_type = "function_call_output",
                    .call_id = cid,
                    .output = final_output,
                };
                input_count += 1;
            }
        }

        var json_tools: ?[]ResponsesTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(ResponsesTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                    .parameters = .{
                        .properties = json_props,
                        .required = tool.function.parameters.required,
                    },
                };
            }
            json_tools = tool_slice;
        }

        const resolved_max_tokens: usize = params.max_tokens orelse self.maxTokens;

        var reasoning: ?ResponsesReasoning = null;
        if (self.reasoningEffort) |eff| {
            if (eff.len > 0) reasoning = .{ .effort = eff };
        }
        // Do NOT auto-map `thinkingEnabled` → reasoning.

        const req = ResponsesRequest{
            .model = self.model,
            .input = input_items[0..input_count],
            .instructions = instructions,
            .max_output_tokens = resolved_max_tokens,
            .stream = stream,
            .temperature = params.temperature orelse self.temperature,
            .reasoning = reasoning,
            .tools = json_tools,
            .tool_choice = if (json_tools != null) "auto" else null,
            .store = false,
            .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
        };

        var aw2: std.Io.Writer.Allocating = .init(allocator);
        try aw2.writer.print("{f}", .{std.json.fmt(req, .{})});
        const out = try aw2.toOwnedSlice();
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {}
        return out;
    }

    pub const CallError = error{
        BuildRequestFailed,
        InvalidUri,
        AuthFailed,
        HttpRequestFailed,
        SendBodyFailed,
        ReceiveFailed,
        ParseJsonFailed,
        ApiError,
        NoChoices,
        AllocFailed,
        /// Profile selects url_style="claude-code" (local CLI backend).
        ClaudeCodeNotWired,
        /// Profile selects backend="opencode" (local CLI backend).
        OpencodeNotWired,
        WriteFailed,
        OutOfMemory,
        Cancelled,
        /// Overall read deadline (HttpOptions.read_timeout_ms) was exceeded.
        StreamTimeout,
        /// No new bytes for HttpOptions.idle_timeout_ms after readSliceShort returned.
        /// With TCP keepalive, this fires after keepalive detects the dead connection
        /// (~25s) and readSliceShort returns an error, then the idle check triggers.
        StreamIdleTimeout,
        /// Mid-stream transport error (e.g. ConnectionResetByPeer from keepalive).
        StreamInterrupted,
        /// Stream ended with 0 chunks and no clean-end signal.
        StreamEmpty,
    };

    pub fn parse_sse_line(_: Agent, line: []const u8) ?[]const u8 {
        if (line.len == 0) return null;
        if (!std.mem.startsWith(u8, line, "data: ")) return null;
        const data = line[6..];
        if (std.mem.eql(u8, data, "[DONE]")) return null;
        return data;
    }

    pub fn parse_stream_chunk(self: *Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        // Anthropic uses a different SSE event shape (`event:` + `data:`
        // pairs with a `type` field, not `choices[0].delta`).
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {
            return self.parse_responses_stream_chunk(data, arena);
        }
        if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            return self.parse_anthropic_stream_chunk(data, arena);
        }
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();
        const root = parsed.value;

        var chunk: StreamChunk = .{};

        if (root.object.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const first_choice = choices.array.items[0];

                if (first_choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) {
                        chunk.finish_reason = FinishReason.from_str(fr.string);
                    }
                }

                const msg_field = first_choice.object.get("delta") orelse first_choice.object.get("message");
                if (msg_field) |delta| {
                    if (delta.object.get("content")) |content| {
                        if (content == .string and content.string.len > 0) {
                            chunk.content = content.string;
                        }
                    }
                    if (delta.object.get("reasoning_content")) |rc| {
                        if (rc == .string and rc.string.len > 0) {
                            chunk.reasoning_content = rc.string;
                        }
                    }
                    if (delta.object.get("tool_calls")) |tc_delta| {
                        if (tc_delta == .array and tc_delta.array.items.len > 0) {
                            var deltas = arena.alloc(ToolCallDelta, tc_delta.array.items.len) catch |err| {
                                self.log_fmt(.err, "Error allocating ToolCallDelta: {s}", .{@errorName(err)});
                                return null;
                            };
                            for (tc_delta.array.items, 0..) |tc_item, i| {
                                var delta_item: ToolCallDelta = .{ .index = i };
                                if (tc_item == .object) {
                                    if (tc_item.object.get("index")) |idx| {
                                        if (idx == .integer) delta_item.index = @intCast(idx.integer);
                                    }
                                    if (tc_item.object.get("id")) |id| {
                                        if (id == .string and id.string.len > 0) delta_item.id = id.string;
                                    }
                                    if (tc_item.object.get("function")) |func| {
                                        if (func == .object) {
                                            if (func.object.get("name")) |name| {
                                                if (name == .string and name.string.len > 0) delta_item.function_name = name.string;
                                            }
                                            if (func.object.get("arguments")) |args| {
                                                if (args == .string and args.string.len > 0) delta_item.function_arguments = args.string;
                                            }
                                        }
                                    }
                                }
                                deltas[i] = delta_item;
                            }
                            chunk.tool_calls_delta = deltas;
                        }
                    }
                }
            }
        }

        if (root.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                var usage: Usage = .{};
                if (usage_val.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                }
                if (usage_val.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                }
                if (usage_val.object.get("total_tokens")) |tt| {
                    if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                }
                chunk.usage = usage;
            }
        }

        return chunk;
    }

    /// Anthropic streaming-SSE → StreamChunk mapper. Anthropic's /v1/messages
    /// streams `event:` + `data:` pairs (the wire shape the OpenAI parser
    /// doesn't understand).
    fn parse_anthropic_stream_chunk(
        self: *Agent,
        data: []const u8,
        arena: std.mem.Allocator,
    ) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const type_val = root.object.get("type") orelse return null;
        if (type_val != .string) return null;
        const event_type = type_val.string;

        if (std.mem.eql(u8, event_type, "message_start")) {
            // Cache input_tokens from message.message.usage.input_tokens.
            // Emit no chunk — the first delta will carry the usage.
            const message = root.object.get("message") orelse return null;
            if (message != .object) return null;
            const usage = message.object.get("usage") orelse return null;
            if (usage != .object) return null;
            if (usage.object.get("input_tokens")) |it| {
                if (it == .integer) self._anthropic_input_tokens = @intCast(it.integer);
            }
            // Cache the cache-shaped fields too — some relays send them at
            // message_start but not at message_delta, and the first-delta
            // usage chunk below folds both into prompt_tokens.
            if (usage.object.get("cache_read_input_tokens")) |cr| {
                if (cr == .integer) self._anthropic_cache_read_tokens = @intCast(cr.integer);
            }
            if (usage.object.get("cache_creation_input_tokens")) |cc| {
                if (cc == .integer) self._anthropic_cache_creation_tokens = @intCast(cc.integer);
            }
            return null;
        }

        var chunk: StreamChunk = .{};

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const index = root.object.get("index") orelse return null;
            const cb = root.object.get("content_block") orelse return null;
            if (index != .integer or cb != .object) return null;
            const cb_type = cb.object.get("type") orelse return null;
            if (cb_type != .string) return null;
            // Only tool_use blocks need a tool_calls_delta here (text /
            // thinking blocks just carry content deltas — handled below).
            if (!std.mem.eql(u8, cb_type.string, "tool_use")) return null;

            const id_val = cb.object.get("id") orelse return null;
            const name_val = cb.object.get("name") orelse return null;
            if (id_val != .string or name_val != .string) return null;

            const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
            delta_slice[0] = .{
                .index = @intCast(index.integer),
                .id = id_val.string,
                .function_name = name_val.string,
            };
            chunk.tool_calls_delta = delta_slice;
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const index_val = root.object.get("index") orelse return null;
            const delta = root.object.get("delta") orelse return null;
            if (index_val != .integer or delta != .object) return null;
            const index: usize = @intCast(index_val.integer);

            const delta_type = delta.object.get("type") orelse return null;
            if (delta_type != .string) return null;

            if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                const text = delta.object.get("text") orelse return null;
                if (text != .string) return null;
                chunk.content = text.string;
            } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                const thinking = delta.object.get("thinking") orelse return null;
                if (thinking != .string) return null;
                chunk.reasoning_content = thinking.string;
            } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
                const partial = delta.object.get("partial_json") orelse return null;
                if (partial != .string) return null;
                const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
                delta_slice[0] = .{
                    .index = index,
                    .function_arguments = partial.string,
                };
                chunk.tool_calls_delta = delta_slice;
            } else {
                return null; // unknown delta.type — ignore
            }

            // Emit a usage chunk on the FIRST delta so the aggregator sees
            // the cached input_tokens count.
            if (self._anthropic_input_tokens > 0 and !self._anthropic_usage_emitted) {
                const cached_creation = self._anthropic_cache_creation_tokens;
                const cached_read = self._anthropic_cache_read_tokens;
                const prompt_first_delta: u32 = self._anthropic_input_tokens + cached_creation + cached_read;
                chunk.usage = .{
                    .prompt_tokens = prompt_first_delta,
                    .completion_tokens = 0,
                    .total_tokens = prompt_first_delta,
                    .cache_creation_input_tokens = cached_creation,
                    .cache_read_input_tokens = cached_read,
                };
                self._anthropic_usage_emitted = true;
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;
            if (delta.object.get("stop_reason")) |sr| {
                if (sr == .string) {
                    chunk.finish_reason = FinishReason.from_str(map_anthropic_stop_reason(sr.string));
                }
            }
            // Anthropic's `message_delta.usage` carries the AUTHORITATIVE
            // token counts for the call.
            if (root.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    var input_tokens: u32 = self._anthropic_input_tokens;
                    var cache_creation_tokens: u32 = self._anthropic_cache_creation_tokens;
                    var cache_read_tokens: u32 = self._anthropic_cache_read_tokens;
                    var output_tokens: u32 = 0;

                    if (usage_val.object.get("input_tokens")) |it| {
                        if (it == .integer) input_tokens = @intCast(it.integer);
                    }
                    if (usage_val.object.get("cache_creation_input_tokens")) |cc| {
                        if (cc == .integer) cache_creation_tokens = @intCast(cc.integer);
                    }
                    if (usage_val.object.get("cache_read_input_tokens")) |cr| {
                        if (cr == .integer) cache_read_tokens = @intCast(cr.integer);
                    }
                    if (usage_val.object.get("output_tokens")) |ot| {
                        if (ot == .integer) output_tokens = @intCast(ot.integer);
                    }

                    if (output_tokens > 0) {
                        const prompt_tokens: u32 = input_tokens + cache_creation_tokens + cache_read_tokens;
                        chunk.usage = .{
                            .prompt_tokens = prompt_tokens,
                            .completion_tokens = output_tokens,
                            .total_tokens = prompt_tokens + output_tokens,
                            .cache_creation_input_tokens = cache_creation_tokens,
                            .cache_read_input_tokens = cache_read_tokens,
                        };
                    }
                }
            }
        } else {
            // message_stop, content_block_stop, ping, anything else — no-op.
            return null;
        }

        return chunk;
    }

    /// Anthropic's stop_reason strings don't match OpenAI's.
    fn map_anthropic_stop_reason(s: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, s, "end_turn")) return "stop";
        if (std.mem.eql(u8, s, "tool_use")) return "tool_calls";
        if (std.mem.eql(u8, s, "max_tokens")) return "length";
        if (std.mem.eql(u8, s, "stop_sequence")) return "stop";
        if (std.mem.eql(u8, s, "refusal")) return "content_filter";
        return null;
    }

    /// OpenAI Responses API streaming-SSE → StreamChunk mapper.
    fn parse_responses_stream_chunk(self: *Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "Responses SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "Responses SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return null;
        const type_val = root.object.get("type") orelse return null;
        if (type_val != .string) return null;
        const event_type = type_val.string;

        var chunk: StreamChunk = .{};

        // Text deltas — may appear as `response.output_text.delta` with field `delta`
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            if (delta.string.len == 0) return null;
            chunk.content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.output_text.annotation.added")) {
            return null;
        }
        if (std.mem.eql(u8, event_type, "response.output_text.done")) {
            return null;
        }
        if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            chunk.content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.refusal.done")) {
            return null;
        }
        // Reasoning deltas (Responses reasoning uses several names)
        if (std.mem.eql(u8, event_type, "response.reasoning_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning.delta"))
        {
            const delta = root.object.get("delta") orelse root.object.get("text") orelse return null;
            if (delta != .string) return null;
            chunk.reasoning_content = delta.string;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.reasoning_text.done") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_text.done"))
        {
            // `done` carries the final `text` for the part — use it as
            // fallback when deltas were not emitted or were dropped.
            const text = root.object.get("text") orelse return null;
            if (text != .string) return null;
            if (text.string.len == 0) return null;
            chunk.reasoning_content = text.string;
            return chunk;
        }
        // Reasoning summary part boundaries — `added`/`done` carry `part`
        // with `{type:"summary_text", text:"..."}`.
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added") or
            std.mem.eql(u8, event_type, "response.reasoning_summary_part.done"))
        {
            const part = root.object.get("part") orelse return null;
            if (part != .object) return null;
            const t = part.object.get("text") orelse return null;
            if (t != .string or t.string.len == 0) return null;
            chunk.reasoning_content = t.string;
            return chunk;
        }
        // Tool call start — `response.output_item.added` with item.type == "function_call"
        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = root.object.get("item") orelse return null;
            if (item != .object) return null;
            const item_type = item.object.get("type") orelse return null;
            if (item_type != .string) return null;
            if (!std.mem.eql(u8, item_type.string, "function_call")) return null;
            const call_id = item.object.get("call_id") orelse item.object.get("id") orelse return null;
            const name_val = item.object.get("name") orelse return null;
            if (call_id != .string or name_val != .string) return null;
            // output_index is the tool index for the aggregator
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{
                .index = idx,
                .id = call_id.string,
                .function_name = name_val.string,
            };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        // Tool arguments deltas
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .string) return null;
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            } else if (root.object.get("item_id")) |_| {
                idx = 0;
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{
                .index = idx,
                .function_arguments = delta.string,
            };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            // Final arguments already assembled via deltas; emit one more delta with full arguments so aggregator finalizes
            const args = root.object.get("arguments") orelse return null;
            if (args != .string) return null;
            // If we already streamed deltas, this is duplicate;aggregator appends, so only emit if non-empty and not already covered
            // We emit as a final chunk only if the string is non-empty and we haven't already emitted same length via deltas
            // For safety, return null to avoid double-append — the deltas already built the full JSON.
            return null;
        }
        // Custom tool deltas (future proof)
        if (std.mem.eql(u8, event_type, "response.custom_tool_call_input.delta")) {
            const delta = root.object.get("delta") orelse root.object.get("input") orelse return null;
            if (delta != .string) return null;
            var idx: usize = 0;
            if (root.object.get("output_index")) |ov| {
                if (ov == .integer) idx = @intCast(ov.integer);
            }
            const slice = arena.alloc(ToolCallDelta, 1) catch return null;
            slice[0] = .{ .index = idx, .function_arguments = delta.string };
            chunk.tool_calls_delta = slice;
            return chunk;
        }
        // Reasoning item done — the per-item finalization carries the
        // complete summary + id + encrypted_content for that reasoning item.
        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = root.object.get("item") orelse return null;
            if (item != .object) return null;
            const it = item.object.get("type") orelse return null;
            if (it != .string or !std.mem.eql(u8, it.string, "reasoning")) return null;
            var has_summary = false;
            var buf: std.ArrayList(u8) = .empty;
            if (item.object.get("summary")) |sv| {
                if (sv == .array) {
                    for (sv.array.items) |si| {
                        if (si != .object) continue;
                        const tv = si.object.get("text") orelse continue;
                        if (tv != .string or tv.string.len == 0) continue;
                        if (has_summary) buf.appendSlice(arena, "\n") catch continue;
                        buf.appendSlice(arena, tv.string) catch continue;
                        has_summary = true;
                    }
                }
            }
            if (has_summary and buf.items.len > 0) chunk.reasoning_content = buf.items;
            if (item.object.get("id")) |idv| {
                if (idv == .string and idv.string.len > 0) chunk.reasoning_id = idv.string;
            }
            if (item.object.get("encrypted_content")) |ev| {
                if (ev == .string and ev.string.len > 0) chunk.reasoning_encrypted_content = ev.string;
            }
            // Don't return yet if only id/enc without summary — let it
            // flow as terminal-like chunk so aggregator captures id/enc.
            if (chunk.reasoning_content != null or chunk.reasoning_id != null or chunk.reasoning_encrypted_content != null) return chunk;
            return null;
        }

        // Terminal events — carry finish_reason + usage
        if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.incomplete") or
            std.mem.eql(u8, event_type, "response.failed"))
        {
            const response = root.object.get("response") orelse root;
            if (response != .object) return null;
            // finish_reason: Responses uses status + incomplete_details.reason
            if (response.object.get("status")) |status_val| {
                if (status_val == .string) {
                    if (std.mem.eql(u8, status_val.string, "completed")) {
                        chunk.finish_reason = .stop;
                    } else if (std.mem.eql(u8, status_val.string, "failed")) {
                        chunk.finish_reason = .content_filter;
                    } else if (std.mem.eql(u8, status_val.string, "incomplete")) {
                        // check reason
                        if (response.object.get("incomplete_details")) |inc| {
                            if (inc == .object) {
                                if (inc.object.get("reason")) |r| {
                                    if (r == .string and std.mem.eql(u8, r.string, "max_output_tokens")) {
                                        chunk.finish_reason = .length;
                                    } else {
                                        chunk.finish_reason = .stop;
                                    }
                                } else chunk.finish_reason = .stop;
                            } else chunk.finish_reason = .stop;
                        } else chunk.finish_reason = .stop;
                    } else {
                        chunk.finish_reason = .stop;
                    }
                }
            } else {
                chunk.finish_reason = .stop;
            }

            // FIX: The Responses API has NO distinct terminal status for tool
            // calls — `status` stays "completed" even when the model emitted
            // one or more function_call items.
            if (response.object.get("output")) |output_val| {
                if (output_val == .array) {
                    for (output_val.array.items) |item| {
                        if (item != .object) continue;
                        const item_type = item.object.get("type") orelse continue;
                        if (item_type != .string) continue;
                        if (std.mem.eql(u8, item_type.string, "function_call")) {
                            chunk.finish_reason = .tool_calls;
                            break;
                        }
                    }
                }
            }

            // Capture reasoning metadata from terminal output: id,
            // encrypted_content, and summary[] fallback for reasoning_content.
            if (response.object.get("output")) |output_val| {
                if (output_val == .array) {
                    var first_reasoning_id: ?[]const u8 = null;
                    var first_encrypted: ?[]const u8 = null;
                    var summary_buf: std.ArrayList(u8) = .empty;
                    var has_summary = false;
                    for (output_val.array.items) |item| {
                        if (item != .object) continue;
                        const item_type = item.object.get("type") orelse continue;
                        if (item_type != .string) continue;
                        if (!std.mem.eql(u8, item_type.string, "reasoning")) continue;
                        if (first_reasoning_id == null) {
                            if (item.object.get("id")) |id_val| {
                                if (id_val == .string and id_val.string.len > 0) {
                                    first_reasoning_id = id_val.string;
                                }
                            }
                        }
                        if (first_encrypted == null) {
                            if (item.object.get("encrypted_content")) |enc_val| {
                                if (enc_val == .string and enc_val.string.len > 0) {
                                    first_encrypted = enc_val.string;
                                }
                            }
                        }
                        if (item.object.get("summary")) |summary_val| {
                            if (summary_val == .array) {
                                for (summary_val.array.items) |s_item| {
                                    if (s_item != .object) continue;
                                    const text_val = s_item.object.get("text") orelse continue;
                                    if (text_val != .string) continue;
                                    if (text_val.string.len == 0) continue;
                                    if (has_summary) {
                                        summary_buf.appendSlice(arena, "\n") catch continue;
                                    }
                                    summary_buf.appendSlice(arena, text_val.string) catch continue;
                                    has_summary = true;
                                }
                            }
                        }
                    }
                    if (first_reasoning_id) |rid| chunk.reasoning_id = rid;
                    if (first_encrypted) |enc| chunk.reasoning_encrypted_content = enc;
                    if (has_summary and summary_buf.items.len > 0) {
                        chunk.reasoning_content = summary_buf.items;
                    }
                }
            }

            if (response.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    var usage: Usage = .{};
                    if (usage_val.object.get("input_tokens")) |pt| {
                        if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                    } else if (usage_val.object.get("prompt_tokens")) |pt| {
                        if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                    }
                    if (usage_val.object.get("output_tokens")) |ct| {
                        if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                    } else if (usage_val.object.get("completion_tokens")) |ct| {
                        if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                    }
                    if (usage_val.object.get("total_tokens")) |tt| {
                        if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                    } else {
                        usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
                    }
                    // preserve cache fields if relay adds them
                    if (usage_val.object.get("input_tokens_details")) |details| {
                        if (details == .object) {
                            if (details.object.get("cached_tokens")) |ct| {
                                if (ct == .integer) usage.cache_read_input_tokens = @intCast(ct.integer);
                            }
                        }
                    }
                    chunk.usage = usage;
                }
            }
            // If no explicit finish_reason yet but we have usage, default to stop
            if (chunk.finish_reason == null) chunk.finish_reason = .stop;
            return chunk;
        }
        // Ignored lifecycle events: response.created, response.in_progress, response.queued,
        // response.content_part.added/done, response.output_item.done, response.output_text.annotation.*
        return null;
    }
    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
    ) CallError!CallResponse {
        self.log_fmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{
            self.model, params.messages.len, params.tools.len,
        });

        // Claude Code profiles select the local CLI backend, not HTTP.
        if (std.mem.eql(u8, self.backend, "claude-code")) {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "profile uses backend=\"claude-code\" (model=\"{s}\") but CLI execution is not wired yet (Phase 1: configuration only). Install the CLI (https://docs.anthropic.com/en/docs/claude-code) and run `claude login`, or set the profile's backend back to \"http\".",
                .{self.model},
            ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            self.log_fmt(.err, "[STREAM] claude-code backend not wired yet (model={s})", .{self.model});
            return error.ClaudeCodeNotWired;
        }

        // OpenCode profiles select the local CLI backend, not HTTP.
        if (std.mem.eql(u8, self.backend, "opencode")) {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "profile uses backend=\"opencode\" (model=\"{s}\") but CLI execution is not wired yet (Phase 1: configuration only). Install the CLI (https://docs.opencode.dev/) and run `opencode login`, or set the profile's backend back to \"http\".",
                .{self.model},
            ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            self.log_fmt(.err, "[STREAM] opencode backend not wired yet (model={s})", .{self.model});
            return error.OpencodeNotWired;
        }

        // Reset per-call Anthropic parser scratch state. The Agent is reused
        // across many calls; without this reset, the second call would see
        // stale input_tokens + a stuck `_usage_emitted` flag.
        self._anthropic_input_tokens = 0;
        self._anthropic_usage_emitted = false;
        self._anthropic_cache_read_tokens = 0;
        self._anthropic_cache_creation_tokens = 0;

        // 1. Build JSON body — dispatch on UrlStyle.
        var json_body: []u8 = undefined;
        if (std.mem.eql(u8, self.UrlStyle, "openai-response")) {
            json_body = self.buildJsonResponsesRequest(params, true) catch |err| {
                self.log_error("buildJsonResponsesRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else if (std.mem.eql(u8, self.UrlStyle, "openai")) {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            json_body = self.buildJsonAnthropicRequest(params, true) catch |err| {
                self.log_error("buildJsonAnthropicRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        }

        defer self.allocator.free(json_body);

        const estimated_tokens = @divFloor(json_body.len + 3, 4);
        self.log_fmt(.info, "[TOKEN ESTIMATE] sending ~{} tokens ({} bytes)", .{ estimated_tokens, json_body.len });

        const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        const json_ellipsis = if (json_body.len > 500) "..." else "";
        self.log_fmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        // 2. Compose URL: baseUrl + endpoint. Anthropic's correct API path is
        // /v1/messages. const endpoint = if (std.mem.eql(u8, self.UrlStyle,
        // "anthropic")) "/v1/messages" else "/chat/completions";
        const uri_str = std.mem.concat(self.allocator, u8, &.{self.baseUrl}) catch |err| {
            self.log_error("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        // Validate the URL scheme BEFORE handing it to libcurl. libcurl
        // returns CURLE_UNSUPPORTED_PROTOCOL (LocalError.UnsupportedProtocol)
        // for any URL it can't parse a scheme out of — which surfaces to the
        const has_http_scheme = std.mem.startsWith(u8, uri_str, "http://") or
            std.mem.startsWith(u8, uri_str, "https://");
        if (!has_http_scheme) {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "baseUrl+endpoint={s} has no http:// or https:// scheme — check api_key/model/base_url in config",
                .{uri_str},
            ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            self.log_fmt(.err, "[STREAM] unsupported URL scheme (must start with http:// or https://): {s}", .{uri_str});
            return error.InvalidUri;
        }

        // 3. Compose auth headers per UrlStyle. `authHeaders` owns the
        // anthropic-vs-Bearer split and is pinned by tests against the
        // header list it emits, not by a grep of this file.
        var auth_value: ?[]u8 = null;
        defer if (auth_value) |v| self.allocator.free(v);

        // 4. Build the custom_http_client.Request.
        var header_buf: [8]custom_http_client.Header = undefined;
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;
        const auth_count = authHeaders(
            self.allocator,
            self.UrlStyle,
            self.apiKey,
            header_buf[header_count..],
            &auth_value,
        ) catch |err| {
            self.log_error("compose auth headers", err, null);
            return error.OutOfMemory;
        };
        header_count += auth_count;
        header_buf[header_count] = .{ .name = "accept-encoding", .value = "identity" };
        header_count += 1;
        if (self.sessionId.len > 0) {
            header_buf[header_count] = .{ .name = "x-opencode-session", .value = self.sessionId };
            header_count += 1;
        }
        const req = custom_http_client.Request{
            .method = .POST,
            .url = uri_str,
            .headers = header_buf[0..header_count],
            .body = json_body,
        };

        // 5. Build Options. Standard libcurl timeouts — no custom watchdog.
        const options = custom_http_client.Options{
            .timeout_ms = self.httpOptions.read_timeout_ms,
            .connect_timeout_ms = 30_000,
            .follow_redirects = false,
            .verify_ssl = true,
            .user_agent = "pabrik/1.0",
        };

        // 6. Open the streaming request.
        var stream = self.client.openStream(self.io, req, options) catch |err| {
            self.log_fmt(.err, "[STREAM] openStream failed: {s}", .{@errorName(err)});
            return error.HttpRequestFailed;
        };
        defer stream.deinit();

        const status = stream.statusCode();
        self.log_fmt(.info, "[STREAM] Connected with HTTP {d}", .{status});

        if (status >= 400) {
            self.log_fmt(.err, "[STREAM] HTTP error status: {d}", .{status});
            // Drain the error body so the workflow catch block can log the
            // server's actual reason (rate limit, auth, model not found,
            // context length, etc.) instead of just `error.ApiError`.
            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(self.allocator);
            const max_body_len: usize = 4096;
            drain_loop: while (body_buf.items.len < max_body_len) {
                const next_chunk = stream.next() catch break :drain_loop;
                if (next_chunk) |chunk| {
                    const remaining = max_body_len - body_buf.items.len;
                    const to_copy = @min(chunk.len, remaining);
                    body_buf.appendSlice(self.allocator, chunk[0..to_copy]) catch break :drain_loop;
                    if (chunk.len > to_copy) break :drain_loop;
                } else break :drain_loop;
            }
            const truncated = body_buf.items.len >= max_body_len;
            if (body_buf.items.len > 0) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "HTTP {d}: {s}{s}",
                    .{ status, body_buf.items, if (truncated) "..." else "" },
                ) catch null;
                if (msg) |m| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = m;
                }
            }
            return error.ApiError;
        }

        // 7. SSE scanner for line-by-line reads.
        var scanner = custom_http_client.StreamScanner.init(&stream, false);
        defer scanner.deinit();

        // 8. Aggregator.
        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();

        // Raw SSE sample buffer.
        var raw_sse_sample: std.ArrayList(u8) = .empty;
        defer raw_sse_sample.deinit(self.allocator);
        const max_raw_sse_sample_len: usize = 2048;

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;

        // 9. SSE loop.
        var scanner_null_count: u32 = 0;
        while (true) {
            // Cancellation check — the only place a MID-stream stop can be
            // observed.
            if (params.cancel_fn) |should_cancel| {
                if (should_cancel()) {
                    stream.cancel();
                    self.log_fmt(.info, "[STREAM] cancelled by caller after {} chunk(s)", .{chunk_count});
                    return error.Cancelled;
                }
            }
            const next_result = scanner.next() catch |err| {
                // Classify cancellation BEFORE anything else.
                if (err == error.Cancelled) return error.Cancelled;
                if (params.cancel_fn) |should_cancel| {
                    if (should_cancel()) {
                        stream.cancel();
                        return error.Cancelled;
                    }
                }
                self.log_fmt(.err, "[STREAM] scanner.next failed: {s}", .{@errorName(err)});
                // Surface the underlying scanner error name to the workflow
                // catch block so it can tell apart a parse failure from a
                // network drop from an EOF mid-line, instead of all
                const detail: ?[]u8 = if (err == error.UnsupportedProtocol and
                    std.mem.startsWith(u8, uri_str, "https://"))
                    std.fmt.allocPrint(
                        self.allocator,
                        "scanner.next failed after {d} chunk(s): UnsupportedProtocol — vendored libcurl was built --disable-ssl (see kabelweb/scripts/build-vendor-curl.sh); URL must be http:// until OpenSSL is vendored, or change base_url in ~/.config/pabrik/config.json to an http:// endpoint",
                        .{chunk_count},
                    ) catch null
                else
                    std.fmt.allocPrint(
                        self.allocator,
                        "scanner.next failed after {d} chunk(s): {s}",
                        .{ chunk_count, @errorName(err) },
                    ) catch null;
                if (detail) |d| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = d;
                }
                return error.StreamInterrupted;
            };
            if (next_result) |line| {
                scanner_null_count = 0;
                if (self.parse_sse_line(line)) |data| {
                    _ = line_arena.reset(.retain_capacity);
                    if (self.parse_stream_chunk(data, line_arena.allocator())) |chunk| {
                        chunk_count += 1;
                        callback(ctx, chunk);
                        aggregator.process_chunk(chunk) catch {};
                    } else {
                        self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
                        // Capture the raw SSE data line for the final-error
                        // message — only while chunk_count == 0 (i.e. the
                        // server's first lines are still unparsed).
                        if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                            raw_sse_sample.appendSlice(self.allocator, data) catch {};
                            raw_sse_sample.append(self.allocator, '\n') catch {};
                        }
                    }
                } else {
                    // parse_sse_line returned null: this line isn't a `data:
                    // …` payload.
                    if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                        raw_sse_sample.appendSlice(self.allocator, line) catch {};
                        raw_sse_sample.append(self.allocator, '\n') catch {};
                    }
                }
                continue;
            }
            // next() returned null. The worker MIGHT have finished (clean
            // EOF) OR the polling budget might have elapsed (worker still
            // going).
            scanner_null_count += 1;
            if (scanner_null_count >= 2) break;
        }

        // A cancel can also land in the window between the final chunk and
        // the loop exit above.
        if (params.cancel_fn) |should_cancel| {
            if (should_cancel()) {
                stream.cancel();
                return error.Cancelled;
            }
        }

        // 10. The scanner returned null twice in a row, which means
        // the worker has definitively finished (clean EOF) without
        // sending a finish_reason chunk. Treat as a mid-stream death.
        if (aggregator.finish_reason == null) {
            self.log_fmt(.err, "[STREAM] stream ended without finish_reason (chunks={})", .{chunk_count});
            // Tell the workflow catch block HOW the stream died and roughly
            // how far it got, so the user can distinguish "the server cut us
            // off after a few tokens" from "it never started streaming at
            const sample_truncated = raw_sse_sample.items.len >= max_raw_sse_sample_len;
            const sample_for_msg: []const u8 = if (raw_sse_sample.items.len > 0)
                if (sample_truncated)
                    raw_sse_sample.items[0 .. max_raw_sse_sample_len - 3] ++ "..."
                else
                    raw_sse_sample.items
            else
                "";
            const detail: ?[]u8 = if (sample_for_msg.len > 0)
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s); first server lines: {s}{s}",
                    .{
                        chunk_count,
                        sample_for_msg,
                        // Console Go gateway error when `x-opencode-session`
                        // was missing. Point at the fix instead of leaving
                        // the user to decode the raw JSON envelope.
                        if (std.mem.indexOf(u8, sample_for_msg, "MissingSessionID") != null)
                            " [hint: provider requires x-opencode-session header — Agent.sessionId was empty or not sent; see https://opencode.ai/docs/go/#where-can-i-use-it]"
                        else
                            "",
                    },
                ) catch null
            else
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s)",
                    .{chunk_count},
                ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            return error.StreamInterrupted;
        }
        stream_ended_cleanly = true;

        callback(ctx, .{ .done = true });

        // 11. Finalize.
        const stream_response = aggregator.finalize() catch |err| {
            self.log_error("finalize streaming response", err, null);
            return error.AllocFailed;
        };

        // 12. Cost tracking (matches Agent.zig's pricing).
        const prompt_cost = @as(f64, @floatFromInt(stream_response.usage.prompt_tokens)) * 0.000003;
        const completion_cost = @as(f64, @floatFromInt(stream_response.usage.completion_tokens)) * 0.000015;
        const total_cost = prompt_cost + completion_cost;
        self.log_fmt(.info, "[STREAM] Complete - Prompt: {} | Completion: {} | Total: {} | Est. cost: ${d:.4}", .{
            stream_response.usage.prompt_tokens,
            stream_response.usage.completion_tokens,
            stream_response.usage.total_tokens,
            total_cost,
        });

        return stream_response;
    }

    pub fn deinit(self: *Agent) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
            self.last_error_message = null;
        }
        self.client.deinit();
    }
};

test "VideoUrl jsonStringify emits video_url url" {
    const alloc = std.testing.allocator;
    const part = ChatContentPart{ .part_type = "video_url", .video_url = .{ .url = "data:video/mp4;base64,AAAA" } };
    const s = try std.json.Stringify.valueAlloc(alloc, part, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "video_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/mp4;base64,AAAA") != null);
}

test "isSupportedVideoMime allowlists full video set" {
    try std.testing.expect(isSupportedVideoMime("video/mp4"));
    try std.testing.expect(isSupportedVideoMime("video/webm"));
    try std.testing.expect(isSupportedVideoMime("video/quicktime"));
    try std.testing.expect(isSupportedVideoMime("video/x-msvideo"));
    try std.testing.expect(isSupportedVideoMime("video/x-matroska"));
    try std.testing.expect(!isSupportedVideoMime("video/ogg"));
    try std.testing.expect(!isSupportedVideoMime("image/png"));
}

test "videoMimeFromDataUrl extracts mime" {
    const m = videoMimeFromDataUrl("data:video/mp4;base64,AAAA");
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("video/mp4", m.?);
    try std.testing.expect(videoMimeFromDataUrl("data:image/png;base64,AAAA") == null);
    try std.testing.expect(videoMimeFromDataUrl("data:video/mp4,AAAA") == null);
}

test "ResponsesInputContent input_video serializes video_url" {
    const alloc = std.testing.allocator;
    const c = ResponsesInputContent{ .content_type = "input_video", .video_url = "data:video/webm;base64,GkXf" };
    const s = try std.json.Stringify.valueAlloc(alloc, c, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "input_video") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/webm") != null);
}

test "AnthropicContentBlock video serializes type video" {
    const alloc = std.testing.allocator;
    const b = AnthropicContentBlock{ .video = .{ .source_type = "url", .url_or_data = "data:video/mp4;base64,AAAA" } };
    const s = try std.json.Stringify.valueAlloc(alloc, b, .{});
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"video\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "data:video/mp4") != null);
}

// ===== Tests merged from agent_request_user_id_test.zig (2026-09-29 flatten) =====
const testing = std.testing;

/// Hardcoded identifier — the value that every Anthropic + OpenAI call
/// from this fork of pabrik sends. See `Agent.userIdentifier` default.
const HARDCODED_USER_ID = "AnakMagang";

fn makeAgentUserId(user_id: []const u8) Agent {
    var a = Agent.init(testing.allocator, testing.io);
    a.model = "test-model";
    a.userIdentifier = user_id;
    return a;
}

test "Agent default userIdentifier is hardcoded to 'AnakMagang'" {
    var a = Agent.init(testing.allocator, testing.io);
    defer a.deinit();
    try testing.expectEqualStrings("AnakMagang", a.userIdentifier);
}

test "buildJsonOpenAIRequest includes 'user' field when userIdentifier is set" {
    var a = makeAgentUserId(HARDCODED_USER_ID);
    defer a.deinit();

    const params = AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"" ++ HARDCODED_USER_ID ++ "\"") != null);
}

test "buildJsonOpenAIRequest omits 'user' field when userIdentifier is empty" {
    var a = makeAgentUserId("");
    defer a.deinit();

    const params = AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"user\":") == null);
}

test "the command tool's provider payload teaches the service recipe" {
    var a = Agent.init(testing.allocator, testing.io);
    a.model = "test-model";
    defer a.deinit();

    const tools = [_]AgentTool{@import("tools/command.zig").command_tool};
    const body = try a.buildJsonOpenAIRequest(.{ .tools = &tools, .messages = &.{} }, false);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "background_persistence") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Never detach by hand") != null);
    try testing.expect(std.mem.indexOf(u8, body, "ONE `foreground` call per thing") != null);
    for ([_][]const u8{ "`&`", "`nohup`", "`setsid`", "`Start-Process`", "`-RedirectStandardOutput`" }) |idiom| {
        if (std.mem.indexOf(u8, body, idiom) == null) {
            std.debug.print("\n!! {s} is no longer forbidden in what the model receives\n", .{idiom});
            return error.HandRolledDetachAllowed;
        }
    }
    try testing.expect(std.mem.indexOf(u8, body, "system_prompt") == null);
}

test "buildJsonAnthropicRequest includes metadata.user_id when userIdentifier is set" {
    var a = makeAgentUserId(HARDCODED_USER_ID);
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"user_id\":\"" ++ HARDCODED_USER_ID ++ "\"}") != null);
}

test "buildJsonAnthropicRequest omits metadata entirely when userIdentifier is empty" {
    var a = makeAgentUserId("");
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\"") == null);
}

// ===== Tests merged from anthropic_adaptive_test.zig (2026-09-29 flatten)
// ===== Tests for the new Anthropic `thinking_budget_tokens` override +
// `type: "adaptive"` mode in `buildJsonAnthropicRequest`.

const AnthropicAdaptiveMakeOpts = struct {
    thinkingEnabled: bool = true,
    thinkingBudgetTokens: ?u32 = null,
    thinkingAdaptive: bool = false,
    maxTokens: usize = 16384,
};

fn makeAgentAnthropicAdaptive(opts: AnthropicAdaptiveMakeOpts) Agent {
    var a = Agent.init(testing.allocator, std.testing.io);
    a.apiKey = "test-key";
    a.model = "claude-sonnet-4-5";
    a.baseUrl = "https://api.minimax.io/anthropic";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.thinkingBudgetTokens = opts.thinkingBudgetTokens;
    a.thinkingAdaptive = opts.thinkingAdaptive;
    a.maxTokens = opts.maxTokens;
    a.temperature = 1.0;
    return a;
}

fn messagesListAnthropicAdaptive() []const AgentMessage {
    return &.{
        .{
            .role = .user,
            .content = "hi",
        },
    };
}

fn emptyToolsAnthropicAdaptive() []const AgentTool {
    return &.{};
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens honored as exact budget" {
    // 16384 / 2 = 8192 (the heuristic). User wants 2048.
    // With override, the request body MUST carry budget_tokens=2048
    // and MUST emit type:enabled (not adaptive).
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = 2048 });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2048") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens below floor clamps to 1024" {
    // max_tokens=8192, override=512 (below the 1024 floor).
    // Anthropic requires budget_tokens >= 1024, so we MUST clamp.
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = 512, .maxTokens = 8192 });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 8192,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":1024") != null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens above ceiling clamps to max_tokens - 1" {
    // max_tokens=2048, override=4096 (way above max_tokens).
    // Anthropic requires budget_tokens < max_tokens strictly, so
    // we MUST clamp to 2047.
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = 4096, .maxTokens = 2048 });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 2048,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":2047") != null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=null + thinkingAdaptive=true emits type:adaptive" {
    // User picked "auto" in the UI → workflow sets thinkingAdaptive=true and
    // leaves thinkingBudgetTokens=null.
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = null, .thinkingAdaptive = true });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "budget_tokens") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens=null + thinkingAdaptive=false falls back to 50% heuristic" {
    // User picked "on" in the UI → workflow sets thinkingAdaptive=false.
    // The request body MUST emit type:enabled with budget_tokens =
    // half of max_tokens (the existing 50%-of-max heuristic).
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = null, .thinkingAdaptive = false, .maxTokens = 8192 });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 8192,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    // 8192 / 2 = 4096 — the heuristic value.
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":4096") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=false omits thinking entirely (override is ignored)" {
    // thinkingEnabled is the master gate — even with
    // thinkingBudgetTokens set, the entire `thinking` block is
    // omitted from the request body.
    var a = makeAgentAnthropicAdaptive(.{ .thinkingEnabled = false, .thinkingBudgetTokens = 4096 });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "budget_tokens") == null);
}

test "buildJsonAnthropicRequest: thinkingBudgetTokens wins over thinkingAdaptive (precedence)" {
    // When both are set (which shouldn't happen in production but
    // could via a misconfigured profile), the explicit budget
    // wins. The adaptive flag is only consulted when budget is null.
    var a = makeAgentAnthropicAdaptive(.{ .thinkingBudgetTokens = 3000, .thinkingAdaptive = true });
    defer a.deinit();

    const params = AgentCall{
        .tools = emptyToolsAnthropicAdaptive(),
        .messages = messagesListAnthropicAdaptive(),
        .max_tokens = 16384,
    };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":3000") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"adaptive\"") == null);
}

// ===== Tests merged from anthropic_request_test.zig (2026-09-29 flatten)
// ===== Regression tests for the Anthropic request-builder bugs documented in
// `docs/superpowers/plans/<anthropic-request-fixes>.md`.

fn makeAgentAnthropicRequest(opts: struct {
    model: []const u8 = "claude-test",
    thinkingEnabled: bool = true,
    maxTokens: usize = 4096,
}) Agent {
    var a = Agent.init(testing.allocator, testing.io);
    a.model = opts.model;
    a.thinkingEnabled = opts.thinkingEnabled;
    a.maxTokens = opts.maxTokens;
    a.UrlStyle = "anthropic";
    return a;
}

fn userMsgAnthropicRequest(text: []const u8) AgentMessage {
    return .{
        .role = .user,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

fn sysMsgAnthropicRequest(text: []const u8) AgentMessage {
    return .{
        .role = .system,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

// Build and return the body. Caller frees with `freeAnthropicBody`.
fn buildAnthropicBodyRawAnthropicRequest(
    a: *Agent,
    messages: []const AgentMessage,
    temperature: ?f32,
    max_tokens: ?usize,
) ![]u8 {
    const params = AgentCall{
        .tools = &.{},
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
    };
    return try a.buildJsonAnthropicRequest(params, true);
}

const ParsedBodyAnthropicRequest = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
};

fn buildAndParseAnthropicRequest(
    a: *Agent,
    messages: []const AgentMessage,
    temperature: ?f32,
    max_tokens: ?usize,
) !ParsedBodyAnthropicRequest {
    const raw = try buildAnthropicBodyRawAnthropicRequest(a, messages, temperature, max_tokens);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    return .{ .raw = raw, .parsed = parsed };
}

fn freeBodyAnthropicRequest(body: ParsedBodyAnthropicRequest) void {
    testing.allocator.free(body.raw);
    body.parsed.deinit();
}

// ============================================================================
// Bug 1 — system messages go to top-level "system" field
// ============================================================================

test "buildJsonAnthropicRequest: system message moves to top-level 'system' field, not into messages" {
    var a = makeAgentAnthropicRequest(.{});
    defer a.deinit();

    const messages = [_]AgentMessage{
        sysMsgAnthropicRequest("You are a helpful assistant."),
        userMsgAnthropicRequest("Hello."),
    };

    var body = try buildAndParseAnthropicRequest(&a, &messages, null, null);
    defer freeBodyAnthropicRequest(body);

    // Top-level "system" string must match the system message content.
    try testing.expect(body.parsed.value.object.get("system") != null);
    const system_str = body.parsed.value.object.get("system").?;
    try testing.expect(system_str == .string);
    try testing.expectEqualStrings("You are a helpful assistant.", system_str.string);

    // No message inside `messages` should have role == "system" — the
    // only message remaining should be the user one.
    try testing.expect(body.parsed.value.object.get("messages") != null);
    const messages_arr = body.parsed.value.object.get("messages").?;
    try testing.expect(messages_arr == .array);
    try testing.expectEqual(@as(usize, 1), messages_arr.array.items.len);
    const only_msg = messages_arr.array.items[0];
    try testing.expect(only_msg.object.get("role") != null);
    try testing.expectEqualStrings("user", only_msg.object.get("role").?.string);
}

test "buildJsonAnthropicRequest: multiple system messages are joined with '\\n\\n' into top-level 'system'" {
    var a = makeAgentAnthropicRequest(.{});
    defer a.deinit();

    const messages = [_]AgentMessage{
        sysMsgAnthropicRequest("First part."),
        sysMsgAnthropicRequest("Second part."),
        userMsgAnthropicRequest("Hi."),
    };

    var body = try buildAndParseAnthropicRequest(&a, &messages, null, null);
    defer freeBodyAnthropicRequest(body);

    try testing.expect(body.parsed.value.object.get("system") != null);
    const system_str = body.parsed.value.object.get("system").?;
    try testing.expect(system_str == .string);
    try testing.expectEqualStrings("First part.\n\nSecond part.", system_str.string);

    const messages_arr = body.parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 1), messages_arr.array.items.len);
}

test "buildJsonAnthropicRequest: no system message → top-level 'system' field absent" {
    var a = makeAgentAnthropicRequest(.{});
    defer a.deinit();

    const messages = [_]AgentMessage{
        userMsgAnthropicRequest("Hello."),
    };

    var body = try buildAndParseAnthropicRequest(&a, &messages, null, null);
    defer freeBodyAnthropicRequest(body);

    // Top-level "system" field must be omitted entirely (not null, not
    // empty string — Anthropic only has a system prompt when we send
    // one).
    try testing.expect(body.parsed.value.object.get("system") == null);
}

// ============================================================================
// Bug 2 — thinking.enabled must include budget_tokens
// ============================================================================

test "buildJsonAnthropicRequest: thinkingEnabled emits budget_tokens (>=1024 and <max_tokens)" {
    // Default Agent.maxTokens is 4096 → budget should be min(2048, 4095) = 2048.
    var a = makeAgentAnthropicRequest(.{ .maxTokens = 4096 });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    // Substring match on raw body — robust to JSON key order + whitespace.
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":") != null);
    // Also check the value is exactly 2048 (50% of 4096 with the >=
    // 1024 floor satisfied and < max_tokens satisfied trivially).
    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":2048") != null);
}

test "buildJsonAnthropicRequest: budget_tokens is clamped to max_tokens-1 when max_tokens is small" {
    // maxTokens=1500 → budget floor of 1024 wins, must be < 1500 → budget=1024.
    var a = makeAgentAnthropicRequest(.{ .maxTokens = 1500 });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"budget_tokens\":1024") != null);
}

test "buildJsonAnthropicRequest: thinkingEnabled=false omits thinking field entirely" {
    var a = makeAgentAnthropicRequest(.{ .thinkingEnabled = false });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
}

// ============================================================================
// Bug 2 — small-max_tokens guard
// ============================================================================

test "buildJsonAnthropicRequest: thinkingEnabled=true with max_tokens<1025 forces thinking off (no budget that violates the floor)" {
    // max_tokens=1024 → can't be thinking-enabled: floor would be 1024,
    // but must be < max_tokens. Expect thinking omitted from output.
    var a = makeAgentAnthropicRequest(.{ .maxTokens = 1024 });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, null, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
}

// ============================================================================
// Bug 3 — temperature must not be sent alongside thinking.enabled
// ============================================================================

test "buildJsonAnthropicRequest: temperature is omitted when thinkingEnabled=true (even if caller set it)" {
    var a = makeAgentAnthropicRequest(.{ .thinkingEnabled = true });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, 0.7, null);
    defer testing.allocator.free(raw);

    // thinking is ON...
    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\":") != null);
    // ...and temperature is NOT sent.
    try testing.expect(std.mem.indexOf(u8, raw, "\"temperature\"") == null);
}

test "buildJsonAnthropicRequest: temperature is emitted when thinkingEnabled=false" {
    var a = makeAgentAnthropicRequest(.{ .thinkingEnabled = false });
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const raw = try buildAnthropicBodyRawAnthropicRequest(&a, &messages, 0.7, null);
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"thinking\"") == null);
    // `temperature` is emitted.
    const temp_present = std.mem.indexOf(u8, raw, "\"temperature\":") != null;
    try testing.expect(temp_present);
    const temp_value_ok =
        std.mem.indexOf(u8, raw, "\"temperature\":0.699999988079071") != null or
        std.mem.indexOf(u8, raw, "\"temperature\":0.7") != null;
    try testing.expect(temp_value_ok);
}

// ============================================================================
// Bug 4 — Anthropic doesn't accept stream_options
// ============================================================================

test "buildJsonAnthropicRequest: stream=true emits 'stream':true and does NOT emit 'stream_options'" {
    var a = makeAgentAnthropicRequest(.{});
    defer a.deinit();

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    // stream=true (third arg is bool `stream`).
    const raw = try a.buildJsonAnthropicRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = null, .max_tokens = null },
        true,
    );
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"stream_options\"") == null);
}

// ============================================================================
// Regression: OpenAI path is unaffected
// ============================================================================

test "regression: buildJsonOpenAIRequest keeps 'stream_options.include_usage' verbatim" {
    var a = makeAgentAnthropicRequest(.{});
    defer a.deinit();
    // Ensure anthropic is NOT selected.
    a.UrlStyle = "openai";

    const messages = [_]AgentMessage{userMsgAnthropicRequest("hi")};
    const body = try a.buildJsonOpenAIRequest(
        .{ .tools = &.{}, .messages = &messages, .temperature = 0.5, .max_tokens = null },
        true,
    );
    defer testing.allocator.free(body);

    // OpenAI keeps stream_options.include_usage=true.
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

// ============================================================================
// Regression: callStreaming auth headers per UrlStyle
// ============================================================================

test "callStreaming: anthropic style sends x-api-key + anthropic-version (not only Bearer)" {
    // Regression for `AuthError: Missing API key` on anthropic-style chat
    // (e.g. opencode.ai/zen/go/v1/messages): callStreaming sent only
    // `Authorization: Bearer`, which Anthropic-style upstreams ignore.
    var buf: [4]custom_http_client.Header = undefined;
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| testing.allocator.free(v);

    const n = try authHeaders(testing.allocator, "anthropic", "sk-anthropic-key", buf[0..], &auth_value);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("anthropic-version", buf[0].name);
    try testing.expectEqualStrings("2023-06-01", buf[0].value);
    try testing.expectEqualStrings("x-api-key", buf[1].name);
    try testing.expectEqualStrings("sk-anthropic-key", buf[1].value);
    // No Bearer alongside it — the anthropic arm allocates nothing.
    try testing.expect(auth_value == null);
}

test "callStreaming: a non-anthropic style keeps authorization: Bearer and drops the anthropic pair" {
    var buf: [4]custom_http_client.Header = undefined;
    var bearer: ?[]u8 = null;
    defer if (bearer) |v| testing.allocator.free(v);

    const n = try authHeaders(testing.allocator, "openai", "sk-openai-key", buf[0..], &bearer);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("authorization", buf[0].name);
    try testing.expectEqualStrings("Bearer sk-openai-key", buf[0].value);
}

test "callStreaming: an anthropic request with no key omits x-api-key but keeps the version" {
    var buf: [4]custom_http_client.Header = undefined;
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| testing.allocator.free(v);

    const n = try authHeaders(testing.allocator, "anthropic", "", buf[0..], &auth_value);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("anthropic-version", buf[0].name);
    try testing.expectEqualStrings("2023-06-01", buf[0].value);
    try testing.expect(auth_value == null);
}

// ===== Tests merged from call_streaming_test.zig (2026-09-29 flatten) =====
// Regression tests for `Agent.callStreaming` deadline / error-propagation
// behavior.

const posix = std.posix;
const linux = std.posix.system;
const builtin = @import("builtin");

// Platform socket constants. Mirrors http_server.zig to keep this test
// self-contained (no cross-module dependency).
const AF_INET = if (builtin.os.tag == .windows) @as(u32, 2) else posix.AF.INET;
const SOCK_STREAM = if (builtin.os.tag == .windows) @as(u32, 1) else posix.SOCK.STREAM;
const IPPROTO_TCP = if (builtin.os.tag == .windows) @as(u32, 6) else posix.IPPROTO.TCP;
const SOL_SOCKET: i32 = if (builtin.os.tag == .windows) 0xffff else 1;
const SO_REUSEADDR: u32 = if (builtin.os.tag == .windows) 4 else 2;

const expectCallStreaming = std.testing.expect;
const expectEqualCallStreaming = std.testing.expectEqual;
const expectErrorCallStreaming = std.testing.expectError;
const expectEqualStringsCallStreaming = std.testing.expectEqualStrings;
const testing_allocatorCallStreaming = std.testing.allocator;

// ============================================================================
// Structural tests — pin the new error variants and HttpOptions field so the
// fix can't be silently removed by a future refactor.

test "CallError has the four new streaming variants" {
    // Compile-time + runtime check: each new error must be assignable to CallError.
    const a: Agent.CallError = error.StreamTimeout;
    const b: Agent.CallError = error.StreamIdleTimeout;
    const c: Agent.CallError = error.StreamInterrupted;
    const d: Agent.CallError = error.StreamEmpty;
    // Use them so the compiler doesn't optimize the assignments away.
    try expectCallStreaming(a != b);
    try expectCallStreaming(b != c);
    try expectCallStreaming(c != d);
    try expectCallStreaming(a != d);
    try expectEqualStringsCallStreaming("StreamTimeout", @errorName(a));
    try expectEqualStringsCallStreaming("StreamIdleTimeout", @errorName(b));
    try expectEqualStringsCallStreaming("StreamInterrupted", @errorName(c));
    try expectEqualStringsCallStreaming("StreamEmpty", @errorName(d));
}

// Pinned 2026-06-28 when idle_timeout_ms was raised from 60_000 to 180_000 to
// support reasoning models.
test "HttpOptions.idle_timeout_ms default stays above TCP keepalive window" {
    const defaults = HttpOptions{};
    try expectCallStreaming(defaults.idle_timeout_ms >= 30_000);
    // Also pin the actual current value so a future bump (or accidental
    // revert to 60_000) shows up as a clear test failure, not a silent
    // behavioral change.
    try expectEqualCallStreaming(@as(u32, 180_000), defaults.idle_timeout_ms);
}

test "callStreaming with claude-code backend fails fast with actionable error" {
    var a = Agent.init(testing_allocatorCallStreaming, std.testing.io);
    defer a.deinit();
    a.baseUrl = "";
    a.model = "sonnet";
    a.apiKey = "";
    a.backend = "claude-code";
    const result = a.callStreaming(makeCall(), null, noopCallback);
    try expectErrorCallStreaming(error.ClaudeCodeNotWired, result);
    const detail = a.last_error_message orelse return error.MissingDetail;
    try expectCallStreaming(std.mem.indexOf(u8, detail, "claude-code") != null);
    try expectCallStreaming(std.mem.indexOf(u8, detail, "claude login") != null);
}

test "callStreaming with opencode backend fails fast with actionable error" {
    var a = Agent.init(testing_allocatorCallStreaming, std.testing.io);
    defer a.deinit();
    a.baseUrl = "";
    a.model = "deepseek-flash";
    a.apiKey = "";
    a.backend = "opencode";
    const result = a.callStreaming(makeCall(), null, noopCallback);
    try expectErrorCallStreaming(error.OpencodeNotWired, result);
    const detail = a.last_error_message orelse return error.MissingDetail;
    try expectCallStreaming(std.mem.indexOf(u8, detail, "opencode") != null);
    try expectCallStreaming(std.mem.indexOf(u8, detail, "opencode login") != null);
}

test "callStreaming ignores a claude-code UrlStyle when backend is http" {
    // The discriminator is `backend`, NOT `UrlStyle`.
    var a = Agent.init(testing_allocatorCallStreaming, std.testing.io);
    defer a.deinit();
    a.baseUrl = "";
    a.model = "sonnet";
    a.apiKey = "k";
    a.UrlStyle = "claude-code";
    const result = a.callStreaming(makeCall(), null, noopCallback);
    // Empty base_url has no scheme → the HTTP path's InvalidUri, not the
    // CLI guard.
    try expectErrorCallStreaming(error.InvalidUri, result);
}

// A PORTABLE fake HTTP server (std.Io.net, so it runs on Windows too): the
// streaming tests point the agent at it, and its behaviours cover the three
// ways a server can leave a stream for dead.

/// How the fixture answers a connection. Every behaviour either finishes its
/// response or holds the socket open until the test stops the fixture.
const ServerBehavior = enum {
    /// Send the HTTP head, then hold the socket open with no body at all.
    head_only_then_stall,
    /// Send the head plus one valid SSE chunk, then hold it open.
    one_chunk_then_stall,
    /// Send the head, then close at once (FIN with no body byte).
    head_then_close,
    /// Send a complete chunked SSE body that ends in a finish_reason, then hold
    /// the socket open. The one behaviour `callStreaming` can SUCCEED against.
    complete_chunked_response,
};

/// A one-listener HTTP fixture on every host. It replaced one that drove
/// `std.os.linux` raw sockets — Linux-only, and it closed fds behind std.Io's
/// back, which hung `std.Io.Threaded.closeFd` on teardown.
const FakeServer = struct {
    allocator: std.mem.Allocator,
    listener: std.Io.net.Server,
    port: u16,
    behavior: ServerBehavior,
    stop: std.atomic.Value(bool),
    /// Set by the worker once a connection has been accepted, so a test can
    /// avoid racing the accept loop's first scheduling.
    connection_seen: std.atomic.Value(bool),
    thread: std.Thread,

    fn start(allocator: std.mem.Allocator, behavior: ServerBehavior) !*FakeServer {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = address.listen(io, .{}) catch return error.BindFailed;

        const self = try allocator.create(FakeServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listener = listener,
            // Port 0 above asked the OS to pick; the resolved value only lands
            // in the socket AFTER listen() runs.
            .port = listener.socket.address.getPort(),
            .behavior = behavior,
            .stop = std.atomic.Value(bool).init(false),
            .connection_seen = std.atomic.Value(bool).init(false),
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// Stop the worker, close the listener, free the fixture. Safe while the
    /// worker is parked in accept OR holding a stalled connection open.
    fn deinit(self: *FakeServer) void {
        const io = std.testing.io;
        self.stop.store(true, .release);
        wakeAccept(self.port);
        self.thread.join();
        self.listener.deinit(io);
        self.allocator.destroy(self);
    }

    /// Block until the worker has accepted a connection, or 5s elapses.
    fn waitForConnection(self: *FakeServer) void {
        const start_ms = nowMs();
        while (!self.connection_seen.load(.acquire)) {
            if (nowMs() - start_ms > 5_000) return; // best-effort
            std.Io.sleep(std.testing.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real) catch return;
        }
    }
};

/// One throwaway connection, opened only to unpark a worker sitting in
/// `accept`. A failure means the worker was not parked after all, so the error
/// is deliberately ignored.
fn wakeAccept(port: u16) void {
    const io = std.testing.io;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds, std.time.ns_per_ms));
}

const sse_head =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";
const sse_delta_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n";
const sse_finish_chunk = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n";

/// Worker: accept, answer per `behavior`, repeat until `stop` is published, so
/// the leak tests can drive several calls against ONE port. A stall behaviour
/// holds its socket, so only `head_then_close` serves call after call.
fn serve(self: *FakeServer) void {
    const io = std.testing.io;
    while (true) {
        const conn = self.listener.accept(io) catch return;
        if (self.stop.load(.acquire)) {
            // The wake connection `deinit` opened: nothing to answer.
            conn.close(io);
            return;
        }
        self.connection_seen.store(true, .release);
        serveConnection(io, conn, self.behavior, &self.stop) catch {};
        conn.close(io);
    }
}

fn serveConnection(
    io: std.Io,
    conn: std.Io.net.Stream,
    behavior: ServerBehavior,
    stop: *std.atomic.Value(bool),
) !void {
    var writer = conn.writer(io, &.{});
    try writer.interface.writeAll(sse_head);
    switch (behavior) {
        .one_chunk_then_stall => try writeSseChunk(&writer.interface, sse_delta_chunk),
        .complete_chunked_response => {
            try writeSseChunk(&writer.interface, sse_delta_chunk);
            try writeSseChunk(&writer.interface, sse_finish_chunk);
            // The zero-length chunk ends the body: a complete SSE response,
            // which the client may finish without ever seeing a FIN.
            try writer.interface.writeAll("0\r\n\r\n");
        },
        .head_only_then_stall, .head_then_close => {},
    }
    try writer.interface.flush();

    // Hold the socket open instead of closing it: a FIN raced against the
    // head is what a stall looks like, and for the complete response the
    // chunked terminator is already the end of the body.
    switch (behavior) {
        .head_then_close => {},
        .head_only_then_stall, .one_chunk_then_stall, .complete_chunked_response => sleepUntilStop(stop, 60_000),
    }
}

/// One `Transfer-Encoding: chunked` frame: hex length, body, CRLF.
fn writeSseChunk(w: *std.Io.Writer, body: []const u8) !void {
    try w.print("{x}\r\n", .{body.len});
    try w.writeAll(body);
    try w.writeAll("\r\n");
}
fn sleepUntilStop(stop: *std.atomic.Value(bool), max_ms: u64) void {
    const start_ms = nowMs();
    while (!stop.load(.acquire)) {
        if (nowMs() - start_ms > @as(i64, @intCast(max_ms))) return;
        std.Io.sleep(std.testing.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .real) catch return;
    }
}

fn noopCallback(_: ?*anyopaque, _: StreamChunk) void {}

/// Build a minimal AgentCall. Allocates nothing — content is a static string.
fn makeCall() AgentCall {
    return .{
        .tools = &.{},
        .messages = &.{
            .{ .role = .user, .content = "hello" },
        },
    };
}

/// Build a base URL like "http://127.0.0.1:NNNNN" pointing at the fake server.
fn makeBaseUrl(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
}

/// Counting callback: how many stream chunks reached the caller, so a test can
/// tell "the server never sent a body" from "it sent one and then died".
const ChunkCounter = struct {
    seen: usize = 0,

    fn callback(ctx: ?*anyopaque, _: StreamChunk) void {
        const self: *ChunkCounter = @ptrCast(@alignCast(ctx orelse return));
        self.seen += 1;
    }
};

/// Run callStreaming against a fake server with custom timeouts; returns the
/// outcome and the elapsed wall-clock ms. The agent runs on an arena because
/// `callStreaming` is arena-scoped, so the helper only serves FAILING calls.
fn runStreamingWithTimeout(
    port: u16,
    idle_timeout_ms: u32,
    read_timeout_ms: u32,
    chunks: *ChunkCounter,
) !struct {
    result: anyerror!CallResponse,
    elapsed_ms: i64,
} {
    var arena = std.heap.ArenaAllocator.init(testing_allocatorCallStreaming);
    defer arena.deinit();
    const alloc = arena.allocator();

    var a = Agent.init_with_options(alloc, std.testing.io, .{
        .idle_timeout_ms = idle_timeout_ms,
        .read_timeout_ms = read_timeout_ms,
    });
    defer a.deinit();

    a.baseUrl = try makeBaseUrl(alloc, port);
    a.model = "test-model";
    a.apiKey = "test-key";

    const start_ms = nowMs();
    const result = a.callStreaming(makeCall(), chunks, ChunkCounter.callback);
    const elapsed_ms = nowMs() - start_ms;
    return .{ .result = result, .elapsed_ms = elapsed_ms };
}

// These tests assert error.StreamInterrupted, not StreamIdleTimeout: the
// transport exposes only CURLOPT_TIMEOUT_MS (fed from read_timeout_ms) and
// StreamIdleTimeout has no producer left anywhere in the tree.

test "callStreaming bounds a server that stalls after the head by read_timeout_ms" {
    const server = try FakeServer.start(testing_allocatorCallStreaming, .head_only_then_stall);
    defer server.deinit();
    server.waitForConnection();

    var chunks = ChunkCounter{};
    const idle_ms: u32 = 500;
    const read_ms: u32 = 3_000;
    const outcome = try runStreamingWithTimeout(server.port, idle_ms, read_ms, &chunks);

    // Head only, so the body never delivered a single chunk to the callback.
    try expectEqualCallStreaming(0, chunks.seen);
    // The call ended at its configured stream deadline, within one poll cycle
    // of slack — a hang would never reach the next line.
    try expectCallStreaming(outcome.elapsed_ms >= @as(i64, @intCast(idle_ms)) - 50);
    try expectCallStreaming(outcome.elapsed_ms <= @as(i64, @intCast(read_ms)) + 2_500);
    try expectErrorCallStreaming(error.StreamInterrupted, outcome.result);
}

test "callStreaming bounds a server that stalls after one chunk by read_timeout_ms" {
    const server = try FakeServer.start(testing_allocatorCallStreaming, .one_chunk_then_stall);
    defer server.deinit();
    server.waitForConnection();

    var chunks = ChunkCounter{};
    const idle_ms: u32 = 50;
    const read_ms: u32 = 2_000;
    const outcome = try runStreamingWithTimeout(server.port, idle_ms, read_ms, &chunks);

    // The delta chunk DID arrive and reach the caller before the stall — which
    // is what separates this case from the head-only one above.
    try expectEqualCallStreaming(1, chunks.seen);
    try expectCallStreaming(outcome.elapsed_ms >= @as(i64, @intCast(idle_ms)) - 50);
    try expectCallStreaming(outcome.elapsed_ms <= @as(i64, @intCast(read_ms)) + 2_500);
    try expectErrorCallStreaming(error.StreamInterrupted, outcome.result);
}

test "callStreaming bounds a silent server by read_timeout_ms, not by the idle window" {
    // idle_timeout_ms sits far below read_timeout_ms: the call must still be
    // bounded by the READ deadline. What this rejects is a stream outliving
    // its deadline, or returning anything but a retryable stream error.
    const server = try FakeServer.start(testing_allocatorCallStreaming, .head_only_then_stall);
    defer server.deinit();
    server.waitForConnection();

    var chunks = ChunkCounter{};
    const idle_ms: u32 = 50;
    const read_ms: u32 = 1_500;
    const outcome = try runStreamingWithTimeout(server.port, idle_ms, read_ms, &chunks);

    try expectEqualCallStreaming(0, chunks.seen);
    try expectCallStreaming(outcome.elapsed_ms <= @as(i64, @intCast(read_ms)) + 2_500);
    try expectErrorCallStreaming(error.StreamInterrupted, outcome.result);
}
/// Portable fixture for the cancellation test: a listener that accepts ONE
/// connection, answers with an HTTP/1.1 SSE head plus a single `data:` chunk,
/// then holds the connection open without sending anything else.
const StallServer = struct {
    allocator: std.mem.Allocator,
    listener: std.Io.net.Server,
    thread: std.Thread,
    port: u16,
    stop: std.atomic.Value(bool),

    fn start(allocator: std.mem.Allocator) !*StallServer {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = address.listen(io, .{}) catch return error.AddressInUse;

        const self = try allocator.create(StallServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listener = listener,
            // Port 0 above means "OS picks"; the resolved value only lands in
            // the socket AFTER listen() runs.
            .port = listener.socket.address.getPort(),
            .thread = undefined,
            .stop = std.atomic.Value(bool).init(false),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *StallServer) void {
        const io = std.testing.io;
        // One-shot: the test opens exactly one connection.
        const conn = self.listener.accept(io) catch return;
        defer conn.socket.close(io);

        const head =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n" ++
            "\r\n";
        const body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n";
        var framed_buf: [160]u8 = undefined;
        const framed = std.fmt.bufPrint(&framed_buf, "{x}\r\n{s}\r\n", .{ body.len, body }) catch return;

        // Written BEFORE the client can cancel, so this never races a closed
        // peer (no SIGPIPE on POSIX).
        var writer = conn.writer(io, &.{});
        writer.interface.writeAll(head) catch return;
        writer.interface.writeAll(framed) catch return;
        writer.interface.flush() catch return;

        // Hold the connection open with no further bytes — exactly the state a
        // user is in when they press Stop mid-stream.
        while (!self.stop.load(.acquire)) {
            std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .real) catch return;
        }
    }

    fn deinit(self: *StallServer) void {
        const io = std.testing.io;
        self.stop.store(true, .release);
        self.thread.join();
        self.listener.deinit(io);
        self.allocator.destroy(self);
    }
};

test "callStreaming reports a mid-stream cancel as error.Cancelled, never as a retryable error" {
    // The workflow treats EVERY non-Cancelled error as a transient failure:
    // it increments retry_count, saves a retry diagnostic to history, sleeps,
    // and re-issues the request (workflow.zig, the callDynamicAgentNew
    var server = try StallServer.start(testing_allocatorCallStreaming);
    defer server.deinit();

    // `callStreaming` is arena-scoped BY CONTRACT:
    // `StreamingAggregator.deinit` is a documented no-op because production
    // hands it the per-iteration arena (see `workflow.zig`'s loop), so its
    var arena = std.heap.ArenaAllocator.init(testing_allocatorCallStreaming);
    defer arena.deinit();
    const alloc = arena.allocator();

    const CancelState = struct {
        var polls: u32 = 0;
        fn should() bool {
            polls += 1;
            return polls > 1;
        }
    };
    CancelState.polls = 0;

    var a = Agent.init_with_options(alloc, std.testing.io, .{
        // Large, so a correct implementation cannot be "saved" by the idle
        // watchdog firing first.
        .idle_timeout_ms = 60_000,
        // Small: after the cancel the deferred `stream.deinit()` join still
        // waits for the parked worker (no bytes are arriving — see the
        // kabelweb `openStream` comment on XFERINFOFUNCTION), and this bounds
        .read_timeout_ms = 1_500,
    });
    defer a.deinit();

    const base_url = try makeBaseUrl(alloc, server.port);
    a.baseUrl = base_url;
    a.model = "test-model";
    a.apiKey = "test-key";

    var call = makeCall();
    call.cancel_fn = &CancelState.should;

    const start_ms = nowMs();
    const result = a.callStreaming(call, null, noopCallback);
    const elapsed_ms = nowMs() - start_ms;

    // The transport error from the aborted request must not leak out.
    try expectErrorCallStreaming(error.Cancelled, result);
    // Bounded by read_timeout_ms, not by the 60s idle window.
    try expectCallStreaming(elapsed_ms < 10_000);
    // The thunk must actually have been consulted — guards against a
    // `cancel_fn` that is silently never called.
    try expectCallStreaming(CancelState.polls >= 2);
}

// FD-leak regression tests. `countPipes` is the Linux metric; the host table
// `helpers.open_descriptors.count()` counts the same thing on Windows (open
// HANDLES), so these tests assert on every host.

/// Count anonymous pipes currently open in the test process via /proc/self/fd.
/// Returns 0 on non-Linux (the leak is Linux-only) and on any proc access error.
fn countPipes() usize {
    if (builtin.os.tag != .linux) return 0;

    // Open /proc/self/fd with posix.openat AT_FDCWD path.
    const dir = std.c.opendir("/proc/self/fd") orelse return 0;
    defer _ = std.c.closedir(dir);

    var pipes: usize = 0;
    var buf: [4096]u8 = undefined; // scratch buffer for std.c.readlink target
    while (std.c.readdir(dir)) |raw_entry| {
        const entry: *std.c.dirent = @ptrCast(raw_entry);
        // On Linux, `name` is a fixed-size [256]u8 array terminated by NUL.
        const name_slice = entry.name[0..];
        const name_len = std.mem.indexOfScalar(u8, name_slice, 0) orelse name_slice.len;
        const name = name_slice[0..name_len];

        // Skip "." and ".."
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        // Build "/proc/self/fd/N" path
        var link_path: [64]u8 = undefined;
        const link_path_z = std.fmt.bufPrintZ(&link_path, "/proc/self/fd/{s}", .{name}) catch continue;

        // Readlink to find the FD's type
        const target_len_signed = std.c.readlink(link_path_z, &buf, buf.len);
        if (target_len_signed > 0) {
            const target = buf[0..@intCast(target_len_signed)];
            // Anonymous pipes show as "pipe:[N]" in /proc. AF_UNIX sockets
            // show as "socket:[N]" — we only count pipes here.
            if (target.len >= 5 and std.mem.eql(u8, target[0..5], "pipe:")) {
                pipes += 1;
            }
        }
    }
    return pipes;
}
/// Linux-only sanity input: a runner holding most of its 1024 soft FD limit
/// must not have its absolute pipe count read as a leak signal. The assertions
/// below are baseline-independent, so this reports instead of skipping.
fn reportCrowdedPipeTable(baseline_pipes: usize) void {
    if (baseline_pipes > 800) {
        std.debug.print(
            "  note: /proc already reports {} open pipes (soft limit 1024); " ++
                "measuring deltas only.\n",
            .{baseline_pipes},
        );
    }
}

/// The agent the leak tests drive: same shape every time, only the allocator
/// and the port differ. A test that will feed real SSE must pass an arena.
fn initLeakTestAgent(allocator: std.mem.Allocator, base_url: []const u8) !Agent {
    var a = Agent.init_with_options(allocator, std.testing.io, .{
        .idle_timeout_ms = 2_000,
        .read_timeout_ms = 5_000,
    });
    a.baseUrl = base_url;
    a.model = "test-model";
    a.apiKey = "test-key";
    return a;
}

test "callStreaming does not leak pipe FDs across many failed calls (TDD: RED → GREEN)" {
    const server = try FakeServer.start(testing_allocatorCallStreaming, .head_then_close);
    defer server.deinit();
    server.waitForConnection();

    const base_url = try makeBaseUrl(testing_allocatorCallStreaming, server.port);
    defer testing_allocatorCallStreaming.free(base_url);

    var a = try initLeakTestAgent(testing_allocatorCallStreaming, base_url);
    defer a.deinit();

    // Warmup: one call absorbs what the FIRST request allocates once (client
    // pool init, curl's own state), so what follows is per-call steady state
    // and not setup cost.
    _ = a.callStreaming(makeCall(), null, noopCallback) catch {};

    const pipes_before = countPipes();
    reportCrowdedPipeTable(pipes_before);
    const handles_before = try helpers.open_descriptors.count();

    // A server that closes right after the head is the path that historically
    // leaked ~100 pipes per call, so N=3 is enough to see one per call.
    const N: usize = 3;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = a.callStreaming(makeCall(), null, noopCallback) catch {};
    }

    const pipes_growth = countPipes() -| pipes_before;
    const handles_growth = (try helpers.open_descriptors.count()) -| handles_before;
    if (pipes_growth >= N or handles_growth >= N) {
        std.debug.print(
            "  leaked descriptors over {} calls: pipes +{} ({} -> {}), handles +{} ({} -> {})\n",
            .{ N, pipes_growth, pipes_before, countPipes(), handles_growth, handles_before, try helpers.open_descriptors.count() },
        );
    }
    // ONE leaked descriptor per call is N growth, so N is the threshold that
    // catches it; the pre-fix leak was ~100x that.
    try expectCallStreaming(pipes_growth < N);
    try expectCallStreaming(handles_growth < N);
}

test "callStreaming zero-pipe-budget: even one failed call must not grow pipes" {
    // Stronger than the N-call test above: a SINGLE failed call must grow
    // neither the pipe count (Linux) nor the handle count (every host) at all.
    const server = try FakeServer.start(testing_allocatorCallStreaming, .head_then_close);
    defer server.deinit();
    server.waitForConnection();

    const base_url = try makeBaseUrl(testing_allocatorCallStreaming, server.port);
    defer testing_allocatorCallStreaming.free(base_url);

    var a = try initLeakTestAgent(testing_allocatorCallStreaming, base_url);
    defer a.deinit();

    // Warmup, exactly as above.
    _ = a.callStreaming(makeCall(), null, noopCallback) catch {};

    const pipes_before = countPipes();
    reportCrowdedPipeTable(pipes_before);
    const handles_before = try helpers.open_descriptors.count();

    _ = a.callStreaming(makeCall(), null, noopCallback) catch {};

    // STRICT: zero growth. A leak test that allows one descriptor per call is
    // the bug this budget exists to prevent.
    try expectEqualCallStreaming(pipes_before, countPipes());
    try expectEqualCallStreaming(handles_before, try helpers.open_descriptors.count());
}

test "callStreaming recovers cleanly after a failed call (success path)" {
    // Regression guard: rejected calls must leave the agent usable, and a
    // COMPLETE SSE body from a healthy server must still come back as a real
    // response with content.
    const dead = try FakeServer.start(testing_allocatorCallStreaming, .head_then_close);
    defer dead.deinit();
    const healthy = try FakeServer.start(testing_allocatorCallStreaming, .complete_chunked_response);
    defer healthy.deinit();
    dead.waitForConnection();

    const dead_url = try makeBaseUrl(testing_allocatorCallStreaming, dead.port);
    defer testing_allocatorCallStreaming.free(dead_url);
    const healthy_url = try makeBaseUrl(testing_allocatorCallStreaming, healthy.port);
    defer testing_allocatorCallStreaming.free(healthy_url);

    // The success path really does deliver a chunk, so the agent runs on an
    // arena for the reason `runStreamingWithTimeout` documents.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorCallStreaming);
    defer arena.deinit();
    var a = try initLeakTestAgent(arena.allocator(), dead_url);
    defer a.deinit();

    // Warmup against the dead server only: the FIRST request to a host pays a
    // one-time cost that must not be read as a per-call leak, and the healthy
    // fixture below serves exactly one connection.
    _ = a.callStreaming(makeCall(), null, noopCallback) catch {};

    const pipes_before = countPipes();
    reportCrowdedPipeTable(pipes_before);
    const handles_before = try helpers.open_descriptors.count();

    // Neither failed call may crash, hang, or come back as a success it did
    // not get. (Pre-fix, the runner died of ProcessFdQuotaExceeded here.)
    const failures: usize = 2;
    var attempt: usize = 0;
    while (attempt < failures) : (attempt += 1) {
        const failed = a.callStreaming(makeCall(), null, noopCallback);
        if (failed) |_| return error.TestUnexpectedResult else |_| {}
    }
    // One leaked descriptor per call would be `failures` growth, so that is
    // the threshold — the same shape the N-call test uses.
    try expectCallStreaming(countPipes() -| pipes_before < failures);
    try expectCallStreaming((try helpers.open_descriptors.count()) -| handles_before < failures);

    // The agent is still able to complete a real turn — and it is a real one:
    // the SSE delta arrived as content, with a finish_reason to end it.
    a.baseUrl = healthy_url;
    var ok = try a.callStreaming(makeCall(), null, noopCallback);
    defer ok.deinit();
    try expectEqualStringsCallStreaming("hi", ok.content orelse return error.MissingContent);
    try expectCallStreaming(ok.finish_reason != null);
}
// ===== Tests merged from image_content_test.zig (2026-09-29 flatten) =====
const expectEqualImageContent = std.testing.expectEqual;
const expectEqualStringsImageContent = std.testing.expectEqualStrings;
const expectImageContent = std.testing.expect;

test "ContentPart - text part creation" {
    const part = ContentPart{
        .part_type = "text",
        .text = try std.testing.allocator.dupe(u8, "Hello, world!"),
        .image_url = null,
    };
    defer {
        if (part.text) |t| std.testing.allocator.free(t);
    }

    try expectEqualStringsImageContent("text", part.part_type);
    try expectEqualStringsImageContent("Hello, world!", part.text.?);
    try expectEqualImageContent(@as(?ImageUrl, null), part.image_url);
}

test "ContentPart - image_url part creation" {
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
    const part = ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };
    defer {
        if (part.image_url) |img| {
            if (img.url) |u| std.testing.allocator.free(u);
        }
    }

    try expectEqualStringsImageContent("image_url", part.part_type);
    try expectEqualImageContent(@as(?[]const u8, null), part.text);
    try expectImageContent(part.image_url != null);
    try expectImageContent(std.mem.startsWith(u8, part.image_url.?.url.?, "data:image/png;base64,"));
}

test "ImageUrl - with detail option" {
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");
    const img = ImageUrl{
        .url = url_str,
        .detail = try std.testing.allocator.dupe(u8, "low"),
    };
    defer {
        if (img.url) |u| std.testing.allocator.free(u);
        if (img.detail) |d| std.testing.allocator.free(d);
    }

    try expectImageContent(img.url != null);
    try expectEqualStringsImageContent("low", img.detail.?);
}

test "AgentMessage - with content_parts (multimodal)" {
    const text_part = try std.testing.allocator.dupe(u8, "What is in this image?");
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==");

    const parts = try std.testing.allocator.alloc(ContentPart, 2);
    parts[0] = .{
        .part_type = "text",
        .text = text_part,
        .image_url = null,
    };
    parts[1] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };

    const msg = AgentMessage{
        .role = .user,
        .content = null,
        .content_parts = parts,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    defer msg.deinit(std.testing.allocator);

    try expectEqualImageContent(@as(?[]const u8, null), msg.content);
    try expectImageContent(msg.content_parts != null);
    try expectEqualImageContent(@as(usize, 2), msg.content_parts.?.len);
    try expectEqualStringsImageContent("text", msg.content_parts.?[0].part_type);
    try expectEqualStringsImageContent("image_url", msg.content_parts.?[1].part_type);
}

test "AgentMessage deinit handles content_parts correctly" {
    const text_part = try std.testing.allocator.dupe(u8, "Hello");
    const url_str = try std.testing.allocator.dupe(u8, "data:image/png;base64,abc123");

    const parts = try std.testing.allocator.alloc(ContentPart, 1);
    parts[0] = .{
        .part_type = "text",
        .text = text_part,
        .image_url = .{
            .url = url_str,
            .detail = null,
        },
    };

    const msg = AgentMessage{
        .role = .user,
        .content = null,
        .content_parts = parts,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    // deinit should free all allocated memory without leaking
    msg.deinit(std.testing.allocator);

    // If we get here without memory errors, the test passes
    try expectImageContent(true);
}

test "ContentPart - base64 image URL format validation" {
    // Test that we can create ContentPart with proper base64 data URL format
    // as expected by OpenAI API
    const base64_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const url = try std.fmt.allocPrint(std.testing.allocator, "data:image/png;base64,{s}", .{base64_data});

    const part = ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = url,
            .detail = null,
        },
    };
    defer {
        if (part.image_url) |img| {
            if (img.url) |u| std.testing.allocator.free(u);
        }
    }

    try expectImageContent(std.mem.startsWith(u8, part.image_url.?.url.?, "data:image/png;base64,"));
}

test "AgentMessage - legacy content field still works" {
    // Verify backward compatibility - AgentMessage with plain content
    const content = try std.testing.allocator.dupe(u8, "Hello, this is plain text content");

    const msg = AgentMessage{
        .role = .user,
        .content = content,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
    defer msg.deinit(std.testing.allocator);

    try expectEqualStringsImageContent("Hello, this is plain text content", msg.content.?);
    try expectEqualImageContent(@as(?[]const ContentPart, null), msg.content_parts);
}

// ===== Tests merged from openai_reasoning_test.zig (2026-09-29 flatten)
// ===== Tests for the new OpenAI `reasoning_effort` field on the request body
// built by `buildJsonOpenAIRequest`. Plan 2026-08-23-model-thinking.

const OpenaiReasoningMakeOpts = struct {
    reasoningEffort: ?[]const u8 = null,
    thinkingEnabled: bool = true,
};

fn makeAgentOpenaiReasoning(opts: OpenaiReasoningMakeOpts) Agent {
    var a = Agent.init(testing.allocator, std.testing.io);
    a.apiKey = "test-key";
    a.model = "o1-preview";
    a.baseUrl = "https://api.openai.com/v1";
    a.UrlStyle = "openai";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.reasoningEffort = opts.reasoningEffort;
    a.maxTokens = 8192;
    return a;
}

fn emptyMessagesOpenaiReasoning() []const AgentMessage {
    return &.{
        .{
            .role = .user,
            .content = "solve x^2 + 2x + 1 = 0",
        },
    };
}

fn emptyToolsOpenaiReasoning() []const AgentTool {
    return &.{};
}

test "buildJsonOpenAIRequest: reasoningEffort set emits reasoning_effort field" {
    var a = makeAgentOpenaiReasoning(.{ .reasoningEffort = "high" });

    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "buildJsonOpenAIRequest: reasoningEffort null omits reasoning_effort field" {
    var a = makeAgentOpenaiReasoning(.{ .reasoningEffort = null });

    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildJsonOpenAIRequest: reasoningEffort empty string omits field" {
    // The frontend uses "" for "auto" / null. The Agent field is
    // ?[]const u8 so an empty slice is a valid-but-meaningless
    // value — we treat it the same as null (omit).
    var a = makeAgentOpenaiReasoning(.{ .reasoningEffort = "" });

    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildJsonOpenAIRequest: reasoning_effort coexists with tools + temperature" {
    // o1 supports tool calls (function calling); the reasoning_effort
    // field must coexist with tools and not be silenced by them.
    var a = makeAgentOpenaiReasoning(.{ .reasoningEffort = "medium" });

    const tool: AgentTool = .{
        .type = "function",
        .function = .{
            .name = "get_weather",
            .description = "Get the weather",
            .parameters = .{
                .type = "object",
                .properties = &.{
                    .{ .name = "city", .type = "string", .description = "City name" },
                },
                .required = &.{"city"},
            },
        },
    };

    const params = AgentCall{
        .messages = emptyMessagesOpenaiReasoning(),
        .tools = &.{tool},
        .temperature = 0.7,
    };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
    // temperature is serialized as a JSON float — Zig emits e.g.
    // "0.699999988079071" for 0.7, so we only check the field name exists,
    // not the exact value.
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"get_weather\"") != null);
}

test "buildJsonOpenAIRequest: each reasoning_effort value passes through verbatim" {
    // Parametric sweep over the 4 canonical values. Backend is a
    // dumb pipe — the server validates per-model compatibility.
    const values = [_][]const u8{ "low", "medium", "high", "auto" };
    for (values) |v| {
        var a = makeAgentOpenaiReasoning(.{ .reasoningEffort = v });
        const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
        const body = try a.buildJsonOpenAIRequest(params, true);
        defer testing.allocator.free(body);

        var needle: [128]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&needle, "\"reasoning_effort\":\"{s}\"", .{v});
        try testing.expect(std.mem.indexOf(u8, body, formatted) != null);
    }
}

// Reasoning-echo backfill (task_1789091513563_0): DeepSeek-style providers in
// thinking mode reject replays where an assistant message lacks
// `reasoning_content`.

fn assistantMsgNoReasoningOpenaiReasoning(text: ?[]const u8) AgentMessage {
    return .{ .role = .assistant, .content = text };
}

// ============================================================================
// Regression: the openai chat-completions body must NOT carry the
// non-standard `thinking` / `enable_thinking` params.

test "buildJsonOpenAIRequest: thinking off emits NEITHER thinking NOR enable_thinking" {
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = false });
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "buildJsonOpenAIRequest: thinking on emits NEITHER thinking NOR enable_thinking" {
    // The positive control for the absence assertions above: the fields
    // are gone for BOTH states, so this cannot pass vacuously.
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = true });
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "buildJsonOpenAIRequest: reasoning_effort still round-trips after the thinking fields were dropped" {
    // Proves the fix removed ONLY the two vendor params — the real
    // thinking knob on this body shape is untouched.
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = false, .reasoningEffort = "high" });
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "buildJsonOpenAIRequest: the body is still valid JSON with the core fields intact" {
    // Guards against the removal having broken the object shape.
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = false });
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("model") != null);
    try testing.expect(obj.get("messages") != null);
    try testing.expect(obj.get("temperature") != null);
    try testing.expect(obj.get("max_tokens") != null);
    try testing.expect(obj.get("thinking") == null);
    try testing.expect(obj.get("enable_thinking") == null);
}

test "buildJsonOpenAIRequest: thinking on + assistant null reasoning emits empty reasoning_content" {
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = true });
    const msgs = [_]AgentMessage{
        .{ .role = .user, .content = "hello" },
        assistantMsgNoReasoningOpenaiReasoning("final answer"),
    };
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"\"") != null);
}

test "buildJsonOpenAIRequest: thinking off + all-null history omits reasoning_content" {
    // Plain sessions keep their exact wire shape — no new field.
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = false });
    const msgs = [_]AgentMessage{
        .{ .role = .user, .content = "hello" },
        assistantMsgNoReasoningOpenaiReasoning("final answer"),
    };
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
}

test "buildJsonOpenAIRequest: thinking off but history has reasoning backfills null assistant" {
    // Mid-session thinking toggle-off: older turns carry reasoning, a
    // newer turn has none. The null one gets "" (echo validator sees
    // the field on every assistant message); the real one is verbatim.
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = false });
    const msgs = [_]AgentMessage{
        .{ .role = .assistant, .content = "first", .reasoning_content = "real-thinking" },
        assistantMsgNoReasoningOpenaiReasoning(null),
    };
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"real-thinking\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"\"") != null);
}

test "buildJsonOpenAIRequest: backfill is assistant-only, user messages stay clean" {
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = true });
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = emptyMessagesOpenaiReasoning() };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
}

test "buildJsonOpenAIRequest: assistant with reasoning keeps verbatim value" {
    var a = makeAgentOpenaiReasoning(.{ .thinkingEnabled = true });
    const msgs = [_]AgentMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "final answer", .reasoning_content = "model's reasoning..." },
        .{ .role = .user, .content = "follow up" },
    };
    const params = AgentCall{ .tools = emptyToolsOpenaiReasoning(), .messages = &msgs };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"model's reasoning...\"") != null);
}

// ===== Tests merged from openai_responses_test.zig (2026-09-29 flatten)
// ===== Behavioural tests for OpenAI Responses API (url_style =
// "openai-response").

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeResponsesAgentOpenaiResponses(opts: struct {
    reasoningEffort: ?[]const u8 = null,
    thinkingEnabled: bool = true,
    maxTokens: usize = 4096,
    model: []const u8 = "gpt-4o",
    baseUrl: []const u8 = "https://api.openai.com/v1",
    userIdentifier: []const u8 = "",
}) Agent {
    var a = Agent.init(testing.allocator, std.testing.io);
    a.model = opts.model;
    a.baseUrl = opts.baseUrl;
    a.UrlStyle = "openai-response";
    a.thinkingEnabled = opts.thinkingEnabled;
    a.reasoningEffort = opts.reasoningEffort;
    a.maxTokens = opts.maxTokens;
    a.userIdentifier = opts.userIdentifier;
    return a;
}

fn userMsgOpenaiResponses(text: []const u8) AgentMessage {
    return .{
        .role = .user,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

fn sysMsgOpenaiResponses(text: []const u8) AgentMessage {
    return .{
        .role = .system,
        .content = text,
        .content_parts = null,
        .tool_calls = null,
        .tool_call_id = null,
        .reasoning_content = null,
    };
}

fn assistantMsgOpenaiResponses(text: ?[]const u8, reasoning: ?[]const u8) AgentMessage {
    return .{
        .role = .assistant,
        .content = text,
        .reasoning_content = reasoning,
        .tool_calls = null,
        .tool_call_id = null,
        .content_parts = null,
    };
}

fn assistantMsgFullOpenaiResponses(text: ?[]const u8, reasoning: ?[]const u8, id: ?[]const u8, enc: ?[]const u8) AgentMessage {
    return .{
        .role = .assistant,
        .content = text,
        .reasoning_content = reasoning,
        .reasoning_id = id,
        .reasoning_encrypted_content = enc,
        .tool_calls = null,
        .tool_call_id = null,
        .content_parts = null,
    };
}

fn buildResponsesBodyOpenaiResponses(
    a: *Agent,
    messages: []const AgentMessage,
    tools: []const AgentTool,
    temperature: ?f32,
    max_tokens: ?usize,
    stream: bool,
) ![]u8 {
    const params = AgentCall{
        .tools = tools,
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
    };
    return try a.buildJsonResponsesRequest(params, stream);
}

const ParsedBodyOpenaiResponses = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
};

fn buildAndParseOpenaiResponses(
    a: *Agent,
    messages: []const AgentMessage,
    tools: []const AgentTool,
    temperature: ?f32,
    max_tokens: ?usize,
    stream: bool,
) !ParsedBodyOpenaiResponses {
    const raw = try buildResponsesBodyOpenaiResponses(a, messages, tools, temperature, max_tokens, stream);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    return .{ .raw = raw, .parsed = parsed };
}

fn freeBodyOpenaiResponses(body: ParsedBodyOpenaiResponses) void {
    testing.allocator.free(body.raw);
    body.parsed.deinit();
}

fn sampleToolOpenaiResponses() AgentTool {
    return .{
        .type = "function",
        .function = .{
            .name = "get_weather",
            .description = "Get the weather",
            .parameters = .{
                .type = "object",
                .properties = &.{
                    .{ .name = "city", .type = "string", .description = "City name" },
                },
                .required = &.{"city"},
            },
        },
    };
}

// ---------------------------------------------------------------------------
// Builder: instructions from system messages
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: single system message becomes instructions" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        sysMsgOpenaiResponses("You are a helpful assistant."),
        userMsgOpenaiResponses("Hello."),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const ins = body.parsed.value.object.get("instructions");
    try testing.expect(ins != null);
    try testing.expect(ins.? == .string);
    try testing.expectEqualStrings("You are a helpful assistant.", ins.?.string);

    // system message must NOT appear in input[]
    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (item.object.get("role")) |r| {
            try testing.expect(!std.mem.eql(u8, r.string, "system"));
        }
    }
    // input should have exactly 1 entry (the user message)
    try testing.expectEqual(@as(usize, 1), input.items.len);
}

test "buildJsonResponsesRequest: multiple system messages joined with \\n\\n into instructions" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        sysMsgOpenaiResponses("First part."),
        sysMsgOpenaiResponses("Second part."),
        userMsgOpenaiResponses("Hi."),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const ins = body.parsed.value.object.get("instructions").?.string;
    try testing.expectEqualStrings("First part.\n\nSecond part.", ins);
}

test "buildJsonResponsesRequest: no system message omits instructions field" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("Hello.")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("instructions") == null);
    // also check raw has no "instructions" key
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"instructions\"") == null);
}

// ---------------------------------------------------------------------------
// Builder: input[] with input_text / input_image
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: user plain text becomes input message with input_text" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hello world")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input.items.len);
    const item = input.items[0];
    try testing.expectEqualStrings("message", item.object.get("type").?.string);
    try testing.expectEqualStrings("user", item.object.get("role").?.string);
    const content = item.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("input_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("hello world", content.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: user content_parts with text+image emits input_text and input_image with detail default auto" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const text_dup = try testing.allocator.dupe(u8, "what is this?");
    defer testing.allocator.free(text_dup);
    const url_dup = try testing.allocator.dupe(u8, "data:image/png;base64,abc123");
    defer testing.allocator.free(url_dup);

    const parts = try testing.allocator.alloc(ContentPart, 2);
    defer testing.allocator.free(parts);
    parts[0] = .{ .part_type = "text", .text = text_dup, .image_url = null };
    parts[1] = .{ .part_type = "image_url", .text = null, .image_url = .{ .url = url_dup, .detail = null } };

    const messages = [_]AgentMessage{
        .{ .role = .user, .content = null, .content_parts = parts, .tool_calls = null, .tool_call_id = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 1), input.items.len);
    const content = input.items[0].object.get("content").?.array;
    try testing.expectEqual(@as(usize, 2), content.items.len);
    try testing.expectEqualStrings("input_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("what is this?", content.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("input_image", content.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("data:image/png;base64,abc123", content.items[1].object.get("image_url").?.string);
    // detail defaults to "auto" when null
    try testing.expectEqualStrings("auto", content.items[1].object.get("detail").?.string);
}

test "buildJsonResponsesRequest: user content_parts image with explicit detail preserves it" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const url_dup = try testing.allocator.dupe(u8, "data:image/jpeg;base64,xyz");
    defer testing.allocator.free(url_dup);
    const parts = try testing.allocator.alloc(ContentPart, 1);
    defer testing.allocator.free(parts);
    parts[0] = .{ .part_type = "image_url", .text = null, .image_url = .{ .url = url_dup, .detail = "high" } };

    const messages = [_]AgentMessage{
        .{ .role = .user, .content = null, .content_parts = parts, .tool_calls = null, .tool_call_id = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const content = body.parsed.value.object.get("input").?.array.items[0].object.get("content").?.array;
    try testing.expectEqualStrings("high", content.items[0].object.get("detail").?.string);
}

// ---------------------------------------------------------------------------
// Builder: assistant output_text (content + reasoning_content)
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: assistant with content and reasoning_content emits separate reasoning and message items" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses("final answer", "thinking trace"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // input[0]=user, input[1]=reasoning, input[2]=assistant message
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqual(@as(usize, 1), summary.items.len);
    try testing.expectEqualStrings("summary_text", summary.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("thinking trace", summary.items[0].object.get("text").?.string);
    // reasoning item must NOT have role/content, and must NOT leak into message
    try testing.expect(reasoning.object.get("role") == null);
    try testing.expect(reasoning.object.get("content") == null);

    const assistant = input.items[2];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("final answer", content.items[0].object.get("text").?.string);
    // assistant content must NOT contain reasoning
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"thinking trace\"") != null);
    // ensure reasoning is not represented as output_text inside message
    for (content.items) |c| {
        try testing.expect(!std.mem.eql(u8, c.object.get("text").?.string, "thinking trace"));
    }
}

test "buildJsonResponsesRequest: assistant with only content emits single message item" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses("only content", null),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const assistant = input.items[1];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("only content", content.items[0].object.get("text").?.string);
    // no reasoning item
    for (input.items) |item| {
        try testing.expect(!std.mem.eql(u8, item.object.get("type").?.string, "reasoning"));
    }
}

test "buildJsonResponsesRequest: assistant with only reasoning_content emits single reasoning item" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses(null, "only reasoning"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqual(@as(usize, 1), summary.items.len);
    try testing.expectEqualStrings("summary_text", summary.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("only reasoning", summary.items[0].object.get("text").?.string);
    // no message item for this assistant turn
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "message")) {
            if (item.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) {
                    // the only assistant item should be reasoning, not message
                    try testing.expect(false); // should not reach
                }
            }
        }
    }
}

test "buildJsonResponsesRequest: assistant reasoning with id and encrypted_content emits them" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{
            .role = .assistant,
            .content = "final answer",
            .reasoning_content = "thinking trace",
            .reasoning_id = "rs_123",
            .reasoning_encrypted_content = "ENC...",
            .tool_calls = null,
            .tool_call_id = null,
            .content_parts = null,
        },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_123", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("ENC...", reasoning.object.get("encrypted_content").?.string);
    const summary = reasoning.object.get("summary").?.array;
    try testing.expectEqualStrings("thinking trace", summary.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: assistant reasoning without id omits id and encrypted_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses("final answer", "thinking trace"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const reasoning = body.parsed.value.object.get("input").?.array.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expect(reasoning.object.get("id") == null);
    try testing.expect(reasoning.object.get("encrypted_content") == null);
    // raw should not contain empty id
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"id\":\"\"") == null);
}

test "buildJsonResponsesRequest: empty assistant without tools emits output_text empty string" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses(null, null),
    };
    // also test with empty strings
    const messages2 = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgOpenaiResponses("", ""),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);
    const assistant = body.parsed.value.object.get("input").?.array.items[1];
    const content = assistant.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("output_text", content.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("", content.items[0].object.get("text").?.string);

    var body2 = try buildAndParseOpenaiResponses(&a, &messages2, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body2);
    const assistant2 = body2.parsed.value.object.get("input").?.array.items[1];
    const content2 = assistant2.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content2.items.len);
    try testing.expectEqualStrings("", content2.items[0].object.get("text").?.string);
}

// ---------------------------------------------------------------------------
// Builder: function_call + function_call_output for tools
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: assistant tool_calls become function_call items" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_123");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "get_weather");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"city\":\"Paris\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("weather?"),
        .{ .role = .assistant, .content = null, .reasoning_content = null, .tool_calls = tc_array, .tool_call_id = null, .content_parts = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // user + function_call (no assistant message because content empty and has tool_calls)
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const fc = input.items[1];
    try testing.expectEqualStrings("function_call", fc.object.get("type").?.string);
    try testing.expectEqualStrings("call_123", fc.object.get("call_id").?.string);
    try testing.expectEqualStrings("get_weather", fc.object.get("name").?.string);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", fc.object.get("arguments").?.string);
}

test "buildJsonResponsesRequest: assistant with content and tool_calls emits message + function_call" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_456");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "search");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"q\":\"test\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{ .role = .assistant, .content = "thinking", .reasoning_content = null, .tool_calls = tc_array, .tool_call_id = null, .content_parts = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    // input[0]=user, input[1]=assistant message, input[2]=function_call
    try testing.expectEqualStrings("message", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[1].object.get("role").?.string);
    try testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
}

test "buildJsonResponsesRequest: tool role becomes function_call_output" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{ .role = .assistant, .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null, .content_parts = null },
        .{ .role = .tool, .content = "tool result", .tool_call_id = "call_123", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // user + assistant(empty) + function_call_output
    try testing.expectEqual(@as(usize, 3), input.items.len);
    const fco = input.items[2];
    try testing.expectEqualStrings("function_call_output", fco.object.get("type").?.string);
    try testing.expectEqualStrings("call_123", fco.object.get("call_id").?.string);
    try testing.expectEqualStrings("tool result", fco.object.get("output").?.string);
}

// ---------------------------------------------------------------------------
// Builder: temperature, max_output_tokens, store, stream, user, tools
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: temperature is emitted" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, 0.7, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("temperature") != null);
    // f32 0.7 serializes as 0.699999988079071 or 0.7 depending on formatting
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"temperature\":") != null);
}

test "buildJsonResponsesRequest: max_output_tokens from params overrides self.maxTokens" {
    var a = makeResponsesAgentOpenaiResponses(.{ .maxTokens = 4096 });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};

    var body1 = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, 8192, true);
    defer freeBodyOpenaiResponses(body1);
    try testing.expectEqual(@as(i64, 8192), body1.parsed.value.object.get("max_output_tokens").?.integer);

    var body2 = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body2);
    try testing.expectEqual(@as(i64, 4096), body2.parsed.value.object.get("max_output_tokens").?.integer);
}

test "buildJsonResponsesRequest: store is always false" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const store = body.parsed.value.object.get("store").?;
    try testing.expect(store == .bool);
    try testing.expectEqual(false, store.bool);
}

test "buildJsonResponsesRequest: stream true emits stream:true, stream false omits it" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};

    var body_true = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body_true);
    try testing.expectEqual(true, body_true.parsed.value.object.get("stream").?.bool);

    var body_false = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, false);
    defer freeBodyOpenaiResponses(body_false);
    // When stream=false, the field is omitted (jsonStringify only writes when self.stream is true)
    try testing.expect(body_false.parsed.value.object.get("stream") == null);
    try testing.expect(std.mem.indexOf(u8, body_false.raw, "\"stream\"") == null);
}

test "buildJsonResponsesRequest: user field present when identifier set, absent when empty" {
    var a_with = makeResponsesAgentOpenaiResponses(.{ .userIdentifier = "user-123" });
    defer a_with.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body_with = try buildAndParseOpenaiResponses(&a_with, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body_with);
    try testing.expectEqualStrings("user-123", body_with.parsed.value.object.get("user").?.string);

    var a_without = makeResponsesAgentOpenaiResponses(.{ .userIdentifier = "" });
    defer a_without.deinit();
    var body_without = try buildAndParseOpenaiResponses(&a_without, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body_without);
    try testing.expect(body_without.parsed.value.object.get("user") == null);
}

test "buildJsonResponsesRequest: tools and tool_choice present when tools non-empty" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    const tools = [_]AgentTool{sampleToolOpenaiResponses()};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &tools, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("tools") != null);
    const tools_arr = body.parsed.value.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 1), tools_arr.items.len);
    try testing.expectEqualStrings("get_weather", tools_arr.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("auto", body.parsed.value.object.get("tool_choice").?.string);
}

test "buildJsonResponsesRequest: tools absent omits tools and tool_choice" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("tools") == null);
    try testing.expect(body.parsed.value.object.get("tool_choice") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"tool_choice\"") == null);
}

// ---------------------------------------------------------------------------
// Builder: reasoning.effort
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: reasoningEffort set emits reasoning.effort" {
    var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = "high" });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const reasoning = body.parsed.value.object.get("reasoning").?;
    try testing.expect(reasoning == .object);
    try testing.expectEqualStrings("high", reasoning.object.get("effort").?.string);
}

test "buildJsonResponsesRequest: reasoningEffort null omits reasoning field" {
    var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = null });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"reasoning\"") == null);
}

test "buildJsonResponsesRequest: reasoningEffort empty string omits reasoning field" {
    var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = "" });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
}

test "buildJsonResponsesRequest: reasoningEffort each value passes through verbatim" {
    const values = [_][]const u8{ "low", "medium", "high", "auto" };
    for (values) |v| {
        var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = v });
        defer a.deinit();
        const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
        var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
        defer freeBodyOpenaiResponses(body);

        const reasoning = body.parsed.value.object.get("reasoning").?;
        try testing.expectEqualStrings(v, reasoning.object.get("effort").?.string);
    }
}

test "buildJsonResponsesRequest: reasoningEffort null + thinkingEnabled true omits reasoning (no auto fallback)" {
    // Regression: must NOT auto-map thinkingEnabled -> reasoning.effort "medium"
    var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = null, .thinkingEnabled = true });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"reasoning\"") == null);
}

test "buildJsonResponsesRequest: reasoningEffort null + thinkingEnabled false omits reasoning" {
    var a = makeResponsesAgentOpenaiResponses(.{ .reasoningEffort = null, .thinkingEnabled = false });
    defer a.deinit();
    const messages = [_]AgentMessage{userMsgOpenaiResponses("hi")};
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    try testing.expect(body.parsed.value.object.get("reasoning") == null);
}

// ---------------------------------------------------------------------------
// Parser: response.output_text.delta -> content
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.output_text.delta populates content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello world\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello world", chunk.?.content.?);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expect(chunk.?.tool_calls_delta == null);
}

test "parse_responses_stream_chunk: response.output_text.delta empty string returns null" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk == null);
}

// ---------------------------------------------------------------------------
// Parser: reasoning deltas -> reasoning_content
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.reasoning_text.delta populates reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"step 1\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("step 1", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning_summary_text.delta populates reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"summary\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("summary", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning.delta populates reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.reasoning.delta\",\"delta\":\"reasoning chunk\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("reasoning chunk", chunk.?.reasoning_content.?);
}

// ---------------------------------------------------------------------------
// Parser: tool call deltas
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.output_item.added function_call emits tool_calls_delta with id+name" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_abc\",\"name\":\"get_weather\",\"arguments\":\"\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.tool_calls_delta != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try testing.expectEqual(@as(usize, 0), chunk.?.tool_calls_delta.?[0].index);
    try testing.expectEqualStrings("call_abc", chunk.?.tool_calls_delta.?[0].id.?);
    try testing.expectEqualStrings("get_weather", chunk.?.tool_calls_delta.?[0].function_name.?);
}

test "parse_responses_stream_chunk: response.output_item.added non-function_call returns null" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk == null);
}

test "parse_responses_stream_chunk: response.function_call_arguments.delta emits tool_calls_delta arguments" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"city\\\":\\\"Paris\\\"}\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.tool_calls_delta != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", chunk.?.tool_calls_delta.?[0].function_arguments.?);
    try testing.expectEqual(@as(usize, 0), chunk.?.tool_calls_delta.?[0].index);
}

test "parse_responses_stream_chunk: response.function_call_arguments.delta with output_index 1" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"partial\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(usize, 1), chunk.?.tool_calls_delta.?[0].index);
}

// ---------------------------------------------------------------------------
// Parser: terminal events — finish_reason + usage + tool_calls override
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.completed without function_call => finish_reason stop" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed with function_call output => finish_reason tool_calls" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed with mixed output containing function_call => tool_calls" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]},{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"search\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.completed usage maps input_tokens->prompt_tokens etc" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":42,\"output_tokens\":7,\"total_tokens\":49}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.usage != null);
    try testing.expectEqual(@as(u32, 42), chunk.?.usage.?.prompt_tokens);
    try testing.expectEqual(@as(u32, 7), chunk.?.usage.?.completion_tokens);
    try testing.expectEqual(@as(u32, 49), chunk.?.usage.?.total_tokens);
}

test "parse_responses_stream_chunk: response.completed usage with cached_tokens via input_tokens_details" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"total_tokens\":120,\"input_tokens_details\":{\"cached_tokens\":30}}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(u32, 30), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_responses_stream_chunk: response.completed usage without total_tokens computes prompt+completion" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(u32, 15), chunk.?.usage.?.total_tokens);
}

test "parse_responses_stream_chunk: response.incomplete with max_output_tokens => finish_reason length" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .length), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.failed => finish_reason content_filter" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"total_tokens\":10}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .content_filter), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: response.incomplete without max_output_tokens reason => stop" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"total_tokens\":10}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

// ---------------------------------------------------------------------------
// Parser: ignored lifecycle events return null
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: ignored events return null" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const ignored = [_][]const u8{
        "{\"type\":\"response.output_text.done\",\"output_index\":0,\"text\":\"hi\"}",
        "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.queued\",\"response\":{\"id\":\"resp_123\"}}",
        "{\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\"}}",
        "{\"type\":\"response.output_item.done\",\"output_index\":0}",
        "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{}\"}",
        "{\"type\":\"response.reasoning_text.done\"}",
        "{\"type\":\"response.refusal.done\"}",
    };
    for (ignored) |data| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk == null);
    }
}

test "parse_responses_stream_chunk: response.refusal.delta populates content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.refusal.delta\",\"delta\":\"I cannot do that\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("I cannot do that", chunk.?.content.?);
}

// ---------------------------------------------------------------------------
// Parser: dispatch via UrlStyle
// ---------------------------------------------------------------------------

test "parse_stream_chunk dispatches to Responses parser when UrlStyle is openai-response" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // This is Responses-shaped, should parse via Responses parser
    const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello", chunk.?.content.?);
}

test "parse_stream_chunk dispatches to OpenAI parser when UrlStyle is openai" {
    var a = Agent.init(testing.allocator, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "openai";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"id\":\"chatcmpl-x\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("hello", chunk.?.content.?);
}

// ---------------------------------------------------------------------------
// Parser: terminal reasoning metadata (Task 4)
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: response.completed with reasoning item captures id/summary/encrypted_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thinking trace\"}],\"encrypted_content\":\"ENC_DATA\"},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"final answer\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_DATA", chunk.?.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("thinking trace", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed with multiple summary entries joins with newline" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_456\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"step 1\"},{\"type\":\"summary_text\",\"text\":\"step 2\"},{\"type\":\"summary_text\",\"text\":\"step 3\"}],\"encrypted_content\":\"ENC2\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_456", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC2", chunk.?.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("step 1\nstep 2\nstep 3", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed without reasoning item has no reasoning metadata" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expect(chunk.?.reasoning_encrypted_content == null);
    try testing.expect(chunk.?.reasoning_content == null);
}

test "parse_responses_stream_chunk: response.completed reasoning item without encrypted_content still captures id and summary" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_789\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"only summary\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_789", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_encrypted_content == null);
    try testing.expectEqualStrings("only summary", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.completed reasoning item with empty summary has no reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const data =
        "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_empty\",\"summary\":[],\"encrypted_content\":\"ENC_EMPTY\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_empty", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_EMPTY", chunk.?.reasoning_encrypted_content.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

// ---------------------------------------------------------------------------
// Aggregator: reasoning metadata via terminal chunk
// ---------------------------------------------------------------------------

test "StreamingAggregator: terminal reasoning chunk populates reasoning_id and encrypted_content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Simulate delta reasoning
    try agg.process_chunk(.{ .reasoning_content = "delta thinking" });
    // Simulate terminal chunk with id/encrypted/summary fallback
    try agg.process_chunk(.{
        .reasoning_id = "rs_agg_1",
        .reasoning_encrypted_content = "ENC_AGG",
        .reasoning_content = "summary fallback",
        .finish_reason = .stop,
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 15 },
    });

    var res = try agg.finalize();
    defer res.deinit();
    // Delta content wins over summary fallback
    try testing.expectEqualStrings("delta thinking", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_agg_1", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_AGG", res.reasoning_encrypted_content.?);
}

test "StreamingAggregator: summary fallback used when no delta reasoning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    try agg.process_chunk(.{
        .reasoning_id = "rs_fallback",
        .reasoning_encrypted_content = "ENC_FB",
        .reasoning_content = "summary only",
        .finish_reason = .stop,
    });

    var res = try agg.finalize();
    defer res.deinit();
    try testing.expectEqualStrings("summary only", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_fallback", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_FB", res.reasoning_encrypted_content.?);
}

test "StreamingAggregator: no reasoning stays null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    try agg.process_chunk(.{ .content = "hello", .finish_reason = .stop });
    var res = try agg.finalize();
    defer res.deinit();
    try testing.expect(res.reasoning_content == null);
    try testing.expect(res.reasoning_id == null);
    try testing.expect(res.reasoning_encrypted_content == null);
}

// ---------------------------------------------------------------------------
// Task 6: Multi-turn replay — builder ordering with reasoning metadata
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: multi-turn replay preserves ordering reasoning before assistant per turn" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("first question"),
        assistantMsgFullOpenaiResponses("first answer", "first thinking", "rs_1", "ENC_1"),
        userMsgOpenaiResponses("second question"),
        assistantMsgFullOpenaiResponses("second answer", "second thinking", "rs_2", "ENC_2"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(rs_1), assistant(first answer), user, reasoning(rs_2), assistant(second answer)]
    try testing.expectEqual(@as(usize, 6), input.items.len);

    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("first thinking", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[2].object.get("role").?.string);
    try testing.expectEqualStrings("first answer", input.items[2].object.get("content").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[3].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("rs_2", input.items[4].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_2", input.items[4].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("second thinking", input.items[4].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("message", input.items[5].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[5].object.get("role").?.string);
    try testing.expectEqualStrings("second answer", input.items[5].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: multi-turn replay reasoning not leaked into output_text" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q1"),
        assistantMsgFullOpenaiResponses("a1", "thinking 1", "rs_1", "ENC_1"),
        userMsgOpenaiResponses("q2"),
        assistantMsgFullOpenaiResponses("a2", "thinking 2", "rs_2", "ENC_2"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "message")) {
            if (item.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) {
                    const content = item.object.get("content").?.array;
                    for (content.items) |c| {
                        const t = c.object.get("text").?.string;
                        try testing.expect(!std.mem.eql(u8, t, "thinking 1"));
                        try testing.expect(!std.mem.eql(u8, t, "thinking 2"));
                    }
                }
            }
        }
    }
}

test "buildJsonResponsesRequest: multi-turn replay encrypted_content preserved verbatim" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const enc1 = "ENCRYPTED_DATA_TURN_1_!@#$%";
    const enc2 = "ENCRYPTED_DATA_TURN_2_^&*()";
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q1"),
        assistantMsgFullOpenaiResponses("a1", "t1", "rs_1", enc1),
        userMsgOpenaiResponses("q2"),
        assistantMsgFullOpenaiResponses("a2", "t2", "rs_2", enc2),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqualStrings(enc1, input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings(enc2, input.items[4].object.get("encrypted_content").?.string);
}

test "buildJsonResponsesRequest: multi-turn replay ids preserved per turn" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q1"),
        assistantMsgFullOpenaiResponses("a1", "t1", "rs_alpha", "ENC_A"),
        userMsgOpenaiResponses("q2"),
        assistantMsgFullOpenaiResponses("a2", "t2", "rs_beta", "ENC_B"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqualStrings("rs_alpha", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("rs_beta", input.items[4].object.get("id").?.string);
    // ids must not be swapped
    try testing.expect(!std.mem.eql(u8, input.items[1].object.get("id").?.string, "rs_beta"));
    try testing.expect(!std.mem.eql(u8, input.items[4].object.get("id").?.string, "rs_alpha"));
}

// ---------------------------------------------------------------------------
// Task 7: Tool-call replay — reasoning separate from function_call
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: tool-call replay reasoning separate from function_call" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_tool_1");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "search");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"q\":\"test\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("find info"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "need to search",
            .reasoning_id = "rs_tool_1",
            .reasoning_encrypted_content = "ENC_TOOL_1",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{ .role = .tool, .content = "tool result here", .tool_call_id = "call_tool_1", .tool_calls = null, .content_parts = null, .reasoning_content = null },
        assistantMsgFullOpenaiResponses("final answer", "final thinking", "rs_tool_2", "ENC_TOOL_2"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(rs_tool_1), function_call, function_call_output, reasoning(rs_tool_2), assistant(final answer)]
    try testing.expectEqual(@as(usize, 6), input.items.len);

    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_tool_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_TOOL_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("need to search", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);

    try testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("call_tool_1", input.items[2].object.get("call_id").?.string);
    try testing.expectEqualStrings("search", input.items[2].object.get("name").?.string);

    try testing.expectEqualStrings("function_call_output", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("call_tool_1", input.items[3].object.get("call_id").?.string);
    try testing.expectEqualStrings("tool result here", input.items[3].object.get("output").?.string);

    try testing.expectEqualStrings("reasoning", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("rs_tool_2", input.items[4].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_TOOL_2", input.items[4].object.get("encrypted_content").?.string);

    try testing.expectEqualStrings("message", input.items[5].object.get("type").?.string);
    try testing.expectEqualStrings("assistant", input.items[5].object.get("role").?.string);
    try testing.expectEqualStrings("final answer", input.items[5].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "buildJsonResponsesRequest: tool-call replay reasoning not inside function_call" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_x");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "do_thing");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "secret thinking",
            .reasoning_id = "rs_x",
            .reasoning_encrypted_content = "ENC_X",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    // function_call item must not contain reasoning text
    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "function_call")) {
            // function_call has call_id/name/arguments, no summary/content with reasoning
            try testing.expect(item.object.get("summary") == null);
            try testing.expect(item.object.get("encrypted_content") == null);
            const args = item.object.get("arguments").?.string;
            try testing.expect(std.mem.indexOf(u8, args, "secret thinking") == null);
        }
    }
    // reasoning item must be separate
    var found_reasoning = false;
    for (input.items) |item| {
        if (std.mem.eql(u8, item.object.get("type").?.string, "reasoning")) {
            found_reasoning = true;
            try testing.expectEqualStrings("secret thinking", item.object.get("summary").?.array.items[0].object.get("text").?.string);
        }
    }
    try testing.expect(found_reasoning);
}

test "buildJsonResponsesRequest: tool-call replay final answer separate from reasoning" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_y");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "lookup");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"id\":1}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q"),
        .{
            .role = .assistant,
            .content = null,
            .reasoning_content = "reasoning before tool",
            .reasoning_id = "rs_y1",
            .reasoning_encrypted_content = "ENC_Y1",
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{ .role = .tool, .content = "result", .tool_call_id = "call_y", .tool_calls = null, .content_parts = null, .reasoning_content = null },
        assistantMsgFullOpenaiResponses("done", "reasoning after tool", "rs_y2", "ENC_Y2"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // last item is assistant message with "done", not reasoning
    const last = input.items[input.items.len - 1];
    try testing.expectEqualStrings("message", last.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", last.object.get("role").?.string);
    try testing.expectEqualStrings("done", last.object.get("content").?.array.items[0].object.get("text").?.string);
    // second-to-last is reasoning with "reasoning after tool"
    const second_last = input.items[input.items.len - 2];
    try testing.expectEqualStrings("reasoning", second_last.object.get("type").?.string);
    try testing.expectEqualStrings("reasoning after tool", second_last.object.get("summary").?.array.items[0].object.get("text").?.string);
    // assistant content must not contain reasoning text
    try testing.expect(!std.mem.eql(u8, last.object.get("content").?.array.items[0].object.get("text").?.string, "reasoning after tool"));
}

// ---------------------------------------------------------------------------
// Task 8: End-to-end — mock SSE stream through StreamingAggregator
// ---------------------------------------------------------------------------

test "StreamingAggregator: end-to-end reasoning delta + output delta + terminal completed with reasoning output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Simulate reasoning delta
    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"thinking step 1 \"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"thinking step 2\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Simulate output delta
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"final answer here\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Simulate terminal completed with reasoning output (id + encrypted_content + summary)
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_e2e_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thinking step 1 thinking step 2\"}],\"encrypted_content\":\"ENC_E2E_DATA\"},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"final answer here\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try testing.expectEqualStrings("rs_e2e_123", chunk.?.reasoning_id.?);
        try testing.expectEqualStrings("ENC_E2E_DATA", chunk.?.reasoning_encrypted_content.?);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    // Delta reasoning wins over summary fallback
    try testing.expectEqualStrings("thinking step 1 thinking step 2", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_e2e_123", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_E2E_DATA", res.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("final answer here", res.content.?);
    try testing.expectEqual(@as(?FinishReason, .stop), res.finish_reason);
}

test "StreamingAggregator: end-to-end terminal summary fallback when no delta reasoning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    // Only output delta, no reasoning delta
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"answer only\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    // Terminal with reasoning summary but no prior delta
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_fallback_e2e\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"fallback thinking\"}],\"encrypted_content\":\"ENC_FB_E2E\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    try testing.expectEqualStrings("fallback thinking", res.reasoning_content.?);
    try testing.expectEqualStrings("rs_fallback_e2e", res.reasoning_id.?);
    try testing.expectEqualStrings("ENC_FB_E2E", res.reasoning_encrypted_content.?);
    try testing.expectEqualStrings("answer only", res.content.?);
}

test "StreamingAggregator: end-to-end DB round-trip simulation via builder replay" {
    // Simulate: aggregator finalizes -> CallResponse -> AgentMessage -> builder replay
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    var agg = StreamingAggregator.init(arena.allocator());
    defer agg.deinit();

    {
        const data = "{\"type\":\"response.reasoning_text.delta\",\"delta\":\"db thinking\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data = "{\"type\":\"response.output_text.delta\",\"delta\":\"db answer\"}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }
    {
        const data =
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_db_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"db thinking\"}],\"encrypted_content\":\"ENC_DB_1\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
        const chunk = a.parse_stream_chunk(data, arena.allocator());
        try testing.expect(chunk != null);
        try agg.process_chunk(chunk.?);
    }

    var res = try agg.finalize();
    defer res.deinit();

    // Simulate DB round-trip: CallResponse -> AgentMessage (as get_llm_histories would)
    const msg = AgentMessage{
        .role = .assistant,
        .content = res.content,
        .reasoning_content = res.reasoning_content,
        .reasoning_id = res.reasoning_id,
        .reasoning_encrypted_content = res.reasoning_encrypted_content,
        .tool_calls = null,
        .tool_call_id = null,
        .content_parts = null,
    };

    // Replay via builder: [user, assistant+reasoning] -> input[] with reasoning separate
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("original question"),
        msg,
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_db_1", input.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("ENC_DB_1", input.items[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("db thinking", input.items[1].object.get("summary").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("db answer", input.items[2].object.get("content").?.array.items[0].object.get("text").?.string);
    // reasoning must not leak into assistant output_text
    try testing.expect(!std.mem.eql(u8, input.items[2].object.get("content").?.array.items[0].object.get("text").?.string, "db thinking"));
}

test "buildJsonResponsesRequest: regression task_1788204837101_1 — reasoning_id+encrypted persisted even when reasoning_content is NULL" {
    // Real DB row from task_1788204837101_1 (2026-09-01 03:17:31): assistant:
    // content="Reasoning ID saved but content empty — tracing the summary
    // extraction." tool_calls=[bash call_01a05af8ce...],
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();

    const tc_id = try testing.allocator.dupe(u8, "call_01a05af8ce457620beb3a5990637e153");
    defer testing.allocator.free(tc_id);
    const tc_name = try testing.allocator.dupe(u8, "bash");
    defer testing.allocator.free(tc_name);
    const tc_args = try testing.allocator.dupe(u8, "{\"command\":\"timeout 10 git checkout main 2>&1 | tail -n 5\",\"cwd\":\"/home/ginwa/ginwaaitoolbox\"}");
    defer testing.allocator.free(tc_args);
    const tc_array = try testing.allocator.alloc(ToolCall, 1);
    defer testing.allocator.free(tc_array);
    tc_array[0] = .{ .id = tc_id, .function = .{ .name = tc_name, .arguments = tc_args } };

    const enc = try testing.allocator.dupe(u8, "Q-PaDgH1f_g4UMio3N6QC9OP42jJO2-WMTCEw6alywPh84L9_64jRusfZspFIeQI7UiYTDzLT6yAPOOfM_e-dMhNZtGD0rjNmMB8DnDBCRxws-8fYmo0BJf8oKM4ze5");
    defer testing.allocator.free(enc);
    const rid = try testing.allocator.dupe(u8, "rs_6a9643abdb33701b240b4ff4:rs_01a05af855327e6083af347abb5c682e");
    defer testing.allocator.free(rid);

    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("trace the summary"),
        .{
            .role = .assistant,
            .content = "Reasoning ID saved but content empty \u{2014} tracing the summary extraction.",
            .reasoning_content = null,
            .reasoning_id = rid,
            .reasoning_encrypted_content = enc,
            .tool_calls = tc_array,
            .tool_call_id = null,
            .content_parts = null,
        },
        .{
            .role = .tool,
            .content = "{\"tool\":\"bash\",\"parameters\":{\"command\":\"timeout 10 git checkout main\"},\"success\":true,\"data\":{\"command\":\"timeout 10 git checkout main\",\"stdout\":\"Already on 'main'\",\"stderr\":\"\",\"exit_code\":0,\"truncated\":false,\"timeout\":false,\"stdout_lines\":1,\"stderr_lines\":0},\"error\":null,\"v\":1}",
            .tool_call_id = "call_01a05af8ce457620beb3a5990637e153",
            .tool_calls = null,
            .content_parts = null,
            .reasoning_content = null,
        },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    // Expected: [user, reasoning(with id+enc, no summary), assistant message, function_call, function_call_output]
    try testing.expectEqual(@as(usize, 5), input.items.len);

    // input[0] = user
    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);

    // input[1] = reasoning — must exist even though reasoning_content was NULL
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_6a9643abdb33701b240b4ff4:rs_01a05af855327e6083af347abb5c682e", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("Q-PaDgH1f_g4UMio3N6QC9OP42jJO2-WMTCEw6alywPh84L9_64jRusfZspFIeQI7UiYTDzLT6yAPOOfM_e-dMhNZtGD0rjNmMB8DnDBCRxws-8fYmo0BJf8oKM4ze5", reasoning.object.get("encrypted_content").?.string);
    // summary must be present as empty array when reasoning_content is NULL —
    // the upstream schema requires the field (omitting it → `missing required field summary`)
    try testing.expect(reasoning.object.get("summary") != null);
    try testing.expectEqual(@as(usize, 0), reasoning.object.get("summary").?.array.items.len);

    // input[2] = assistant message with original content, must NOT contain reasoning
    const assistant = input.items[2];
    try testing.expectEqualStrings("message", assistant.object.get("type").?.string);
    try testing.expectEqualStrings("assistant", assistant.object.get("role").?.string);
    try testing.expectEqualStrings("Reasoning ID saved but content empty \u{2014} tracing the summary extraction.", assistant.object.get("content").?.array.items[0].object.get("text").?.string);

    // input[3] = function_call
    try testing.expectEqualStrings("function_call", input.items[3].object.get("type").?.string);
    try testing.expectEqualStrings("call_01a05af8ce457620beb3a5990637e153", input.items[3].object.get("call_id").?.string);

    // input[4] = function_call_output
    try testing.expectEqualStrings("function_call_output", input.items[4].object.get("type").?.string);
    try testing.expectEqualStrings("call_01a05af8ce457620beb3a5990637e153", input.items[4].object.get("call_id").?.string);
}

test "buildJsonResponsesRequest: reasoning with id but no content emits empty summary array" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        assistantMsgFullOpenaiResponses(null, null, "rs_only_id", "ENC_ONLY"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);
    const input = body.parsed.value.object.get("input").?.array;
    // user + reasoning (id+enc, empty summary array, no message) — provider requires summary field
    try testing.expectEqual(@as(usize, 2), input.items.len);
    const reasoning = input.items[1];
    try testing.expectEqualStrings("reasoning", reasoning.object.get("type").?.string);
    try testing.expectEqualStrings("rs_only_id", reasoning.object.get("id").?.string);
    try testing.expectEqualStrings("ENC_ONLY", reasoning.object.get("encrypted_content").?.string);
    try testing.expect(reasoning.object.get("summary") != null);
    try testing.expectEqual(@as(usize, 0), reasoning.object.get("summary").?.array.items.len);
    // raw must contain empty summary array (field present)
    try testing.expect(std.mem.indexOf(u8, body.raw, "\"summary\":[]") != null);
}

test "parse_responses_stream_chunk: response.reasoning_summary_text.done captures reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.reasoning_summary_text.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"text\":\"final summary via done\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("final summary via done", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.reasoning_summary_part.added captures reasoning_content" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"part added text\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("part added text", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: response.output_item.done reasoning captures id/enc/summary" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_done_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"done summary\"}],\"encrypted_content\":\"ENC_DONE\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("done summary", chunk.?.reasoning_content.?);
    try testing.expectEqualStrings("rs_done_1", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC_DONE", chunk.?.reasoning_encrypted_content.?);
}

test "parse_responses_stream_chunk: response.output_item.done reasoning without summary still captures id/enc" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_done_2\",\"summary\":[],\"encrypted_content\":\"ENC2\"}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_done_2", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("ENC2", chunk.?.reasoning_encrypted_content.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

// ---------------------------------------------------------------------------
// Spec cases from OpenAI JSON response — output[] handling (user-provided)
// ---------------------------------------------------------------------------

test "parse_responses_stream_chunk: case 1 normal answer — no reasoning item" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 2 reasoning with empty summary" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_content == null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 3 reasoning with summary + answer" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_123\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"The calculation requires adding 2 and 2.\"}]},{\"type\":\"message\",\"id\":\"msg_123\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"2 + 2 = 4.\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqualStrings("rs_123", chunk.?.reasoning_id.?);
    try testing.expectEqualStrings("The calculation requires adding 2 and 2.", chunk.?.reasoning_content.?);
}

test "parse_responses_stream_chunk: case 4 multiple reasoning items — iterates output[], does not assume [0]/[1]" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_001\",\"summary\":[]},{\"type\":\"reasoning\",\"id\":\"rs_002\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_001\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The answer is 42.\"}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    // parser keeps first id (current single-row model) but must not misinterpret indices
    try testing.expectEqualStrings("rs_001", chunk.?.reasoning_id.?);
    try testing.expect(chunk.?.reasoning_content == null);
}

test "parse_responses_stream_chunk: case 5 tool call" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Jakarta\\\"}\"}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expectEqual(@as(?FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 6 reasoning + tool_call and reasoning + answer are two separate responses" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data1 = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_001\",\"summary\":[]},{\"type\":\"function_call\",\"id\":\"fc_001\",\"call_id\":\"call_001\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Jakarta\\\"}\"}]}}";
    const c1 = a.parse_stream_chunk(data1, arena.allocator());
    try testing.expect(c1 != null);
    try testing.expectEqualStrings("rs_001", c1.?.reasoning_id.?);
    try testing.expectEqual(@as(?FinishReason, .tool_calls), c1.?.finish_reason);
    const data2 = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_002\",\"summary\":[]},{\"type\":\"message\",\"id\":\"msg_001\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Jakarta is currently 30°C.\"}]}]}}";
    const c2 = a.parse_stream_chunk(data2, arena.allocator());
    try testing.expect(c2 != null);
    try testing.expectEqualStrings("rs_002", c2.?.reasoning_id.?);
    try testing.expectEqual(@as(?FinishReason, .stop), c2.?.finish_reason);
}

test "parse_responses_stream_chunk: case 7 multiple content parts in one message — don't assume content[0]" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Here is the result:\"},{\"type\":\"output_text\",\"text\":\"2 + 2 = 4.\"}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_responses_stream_chunk: case 8 message containing annotations" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"According to the source, the answer is 42.\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.com\",\"title\":\"Example\"}]}]}]}}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try testing.expect(chunk != null);
    try testing.expect(chunk.?.reasoning_id == null);
    try testing.expectEqual(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "buildJsonResponsesRequest: case 2 reasoning empty summary replays as reasoning+message" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q"),
        assistantMsgFullOpenaiResponses("The answer is 4.", null, "rs_123", null),
    };
    // reasoning_content null but id present -> should still emit reasoning with empty summary
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);
    const input = body.parsed.value.object.get("input").?.array;
    try testing.expectEqual(@as(usize, 3), input.items.len);
    try testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("reasoning", input.items[1].object.get("type").?.string);
    try testing.expectEqualStrings("rs_123", input.items[1].object.get("id").?.string);
    try testing.expectEqual(@as(usize, 0), input.items[1].object.get("summary").?.array.items.len);
    try testing.expectEqualStrings("message", input.items[2].object.get("type").?.string);
}

test "buildJsonResponsesRequest: iterates output — not output[0] reasoning assumption" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    // Simulate history with two reasoning turns collapsed into one row — builder emits one reasoning per row
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("q"),
        assistantMsgFullOpenaiResponses("a", "summary text", "rs_123", "ENC"),
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);
    const input = body.parsed.value.object.get("input").?.array;
    // Must handle reasoning at any index, not fixed positions
    var found_reasoning = false;
    var found_message = false;
    for (input.items) |it| {
        const t = it.object.get("type").?.string;
        if (std.mem.eql(u8, t, "reasoning")) found_reasoning = true;
        if (std.mem.eql(u8, t, "message")) {
            if (it.object.get("role")) |r| {
                if (std.mem.eql(u8, r.string, "assistant")) found_message = true;
            }
        }
    }
    try testing.expect(found_reasoning);
    try testing.expect(found_message);
}

// ---------------------------------------------------------------------------
// Builder: function_call_output sanitization (input[N].output[M] rejection)
// ---------------------------------------------------------------------------

test "buildJsonResponsesRequest: tool output with invalid UTF-8 is sanitized" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    // ELF magic + invalid bytes, mimicking `cat` of a binary in tool stdout.
    const raw_output = "\x7fELF\x02\x01\x01\x00\xFF\xFEbinary\x80\x81done";
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{ .role = .tool, .content = raw_output, .tool_call_id = "call_elf", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    var found = false;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        found = true;
        const out = it.object.get("output").?.string;
        // Raw invalid bytes must be gone; U+FFFD (EF BF BD) marks each one.
        try testing.expect(std.mem.indexOf(u8, out, "\xFF") == null);
        try testing.expect(std.mem.indexOf(u8, out, "\x80") == null);
        try testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
        // Body itself must be valid UTF-8 so the gateway can parse it.
        try testing.expect(std.unicode.utf8ValidateSlice(body.raw));
    }
    try testing.expect(found);
}

test "buildJsonResponsesRequest: tool without call_id is skipped, not emitted empty" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{ .role = .tool, .content = "orphan output", .tool_call_id = null, .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        const cid = it.object.get("call_id").?.string;
        // An empty call_id can never pair with a function_call — must not be sent.
        try testing.expect(cid.len > 0);
    }
}

test "buildJsonResponsesRequest: oversize tool output is truncated with marker" {
    var a = makeResponsesAgentOpenaiResponses(.{});
    defer a.deinit();
    const big = try testing.allocator.alloc(u8, 25_000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const messages = [_]AgentMessage{
        userMsgOpenaiResponses("hi"),
        .{ .role = .tool, .content = big, .tool_call_id = "call_big", .tool_calls = null, .content_parts = null, .reasoning_content = null },
    };
    var body = try buildAndParseOpenaiResponses(&a, &messages, &.{}, null, null, true);
    defer freeBodyOpenaiResponses(body);

    const input = body.parsed.value.object.get("input").?.array;
    var found = false;
    for (input.items) |it| {
        if (!std.mem.eql(u8, it.object.get("type").?.string, "function_call_output")) continue;
        found = true;
        const out = it.object.get("output").?.string;
        try testing.expect(out.len < big.len);
        try testing.expect(std.mem.indexOf(u8, out, "[truncated") != null);
    }
    try testing.expect(found);
}

// ===== Tests merged from parse_anthropic_sse_test.zig (2026-09-29 flatten)
// ===== Tests for the Anthropic /v1/messages SSE parser + the raw-SSE sample
// capture added to Agent.callStreaming.

const expectParseAnthropicSse = std.testing.expect;
const expectEqualParseAnthropicSse = std.testing.expectEqual;
const expectErrorParseAnthropicSse = std.testing.expectError;
const expectEqualStringsParseAnthropicSse = std.testing.expectEqualStrings;
const testing_allocatorParseAnthropicSse = std.testing.allocator;

// ===== Regression test for 2026-08-15 "bash tool leak" =============== The
// user posted a leaked tool_call record with a bash `arguments` payload of
// literally `$'\xaa\xaa\xaa...'` (22 bytes of 0xAA — Zig's DebugAllocator
test "CallResponse arena ownership: tool_call.function.arguments points at caller's arena (no .deinit needed)" {
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var agg = StreamingAggregator.init(arena_alloc);
    defer agg.deinit();

    // Stage 1: content_block_start arrives with id + name.
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]ToolCallDelta{.{
            .index = 0,
            .id = "toolu_leak_test",
            .function_name = "bash",
        }},
    });

    // Stage 2: two input_json_delta chunks concatenate to the bash arguments
    // JSON.
    const args_payload =
        \\{"command":"cd /tmp && echo hello","cwd":"/tmp"}
    ;
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]ToolCallDelta{.{
            .index = 0,
            .function_arguments = args_payload[0..20],
        }},
    });
    try agg.process_chunk(.{
        .tool_calls_delta = &[_]ToolCallDelta{.{
            .index = 0,
            .function_arguments = args_payload[20..],
        }},
    });

    const response = try agg.finalize();
    defer response.deinit();

    try expectParseAnthropicSse(response.tool_calls != null);
    try expectEqualParseAnthropicSse(@as(usize, 1), response.tool_calls.?.len);
    const tc = &response.tool_calls.?[0];
    try expectEqualStringsParseAnthropicSse("toolu_leak_test", tc.id);
    try expectEqualStringsParseAnthropicSse("bash", tc.function.name);

    // CRITICAL: `tc.function.arguments` points at the same arena memory the
    // aggregator's internal `arguments` ArrayList holds.
    try expectEqualStringsParseAnthropicSse(args_payload, tc.function.arguments);

    // Belt-and-suspenders: pin the contract by asserting no
    // `0xAA` byte appears in the returned slice. Legitimate
    // ASCII/UTF-8/JSON cannot contain this byte.
    try expectParseAnthropicSse(std.mem.indexOfScalar(u8, tc.function.arguments, 0xAA) == null);
}

// ===================================================================

// ============================================================================
// Part B — parse_stream_chunk for Anthropic SSE
// ============================================================================

test "parse_stream_chunk (anthropic): message_start caches input_tokens, emits no chunk" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    const data =
        \\{"type":"message_start","message":{"id":"msg_x","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":42,"output_tokens":1}}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const chunk = a.parse_stream_chunk(data, arena.allocator());
    // message_start is a pure cache step — no chunk emitted.
    try expectParseAnthropicSse(chunk == null);
}

test "parse_stream_chunk (anthropic): content_block_delta text_delta populates content" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // First emit a message_start so the input_tokens cache gets populated.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    var arena2 = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena2.deinit();

    const delta_data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello world"}}
    ;
    const chunk = a.parse_stream_chunk(delta_data, arena2.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualStringsParseAnthropicSse("Hello world", chunk.?.content.?);
    try expectParseAnthropicSse(chunk.?.tool_calls_delta == null);
    try expectParseAnthropicSse(chunk.?.finish_reason == null);
}

test "parse_stream_chunk (anthropic): thinking_delta populates reasoning_content" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"step 1"}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualStringsParseAnthropicSse("step 1", chunk.?.reasoning_content.?);
}

test "parse_stream_chunk (anthropic): content_block_start (tool_use) emits tool_calls_delta with id+name" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"bash","input":{}}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.tool_calls_delta != null);
    try expectEqualParseAnthropicSse(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try expectEqualStringsParseAnthropicSse("toolu_abc", chunk.?.tool_calls_delta.?[0].id.?);
    try expectEqualStringsParseAnthropicSse("bash", chunk.?.tool_calls_delta.?[0].function_name.?);
}

test "parse_stream_chunk (anthropic): input_json_delta appends to tool_calls_delta arguments" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.tool_calls_delta != null);
    try expectEqualParseAnthropicSse(@as(usize, 1), chunk.?.tool_calls_delta.?.len);
    try expectEqualStringsParseAnthropicSse("{\"command\":\"ls\"}", chunk.?.tool_calls_delta.?[0].function_arguments.?);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=end_turn → finish_reason=.stop" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualParseAnthropicSse(@as(?FinishReason, .stop), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=tool_use → finish_reason=.tool_calls" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualParseAnthropicSse(@as(?FinishReason, .tool_calls), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=max_tokens → finish_reason=.length" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualParseAnthropicSse(@as(?FinishReason, .length), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_delta stop_reason=refusal → finish_reason=.content_filter" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualParseAnthropicSse(@as(?FinishReason, .content_filter), chunk.?.finish_reason);
}

test "parse_stream_chunk (anthropic): message_stop returns null (signal-only)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data = "{\"type\":\"message_stop\"}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk == null);
}

test "parse_stream_chunk (anthropic): content_block_stop returns null (signal-only)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data = "{\"type\":\"content_block_stop\",\"index\":0}";
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk == null);
}

test "parse_stream_chunk (anthropic): usage chunk emitted on first delta after message_start with input_tokens" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // Cache input_tokens via message_start.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":7,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta should carry a usage chunk with prompt_tokens=7.
    var arena2 = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena2.deinit();

    const delta_data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}
    ;
    const chunk = a.parse_stream_chunk(delta_data, arena2.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 7), chunk.?.usage.?.prompt_tokens);
}

test "parse_stream_chunk (anthropic): usage emitted exactly once across multiple deltas" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // Cache input_tokens via message_start.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta → usage chunk present.
    var arena1 = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena1.deinit();
    const d1 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a"}}
    ;
    const c1 = a.parse_stream_chunk(d1, arena1.allocator());
    try expectParseAnthropicSse(c1 != null);
    try expectParseAnthropicSse(c1.?.usage != null);

    // Second delta → no usage chunk (already emitted).
    var arena2 = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena2.deinit();
    const d2 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"b"}}
    ;
    const c2 = a.parse_stream_chunk(d2, arena2.allocator());
    try expectParseAnthropicSse(c2 != null);
    try expectParseAnthropicSse(c2.?.usage == null);
}

// ============================================================================
// Anthropic usage handling — make total_tokens match OpenAI's semantic
// (prompt_tokens + completion_tokens) so llm_history / compaction code that

test "parse_stream_chunk (anthropic): message_delta usage emits total = input + output (strict API shape — no input in message_delta)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start caches input_tokens=42 (canonical input — strict API).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":42,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta with ONLY output_tokens (strict Anthropic API doesn't
    // repeat input_tokens here). prompt must stay 42 (from message_start),
    // total = 42 + 7.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":7}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 42), chunk.?.usage.?.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 7), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 49), chunk.?.usage.?.total_tokens);
}

test "parse_stream_chunk (anthropic): message_delta input_tokens OVERRIDES message_start (some relays send input=0 at message_start then correct value at message_delta)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start with input_tokens=0 (this relay returns 0 here).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta with the AUTHORITATIVE input_tokens=54 (this relay).
    // The handler must prefer this over the cached 0 from message_start.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":54,"output_tokens":23}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 54), chunk.?.usage.?.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 23), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 77), chunk.?.usage.?.total_tokens);
}

test "parse_stream_chunk (anthropic): message_delta includes cache_creation_input_tokens in total (cache writes ARE billable)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=10 (excludes cache_creation).
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: cache_creation_input_tokens=5 (a cache write — billable).
    // billable total = 10 (input) + 5 (cache_creation) + 8 (output) = 23.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"cache_creation_input_tokens":5,"output_tokens":8}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 15), chunk.?.usage.?.prompt_tokens); // 10 + 5
    try expectEqualParseAnthropicSse(@as(usize, 8), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 23), chunk.?.usage.?.total_tokens); // 15 + 8
}

test "parse_stream_chunk (anthropic): cache_read_input_tokens IS added to prompt + total (cache reads ARE tokens processed)" {
    // Mirrors the spec TL;DR: cache_read counts as tokens the model
    // processed, so prompt = input + cache_read and total = prompt +
    // completion.
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=54, cache_read_input_tokens=128.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":54,"cache_read_input_tokens":128,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: input_tokens=54 + cache_creation=0 + cache_read=128
    // (uses cached message_start value because delta omits it)
    // + output_tokens=23.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":54,"output_tokens":23}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 182), chunk.?.usage.?.prompt_tokens); // 54 + 0 + 128
    try expectEqualParseAnthropicSse(@as(usize, 23), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 205), chunk.?.usage.?.total_tokens); // 182 + 23
    try expectEqualParseAnthropicSse(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 128), chunk.?.usage.?.cache_read_input_tokens);
}

// ============================================================================
// Task 1 contract — Agent.Usage struct surface area.

test "Agent.Usage struct has cache_creation_input_tokens + cache_read_input_tokens fields (structural contract)" {
    const u: Usage = .{};
    // New fields default to 0 — no breakage for OpenAI.
    try expectEqualParseAnthropicSse(@as(usize, 0), u.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), u.cache_read_input_tokens);
    // Existing fields still work.
    try expectEqualParseAnthropicSse(@as(usize, 0), u.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), u.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), u.total_tokens);
}

test "Agent.Usage can be constructed with explicit cache values" {
    // Mirrors what parse_anthropic_stream_chunk emits at message_delta
    // when both cache fields are non-zero.
    const u: Usage = .{
        .prompt_tokens = 6500,
        .completion_tokens = 1000,
        .total_tokens = 7500,
        .cache_creation_input_tokens = 500,
        .cache_read_input_tokens = 5000,
    };
    try expectEqualParseAnthropicSse(@as(usize, 6500), u.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 1000), u.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 7500), u.total_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 500), u.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 5000), u.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): message_delta includes BOTH cache_creation AND cache_read in prompt + total" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start caches input_tokens=1000.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1000,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // message_delta: cache_creation=500, cache_read=5000, output=1000.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":5000,"output_tokens":1000}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 6500), chunk.?.usage.?.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 1000), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 7500), chunk.?.usage.?.total_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 500), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 5000), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): cache_read_only is included in prompt + total" {
    // Cache reads ONLY (no cache writes) — prompt = input + cache_read.
    // Pre-fix this would have been `prompt = input = 10`, dropping the
    // 128 cached-read tokens on the floor.
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const data =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":10,"cache_read_input_tokens":128,"output_tokens":7}}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 138), chunk.?.usage.?.prompt_tokens); // 10 + 128
    try expectEqualParseAnthropicSse(@as(usize, 7), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 145), chunk.?.usage.?.total_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 128), chunk.?.usage.?.cache_read_input_tokens);
}

test "parse_stream_chunk (anthropic): cache_read from message_start is preserved on first-delta usage chunk" {
    // Some relays send cache_read_input_tokens at message_start but not at
    // message_delta. The first-delta usage chunk needs to fold that into
    // prompt_tokens, mirroring how message_delta folds it later.
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "anthropic";

    // message_start: input_tokens=20 + cache_read_input_tokens=4096.
    {
        var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
        defer arena.deinit();
        const start_data =
            \\{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"c","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"cache_read_input_tokens":4096,"output_tokens":1}}}
        ;
        _ = a.parse_stream_chunk(start_data, arena.allocator());
    }

    // First delta emits a usage chunk. Prompt must be 20 + 0 + 4096 = 4116.
    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();
    const d1 =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}
    ;
    const chunk = a.parse_stream_chunk(d1, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectParseAnthropicSse(chunk.?.usage != null);
    try expectEqualParseAnthropicSse(@as(usize, 4116), chunk.?.usage.?.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), chunk.?.usage.?.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 4116), chunk.?.usage.?.total_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 0), chunk.?.usage.?.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 4096), chunk.?.usage.?.cache_read_input_tokens);
}

test "Agent.Usage can be constructed with explicit cache values (regression pin at end-of-file)" {
    // Pinned at the END of the test file (in addition to the canonical
    // assertion at L436) so the contract surfaces under `rg` near any
    // future Anthropic-Usage changes. Both must pass.
    const u: Usage = .{
        .prompt_tokens = 6500,
        .completion_tokens = 1000,
        .total_tokens = 7500,
        .cache_creation_input_tokens = 500,
        .cache_read_input_tokens = 5000,
    };
    try expectEqualParseAnthropicSse(@as(usize, 6500), u.prompt_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 1000), u.completion_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 7500), u.total_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 500), u.cache_creation_input_tokens);
    try expectEqualParseAnthropicSse(@as(usize, 5000), u.cache_read_input_tokens);
}

// ============================================================================
// Regression test — reproduce the iter-2 SEGV in buildJsonAnthropicRequest
// (the slice-header 0xAA-poisoning crash seen when an Anthropic chat hits

test "buildJsonAnthropicRequest: assistant message with tool_calls + null reasoning_content survives" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = true;
    a.userIdentifier = "test-user";

    // Simulate the DB-loaded shape for an assistant message that emitted
    // tool_calls in the previous iteration: reasoning_content is null,
    // content is empty, tool_calls_json has 1 tool call with id+name+args.
    const tc_args_json = "{\"query\":\"recent\"}";
    const tc_id_dup = try testing_allocatorParseAnthropicSse.dupe(u8, "toolu_test_123");
    defer testing_allocatorParseAnthropicSse.free(tc_id_dup);
    const tc_name_dup = try testing_allocatorParseAnthropicSse.dupe(u8, "load_memory");
    defer testing_allocatorParseAnthropicSse.free(tc_name_dup);
    const tc_args_dup = try testing_allocatorParseAnthropicSse.dupe(u8, tc_args_json);
    defer testing_allocatorParseAnthropicSse.free(tc_args_dup);
    const tc_array = try testing_allocatorParseAnthropicSse.alloc(ToolCall, 1);
    defer testing_allocatorParseAnthropicSse.free(tc_array);
    tc_array[0] = .{
        .id = tc_id_dup,
        .function = .{
            .name = tc_name_dup,
            .arguments = tc_args_dup,
        },
    };

    // 3 messages: system + user + assistant-with-tool-calls.
    // Mirrors what workflow.zig's buildMessages produces for the second
    // iteration of an Anthropic chat that emitted tool_calls in iter 1.
    const system_content = try testing_allocatorParseAnthropicSse.dupe(u8, "You are a coding agent.");
    defer testing_allocatorParseAnthropicSse.free(system_content);
    const user_content = try testing_allocatorParseAnthropicSse.dupe(u8, "please look up memory");
    defer testing_allocatorParseAnthropicSse.free(user_content);

    const messages = try testing_allocatorParseAnthropicSse.alloc(AgentMessage, 3);
    defer testing_allocatorParseAnthropicSse.free(messages);
    messages[0] = .{ .role = .system, .content = system_content };
    messages[1] = .{ .role = .user, .content = user_content };
    messages[2] = .{
        .role = .assistant,
        .content = "", // empty text content — model emitted only tool_calls
        .reasoning_content = null, // no thinking text emitted
        .tool_calls = tc_array,
    };

    const params = AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocatorParseAnthropicSse.free(body);

    // If we got here without a SEGV, the slice-pointer corruption didn't
    // happen for this synthetic input.
    try expectParseAnthropicSse(body.len > 100);
    try expectParseAnthropicSse(std.mem.startsWith(u8, body, "{"));
}

// ============================================================================
// Part C — Anthropic request body preserves `image_url` content_parts (smoke
// test 2026-08-13: "i cannot send image" with profile `url_style:

test "buildJsonAnthropicRequest: user message with image content_parts preserves the image URL" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;
    a.userIdentifier = "test-user";

    // Synthetic data: text + 1 image, mirroring what
    // `transformLLMHistoryToAgentMessage` produces from a DB row with
    // `image_urls` populated.
    const text_dup = try testing_allocatorParseAnthropicSse.dupe(u8, "ini gambar apa ?");
    defer testing_allocatorParseAnthropicSse.free(text_dup);
    const url_dup = try testing_allocatorParseAnthropicSse.dupe(
        u8,
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    );
    defer testing_allocatorParseAnthropicSse.free(url_dup);

    const parts = try testing_allocatorParseAnthropicSse.alloc(ContentPart, 2);
    defer testing_allocatorParseAnthropicSse.free(parts);
    parts[0] = .{
        .part_type = "text",
        .text = text_dup,
        .image_url = null,
    };
    parts[1] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocatorParseAnthropicSse.alloc(AgentMessage, 2);
    defer testing_allocatorParseAnthropicSse.free(messages);
    messages[0] = .{ .role = .system, .content = "You are a helpful assistant." };
    messages[1] = .{
        .role = .user,
        .content = null, // text lives in content_parts[0]
        .content_parts = parts,
    };

    const params = AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocatorParseAnthropicSse.free(body);

    // The body MUST include the user-attached image (otherwise the LLM — and
    // `api.minimax.io/anthropic` — sees an empty user message and replies "i
    // don't see an image").
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, url_dup) != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, text_dup) != null);

    // Sanity: the body's still valid JSON with the user message
    // emitted as `role: "user"`.
    try expectParseAnthropicSse(std.mem.startsWith(u8, body, "{"));
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

test "buildJsonAnthropicRequest: user message with ONLY image (no text) is preserved" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;

    const url_dup = try testing_allocatorParseAnthropicSse.dupe(
        u8,
        "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD",
    );
    defer testing_allocatorParseAnthropicSse.free(url_dup);

    const parts = try testing_allocatorParseAnthropicSse.alloc(ContentPart, 1);
    defer testing_allocatorParseAnthropicSse.free(parts);
    parts[0] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocatorParseAnthropicSse.alloc(AgentMessage, 2);
    defer testing_allocatorParseAnthropicSse.free(messages);
    messages[0] = .{ .role = .system, .content = "Helper." };
    messages[1] = .{
        .role = .user,
        .content = null,
        .content_parts = parts,
    };

    const params = AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocatorParseAnthropicSse.free(body);

    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, url_dup) != null);
}

test "buildJsonAnthropicRequest: user message with plain text (no image) still emits single-text content (regression)" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";
    a.thinkingEnabled = false;

    const content_dup = try testing_allocatorParseAnthropicSse.dupe(u8, "halo dunia");
    defer testing_allocatorParseAnthropicSse.free(content_dup);

    const messages = try testing_allocatorParseAnthropicSse.alloc(AgentMessage, 2);
    defer testing_allocatorParseAnthropicSse.free(messages);
    messages[0] = .{ .role = .system, .content = "Helper." };
    messages[1] = .{
        .role = .user,
        .content = content_dup,
        .content_parts = null,
    };

    const params = AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocatorParseAnthropicSse.free(body);

    // No images: `content` MUST serialize as a top-level string (the legacy
    // shape Anthropic accepts), not as an array.
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"content\":\"halo dunia\"") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"image\"") == null);
}

test "buildJsonAnthropicRequest: image content uses Anthropic-native source.url wrapper" {
    // The OpenAI wire format puts the data URL straight under `image_url: {
    // url: "data:..." }`; Anthropic wraps it under `source: { type: "url",
    // url: "data:..." }` inside an `image`-typed content block.
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.model = "claude-test";
    a.UrlStyle = "anthropic";

    const url_dup = try testing_allocatorParseAnthropicSse.dupe(u8, "data:image/png;base64,abc123");
    defer testing_allocatorParseAnthropicSse.free(url_dup);
    const parts = try testing_allocatorParseAnthropicSse.alloc(ContentPart, 1);
    defer testing_allocatorParseAnthropicSse.free(parts);
    parts[0] = .{
        .part_type = "image_url",
        .text = null,
        .image_url = .{ .url = url_dup, .detail = null },
    };

    const messages = try testing_allocatorParseAnthropicSse.alloc(AgentMessage, 1);
    defer testing_allocatorParseAnthropicSse.free(messages);
    messages[0] = .{
        .role = .user,
        .content = null,
        .content_parts = parts,
    };

    const params = AgentCall{ .messages = messages, .tools = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing_allocatorParseAnthropicSse.free(body);

    // The Anthropic-native wrapper: `"image"` block + `"source"` with
    // `"type":"url"`.
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"source\":{") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"url\"") != null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"url\":\"data:image/png;base64,abc123\"") != null);

    // And the OpenAI-style flat shape MUST NOT appear.
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"image_url\":") == null);
    try expectParseAnthropicSse(std.mem.indexOf(u8, body, "\"type\":\"image_url\"") == null);
}

// ============================================================================
// Part B — OpenAI parser is NOT affected by the dispatch (regression check)
// ============================================================================

test "parse_stream_chunk (openai): OpenAI-shaped data still parses as before" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    a.UrlStyle = "openai"; // explicit

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello"}}]}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualStringsParseAnthropicSse("hello", chunk.?.content.?);
}

test "parse_stream_chunk (default UrlStyle): falls through to OpenAI parser" {
    var a: Agent = .init(testing_allocatorParseAnthropicSse, std.testing.io);
    defer a.deinit();
    // Don't set UrlStyle — it's "" by default. Should behave like openai.

    var arena = std.heap.ArenaAllocator.init(testing_allocatorParseAnthropicSse);
    defer arena.deinit();

    const data =
        \\{"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"world"}}]}
    ;
    const chunk = a.parse_stream_chunk(data, arena.allocator());
    try expectParseAnthropicSse(chunk != null);
    try expectEqualStringsParseAnthropicSse("world", chunk.?.content.?);
}
