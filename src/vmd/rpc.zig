//! `pabrik-vmd`'s wire protocol: length-prefixed JSON frames over a unix
//! socket. A request carries a workspace id, an action and that action's
//! arguments — never a VM path, a drive plan or a socket location.

const std = @import("std");
const policy = @import("policy.zig");
const fs_policy = @import("fs_policy.zig");

pub const version = "0.1";
pub const max_frame: usize = 4 * 1024 * 1024;
pub const default_timeout_ms: u32 = 10_000;
pub const default_max_output_bytes: usize = 256 * 1024;
/// One `log` reply's default and ceiling. A detached job's log is read in
/// pieces, so the default matches the `process` tool's own read cap.
pub const default_max_log_bytes: usize = 16 * 1024;
/// A base64 frame costs 4 bytes per 3, so the reply budget has to stay well
/// under `max_frame` or a legal command produces an illegal response.
pub const max_output_bytes_limit: usize = 1024 * 1024;
pub const max_log_bytes_limit: usize = 1024 * 1024;
/// One `fs.read` reply's default and ceiling. A reply is base64, so the ceiling
/// is what keeps a legal request from producing an illegal frame.
pub const default_fs_read_bytes: usize = 64 * 1024;
pub const max_fs_read_bytes: usize = 1024 * 1024;
/// A signal number a caller may ask for. SIGKILL and SIGTERM are the two the
/// tool sends; the range stops a request from naming a real-time signal.
pub const max_signal: i64 = 64;
/// A walk's default and ceiling. Both are the guest's own, so the daemon and
/// the agent bound the same walk the same way.
pub const default_walk_depth: u32 = fs_policy.max_walk_depth;
pub const default_walk_entries: usize = fs_policy.max_walk_entries;

pub const Error = error{
    BadRequest,
    UnknownAction,
    FrameTooLarge,
    EmptyFrame,
    UnknownResponse,
    InvalidBase64,
};

pub const Action = enum { ping, exec, stop, status, resize, spawn, probe, signal, log, fs_stat, fs_read, fs_remove, fs_write, fs_walk, tty, duplex };

/// Whether this action carries work into a workspace's guest: `status` and
/// `ping` only read the state file, and the console polls them for every
/// workspace, so counting them as use would pin every VM. `stop` is not use.
pub fn carriesWork(action: Action) bool {
    return switch (action) {
        .ping, .status, .stop => false,
        else => true,
    };
}

test "a status poll is not work, a command is" {
    try testing.expect(!carriesWork(.ping));
    try testing.expect(!carriesWork(.status));
    try testing.expect(!carriesWork(.stop));
    try testing.expect(carriesWork(.exec));
    try testing.expect(carriesWork(.spawn));
    try testing.expect(carriesWork(.tty));
    try testing.expect(carriesWork(.duplex));
    try testing.expect(carriesWork(.fs_read));
    try testing.expect(carriesWork(.resize));
}

/// What a `tty` request does. One action rather than five, because every one of
/// them carries the same four fields and answers with the same reply shape.
pub const TtyOp = enum { open, read, write, resize, close };

/// What a `duplex` request does: a guest process's two byte streams. Same
/// one-action shape as `TtyOp`, and for the same reason.
pub const DuplexOp = enum { open, read, write, close };

