//! `pabrik-vmd`'s wire protocol: length-prefixed JSON frames over a unix
//! socket. A request carries a workspace id, an action and that action's
//! arguments — never a VM path, a drive plan or a socket location.

const std = @import("std");
const policy = @import("policy.zig");

pub const version = "0.1";
pub const max_frame: usize = 4 * 1024 * 1024;
pub const default_timeout_ms: u32 = 10_000;
pub const default_max_output_bytes: usize = 256 * 1024;
/// A base64 frame costs 4 bytes per 3, so the reply budget has to stay well
/// under `max_frame` or a legal command produces an illegal response.
pub const max_output_bytes_limit: usize = 1024 * 1024;

pub const Error = error{
    BadRequest,
    UnknownAction,
    FrameTooLarge,
    EmptyFrame,
    UnknownResponse,
    InvalidBase64,
};

pub const Action = enum { ping, exec, stop, status };

pub const Request = struct {
    id: i64 = 0,
    action: Action,
    workspace_id: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd_rel: []const u8 = "",
    timeout_ms: u32 = default_timeout_ms,
    max_output_bytes: usize = default_max_output_bytes,
};

pub const FailureCode = enum {
    bad_request,
    forbidden_peer,
    vm_unavailable,
    not_ready,
    internal,

    pub fn name(self: FailureCode) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?FailureCode {
        inline for (@typeInfo(FailureCode).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const ExecResult = struct {
    code: i64,
    timed_out: bool,
    truncated: bool,
    /// Decoded stdout. Owned by the arena of the parsed response.
    stdout: []const u8,
    /// Decoded stderr. Owned by the arena of the parsed response.
    stderr: []const u8,
};

pub const Response = union(enum) {
    pong: struct { version: []const u8 },
    ack,
    status: struct { state: []const u8, pid: i64, last_error: []const u8 },
    exec_result: ExecResult,
    failure: struct { code: FailureCode, message: []const u8 },
};

/// A decoded response plus the arena its slices point into.
pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    value: Response,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
    }
};

/// A decoded request plus the arena its slices point into.
pub const OwnedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
    }
};

// ─── framing ─────────────────────────────────────────────────────────────

pub fn frameHeader(payload_len: usize, out: *[4]u8) void {
    std.mem.writeInt(u32, out, @intCast(payload_len), .big);
}

/// A zero-length frame is a peer that wrote nothing meaningful; an oversized
/// one must be refused BEFORE anything is allocated for it.
pub fn framePayloadLen(header: [4]u8) Error!usize {
    const len = std.mem.readInt(u32, &header, .big);
    if (len == 0) return Error.EmptyFrame;
    if (len > max_frame) return Error.FrameTooLarge;
    return len;
}

// ─── a flat-object JSON writer ───────────────────────────────────────────

const ObjectWriter = struct {
    list: std.ArrayList(u8) = .empty,
    fields: usize = 0,

    fn init(allocator: std.mem.Allocator) !ObjectWriter {
        var self = ObjectWriter{};
        try self.list.append(allocator, '{');
        return self;
    }

    fn open(self: *ObjectWriter, allocator: std.mem.Allocator, key: []const u8) !void {
        if (self.fields > 0) try self.list.append(allocator, ',');
        self.fields += 1;
        try self.writeQuoted(allocator, key);
        try self.list.append(allocator, ':');
    }

    fn strField(self: *ObjectWriter, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.open(allocator, key);
        try self.writeQuoted(allocator, value);
    }

    fn intField(self: *ObjectWriter, allocator: std.mem.Allocator, key: []const u8, value: i64) !void {
        try self.open(allocator, key);
        try self.list.print(allocator, "{d}", .{value});
    }

    fn boolField(self: *ObjectWriter, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
        try self.open(allocator, key);
        try self.list.appendSlice(allocator, if (value) "true" else "false");
    }

    fn strArrayField(
        self: *ObjectWriter,
        allocator: std.mem.Allocator,
        key: []const u8,
        values: []const []const u8,
    ) !void {
        try self.open(allocator, key);
        try self.list.append(allocator, '[');
        for (values, 0..) |value, i| {
            if (i > 0) try self.list.append(allocator, ',');
            try self.writeQuoted(allocator, value);
        }
        try self.list.append(allocator, ']');
    }

    fn finish(self: *ObjectWriter, allocator: std.mem.Allocator) ![]u8 {
        try self.list.append(allocator, '}');
        return self.list.toOwnedSlice(allocator);
    }

    fn writeQuoted(self: *ObjectWriter, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.list.append(allocator, '"');
        for (value) |byte| {
            switch (byte) {
                '"' => try self.list.appendSlice(allocator, "\\\""),
                '\\' => try self.list.appendSlice(allocator, "\\\\"),
                '\n' => try self.list.appendSlice(allocator, "\\n"),
                '\r' => try self.list.appendSlice(allocator, "\\r"),
                '\t' => try self.list.appendSlice(allocator, "\\t"),
                else => {
                    if (byte < 0x20) {
                        try self.list.print(allocator, "\\u{x:0>4}", .{byte});
                    } else {
                        try self.list.append(allocator, byte);
                    }
                },
            }
        }
        try self.list.append(allocator, '"');
    }
};

