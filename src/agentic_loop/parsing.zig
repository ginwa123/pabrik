const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const LLMHistory = @import("llm_history_row.zig").LLMHistory;
const args_repair = @import("../modules/agent/tools/tools_args_repair.zig");
const file_attachments = @import("file_attachments.zig");

const agent = pabrikcore.agent;
const json = std.json;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

pub fn transformLLMHistoryToAgentMessage(allocator: std.mem.Allocator, message: LLMHistory) ![]agent.AgentMessage {
    var messages: std.ArrayList(agent.AgentMessage) = .empty;

    const role = agent.Role.from_str(message.role) orelse .assistant;

    // Handle tool result messages (role == "tool") For tool messages, the
    // tools column contains the tool_call_id string directly.
    if (role == .tool) {
        const agentMessage = agent.AgentMessage{
            .id = try allocator.dupe(u8, message.id),
            .role = .tool,
            .content = try stripToolEnvelope(allocator, message.response_content),
            .tool_call_id = try allocator.dupe(u8, message.tool_call_id orelse ""),
        };
        try messages.append(allocator, agentMessage);

        // A provider refuses an image part on a tool message, so the picture
        // rides in a user message directly after it.
        if (message.image_urls) |urls| {
            if (urls.len > 0) try messages.append(allocator, try toolImageFollowUp(allocator, message.tool_name, urls));
        }
        return messages.toOwnedSlice(allocator);
    }

    // Handle assistant/user/system messages - always create a message if role
    // is valid (but not tool role which is handled above) const finishReason
    // = agent.FinishReason.from_str(message.finish_reason); const isToolCalls

    // For assistant/user/system roles, always create a message (even if content is empty)
    // Tool role is handled separately above
    if (role != .tool) {
        var tool_calls: ?[]agent.ToolCall = null;
        const toolSource = if (message.tool_calls_json.len > 0) message.tool_calls_json else message.response_content;
        const tcParsed = json.parseFromSlice(json.Value, allocator, toolSource, .{}) catch null;
        if (tcParsed) |tcp| {
            defer tcp.deinit();
            if (tcp.value == .array and tcp.value.array.items.len > 0) {
                var calls = try allocator.alloc(agent.ToolCall, tcp.value.array.items.len);
                for (tcp.value.array.items, 0..) |tc_item, i| {
                    if (tc_item == .object) {
                        const id_raw = if (tc_item.object.get("id")) |id_val| id_val.string else "";
                        const func_obj = if (tc_item.object.get("function")) |f| f.object else null;
                        const name_raw = if (func_obj) |fo| if (fo.get("name")) |n| n.string else "" else "";
                        // Normalize: empty/missing arguments → "{}" (valid JSON object)
                        var args_raw: []const u8 = "{}";
                        if (func_obj) |fo| {
                            if (fo.get("arguments")) |a| {
                                if (a.string.len > 0) args_raw = a.string;
                            }
                        }
                        // Repair before falling back to "{}".
                        var safe_owned: ?[]u8 = null;
                        const safe_args = blk: {
                            if (args_raw.len == 0) break :blk "{}";
                            const repaired = args_repair.repairToolCallArguments(allocator, args_raw) catch break :blk "{}";
                            if (repaired) |r| {
                                defer r.deinit(allocator);
                                safe_owned = try allocator.dupe(u8, r.slice());
                                break :blk safe_owned.?;
                            }
                            break :blk "{}";
                        };
                        calls[i] = .{
                            .id = try allocator.dupe(u8, id_raw),
                            .function = .{
                                .name = try allocator.dupe(u8, name_raw),
                                .arguments = try allocator.dupe(u8, safe_args),
                            },
                        };
                        if (safe_owned) |s| allocator.free(s);
                    } else {
                        calls[i] = .{
                            .id = try allocator.dupe(u8, ""),
                            .function = .{
                                .name = try allocator.dupe(u8, ""),
                                .arguments = try allocator.dupe(u8, "{}"),
                            },
                        };
                    }
                }
                tool_calls = calls;
            }
        }

        const content = try unwrapChatContent(allocator, message.response_content);
        const reasoning_content: ?[]const u8 = if (message.reasoning_content) |rc| try allocator.dupe(u8, rc) else null;
        const reasoning_id: ?[]const u8 = if (message.reasoning_id) |rid| try allocator.dupe(u8, rid) else null;
        const reasoning_encrypted_content: ?[]const u8 = if (message.reasoning_encrypted_content) |rec| try allocator.dupe(u8, rec) else null;

        // Handle vision + video + file support: if image_urls/video_urls or
        // file attachments are set, create content_parts with text, images,
        // videos and files.
        var stored_files: ?file_attachments.Stored = null;
        defer if (stored_files) |*s| s.deinit();
        if (message.file_attachments) |raw| {
            if (raw.len > 0) stored_files = try file_attachments.parseStored(allocator, raw);
        }
        const files: []const file_attachments.StoredFile = if (stored_files) |s| s.files else &.{};

        var content_parts: ?[]agent.ContentPart = null;
        const has_images = message.image_urls != null and message.image_urls.?.len > 0;
        const has_videos = message.video_urls != null and message.video_urls.?.len > 0;
        if (has_images or has_videos or files.len > 0) {
            const image_count = if (message.image_urls) |iums| iums.len else 0;
            const video_count = if (message.video_urls) |vums| vums.len else 0;
            const has_text = content.len > 0;
            const total_parts = image_count + video_count + files.len + (if (has_text) @as(usize, 1) else 0);
            var parts = try allocator.alloc(agent.ContentPart, total_parts);
            var part_idx: usize = 0;
            // Text part (first) if there's text content
            if (has_text) {
                parts[part_idx] = .{
                    .part_type = "text",
                    .text = content,
                    .image_url = null,
                    .video_url = null,
                    .file = null,
                };
                part_idx += 1;
            }
            // Image URL parts
            if (message.image_urls) |iums| {
                for (iums) |image_url| {
                    parts[part_idx] = .{
                        .part_type = "image_url",
                        .text = null,
                        .image_url = .{
                            .url = try allocator.dupe(u8, image_url),
                            .detail = null,
                        },
                        .video_url = null,
                        .file = null,
                    };
                    part_idx += 1;
                }
            }
            // Video URL parts (hard error downstream on unsupported model —
            // never silently dropped)
            if (message.video_urls) |vums| {
                for (vums) |video_url| {
                    parts[part_idx] = .{
                        .part_type = "video_url",
                        .text = null,
                        .image_url = null,
                        .video_url = .{
                            .url = try allocator.dupe(u8, video_url),
                        },
                        .file = null,
                    };
                    part_idx += 1;
                }
            }
            // File parts: a text-like document rides as text (every style
            // reads it), a binary one as a provider file part.
            for (files) |file| {
                if (file.text) |_| {
                    parts[part_idx] = .{
                        .part_type = "text",
                        .text = try file_attachments.textPart(allocator, file),
                        .image_url = null,
                        .video_url = null,
                        .file = null,
                    };
                } else {
                    parts[part_idx] = .{
                        .part_type = "file",
                        .text = null,
                        .image_url = null,
                        .video_url = null,
                        .file = .{
                            .filename = try allocator.dupe(u8, file.name),
                            .mime = try allocator.dupe(u8, file.mime),
                            .b64 = try allocator.dupe(u8, file.b64 orelse ""),
                        },
                    };
                }
                part_idx += 1;
            }
            content_parts = parts;
        } else {}

        const agentMessage = agent.AgentMessage{
            .id = try allocator.dupe(u8, message.id),
            .role = role,
            .content = if (content_parts != null) null else content,
            .content_parts = content_parts,
            .tool_calls = tool_calls,
            .reasoning_content = reasoning_content,
            .reasoning_id = reasoning_id,
            .reasoning_encrypted_content = reasoning_encrypted_content,
        };
        try messages.append(allocator, agentMessage);
    }

    return messages.toOwnedSlice(allocator);
}

