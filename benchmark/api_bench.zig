const std = @import("std");
const linux = std.os.linux;

pub const expected_body = "{\"status\":\"ok\",\"timestamp\":<ts>}";
pub const messages_body = "{\"messages\":[],\"has_more\":false,\"next_cursor\":null,\"cwd\":null,\"git_worktree_cwd\":null,\"pr_url\":null,\"pr_provider\":null,\"selected_profile_model\":null,\"sub_agent_name\":null,\"parent_session_id\":null,\"max_total_tokens\":0,\"max_capacity_total_tokens\":200000,\"total\":0,\"skills\":[]}";
pub const max_response_bytes = 64 * 1024;
pub const phase_names = [2][]const u8{ "c1", "cN" };
const zero_digest: [32]u8 = [_]u8{0} ** 32;

pub const Method = enum {
    get,
    post,
    patch,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .patch => "PATCH",
        };
    }
};

pub const Scenario = struct {
    name: []const u8,
    method: Method = .get,
    route: []const u8,
    /// A documents reorder of this many seeded rows, reversed: `bench-doc-00NN` … `bench-doc-0001`.
    reorder_rows: u32 = 0,
    mask_timestamp: bool,
    expected: []const u8,
    min_scaling: f64 = 0,
    min_rps: f64 = 0,
    /// p99 ceiling at concurrency 1, in ms. 0 keeps the global one.
    max_p99_ms: f64 = 0,
    /// One request sent before the phases, so a list route has rows to read.
    seed_route: ?[]const u8 = null,
    seed_method: Method = .post,
    /// Adopt the first response as the contract instead of `expected`: a seeded
    /// list body is long and only its byte-stability is worth pinning.
    probe_contract: bool = false,
    /// A second route measured at concurrency 1 and divided into the first
    /// one's p50, so the machine's speed cancels out of the ratio.
    reference_route: ?[]const u8 = null,
    max_cost_ratio: f64 = 0,
    /// This scenario's performance checks block even without `--strict`.
    enforced_performance: bool = false,
};

pub const scenarios = [_]Scenario{
    .{
        .name = "health",
        .route = "/health",
        .mask_timestamp = true,
        .expected = expected_body,
    },
    .{
        .name = "messages",
        .route = "/api/session/bench/messages",
        .mask_timestamp = false,
        .expected = messages_body,
        .min_scaling = 1.0,
        .min_rps = 1000.0,
    },
    .{
        .name = "sessions",
        .route = "/api/llm/session?limit=50",
        .mask_timestamp = false,
        .expected = "",
        .seed_route = "/api/bench/seed/sessions?rows=50",
        .probe_contract = true,
        .reference_route = "/api/llm/session?limit=5",
        .max_cost_ratio = 3.0,
        .max_p99_ms = 20.0,
        .min_scaling = 1.0,
        .min_rps = 1000.0,
        .enforced_performance = true,
    },
    .{
        .name = "documents",
        .route = "/api/workspaces/bench-docs/documents",
        .mask_timestamp = false,
        .expected = "",
        .seed_route = "/api/bench/seed/documents?rows=50",
        .probe_contract = true,
        .max_p99_ms = 20.0,
        .min_scaling = 1.0,
        .min_rps = 1000.0,
    },
    .{
        .name = "documents-reorder",
        .method = .patch,
        .route = "/api/workspaces/bench-docs/documents/reorder",
        .reorder_rows = 50,
        .mask_timestamp = false,
        .expected = "",
        .seed_route = "/api/bench/seed/documents?rows=50",
        .probe_contract = true,
        .max_p99_ms = 25.0,
        .min_scaling = 1.0,
        .min_rps = 300.0,
    },
};

pub const scenario_pointers = [scenarios.len]*const Scenario{
    &scenarios[0],
    &scenarios[1],
    &scenarios[2],
    &scenarios[3],
    &scenarios[4],
};

pub fn findScenario(name: []const u8) ?*const Scenario {
    for (&scenarios) |*scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

pub const Config = struct {
    port: u16 = 18080,
    selected: []const *const Scenario = &scenario_pointers,
    requests: usize = 2000,
    concurrency: usize = 8,
    warmup: usize = 200,
    ready_timeout_ms: u64 = 120_000,
    recv_timeout_ms: u64 = 30_000,
    min_scaling: f64 = 2.0,
    max_p99_ms: f64 = 5.0,
    min_rps: f64 = 2000.0,
    strict: bool = false,
    profile: []const u8 = "",
    server_cpuset: []const u8 = "",
    client_cpuset: []const u8 = "",
    memory_mb: u32 = 0,
    server_binary_sha256: []const u8 = "",
    json_path: []const u8 = "",
    markdown_path: []const u8 = "",
};

pub const StatusCount = struct {
    code: u16,
    count: usize,
};

pub const Head = struct {
    status: u16,
    content_length: ?usize,
    chunked: bool,
    close: bool,
    content_type: []const u8,
};

pub const Taken = struct {
    consumed: usize,
    head: Head,
    body: []const u8,
};

pub const Latency = struct {
    samples: usize = 0,
    p50_ms: f64 = 0,
    p90_ms: f64 = 0,
    p99_ms: f64 = 0,
    max_ms: f64 = 0,
    mean_ms: f64 = 0,
    throughput_rps: f64 = 0,
};

pub const Phase = struct {
    requests: usize = 0,
    expected_requests: usize = 0,
    connections: usize = 0,
    distinct_bodies: usize = 0,
    bodies: std.ArrayList([]const u8) = .empty,
    statuses: std.ArrayList(StatusCount) = .empty,
    content_types: std.ArrayList([]const u8) = .empty,
    samples: std.ArrayList(u64) = .empty,
    elapsed_ns: u64 = 0,
    latency: Latency = .{},
    body_fp: [32]u8 = zero_digest,
    problems: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn ok(self: *const Phase) bool {
        return self.problems.items.len == 0;
    }

    pub fn fingerprintHex(self: *const Phase) [64]u8 {
        return std.fmt.bytesToHex(self.body_fp, .lower);
    }

    pub fn deinit(self: *Phase) void {
        for (self.bodies.items) |body| self.gpa.free(body);
        self.bodies.deinit(self.gpa);
        for (self.content_types.items) |value| self.gpa.free(value);
        self.content_types.deinit(self.gpa);
        self.statuses.deinit(self.gpa);
        self.samples.deinit(self.gpa);
        for (self.problems.items) |problem| self.gpa.free(problem);
        self.problems.deinit(self.gpa);
    }
};

pub const Check = struct {
    name: []const u8,
    kind: []const u8,
    ok: bool,
    value: f64 = 0,
    has_value: bool = true,
    limit: f64 = 0,
    has_limit: bool = true,
    detail: []const u8 = "",
};

pub const Gate = struct {
    checks: []Check = &.{},
    verdict_pass: bool = true,
    strict: bool = false,
    enforced: bool = false,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Gate) void {
        for (self.checks) |check| self.gpa.free(check.name);
        self.gpa.free(self.checks);
    }
};

pub fn isDigits(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn normalizeBody(out: []u8, body: []const u8) ![]const u8 {
    const marker = "\"timestamp\":";
    const start = std.mem.indexOf(u8, body, marker) orelse {
        if (body.len > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    };
    var cursor = start + marker.len;
    while (cursor < body.len and (body[cursor] == ' ' or body[cursor] == '\t')) cursor += 1;
    if (cursor < body.len and body[cursor] == '-') cursor += 1;
    const digits_start = cursor;
    while (cursor < body.len and isDigits(body[cursor])) cursor += 1;
    const replacement = "\"timestamp\":<ts>";
    var written: usize = 0;
    if (body.len - (cursor - digits_start) + replacement.len > out.len) return error.NoSpaceLeft;
    if (cursor == digits_start) {
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }
    const prefix = body[0..start];
    @memcpy(out[written .. written + prefix.len], prefix);
    written += prefix.len;
    @memcpy(out[written .. written + replacement.len], replacement);
    written += replacement.len;
    const suffix = body[cursor..];
    @memcpy(out[written .. written + suffix.len], suffix);
    written += suffix.len;
    return out[0..written];
}

pub fn percentile(ordered: []const u64, q: f64) ?u64 {
    if (ordered.len == 0) return null;
    if (q <= 0.0) return ordered[0];
    if (q >= 1.0) return ordered[ordered.len - 1];
    const position = @as(f64, @floatFromInt(ordered.len - 1)) * q;
    const lower: usize = @intFromFloat(position);
    const upper = lower + 1;
    if (upper >= ordered.len) return ordered[lower];
    const fraction = position - @as(f64, @floatFromInt(lower));
    const lo: f64 = @floatFromInt(ordered[lower]);
    const hi: f64 = @floatFromInt(ordered[upper]);
    const value = lo + (hi - lo) * fraction;
    if (value <= 0.0) return 0;
    return @intFromFloat(value + 0.5);
}

pub fn planCounts(gpa: std.mem.Allocator, total: usize, workers: usize) ![]usize {
    if (workers == 0) return error.ZeroWorkers;
    const counts = try gpa.alloc(usize, workers);
    errdefer gpa.free(counts);
    const base = total / workers;
    const remainder = total % workers;
    for (counts, 0..) |*count, index| {
        count.* = base + @as(usize, if (index < remainder) 1 else 0);
    }
    return counts;
}

pub fn parseHead(head: []const u8) !Head {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadStatusLine;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") or status_line.len < 12) {
        return error.BadStatusLine;
    }
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadStatusLine;
    var parsed: Head = .{
        .status = status,
        .content_length = null,
        .chunked = false,
        .close = false,
        .content_type = "",
    };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            parsed.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadHead;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) parsed.chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) parsed.close = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            parsed.content_type = value;
        }
    }
    return parsed;
}