// ─── requests ────────────────────────────────────────────────────────────

pub fn encodeRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "request");
    try out.strField(allocator, "action", @tagName(request.action));
    try out.intField(allocator, "id", request.id);
    if (request.action == .ping) return out.finish(allocator);
    try out.strField(allocator, "workspace_id", request.workspace_id);
    if (request.action == .exec) {
        try out.strArrayField(allocator, "argv", request.argv);
        try out.strField(allocator, "cwd_rel", request.cwd_rel);
        try out.intField(allocator, "timeout_ms", @intCast(request.timeout_ms));
        try out.intField(allocator, "max_output_bytes", @intCast(request.max_output_bytes));
    }
    return out.finish(allocator);
}

/// Every rejection here is a rejection of something a caller cannot fix by
/// retrying, so each names the field it refused.
pub fn decodeRequest(allocator: std.mem.Allocator, json: []const u8) !OwnedRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, json, .{}) catch return Error.BadRequest;
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadRequest,
    };

    const action_text = stringField(object, "action") orelse return Error.BadRequest;
    const action = std.meta.stringToEnum(Action, action_text) orelse return Error.UnknownAction;

    var request = Request{
        .action = action,
        .id = integerField(object, "id") orelse 0,
    };

    if (action == .ping) return .{ .arena = arena, .value = request };

    const workspace_id = stringField(object, "workspace_id") orelse return Error.BadRequest;
    if (!policy.workspaceIdValid(workspace_id)) return Error.BadRequest;
    request.workspace_id = workspace_id;

    if (action == .exec) {
        const argv_value = object.get("argv") orelse return Error.BadRequest;
        const items = switch (argv_value) {
            .array => |a| a,
            else => return Error.BadRequest,
        };
        if (items.items.len == 0) return Error.BadRequest;
        const argv = try aa.alloc([]const u8, items.items.len);
        for (items.items, 0..) |item, i| {
            argv[i] = switch (item) {
                .string => |s| s,
                else => return Error.BadRequest,
            };
        }
        request.argv = argv;

        const cwd_rel = stringField(object, "cwd_rel") orelse return Error.BadRequest;
        if (!policy.cwdRelValid(cwd_rel)) return Error.BadRequest;
        request.cwd_rel = cwd_rel;

        if (integerField(object, "timeout_ms")) |t| {
            if (t <= 0 or t > 600_000) return Error.BadRequest;
            request.timeout_ms = @intCast(t);
        }
        if (integerField(object, "max_output_bytes")) |m| {
            if (m <= 0 or m > max_output_bytes_limit) return Error.BadRequest;
            request.max_output_bytes = @intCast(m);
        }
    }

    return .{ .arena = arena, .value = request };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .float => |f| if (f == @floor(f)) @intFromFloat(f) else null,
        else => null,
    };
}

// ─── responses ───────────────────────────────────────────────────────────

pub fn encodePong(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "pong");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "version", version);
    return out.finish(allocator);
}

pub fn encodeAck(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "ack");
    try out.intField(allocator, "id", id);
    return out.finish(allocator);
}

pub fn encodeStatus(allocator: std.mem.Allocator, id: i64, state: []const u8, pid: i64, last_error: []const u8) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "status");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "state", state);
    try out.intField(allocator, "pid", pid);
    if (last_error.len > 0) try out.strField(allocator, "error", last_error);
    return out.finish(allocator);
}

pub fn encodeFailure(
    allocator: std.mem.Allocator,
    id: i64,
    code: FailureCode,
    message: []const u8,
) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "failure");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "code", code.name());
    try out.strField(allocator, "message", message);
    return out.finish(allocator);
}

pub fn encodeExecResult(
    allocator: std.mem.Allocator,
    id: i64,
    result: ExecResult,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const stdout_b64 = try allocator.alloc(u8, encoder.calcSize(result.stdout.len));
    defer allocator.free(stdout_b64);
    _ = encoder.encode(stdout_b64, result.stdout);
    const stderr_b64 = try allocator.alloc(u8, encoder.calcSize(result.stderr.len));
    defer allocator.free(stderr_b64);
    _ = encoder.encode(stderr_b64, result.stderr);

    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "exec.result");
    try out.intField(allocator, "id", id);
    try out.intField(allocator, "code", result.code);
    try out.boolField(allocator, "timed_out", result.timed_out);
    try out.boolField(allocator, "truncated", result.truncated);
    try out.strField(allocator, "stdout_b64", stdout_b64);
    try out.strField(allocator, "stderr_b64", stderr_b64);
    return out.finish(allocator);
}

