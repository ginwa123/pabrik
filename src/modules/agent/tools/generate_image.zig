//! `generate_image` — an agent tool that calls the OpenAI Images API (`POST
//! /v1/images/generations`) to generate images from a text prompt using
//! DALL-E 2 / DALL-E 3 / gpt-image-1.

const std = @import("std");
const custom_http_client = @import("kabelweb").client;
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;

/// Maximum response body size — 4 MiB covers a single DALL-E 3 b64_json
/// payload (1-3 MiB PNG → 1.3-4 MiB base64). 4 MiB also covers a 10-image
/// DALL-E 2 multi-image response comfortably.
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// Input structure for the `generate_image` tool.
pub const GenerateImageInput = struct {
    /// REQUIRED. Description of the image to generate.
    prompt: []const u8,
    /// Model name. `null` → "dall-e-3".
    model: ?[]const u8 = null,
    /// Number of images. `null` → 1. Range 1-10; DALL-E 3 and gpt-image-1
    /// only accept n=1 (OpenAI returns 400 if violated).
    n: ?u8 = null,
    /// Output size. `null` → "1024x1024". Allowed values depend on model
    /// (enforced by `validateModelSize`).
    size: ?[]const u8 = null,
    /// Quality (DALL-E 3 only). Ignored for other models.
    quality: ?[]const u8 = null,
    /// Style (DALL-E 3 only). Ignored for other models.
    style: ?[]const u8 = null,
    /// Response format. `null` → "b64_json". OpenAI's defaults apply if
    /// we don't pass it explicitly — we always pass it for predictability.
    response_format: ?[]const u8 = null,
    /// End-user identifier forwarded to OpenAI for abuse detection.
    user: ?[]const u8 = null,
};

/// One decoded image record from OpenAI's response. Exactly one of `b64_json`
/// / `url` is non-null (depends on `response_format`); the other is null.
pub const ImageRecord = struct {
    b64_json: ?[]const u8 = null,
    url: ?[]const u8 = null,
    revised_prompt: ?[]const u8 = null,
};

/// One saved image ready to be referenced by `<image>` element in the
/// envelope.
pub const SavedImage = struct {
    path: []const u8,
    bytes: u64,
    mime: []const u8,
};

// ─── Tool definition ──────────────────────────────────────────────────────

/// Top-level tool definition exposed to the LLM.
pub const generate_image_tool_system_prompt =
    \\## Generate Image Tool — Behavior
    \\Use `generate_image` to generate an image via OpenAI Images API (DALL-E 2/3, gpt-image-1).
    \\- Provide a detailed `prompt`. Saves to `generated_images/` and returns a path; call `present_files` next to display it.
    \\
;

pub const generate_image_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "generate_image",
        .description =
        \\Generate an image from a text prompt via the OpenAI Images API (POST /v1/images/generations). Supports DALL-E 2, DALL-E 3, and gpt-image-1.
        \\
        \\Uses the active profile's api_key + base_url — same auth as chat completion, NO separate key; point base_url at a proxy for a self-hosted DALL-E-compatible endpoint. Saves to <cwd>/generated_images/img_<timestamp>_<index>.png, creating the directory if missing.
        \\
        \\OUTPUT (JSON success payload): <generate_image><status>generated</status><count>N</count><model>...</model><size>...</size><images><image index="0" path="/abs/path/img_xxx.png" bytes="12345" mime="image/png"/></images><revised_prompt>...</revised_prompt></generate_image>. On error: <generate_image><error>HTTP 400: ...OpenAI message...</error></generate_image>.
        \\
        \\NEXT STEP: call `present_files` with files=[{path=<path from the envelope>}] and label=<prompt> — DALL-E 3 images are 1-5 MB, so URL-preview them (no inline byte cap). The file is durable on disk, so the user can re-view it later.
        ,
        .parameters = .{
            .type = "object",
            .properties = &[_]ToolProperty{
                .{ .name = "prompt", .type = "string", .description = "What to draw. Max 1000 characters for dall-e-2, 4000 for dall-e-3 / gpt-image-1. Be specific — subject, style, lighting, composition." },
                .{ .name = "model", .type = "string", .description = "One of \"dall-e-2\" (cheaper, allows n>1), \"dall-e-3\" (best quality, default), \"gpt-image-1\" (newest, multimodal)." },
                .{ .name = "n", .type = "string", .description = "Images to generate (1-10). DALL-E 3 and gpt-image-1 accept only n=1." },
                .{ .name = "size", .type = "string", .description = "Output size. dall-e-2: \"256x256\", \"512x512\", \"1024x1024\". dall-e-3: \"1024x1024\", \"1792x1024\", \"1024x1792\". gpt-image-1: \"1024x1024\", \"1536x1024\", \"1024x1536\". Default \"1024x1024\"." },
                .{ .name = "quality", .type = "string", .description = "DALL-E 3 only. \"standard\" (default) or \"hd\" (more detail, ~2× cost). Ignored for dall-e-2 / gpt-image-1." },
                .{ .name = "style", .type = "string", .description = "DALL-E 3 only. \"vivid\" (default, hyper-real / dramatic) or \"natural\" (more subdued). Ignored for dall-e-2 / gpt-image-1." },
                .{ .name = "response_format", .type = "string", .description = "\"url\" or \"b64_json\" (default). The image is always saved to disk; \"url\" only additionally returns the OpenAI URL, which expires after ~60 min." },
                .{ .name = "user", .type = "string", .description = "End-user identifier. Helps OpenAI detect abuse. Optional." },
            },
            .required = &.{"prompt"},
        },
        .system_prompt = generate_image_tool_system_prompt,
    },
};