pub const Chunked = struct {
    body: []const u8,
    consumed: usize,
};

pub fn takeChunked(scratch: []u8, buf: []const u8) !?Chunked {
    var offset: usize = 0;
    var written: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfScalarPos(u8, buf, offset, '\n') orelse return null;
        var size_text = std.mem.trim(u8, buf[offset..line_end], " \t\r");
        if (std.mem.indexOfScalar(u8, size_text, ';')) |semi| size_text = size_text[0..semi];
        const size = std.fmt.parseInt(usize, size_text, 16) catch return error.BadChunk;
        offset = line_end + 1;
        if (size == 0) {
            if (buf.len < offset + 2) return null;
            return .{ .body = scratch[0..written], .consumed = offset + 2 };
        }
        if (buf.len < offset + size + 2) return null;
        if (written + size > scratch.len) return error.NoSpaceLeft;
        @memcpy(scratch[written .. written + size], buf[offset .. offset + size]);
        written += size;
        offset += size + 2;
    }
}

pub fn takeResponse(scratch: []u8, buf: []const u8) !?Taken {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        if (buf.len > max_response_bytes) return error.ResponseTooLarge;
        return null;
    };
    const head = try parseHead(buf[0..head_end]);
    const body_start = head_end + 4;
    var body: []const u8 = "";
    var consumed: usize = 0;
    if (head.content_length) |length| {
        if (buf.len < body_start + length) return null;
        body = buf[body_start .. body_start + length];
        consumed = body_start + length;
    } else if (head.chunked) {
        const chunked = (try takeChunked(scratch, buf[body_start..])) orelse return null;
        body = chunked.body;
        consumed = body_start + chunked.consumed;
    } else if (head.status == 204 or head.status == 304) {
        consumed = body_start;
    } else {
        return error.NoBodyFraming;
    }
    return .{ .consumed = consumed, .head = head, .body = body };
}

fn lessThanBody(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

pub fn fingerprint(gpa: std.mem.Allocator, bodies: []const []const u8) ![32]u8 {
    if (bodies.len == 0) return zero_digest;
    const ordered = try gpa.dupe([]const u8, bodies);
    defer gpa.free(ordered);
    std.mem.sort([]const u8, ordered, {}, lessThanBody);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var length_buffer: [8]u8 = undefined;
    for (ordered, 0..) |body, index| {
        if (index > 0 and std.mem.eql(u8, ordered[index - 1], body)) continue;
        std.mem.writeInt(u64, &length_buffer, body.len, .big);
        hasher.update(&length_buffer);
        hasher.update(body);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn rate(samples: usize, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    return @as(f64, @floatFromInt(samples)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);
}

pub fn round1(value: f64) f64 {
    return @round(value * 10.0) / 10.0;
}

pub fn round3(value: f64) f64 {
    return @round(value * 1000.0) / 1000.0;
}

fn nsToMs(value: u64) f64 {
    return round3(@as(f64, @floatFromInt(value)) / 1e6);
}

pub fn computeLatency(gpa: std.mem.Allocator, samples: []const u64, elapsed_ns: u64) !Latency {
    if (samples.len == 0) return .{};
    const ordered = try gpa.dupe(u64, samples);
    defer gpa.free(ordered);
    std.mem.sort(u64, ordered, {}, lessThanU64);
    var total: u64 = 0;
    for (ordered) |value| total += value;
    return .{
        .samples = ordered.len,
        .p50_ms = nsToMs(percentile(ordered, 0.50).?),
        .p90_ms = nsToMs(percentile(ordered, 0.90).?),
        .p99_ms = nsToMs(percentile(ordered, 0.99).?),
        .max_ms = nsToMs(ordered[ordered.len - 1]),
        .mean_ms = round3((@as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ordered.len))) / 1e6),
        .throughput_rps = round1(rate(ordered.len, elapsed_ns)),
    };
}

pub fn phaseProblems(phase: *Phase, expected: []const u8) !void {
    if (phase.requests != phase.expected_requests) {
        try phase.problems.append(phase.gpa, try std.fmt.allocPrint(phase.gpa, "completed {d} of {d} requests", .{ phase.requests, phase.expected_requests }));
    }
    if (phase.requests == 0) {
        try phase.problems.append(phase.gpa, try phase.gpa.dupe(u8, "no responses were measured"));
        return;
    }
    for (phase.statuses.items) |entry| {
        if (entry.code == 200) continue;
        try phase.problems.append(phase.gpa, try std.fmt.allocPrint(phase.gpa, "status {d} seen {d} times", .{ entry.code, entry.count }));
    }
    if (phase.distinct_bodies != 1) {
        try phase.problems.append(phase.gpa, try std.fmt.allocPrint(phase.gpa, "{d} distinct response bodies", .{phase.distinct_bodies}));
    } else if (!std.mem.eql(u8, phase.bodies.items[0], expected)) {
        try phase.problems.append(phase.gpa, try std.fmt.allocPrint(phase.gpa, "body does not match the contract: {s}", .{phase.bodies.items[0]}));
    }
    if (phase.content_types.items.len == 0) {
        try phase.problems.append(phase.gpa, try phase.gpa.dupe(u8, "no content-type was sent"));
    }
    for (phase.content_types.items) |value| {
        if (!std.mem.startsWith(u8, value, "application/json")) {
            try phase.problems.append(phase.gpa, try std.fmt.allocPrint(phase.gpa, "content-type {s} is not application/json", .{value}));
        }
    }
}

pub fn settlePhase(phase: *Phase, expected: []const u8) !void {
    phase.requests = phase.samples.items.len;
    phase.distinct_bodies = phase.bodies.items.len;
    phase.body_fp = try fingerprint(phase.gpa, phase.bodies.items);
    phase.latency = try computeLatency(phase.gpa, phase.samples.items, phase.elapsed_ns);
    phase.latency.samples = phase.samples.items.len;
    try phaseProblems(phase, expected);
}

pub fn evaluateGate(
    gpa: std.mem.Allocator,
    phases: *const [2]Phase,
    cfg: *const Config,
    scenario: *const Scenario,
    cost_ratio: f64,
) !Gate {
    var checks = std.ArrayList(Check).empty;
    errdefer checks.deinit(gpa);

    for (0..2) |index| {
        try checks.append(gpa, .{
            .name = try std.fmt.allocPrint(gpa, "functional.{s}", .{phase_names[index]}),
            .kind = "functional",
            .ok = phases[index].ok(),
            .has_value = false,
            .has_limit = false,
            .detail = if (phases[index].ok()) "every response matches the contract" else "see the phase problems",
        });
    }

    const min_scaling = if (scenario.min_scaling > 0) scenario.min_scaling else cfg.min_scaling;
    const min_rps = if (scenario.min_rps > 0) scenario.min_rps else cfg.min_rps;
    const max_p99 = if (scenario.max_p99_ms > 0) scenario.max_p99_ms else cfg.max_p99_ms;
    const floor = phases[0].latency.throughput_rps;
    const ceiling = phases[1].latency.throughput_rps;
    const scaling = if (floor > 0) round3(ceiling / floor) else 0;
    try checks.append(gpa, .{
        .name = try gpa.dupe(u8, "scaling.throughput"),
        .kind = "performance",
        .ok = scaling >= min_scaling,
        .value = scaling,
        .limit = min_scaling,
        .detail = "throughput at the high-concurrency phase over concurrency 1",
    });
    try checks.append(gpa, .{
        .name = try gpa.dupe(u8, "latency.p99_c1"),
        .kind = "performance",
        .ok = phases[0].latency.samples > 0 and phases[0].latency.p99_ms <= max_p99,
        .value = phases[0].latency.p99_ms,
        .limit = max_p99,
        .detail = "percentile-99 round trip at concurrency 1, in milliseconds",
    });
    try checks.append(gpa, .{
        .name = try gpa.dupe(u8, "throughput.cN"),
        .kind = "performance",
        .ok = ceiling >= min_rps,
        .value = ceiling,
        .limit = min_rps,
        .detail = "requests per second at the high-concurrency phase",
    });

    if (scenario.max_cost_ratio > 0) {
        try checks.append(gpa, .{
            .name = try gpa.dupe(u8, "cost.rows"),
            .kind = "performance",
            .ok = cost_ratio > 0 and cost_ratio <= scenario.max_cost_ratio,
            .value = cost_ratio,
            .limit = scenario.max_cost_ratio,
            .detail = "p50 of the measured route over p50 of its short-page reference, so a slow machine divides out",
        });
    }

    var verdict_pass = true;
    var enforced = false;
    for (checks.items) |check| {
        if (check.ok) continue;
        verdict_pass = false;
        if (std.mem.eql(u8, check.kind, "functional") or cfg.strict or scenario.enforced_performance) enforced = true;
    }
    return .{
        .checks = try checks.toOwnedSlice(gpa),
        .verdict_pass = verdict_pass,
        .strict = cfg.strict,
        .enforced = enforced,
        .gpa = gpa,
    };
}

fn appendPrint(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(gpa, format, args);
    defer gpa.free(rendered);
    try list.appendSlice(gpa, rendered);
}

pub fn canonicalDigest(gpa: std.mem.Allocator, cfg: *const Config, results: []const ScenarioResult) ![32]u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(gpa);

    try appendPrint(&text, gpa, "requests={d}\nconcurrency={d}\nwarmup={d}\n", .{ cfg.requests, cfg.concurrency, cfg.warmup });
    try appendPrint(&text, gpa, "profile={s}\n", .{cfg.profile});

    for (results) |result| {
        const scenario = result.scenario;
        try appendPrint(&text, gpa, "scenario={s} route={s}\n", .{ scenario.name, scenario.route });
        for (0..2) |index| {
            const phase = &result.phases[index];
            try appendPrint(&text, gpa, " phase={s} requests={d} expected={d} distinct={d} fp={s}\n", .{
                phase_names[index],
                phase.requests,
                phase.expected_requests,
                phase.distinct_bodies,
                &phase.fingerprintHex(),
            });
            for (phase.statuses.items) |entry| try appendPrint(&text, gpa, "  status={d}:{d}\n", .{ entry.code, entry.count });
            for (phase.content_types.items) |value| try appendPrint(&text, gpa, "  content_type={s}\n", .{value});
            for (phase.problems.items) |problem| try appendPrint(&text, gpa, "  problem={s}\n", .{problem});
            try appendPrint(&text, gpa, "  ok={d}\n", .{@intFromBool(phase.ok())});
        }
        for (result.gate.checks) |check| {
            if (!std.mem.eql(u8, check.kind, "functional")) continue;
            try appendPrint(&text, gpa, " check={s} ok={d}\n", .{ check.name, @intFromBool(check.ok) });
        }
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text.items, &digest, .{});
    return digest;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepMs(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}

const Connection = struct {
    fd: i32 = -1,
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    port: u16,
    timeout_ms: u64,
    opened: usize = 0,

    fn open(self: *Connection) !void {
        self.close();
        const raw_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        switch (linux.errno(raw_result)) {
            .SUCCESS => {},
            else => return error.SocketFailed,
        }
        const raw: i32 = @intCast(raw_result);
        errdefer _ = linux.close(raw);

        const timeout = linux.timeval{
            .sec = @intCast(self.timeout_ms / 1000),
            .usec = @intCast((self.timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(raw, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch return error.SocketFailed;
        std.posix.setsockopt(raw, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch return error.SocketFailed;
        const one: i32 = 1;
        std.posix.setsockopt(raw, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one)) catch {};

        const address = linux.sockaddr.in{
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        switch (linux.errno(linux.connect(raw, @ptrCast(&address), @sizeOf(linux.sockaddr.in)))) {
            .SUCCESS => {},
            .CONNREFUSED => return error.ConnectionRefused,
            else => return error.ConnectFailed,
        }
        self.fd = raw;
        self.opened += 1;
        self.buf.clearRetainingCapacity();
    }

    fn close(self: *Connection) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        self.buf.clearRetainingCapacity();
    }

    fn sendAll(self: *Connection, payload: []const u8) !void {
        var written: usize = 0;
        while (written < payload.len) {
            const result = linux.sendto(self.fd, payload.ptr + written, payload.len - written, 0, null, 0);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return error.SendTimeout,
                else => return error.SendFailed,
            }
            if (result == 0) return error.SendFailed;
            written += result;
        }
    }

    fn receive(self: *Connection) !void {
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const result = linux.recvfrom(self.fd, &chunk, chunk.len, 0, null, null);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return error.ReceiveTimeout,
                else => return error.ReceiveFailed,
            }
            if (result == 0) return error.PeerClosed;
            try self.buf.appendSlice(self.gpa, chunk[0..result]);
            if (self.buf.items.len > max_response_bytes * 4) return error.ResponseTooLarge;
            return;
        }
    }

    fn attempt(self: *Connection, payload: []const u8, scratch: []u8) !Taken {
        try self.sendAll(payload);
        while (true) {
            if (try takeResponse(scratch, self.buf.items)) |taken| {
                const remaining = self.buf.items.len - taken.consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[taken.consumed..]);
                }
                self.buf.shrinkRetainingCapacity(remaining);
                return taken;
            }
            try self.receive();
        }
    }

    fn roundTrip(self: *Connection, payload: []const u8, scratch: []u8) !struct { taken: Taken, elapsed_ns: u64 } {
        if (self.fd < 0) try self.open();
        var retried = false;
        while (true) {
            const started = nowNs();
            if (self.attempt(payload, scratch)) |taken| {
                const elapsed = nowNs() - started;
                if (taken.head.close) self.close();
                return .{ .taken = taken, .elapsed_ns = elapsed };
            } else |err| {
                switch (err) {
                    error.PeerClosed, error.SendFailed, error.ReceiveFailed => {
                        self.close();
                        if (retried) return err;
                        retried = true;
                        try self.open();
                        continue;
                    },
                    else => return err,
                }
            }
        }
    }
};