pub const Request = struct {
    id: i64 = 0,
    action: Action,
    workspace_id: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd_rel: []const u8 = "",
    timeout_ms: u32 = default_timeout_ms,
    max_output_bytes: usize = default_max_output_bytes,
    /// `spawn` and `log`: the detached job's log NAME, never its path.
    log_name: []const u8 = "",
    /// `probe` and `signal`: the pid the guest reported for a detached job.
    pid: i64 = 0,
    /// `signal`: the signal number to send.
    sig: i64 = 9,
    /// `log`: where the caller's cursor is, and how much it will take.
    offset: i64 = 0,
    max_bytes: usize = default_max_log_bytes,
    /// `fs_*`: the path RELATIVE to the workspace root. Never a host path, and
    /// never an absolute one — the daemon joins it under `/workspace`.
    path: []const u8 = "",
    /// `fs_write`: the whole body. The daemon pages it to the guest.
    data: []const u8 = "",
    /// `fs_write`: create the directories the path needs.
    create_dirs: bool = false,
    /// `fs_walk`: how deep to descend, and how many entries to report.
    max_depth: u32 = default_walk_depth,
    max_entries: usize = default_walk_entries,
    /// `tty`: which operation, and which guest tty it names. `open` mints the
    /// id, so it is the one op that ignores `tty_id`.
    tty_op: TtyOp = .open,
    tty_id: i64 = -1,
    /// `tty open` and `tty resize`: the window the caller wants.
    cols: u16 = 0,
    rows: u16 = 0,
    /// `duplex`: which operation, and which guest duplex it names. `open`
    /// mints the id, so it is the one op that ignores `duplex_id`.
    duplex_op: DuplexOp = .open,
    duplex_id: i64 = -1,
    /// `resize`: the size the workspace's VM must boot with next. Firecracker
    /// fixes both at InstanceStart, so applying them restarts the VM.
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    /// `resize`: how big the workspace's disk image must become. 0 means "leave
    /// the image alone", which is what a caller that only sizes memory sends.
    disk_mib: u32 = 0,
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

/// A detached job's identity: the pid the GUEST gave it, and the log the guest
/// writes. Neither is a host path or a host pid.
pub const Spawned = struct {
    pid: i64,
    log_path: []const u8,
};

/// Whether a detached job is still there, and which VM boot answered.
pub const Probe = struct {
    alive: bool,
    state: []const u8,
    /// The VMM pid of the boot that answered. A different one means the VM was
    /// restarted, so a job from an earlier boot is gone however the pid reads.
    boot_pid: i64,
};

/// One piece of a guest log. `missing` is its own answer: "the command never
/// started" is not "the command said nothing".
pub const LogChunk = struct {
    data: []const u8,
    size: i64,
    eof: bool,
    missing: bool,
};

/// One path's kind and size, as the guest sees it.
pub const FsStat = struct {
    kind: []const u8,
    size: i64,
    missing: bool,
};

/// One piece of a guest file. `missing` is its own answer: "the path is not
/// there" is not "the file is empty".
pub const FsChunk = struct {
    data: []const u8,
    size: i64,
    eof: bool,
    missing: bool,
};

/// One entry of a walk: a path RELATIVE to the workspace, and what it is.
pub const WalkEntry = struct {
    path: []const u8,
    kind: []const u8,
};

/// A walk's answer. `truncated` is the guest saying the tree was bigger than
/// the ceilings allowed, which is not the same as a tree that ended.
pub const FsWalk = struct {
    entries: []WalkEntry,
    count: usize,
    truncated: bool,
};

/// A terminal's answer. `data` is a `read`'s bytes and `` for every other op;
/// `message` is an `open` the guest refused and `` otherwise.
pub const TtyReply = struct {
    op: []const u8,
    tty_id: i64,
    pid: i64,
    data: []const u8,
    eof: bool,
    exited: bool,
    exit_code: i64,
    bytes: i64,
    message: []const u8,
};

/// A duplex's answer. `data` is a `read`'s bytes and `` for every other op;
/// `message` is an `open` the guest refused and `` otherwise.
pub const DuplexReply = struct {
    op: []const u8,
    duplex_id: i64,
    pid: i64,
    data: []const u8,
    eof: bool,
    exited: bool,
    exit_code: i64,
    bytes: i64,
    message: []const u8,
};

pub const Response = union(enum) {
    pong: struct { version: []const u8 },
    ack,
    status: struct { state: []const u8, pid: i64, last_error: []const u8, vcpus: u32 = 0, mem_mib: u32 = 0, disk_mib: u32 = 0 },
    exec_result: ExecResult,
    spawned: Spawned,
    probe: Probe,
    log_chunk: LogChunk,
    fs_stat: FsStat,
    fs_read: FsChunk,
    fs_walk: FsWalk,
    tty: TtyReply,
    duplex: DuplexReply,
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

    /// A byte string as base64. The body of a write is not text, so it does
    /// not go through `writeQuoted`'s byte-by-byte escaping.
    fn base64Field(
        self: *ObjectWriter,
        allocator: std.mem.Allocator,
        key: []const u8,
        bytes: []const u8,
    ) !void {
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(bytes.len));
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, bytes);
        try self.strField(allocator, key, encoded);
    }

    fn walkEntriesField(
        self: *ObjectWriter,
        allocator: std.mem.Allocator,
        key: []const u8,
        entries: []const WalkEntry,
    ) !void {
        try self.open(allocator, key);
        try self.list.append(allocator, '[');
        for (entries, 0..) |entry, i| {
            if (i > 0) try self.list.append(allocator, ',');
            try self.list.appendSlice(allocator, "{\"path\":");
            try self.writeQuoted(allocator, entry.path);
            try self.list.appendSlice(allocator, ",\"kind\":");
            try self.writeQuoted(allocator, entry.kind);
            try self.list.append(allocator, '}');
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
    if (request.action == .exec or request.action == .spawn or
        (request.action == .duplex and request.duplex_op == .open))
    {
        try out.strArrayField(allocator, "argv", request.argv);
        try out.strField(allocator, "cwd_rel", request.cwd_rel);
    }
    if (request.action == .exec) {
        try out.intField(allocator, "timeout_ms", @intCast(request.timeout_ms));
        try out.intField(allocator, "max_output_bytes", @intCast(request.max_output_bytes));
    }
    if (request.action == .spawn or request.action == .log) {
        try out.strField(allocator, "log_name", request.log_name);
    }
    if (request.action == .probe or request.action == .signal) {
        try out.intField(allocator, "pid", request.pid);
    }
    if (request.action == .resize) {
        try out.intField(allocator, "vcpus", @intCast(request.vcpus));
        try out.intField(allocator, "mem_mib", @intCast(request.mem_mib));
        if (request.disk_mib != 0) try out.intField(allocator, "disk_mib", @intCast(request.disk_mib));
    }
    if (request.action == .signal) {
        try out.intField(allocator, "signal", request.sig);
    }
    if (request.action == .log) {
        try out.intField(allocator, "offset", request.offset);
        try out.intField(allocator, "max_bytes", @intCast(request.max_bytes));
    }
    if (request.action == .fs_stat or request.action == .fs_read or request.action == .fs_remove or
        request.action == .fs_write or request.action == .fs_walk)
    {
        try out.strField(allocator, "path", request.path);
    }
    if (request.action == .fs_read) {
        try out.intField(allocator, "offset", request.offset);
        try out.intField(allocator, "max_bytes", @intCast(request.max_bytes));
    }
    if (request.action == .fs_write) {
        try out.base64Field(allocator, "data_b64", request.data);
        try out.boolField(allocator, "create_dirs", request.create_dirs);
    }
    if (request.action == .fs_walk) {
        try out.intField(allocator, "max_depth", @intCast(request.max_depth));
        try out.intField(allocator, "max_entries", @intCast(request.max_entries));
    }
    if (request.action == .tty) {
        try out.strField(allocator, "tty_op", @tagName(request.tty_op));
        if (request.tty_op != .open) try out.intField(allocator, "tty_id", request.tty_id);
        if (request.tty_op == .open or request.tty_op == .resize) {
            try out.intField(allocator, "cols", @intCast(request.cols));
            try out.intField(allocator, "rows", @intCast(request.rows));
        }
        if (request.tty_op == .open) try out.strField(allocator, "cwd_rel", request.cwd_rel);
        if (request.tty_op == .read) try out.intField(allocator, "max_bytes", @intCast(request.max_bytes));
        if (request.tty_op == .write) try out.base64Field(allocator, "data_b64", request.data);
    }
    if (request.action == .duplex) {
        try out.strField(allocator, "duplex_op", @tagName(request.duplex_op));
        if (request.duplex_op != .open) try out.intField(allocator, "duplex_id", request.duplex_id);
        if (request.duplex_op == .read) try out.intField(allocator, "max_bytes", @intCast(request.max_bytes));
        if (request.duplex_op == .write) try out.base64Field(allocator, "data_b64", request.data);
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

    if (action == .spawn or action == .probe or action == .signal or action == .log) {
        try decodeJobAction(object, aa, action, &request);
        return .{ .arena = arena, .value = request };
    }

    if (action == .fs_stat or action == .fs_read or action == .fs_remove) {
        try decodeFsAction(object, action, &request);
        return .{ .arena = arena, .value = request };
    }

    if (action == .fs_write or action == .fs_walk) {
        try decodeFsWriteWalk(object, aa, action, &request);
        return .{ .arena = arena, .value = request };
    }

    if (action == .tty) {
        try decodeTtyAction(object, aa, &request);
        return .{ .arena = arena, .value = request };
    }

    if (action == .duplex) {
        try decodeDuplexAction(object, aa, &request);
        return .{ .arena = arena, .value = request };
    }

    if (action == .resize) {
        // The size rides in the request: the daemon has no database to look it
        // up in, and the caller is the one that decided it.
        const vcpus = integerField(object, "vcpus") orelse return Error.BadRequest;
        const mem_mib = integerField(object, "mem_mib") orelse return Error.BadRequest;
        if (vcpus <= 0 or mem_mib <= 0) return Error.BadRequest;
        request.vcpus = @intCast(vcpus);
        request.mem_mib = @intCast(mem_mib);
        if (integerField(object, "disk_mib")) |disk_mib| {
            if (disk_mib < 0) return Error.BadRequest;
            request.disk_mib = @intCast(disk_mib);
        }
        return .{ .arena = arena, .value = request };
    }

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

/// The four actions a detached job needs — and nothing about them may name a
/// path: `log_name` is a token the daemon turns into a path it owns.
fn decodeJobAction(
    object: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    action: Action,
    request: *Request,
) !void {
    if (action == .spawn) {
        const argv_value = object.get("argv") orelse return Error.BadRequest;
        const items = switch (argv_value) {
            .array => |a| a,
            else => return Error.BadRequest,
        };
        if (items.items.len == 0) return Error.BadRequest;
        const argv = try allocator.alloc([]const u8, items.items.len);
        for (items.items, 0..) |item, i| {
            argv[i] = switch (item) {
                .string => |t| t,
                else => return Error.BadRequest,
            };
        }
        request.argv = argv;
        const cwd_rel = stringField(object, "cwd_rel") orelse return Error.BadRequest;
        if (!policy.cwdRelValid(cwd_rel)) return Error.BadRequest;
        request.cwd_rel = cwd_rel;
    }
    if (action == .probe or action == .signal) {
        const pid = integerField(object, "pid") orelse return Error.BadRequest;
        if (pid <= 0) return Error.BadRequest;
        request.pid = pid;
    }
    if (action == .signal) {
        if (integerField(object, "signal")) |sig| {
            if (sig <= 0 or sig > max_signal) return Error.BadRequest;
            request.sig = sig;
        }
    }
    if (action == .spawn or action == .log) {
        const log_name = stringField(object, "log_name") orelse return Error.BadRequest;
        if (!policy.logNameValid(log_name)) return Error.BadRequest;
        request.log_name = log_name;
    }
    if (action == .log) {
        if (integerField(object, "offset")) |offset| {
            if (offset < 0) return Error.BadRequest;
            request.offset = offset;
        }
        if (integerField(object, "max_bytes")) |bytes| {
            if (bytes <= 0 or bytes > max_log_bytes_limit) return Error.BadRequest;
            request.max_bytes = @intCast(bytes);
        }
    }
}

/// The three file actions. The path is relative to the workspace and is checked
/// here as well as in the guest: a refusal the daemon can name beats one the
/// agent has to spell out.
fn decodeFsAction(
    object: std.json.ObjectMap,
    action: Action,
    request: *Request,
) !void {
    const path = stringField(object, "path") orelse return Error.BadRequest;
    if (!fs_policy.pathRelValid(path)) return Error.BadRequest;
    request.path = path;

    if (action != .fs_read) return;
    if (integerField(object, "offset")) |offset| {
        if (offset < 0) return Error.BadRequest;
        request.offset = offset;
    }
    if (integerField(object, "max_bytes")) |bytes| {
        if (bytes <= 0 or bytes > max_fs_read_bytes) return Error.BadRequest;
        request.max_bytes = @intCast(bytes);
    } else {
        request.max_bytes = default_fs_read_bytes;
    }
}

/// The two actions that carry more than a path. A write's body is bounded by
/// the frame it has to fit, and refused here rather than at the agent, which
/// would have to spell the same refusal out.
fn decodeFsWriteWalk(
    object: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    action: Action,
    request: *Request,
) !void {
    const path = stringField(object, "path") orelse return Error.BadRequest;
    request.path = path;

    if (action == .fs_walk) {
        // A walk may start at the workspace root, which is the one path a
        // file op may not name.
        if (!fs_policy.dirRelValid(path)) return Error.BadRequest;
        if (integerField(object, "max_depth")) |depth| {
            if (depth <= 0 or depth > fs_policy.max_walk_depth) return Error.BadRequest;
            request.max_depth = @intCast(depth);
        }
        if (integerField(object, "max_entries")) |entries| {
            if (entries <= 0 or entries > fs_policy.max_walk_entries) return Error.BadRequest;
            request.max_entries = @intCast(entries);
        }
        return;
    }

    if (!fs_policy.pathRelValid(path)) return Error.BadRequest;
    request.create_dirs = boolField(object, "create_dirs");
    const body = stringField(object, "data_b64") orelse return Error.BadRequest;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(body) catch return Error.InvalidBase64;
    if (size > fs_policy.max_write_bytes) return Error.BadRequest;
    const data = try allocator.alloc(u8, size);
    decoder.decode(data, body) catch return Error.InvalidBase64;
    request.data = data;
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
    return encodeStatusSized(allocator, id, state, pid, last_error, 0, 0, 0);
}

/// `encodeStatus` with the size the workspace boots with, so a caller can show
/// it without a second round trip.
pub fn encodeStatusSized(
    allocator: std.mem.Allocator,
    id: i64,
    state: []const u8,
    pid: i64,
    last_error: []const u8,
    vcpus: u32,
    mem_mib: u32,
    disk_mib: u32,
) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "status");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "state", state);
    try out.intField(allocator, "pid", pid);
    if (vcpus != 0) try out.intField(allocator, "vcpus", @intCast(vcpus));
    if (mem_mib != 0) try out.intField(allocator, "mem_mib", @intCast(mem_mib));
    if (disk_mib != 0) try out.intField(allocator, "disk_mib", @intCast(disk_mib));
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

pub fn encodeSpawned(allocator: std.mem.Allocator, id: i64, pid: i64, log_path: []const u8) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "spawn.result");
    try out.intField(allocator, "id", id);
    try out.intField(allocator, "pid", pid);
    try out.strField(allocator, "log_path", log_path);
    return out.finish(allocator);
}