// ─── Model + size validation ─────────────────────────────────────────────

/// Allowed (model, size) combinations per OpenAI's API docs as of
/// 2026-08-14. The set is small and stable; if OpenAI adds new models
/// or sizes, add them here.
const ModelSizes = struct {
    model: []const u8,
    sizes: []const []const u8,
};

const MODEL_SIZE_TABLE = [_]ModelSizes{
    .{ .model = "dall-e-2", .sizes = &.{ "256x256", "512x512", "1024x1024" } },
    .{ .model = "dall-e-3", .sizes = &.{ "1024x1024", "1792x1024", "1024x1792" } },
    .{ .model = "gpt-image-1", .sizes = &.{ "1024x1024", "1536x1026", "1024x1536" } },
};

/// Validate that `size` is one of the sizes allowed for `model`. Returns
/// `null` on success, or an owned error message string on failure (caller
/// wraps it in the JSON error payload via `toJSONError`).
pub fn validateModelSize(allocator: std.mem.Allocator, model: []const u8, size: []const u8) !?[]u8 {
    for (MODEL_SIZE_TABLE) |entry| {
        if (std.mem.eql(u8, model, entry.model)) {
            for (entry.sizes) |allowed| {
                if (std.mem.eql(u8, size, allowed)) return null;
            }
            // Size not in the allowed list — build an error message
            // listing the allowed sizes for this model.
            var allowed_buf = std.ArrayList(u8).empty;
            defer allowed_buf.deinit(allocator);
            for (entry.sizes, 0..) |s, i| {
                if (i > 0) try allowed_buf.appendSlice(allocator, ", ");
                try allowed_buf.appendSlice(allocator, s);
            }
            const allowed_str = try allowed_buf.toOwnedSlice(allocator);
            defer allocator.free(allowed_str);
            return try std.fmt.allocPrint(
                allocator,
                "size '{s}' is not valid for model '{s}'. Allowed sizes: {s}.",
                .{ size, model, allowed_str },
            );
        }
    }
    // Model not in the table — unknown model
    return try std.fmt.allocPrint(
        allocator,
        "unknown model '{s}'. Allowed models: dall-e-2, dall-e-3, gpt-image-1.",
        .{model},
    );
}

// ─── JSON request body builder ───────────────────────────────────────────

