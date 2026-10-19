//! The preview tunnel: the one RPC the server asks the daemon for, and the
//! guest op behind it. The ports a workspace may be reached on are the daemon's
//! to decide, never a caller's to name.

const std = @import("std");
const linux = std.os.linux;
const rpc = @import("rpc.zig");
const egress_proxy = @import("egress_proxy.zig");
const vm_client = @import("vm_client.zig");
const policy = @import("policy.zig");

pub const request_type = "proxy.exchange";
pub const ok_type = "proxy.exchange.ok";
pub const error_type = "proxy.error";
/// One port per line, `#` comments allowed.
pub const ports_file = "preview.ports";
pub const max_request_bytes: usize = 16 * 1024;
pub const max_response_bytes: usize = 1024 * 1024;
pub const guest_op = "port.forward";
pub const guest_ok = "port.forward.data";
pub const guest_done = "port.forward.done";
pub const guest_error = "port.forward.error";

pub const Reply = struct {
    bytes: []const u8 = "",
    truncated: bool = false,
    failure: ?[]const u8 = null,

    pub fn deinit(self: Reply, allocator: std.mem.Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
        if (self.failure) |message| allocator.free(message);
    }

    pub fn refused(self: Reply) bool {
        return self.failure != null;
    }
};

/// True for a frame this module owns: `type` has to be the FIRST field and its
/// value exactly this module's, so a frame that merely mentions the type in a
/// path, an argv or a body is still the other decoder's.
pub fn isProxyFrame(body: []const u8) bool {
    var rest = std.mem.trimStart(u8, body, " \t\r\n");
    if (rest.len == 0 or rest[0] != '{') return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, "\"type\"")) return false;
    rest = std.mem.trimStart(u8, rest["\"type\"".len..], " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '"') return false;
    rest = rest[1..];
    if (!std.mem.startsWith(u8, rest, request_type)) return false;
    return rest.len > request_type.len and rest[request_type.len] == '"';
}

// ─── the port allowlist ─────────────────────────────────────────────────

pub fn parsePorts(allocator: std.mem.Allocator, text: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const port = std.fmt.parseInt(u16, line, 10) catch return error.InvalidPreviewPort;
        if (port == 0) return error.InvalidPreviewPort;
        try out.append(allocator, port);
    }
    return out.toOwnedSlice(allocator);
}

pub fn portDeclared(port: u16, declared: []const u16) bool {
    if (port == 0) return false;
    for (declared) |candidate| {
        if (candidate == port) return true;
    }
    return false;
}

fn loadDeclaredPorts(allocator: std.mem.Allocator, dir: []const u8) ![]u16 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, ports_file });
    defer allocator.free(path);
    const text = egress_proxy.readFileAlloc(allocator, path, egress_proxy.max_config_bytes) orelse return &.{};
    defer allocator.free(text);
    return parsePorts(allocator, text);
}

// ─── the codec ──────────────────────────────────────────────────────────

/// A request the caller frames. `workspace_id` is validated before it is
/// spliced into JSON, so no escaping is needed here.
pub fn encodeRequest(allocator: std.mem.Allocator, id: i64, workspace_id: []const u8, port: u16, data: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"id\":{d},\"workspace_id\":\"{s}\",\"port\":{d},\"data_b64\":\"{s}\"}}",
        .{ request_type, id, workspace_id, port, encoded },
    );
}

pub fn encodeReply(allocator: std.mem.Allocator, id: i64, data: []const u8, truncated: bool) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"id\":{d},\"truncated\":{s},\"data_b64\":\"{s}\"}}",
        .{ ok_type, id, if (truncated) "true" else "false", encoded },
    );
}

pub fn encodeError(allocator: std.mem.Allocator, id: i64, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"id\":{d},\"message\":\"{s}\"}}",
        .{ error_type, id, message },
    );
}

pub const Request = struct {
    id: i64 = 0,
    workspace_id: []const u8 = "",
    port: u16 = 0,
    data: []const u8 = "",
};

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
    }
};

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