/// The `user` message that carries a tool's images, so `read_file` on a
/// screenshot puts the screenshot in front of the model instead of its bytes.
fn toolImageFollowUp(allocator: std.mem.Allocator, tool_name: []const u8, urls: []const []const u8) !agent.AgentMessage {
    const caption = if (tool_name.len > 0)
        try std.fmt.allocPrint(allocator, "The `{s}` tool attached this image — look at it before answering.", .{tool_name})
    else
        try allocator.dupe(u8, "A tool attached this image — look at it before answering.");
    errdefer allocator.free(caption);

    const parts = try allocator.alloc(agent.ContentPart, urls.len + 1);
    parts[0] = .{
        .part_type = "text",
        .text = caption,
        .image_url = null,
        .video_url = null,
        .file = null,
    };
    for (urls, 0..) |url, i| {
        parts[i + 1] = .{
            .part_type = "image_url",
            .text = null,
            .image_url = .{
                .url = try allocator.dupe(u8, url),
                .detail = null,
            },
            .video_url = null,
            .file = null,
        };
    }

    return agent.AgentMessage{
        .role = .user,
        .content = null,
        .content_parts = parts,
    };
}

/// Strip the JSON tool envelope
/// (`{"tool":…,"parameters":…,"success":…,"data":…,"error":…,"v":1}`)
/// produced by `tool_registry.wrapToolOutput` and return just the inner
fn stripToolEnvelope(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return stripToolEnvelopeImpl(allocator, raw) catch |err| {
        // Use the project's custom Logger (pabrikcore.loggermod) — it has its
        // own formatter and does NOT route through std.log, so it won't
        // increment the test runner's `log_err_count`.
        if (pabrikcore.loggermod.getGlobal()) |logger| {
            logger.warnFmt(
                "[stripToolEnvelope] Agent Pabrik System error, the actual error is ->>>> {s} (input_len={d}, looks_like_json={any})",
                .{
                    @errorName(err),
                    raw.len,
                    std.mem.startsWith(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), "{"),
                },
            );
        }
        return err;
    };
}