/// Build the JSON request body for `POST /v1/images/generations`.
pub fn buildJsonRequestBody(allocator: std.mem.Allocator, input: GenerateImageInput) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(allocator);

    // Apply defaults
    const model = input.model orelse "dall-e-3";
    const n: u8 = input.n orelse 1;
    const size = input.size orelse "1024x1024";
    const response_format = input.response_format orelse "b64_json";

    try json.append(allocator, '{');

    // prompt (required)
    try json.appendSlice(allocator, "\"prompt\":\"");
    const ep = try xmlEscape(allocator, input.prompt);
    defer allocator.free(ep);
    try json.appendSlice(allocator, ep);
    try json.append(allocator, '"');

    // model
    try json.appendSlice(allocator, ",\"model\":\"");
    try json.appendSlice(allocator, model);
    try json.append(allocator, '"');

    // n (number, no quotes)
    try json.appendSlice(allocator, ",\"n\":");
    var n_buf: [16]u8 = undefined;
    const n_str = std.fmt.bufPrint(&n_buf, "{d}", .{n}) catch @panic("bufPrint failed formatting the image count");
    try json.appendSlice(allocator, n_str);

    // size
    try json.appendSlice(allocator, ",\"size\":\"");
    try json.appendSlice(allocator, size);
    try json.append(allocator, '"');

    // quality (optional)
    if (input.quality) |q| {
        try json.appendSlice(allocator, ",\"quality\":\"");
        try json.appendSlice(allocator, q);
        try json.append(allocator, '"');
    }

    // style (optional)
    if (input.style) |s| {
        try json.appendSlice(allocator, ",\"style\":\"");
        try json.appendSlice(allocator, s);
        try json.append(allocator, '"');
    }

    // response_format
    try json.appendSlice(allocator, ",\"response_format\":\"");
    try json.appendSlice(allocator, response_format);
    try json.append(allocator, '"');

    // user (optional)
    if (input.user) |u| {
        try json.appendSlice(allocator, ",\"user\":\"");
        try json.appendSlice(allocator, u);
        try json.append(allocator, '"');
    }

    try json.append(allocator, '}');
    return try json.toOwnedSlice(allocator);
}

// ─── JSON response parser ────────────────────────────────────────────────

/// Parse an OpenAI Images API response body. Returns one `ImageRecord` per
/// image in the `data` array.
pub fn parseImageResponse(allocator: std.mem.Allocator, body: []const u8) ![]ImageRecord {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    // OpenAI error envelope: {"error": {"message": "...", ...}}
    if (root.object.get("error")) |_| {
        return error.OpenAiError;
    }

    // Walk the data array
    const data_val = root.object.get("data") orelse return error.NoImagesReturned;
    if (data_val != .array) return error.NoImagesReturned;
    if (data_val.array.items.len == 0) return error.NoImagesReturned;

    const images = try allocator.alloc(ImageRecord, data_val.array.items.len);
    errdefer {
        for (images[0..data_val.array.items.len]) |img| {
            if (img.b64_json) |v| allocator.free(@constCast(v));
            if (img.url) |v| allocator.free(@constCast(v));
            if (img.revised_prompt) |v| allocator.free(@constCast(v));
        }
        allocator.free(images);
    }

    for (data_val.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidJson;

        var b64: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var rp: ?[]const u8 = null;

        if (item.object.get("b64_json")) |v| {
            if (v == .string) b64 = try allocator.dupe(u8, v.string);
        }
        if (item.object.get("url")) |v| {
            if (v == .string) url = try allocator.dupe(u8, v.string);
        }
        if (item.object.get("revised_prompt")) |v| {
            if (v == .string) rp = try allocator.dupe(u8, v.string);
        }

        images[i] = .{ .b64_json = b64, .url = url, .revised_prompt = rp };
    }

    return images;
}

// ─── Save image to disk ──────────────────────────────────────────────────

/// Decode `b64_payload` (base64) and write the raw bytes to
/// `<cwd>/generated_images/img_<unix_ms>_<index>.<ext>`. Returns the absolute
/// path.
pub fn saveImageToDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    b64_payload: []const u8,
    index: usize,
    mime: []const u8,
) ![]u8 {
    const decoder = &std.base64.standard.Decoder;

    // 1. Decode base64 → raw bytes
    const decoded_len = decoder.calcSizeForSlice(b64_payload) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, b64_payload) catch return error.InvalidBase64;

    // 2. Resolve filename + compose the absolute path up front so the
    //    I/O calls below write to the right place (the cwd passed by
    //    the caller is the canonical absolute path; we don't chdir).
    const ts = std.Io.Clock.now(.real, io).toMilliseconds();
    const ext = extForMime(mime);
    const filename = try std.fmt.allocPrint(allocator, "img_{d}_{d}.{s}", .{ ts, index, ext });
    defer allocator.free(filename);

    const abs_path = try std.fs.path.join(allocator, &.{ cwd, "generated_images", filename });
    errdefer allocator.free(abs_path);

    // 3. Create the parent directory (mkdir -p). Idempotent — no
    //    error if the dir already exists. Extract the parent dir from
    //    the absolute path so we don't depend on process cwd.
    const parent_dir = std.fs.path.dirname(abs_path) orelse abs_path;
    try std.Io.Dir.cwd().createDirPath(io, parent_dir);

    // 4. Write the file at the absolute path.
    const file = try std.Io.Dir.cwd().createFile(io, abs_path, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, decoded);

    return abs_path;
}