const WorkerResult = struct {
    samples: std.ArrayList(u64) = .empty,
    statuses: std.ArrayList(StatusCount) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,
    content_types: std.ArrayList([]const u8) = .empty,
    failures: std.ArrayList([]const u8) = .empty,
    connections: usize = 0,
    started_ns: u64 = 0,
    finished_ns: u64 = 0,

    fn deinit(self: *WorkerResult, gpa: std.mem.Allocator) void {
        for (self.bodies.items) |body| gpa.free(body);
        self.bodies.deinit(gpa);
        for (self.content_types.items) |value| gpa.free(value);
        self.content_types.deinit(gpa);
        for (self.failures.items) |failure| gpa.free(failure);
        self.failures.deinit(gpa);
        self.samples.deinit(gpa);
        self.statuses.deinit(gpa);
    }
};

const Shared = struct {
    gpa: std.mem.Allocator,
    cfg: *const Config,
    payload: []const u8,
    counts: []const usize,
    results: []WorkerResult,
    mask_timestamp: bool = true,
    started: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deadline_ns: u64 = 0,
};

fn recordStatus(list: *std.ArrayList(StatusCount), gpa: std.mem.Allocator, code: u16) !void {
    for (list.items) |*entry| {
        if (entry.code == code) {
            entry.count += 1;
            return;
        }
    }
    try list.append(gpa, .{ .code = code, .count = 1 });
}

fn recordUnique(list: *std.ArrayList([]const u8), gpa: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(gpa, try gpa.dupe(u8, value));
}

fn noteFailure(result: *WorkerResult, gpa: std.mem.Allocator, comptime format: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(gpa, format, args) catch return;
    result.failures.append(gpa, text) catch gpa.free(text);
}

fn workerMain(shared: *Shared, index: usize) void {
    const gpa = shared.gpa;
    const result = &shared.results[index];

    const scratch = gpa.alloc(u8, max_response_bytes) catch {
        shared.abort.store(true, .release);
        return;
    };
    defer gpa.free(scratch);
    const normalized = gpa.alloc(u8, max_response_bytes) catch {
        shared.abort.store(true, .release);
        return;
    };
    defer gpa.free(normalized);

    var connection: Connection = .{ .gpa = gpa, .port = shared.cfg.port, .timeout_ms = shared.cfg.recv_timeout_ms };
    defer connection.close();

    connection.open() catch |err| {
        noteFailure(result, gpa, "worker {d} connect: {s}", .{ index, @errorName(err) });
        shared.abort.store(true, .release);
        return;
    };
    _ = shared.started.fetchAdd(1, .acq_rel);
    while (shared.started.load(.acquire) < shared.counts.len) {
        if (shared.abort.load(.acquire)) return;
        if (nowNs() > shared.deadline_ns) {
            noteFailure(result, gpa, "worker {d} barrier timeout", .{index});
            shared.abort.store(true, .release);
            return;
        }
        std.atomic.spinLoopHint();
    }

    result.started_ns = nowNs();
    const count = shared.counts[index];
    var completed: usize = 0;
    while (completed < count) : (completed += 1) {
        const outcome = connection.roundTrip(shared.payload, scratch) catch |err| {
            noteFailure(result, gpa, "worker {d} request {d}: {s}", .{ index, completed, @errorName(err) });
            break;
        };
        result.samples.append(gpa, outcome.elapsed_ns) catch break;
        recordStatus(&result.statuses, gpa, outcome.taken.head.status) catch break;
        const body = if (shared.mask_timestamp)
            (normalizeBody(normalized, outcome.taken.body) catch outcome.taken.body)
        else
            outcome.taken.body;
        recordUnique(&result.bodies, gpa, body) catch break;
        recordUnique(&result.content_types, gpa, outcome.taken.head.content_type) catch break;
    }
    result.finished_ns = nowNs();
    result.connections = connection.opened;
}

fn mergePhase(gpa: std.mem.Allocator, phase: *Phase, results: []const WorkerResult, expected: usize, contract: []const u8) !void {
    phase.expected_requests = expected;
    var started: u64 = std.math.maxInt(u64);
    var finished: u64 = 0;
    for (results) |result| {
        try phase.samples.appendSlice(gpa, result.samples.items);
        for (result.statuses.items) |entry| {
            var merged = false;
            for (phase.statuses.items) |*existing| {
                if (existing.code == entry.code) {
                    existing.count += entry.count;
                    merged = true;
                    break;
                }
            }
            if (!merged) try phase.statuses.append(gpa, entry);
        }
        for (result.bodies.items) |body| try recordUnique(&phase.bodies, gpa, body);
        for (result.content_types.items) |value| try recordUnique(&phase.content_types, gpa, value);
        for (result.failures.items) |failure| try phase.problems.append(gpa, try gpa.dupe(u8, failure));
        phase.connections += result.connections;
        if (result.samples.items.len > 0) {
            started = @min(started, result.started_ns);
            finished = @max(finished, result.finished_ns);
        }
    }
    if (finished > started and started != std.math.maxInt(u64)) phase.elapsed_ns = finished - started;
    try settlePhase(phase, contract);
}