fn stripToolEnvelopeImpl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        // Not JSON — legacy pre-migration row or plain text. Degrade to raw.
        return try allocator.dupe(u8, raw);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.dupe(u8, raw);
    const obj = parsed.value.object;
    const v = obj.get("v") orelse return try allocator.dupe(u8, raw);
    if (v != .integer or v.integer != 1) return try allocator.dupe(u8, raw);
    const success_val = obj.get("success") orelse return try allocator.dupe(u8, raw);
    if (success_val != .bool) return try allocator.dupe(u8, raw);

    if (success_val.bool) {
        const data = obj.get("data") orelse return try allocator.dupe(u8, "");
        if (data == .null) return try allocator.dupe(u8, "");
        return try std.json.Stringify.valueAlloc(allocator, data, .{});
    } else {
        const err = obj.get("error") orelse return try allocator.dupe(u8, "");
        if (err != .string) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, err.string);
    }
}

// ─── Chat content envelopes (user + assistant) ────────────────────────────
// / / Option A: `llm_history.response_content` holds a JSON object string for
// / `role=user` (`{"user","name","msg"}`) and for non-empty `role=assistant`
pub const UserEnvelope = struct {
    user: []const u8,
    name: []const u8,
    msg: []const u8,
};

pub const AssistantEnvelope = struct {
    model: []const u8,
    msg: []const u8,
};

pub fn encodeUserContent(allocator: std.mem.Allocator, user: []const u8, name: []const u8, msg: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, UserEnvelope{ .user = user, .name = name, .msg = msg }, .{});
}

pub fn encodeAssistantContent(allocator: std.mem.Allocator, model: []const u8, msg: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, AssistantEnvelope{ .model = model, .msg = msg }, .{});
}

/// True when `raw` already parses as a chat envelope (object with a string
/// `msg` plus `user` or `model`). Used by write paths for idempotence —
/// never double-envelop a row that is already enveloped.
pub fn isChatEnvelope(allocator: std.mem.Allocator, raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    const msg = obj.get("msg") orelse return false;
    if (msg != .string) return false;
    if (obj.get("user") != null) return true;
    if (obj.get("model") != null) return true;
    return false;
}

/// Unwrap a chat envelope to its `.msg` text. Returns a heap-dupe the caller
/// owns.
pub fn unwrapChatContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, raw);
    if (trimmed[0] != '{') return try allocator.dupe(u8, raw);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return try allocator.dupe(u8, raw);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.dupe(u8, raw);
    const obj = parsed.value.object;
    const msg = obj.get("msg") orelse return try allocator.dupe(u8, raw);
    if (msg != .string) return try allocator.dupe(u8, raw);
    // Require the identity marker so a user-typed `{"msg":"hi"}` literal
    // without `user`/`model` stays verbatim instead of being unwrapped.
    if (obj.get("user") == null and obj.get("model") == null) return try allocator.dupe(u8, raw);
    return try allocator.dupe(u8, msg.string);
}

/// Identity for a `role=user` envelope: the session owner's id + display
/// name, resolved via `sessions.user_id -> users.name`.
pub const ChatIdentity = struct {
    user_id: []u8,
    name: []u8,

    pub fn deinit(self: *ChatIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.name);
    }
};