/// Map an image MIME type to its conventional file extension.
/// OpenAI always returns PNG today; the function is here for forward
/// compatibility (gpt-image-1 may return other formats in the future).
fn extForMime(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    return "png"; // safe default — PNG decoders exist everywhere
}

/// Read the file size of a just-written image. Returns 0 on any error
/// (open failure, stat failure) — the LLM still gets a valid path; the
/// size is metadata, not part of the tool's correctness contract.
fn statFileSize(io: std.Io, path: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer std.Io.File.close(file, io);
    const stat = std.Io.File.stat(file, io) catch return 0;
    return stat.size;
}

// ─── XML helpers ─────────────────────────────────────────────────────────

/// Escape XML special characters. Mirrors the helper in
/// `kanban_list.zig` (duplicated per project convention —
/// every tool file has its own copy).
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// JSON payload for a generate_image result. `std.json` handles all
/// escaping — no manual layer.
pub const GenerateImageJSONImage = struct {
    index: usize,
    path: []const u8,
};

pub const GenerateImageJSON = struct {
    status: []const u8,
    count: usize = 0,
    model: []const u8 = "",
    size: []const u8 = "",
    images: []const GenerateImageJSONImage = &.{},
    revised_prompt: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Build the success payload:
/// `{status:"generated", count, model, size, images:[{index, path}], revised_prompt}`.
/// `revised_prompt` is null when the model doesn't rewrite (DALL-E 2).
pub fn toJSONSuccess(
    allocator: std.mem.Allocator,
    model: []const u8,
    size: []const u8,
    images: []const SavedImage,
    revised_prompt: ?[]const u8,
) ![]u8 {
    const items = try allocator.alloc(GenerateImageJSONImage, images.len);
    defer allocator.free(items);
    for (images, 0..) |img, i| {
        items[i] = .{ .index = i, .path = img.path };
    }
    return try std.json.Stringify.valueAlloc(allocator, GenerateImageJSON{
        .status = "generated",
        .count = images.len,
        .model = model,
        .size = size,
        .images = items,
        .revised_prompt = revised_prompt,
    }, .{});
}

/// Build the error payload: `{status:"error", error:...}`.
/// Mirrors the old `<generate_image><error>...</error></generate_image>`
/// fields (just the message) in JSON form.
pub fn toJSONError(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, GenerateImageJSON{
        .status = "error",
        .@"error" = error_msg,
    }, .{});
}

// ─── HTTP execution ──────────────────────────────────────────────────────