pub fn encodeProbe(
    allocator: std.mem.Allocator,
    id: i64,
    alive: bool,
    state: []const u8,
    boot_pid: i64,
) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "probe.result");
    try out.intField(allocator, "id", id);
    try out.boolField(allocator, "alive", alive);
    try out.strField(allocator, "state", state);
    try out.intField(allocator, "boot_pid", boot_pid);
    return out.finish(allocator);
}

pub fn encodeLogChunk(allocator: std.mem.Allocator, id: i64, chunk: LogChunk) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "log.chunk");
    try out.intField(allocator, "id", id);
    if (chunk.missing) {
        try out.boolField(allocator, "missing", true);
        return out.finish(allocator);
    }
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(chunk.data.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, chunk.data);
    try out.strField(allocator, "data_b64", encoded);
    try out.intField(allocator, "size", chunk.size);
    try out.boolField(allocator, "eof", chunk.eof);
    return out.finish(allocator);
}

pub fn encodeFsStat(allocator: std.mem.Allocator, id: i64, stat: FsStat) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "fs.stat");
    try out.intField(allocator, "id", id);
    if (stat.missing) {
        try out.boolField(allocator, "missing", true);
        return out.finish(allocator);
    }
    try out.strField(allocator, "kind", stat.kind);
    try out.intField(allocator, "size", stat.size);
    return out.finish(allocator);
}