fn runPhase(gpa: std.mem.Allocator, cfg: *const Config, scenario: *const Scenario, payload: []const u8, requests: usize, concurrency: usize, contract: []const u8) !Phase {
    const counts = try planCounts(gpa, requests, concurrency);
    defer gpa.free(counts);
    const results = try gpa.alloc(WorkerResult, concurrency);
    defer {
        for (results) |*result| result.deinit(gpa);
        gpa.free(results);
    }
    for (results) |*result| result.* = .{};

    var shared: Shared = .{
        .gpa = gpa,
        .cfg = cfg,
        .payload = payload,
        .counts = counts,
        .results = results,
        .mask_timestamp = scenario.mask_timestamp,
        .deadline_ns = nowNs() + std.time.ns_per_s * 120,
    };

    const threads = try gpa.alloc(std.Thread, concurrency);
    defer gpa.free(threads);
    var spawned: usize = 0;
    errdefer {
        shared.abort.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    while (spawned < concurrency) {
        threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{ &shared, spawned });
        spawned += 1;
    }
    for (threads) |thread| thread.join();

    var phase: Phase = .{ .gpa = gpa };
    errdefer phase.deinit();
    try mergePhase(gpa, &phase, results, requests, contract);
    return phase;
}

fn waitReady(gpa: std.mem.Allocator, cfg: *const Config, payload: []const u8) !void {
    const deadline = nowNs() + cfg.ready_timeout_ms * std.time.ns_per_ms;
    const scratch = try gpa.alloc(u8, max_response_bytes);
    defer gpa.free(scratch);
    var last: []const u8 = "no attempt was made";
    while (nowNs() < deadline) {
        var connection: Connection = .{ .gpa = gpa, .port = cfg.port, .timeout_ms = 2000 };
        defer connection.close();
        if (connection.open()) {
            if (connection.roundTrip(payload, scratch)) |outcome| {
                if (outcome.taken.head.status == 200) return;
                last = "the server answered with a non-200 status";
            } else |err| {
                last = @errorName(err);
            }
        } else |err| {
            last = @errorName(err);
        }
        sleepMs(100);
    }
    std.log.err("the server never answered on 127.0.0.1:{d}: {s}", .{ cfg.port, last });
    return error.NotReady;
}

fn calibrate() f64 {
    var payload: [1 << 20]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 256);
    const started = nowNs();
    var digest: [32]u8 = undefined;
    var round: usize = 0;
    while (round < 32) : (round += 1) {
        std.crypto.hash.sha2.Sha256.hash(&payload, &digest, .{});
    }
    std.mem.doNotOptimizeAway(&digest);
    const elapsed = nowNs() - started;
    if (elapsed == 0) return 0;
    return round1(@as(f64, @floatFromInt(32)) * 1e9 / @as(f64, @floatFromInt(elapsed)));
}

fn buildRequest(gpa: std.mem.Allocator, cfg: *const Config, method: Method, route: []const u8, body: ?[]const u8) ![]u8 {
    const payload = body orelse "";
    if (method == .get) {
        return std.fmt.allocPrint(gpa, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUser-Agent: pabrik-api-bench/1\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n", .{ route, cfg.port });
    }
    if (payload.len == 0) {
        return std.fmt.allocPrint(gpa, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUser-Agent: pabrik-api-bench/1\r\nAccept: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n", .{ method.name(), route, cfg.port });
    }
    return std.fmt.allocPrint(gpa, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUser-Agent: pabrik-api-bench/1\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}", .{ method.name(), route, cfg.port, payload.len, payload });
}

/// The ordered_ids body a reorder scenario sends: every seeded row, reversed.
pub fn reorderBody(gpa: std.mem.Allocator, rows: u32) ![]u8 {
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"ordered_ids\":[");
    var row = rows;
    while (row > 0) : (row -= 1) {
        if (row != rows) try body.append(gpa, ',');
        var quoted: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&quoted, "\"bench-doc-{d:0>4}\"", .{row});
        try body.appendSlice(gpa, id);
    }
    try body.appendSlice(gpa, "]}");
    return body.toOwnedSlice(gpa);
}

fn buildPayload(gpa: std.mem.Allocator, cfg: *const Config, scenario: *const Scenario) ![]u8 {
    if (scenario.reorder_rows == 0) {
        return buildRequest(gpa, cfg, scenario.method, scenario.route, null);
    }
    const body = try reorderBody(gpa, scenario.reorder_rows);
    defer gpa.free(body);
    return buildRequest(gpa, cfg, scenario.method, scenario.route, body);
}

const OneShot = struct {
    status: u16,
    body: []u8,
};

/// One request on its own connection: the seed a list scenario needs, and the
/// probe whose body becomes the contract.
fn requestOnce(gpa: std.mem.Allocator, cfg: *const Config, payload: []const u8) !OneShot {
    const scratch = try gpa.alloc(u8, max_response_bytes);
    defer gpa.free(scratch);

    var connection: Connection = .{ .gpa = gpa, .port = cfg.port, .timeout_ms = cfg.recv_timeout_ms };
    defer connection.close();
    try connection.open();
    const outcome = try connection.roundTrip(payload, scratch);
    return .{ .status = outcome.taken.head.status, .body = try gpa.dupe(u8, outcome.taken.body) };
}

pub const ScenarioResult = struct {
    scenario: *const Scenario,
    phases: [2]Phase,
    gate: Gate,
    cost_ratio: f64 = 0,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *ScenarioResult) void {
        for (&self.phases) |*phase| phase.deinit();
        self.gate.deinit();
    }
};

fn runScenario(gpa: std.mem.Allocator, cfg: *const Config, scenario: *const Scenario, cpu_mibs: *f64) !ScenarioResult {
    const payload = try buildPayload(gpa, cfg, scenario);
    defer gpa.free(payload);

    waitReady(gpa, cfg, payload) catch return error.NotReady;

    if (scenario.seed_route) |seed_route| {
        const seed_payload = try buildRequest(gpa, cfg, scenario.seed_method, seed_route, null);
        defer gpa.free(seed_payload);
        const seeded = try requestOnce(gpa, cfg, seed_payload);
        defer gpa.free(seeded.body);
        if (seeded.status != 200) {
            std.log.err("{s}: seed {s} answered {d}: {s}", .{ scenario.name, seed_route, seeded.status, seeded.body });
            return error.SeedFailed;
        }
        std.log.info("{s}: seeded through {s}: {s}", .{ scenario.name, seed_route, seeded.body });
    }

    var contract_owned: ?[]u8 = null;
    defer if (contract_owned) |body| gpa.free(body);
    if (scenario.probe_contract) {
        const probe = try requestOnce(gpa, cfg, payload);
        defer gpa.free(probe.body);
        if (probe.status != 200) {
            std.log.err("{s}: probe {s} answered {d}", .{ scenario.name, scenario.route, probe.status });
            return error.ProbeFailed;
        }
        contract_owned = try gpa.dupe(u8, probe.body);
    }
    const contract: []const u8 = contract_owned orelse scenario.expected;

    if (cfg.warmup > 0) {
        var warm = try runPhase(gpa, cfg, scenario, payload, cfg.warmup, @min(cfg.warmup, cfg.concurrency), contract);
        const measured = warm.requests;
        const problems = warm.problems.items.len;
        warm.deinit();
        std.log.info("{s}: warmup {d} requests, {d} measured, {d} problems", .{ scenario.name, cfg.warmup, measured, problems });
        if (measured == 0) return error.NotReady;
    }

    cpu_mibs.* = calibrate();

    var result: ScenarioResult = .{
        .scenario = scenario,
        .phases = undefined,
        .gate = undefined,
        .gpa = gpa,
    };
    result.phases[0] = try runPhase(gpa, cfg, scenario, payload, cfg.requests, 1, contract);
    result.phases[1] = try runPhase(gpa, cfg, scenario, payload, cfg.requests, cfg.concurrency, contract);

    if (scenario.reference_route) |reference_route| {
        const reference_payload = try buildRequest(gpa, cfg, .get, reference_route, null);
        defer gpa.free(reference_payload);

        var reference = try runPhase(gpa, cfg, scenario, reference_payload, cfg.requests, 1, "");
        defer reference.deinit();

        const head = result.phases[0].latency.p50_ms;
        const tail = reference.latency.p50_ms;
        result.cost_ratio = if (tail > 0) round3(head / tail) else 0;
        std.log.info("{s}: p50 {d:.3} ms at {s} over {d:.3} ms at {s} = {d:.3}", .{
            scenario.name, head, scenario.route, tail, reference_route, result.cost_ratio,
        });
    }

    result.gate = try evaluateGate(gpa, &result.phases, cfg, scenario, result.cost_ratio);
    return result;
}