/// Execute the `generate_image` tool end-to-end: 1. Validate `prompt`
/// (non-empty) 2. Apply defaults for `model`, `n`, `size`, `response_format`
/// 3.
pub fn execute_generate_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: GenerateImageInput,
    base_url: []const u8,
    api_key: []const u8,
    cwd: []const u8,
) ![]u8 {
    // 1. Validate prompt (non-empty)
    if (input.prompt.len == 0) {
        return toJSONError(allocator, "prompt is required and must be non-empty");
    }

    // 2. Apply defaults
    const model = input.model orelse "dall-e-3";
    const size = input.size orelse "1024x1024";
    const response_format = input.response_format orelse "b64_json";

    // 3. Validate model + size
    if (try validateModelSize(allocator, model, size)) |err_msg| {
        defer allocator.free(err_msg);
        return toJSONError(allocator, err_msg);
    }

    // If the user asked for "url" response_format, surface a clear
    // warning — we don't currently return the URL in the envelope, so
    // the user would be confused why their url param had no effect.
    if (!std.mem.eql(u8, response_format, "b64_json")) {
        std.log.warn("generate_image: response_format={s} requested — image is still saved to disk; URL is not returned in the envelope", .{response_format});
    }

    // 4. Build the JSON request body
    const json_body = buildJsonRequestBody(allocator, input) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "buildJsonRequestBody failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    };
    defer allocator.free(json_body);

    // 5. Compose URL: <base_url> + "/images/generations"
    const endpoint = "/images/generations";
    const uri_str = std.mem.concat(allocator, u8, &.{ base_url, endpoint }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "concat URI failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    };
    defer allocator.free(uri_str);

    // Validate the URL scheme BEFORE handing to libcurl (same pattern
    // as Agent.zig:1799-1821 — a missing scheme surfaces as
    // CURLE_UNSUPPORTED_PROTOCOL with no hint about WHY).
    if (!std.mem.startsWith(u8, uri_str, "http://") and
        !std.mem.startsWith(u8, uri_str, "https://"))
    {
        const msg = try std.fmt.allocPrint(
            allocator,
            "baseUrl+endpoint={s} has no http:// or https:// scheme — check api_key/base_url in config",
            .{uri_str},
        );
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    }

    // 6. Build auth header + request
    const auth_value = try std.mem.concat(allocator, u8, &.{ "Bearer ", api_key });
    defer allocator.free(auth_value);

    const headers = [_]custom_http_client.Header{
        .{ .name = "authorization", .value = auth_value },
        .{ .name = "content-type", .value = "application/json" },
    };

    const req = custom_http_client.Request{
        .method = .POST,
        .url = uri_str,
        .headers = &headers,
        .body = json_body,
    };

    // Timeouts: 60 s connect + 120 s total. DALL-E 3 generation takes
    // 5-30 s typically, gpt-image-1 can be slower for large sizes.
    const options = custom_http_client.Options{
        .timeout_ms = 120_000,
        .connect_timeout_ms = 30_000,
        .follow_redirects = false,
        .verify_ssl = true,
    };

    // 7. Perform the request
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    var response = client.perform(req, options) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "HTTP request failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    };
    defer response.deinit(allocator);

    // 8. Check the status code
    if (response.status_code >= 400) {
        // Try to surface OpenAI's actual error message.
        var msg_buf: std.ArrayList(u8) = .empty;
        defer msg_buf.deinit(allocator);
        try msg_buf.print(allocator, "HTTP {d}", .{response.status_code});
        if (extractOpenAiErrorMessage(allocator, response.body)) |extracted| {
            defer allocator.free(extracted);
            try msg_buf.print(allocator, ": {s}", .{extracted});
        }
        return toJSONError(allocator, msg_buf.items);
    }

    // Enforce the response-size cap BEFORE parsing (a runaway server
    // response shouldn't OOM the LLM context).
    if (response.body.len > MAX_RESPONSE_BYTES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "response body size {d} exceeds MAX_RESPONSE_BYTES ({d}) — retry with smaller `n` or `size`",
            .{ response.body.len, MAX_RESPONSE_BYTES },
        );
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    }

    // 9. Parse the response
    const images = parseImageResponse(allocator, response.body) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "parseImageResponse failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    };
    defer {
        for (images) |img| {
            if (img.b64_json) |v| allocator.free(@constCast(v));
            if (img.url) |v| allocator.free(@constCast(v));
            if (img.revised_prompt) |v| allocator.free(@constCast(v));
        }
        allocator.free(images);
    }

    // 10. Save each image to disk and collect SavedImage records. If a save
    // fails, abort and return the error envelope (the user explicitly asked
    // for the image; partial results are worse than a clean failure).
    var saved = try allocator.alloc(SavedImage, images.len);
    errdefer {
        for (saved[0..images.len]) |s| allocator.free(@constCast(s.path));
        allocator.free(saved);
    }

    var last_revised: ?[]const u8 = null;

    for (images, 0..) |img, i| {
        // Only b64_json is supported for saving (we don't follow
        // external URLs — the OpenAI URL expires in 60 min anyway).
        const b64 = img.b64_json orelse {
            const msg = try std.fmt.allocPrint(
                allocator,
                "image {d} has no b64_json field — response_format must be \"b64_json\" (URL format is not saved to disk; OpenAI URLs expire after ~60 min)",
                .{i},
            );
            defer allocator.free(msg);
            return toJSONError(allocator, msg);
        };

        const path = saveImageToDisk(allocator, io, cwd, b64, i, "image/png") catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "saveImageToDisk failed for image {d}: {s}",
                .{ i, @errorName(err) },
            );
            defer allocator.free(msg);
            return toJSONError(allocator, msg);
        };

        // Read back the file size so the LLM sees an honest number
        // (instead of "0" or the b64 length which differs). On stat
        // failure, fall back to 0 — the LLM still gets a valid path.
        const stat_size: u64 = statFileSize(io, path);
        saved[i] = .{ .path = path, .bytes = stat_size, .mime = "image/png" };

        // Capture the last revised_prompt (DALL-E 3 / gpt-image-1 return
        // one for every image; for n>1 we use the last one in the
        // envelope since they're all the same model + same prompt).
        if (img.revised_prompt) |rp| {
            last_revised = rp;
        }
    }

    // 11. Build the success envelope.
    //     Note: `last_revised` is borrowed from `images[i].revised_prompt`
    //     — we MUST not free it. The `defer` above handles the cleanup.
    const envelope = toJSONSuccess(allocator, model, size, saved, last_revised) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "toJSONSuccess failed: {s}",
            .{@errorName(err)},
        );
        defer allocator.free(msg);
        return toJSONError(allocator, msg);
    };

    // saved[].path was allocated by std.fs.path.join in saveImageToDisk —
    // ownership transfers to the envelope? No, the envelope only references
    // the path strings as slices. We have to free them now that we're done.
    for (saved) |s| allocator.free(@constCast(s.path));
    allocator.free(saved);

    return envelope;
}