pub fn resolveChatUser(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !ChatIdentity {
    var uid = try allocator.dupe(u8, "");
    errdefer allocator.free(uid);
    var name = try allocator.dupe(u8, "");
    errdefer allocator.free(name);

    var srows = try db.query(allocator, "SELECT COALESCE(user_id,'') FROM sessions WHERE id=?", &.{session_id});
    defer srows.deinit();
    if (try srows.next()) |srow| {
        defer srow.deinit(allocator);
        if (srow.values[0].len > 0) {
            allocator.free(uid);
            uid = try allocator.dupe(u8, srow.values[0]);
        }
    }
    if (uid.len > 0) {
        var urows = try db.query(allocator, "SELECT COALESCE(name,'') FROM users WHERE id=?", &.{uid});
        defer urows.deinit();
        if (try urows.next()) |urow| {
            defer urow.deinit(allocator);
            if (urow.values[0].len > 0) {
                allocator.free(name);
                name = try allocator.dupe(u8, urow.values[0]);
            }
        }
    }
    return .{ .user_id = uid, .name = name };
}

/// Profile name picked for the session (`sessions.selected_profile_model`,
/// e.g. `"900ribu"`), for the assistant envelope's identity field.
pub fn resolveProfileName(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) ![]u8 {
    var prows = try db.query(allocator, "SELECT COALESCE(selected_profile_model,'') FROM sessions WHERE id=?", &.{session_id});
    defer prows.deinit();
    if (try prows.next()) |prow| {
        defer prow.deinit(allocator);
        if (prow.values[0].len > 0) return try allocator.dupe(u8, prow.values[0]);
    }
    return try allocator.dupe(u8, "");
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Build a minimal `LLMHistory` with `role = "tool"` and the given
/// `response_content`.
fn makeToolMessage(allocator: std.mem.Allocator, response_content: []const u8) !LLMHistory {
    return LLMHistory{
        .id = try allocator.dupe(u8, "msg_test_001"),
        .session_id = try allocator.dupe(u8, "session_test"),
        .model = try allocator.dupe(u8, "test-model"),
        .created_at = try allocator.dupe(u8, "2025-01-01T00:00:00Z"),
        .response_content = try allocator.dupe(u8, response_content),
        .finish_reason = try allocator.dupe(u8, "tool_calls"),
        .role = try allocator.dupe(u8, "tool"),
        .agent = try allocator.dupe(u8, "Agent"),
        .session_name = try allocator.dupe(u8, ""),
        .tool_name = try allocator.dupe(u8, ""),
        .tool_calls_json = try allocator.dupe(u8, ""),
        .tool_call_id = try allocator.dupe(u8, "tool_call_abc"),
    };
}

/// Free the messages returned by `transformLLMHistoryToAgentMessage`.
fn freeMessages(allocator: std.mem.Allocator, msgs: []agent.AgentMessage) void {
    for (msgs) |*m| m.deinit(allocator);
    allocator.free(msgs);
}

// ─── Tests: success envelope ("data") ──────────────────────────────────────

test "tool message strips JSON envelope and returns canonical data JSON" {
    const allocator = testing.allocator;
    const envelope =
        "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"/foo\"}," ++
        "\"success\":true," ++
        "\"data\":{\"path\":\"/foo\",\"content\":\"hello\"},\"error\":null,\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("{\"path\":\"/foo\",\"content\":\"hello\"}", result[0].content.?);
    try testing.expect(result[0].role == .tool);
    try testing.expectEqualStrings("tool_call_abc", result[0].tool_call_id.?);
}

test "tool message success envelope with simple data value" {
    const allocator = testing.allocator;
    const envelope =
        "{\"tool\":\"bash\",\"parameters\":{\"command\":\"echo hi\"}," ++
        "\"success\":true,\"data\":{\"stdout\":\"hi\"},\"error\":null,\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("{\"stdout\":\"hi\"}", result[0].content.?);
}

test "tool message success envelope with null data returns empty content" {
    const allocator = testing.allocator;
    const envelope = "{\"tool\":\"foo\",\"parameters\":{},\"success\":true,\"data\":null,\"error\":null,\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

// ─── Tests: an image a tool read ────────────────────────────────────────────

fn giveToolMessageImage(allocator: std.mem.Allocator, msg: *LLMHistory, tool_name: []const u8, urls: []const []const u8) !void {
    allocator.free(msg.tool_name);
    msg.tool_name = try allocator.dupe(u8, tool_name);
    const owned = try allocator.alloc([]const u8, urls.len);
    for (urls, 0..) |url, i| owned[i] = try allocator.dupe(u8, url);
    msg.image_urls = owned;
}

test "a tool result carrying an image becomes a tool message plus a user message with the picture" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "{\"tool\":\"read_file\",\"parameters\":{},\"success\":true,\"data\":{\"mime\":\"image/png\"},\"error\":null,\"v\":1}");
    defer msg.deinit(allocator);
    try giveToolMessageImage(allocator, &msg, "read_file", &.{"data:image/png;base64,iVBORw0KGgo="});

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expect(result[0].role == .tool);
    try testing.expectEqualStrings("{\"mime\":\"image/png\"}", result[0].content.?);

    try testing.expect(result[1].role == .user);
    const parts = result[1].content_parts.?;
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("text", parts[0].part_type);
    try testing.expect(std.mem.indexOf(u8, parts[0].text.?, "read_file") != null);
    try testing.expectEqualStrings("image_url", parts[1].part_type);
    try testing.expectEqualStrings("data:image/png;base64,iVBORw0KGgo=", parts[1].image_url.?.url.?);
}

test "a tool result with several images puts every one of them in the picture message" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "ok");
    defer msg.deinit(allocator);
    try giveToolMessageImage(allocator, &msg, "read_file", &.{ "data:image/png;base64,AAA", "data:image/jpeg;base64,BBB" });

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqual(@as(usize, 2), result.len);
    const parts = result[1].content_parts.?;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("data:image/png;base64,AAA", parts[1].image_url.?.url.?);
    try testing.expectEqualStrings("data:image/jpeg;base64,BBB", parts[2].image_url.?.url.?);
}