pub fn encodeFsRead(allocator: std.mem.Allocator, id: i64, chunk: FsChunk) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "fs.read");
    try out.intField(allocator, "id", id);
    if (chunk.missing) {
        try out.boolField(allocator, "missing", true);
        return out.finish(allocator);
    }
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(chunk.data.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, chunk.data);
    try out.strField(allocator, "data_b64", encoded);
    try out.intField(allocator, "size", chunk.size);
    try out.boolField(allocator, "eof", chunk.eof);
    return out.finish(allocator);
}

pub fn encodeFsWalk(allocator: std.mem.Allocator, id: i64, walk: FsWalk) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "fs.walk");
    try out.intField(allocator, "id", id);
    try out.boolField(allocator, "truncated", walk.truncated);
    try out.intField(allocator, "count", @intCast(walk.count));
    try out.walkEntriesField(allocator, "entries", walk.entries);
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
            .vcpus = @intCast(@max(0, integerField(object, "vcpus") orelse 0)),
            .mem_mib = @intCast(@max(0, integerField(object, "mem_mib") orelse 0)),
            .disk_mib = @intCast(@max(0, integerField(object, "disk_mib") orelse 0)),
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
    if (std.mem.eql(u8, kind, "spawn.result")) {
        return .{ .arena = arena, .value = .{ .spawned = .{
            .pid = integerField(object, "pid") orelse -1,
            .log_path = stringField(object, "log_path") orelse "",
        } } };
    }
    if (std.mem.eql(u8, kind, "probe.result")) {
        return .{ .arena = arena, .value = .{ .probe = .{
            .alive = boolField(object, "alive"),
            .state = stringField(object, "state") orelse "",
            .boot_pid = integerField(object, "boot_pid") orelse 0,
        } } };
    }
    if (std.mem.eql(u8, kind, "log.chunk")) {
        if (boolField(object, "missing")) {
            return .{ .arena = arena, .value = .{ .log_chunk = .{
                .data = "",
                .size = 0,
                .eof = true,
                .missing = true,
            } } };
        }
        const data = try decodeBase64Field(aa, object, "data_b64");
        return .{ .arena = arena, .value = .{ .log_chunk = .{
            .data = data,
            .size = integerField(object, "size") orelse @intCast(data.len),
            .eof = boolField(object, "eof"),
            .missing = false,
        } } };
    }
    if (std.mem.eql(u8, kind, "fs.stat")) {
        if (boolField(object, "missing")) {
            return .{ .arena = arena, .value = .{ .fs_stat = .{ .kind = "", .size = 0, .missing = true } } };
        }
        return .{ .arena = arena, .value = .{ .fs_stat = .{
            .kind = stringField(object, "kind") orelse "file",
            .size = integerField(object, "size") orelse 0,
            .missing = false,
        } } };
    }
    if (std.mem.eql(u8, kind, "fs.read")) {
        if (boolField(object, "missing")) {
            return .{ .arena = arena, .value = .{ .fs_read = .{
                .data = "",
                .size = 0,
                .eof = true,
                .missing = true,
            } } };
        }
        const data = try decodeBase64Field(aa, object, "data_b64");
        return .{ .arena = arena, .value = .{ .fs_read = .{
            .data = data,
            .size = integerField(object, "size") orelse @intCast(data.len),
            .eof = boolField(object, "eof"),
            .missing = false,
        } } };
    }
    if (std.mem.eql(u8, kind, "fs.walk")) {
        const items = blk: {
            const value = object.get("entries") orelse break :blk &[_]std.json.Value{};
            break :blk switch (value) {
                .array => |a| a.items,
                else => return Error.BadRequest,
            };
        };
        const entries = try aa.alloc(WalkEntry, items.len);
        for (items, 0..) |item, i| {
            const entry = switch (item) {
                .object => |o| o,
                else => return Error.BadRequest,
            };
            entries[i] = .{
                .path = stringField(entry, "path") orelse return Error.BadRequest,
                .kind = stringField(entry, "kind") orelse return Error.BadRequest,
            };
        }
        return .{ .arena = arena, .value = .{ .fs_walk = .{
            .entries = entries,
            .count = @intCast(integerField(object, "count") orelse @as(i64, @intCast(entries.len))),
            .truncated = boolField(object, "truncated"),
        } } };
    }
    if (std.mem.eql(u8, kind, "tty")) {
        const data = if (object.get("data_b64")) |_| try decodeBase64Field(aa, object, "data_b64") else "";
        return .{ .arena = arena, .value = .{ .tty = .{
            .op = stringField(object, "tty_op") orelse "",
            .tty_id = integerField(object, "tty_id") orelse -1,
            .pid = integerField(object, "pid") orelse 0,
            .data = data,
            .eof = boolField(object, "eof"),
            .exited = boolField(object, "exited"),
            .exit_code = integerField(object, "exit_code") orelse 0,
            .bytes = integerField(object, "bytes") orelse 0,
            .message = stringField(object, "message") orelse "",
        } } };
    }
    if (std.mem.eql(u8, kind, "duplex")) {
        const data = if (object.get("data_b64")) |_| try decodeBase64Field(aa, object, "data_b64") else "";
        return .{ .arena = arena, .value = .{ .duplex = .{
            .op = stringField(object, "duplex_op") orelse "",
            .duplex_id = integerField(object, "duplex_id") orelse -1,
            .pid = integerField(object, "pid") orelse 0,
            .data = data,
            .eof = boolField(object, "eof"),
            .exited = boolField(object, "exited"),
            .exit_code = integerField(object, "exit_code") orelse 0,
            .bytes = integerField(object, "bytes") orelse 0,
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

/// The terminal action. `open` names a DIRECTORY inside the workspace; every
/// other op names a tty id the daemon itself minted, never a port or a pid.
fn decodeTtyAction(
    object: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    request: *Request,
) !void {
    const op_text = stringField(object, "tty_op") orelse return Error.BadRequest;
    const op = std.meta.stringToEnum(TtyOp, op_text) orelse return Error.BadRequest;
    request.tty_op = op;

    if (op == .open) {
        const cwd_rel = stringField(object, "cwd_rel") orelse return Error.BadRequest;
        if (!policy.cwdRelValid(cwd_rel)) return Error.BadRequest;
        request.cwd_rel = cwd_rel;
        request.cols = try ttyDimField(object, "cols");
        request.rows = try ttyDimField(object, "rows");
        return;
    }

    const id = integerField(object, "tty_id") orelse return Error.BadRequest;
    if (!policy.ttyIdValid(id)) return Error.BadRequest;
    request.tty_id = id;

    if (op == .resize) {
        request.cols = try ttyDimField(object, "cols");
        request.rows = try ttyDimField(object, "rows");
    }
    if (op == .read) {
        const bytes = integerField(object, "max_bytes") orelse return Error.BadRequest;
        if (bytes <= 0 or bytes > policy.max_tty_chunk) return Error.BadRequest;
        request.max_bytes = @intCast(bytes);
    }
    if (op == .write) {
        const text = stringField(object, "data_b64") orelse return Error.BadRequest;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(text) catch return Error.InvalidBase64;
        if (size == 0 or size > policy.max_tty_chunk) return Error.BadRequest;
        const data = try allocator.alloc(u8, size);
        decoder.decode(data, text) catch return Error.InvalidBase64;
        request.data = data;
    }
}

/// The duplex action. `open` names an argv the guest runs; every other op
/// names a duplex id the daemon itself minted, never a port or a pid.
fn decodeDuplexAction(
    object: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    request: *Request,
) !void {
    const op_text = stringField(object, "duplex_op") orelse return Error.BadRequest;
    const op = std.meta.stringToEnum(DuplexOp, op_text) orelse return Error.BadRequest;
    request.duplex_op = op;

    if (op == .open) {
        const argv_value = object.get("argv") orelse return Error.BadRequest;
        const items = switch (argv_value) {
            .array => |a| a,
            else => return Error.BadRequest,
        };
        if (items.items.len == 0) return Error.BadRequest;
        const argv = try allocator.alloc([]const u8, items.items.len);
        for (items.items, 0..) |item, i| {
            argv[i] = switch (item) {
                .string => |t| t,
                else => return Error.BadRequest,
            };
        }
        request.argv = argv;

        const cwd_rel = stringField(object, "cwd_rel") orelse return Error.BadRequest;
        if (!policy.cwdRelValid(cwd_rel)) return Error.BadRequest;
        request.cwd_rel = cwd_rel;
        return;
    }

    const id = integerField(object, "duplex_id") orelse return Error.BadRequest;
    if (!policy.duplexIdValid(id)) return Error.BadRequest;
    request.duplex_id = id;

    if (op == .read) {
        const bytes = integerField(object, "max_bytes") orelse return Error.BadRequest;
        if (bytes <= 0 or bytes > policy.max_duplex_chunk) return Error.BadRequest;
        request.max_bytes = @intCast(bytes);
    }
    if (op == .write) {
        const text = stringField(object, "data_b64") orelse return Error.BadRequest;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(text) catch return Error.InvalidBase64;
        if (size == 0 or size > policy.max_duplex_chunk) return Error.BadRequest;
        const data = try allocator.alloc(u8, size);
        decoder.decode(data, text) catch return Error.InvalidBase64;
        request.data = data;
    }
}

fn ttyDimField(object: std.json.ObjectMap, key: []const u8) !u16 {
    const value = integerField(object, key) orelse return Error.BadRequest;
    if (value < 0 or value > std.math.maxInt(u16)) return Error.BadRequest;
    return @intCast(value);
}

pub fn encodeTtyReply(allocator: std.mem.Allocator, id: i64, reply: TtyReply) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "tty");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "tty_op", reply.op);
    try out.intField(allocator, "tty_id", reply.tty_id);
    try out.intField(allocator, "pid", reply.pid);
    try out.intField(allocator, "exit_code", reply.exit_code);
    try out.intField(allocator, "bytes", reply.bytes);
    try out.boolField(allocator, "eof", reply.eof);
    try out.boolField(allocator, "exited", reply.exited);
    if (reply.message.len > 0) try out.strField(allocator, "message", reply.message);
    if (reply.data.len > 0) try out.base64Field(allocator, "data_b64", reply.data);
    return out.finish(allocator);
}

pub fn encodeDuplexReply(allocator: std.mem.Allocator, id: i64, reply: DuplexReply) ![]u8 {
    var out = try ObjectWriter.init(allocator);
    errdefer out.list.deinit(allocator);
    try out.strField(allocator, "type", "duplex");
    try out.intField(allocator, "id", id);
    try out.strField(allocator, "duplex_op", reply.op);
    try out.intField(allocator, "duplex_id", reply.duplex_id);
    try out.intField(allocator, "pid", reply.pid);
    try out.intField(allocator, "exit_code", reply.exit_code);
    try out.intField(allocator, "bytes", reply.bytes);
    try out.boolField(allocator, "eof", reply.eof);
    try out.boolField(allocator, "exited", reply.exited);
    if (reply.message.len > 0) try out.strField(allocator, "message", reply.message);
    if (reply.data.len > 0) try out.base64Field(allocator, "data_b64", reply.data);
    return out.finish(allocator);
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

test "rpc: a spawn request carries argv, cwd and a log NAME — never a path" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .spawn,
        .id = 11,
        .workspace_id = "ws_1",
        .argv = &.{ "/bin/sh", "-c", "make -j4" },
        .cwd_rel = "src",
        .log_name = "bg_1712345678901.log",
    });
    defer allocator.free(encoded);

    var owned = try decodeRequest(allocator, encoded);
    defer owned.deinit();
    try testing.expectEqual(Action.spawn, owned.value.action);
    try testing.expectEqualStrings("bg_1712345678901.log", owned.value.log_name);
    try testing.expectEqualStrings("src", owned.value.cwd_rel);
    try testing.expectEqual(@as(usize, 3), owned.value.argv.len);
    // The name is a token; the recoder never emits a directory.
    try testing.expect(std.mem.indexOf(u8, encoded, "/tmp/pabrik") == null);
    try testing.expect(std.mem.indexOf(u8, encoded, "log_path") == null);
}