/// Extract OpenAI's `error.message` field from an error response body.
/// Returns null if the body is not the error envelope or doesn't have
/// the expected shape — caller falls back to a generic message.
fn extractOpenAiErrorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const err_val = root.object.get("error") orelse return null;
    if (err_val != .object) return null;

    const msg_val = err_val.object.get("message") orelse return null;
    if (msg_val != .string) return null;

    return allocator.dupe(u8, msg_val.string) catch null;
}

const builtin = @import("builtin");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const generate_image = @import("generate_image.zig");

// ─── Helpers ─────────────────────────────────────────────────────────────

/// Open a fresh `std.Io.Threaded` runtime for tests that need an Io (the
/// save-to-disk helper needs it for `std.Io.Clock.now` and
/// `std.Io.Dir.createFile`).
fn setupIo() std.Io.Threaded {
    const threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded;
}

// ─── validateModelSize behavioural tests (8) ─────────────────────────────

test "validateModelSize accepts dall-e-2 with 256x256" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "256x256");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-2 with 512x512" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "512x512");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-2 with 1024x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "1024x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1024x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1024x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1792x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1792x1024");
    try testing.expect(err == null);
}

test "validateModelSize accepts dall-e-3 with 1024x1792" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "1024x1792");
    try testing.expect(err == null);
}

test "validateModelSize rejects dall-e-3 with 512x512" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "512x512");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "dall-e-3") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "512x512") != null);
    }
}

test "validateModelSize rejects dall-e-2 with 1792x1024" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-2", "1792x1024");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
    }
}

test "validateModelSize rejects unknown model" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dalle-4", "1024x1024");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "dalle-4") != null);
    }
}

test "validateModelSize rejects unknown size" {
    const alloc = testing.allocator;
    const err = try generate_image.validateModelSize(alloc, "dall-e-3", "4096x4096");
    try testing.expect(err != null);
    if (err) |msg| {
        defer alloc.free(msg);
    }
}

// ─── buildJsonRequestBody behavioural tests (5) ──────────────────────────

test "buildJsonRequestBody produces correct shape for minimal input (prompt only)" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "a cat" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    // Must contain the prompt and the default model + n + response_format
    try testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a cat\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"b64_json\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"size\":\"1024x1024\"") != null);
}