pub fn decodeRequest(allocator: std.mem.Allocator, body: []const u8) !Decoded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch return error.BadRequest;
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadRequest,
    };
    const workspace_id = jsonString(object, "workspace_id") orelse return error.BadRequest;
    // The id is a path component and a directory name downstream, so this is
    // the same rule every other action gets: no separator, no dot-dot.
    if (!policy.workspaceIdValid(workspace_id)) return error.BadRequest;
    const port_int = jsonInt(object, "port") orelse return error.BadRequest;
    if (port_int <= 0 or port_int > 65535) return error.BadRequest;
    const data_b64 = jsonString(object, "data_b64") orelse return error.BadRequest;
    const data = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.BadRequest;
    if (data > max_request_bytes) return error.BadRequest;
    const buffer = try aa.alloc(u8, data);
    std.base64.standard.Decoder.decode(buffer, data_b64) catch return error.BadRequest;
    // The arena moves into the result, so the value's slices outlive the
    // frame that carried them: the caller owns them until `deinit`.
    return .{
        .arena = arena,
        .value = .{
            .id = jsonInt(object, "id") orelse 0,
            .workspace_id = workspace_id,
            .port = @intCast(port_int),
            .data = buffer,
        },
    };
}

pub const Exchange = struct {
    bytes: []const u8 = "",
    truncated: bool = false,
};

pub fn decodeReply(allocator: std.mem.Allocator, body: []const u8) !Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.BadRequest;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadRequest,
    };
    const kind = jsonString(object, "type") orelse return error.BadRequest;
    if (std.mem.eql(u8, kind, error_type)) {
        return .{ .failure = try allocator.dupe(u8, jsonString(object, "message") orelse "refused") };
    }
    if (!std.mem.eql(u8, kind, ok_type)) return error.BadRequest;
    const data_b64 = jsonString(object, "data_b64") orelse return error.BadRequest;
    const size = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.BadRequest;
    if (size > max_response_bytes) return error.BadRequest;
    const bytes: []u8 = if (size == 0) @constCast(&[_]u8{}) else try allocator.alloc(u8, size);
    errdefer if (size > 0) allocator.free(bytes);
    if (size > 0) std.base64.standard.Decoder.decode(bytes, data_b64) catch return error.BadRequest;
    const truncated = object.get("truncated") orelse return .{ .bytes = bytes, .truncated = false };
    return .{ .bytes = bytes, .truncated = truncated == .bool and truncated.bool };
}

// ─── the daemon's half ──────────────────────────────────────────────────

/// One preview exchange, on the daemon's side of the control socket.
pub fn serve(manager: anytype, allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var decoded = decodeRequest(allocator, body) catch |err| {
        return encodeError(allocator, 0, @errorName(err));
    };
    defer decoded.deinit();
    const request = decoded.value;

    const layout = manager.layoutFor(allocator, request.workspace_id) catch |err| {
        return encodeError(allocator, request.id, @errorName(err));
    };
    defer layout.deinit(allocator);
    const declared = loadDeclaredPorts(allocator, layout.dir) catch &.{};
    defer if (declared.len > 0) allocator.free(declared);
    if (!portDeclared(request.port, declared)) {
        return encodeError(allocator, request.id, "port not declared");
    }

    var running = manager.ensure(allocator, request.workspace_id) catch |err| {
        return encodeError(allocator, request.id, @errorName(err));
    };
    defer running.deinit(allocator);
    const forwarded = guestExchange(allocator, running, request.port, request.data) catch |err| {
        return encodeError(allocator, request.id, @errorName(err));
    };
    defer if (forwarded.bytes.len > 0) allocator.free(forwarded.bytes);
    return encodeReply(allocator, request.id, forwarded.bytes, forwarded.truncated);
}