test "a tool result with no image stays one text message" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "ok");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0].content_parts == null);
}

// ─── Tests: failure envelope ("error") ─────────────────────────────────────

test "tool message with failure envelope returns error value" {
    const allocator = testing.allocator;
    const envelope =
        "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"/missing\"}," ++
        "\"success\":false,\"data\":null,\"error\":\"File not found\",\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("File not found", result[0].content.?);
}

test "tool message failure envelope with special chars keeps them verbatim" {
    // JSON carries <>&" natively — no entity layer, nothing to unescape.
    const allocator = testing.allocator;
    const envelope =
        "{\"tool\":\"read_file\",\"parameters\":{}," ++
        "\"success\":false,\"data\":null,\"error\":\"File \\\"foo\\\" not <found>\",\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("File \"foo\" not <found>", result[0].content.?);
}

// ─── Tests: legacy / non-envelope fallback ─────────────────────────────────

test "tool message with plain-text legacy content falls back to full response_content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "hello plain text");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("hello plain text", result[0].content.?);
}

test "tool message with empty string content returns empty content" {
    const allocator = testing.allocator;
    var msg = try makeToolMessage(allocator, "");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("", result[0].content.?);
}

test "tool message with truncated JSON falls back to full content" {
    const allocator = testing.allocator;
    // Truncated mid-object — not parseable JSON.
    var msg = try makeToolMessage(allocator, "{\"tool\":\"foo\",\"data\":");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("{\"tool\":\"foo\",\"data\":", result[0].content.?);
}

test "tool message with JSON missing v tag falls back to full content" {
    const allocator = testing.allocator;
    // Valid JSON but not a v1 envelope — passed through untouched.
    var msg = try makeToolMessage(allocator, "{\"tool\":\"foo\"}");
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("{\"tool\":\"foo\"}", result[0].content.?);
}

test "tool message with legacy XML envelope degrades to raw text" {
    const allocator = testing.allocator;
    // Pre-migration history row: not JSON, so it passes through unchanged
    // and renders as raw text downstream. No bulk-rewrite of history.
    const legacy = "<tool><name>foo</name></tool>";
    var msg = try makeToolMessage(allocator, legacy);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings(legacy, result[0].content.?);
}

// ─── Tests: data payload structure (JSON preserved) ────────────────────

test "tool message data containing markup chars keeps the payload intact" {
    // read_file's data is a JSON object; <>& inside strings need no
    // escaping and round-trip verbatim through the envelope.
    const allocator = testing.allocator;
    const envelope =
        "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"/home/user/file.txt\"}," ++
        "\"success\":true,\"data\":{\"path\":\"/home/user/file.txt\"," ++
        "\"content\":\"<div>a & b</div>\"},\"error\":null,\"v\":1}";
    var msg = try makeToolMessage(allocator, envelope);
    defer msg.deinit(allocator);

    const result = try transformLLMHistoryToAgentMessage(allocator, msg);
    defer freeMessages(allocator, result);

    try testing.expectEqualStrings("{\"path\":\"/home/user/file.txt\",\"content\":\"<div>a & b</div>\"}", result[0].content.?);
}