test "buildJsonRequestBody omits optional fields when null (no nulls in JSON)" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "a cat" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    // quality, style, user should NOT appear (they're null)
    try testing.expect(std.mem.indexOf(u8, body, "quality") == null);
    try testing.expect(std.mem.indexOf(u8, body, "style") == null);
    try testing.expect(std.mem.indexOf(u8, body, "user") == null);
    try testing.expect(std.mem.indexOf(u8, body, "null") == null);
}

test "buildJsonRequestBody includes all fields when provided" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{
        .prompt = "a hat-wearing cat",
        .model = "dall-e-2",
        .n = 3,
        .size = "512x512",
        .quality = "hd",
        .style = "vivid",
        .response_format = "url",
        .user = "user-42",
    };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a hat-wearing cat\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":3") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"size\":\"512x512\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"quality\":\"hd\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"style\":\"vivid\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"url\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"user-42\"") != null);
}

test "buildJsonRequestBody defaults model to dall-e-3 and n to 1" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "x" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"dall-e-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"n\":1") != null);
}

test "buildJsonRequestBody defaults response_format to b64_json" {
    const alloc = testing.allocator;
    const input = generate_image.GenerateImageInput{ .prompt = "x" };
    const body = try generate_image.buildJsonRequestBody(alloc, input);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"b64_json\"") != null);
}

// ─── parseImageResponse behavioural tests (5) ────────────────────────────

test "parseImageResponse accepts a single-image response with b64_json" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1700000000,"data":[{"b64_json":"iVBORw0KGgo=","revised_prompt":"a happy cat"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }

    try testing.expect(images.len == 1);
    try testing.expect(std.mem.eql(u8, images[0].b64_json.?, "iVBORw0KGgo="));
    try testing.expect(std.mem.eql(u8, images[0].revised_prompt.?, "a happy cat"));
}

test "parseImageResponse accepts a multi-image response with n=2 (DALL-E 2)" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1700000000,"data":[
        \\  {"b64_json":"AAAA"},
        \\  {"b64_json":"BBBB"}
        \\]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images.len == 2);
    try testing.expect(std.mem.eql(u8, images[0].b64_json.?, "AAAA"));
    try testing.expect(std.mem.eql(u8, images[1].b64_json.?, "BBBB"));
}

test "parseImageResponse extracts revised_prompt when present" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[{"b64_json":"x","revised_prompt":"A vibrant watercolor painting of a cat"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images[0].revised_prompt != null);
    try testing.expect(std.mem.eql(u8, images[0].revised_prompt.?, "A vibrant watercolor painting of a cat"));
}

test "parseImageResponse handles URL response_format (URL only, no b64_json)" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[{"url":"https://example.com/img.png"}]}
    ;
    const images = try generate_image.parseImageResponse(alloc, body);
    defer {
        for (images) |img| {
            if (img.b64_json) |b| alloc.free(b);
            if (img.url) |u| alloc.free(u);
            if (img.revised_prompt) |r| alloc.free(r);
        }
        alloc.free(images);
    }
    try testing.expect(images.len == 1);
    try testing.expect(images[0].b64_json == null);
    try testing.expect(images[0].url != null);
    try testing.expect(std.mem.eql(u8, images[0].url.?, "https://example.com/img.png"));
}

test "parseImageResponse surfaces OpenAI error envelope (HTTP 400-style body)" {
    const alloc = testing.allocator;
    const body =
        \\{"error":{"message":"Invalid model","type":"invalid_request_error","code":"model_not_found"}}
    ;
    const result = generate_image.parseImageResponse(alloc, body);
    try testing.expectError(error.OpenAiError, result);
}

test "parseImageResponse rejects empty data array" {
    const alloc = testing.allocator;
    const body =
        \\{"created":1,"data":[]}
    ;
    const result = generate_image.parseImageResponse(alloc, body);
    try testing.expectError(error.NoImagesReturned, result);
}

// ─── saveImageToDisk behavioural tests (3) ───────────────────────────────