fn renderMarkdown(gpa: std.mem.Allocator, cfg: *const Config, results: []const ScenarioResult, digest: [32]u8) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(gpa);

    try text.appendSlice(gpa, "## api benchmark\n\n");
    for (results) |result| {
        try appendPrint(&text, gpa, "`{s} {s}` (`{s}`)\n", .{ result.scenario.method.name(), result.scenario.route, result.scenario.name });
    }
    try appendPrint(&text, gpa, "\nprofile `{s}` — {d} requests per phase, concurrency 1 and {d}, warmup {d}\n", .{
        cfg.profile, cfg.requests, cfg.concurrency, cfg.warmup,
    });

    for (results) |result| {
        try appendPrint(&text, gpa, "\n### `{s}`\n\n", .{result.scenario.name});
        try text.appendSlice(gpa, "| phase | requests | p50 ms | p90 ms | p99 ms | max ms | rps | bodies | connections | verdict |\n");
        try text.appendSlice(gpa, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");
        for (0..2) |index| {
            const phase = &result.phases[index];
            try appendPrint(&text, gpa, "| {s} | {d}/{d} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d:.1} | {d} | {d} | {s} |\n", .{
                phase_names[index],
                phase.requests,
                phase.expected_requests,
                phase.latency.p50_ms,
                phase.latency.p90_ms,
                phase.latency.p99_ms,
                phase.latency.max_ms,
                phase.latency.throughput_rps,
                phase.distinct_bodies,
                phase.connections,
                if (phase.ok()) "pass" else "fail",
            });
        }
        for (0..2) |index| {
            const phase = &result.phases[index];
            if (phase.ok()) continue;
            try appendPrint(&text, gpa, "\n- {s}: ", .{phase_names[index]});
            for (phase.problems.items, 0..) |problem, position| {
                if (position > 0) try text.appendSlice(gpa, "; ");
                try text.appendSlice(gpa, problem);
            }
            try text.appendSlice(gpa, "\n");
        }
        try text.appendSlice(gpa, "\n| gate | kind | value | limit | ok |\n| --- | --- | --- | --- | --- |\n");
        for (result.gate.checks) |check| {
            try appendPrint(&text, gpa, "| {s} | {s} | ", .{ check.name, check.kind });
            if (check.has_value) try appendPrint(&text, gpa, "{d:.3}", .{check.value}) else try text.appendSlice(gpa, "-");
            try text.appendSlice(gpa, " | ");
            if (check.has_limit) try appendPrint(&text, gpa, "{d:.3}", .{check.limit}) else try text.appendSlice(gpa, "-");
            try appendPrint(&text, gpa, " | {s} |\n", .{if (check.ok) "yes" else "no"});
        }
        try appendPrint(&text, gpa, "\nbody fingerprint `{s}` on {s}\n", .{
            &result.phases[1].fingerprintHex(),
            if (result.phases[1].distinct_bodies == 1) "one body" else "several bodies",
        });
    }

    try appendPrint(&text, gpa, "\ndeterministic result digest `{s}` — identical on every run of this profile, timing excluded\n", .{std.fmt.bytesToHex(digest, .lower)});
    try appendPrint(&text, gpa, "\ncontainer spec: `{s}`, server cpuset `{s}`, client cpuset `{s}`, memory `{d}` MB\n", .{
        cfg.profile, cfg.server_cpuset, cfg.client_cpuset, cfg.memory_mb,
    });
    return text.toOwnedSlice(gpa);
}

fn jsonString(text: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try text.append(gpa, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try text.appendSlice(gpa, "\\\""),
            '\\' => try text.appendSlice(gpa, "\\\\"),
            '\n' => try text.appendSlice(gpa, "\\n"),
            '\r' => try text.appendSlice(gpa, "\\r"),
            '\t' => try text.appendSlice(gpa, "\\t"),
            else => {
                if (byte < 0x20) {
                    try appendPrint(text, gpa, "\\u{x:0>4}", .{byte});
                } else {
                    try text.append(gpa, byte);
                }
            },
        }
    }
    try text.append(gpa, '"');
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn renderJson(gpa: std.mem.Allocator, cfg: *const Config, results: []const ScenarioResult, digest: [32]u8, cpu_mibs: f64) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, "{\n  \"schema\": 2,\n  \"spec\": {\n");

    try text.appendSlice(gpa, "    \"profile\": ");
    try jsonString(&text, gpa, cfg.profile);
    try text.appendSlice(gpa, ",\n    \"method\": \"GET\",\n");
    try appendPrint(&text, gpa, "    \"port\": {d},\n    \"requests\": {d},\n    \"concurrency\": {d},\n    \"warmup\": {d},\n", .{ cfg.port, cfg.requests, cfg.concurrency, cfg.warmup });
    try text.appendSlice(gpa, "    \"server_binary_sha256\": ");
    try jsonString(&text, gpa, cfg.server_binary_sha256);
    try text.appendSlice(gpa, ",\n    \"server_cpuset\": ");
    try jsonString(&text, gpa, cfg.server_cpuset);
    try text.appendSlice(gpa, ",\n    \"client_cpuset\": ");
    try jsonString(&text, gpa, cfg.client_cpuset);
    try appendPrint(&text, gpa, ",\n    \"memory_mb\": {d},\n", .{cfg.memory_mb});
    try appendPrint(&text, gpa, "    \"rules\": {{\"min_scaling\": {d:.3}, \"max_p99_ms\": {d:.3}, \"min_rps\": {d:.3}}},\n", .{ cfg.min_scaling, cfg.max_p99_ms, cfg.min_rps });
    try text.appendSlice(gpa, "    \"scenarios\": [");
    for (results, 0..) |result, index| {
        if (index > 0) try text.appendSlice(gpa, ", ");
        try jsonString(&text, gpa, result.scenario.name);
    }
    try text.appendSlice(gpa, "]\n  },\n  \"results\": {\n");

    for (results, 0..) |result, scenario_index| {
        try text.appendSlice(gpa, "    ");
        try jsonString(&text, gpa, result.scenario.name);
        try text.appendSlice(gpa, ": {\n      \"route\": ");
        try jsonString(&text, gpa, result.scenario.route);
        try text.appendSlice(gpa, ",\n      \"phases\": {\n");
        for (0..2) |index| {
            const phase = &result.phases[index];
            try text.appendSlice(gpa, "        ");
            try jsonString(&text, gpa, phase_names[index]);
            try text.appendSlice(gpa, ": {\n");
            try appendPrint(&text, gpa, "          \"requests\": {d},\n          \"expected_requests\": {d},\n          \"connections\": {d},\n          \"distinct_bodies\": {d},\n", .{
                phase.requests, phase.expected_requests, phase.connections, phase.distinct_bodies,
            });
            try appendPrint(&text, gpa, "          \"body_fingerprint\": \"{s}\",\n          \"statuses\": {{", .{&phase.fingerprintHex()});
            for (phase.statuses.items, 0..) |entry, position| {
                if (position > 0) try text.appendSlice(gpa, ", ");
                try appendPrint(&text, gpa, "\"{d}\": {d}", .{ entry.code, entry.count });
            }
            try text.appendSlice(gpa, "},\n          \"content_types\": [");
            for (phase.content_types.items, 0..) |value, position| {
                if (position > 0) try text.appendSlice(gpa, ", ");
                try jsonString(&text, gpa, value);
            }
            try text.appendSlice(gpa, "],\n          \"latency\": {\n");
            try appendPrint(&text, gpa, "            \"samples\": {d},\n            \"p50_ms\": {d:.3},\n            \"p90_ms\": {d:.3},\n            \"p99_ms\": {d:.3},\n            \"max_ms\": {d:.3},\n            \"mean_ms\": {d:.3},\n            \"throughput_rps\": {d:.1}\n          }},\n", .{
                phase.latency.samples, phase.latency.p50_ms, phase.latency.p90_ms, phase.latency.p99_ms,
                phase.latency.max_ms, phase.latency.mean_ms, phase.latency.throughput_rps,
            });
            try appendPrint(&text, gpa, "          \"ok\": {s},\n          \"problems\": [", .{jsonBool(phase.ok())});
            for (phase.problems.items, 0..) |problem, position| {
                if (position > 0) try text.appendSlice(gpa, ", ");
                try jsonString(&text, gpa, problem);
            }
            try text.appendSlice(gpa, "]\n        }");
            if (index == 0) try text.appendSlice(gpa, ",");
            try text.appendSlice(gpa, "\n");
        }
        try text.appendSlice(gpa, "      },\n      \"gate\": {\n        \"verdict\": ");
        try jsonString(&text, gpa, if (result.gate.verdict_pass) "pass" else "fail");
        try appendPrint(&text, gpa, ",\n        \"strict\": {s},\n        \"enforced\": {s},\n        \"enforced_by\": [", .{
            jsonBool(result.gate.strict), jsonBool(result.gate.enforced),
        });
        var first = true;
        for (result.gate.checks) |check| {
            if (check.ok) continue;
            if (!result.gate.strict and !std.mem.eql(u8, check.kind, "functional")) continue;
            if (!first) try text.appendSlice(gpa, ", ");
            first = false;
            try jsonString(&text, gpa, check.name);
        }
        try text.appendSlice(gpa, "],\n        \"checks\": [\n");
        for (result.gate.checks, 0..) |check, index| {
            try text.appendSlice(gpa, "          {\"name\": ");
            try jsonString(&text, gpa, check.name);
            try text.appendSlice(gpa, ", \"kind\": ");
            try jsonString(&text, gpa, check.kind);
            try appendPrint(&text, gpa, ", \"ok\": {s}, \"value\": ", .{jsonBool(check.ok)});
            if (check.has_value) try appendPrint(&text, gpa, "{d:.3}", .{check.value}) else try text.appendSlice(gpa, "null");
            try text.appendSlice(gpa, ", \"limit\": ");
            if (check.has_limit) try appendPrint(&text, gpa, "{d:.3}", .{check.limit}) else try text.appendSlice(gpa, "null");
            try text.appendSlice(gpa, ", \"detail\": ");
            try jsonString(&text, gpa, check.detail);
            try text.appendSlice(gpa, "}");
            if (index + 1 < result.gate.checks.len) try text.appendSlice(gpa, ",");
            try text.appendSlice(gpa, "\n");
        }
        try text.appendSlice(gpa, "        ]\n      }\n    }");
        if (scenario_index + 1 < results.len) try text.appendSlice(gpa, ",");
        try text.appendSlice(gpa, "\n");
    }

    try appendPrint(&text, gpa, "  }},\n  \"machine\": {{\n    \"cpu_hash_mib_per_s\": {d:.1},\n    \"result_sha256\": \"{s}\"\n  }}\n}}\n", .{
        cpu_mibs, std.fmt.bytesToHex(digest, .lower),
    });
    return text.toOwnedSlice(gpa);
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn usage(io: std.Io) !void {
    const text =
        \\usage: api-bench --port <n> [--scenario health,messages] [--requests 2000]
        \\                 [--concurrency 8] [--warmup 200] [--min-scaling 2] [--max-p99-ms 5]
        \\                 [--min-rps 2000] [--strict] [--profile name]
        \\                 [--server-cpuset 0,1] [--client-cpuset 2,3] [--memory-mb 2048]
        \\                 [--server-binary-sha256 hex] [--json path] [--markdown path]
        \\scenarios: health (/health), messages (/api/session/bench/messages),
        \\           sessions (/api/llm/session?limit=50, seeded)
        \\           documents (GET /api/workspaces/bench-docs/documents, seeded),
        \\           documents-reorder (PATCH .../documents/reorder, seeded)
        \\
    ;
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, text);
}