pub fn decodeResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
) !OwnedResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, json, .{}) catch return Error.BadRequest;
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadRequest,
    };
    const kind = stringField(object, "type") orelse return Error.BadRequest;

    if (std.mem.eql(u8, kind, "pong")) {
        return .{ .arena = arena, .value = .{ .pong = .{
            .version = stringField(object, "version") orelse "",
        } } };
    }
    if (std.mem.eql(u8, kind, "ack")) return .{ .arena = arena, .value = .ack };
    if (std.mem.eql(u8, kind, "status")) {
        return .{ .arena = arena, .value = .{ .status = .{
            .state = stringField(object, "state") orelse "",
            .pid = integerField(object, "pid") orelse 0,
            .last_error = stringField(object, "error") orelse "",
        } } };
    }
    if (std.mem.eql(u8, kind, "failure")) {
        const code_text = stringField(object, "code") orelse return Error.BadRequest;
        const code = FailureCode.fromName(code_text) orelse return Error.BadRequest;
        return .{ .arena = arena, .value = .{ .failure = .{
            .code = code,
            .message = stringField(object, "message") orelse "",
        } } };
    }
    if (std.mem.eql(u8, kind, "exec.result")) {
        const stdout = try decodeBase64Field(aa, object, "stdout_b64");
        const stderr = try decodeBase64Field(aa, object, "stderr_b64");
        return .{ .arena = arena, .value = .{ .exec_result = .{
            .code = integerField(object, "code") orelse -1,
            .timed_out = boolField(object, "timed_out"),
            .truncated = boolField(object, "truncated"),
            .stdout = stdout,
            .stderr = stderr,
        } } };
    }
    return Error.UnknownResponse;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

fn decodeBase64Field(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const text = stringField(object, key) orelse return Error.BadRequest;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return Error.InvalidBase64;
    const out = try allocator.alloc(u8, size);
    decoder.decode(out, text) catch return Error.InvalidBase64;
    return out;
}

const testing = std.testing;

fn expectExec(allocator: std.mem.Allocator, encoded: []u8, expect_code: i64) !void {
    defer allocator.free(encoded);
    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const result = switch (owned.value) {
        .exec_result => |r| r,
        else => return error.TestExpectedExecResult,
    };
    try testing.expectEqual(expect_code, result.code);
}

test "rpc: a ping request round-trips and carries nothing else" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{ .action = .ping, .id = 7 });
    defer allocator.free(encoded);

    var owned = try decodeRequest(allocator, encoded);
    defer owned.deinit();
    try testing.expectEqual(Action.ping, owned.value.action);
    try testing.expectEqual(@as(i64, 7), owned.value.id);
    try testing.expectEqualStrings("", owned.value.workspace_id);
}

test "rpc: an exec request round-trips workspace id, argv and cwd" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .exec,
        .id = 3,
        .workspace_id = "ws_1",
        .argv = &.{ "/bin/sh", "-c", "echo \"hi\"\nnext" },
        .cwd_rel = "src",
        .timeout_ms = 2500,
        .max_output_bytes = 4096,
    });
    defer allocator.free(encoded);

    var owned = try decodeRequest(allocator, encoded);
    defer owned.deinit();
    try testing.expectEqual(Action.exec, owned.value.action);
    try testing.expectEqualStrings("ws_1", owned.value.workspace_id);
    try testing.expectEqualStrings("src", owned.value.cwd_rel);
    try testing.expectEqual(@as(u32, 2500), owned.value.timeout_ms);
    try testing.expectEqual(@as(usize, 4096), owned.value.max_output_bytes);
    try testing.expectEqual(@as(usize, 3), owned.value.argv.len);
    try testing.expectEqualStrings("echo \"hi\"\nnext", owned.value.argv[2]);
}

test "rpc: a request naming its own paths is refused, not honoured" {
    const allocator = testing.allocator;
    const hostile =
        \\{"type":"request","action":"exec","id":1,"workspace_id":"ws_1",
        \\ "argv":["/bin/sh","-c","id"],"cwd_rel":"","disk_path":"/etc/shadow",
        \\ "api_sock":"/tmp/evil.sock","vsock_socket":"/tmp/evil.vsock"}
    ;
    var owned = try decodeRequest(allocator, hostile);
    defer owned.deinit();

    const derived = try @import("vm_client.zig").layoutFor(allocator, .{
        .workspace_id = owned.value.workspace_id,
        .base_image = "/base.ext4",
        .kernel = "/vmlinux",
        .fc_bin = "firecracker",
        .root = "/vms",
    });
    defer derived.deinit(allocator);

    try testing.expectEqualStrings("/vms/workspaces/ws_1/disk.ext4", derived.disk);
    try testing.expectEqualStrings("/vms/workspaces/ws_1/api.sock", derived.api_sock);
    try testing.expectEqualStrings("/vms/workspaces/ws_1/vsock.sock", derived.vsock_sock);
}