test "rpc: a job request that names a path, or a pid that is not one, is refused" {
    const allocator = testing.allocator;
    const hostile = [_][]const u8{
        \\{"type":"request","action":"spawn","id":1,"workspace_id":"ws_1",\\
        \\ "argv":["/bin/sh"],"cwd_rel":"","log_name":"../../etc/passwd"}
        ,
        \\{"type":"request","action":"spawn","id":1,"workspace_id":"ws_1",\\
        \\ "argv":["/bin/sh"],"cwd_rel":"","log_name":"/tmp/pabrik/x.log"}
        ,
        \\{"type":"request","action":"spawn","id":1,"workspace_id":"ws_1",\\
        \\ "argv":["/bin/sh"],"cwd_rel":"","log_name":"ok.log","log_path":"/etc/shadow"}
        ,
        \\{"type":"request","action":"log","id":1,"workspace_id":"ws_1","log_name":"ok.log","offset":-1}
        ,
        \\{"type":"request","action":"log","id":1,"workspace_id":"ws_1","log_name":"ok.log","max_bytes":0}
        ,
        \\{"type":"request","action":"probe","id":1,"workspace_id":"ws_1","pid":0}
        ,
        \\{"type":"request","action":"signal","id":1,"workspace_id":"ws_1","pid":7,"signal":9999}
    };
    for (hostile) |text| {
        try testing.expectError(Error.BadRequest, decodeRequest(allocator, text));
    }
}