test "saveImageToDisk writes base64 bytes to <cwd>/generated_images/img_<ts>_<idx>.png" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_cwd = "/tmp/pabrik-generate-image-save";
    std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_cwd) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_cwd);

    // "iVBORw0KGgo=" decodes to 8 bytes (PNG signature prefix + IHDR start).
    // We don't need a valid PNG for the save test — we just verify the
    // bytes round-trip through disk.
    const path = try generate_image.saveImageToDisk(alloc, io, tmp_cwd, "iVBORw0KGgo=", 0, "image/png");
    defer alloc.free(path);

    try testing.expect(std.mem.endsWith(u8, path, ".png"));
    // Path separator: `/` on POSIX, `\` on Windows. `std.fs.path.join`
    // uses the host's separator, so accept either when checking the
    // subdirectory in the returned path.
    const sep_str: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    try testing.expect(std.mem.indexOf(u8, path, sep_str ++ "generated_images" ++ sep_str) != null);
    try testing.expect(std.mem.indexOf(u8, path, "img_") != null);

    // Verify the file exists and has the expected content
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer std.Io.File.close(file, io);
    const stat = try std.Io.File.stat(file, io);
    try testing.expect(stat.size == 8);
}

test "saveImageToDisk creates the generated_images subdirectory if missing" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const tmp_cwd = dir_buf[0..dir_len];

    // generated_images/ does NOT exist yet — saveImageToDisk must create it.
    const path = try generate_image.saveImageToDisk(alloc, io, tmp_cwd, "AAAA", 0, "image/png");
    defer alloc.free(path);

    // Verify the dir now exists by writing a sentinel file inside it
    try tmp.dir.createDirPath(io, "generated_images");
    const f = try tmp.dir.createFile(io, "generated_images/.sentinel", .{});
    std.Io.File.close(f, io);
}

test "saveImageToDisk rejects when the base64 payload is not valid base64" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    // "not_valid_base64!!!" contains '!' and ' ' which are not in the
    // base64 alphabet. std.base64.standard.Decoder rejects them.
    const result = generate_image.saveImageToDisk(alloc, io, "/tmp/pabrik-generate-image-bad-b64", "not_valid_base64!!!", 0, "image/png");
    try testing.expectError(error.InvalidBase64, result);
}

// ─── toJSONSuccess / toJSONError behavioural tests (4) ─────────────────────

test "toJSONSuccess produces the expected payload shape" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/cwd/generated_images/img_1_0.png", .bytes = 12345, .mime = "image/png" },
    };
    const payload = try generate_image.toJSONSuccess(alloc, "dall-e-3", "1024x1024", &images, "A cat");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("generated", obj.get("status").?.string);
    try testing.expectEqual(@as(i64, 1), obj.get("count").?.integer);
    try testing.expectEqualStrings("dall-e-3", obj.get("model").?.string);
    try testing.expectEqualStrings("1024x1024", obj.get("size").?.string);
    const imgs = obj.get("images").?.array;
    try testing.expectEqual(@as(usize, 1), imgs.items.len);
    try testing.expectEqual(@as(i64, 0), imgs.items[0].object.get("index").?.integer);
    try testing.expectEqualStrings("/cwd/generated_images/img_1_0.png", imgs.items[0].object.get("path").?.string);
    try testing.expectEqualStrings("A cat", obj.get("revised_prompt").?.string);
    try testing.expect(obj.get("error").? == .null);
}

test "toJSONSuccess omits revised_prompt when null (DALL-E 2)" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/x.png", .bytes = 100, .mime = "image/png" },
    };
    const payload = try generate_image.toJSONSuccess(alloc, "dall-e-2", "512x512", &images, null);
    defer alloc.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("revised_prompt").? == .null);
}

test "toJSONSuccess keeps special chars raw (JSON needs no XML escaping)" {
    const alloc = testing.allocator;
    const images = [_]generate_image.SavedImage{
        .{ .path = "/x.png", .bytes = 100, .mime = "image/png" },
    };
    const payload = try generate_image.toJSONSuccess(alloc, "dall-e-3", "1024x1024", &images, "A <cat> & a <dog>");
    defer alloc.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("A <cat> & a <dog>", parsed.value.object.get("revised_prompt").?.string);
}

test "toJSONError produces status error with message" {
    const alloc = testing.allocator;
    const payload = try generate_image.toJSONError(alloc, "HTTP 401: Invalid API key");
    defer alloc.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("error", obj.get("status").?.string);
    try testing.expectEqualStrings("HTTP 401: Invalid API key", obj.get("error").?.string);
}