fn nextValue(args: []const [:0]const u8, index: usize) ![]const u8 {
    if (index + 1 >= args.len) return error.MissingValue;
    return std.mem.sliceTo(args[index + 1], 0);
}

fn selectScenarios(gpa: std.mem.Allocator, spec: []const u8) ![]const *const Scenario {
    var selected = std.ArrayList(*const Scenario).empty;
    errdefer selected.deinit(gpa);
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "all")) {
            for (&scenarios) |*scenario| {
                var present = false;
                for (selected.items) |existing| {
                    if (existing == scenario) present = true;
                }
                if (!present) try selected.append(gpa, scenario);
            }
            continue;
        }
        const scenario = findScenario(name) orelse return error.UnknownScenario;
        var present = false;
        for (selected.items) |existing| {
            if (existing == scenario) present = true;
        }
        if (!present) try selected.append(gpa, scenario);
    }
    if (selected.items.len == 0) return error.UnknownScenario;
    return selected.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cfg: Config = .{};
    var scenario_spec: []const u8 = "all";
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.sliceTo(args[index], 0);
        if (std.mem.eql(u8, arg, "--port")) {
            cfg.port = try std.fmt.parseInt(u16, try nextValue(args, index), 10);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--scenario") or std.mem.eql(u8, arg, "--route")) {
            scenario_spec = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--requests")) {
            cfg.requests = try std.fmt.parseInt(usize, try nextValue(args, index), 10);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            cfg.concurrency = try std.fmt.parseInt(usize, try nextValue(args, index), 10);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            cfg.warmup = try std.fmt.parseInt(usize, try nextValue(args, index), 10);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--min-scaling")) {
            cfg.min_scaling = try std.fmt.parseFloat(f64, try nextValue(args, index));
            index += 1;
        } else if (std.mem.eql(u8, arg, "--max-p99-ms")) {
            cfg.max_p99_ms = try std.fmt.parseFloat(f64, try nextValue(args, index));
            index += 1;
        } else if (std.mem.eql(u8, arg, "--min-rps")) {
            cfg.min_rps = try std.fmt.parseFloat(f64, try nextValue(args, index));
            index += 1;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            cfg.profile = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--server-cpuset")) {
            cfg.server_cpuset = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--client-cpuset")) {
            cfg.client_cpuset = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--memory-mb")) {
            cfg.memory_mb = try std.fmt.parseInt(u32, try nextValue(args, index), 10);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--server-binary-sha256")) {
            cfg.server_binary_sha256 = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            cfg.json_path = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            cfg.markdown_path = try nextValue(args, index);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            cfg.strict = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage(io);
            return 0;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return 2;
        }
    }

    cfg.selected = selectScenarios(gpa, scenario_spec) catch {
        std.log.err("unknown scenario in '{s}'; known: health, messages", .{scenario_spec});
        return 2;
    };
    defer gpa.free(cfg.selected);

    const cpu_holder: *f64 = try gpa.create(f64);
    defer gpa.destroy(cpu_holder);
    cpu_holder.* = 0;

    const results = try gpa.alloc(ScenarioResult, cfg.selected.len);
    var built: usize = 0;
    defer {
        for (results[0..built]) |*result| result.deinit();
        gpa.free(results);
    }
    while (built < cfg.selected.len) : (built += 1) {
        results[built] = runScenario(gpa, &cfg, cfg.selected[built], cpu_holder) catch return 2;
    }

    const digest = try canonicalDigest(gpa, &cfg, results);

    const markdown = try renderMarkdown(gpa, &cfg, results, digest);
    defer gpa.free(markdown);
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, markdown);

    if (cfg.json_path.len > 0) {
        const report = try renderJson(gpa, &cfg, results, digest, cpu_holder.*);
        defer gpa.free(report);
        try writeFile(io, cfg.json_path, report);
    }
    if (cfg.markdown_path.len > 0) {
        try writeFile(io, cfg.markdown_path, markdown);
    }

    var enforced = false;
    var verdict_pass = true;
    for (results) |result| {
        for (result.gate.checks) |check| {
            if (check.ok) continue;
            std.log.err("{s}: gate check {s} failed: value {d:.3}, limit {d:.3} ({s})", .{
                result.scenario.name, check.name, check.value, check.limit, check.detail,
            });
        }
        if (!result.gate.verdict_pass) {
            verdict_pass = false;
            std.log.info("{s}: verdict fail", .{result.scenario.name});
        } else {
            std.log.info("{s}: verdict pass", .{result.scenario.name});
        }
        if (result.gate.enforced) enforced = true;
    }
    std.log.info("run verdict {s} (enforced: {})", .{ if (verdict_pass) "pass" else "fail", enforced });

    return if (enforced) 1 else 0;
}

fn phaseFixture(gpa: std.mem.Allocator, bodies: []const []const u8, requests: usize, expected: usize, throughput: f64, p99: f64) !Phase {
    var phase: Phase = .{ .gpa = gpa };
    try phase.samples.appendNTimes(gpa, 1_000_000, requests);
    try phase.statuses.append(gpa, .{ .code = 200, .count = requests });
    try phase.content_types.append(gpa, try gpa.dupe(u8, "application/json"));
    for (bodies) |body| try recordUnique(&phase.bodies, gpa, body);
    phase.expected_requests = expected;
    phase.elapsed_ns = requests * 1_000_000;
    try settlePhase(&phase, if (bodies.len == 1) bodies[0] else "several bodies");
    phase.latency.throughput_rps = throughput;
    phase.latency.p99_ms = p99;
    return phase;
}

fn bodyList() [1][]const u8 {
    return .{expected_body};
}

fn healthyPhases(gpa: std.mem.Allocator) ![2]Phase {
    const bodies = bodyList();
    return .{
        try phaseFixture(gpa, &bodies, 10, 10, 3000.0, 0.5),
        try phaseFixture(gpa, &bodies, 10, 10, 12000.0, 2.0),
    };
}

fn healthyConfig(strict: bool) Config {
    return .{
        .concurrency = 8,
        .min_scaling = 2.0,
        .max_p99_ms = 5.0,
        .min_rps = 2000.0,
        .strict = strict,
        .selected = &scenario_pointers,
    };
}

fn resultFixture(gpa: std.mem.Allocator, scenario: *const Scenario, config: *const Config, bodies: []const []const u8, requests: usize, expected: usize, throughput: f64, p99: f64) !ScenarioResult {
    var result: ScenarioResult = .{ .scenario = scenario, .phases = undefined, .gate = undefined, .gpa = gpa };
    result.phases[0] = try phaseFixture(gpa, bodies, requests, expected, 100.0, p99);
    result.phases[1] = try phaseFixture(gpa, bodies, requests, expected, throughput, p99);
    result.gate = try evaluateGate(gpa, &result.phases, config, scenario, 0);
    return result;
}

test "timestamps normalize to one body" {
    var buffer: [128]u8 = undefined;
    const early = try normalizeBody(&buffer, "{\"status\":\"ok\",\"timestamp\":1700000000}");
    try std.testing.expectEqualStrings(expected_body, early);
    const late = try normalizeBody(&buffer, "{\"status\":\"ok\",\"timestamp\":1700000123}");
    try std.testing.expectEqualStrings(expected_body, late);
}

test "a body without a timestamp is left alone" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", try normalizeBody(&buffer, "{\"status\":\"ok\"}"));
}

test "a different status word survives normalization" {
    var buffer: [64]u8 = undefined;
    const body = try normalizeBody(&buffer, "{\"status\":\"down\",\"timestamp\":1}");
    try std.testing.expect(!std.mem.eql(u8, body, expected_body));
    try std.testing.expectEqualStrings("{\"status\":\"down\",\"timestamp\":<ts>}", body);
}

test "a negative timestamp is masked too" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected_body, try normalizeBody(&buffer, "{\"status\":\"ok\",\"timestamp\":-1}"));
}

test "a buffer too short for the body is refused" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, normalizeBody(&buffer, expected_body));
}

test "percentile of one sample is that sample" {
    try std.testing.expectEqual(@as(?u64, 7), percentile(&[_]u64{7}, 0.5));
    try std.testing.expectEqual(@as(?u64, 7), percentile(&[_]u64{7}, 0.99));
}

test "percentile interpolates between neighbours" {
    try std.testing.expectEqual(@as(?u64, 50), percentile(&[_]u64{ 0, 100 }, 0.5));
    try std.testing.expectEqual(@as(?u64, 10), percentile(&[_]u64{ 0, 10, 20, 30, 40 }, 0.25));
}