test "rpc: probe, signal and log requests round-trip their own fields" {
    const allocator = testing.allocator;

    const probe_frame = try encodeRequest(allocator, .{
        .action = .probe,
        .id = 2,
        .workspace_id = "ws_1",
        .pid = 4242,
    });
    defer allocator.free(probe_frame);
    var probe = try decodeRequest(allocator, probe_frame);
    defer probe.deinit();
    try testing.expectEqual(@as(i64, 4242), probe.value.pid);

    const signal_frame = try encodeRequest(allocator, .{
        .action = .signal,
        .id = 3,
        .workspace_id = "ws_1",
        .pid = 4242,
        .sig = 15,
    });
    defer allocator.free(signal_frame);
    var signal = try decodeRequest(allocator, signal_frame);
    defer signal.deinit();
    try testing.expectEqual(@as(i64, 15), signal.value.sig);

    const log_frame = try encodeRequest(allocator, .{
        .action = .log,
        .id = 4,
        .workspace_id = "ws_1",
        .log_name = "bg_1.log",
        .offset = 4096,
        .max_bytes = 1024,
    });
    defer allocator.free(log_frame);
    var log = try decodeRequest(allocator, log_frame);
    defer log.deinit();
    try testing.expectEqual(@as(i64, 4096), log.value.offset);
    try testing.expectEqual(@as(usize, 1024), log.value.max_bytes);
}

test "rpc: a spawn, probe and log reply decode to their own shape" {
    const allocator = testing.allocator;

    const spawned = try encodeSpawned(allocator, 1, 77, "/tmp/pabrik/bg_1.log");
    defer allocator.free(spawned);
    var own_spawn = try decodeResponse(allocator, spawned);
    defer own_spawn.deinit();
    switch (own_spawn.value) {
        .spawned => |s| {
            try testing.expectEqual(@as(i64, 77), s.pid);
            try testing.expectEqualStrings("/tmp/pabrik/bg_1.log", s.log_path);
        },
        else => return error.TestExpectedSpawned,
    }

    const probed = try encodeProbe(allocator, 1, false, "ready", 908967);
    defer allocator.free(probed);
    var own_probe = try decodeResponse(allocator, probed);
    defer own_probe.deinit();
    switch (own_probe.value) {
        .probe => |p| {
            try testing.expect(!p.alive);
            try testing.expectEqualStrings("ready", p.state);
            try testing.expectEqual(@as(i64, 908967), p.boot_pid);
        },
        else => return error.TestExpectedProbe,
    }

    const chunk = try encodeLogChunk(allocator, 1, .{
        .data = "build ok\n",
        .size = 9,
        .eof = true,
        .missing = false,
    });
    defer allocator.free(chunk);
    var own_chunk = try decodeResponse(allocator, chunk);
    defer own_chunk.deinit();
    switch (own_chunk.value) {
        .log_chunk => |c| {
            try testing.expectEqualStrings("build ok\n", c.data);
            try testing.expectEqual(@as(i64, 9), c.size);
            try testing.expect(c.eof);
            try testing.expect(!c.missing);
        },
        else => return error.TestExpectedLogChunk,
    }

    // A missing log is its own answer, and carries no bytes to mistake for
    // empty output.
    const missing = try encodeLogChunk(allocator, 1, .{
        .data = "",
        .size = 0,
        .eof = true,
        .missing = true,
    });
    defer allocator.free(missing);
    var own_missing = try decodeResponse(allocator, missing);
    defer own_missing.deinit();
    switch (own_missing.value) {
        .log_chunk => |c| try testing.expect(c.missing),
        else => return error.TestExpectedLogChunk,
    }
}

test "rpc: a duplex open carries the argv the guest runs, and no id" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .duplex,
        .id = 11,
        .workspace_id = "ws_1",
        .duplex_op = .open,
        .argv = &.{ "npx", "-y", "@modelcontextprotocol/server-filesystem" },
        .cwd_rel = "src",
    });
    defer allocator.free(encoded);

    var owned = try decodeRequest(allocator, encoded);
    defer owned.deinit();
    try testing.expectEqual(Action.duplex, owned.value.action);
    try testing.expectEqual(DuplexOp.open, owned.value.duplex_op);
    try testing.expectEqualStrings("ws_1", owned.value.workspace_id);
    try testing.expectEqualStrings("src", owned.value.cwd_rel);
    try testing.expectEqual(@as(usize, 3), owned.value.argv.len);
    try testing.expectEqualStrings("npx", owned.value.argv[0]);
    try testing.expectEqual(@as(i64, -1), owned.value.duplex_id);
}