fn guestExchange(
    allocator: std.mem.Allocator,
    layout: vm_client.Layout,
    port: u16,
    data: []const u8,
) !Exchange {
    const fd = try vm_client.connectUnix(layout.vsock_sock);
    defer _ = linux.close(fd);
    try handshake(fd, vm_client.agent_port);

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    const frame = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"id\":1,\"port\":{d},\"max_bytes\":{d},\"data_b64\":\"{s}\"}}",
        .{ guest_op, port, max_response_bytes, encoded },
    );
    defer allocator.free(frame);
    if (frame.len > rpc.max_frame) return error.RequestTooLarge;
    try sendFrame(fd, frame);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // The guest's own frame ceiling, not the daemon's: nothing it sends can be
    // larger, so a bigger stack buffer would only invite a scaled-up forgery.
    var payload: [vm_client.max_frame]u8 = undefined;
    var truncated = false;
    while (true) {
        const text = try readFrame(fd, &payload);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.ProtocolViolation;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return error.ProtocolViolation,
        };
        const kind = jsonString(object, "type") orelse return error.ProtocolViolation;
        if (std.mem.eql(u8, kind, guest_error)) {
            std.log.info("preview: forwarding to guest port {d} failed: {s}", .{
                port,
                jsonString(object, "message") orelse "no reason given",
            });
            return error.GuestRefused;
        }
        if (std.mem.eql(u8, kind, guest_done)) {
            if (object.get("truncated")) |value| truncated = value == .bool and value.bool;
            return .{ .bytes = try out.toOwnedSlice(allocator), .truncated = truncated };
        }
        if (!std.mem.eql(u8, kind, guest_ok)) return error.ProtocolViolation;
        const data_b64 = jsonString(object, "data_b64") orelse return error.ProtocolViolation;
        const size = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.ProtocolViolation;
        if (out.items.len + size > max_response_bytes) {
            truncated = true;
            return .{ .bytes = try out.toOwnedSlice(allocator), .truncated = truncated };
        }
        const start = out.items.len;
        try out.resize(allocator, start + size);
        std.base64.standard.Decoder.decode(out.items[start..], data_b64) catch return error.ProtocolViolation;
    }
}

// ─── the caller's half ──────────────────────────────────────────────────

pub fn exchange(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    workspace_id: []const u8,
    port: u16,
    request_bytes: []const u8,
) !Reply {
    if (request_bytes.len > max_request_bytes) return error.RequestTooLarge;
    if (workspace_id.len == 0 or !policy.workspaceIdValid(workspace_id)) return error.BadRequest;
    const fd = try vm_client.connectUnix(socket_path);
    defer _ = linux.close(fd);
    const frame = try encodeRequest(allocator, 1, workspace_id, port, request_bytes);
    defer allocator.free(frame);
    try sendFrame(fd, frame);
    var payload: [rpc.max_frame]u8 = undefined;
    const text = try readFrame(fd, &payload);
    return decodeReply(allocator, text);
}

// ─── framing ────────────────────────────────────────────────────────────

/// The muxer's own handshake, the same one every other guest call makes.
fn handshake(fd: linux.fd_t, port: u32) !void {
    var line: [64]u8 = undefined;
    const request = try std.fmt.bufPrint(&line, "CONNECT {d}\n", .{port});
    try writeAll(fd, request);
    var seen: usize = 0;
    while (seen < line.len) {
        if (!readExact(fd, line[seen .. seen + 1])) return error.HandshakeRejected;
        seen += 1;
        if (line[seen - 1] == '\n') break;
    }
    if (seen < 2 or !std.mem.startsWith(u8, line[0..seen], "OK")) return error.HandshakeRejected;
}

pub fn sendFrame(fd: linux.fd_t, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    rpc.frameHeader(payload.len, &header);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

pub fn readFrame(fd: linux.fd_t, buf: []u8) ![]const u8 {
    var header: [4]u8 = undefined;
    if (!readExact(fd, &header)) return error.ConnectionClosed;
    const len = try rpc.framePayloadLen(header);
    if (len > buf.len) return error.FrameTooLarge;
    if (!readExact(fd, buf[0..len])) return error.ConnectionClosed;
    return buf[0..len];
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return error.ConnectionClosed;
        off += rc;
    }
}