test "percentile clamps at both ends" {
    try std.testing.expectEqual(@as(?u64, 1), percentile(&[_]u64{ 1, 2, 3 }, 0.0));
    try std.testing.expectEqual(@as(?u64, 3), percentile(&[_]u64{ 1, 2, 3 }, 1.0));
}

test "percentile of nothing is none" {
    try std.testing.expectEqual(@as(?u64, null), percentile(&[_]u64{}, 0.5));
}

test "percentiles never decrease with q" {
    var ordered: [1000]u64 = undefined;
    for (&ordered, 0..) |*value, index| value.* = index + 1;
    const p50 = percentile(&ordered, 0.50).?;
    const p90 = percentile(&ordered, 0.90).?;
    const p99 = percentile(&ordered, 0.99).?;
    const p100 = percentile(&ordered, 1.0).?;
    try std.testing.expect(p50 <= p90 and p90 <= p99 and p99 <= p100);
}

test "a plan splits exactly the requested total" {
    const cases = [_][2]usize{ .{ 2000, 8 }, .{ 7, 3 }, .{ 1, 8 }, .{ 0, 4 }, .{ 100, 1 } };
    for (cases) |case| {
        const counts = try planCounts(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(counts);
        var total: usize = 0;
        var smallest: usize = std.math.maxInt(usize);
        var largest: usize = 0;
        for (counts) |count| {
            total += count;
            smallest = @min(smallest, count);
            largest = @max(largest, count);
        }
        try std.testing.expectEqual(case[0], total);
        try std.testing.expectEqual(case[1], counts.len);
        try std.testing.expect(largest - smallest <= 1);
    }
}

test "a plan rejects zero workers" {
    try std.testing.expectError(error.ZeroWorkers, planCounts(std.testing.allocator, 10, 0));
}

test "throughput is requests over wall clock" {
    const samples = [_]u64{1_000_000} ** 100;
    const latency = try computeLatency(std.testing.allocator, &samples, 1_000_000_000);
    try std.testing.expectEqual(@as(usize, 100), latency.samples);
    try std.testing.expectEqual(@as(f64, 100.0), latency.throughput_rps);
    try std.testing.expectEqual(@as(f64, 0.0), rate(5, 0));
}

test "latency percentiles come out ordered" {
    var samples: [100]u64 = undefined;
    for (&samples, 0..) |*value, index| value.* = (index + 1) * 1000;
    const latency = try computeLatency(std.testing.allocator, &samples, 1_000_000);
    try std.testing.expect(latency.p50_ms <= latency.p90_ms);
    try std.testing.expect(latency.p90_ms <= latency.p99_ms);
    try std.testing.expect(latency.p99_ms <= latency.max_ms);
    try std.testing.expectEqual(@as(f64, 0.1), latency.max_ms);
}

test "a complete response is taken whole" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\nhi";
    const taken = (try takeResponse(&scratch, raw)).?;
    try std.testing.expectEqual(@as(u16, 200), taken.head.status);
    try std.testing.expectEqualStrings("hi", taken.body);
    try std.testing.expectEqual(@as(usize, raw.len), taken.consumed);
    try std.testing.expectEqualStrings("application/json", taken.head.content_type);
    try std.testing.expect(!taken.head.close);
}

test "an incomplete response asks for more" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort";
    try std.testing.expectEqual(@as(?Taken, null), try takeResponse(&scratch, raw));
}

test "a split head asks for more" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?Taken, null), try takeResponse(&scratch, "HTTP/1.1 200 OK\r\nContent-Le"));
}

test "pipelined responses leave the remainder" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\naHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb";
    const first = (try takeResponse(&scratch, raw)).?;
    const second = (try takeResponse(&scratch, raw[first.consumed..])).?;
    try std.testing.expectEqualStrings("a", first.body);
    try std.testing.expectEqualStrings("b", second.body);
    try std.testing.expectEqual(@as(usize, raw.len), first.consumed + second.consumed);
}

test "a chunked body is decoded" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n3\r\nefg\r\n0\r\n\r\n";
    const taken = (try takeResponse(&scratch, raw)).?;
    try std.testing.expectEqualStrings("abcdefg", taken.body);
    try std.testing.expectEqual(@as(usize, raw.len), taken.consumed);
}

test "a chunked body split across reads asks for more" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab";
    try std.testing.expectEqual(@as(?Taken, null), try takeResponse(&scratch, raw));
}

test "a bad status line is rejected" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.BadStatusLine, takeResponse(&scratch, "NOT-HTTP\r\n\r\n"));
}

test "a response without framing is rejected" {
    var scratch: [64]u8 = undefined;
    try std.testing.expectError(error.NoBodyFraming, takeResponse(&scratch, "HTTP/1.1 200 OK\r\nServer: x\r\n\r\n"));
}

test "a 204 response has no body" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
    const taken = (try takeResponse(&scratch, raw)).?;
    try std.testing.expectEqual(@as(u16, 204), taken.head.status);
    try std.testing.expectEqualStrings("", taken.body);
}

test "header names are case insensitive and close is noticed" {
    var scratch: [64]u8 = undefined;
    const raw = "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nConnection: close\r\n\r\n";
    const taken = (try takeResponse(&scratch, raw)).?;
    try std.testing.expectEqual(@as(usize, 0), taken.head.content_length.?);
    try std.testing.expect(taken.head.close);
}

test "the fingerprint ignores arrival order" {
    const first = try fingerprint(std.testing.allocator, &[_][]const u8{ "a", "b", "a" });
    const second = try fingerprint(std.testing.allocator, &[_][]const u8{ "b", "a" });
    try std.testing.expectEqualSlices(u8, &first, &second);
}

test "the fingerprint changes when a body changes" {
    const first = try fingerprint(std.testing.allocator, &[_][]const u8{"a"});
    const second = try fingerprint(std.testing.allocator, &[_][]const u8{"b"});
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "every scenario is reachable by name" {
    for (&scenarios) |*scenario| {
        const found = findScenario(scenario.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(scenario, found);
        try std.testing.expect(std.mem.startsWith(u8, found.route, "/"));
    }
    try std.testing.expectEqual(@as(?*const Scenario, null), findScenario("nope"));
}

test "the inbox contract is pinned and needs no masking" {
    const inbox = findScenario("messages").?;
    try std.testing.expect(!inbox.mask_timestamp);
    try std.testing.expectEqualStrings("/api/session/bench/messages", inbox.route);
    try std.testing.expect(std.mem.indexOf(u8, inbox.expected, "\"messages\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox.expected, "timestamp") == null);
}

test "the health contract needs masking and the inbox does not" {
    try std.testing.expect(findScenario("health").?.mask_timestamp);
    try std.testing.expect(std.mem.indexOf(u8, findScenario("health").?.expected, "<ts>") != null);
    try std.testing.expect(!findScenario("messages").?.mask_timestamp);
}

test "selecting all lists every scenario once" {
    const selected = try selectScenarios(std.testing.allocator, "all,health");
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(scenarios.len, selected.len);
    try std.testing.expectEqualStrings("health", selected[0].name);
    try std.testing.expectEqualStrings("messages", selected[1].name);
    try std.testing.expectEqualStrings("sessions", selected[2].name);
}

test "a named selection keeps the requested order" {
    const selected = try selectScenarios(std.testing.allocator, "messages, health");
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("messages", selected[0].name);
    try std.testing.expectEqualStrings("health", selected[1].name);
}

test "an unknown scenario is rejected" {
    try std.testing.expectError(error.UnknownScenario, selectScenarios(std.testing.allocator, "nope"));
    try std.testing.expectError(error.UnknownScenario, selectScenarios(std.testing.allocator, ""));
}

test "a clean phase reports no problems" {
    const bodies = bodyList();
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    try std.testing.expect(phase.ok());
    try std.testing.expectEqual(@as(usize, 1), phase.distinct_bodies);
    try std.testing.expectEqual(@as(usize, 10), phase.requests);
}

test "an inbox phase off its contract is a problem" {
    const bodies = bodyList();
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    phase.problems.clearRetainingCapacity();
    try phaseProblems(&phase, messages_body);
    try std.testing.expect(!phase.ok());
}

test "a wrong status code is a problem" {
    const bodies = bodyList();
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    phase.statuses.items[0].count = 9;
    try phase.statuses.append(phase.gpa, .{ .code = 503, .count = 1 });
    phase.problems.clearRetainingCapacity();
    try phaseProblems(&phase, expected_body);
    try std.testing.expect(!phase.ok());
    try std.testing.expect(std.mem.indexOf(u8, phase.problems.items[0], "503") != null);
}

test "two distinct bodies are a problem" {
    const bodies = [_][]const u8{ expected_body, "{\"status\":\"ok\",\"timestamp\":<ts>,\"extra\":1}" };
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    try std.testing.expectEqual(@as(usize, 2), phase.distinct_bodies);
    try std.testing.expect(!phase.ok());
    try std.testing.expect(std.mem.indexOf(u8, phase.problems.items[0], "distinct response bodies") != null);
}

test "a body off the contract is a problem" {
    const bodies = [_][]const u8{"{\"status\":\"down\",\"timestamp\":<ts>}"};
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    phase.problems.clearRetainingCapacity();
    try phaseProblems(&phase, expected_body);
    try std.testing.expect(!phase.ok());
    try std.testing.expect(std.mem.indexOf(u8, phase.problems.items[0], "contract") != null);
}

test "a missing response is a problem" {
    const bodies = bodyList();
    var phase = try phaseFixture(std.testing.allocator, &bodies, 9, 10, 3000.0, 0.5);
    defer phase.deinit();
    try std.testing.expect(!phase.ok());
    try std.testing.expect(std.mem.indexOf(u8, phase.problems.items[0], "completed 9 of 10") != null);
}

test "a non-json content type is a problem" {
    const bodies = bodyList();
    var phase = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    defer phase.deinit();
    phase.gpa.free(phase.content_types.items[0]);
    phase.content_types.items[0] = try phase.gpa.dupe(u8, "text/html");
    phase.problems.clearRetainingCapacity();
    try phaseProblems(&phase, expected_body);
    try std.testing.expect(!phase.ok());
}

test "an empty phase is a problem" {
    var phase: Phase = .{ .gpa = std.testing.allocator };
    defer phase.deinit();
    try settlePhase(&phase, expected_body);
    try std.testing.expect(!phase.ok());
    try std.testing.expectEqual(@as(usize, 1), phase.problems.items.len);
    try std.testing.expect(std.mem.indexOf(u8, phase.problems.items[0], "no responses") != null);
}

test "a healthy run passes the gate" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(true);
    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer gate.deinit();
    try std.testing.expect(gate.verdict_pass);
    try std.testing.expect(!gate.enforced);
    try std.testing.expectEqualStrings("scaling.throughput", gate.checks[2].name);
    try std.testing.expect(gate.checks[2].ok);
}

test "flat throughput fails scaling but stays advisory" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(false);
    phases[1].latency.throughput_rps = phases[0].latency.throughput_rps;
    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer gate.deinit();
    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(!gate.enforced);
}

test "a strict run enforces a performance failure" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(true);
    phases[1].latency.throughput_rps = 1.0;
    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer gate.deinit();
    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(gate.enforced);
}

test "a functional failure is enforced without strict" {
    const bodies = [_][]const u8{"{\"status\":\"down\",\"timestamp\":<ts>}"};
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    phases[0].deinit();
    phases[0] = try phaseFixture(std.testing.allocator, &bodies, 10, 10, 3000.0, 0.5);
    phases[0].problems.clearRetainingCapacity();
    try phaseProblems(&phases[0], expected_body);
    var config = healthyConfig(false);
    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer gate.deinit();
    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(gate.enforced);
}

test "a slow p99 fails the latency check" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(true);
    phases[0].latency.p99_ms = 9000.0;
    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer gate.deinit();
    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(gate.enforced);
}