test "rpc: a workspace id that could steer a path is refused" {
    const allocator = testing.allocator;
    for ([_][]const u8{
        \\{"type":"request","action":"status","id":1,"workspace_id":"../../etc"}
        ,
        \\{"type":"request","action":"status","id":1,"workspace_id":"/tmp"}
        ,
        \\{"type":"request","action":"status","id":1,"workspace_id":""}
        ,
        \\{"type":"request","action":"exec","id":1,"workspace_id":"ws_1","argv":["/bin/sh"],"cwd_rel":"../.."}
    }) |hostile| {
        try testing.expectError(Error.BadRequest, decodeRequest(allocator, hostile));
    }
}

test "rpc: malformed and unknown requests are refused with a nameable error" {
    const allocator = testing.allocator;
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, "not json"));
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, "[]"));
    try testing.expectError(Error.UnknownAction, decodeRequest(allocator,
        \\{"type":"request","action":"rm -rf","workspace_id":"ws_1"}
    ));
    try testing.expectError(Error.BadRequest, decodeRequest(allocator,
        \\{"type":"request","action":"exec","workspace_id":"ws_1","argv":[],"cwd_rel":""}
    ));
    try testing.expectError(Error.BadRequest, decodeRequest(allocator,
        \\{"type":"request","action":"exec","workspace_id":"ws_1","argv":["sh"],"cwd_rel":"","timeout_ms":0}
    ));
}

test "rpc: frame length is refused before anything is allocated" {
    var header: [4]u8 = undefined;

    frameHeader(12, &header);
    try testing.expectEqual(@as(usize, 12), try framePayloadLen(header));

    frameHeader(0, &header);
    try testing.expectError(Error.EmptyFrame, framePayloadLen(header));

    frameHeader(max_frame + 1, &header);
    try testing.expectError(Error.FrameTooLarge, framePayloadLen(header));

    frameHeader(max_frame, &header);
    try testing.expectEqual(@as(usize, max_frame), try framePayloadLen(header));
}

test "rpc: an exec result carries its streams, flags and exit code" {
    const allocator = testing.allocator;
    try expectExec(allocator, try encodeExecResult(allocator, 5, .{
        .code = 7,
        .timed_out = true,
        .truncated = false,
        .stdout = "out\n",
        .stderr = "err\n",
    }), 7);

    const encoded = try encodeExecResult(allocator, 5, .{
        .code = 0,
        .timed_out = false,
        .truncated = true,
        .stdout = "\x00\x01\xff binary",
        .stderr = "",
    });
    defer allocator.free(encoded);
    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const result = switch (owned.value) {
        .exec_result => |r| r,
        else => return error.TestExpectedExecResult,
    };
    try testing.expect(result.truncated);
    try testing.expect(!result.timed_out);
    try testing.expectEqualStrings("\x00\x01\xff binary", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "rpc: a failure names its code, and an unknown one is not guessed" {
    const allocator = testing.allocator;
    const encoded = try encodeFailure(allocator, 1, .forbidden_peer, "peer uid 0 is not 1000");
    defer allocator.free(encoded);

    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const failure = switch (owned.value) {
        .failure => |f| f,
        else => return error.TestExpectedFailure,
    };
    try testing.expectEqual(FailureCode.forbidden_peer, failure.code);
    try testing.expectEqualStrings("peer uid 0 is not 1000", failure.message);

    try testing.expectError(Error.BadRequest, decodeResponse(allocator,
        \\{"type":"failure","id":1,"code":"made_up","message":"x"}
    ));
    try testing.expectError(Error.UnknownResponse, decodeResponse(allocator,
        \\{"type":"who_knows","id":1}
    ));
}

test "rpc: pong and status decode to their own shape" {
    const allocator = testing.allocator;
    const pong = try encodePong(allocator, 9);
    defer allocator.free(pong);
    var decoded_pong = try decodeResponse(allocator, pong);
    defer decoded_pong.deinit();
    switch (decoded_pong.value) {
        .pong => |p| try testing.expectEqualStrings(version, p.version),
        else => return error.TestExpectedPong,
    }

    const status = try encodeStatus(allocator, 9, "ready", 4242, "");
    defer allocator.free(status);
    var decoded_status = try decodeResponse(allocator, status);
    defer decoded_status.deinit();
    switch (decoded_status.value) {
        .status => |s| {
            try testing.expectEqualStrings("ready", s.state);
            try testing.expectEqual(@as(i64, 4242), s.pid);
        },
        else => return error.TestExpectedStatus,
    }
}