test "rpc: duplex read and write name a minted id, never a port or a pid" {
    const allocator = testing.allocator;

    const read_encoded = try encodeRequest(allocator, .{
        .action = .duplex,
        .id = 12,
        .workspace_id = "ws_1",
        .duplex_op = .read,
        .duplex_id = 3,
        .max_bytes = 4096,
    });
    defer allocator.free(read_encoded);
    var read_owned = try decodeRequest(allocator, read_encoded);
    defer read_owned.deinit();
    try testing.expectEqual(DuplexOp.read, read_owned.value.duplex_op);
    try testing.expectEqual(@as(i64, 3), read_owned.value.duplex_id);
    try testing.expectEqual(@as(usize, 4096), read_owned.value.max_bytes);

    const write_encoded = try encodeRequest(allocator, .{
        .action = .duplex,
        .id = 13,
        .workspace_id = "ws_1",
        .duplex_op = .write,
        .duplex_id = 3,
        .data = "{\"jsonrpc\":\"2.0\"}\n",
    });
    defer allocator.free(write_encoded);
    var write_owned = try decodeRequest(allocator, write_encoded);
    defer write_owned.deinit();
    try testing.expectEqual(DuplexOp.write, write_owned.value.duplex_op);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}\n", write_owned.value.data);
}

test "rpc: a duplex id outside the guest's table is refused, not clamped" {
    const allocator = testing.allocator;
    const hostile = try std.fmt.allocPrint(allocator,
        \\{{"type":"request","action":"duplex","id":1,"workspace_id":"ws_1",
        \\ "duplex_op":"read","duplex_id":{d},"max_bytes":16}}
    , .{policy.max_duplex});
    defer allocator.free(hostile);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, hostile));

    const negative = try std.fmt.allocPrint(allocator,
        \\{{"type":"request","action":"duplex","id":1,"workspace_id":"ws_1",
        \\ "duplex_op":"close","duplex_id":-1}}
    , .{});
    defer allocator.free(negative);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, negative));
}

test "rpc: a duplex read over the chunk ceiling is refused" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .duplex,
        .workspace_id = "ws_1",
        .duplex_op = .read,
        .duplex_id = 0,
        .max_bytes = policy.max_duplex_chunk + 1,
    });
    defer allocator.free(encoded);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, encoded));
}

test "rpc: a duplex reply carries its bytes, its end and its exit" {
    const allocator = testing.allocator;
    const encoded = try encodeDuplexReply(allocator, 21, .{
        .op = "read",
        .duplex_id = 2,
        .pid = 4242,
        .data = "{\"id\":1}\n",
        .eof = false,
        .exited = true,
        .exit_code = 7,
        .bytes = 0,
        .message = "",
    });
    defer allocator.free(encoded);

    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const reply = owned.value.duplex;
    try testing.expectEqualStrings("read", reply.op);
    try testing.expectEqual(@as(i64, 2), reply.duplex_id);
    try testing.expectEqual(@as(i64, 4242), reply.pid);
    try testing.expectEqualStrings("{\"id\":1}\n", reply.data);
    try testing.expect(!reply.eof);
    try testing.expect(reply.exited);
    try testing.expectEqual(@as(i64, 7), reply.exit_code);
}

test "rpc: a duplex open the guest refused keeps the guest's own words" {
    const allocator = testing.allocator;
    const encoded = try encodeDuplexReply(allocator, 22, .{
        .op = "open",
        .duplex_id = -1,
        .pid = 0,
        .data = "",
        .eof = false,
        .exited = false,
        .exit_code = 0,
        .bytes = 0,
        .message = "all 8 duplexes are in use",
    });
    defer allocator.free(encoded);

    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const reply = owned.value.duplex;
    try testing.expectEqual(@as(i64, -1), reply.duplex_id);
    try testing.expectEqualStrings("all 8 duplexes are in use", reply.message);
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

test "a resize request carries the size it asks for" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .resize,
        .id = 31,
        .workspace_id = "ws_1",
        .vcpus = 2,
        .mem_mib = 1024,
        .disk_mib = 4096,
    });
    defer allocator.free(encoded);
    var decoded = try decodeRequest(allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(Action.resize, decoded.value.action);
    try testing.expectEqualStrings("ws_1", decoded.value.workspace_id);
    try testing.expectEqual(@as(u32, 2), decoded.value.vcpus);
    try testing.expectEqual(@as(u32, 1024), decoded.value.mem_mib);
    try testing.expectEqual(@as(u32, 4096), decoded.value.disk_mib);
}

test "a resize that only names vCPUs and memory leaves the disk alone" {
    const allocator = testing.allocator;
    // A caller written before the disk existed sends no `disk_mib` at all; 0 is
    // the daemon's "do not touch the image".
    var decoded = try decodeRequest(allocator,
        \\{"type":"request","action":"resize","id":5,"workspace_id":"ws_1","vcpus":1,"mem_mib":512}
    );
    defer decoded.deinit();
    try testing.expectEqual(@as(u32, 0), decoded.value.disk_mib);
}

test "a status answer carries the disk size back" {
    const allocator = testing.allocator;
    const encoded = try encodeStatusSized(allocator, 12, "ready", 999, "", 4, 2048, 8192);
    defer allocator.free(encoded);
    var decoded = try decodeResponse(allocator, encoded);
    defer decoded.deinit();
    switch (decoded.value) {
        .status => |s| {
            try testing.expectEqual(@as(u32, 4), s.vcpus);
            try testing.expectEqual(@as(u32, 2048), s.mem_mib);
            try testing.expectEqual(@as(u32, 8192), s.disk_mib);
        },
        else => return error.TestExpectedStatus,
    }
}

test "fs actions: a relative path crosses whole, with its offset and ceiling" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .fs_read,
        .id = 7,
        .workspace_id = "ws_1",
        .path = "src/main.zig",
        .offset = 10,
        .max_bytes = 4096,
    });
    defer allocator.free(encoded);
    var decoded = try decodeRequest(allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(Action.fs_read, decoded.value.action);
    try testing.expectEqualStrings("src/main.zig", decoded.value.path);
    try testing.expectEqual(@as(i64, 10), decoded.value.offset);
    try testing.expectEqual(@as(usize, 4096), decoded.value.max_bytes);
}