test "the digest ignores timing" {
    var config = healthyConfig(false);
    const health = findScenario("health").?;
    const bodies = bodyList();
    var results: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 10, 10, 12000.0, 2.0),
    };
    defer for (&results) |*result| result.deinit();
    const slow = try canonicalDigest(std.testing.allocator, &config, &results);

    results[0].phases[0].latency.p99_ms = 1.0;
    results[0].phases[1].latency.throughput_rps = 999_999.0;
    const fast = try canonicalDigest(std.testing.allocator, &config, &results);
    try std.testing.expectEqualSlices(u8, &slow, &fast);
}

test "the digest changes when a body changes" {
    var config = healthyConfig(false);
    const health = findScenario("health").?;
    const other = [_][]const u8{"{\"status\":\"down\",\"timestamp\":<ts>}"};
    const bodies = bodyList();

    var first: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 10, 10, 12000.0, 2.0),
    };
    defer for (&first) |*result| result.deinit();
    var second: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &other, 10, 10, 500.0, 40.0),
    };
    defer for (&second) |*result| result.deinit();

    const first_digest = try canonicalDigest(std.testing.allocator, &config, &first);
    const second_digest = try canonicalDigest(std.testing.allocator, &config, &second);
    try std.testing.expect(!std.mem.eql(u8, &first_digest, &second_digest));
}

test "the digest notices a missing response" {
    var config = healthyConfig(false);
    const health = findScenario("health").?;
    const bodies = bodyList();

    var first: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 10, 10, 12000.0, 2.0),
    };
    defer for (&first) |*result| result.deinit();
    var second: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 9, 10, 12000.0, 2.0),
    };
    defer for (&second) |*result| result.deinit();

    const first_digest = try canonicalDigest(std.testing.allocator, &config, &first);
    const second_digest = try canonicalDigest(std.testing.allocator, &config, &second);
    try std.testing.expect(!std.mem.eql(u8, &first_digest, &second_digest));
}

test "the digest covers every scenario" {
    var config = healthyConfig(false);
    const health = findScenario("health").?;
    const inbox = findScenario("messages").?;
    const bodies = bodyList();

    var one: [1]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 10, 10, 12000.0, 2.0),
    };
    defer for (&one) |*result| result.deinit();
    var two: [2]ScenarioResult = .{
        try resultFixture(std.testing.allocator, health, &config, &bodies, 10, 10, 12000.0, 2.0),
        try resultFixture(std.testing.allocator, inbox, &config, &bodyList(), 10, 10, 12000.0, 2.0),
    };
    defer for (&two) |*result| result.deinit();

    const one_digest = try canonicalDigest(std.testing.allocator, &config, &one);
    const two_digest = try canonicalDigest(std.testing.allocator, &config, &two);
    try std.testing.expect(!std.mem.eql(u8, &one_digest, &two_digest));
}

fn findCheck(gate: *const Gate, name: []const u8) ?*const Check {
    for (gate.checks) |*check| {
        if (std.mem.eql(u8, check.name, name)) return check;
    }
    return null;
}

test "a list that pays per row fails cost.rows on any machine speed" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(false);

    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("sessions").?, 9.4);
    defer gate.deinit();

    try std.testing.expect(!findCheck(&gate, "cost.rows").?.ok);
    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(gate.enforced);
}

test "a slow machine that slows both routes equally keeps cost.rows green" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(false);

    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("sessions").?, 1.25);
    defer gate.deinit();

    try std.testing.expect(findCheck(&gate, "cost.rows").?.ok);
    try std.testing.expect(gate.verdict_pass);
}

test "the sessions scenario carries its own p99 ceiling, not the global one" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(false);
    phases[0].latency.p99_ms = 8.0;

    var health_gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("health").?, 0);
    defer health_gate.deinit();
    try std.testing.expect(!findCheck(&health_gate, "latency.p99_c1").?.ok);

    var sessions_gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("sessions").?, 1.0);
    defer sessions_gate.deinit();
    try std.testing.expect(findCheck(&sessions_gate, "latency.p99_c1").?.ok);
}

test "a session list over its ceiling blocks the run without strict" {
    var phases = try healthyPhases(std.testing.allocator);
    defer for (&phases) |*phase| phase.deinit();
    var config = healthyConfig(false);
    phases[0].latency.p99_ms = 400.0;

    var gate = try evaluateGate(std.testing.allocator, &phases, &config, findScenario("sessions").?, 1.0);
    defer gate.deinit();

    try std.testing.expect(!gate.verdict_pass);
    try std.testing.expect(gate.enforced);
}

test "the sessions scenario keeps its seed, probe and both ceilings" {
    const sessions = findScenario("sessions").?;
    try std.testing.expect(sessions.seed_route != null);
    try std.testing.expect(sessions.probe_contract);
    try std.testing.expect(sessions.reference_route != null);
    try std.testing.expect(sessions.max_p99_ms > 0);
    try std.testing.expect(sessions.max_cost_ratio > 0);
    try std.testing.expect(sessions.enforced_performance);
}

test "a request with a body declares its length and content type" {
    var config: Config = .{ .port = 1234 };
    const payload = try buildRequest(std.testing.allocator, &config, .patch, "/x", "{\"a\":1}");
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.startsWith(u8, payload, "PATCH /x HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, payload, "Content-Type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Content-Length: 7\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, payload, "\r\n\r\n{\"a\":1}"));
}

test "a GET request still carries no body framing" {
    var config: Config = .{ .port = 1234 };
    const payload = try buildRequest(std.testing.allocator, &config, .get, "/health", null);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.startsWith(u8, payload, "GET /health HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, payload, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, payload, "\r\n\r\n"));
}

test "the reorder body names every seeded document, highest id first" {
    const body = try reorderBody(std.testing.allocator, 3);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"ordered_ids\":[\"bench-doc-0003\",\"bench-doc-0002\",\"bench-doc-0001\"]}", body);
}

test "the documents scenarios are seeded, probe their contract and sit on their own route" {
    const list = findScenario("documents").?;
    try std.testing.expectEqualStrings("/api/workspaces/bench-docs/documents", list.route);
    try std.testing.expectEqual(Method.get, list.method);
    try std.testing.expect(list.probe_contract);
    try std.testing.expectEqualStrings("/api/bench/seed/documents?rows=50", list.seed_route.?);
    try std.testing.expectEqual(@as(u32, 0), list.reorder_rows);

    const reorder = findScenario("documents-reorder").?;
    try std.testing.expectEqualStrings("/api/workspaces/bench-docs/documents/reorder", reorder.route);
    try std.testing.expectEqual(Method.patch, reorder.method);
    try std.testing.expect(reorder.probe_contract);
    try std.testing.expectEqual(@as(u32, 50), reorder.reorder_rows);
    try std.testing.expectEqualStrings("/api/bench/seed/documents?rows=50", reorder.seed_route.?);
    try std.testing.expect(reorder.min_rps < findScenario("documents").?.min_rps);
}

test "the measured documents-reorder payload is the PATCH the seed prepared" {
    var config: Config = .{ .port = 1234 };
    const payload = try buildPayload(std.testing.allocator, &config, findScenario("documents-reorder").?);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.startsWith(u8, payload, "PATCH /api/workspaces/bench-docs/documents/reorder HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bench-doc-0050\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bench-doc-0001\"") != null);
}