// ─── Tests: chat content envelopes (user + assistant, Option A) ─────────

fn makeChatMessage(allocator: std.mem.Allocator, role: []const u8, response_content: []const u8, tool_calls_json: []const u8) !LLMHistory {
    return LLMHistory{
        .id = try allocator.dupe(u8, "msg_chat_001"),
        .session_id = try allocator.dupe(u8, "session_test"),
        .model = try allocator.dupe(u8, "MiniMax-M3"),
        .created_at = try allocator.dupe(u8, "2025-01-01T00:00:00Z"),
        .response_content = try allocator.dupe(u8, response_content),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, role),
        .agent = try allocator.dupe(u8, "Agent"),
        .session_name = try allocator.dupe(u8, ""),
        .tool_name = try allocator.dupe(u8, ""),
        .tool_calls_json = try allocator.dupe(u8, tool_calls_json),
    };
}

test "user envelope round-trips through encode + unwrap" {
    const allocator = testing.allocator;
    const enc = try encodeUserContent(allocator, "usr_7f3a", "Budi", "i wanna ask with you");
    defer allocator.free(enc);
    try testing.expect(isChatEnvelope(allocator, enc));
    const msg = try unwrapChatContent(allocator, enc);
    defer allocator.free(msg);
    try testing.expectEqualStrings("i wanna ask with you", msg);
}

test "assistant envelope round-trips through encode + unwrap" {
    const allocator = testing.allocator;
    const enc = try encodeAssistantContent(allocator, "MiniMax-M3", "hey human");
    defer allocator.free(enc);
    try testing.expect(isChatEnvelope(allocator, enc));
    const msg = try unwrapChatContent(allocator, enc);
    defer allocator.free(msg);
    try testing.expectEqualStrings("hey human", msg);
}

test "unwrap falls back to raw for legacy plain text" {
    const allocator = testing.allocator;
    const msg = try unwrapChatContent(allocator, "i wanna ask with you");
    defer allocator.free(msg);
    try testing.expectEqualStrings("i wanna ask with you", msg);
    try testing.expect(!isChatEnvelope(allocator, "i wanna ask with you"));
}

test "transform unwraps user envelope to .msg" {
    const allocator = testing.allocator;
    const enc = try encodeUserContent(allocator, "usr_7f3a", "Budi", "i wanna ask with you");
    defer allocator.free(enc);
    var hist = try makeChatMessage(allocator, "user", enc, "");
    defer hist.deinit(allocator);
    const result = try transformLLMHistoryToAgentMessage(allocator, hist);
    defer freeMessages(allocator, result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("i wanna ask with you", result[0].content.?);
}

test "transform unwraps assistant envelope to .msg" {
    const allocator = testing.allocator;
    const enc = try encodeAssistantContent(allocator, "MiniMax-M3", "hey human");
    defer allocator.free(enc);
    var hist = try makeChatMessage(allocator, "assistant", enc, "");
    defer hist.deinit(allocator);
    const result = try transformLLMHistoryToAgentMessage(allocator, hist);
    defer freeMessages(allocator, result);
    try testing.expectEqualStrings("hey human", result[0].content.?);
}

test "transform unwraps assistant text even when tool_calls_json present (screenshot case)" {
    const allocator = testing.allocator;
    const enc = try encodeAssistantContent(allocator, "muse-spark-1.3-c", "Understood - ban and refactor");
    defer allocator.free(enc);
    var hist = try makeChatMessage(allocator, "assistant", enc, "[{\"id\":\"call_01\",\"function\":{\"name\":\"command\",\"arguments\":\"{}\"}}]");
    defer hist.deinit(allocator);
    const result = try transformLLMHistoryToAgentMessage(allocator, hist);
    defer freeMessages(allocator, result);
    try testing.expectEqualStrings("Understood - ban and refactor", result[0].content.?);
    try testing.expect(result[0].tool_calls != null);
    try testing.expectEqual(@as(usize, 1), result[0].tool_calls.?.len);
}

test "transform keeps legacy plain user text verbatim (positive control)" {
    const allocator = testing.allocator;
    var hist = try makeChatMessage(allocator, "user", "hello plain", "");
    defer hist.deinit(allocator);
    const result = try transformLLMHistoryToAgentMessage(allocator, hist);
    defer freeMessages(allocator, result);
    try testing.expectEqualStrings("hello plain", result[0].content.?);
}