test "fs_write: a body crosses base64, and one over the ceiling is refused" {
    const allocator = testing.allocator;
    const encoded = try encodeRequest(allocator, .{
        .action = .fs_write,
        .id = 9,
        .workspace_id = "ws_1",
        .path = "src/main.zig",
        .data = "hello\n",
        .create_dirs = true,
    });
    defer allocator.free(encoded);
    // The body is bytes on the wire, so it is base64 there.
    try testing.expect(std.mem.indexOf(u8, encoded, "aGVsbG8K") != null);

    var decoded = try decodeRequest(allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(Action.fs_write, decoded.value.action);
    try testing.expectEqualStrings("src/main.zig", decoded.value.path);
    try testing.expectEqualStrings("hello\n", decoded.value.data);
    try testing.expect(decoded.value.create_dirs);

    // A body the frame could not hold is refused before the guest is asked.
    const big = try allocator.alloc(u8, fs_policy.max_write_bytes + 1);
    defer allocator.free(big);
    @memset(big, 'x');
    const over = try encodeRequest(allocator, .{
        .action = .fs_write,
        .id = 9,
        .workspace_id = "ws_1",
        .path = "a.txt",
        .data = big,
    });
    defer allocator.free(over);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, over));
}

test "fs_write: a body that is not base64 is refused, not written" {
    const allocator = testing.allocator;
    try testing.expectError(Error.InvalidBase64, decodeRequest(allocator,
        \\{"action":"fs_write","id":1,"workspace_id":"ws_1","path":"a.txt","data_b64":"not base64!"}
    ));
    // A write with no body at all is a caller bug, not an empty file.
    try testing.expectError(Error.BadRequest, decodeRequest(allocator,
        \\{"action":"fs_write","id":1,"workspace_id":"ws_1","path":"a.txt"}
    ));
}

test "fs_walk: the root is a legal start, an escape is not, and depth is bounded" {
    const allocator = testing.allocator;
    var at_root = try decodeRequest(allocator,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"","max_depth":4,"max_entries":100}
    );
    defer at_root.deinit();
    try testing.expectEqual(@as(u32, 4), at_root.value.max_depth);
    try testing.expectEqual(@as(usize, 100), at_root.value.max_entries);
    // No ceilings on the wire means the guest's own, not none.
    var defaults = try decodeRequest(allocator,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":""}
    );
    defer defaults.deinit();
    try testing.expectEqual(default_walk_depth, defaults.value.max_depth);
    try testing.expectEqual(default_walk_entries, defaults.value.max_entries);

    for ([_][]const u8{
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"../etc"}
        ,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"/etc"}
        ,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"","max_depth":0}
        ,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"","max_depth":9999}
        ,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"","max_entries":0}
        ,
        \\{"action":"fs_walk","id":3,"workspace_id":"ws_1","path":"","max_entries":1000000}
    }) |hostile| {
        try testing.expectError(Error.BadRequest, decodeRequest(allocator, hostile));
    }
}

test "fs_walk: a walk's entries and its truncation round-trip" {
    const allocator = testing.allocator;
    var entries = [_]WalkEntry{
        .{ .path = "src/main.zig", .kind = "file" },
        .{ .path = "src", .kind = "dir" },
    };
    const encoded = try encodeFsWalk(allocator, 4, .{
        .entries = entries[0..],
        .count = 2,
        .truncated = true,
    });
    defer allocator.free(encoded);

    var owned = try decodeResponse(allocator, encoded);
    defer owned.deinit();
    const walked = switch (owned.value) {
        .fs_walk => |w| w,
        else => return error.TestExpectedFsWalk,
    };
    try testing.expectEqual(@as(usize, 2), walked.count);
    try testing.expect(walked.truncated);
    try testing.expectEqual(@as(usize, 2), walked.entries.len);
    try testing.expectEqualStrings("src/main.zig", walked.entries[0].path);
    try testing.expectEqualStrings("dir", walked.entries[1].kind);
}

test "fs actions: a path that leaves the workspace never reaches the agent" {
    const allocator = testing.allocator;
    const refused = [_][]const u8{ "/etc/passwd", "../etc/passwd", "a/../../b", "src/", "a\\b" };
    for (refused) |path| {
        const encoded = try encodeRequest(allocator, .{
            .action = .fs_stat,
            .id = 1,
            .workspace_id = "ws_1",
            .path = path,
        });
        defer allocator.free(encoded);
        try testing.expectError(Error.BadRequest, decodeRequest(allocator, encoded));
    }
}

test "fs_read: the reply ceiling is the frame's, and a zero ask is refused" {
    const allocator = testing.allocator;
    const too_much = try encodeRequest(allocator, .{
        .action = .fs_read,
        .id = 1,
        .workspace_id = "ws_1",
        .path = "a.txt",
        .max_bytes = max_fs_read_bytes + 1,
    });
    defer allocator.free(too_much);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, too_much));

    const zero = try encodeRequest(allocator, .{
        .action = .fs_read,
        .id = 1,
        .workspace_id = "ws_1",
        .path = "a.txt",
        .max_bytes = 0,
    });
    defer allocator.free(zero);
    try testing.expectError(Error.BadRequest, decodeRequest(allocator, zero));

    // A frame that asks for no ceiling at all gets the file default — which is
    // not the log default, so the two actions cannot silently share one.
    var defaulted = try decodeRequest(allocator,
        \\{"action":"fs_read","id":1,"workspace_id":"ws_1","path":"a.txt"}
    );
    defer defaulted.deinit();
    try testing.expectEqual(default_fs_read_bytes, defaulted.value.max_bytes);
}

test "fs_stat and fs_read: missing is its own answer, not an empty one" {
    const allocator = testing.allocator;

    const stat_missing = try encodeFsStat(allocator, 3, .{ .kind = "", .size = 0, .missing = true });
    defer allocator.free(stat_missing);
    var stat = try decodeResponse(allocator, stat_missing);
    defer stat.deinit();
    try testing.expect(stat.value.fs_stat.missing);

    const chunk_missing = try encodeFsRead(allocator, 4, .{ .data = "", .size = 0, .eof = true, .missing = true });
    defer allocator.free(chunk_missing);
    var gone = try decodeResponse(allocator, chunk_missing);
    defer gone.deinit();
    try testing.expect(gone.value.fs_read.missing);

    const chunk = try encodeFsRead(allocator, 5, .{ .data = "hello", .size = 5, .eof = true, .missing = false });
    defer allocator.free(chunk);
    var read = try decodeResponse(allocator, chunk);
    defer read.deinit();
    try testing.expectEqualStrings("hello", read.value.fs_read.data);
    try testing.expect(read.value.fs_read.eof);
    try testing.expect(!read.value.fs_read.missing);
}