fn readExact(fd: linux.fd_t, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

const testing = std.testing;

test "a frame this module owns is claimed, and another module's is not" {
    try testing.expect(isProxyFrame("{\"type\":\"proxy.exchange\",\"id\":1}"));
    try testing.expect(isProxyFrame("{\"type\": \"proxy.exchange\", \"id\": 1}"));
    try testing.expect(!isProxyFrame("{\"type\":\"fs.read\",\"id\":1}"));
    try testing.expect(!isProxyFrame("{\"type\":\"exec\",\"argv\":[\"ls\"]}"));
    // A frame that only MENTIONS the type belongs to the other decoder.
    try testing.expect(!isProxyFrame("{\"type\":\"exec\",\"argv\":[\"rg\",\"proxy.exchange\"]}"));
    try testing.expect(!isProxyFrame("{\"id\":1,\"type\":\"proxy.exchange\"}"));
    try testing.expect(!isProxyFrame("{\"type\":\"proxy.exchange.extra\"}"));
    try testing.expect(!isProxyFrame(""));
    try testing.expect(!isProxyFrame("{}"));
}

test "a request round-trips through the wire with its body intact" {
    const body = "GET /index.html HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n";
    const frame = try encodeRequest(testing.allocator, 7, "ws_1", 3000, body);
    defer testing.allocator.free(frame);
    var decoded = try decodeRequest(testing.allocator, frame);
    defer decoded.deinit();
    try testing.expectEqual(@as(i64, 7), decoded.value.id);
    try testing.expectEqualStrings("ws_1", decoded.value.workspace_id);
    try testing.expectEqual(@as(u16, 3000), decoded.value.port);
    try testing.expectEqualStrings(body, decoded.value.data);
}

test "a request whose body is not base64 is refused rather than guessed" {
    const frame = "{\"type\":\"proxy.exchange\",\"id\":1,\"workspace_id\":\"ws_1\",\"port\":3000,\"data_b64\":\"not base64!!\"}";
    try testing.expectError(error.BadRequest, decodeRequest(testing.allocator, frame));
}

test "a request naming a workspace-less or portless exchange is refused" {
    try testing.expectError(error.BadRequest, decodeRequest(
        testing.allocator,
        "{\"type\":\"proxy.exchange\",\"id\":1,\"workspace_id\":\"\",\"port\":3000,\"data_b64\":\"\"}",
    ));
    try testing.expectError(error.BadRequest, decodeRequest(
        testing.allocator,
        "{\"type\":\"proxy.exchange\",\"id\":1,\"workspace_id\":\"ws_1\",\"port\":0,\"data_b64\":\"\"}",
    ));
    try testing.expectError(error.BadRequest, decodeRequest(
        testing.allocator,
        "{\"type\":\"proxy.exchange\",\"id\":1,\"workspace_id\":\"ws_1\",\"port\":70000,\"data_b64\":\"\"}",
    ));
}

test "a reply carries the bytes the guest answered with" {
    const reply = try encodeReply(testing.allocator, 1, "HTTP/1.1 200 OK\r\n\r\nhi", false);
    defer testing.allocator.free(reply);
    const decoded = try decodeReply(testing.allocator, reply);
    defer decoded.deinit(testing.allocator);
    try testing.expect(!decoded.refused());
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\nhi", decoded.bytes);
}

test "a refusal comes back as the daemon's own words, not as bytes" {
    const reply = try encodeError(testing.allocator, 1, "port not declared");
    defer testing.allocator.free(reply);
    const decoded = try decodeReply(testing.allocator, reply);
    defer decoded.deinit(testing.allocator);
    try testing.expect(decoded.refused());
    try testing.expectEqualStrings("port not declared", decoded.failure.?);
}

test "only a port the workspace declared is reachable" {
    const allocator = testing.allocator;
    const declared = try parsePorts(allocator, "# dev servers\n3000\n5173\n");
    defer allocator.free(declared);
    try testing.expectEqualSlices(u16, &[_]u16{ 3000, 5173 }, declared);
    try testing.expect(portDeclared(3000, declared));
    try testing.expect(!portDeclared(8081, declared));
    try testing.expect(!portDeclared(0, declared));
    try testing.expect(!portDeclared(3000, &[_]u16{}));
}

test "a malformed port file refuses rather than publishing a port by accident" {
    try testing.expectError(error.InvalidPreviewPort, parsePorts(testing.allocator, "3000\nnot-a-port\n"));
    try testing.expectError(error.InvalidPreviewPort, parsePorts(testing.allocator, "0\n"));
    try testing.expectError(error.InvalidPreviewPort, parsePorts(testing.allocator, "70000\n"));
}
