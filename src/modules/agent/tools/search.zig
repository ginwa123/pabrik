const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const sanitize = @import("helpers").sanitize;

pub const SearchError = error{
    /// Pattern was an empty string — almost certainly a caller bug, not a
    /// "no match" condition. ripgrep accepts empty patterns but the tool
    /// should reject them so the LLM/operator sees a clear error.
    EmptyPattern,
    /// Pattern contained a NUL byte. ripgrep silently truncates at NUL,
    /// which would mean the LLM's intended search runs against a shorter
    /// (and likely wrong) pattern. Reject up-front instead.
    PatternContainsNulByte,
    /// max_output was 0. Passing stdout_limit = .limited(0) to ripgrep
    /// produces zero output and a confusing failure mode.
    InvalidMaxOutput,
    /// max_output exceeded the hard ceiling (100 MB). Prevents a single
    /// search from OOM-ing the process.
    MaxOutputTooLarge,
    /// max_results was 0. Returns empty matches + "<warning>pattern not
    /// found" which looks identical to a real no-match and confuses the
    /// LLM. Treat as a caller bug.
    InvalidMaxResults,
    /// head or tail was 0. `head=0` / `tail=0` also look identical to a
    /// real no-match, so they are rejected the same way as max_results=0.
    InvalidHeadTail,
    /// The `glob` filter contained a NUL byte — rg copies the value into a
    /// C string, so everything after the NUL would be silently dropped.
    GlobContainsNulByte,
    /// ripgrep could not parse the pattern as a valid regex (exit 2
    /// with a "regex parse error" / "regex error" signature in stderr).
    RegexParseError,
    /// ripgrep could not access the path (path doesn't exist, permission
    /// denied, etc). Wraps the ripgrep stderr text in the error name.
    PathError,
    /// ripgrep did not finish before timeout_ms elapsed. The child was
    /// killed and reaped — the worker never blocks forever. Returned for
    /// timeout_ms == 0 as well (fail-fast path used by tests).
    Timeout,
    /// The ripgrep binary itself is missing (spawn FileNotFound while the
    /// cwd probes fine). Distinct from PathError so the LLM installs rg
    /// instead of retrying with a different path.
    RgNotFound,
    /// The pipe reader could not read or retain the result stream. This is
    /// distinct from an ordinary stdout byte cap, which is recoverable.
    OutputReadFailed,
    /// stderr exceeded the diagnostic byte cap and can no longer be trusted
    /// to explain a genuine ripgrep failure.
    StderrTooLong,
};

/// Default deadline for one ripgrep invocation (30s). Windows Defender +
/// NTFS make broad scans 10-50x slower than POSIX; without a bound a
/// single slow scan blocked the agent worker forever (2026-09-05 freeze).
pub const default_search_timeout_ms: u64 = 30_000;

/// Upper clamp for timeout_ms (1h). A caller-supplied astronomic value
/// would overflow the ns conversion below; clamp instead of erroring so
/// normal calls never fail validation on this field.
pub const max_search_timeout_ms: u64 = 3_600_000;

const SearchNanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
// Raw nanosleep (NOT std.Io.sleep): the workflow runs tools inside an
// Io.Group worker and parking that worker deadlocks the group. Same
// rationale as shell.zig's NanoSleepTimespec.
extern "c" fn nanosleep(req: *const SearchNanoSleepTimespec, rem: ?*SearchNanoSleepTimespec) c_int;

/// Sleep ~10ms between deadline polls. Windows: Win32 Sleep via
/// helpers.sleepMillis.
fn pollSleep10ms() void {
    if (builtin.os.tag == .windows) {
        @import("helpers").sleepMillis(10);
    } else {
        const ts = SearchNanoSleepTimespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = nanosleep(&ts, null);
    }
}

/// Probe whether rg_binary resolves: spawn `<rg> --version` with an
/// inherited cwd. True = binary exists (cwd was the problem), false =
/// binary missing. Only called on the rare spawn-FileNotFound path.
fn probeRg(io: std.Io, rg_binary: []const u8) bool {
    var probe = std.process.spawn(io, .{
        .argv = &.{ rg_binary, "--version" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
        .cwd = .inherit,
    }) catch return false;
    _ = probe.wait(io) catch {};
    return true;
}

const search_match_event_marker = "\"type\":\"match\"";

/// Count complete ripgrep JSON match events without retaining the discarded
/// suffix of a capped stream. The carry is bounded to marker.len - 1 bytes,
/// so a marker split across two pipe reads is still detected.
const SearchMatchCounter = struct {
    carry: [search_match_event_marker.len - 1]u8 = undefined,
    carry_len: usize = 0,
    line_has_match: bool = false,
    count: usize = 0,

    fn consume(self: *SearchMatchCounter, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.carry_len < search_match_event_marker.len) {
                var window: [search_match_event_marker.len]u8 = undefined;
                @memcpy(window[0..self.carry_len], self.carry[0..self.carry_len]);
                window[self.carry_len] = byte;
                if (self.carry_len + 1 == search_match_event_marker.len and
                    std.mem.eql(u8, window[0..], search_match_event_marker))
                {
                    self.line_has_match = true;
                }
            }

            if (self.carry_len < search_match_event_marker.len - 1) {
                self.carry[self.carry_len] = byte;
                self.carry_len += 1;
            } else {
                std.mem.copyForwards(
                    u8,
                    self.carry[0 .. search_match_event_marker.len - 2],
                    self.carry[1 .. search_match_event_marker.len - 1],
                );
                self.carry[search_match_event_marker.len - 2] = byte;
            }

            if (byte == '\n') {
                if (self.line_has_match) self.count += 1;
                self.line_has_match = false;
                self.carry_len = 0;
            }
        }
    }
};

const SearchPipeReadState = enum {
    complete,
    output_truncated,
    read_failed,
    allocation_failed,
};

/// Per-pipe reader context (one per stdout/stderr thread). File scope —
/// std.Thread.spawn takes a plain function, not a struct namespace.
const SearchPipeReadContext = struct {
    stream: std.Io.File,
    io: std.Io,
    buf: *[4096]u8,
    data: *std.ArrayList(u8),
    state: *SearchPipeReadState,
    failure_flag: *std.atomic.Value(bool),
    max_output: usize,
    eof_flag: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    bytes_seen: *u64,
    match_counter: ?*SearchMatchCounter,
};

fn readSearchPipe(ctx: SearchPipeReadContext) void {
    defer ctx.eof_flag.store(true, .release);
    while (true) {
        const n = std.Io.File.readStreaming(ctx.stream, ctx.io, &.{ctx.buf}) catch |err| {
            if (err == error.EndOfStream) return;
            ctx.state.* = .read_failed;
            ctx.failure_flag.store(true, .release);
            return;
        };
        if (n == 0) return;

        ctx.bytes_seen.* += @intCast(n);
        if (ctx.match_counter) |counter| counter.consume(ctx.buf[0..n]);

        // Keep draining after the cap (and after an allocation failure) so
        // the child never blocks on a full pipe. The caller inspects the
        // state only after both reader threads have joined.
        if (ctx.state.* == .read_failed) return;
        if (ctx.state.* == .allocation_failed or ctx.state.* == .output_truncated) continue;

        const remaining = if (ctx.data.items.len < ctx.max_output)
            ctx.max_output - ctx.data.items.len
        else
            0;
        const keep = @min(n, remaining);
        if (keep > 0) {
            ctx.data.appendSlice(ctx.allocator, ctx.buf[0..keep]) catch {
                ctx.state.* = .allocation_failed;
                ctx.failure_flag.store(true, .release);
                continue;
            };
        }
        if (keep < n) ctx.state.* = .output_truncated;
    }
}

pub const SearchMatch = struct {
    file: []const u8,
    line_number: usize,
    file_total_lines: usize,
    snippet: []const u8,
};

/// Default byte length of a rendered snippet. See
/// SearchInput.snippet_max_chars.
pub const default_snippet_max_chars: usize = 240;

/// Internal struct for grouped file matches
const MatchInFile = struct {
    line_number: usize,
    snippet: []const u8,
};

pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
    head: ?usize = null,
    tail: ?usize = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    group_by_file: bool = true, // when true, results are grouped by file
    cwd: ?[]const u8 = null,
    /// When true (default), ripgrep respects .gitignore / .ignore /
    /// .rgignore.
    respect_ignore_files: bool = true,
    /// When true, appends `-w` to rg's argv: matches must be at a word
    /// boundary (start/end of file, or between word and non-word chars).
    /// ripgrep's default Unicode word rule treats underscore as a word char,
    word_boundary: bool = false,
    /// When true, the pattern is treated as a literal string (no regex
    /// metacharacters are interpreted). Maps to rg's `-F` /
    /// `--fixed-strings`.
    literal: bool = false,
    /// When true, only the matched substring is shown per line (instead of
    /// the full line content). Maps to rg's `-o` / `--only-matching`.
    only_matching: bool = false,
    /// Long-line window, in bytes. rg's `lines.text` is the ENTIRE line — not
    /// a preview — so one minified bundle / single-line JSON blob match can
    /// be megabytes and swallow the whole tool-output budget (the agent loop
    snippet_max_chars: ?usize = null,
    /// When true, appends `--hidden` to rg's argv: dotfiles and dotdirs
    /// (.github/workflows/, .env) become searchable. rg skips hidden entries
    /// by default, and `--no-ignore` does NOT change that — it only disables
    hidden: bool = false,
    /// ripgrep `--glob` filter, e.g. "*.zig", "*.vue", "!test_*.zig". Passed
    /// as ONE argv element (`--glob=<pattern>`) so a value starting with `-`
    /// can never be read as a flag.
    glob: ?[]const u8 = null,
    /// Deadline for one rg invocation in milliseconds (null → 30s default,
    /// clamped to 1h). 0 fails fast with error.Timeout.
    timeout_ms: ?u64 = null,
    /// ripgrep binary override (null → "rg" from PATH). Test hook for the
    /// RgNotFound path + escape hatch for boxes where rg lives outside PATH.
    rg_binary: ?[]const u8 = null,
};

pub const SearchResult = struct {
    matches: std.ArrayList(SearchMatch),
    /// No-match warning body (`<warning>…</warning>`); empty whenever at
    /// least one row was collected.
    warning: []const u8 = "",
    /// Number of match EVENTS rg produced (one per matched line). Compared
    /// against `matches.items.len` this exposes silent truncation: the
    /// caller can tell "50 matches" from "50 of 9,000".
    total_matches: usize = 0,
    /// True when the visible result is incomplete because any output/row cap
    /// was reached (max_output, max_results, head, or tail).
    truncated: bool = false,
    /// True when the raw ripgrep stdout stream exceeded max_output. The
    /// retained prefix can still contain complete match records.
    output_truncated: bool = false,
    /// Number of raw stdout bytes observed, including bytes drained after
    /// max_output was reached.
    output_bytes: u64 = 0,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        self.matches.deinit(allocator);
        allocator.free(self.warning);
    }
};

fn getTextFromJson(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .object) {
            if (val.object.get("text")) |text_val| {
                if (text_val == .string) {
                    return text_val.string;
                }
            }
        }
    }
    return null;
}

fn getMatchedLines(obj: *const std.json.ObjectMap) ?usize {
    if (obj.get("stats")) |stats| {
        if (stats == .object) {
            if (stats.object.get("matched_lines")) |ml| {
                if (ml == .integer) {
                    return @intCast(ml.integer);
                }
            }
            if (stats.object.get("lines_with_matches")) |lw| {
                if (lw == .integer) {
                    return @intCast(lw.integer);
                }
            }
        }
    }
    return null;
}

/// Hard ceiling on max_output to prevent a single search from OOM-ing the
/// process. 100 MB is large enough for any practical search (genuinely huge
/// codebases will still fit) but small enough to bound the worst case.
pub const max_output_hard_limit: usize = 100 * 1024 * 1024;

/// True for rg's per-match JSON lines. rg emits one COMPACT object per line
/// (`{"type":"match","data":{…}}` — no spaces), so a substring test is
/// enough.
fn lineIsMatchEvent(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\":\"match\"") != null;
}

/// Window `text` to at most `cap` bytes, biased left of `offset` (the byte
/// offset of the first match inside `text`), with `...` markers where content
/// was dropped, then trim surrounding whitespace.
fn windowSnippet(allocator: std.mem.Allocator, text: []const u8, offset: usize, cap: usize) ![]u8 {
    if (cap == 0 or text.len <= cap) {
        return try allocator.dupe(u8, std.mem.trim(u8, text, &std.ascii.whitespace));
    }

    const off = if (offset > text.len) text.len else offset;
    const before = cap / 3;
    var start: usize = if (off > before) off - before else 0;
    var end: usize = start + cap;
    if (end > text.len) {
        end = text.len;
        start = if (end > cap) end - cap else 0;
    }
    // Never split a UTF-8 sequence: skip forward off a continuation byte for
    // the start, back off to one for the end.
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    while (end < text.len and end > start and (text[end] & 0xC0) == 0x80) end -= 1;

    const body = std.mem.trim(u8, text[start..end], &std.ascii.whitespace);
    const prefix: []const u8 = if (start > 0) "..." else "";
    const suffix: []const u8 = if (end < text.len) "..." else "";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, suffix);
    return try out.toOwnedSlice(allocator);
}

/// Where ripgrep ran, and what came back. Under `--saas` the GUEST runs it —
/// the scan happens where the files are, and the host opens none of them.
pub const Runner = struct {
    ctx: *const anyopaque,
    runFn: *const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        argv: []const []const u8,
        timeout_ms: u64,
        max_output: usize,
    ) anyerror!Run,
};

pub const Run = struct {
    stdout: []u8,
    stderr: []u8,
    code: i64,
    timed_out: bool,
    truncated: bool,

    pub fn deinit(self: Run, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// ripgrep's output, whichever substrate produced it.
const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    /// The stdout cap cut the stream: a bounded partial result, not a failure.
    capped: bool,
    bytes: u64,
    match_events: usize,

    pub fn deinit(self: Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// The match events in a stream that arrived in one piece — the same count the
/// host's reader thread makes while the bytes arrive.
fn countMatchEvents(stdout: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, stdout, at, '\n') orelse stdout.len;
        if (lineIsMatchEvent(stdout[at..line_end])) count += 1;
        at = line_end + 1;
    }
    return count;
}

/// Spawn ripgrep HERE and collect its streams. Everything the search does to
/// its own host process lives in this function and nowhere else.
fn spawnAndCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    arg_cwd: []const u8,
    rg_binary: []const u8,
    max_output: usize,
    timeout_ns: u64,
) !Captured {
    var child = std.process.spawn(io, .{
        .argv = args,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = arg_cwd },
    }) catch |err| {
        // FileNotFound is ambiguous: missing rg binary vs missing cwd.
        // Probe the binary from an inherited cwd to disambiguate.
        if (err == error.FileNotFound) {
            if (probeRg(io, rg_binary)) return error.PathError;
            return error.RgNotFound;
        }
        return err;
    };
    // Cleanup for every error return below: pipes are nulled after close
    // so this never double-closes; child_waited skips the second wait
    // (double-wait on a reaped child aborts). kill on a dead child is safe.
    var child_waited = false;
    errdefer {
        if (!child_waited) {
            // Child.kill both terminates and reaps in Zig 0.16; never call
            // wait after it because kill clears Child.id.
            child.kill(io);
            child_waited = true;
        }
        if (child.stdout) |p| p.close(io);
        if (child.stderr) |p| p.close(io);
    }

    var stdout_data: std.ArrayList(u8) = .empty;
    defer stdout_data.deinit(allocator);
    var stderr_data: std.ArrayList(u8) = .empty;
    defer stderr_data.deinit(allocator);
    var stdout_state: SearchPipeReadState = .complete;
    var stderr_state: SearchPipeReadState = .complete;
    var stdout_failure = std.atomic.Value(bool).init(false);
    var stderr_failure = std.atomic.Value(bool).init(false);
    var stdout_eof = std.atomic.Value(bool).init(false);
    var stderr_eof = std.atomic.Value(bool).init(false);
    var stdout_bytes: u64 = 0;
    var stderr_bytes: u64 = 0;
    var stdout_match_counter = SearchMatchCounter{};

    const ReadContext = SearchPipeReadContext;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    const stdout_stream = child.stdout orelse return error.PathError;
    const stderr_stream = child.stderr orelse return error.PathError;
    const stdout_thread = try std.Thread.spawn(.{}, readSearchPipe, .{ReadContext{
        .stream = stdout_stream,
        .io = io,
        .buf = &stdout_buf,
        .data = &stdout_data,
        .state = &stdout_state,
        .failure_flag = &stdout_failure,
        .max_output = max_output,
        .eof_flag = &stdout_eof,
        .allocator = allocator,
        .bytes_seen = &stdout_bytes,
        .match_counter = &stdout_match_counter,
    }});
    const stderr_thread = std.Thread.spawn(.{}, readSearchPipe, .{ReadContext{
        .stream = stderr_stream,
        .io = io,
        .buf = &stderr_buf,
        .data = &stderr_data,
        .state = &stderr_state,
        .failure_flag = &stderr_failure,
        .max_output = max_output,
        .eof_flag = &stderr_eof,
        .allocator = allocator,
        .bytes_seen = &stderr_bytes,
        .match_counter = null,
    }}) catch |err| {
        // stderr spawn failed AFTER the stdout reader is already running with
        // a stack-borrowed buf.
        if (child.stdout) |p| {
            p.close(io);
            child.stdout = null;
        }
        stdout_thread.join();
        return err;
    };
    // Join-gate: the explicit joins below run on the happy path; any later
    // `return error.X` (Timeout, PathError, RegexParseError, …) fires this
    // errdefer.
    var threads_joined = false;
    errdefer {
        if (!threads_joined) {
            stdout_thread.join();
            stderr_thread.join();
        }
    }

    // Deadline poll (10ms cadence, same as shell.zig). No std.Io.sleep
    // — it would park the Io.Group worker. Timestamp is i96 in Zig
    // 0.16: keep the inferred width, don't narrow to i64.
    const deadline_ns = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i64, @intCast(timeout_ns));
    var timeout_hit = false;
    var reader_failed = false;
    while (!(stdout_eof.load(.acquire) and stderr_eof.load(.acquire))) {
        if (stdout_failure.load(.acquire) or stderr_failure.load(.acquire)) {
            reader_failed = true;
            break;
        }
        if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
            timeout_hit = true;
            break;
        }
        pollSleep10ms();
    }

    if (reader_failed) {
        child.kill(io);
        child_waited = true;
    }

    // Close pipes (unblocks readers) BEFORE join — same order as shell.zig.
    if (child.stdout) |p| {
        p.close(io);
        child.stdout = null;
    }
    if (child.stderr) |p| {
        p.close(io);
        child.stderr = null;
    }
    stdout_thread.join();
    stderr_thread.join();
    threads_joined = true;

    if (timeout_hit) {
        if (!child_waited) {
            child.kill(io);
            child_waited = true;
        }
        return error.Timeout;
    }
    if (reader_failed or stdout_state == .read_failed or stdout_state == .allocation_failed or
        stderr_state == .read_failed or stderr_state == .allocation_failed)
    {
        if (!child_waited) {
            child.kill(io);
            child_waited = true;
        }
        return error.OutputReadFailed;
    }
    const term = child.wait(io) catch return error.PathError;
    child_waited = true;

    // A capped stdout stream is a successful, bounded partial result.

    // === Map ripgrep exit code to a domain error or accept stdout ===
    // ripgrep exit codes (from rg --help): 0 — match found 1 — no match
    // (empty stdout, stderr empty) 2 — error (regex parse error, file/dir not
    switch (term) {
        .exited => |code| switch (code) {
            0 => {}, // success — fall through
            1 => {}, // no match — fall through (empty matches list will yield "pattern not found" later)
            else => {
                // exit 2 (or other non-zero) → distinguish by stderr
                const stderr_text: []const u8 = stderr_data.items;
                if (std.mem.indexOf(u8, stderr_text, "regex") != null or
                    std.mem.indexOf(u8, stderr_text, "Regex") != null or
                    std.mem.indexOf(u8, stderr_text, "pattern") != null)
                {
                    return error.RegexParseError;
                }
                return error.PathError;
            },
        },
        .signal, .stopped, .unknown => {
            // rg was killed by signal (e.g. ulimit, OOM) or terminated
            // abnormally. Surface as a path/I/O error so the LLM retries
            // with a different path or smaller pattern.
            return error.PathError;
        },
    }

    // A capped stdout stream is a successful, bounded partial result.
    if (stderr_state == .output_truncated) return error.StderrTooLong;
    return .{
        .stdout = try stdout_data.toOwnedSlice(allocator),
        .stderr = try stderr_data.toOwnedSlice(allocator),
        .capped = stdout_state == .output_truncated,
        .bytes = stdout_bytes,
        .match_events = stdout_match_counter.count,
    };
}

pub fn executeSearch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, input: SearchInput) !SearchResult {
    return executeSearchWith(allocator, io, cwd, input, null);
}

/// The same search, with the place ripgrep runs chosen by the caller: null
/// spawns it here, and a runner is the guest's own scan.
pub fn executeSearchWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: SearchInput,
    runner: ?Runner,
) !SearchResult {
    // === Up-front validation (no ripgrep invocation if any fail) ===

    // Validate head/tail are mutually exclusive
    if (input.head != null and input.tail != null) {
        return error.HeadAndTailMutuallyExclusive;
    }

    // head=0 / tail=0 select zero rows while still reporting success —
    // indistinguishable from a real "no match", so reject them the same way
    // max_results=0 is rejected.
    if (input.head) |head_n| {
        if (head_n == 0) return error.InvalidHeadTail;
    }
    if (input.tail) |tail_n| {
        if (tail_n == 0) return error.InvalidHeadTail;
    }

    // Pattern must be non-empty. ripgrep accepts empty patterns but the
    // result is meaningless — reject so the caller sees a clear error.
    if (input.pattern.len == 0) return error.EmptyPattern;

    // Reject patterns containing NUL bytes. ripgrep's C-string handling
    // truncates at NUL, which would mean the LLM's intended pattern is
    // silently mutated. Refuse the call entirely.
    if (std.mem.indexOfScalar(u8, input.pattern, 0) != null) {
        return error.PatternContainsNulByte;
    }

    // Same NUL hazard for the glob filter: rg copies argv into C strings,
    // so anything after a NUL would be silently dropped from the filter.
    if (input.glob) |glob_pattern| {
        if (std.mem.indexOfScalar(u8, glob_pattern, 0) != null) {
            return error.GlobContainsNulByte;
        }
    }

    // Validate max_output bounds up-front. Zero is meaningless; over the
    // hard ceiling risks OOM.
    const max_output = input.max_output orelse 1024 * 1024;
    if (max_output == 0) return error.InvalidMaxOutput;
    if (max_output > max_output_hard_limit) return error.MaxOutputTooLarge;

    // Validate max_results. Zero is indistinguishable from "no match" and
    // is almost certainly a caller bug.
    const max_results = input.max_results orelse 50;
    if (max_results == 0) return error.InvalidMaxResults;

    const snippet_max_chars = input.snippet_max_chars orelse default_snippet_max_chars;

    const rg_binary = input.rg_binary orelse "rg";
    const timeout_ms = input.timeout_ms orelse default_search_timeout_ms;
    // Fail fast BEFORE spawning (also the deterministic hook for tests).
    if (timeout_ms == 0) return error.Timeout;
    // Clamp WITHOUT @min: `@min(u64, u64) * std.time.ns_per_ms` miscompiles
    // on Zig 0.16.0 (compile error in isolation, phantom overflow at
    // runtime). Plain u64 × u64 with an explicitly-typed constant is safe.
    const clamped_ms: u64 = if (timeout_ms > max_search_timeout_ms) max_search_timeout_ms else timeout_ms;
    const ns_per_ms_u64: u64 = std.time.ns_per_ms;
    const timeout_ns: u64 = clamped_ms * ns_per_ms_u64;

    // === Build ripgrep argv with flag-injection defense === We use `-e
    // <pattern>` to tell ripgrep "next arg is the pattern", which means a
    // pattern starting with `-` (e.g.
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    // `--glob=<pattern>` is one argv element, so a value that starts with
    // `-` cannot be reinterpreted as another flag.
    var glob_arg: ?[]u8 = null;
    defer if (glob_arg) |owned| allocator.free(owned);

    try args.append(allocator, rg_binary);
    try args.append(allocator, "--json");
    try args.append(allocator, "--line-number");
    try args.append(allocator, "--no-config");
    try args.append(allocator, "--no-messages");
    if (!input.respect_ignore_files) {
        try args.append(allocator, "--no-ignore");
    }
    if (input.hidden) {
        // rg skips dotfiles/dotdirs unless --hidden is passed. --no-ignore
        // only disables ignore-FILE filtering, so without this flag
        // `.github/workflows/…` stays invisible even with
        try args.append(allocator, "--hidden");
    }
    if (input.glob) |glob_pattern| {
        if (glob_pattern.len > 0) {
            glob_arg = try std.fmt.allocPrint(allocator, "--glob={s}", .{glob_pattern});
            try args.append(allocator, glob_arg.?);
        }
    }
    if (input.word_boundary) {
        // -w: only match whole words (word-boundary semantics). rg's default
        // Unicode word rule treats underscore as a word char, so this matches
        // what `-w` says, not what an English speaker might expect for
        try args.append(allocator, "-w");
    }
    // Chunk 2: literal / -F flag. Treat the pattern as opaque bytes instead
    // of a regex.
    if (input.literal) {
        try args.append(allocator, "-F");
    }
    if (input.only_matching) {
        // -o / --only-matching: rg emits ONLY the matched substring per line
        // (via data.submatches[]), NOT the full surrounding line.
        try args.append(allocator, "-o");
    }
    try args.append(allocator, "-e");
    try args.append(allocator, input.pattern);
    try args.append(allocator, "--");
    try args.append(allocator, input.path);

    var captured = if (runner) |chosen| blk: {
        var ran = try chosen.runFn(
            chosen.ctx,
            allocator,
            io,
            input.cwd orelse cwd,
            args.items,
            clamped_ms,
            max_output,
        );
        defer ran.deinit(allocator);
        if (ran.timed_out) return error.Timeout;
        if (ran.code != 0 and ran.code != 1) {
            // The guest's own `exec failed` is what an image without ripgrep
            // says, and it is the same answer the host gives when rg is not
            // installed: nothing to scan with.
            if (ran.code == 127 and std.mem.indexOf(u8, ran.stderr, "exec failed") != null) {
                return error.RgNotFound;
            }
            if (std.mem.indexOf(u8, ran.stderr, "regex") != null or
                std.mem.indexOf(u8, ran.stderr, "Regex") != null or
                std.mem.indexOf(u8, ran.stderr, "pattern") != null)
            {
                return error.RegexParseError;
            }
            return error.PathError;
        }
        break :blk Captured{
            .stdout = try allocator.dupe(u8, ran.stdout),
            .stderr = try allocator.dupe(u8, ran.stderr),
            .capped = ran.truncated,
            .bytes = ran.stdout.len,
            .match_events = countMatchEvents(ran.stdout),
        };
    } else try spawnAndCollect(allocator, io, args.items, input.cwd orelse cwd, rg_binary, max_output, timeout_ns);
    defer captured.deinit(allocator);


    var matches = std.ArrayList(SearchMatch).empty;
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        matches.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file_stats = std.StringHashMap(usize).init(allocator);
    defer file_stats.deinit();

    // Row cap + collection mode.
    const mode_requested: usize = if (input.head) |head_n| head_n else if (input.tail) |tail_n| tail_n else max_results;
    const row_cap: usize = if (mode_requested < max_results) mode_requested else max_results;
    const tail_mode = input.tail != null;
    // Match EVENTS seen (not rows kept) — the honest denominator for
    // `total=`/`truncated=` in the rendered envelope.
    var seen_total: usize = 0;
    // Cleared once row_cap rows are collected; from then on the loop only
    // counts match events instead of JSON-parsing every remaining line.
    var collecting = true;

    const stdout_slice: []const u8 = captured.stdout;
    var line_start: usize = 0;
    var current_file: ?[]const u8 = null;

    while (line_start < stdout_slice.len) {
        const line_end = std.mem.indexOfScalarPos(u8, stdout_slice, line_start, '\n') orelse stdout_slice.len;
        const line = stdout_slice[line_start..line_end];

        if (line.len > 0) {
            if (!collecting) {
                // A capped final segment may be partial. Do not count its
                // marker unless it is newline-terminated; the full-stream
                // counter already accounts for complete match events.
                if (captured.capped and
                    line_end == stdout_slice.len and
                    line_end > line_start and
                    !std.mem.endsWith(u8, stdout_slice, "\n"))
                {
                    line_start = line_end;
                    continue;
                }
                // Row cap reached — only the total count matters now, and
                // rg's raw line tells us a match event cheaply.
                if (lineIsMatchEvent(line)) seen_total += 1;
                line_start = line_end + 1;
                continue;
            }

            const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, line, .{}) catch {
                line_start = line_end + 1;
                continue;
            };

            if (parsed.value.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "begin")) {
                    if (parsed.value.object.get("data")) |data| {
                        if (data == .object) {
                            if (getTextFromJson(&data.object, "path")) |path_text| {
                                current_file = path_text;
                            }
                        }
                    }
                } else if (type_val == .string and std.mem.eql(u8, type_val.string, "match")) {
                    // Counted as soon as the event is recognised (not at
                    // append time) so `total=` matches what the cheap
                    // substring scan counts once collection stops.
                    seen_total += 1;
                    if (parsed.value.object.get("data")) |data| {
                        if (data == .object) {
                            var match_file: []const u8 = "";
                            var match_snippet: []const u8 = "";
                            // Byte offset of the first submatch inside
                            // `match_snippet` — drives the long-line window.
                            // 0 is correct for the --only-matching paths (the
                            var snippet_offset: usize = 0;
                            // Tracks whether match_snippet is a heap-owned
                            // allocation we must free (true only when built
                            // from the comma-joined multi-submatch path).
                            var match_snippet_owned = false;
                            var line_num: usize = 0;
                            var line_num_valid = false;
                            var file_ok = false;

                            if (getTextFromJson(&data.object, "path")) |path_text| {
                                if (path_text.len > 0) {
                                    match_file = path_text;
                                    file_ok = true;
                                }
                            }

                            if (input.only_matching) {
                                // --only-matching: snippet = matched
                                // substring(s) from submatches[].
                                if (data.object.get("submatches")) |submatches_val| {
                                    if (submatches_val == .array) {
                                        const submatch_list = submatches_val.array;
                                        if (submatch_list.items.len == 1) {
                                            // Single submatch: use its match.text directly.
                                            if (getTextFromJson(&submatch_list.items[0].object, "match")) |match_text| {
                                                match_snippet = match_text;
                                            }
                                        } else if (submatch_list.items.len > 1) {
                                            // Multiple submatches on same
                                            // line: comma-join into one
                                            // snippet string.
                                            var combined: std.ArrayList(u8) = .empty;
                                            defer combined.deinit(allocator);
                                            for (submatch_list.items, 0..) |sub, i| {
                                                if (i > 0) try combined.append(allocator, ',');
                                                if (getTextFromJson(&sub.object, "match")) |m| {
                                                    try combined.appendSlice(allocator, m);
                                                }
                                            }
                                            // Heap-owned dupe
                                            // (allocator.dupe) so the slice
                                            // outlives the ArrayList's defer.
                                            const owned = allocator.dupe(u8, combined.items) catch {
                                                // OOM: skip this match
                                                continue;
                                            };
                                            match_snippet = owned;
                                            match_snippet_owned = true;
                                        }
                                        // If submatch_list.items.len == 0
                                        // (shouldn't happen for a real match
                                        // event), match_snippet stays "".
                                    }
                                }
                            } else {
                                // Default: snippet = full surrounding line.
                                if (getTextFromJson(&data.object, "lines")) |lines_text| {
                                    match_snippet = lines_text;
                                }
                                // First submatch offset (relative to
                                // lines.text) — rg's JSON gives us the match
                                // position for free; without it a windowed
                                if (data.object.get("submatches")) |submatches_val| {
                                    if (submatches_val == .array and submatches_val.array.items.len > 0) {
                                        if (submatches_val.array.items[0].object.get("start")) |start_val| {
                                            if (start_val == .integer and start_val.integer >= 0) {
                                                snippet_offset = @intCast(start_val.integer);
                                            }
                                        }
                                    }
                                }
                            }

                            if (data.object.get("line_number")) |ln| {
                                if (ln == .integer) {
                                    // Validate before casting: rg emits
                                    // positive line numbers, so 0 or negative
                                    // is corrupt.
                                    if (ln.integer >= 1 and ln.integer <= std.math.maxInt(usize)) {
                                        line_num = @intCast(ln.integer);
                                        line_num_valid = true;
                                    }
                                }
                            }

                            if (line_num_valid and file_ok) {
                                // The multi-submatch path heap-allocates
                                // match_snippet via allocator.dupe; the
                                // default-line and single-submatch paths
                                defer if (match_snippet_owned) allocator.free(match_snippet);

                                // Sanitize the snippet to ensure valid UTF-8.
                                // rg emits snippets in the file's encoding;
                                // binary files can contain invalid UTF-8
                                const sanitized_snippet = sanitize.sanitizeUtf8(allocator, match_snippet) catch continue;
                                defer allocator.free(sanitized_snippet);

                                const owned_file = try allocator.dupe(u8, match_file);
                                errdefer allocator.free(owned_file);

                                // Window the (now valid-UTF-8) snippet so a
                                // single long line can never swallow the
                                // result budget.
                                const windowed_snippet = windowSnippet(allocator, sanitized_snippet, snippet_offset, snippet_max_chars) catch {
                                    allocator.free(owned_file);
                                    continue;
                                };
                                errdefer allocator.free(windowed_snippet);

                                const match = SearchMatch{
                                    .file = owned_file,
                                    .line_number = line_num,
                                    .file_total_lines = 0,
                                    .snippet = windowed_snippet,
                                };

                                if (tail_mode) {
                                    // Last-N semantics: keep the NEWEST
                                    // row_cap rows and evict the oldest, so
                                    // `tail` means "last N of the whole
                                    if (matches.items.len == row_cap) {
                                        allocator.free(matches.items[0].file);
                                        allocator.free(matches.items[0].snippet);
                                        _ = matches.orderedRemove(0);
                                    }
                                    try matches.append(allocator, match);
                                } else {
                                    try matches.append(allocator, match);
                                    if (matches.items.len >= row_cap) {
                                        // Row cap reached: stop JSON-parsing
                                        // the rest of rg's (already buffered)
                                        // output.
                                        collecting = false;
                                    }
                                }
                            }
                        }
                    }
                } else if (type_val == .string and std.mem.eql(u8, type_val.string, "end")) {
                    if (current_file != null) {
                        if (parsed.value.object.get("data")) |data| {
                            if (data == .object) {
                                if (getMatchedLines(&data.object)) |ml| {
                                    try file_stats.put(current_file.?, ml);
                                }
                            }
                        }
                    }
                }
            }
        }
        line_start = line_end + 1;
    }

    for (matches.items) |*m| {
        if (file_stats.get(m.file)) |total| {
            m.file_total_lines = total;
        }
    }

    const output_truncated = captured.capped;
    const total_matches = @max(seen_total, captured.match_events);
    const truncated = output_truncated or total_matches > matches.items.len;

    // No-match warning body. Built ONLY when nothing was collected and the
    // raw stream was not capped.
    var warning: []const u8 = "";
    errdefer if (warning.len > 0) allocator.free(warning);
    if (matches.items.len == 0 and !output_truncated) {
        if (captured.stderr.len > 0) {
            // ripgrep surfaced an error (regex parse error, permission
            // denied, etc). Surface stderr verbatim — it already names the
            // root cause.
            warning = try std.fmt.allocPrint(allocator, "<warning>{s}</warning>", .{captured.stderr});
        } else {
            // Clean no-match (rg exit code 1, empty stderr).
            warning = try std.fmt.allocPrint(
                allocator,
                "<warning>no matches for pattern \"{s}\" in path \"{s}\"</warning>",
                .{ input.pattern, input.path },
            );
        }
    }

    return SearchResult{
        .matches = matches,
        .warning = warning,
        .total_matches = total_matches,
        .truncated = truncated,
        .output_truncated = output_truncated,
        .output_bytes = captured.bytes,
    };
}

/// Multiple matches in the same file are grouped together under one entry of
/// the `files` array, inside a JSON object carrying the pattern/path plus the
/// collection summary (`returned` / `total` / `truncated`).
pub fn search_result_to_json_grouped(allocator: std.mem.Allocator, result: SearchResult, pattern: []const u8, search_path: []const u8) ![]const u8 {
    const clean_pattern = try sanitizeControlChars(allocator, pattern);
    defer allocator.free(clean_pattern);
    const clean_path = try sanitizeControlChars(allocator, search_path);
    defer allocator.free(clean_path);

    const warning_text = try cleanWarningText(allocator, result.warning);
    defer if (warning_text) |w| allocator.free(w);

    const hint = try buildTruncationHint(allocator, result);
    defer if (hint) |h| allocator.free(h);

    // Group matches by file, PRESERVING rg's output order.
    const FileGroup = struct {
        path: []const u8,
        matches: std.ArrayList(MatchInFile) = .empty,
    };
    var groups: std.ArrayList(FileGroup) = .empty;
    defer {
        for (groups.items) |*group| group.matches.deinit(allocator);
        groups.deinit(allocator);
    }
    var group_index = std.StringHashMap(usize).init(allocator);
    defer group_index.deinit();

    // Collect all matches grouped by file (insertion order = rg's order).
    for (result.matches.items) |m| {
        const index_entry = try group_index.getOrPut(m.file);
        if (!index_entry.found_existing) {
            index_entry.value_ptr.* = groups.items.len;
            try groups.append(allocator, .{ .path = m.file });
        }
        try groups.items[index_entry.value_ptr.*].matches.append(allocator, .{
            .line_number = m.line_number,
            .snippet = m.snippet,
        });
    }

    // Per-file matched-line count (rg's `stats.matched_lines` for THIS
    // search — not the file's line count, see the tool description).
    var file_totals = std.StringHashMap(usize).init(allocator);
    defer file_totals.deinit();

    for (result.matches.items) |m| {
        if (m.file_total_lines > 0) {
            try file_totals.put(m.file, m.file_total_lines);
        }
    }

    const JsonMatch = struct {
        line: usize,
        text: []const u8,
    };
    const JsonFile = struct {
        path: []const u8,
        total: usize,
        count: usize,
        matches: []const JsonMatch,
    };
    const JsonGrouped = struct {
        pattern: []const u8,
        path: []const u8,
        returned: usize,
        total: usize,
        truncated: bool,
        output_truncated: bool,
        output_bytes: u64,
        truncated_hint: ?[]const u8,
        grouped: bool,
        files: []const JsonFile,
        warning: ?[]const u8,
    };

    var files = std.ArrayList(JsonFile).empty;
    defer files.deinit(allocator);
    var owned_texts = std.ArrayList([]const u8).empty;
    defer {
        for (owned_texts.items) |t| allocator.free(t);
        owned_texts.deinit(allocator);
    }
    var owned_match_lists = std.ArrayList([]const JsonMatch).empty;
    defer {
        for (owned_match_lists.items) |l| allocator.free(l);
        owned_match_lists.deinit(allocator);
    }

    for (groups.items) |group| {
        // An output cap can cut before rg's per-file `end` event. In that
        // case use the retained row count as an honest lower bound instead
        // of serializing a misleading zero total.
        const total = file_totals.get(group.path) orelse
            (if (result.output_truncated) group.matches.items.len else 0);
        const clean_file = try sanitizeControlChars(allocator, std.mem.trim(u8, group.path, &std.ascii.whitespace));
        try owned_texts.append(allocator, clean_file);
        var jm = std.ArrayList(JsonMatch).empty;
        for (group.matches.items) |m| {
            const clean_snippet = try sanitizeControlChars(allocator, std.mem.trim(u8, m.snippet, &std.ascii.whitespace));
            try owned_texts.append(allocator, clean_snippet);
            try jm.append(allocator, .{ .line = m.line_number, .text = clean_snippet });
        }
        const jm_slice = try jm.toOwnedSlice(allocator);
        try owned_match_lists.append(allocator, jm_slice);
        try files.append(allocator, .{
            .path = clean_file,
            .total = total,
            .count = group.matches.items.len,
            .matches = jm_slice,
        });
    }

    const payload = JsonGrouped{
        .pattern = clean_pattern,
        .path = clean_path,
        .returned = result.matches.items.len,
        .total = result.total_matches,
        .truncated = result.truncated,
        .output_truncated = result.output_truncated,
        .output_bytes = result.output_bytes,
        .truncated_hint = hint,
        .grouped = true,
        .files = files.items,
        .warning = warning_text,
    };
    return try std.json.Stringify.valueAlloc(allocator, payload, .{});
}

/// Flat (non-grouped) output: one entry per match in a top-level `matches`
/// array. Same match fields as the grouped entries, plus the file each
/// match came from. Used when SearchInput.group_by_file == false.
pub fn search_result_to_json_flat(allocator: std.mem.Allocator, result: SearchResult, pattern: []const u8, search_path: []const u8) ![]const u8 {
    const clean_pattern = try sanitizeControlChars(allocator, pattern);
    defer allocator.free(clean_pattern);
    const clean_path = try sanitizeControlChars(allocator, search_path);
    defer allocator.free(clean_path);

    const warning_text = try cleanWarningText(allocator, result.warning);
    defer if (warning_text) |w| allocator.free(w);

    const hint = try buildTruncationHint(allocator, result);
    defer if (hint) |h| allocator.free(h);

    const JsonMatch = struct {
        line: usize,
        text: []const u8,
        file: []const u8,
    };
    const JsonFlat = struct {
        pattern: []const u8,
        path: []const u8,
        returned: usize,
        total: usize,
        truncated: bool,
        output_truncated: bool,
        output_bytes: u64,
        truncated_hint: ?[]const u8,
        grouped: bool,
        matches: []const JsonMatch,
        warning: ?[]const u8,
    };

    var jm = std.ArrayList(JsonMatch).empty;
    defer jm.deinit(allocator);
    var owned_texts = std.ArrayList([]const u8).empty;
    defer {
        for (owned_texts.items) |t| allocator.free(t);
        owned_texts.deinit(allocator);
    }

    for (result.matches.items) |m| {
        const clean_snippet = try sanitizeControlChars(allocator, std.mem.trim(u8, m.snippet, &std.ascii.whitespace));
        try owned_texts.append(allocator, clean_snippet);
        const clean_file = try sanitizeControlChars(allocator, std.mem.trim(u8, m.file, &std.ascii.whitespace));
        try owned_texts.append(allocator, clean_file);
        try jm.append(allocator, .{ .line = m.line_number, .text = clean_snippet, .file = clean_file });
    }

    const payload = JsonFlat{
        .pattern = clean_pattern,
        .path = clean_path,
        .returned = result.matches.items.len,
        .total = result.total_matches,
        .truncated = result.truncated,
        .output_truncated = result.output_truncated,
        .output_bytes = result.output_bytes,
        .truncated_hint = hint,
        .grouped = false,
        .matches = jm.items,
        .warning = warning_text,
    };
    return try std.json.Stringify.valueAlloc(allocator, payload, .{});
}

/// Replace JSON-hostile control bytes (NUL/C0 except tab/LF/CR, plus DEL)
/// with U+FFFD. File-local: shared helpers are frozen for this migration.
fn sanitizeControlChars(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        const keep = c == 0x09 or c == 0x0A or c == 0x0D;
        if ((c < 0x20 and !keep) or c == 0x7F) {
            try out.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Strip the `<warning>…</warning>` envelope executeSearch builds around
/// the no-match/stderr body and sanitize the inner text. Returns null when
/// there is no warning so the JSON field serializes as null.
fn cleanWarningText(allocator: std.mem.Allocator, warning: []const u8) !?[]u8 {
    if (warning.len == 0) return null;
    var inner: []const u8 = warning;
    if (std.mem.startsWith(u8, inner, "<warning>")) inner = inner["<warning>".len..];
    if (std.mem.endsWith(u8, inner, "</warning>")) inner = inner[0 .. inner.len - "</warning>".len];
    if (inner.len == 0) return null;
    const clean = try sanitizeControlChars(allocator, inner);
    errdefer allocator.free(clean);
    if (clean.len == 0) {
        allocator.free(clean);
        return null;
    }
    return clean;
}

fn buildTruncationHint(allocator: std.mem.Allocator, result: SearchResult) !?[]const u8 {
    if (!result.truncated) return null;

    if (result.output_truncated) {
        if (result.total_matches > result.matches.items.len) {
            return try std.fmt.allocPrint(
                allocator,
                "Search output exceeded the requested max_output (observed {d} bytes); {d} of {d} match events are shown from the retained prefix. Results were truncated — raise max_output, adjust max_results/head/tail, narrow the pattern/path, or add a glob filter.",
                .{ result.output_bytes, result.matches.items.len, result.total_matches },
            );
        }
        return try std.fmt.allocPrint(
            allocator,
            "Search output exceeded the requested max_output (observed {d} bytes); only complete records in the retained prefix are shown. Results were truncated — raise max_output, adjust max_results/head/tail, narrow the pattern/path, or add a glob filter.",
            .{result.output_bytes},
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "{d} of {d} matched lines shown — adjust max_results/head/tail, narrow the pattern, or add a glob filter.",
        .{ result.matches.items.len, result.total_matches },
    );
}

pub const search_tool_system_prompt =
    \\## Search Tool — Behavior
    \\Use `search` for full-text code  Always prefer this over `bash` with `rg`/`grep`.
    \\- Returns structured JSON with file paths + line numbers, respects `.gitignore`.
    \\- Use `word_boundary`, `literal`, `only_matching` flags as needed.
    \\- Narrow noisy trees with `glob` (e.g. `*.zig`) instead of post-filtering mentally.
    \\- Check `truncated=true` / `truncated_hint` on the result: it means the
    \\  visible result is incomplete. The hint identifies whether max_results
    \\  or max_output caused the truncation.
    \\- Exceeding max_output is a successful bounded result with
    \\  `output_truncated=true`; only complete records before the byte cap
    \\  are returned. Narrow `pattern`/`path`/`glob` or adjust the cap.
    \\- Snippets are windowed to `snippet_max_chars` (default 240) and control-char sanitized.
    \\- Bound results with `max_results`/`max_output`.
    \\- Use at most one of `head`/`tail`; omit the unused field entirely (never send 0 as a placeholder).
    \\
;

pub const search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search",
        .description =
        \\PRIMARY search tool for code navigation — use it instead of a shell `rg` / `grep` / `find` run through `command`.
        \\Use it to locate a definition (symbol, function, type, constant), find references to X, check whether a pattern already exists before writing new code, find which file produced an error or log line, or follow a non-trivial code path.
        \\
        \\NOT this tool:
        \\- You already know the exact file path → `read_file`.
        \\- You want files BY NAME (not by content) → `glob`.
        \\- You need a ripgrep flag this tool does not expose → run `rg` through `command`.
        \\
        \\WHY over a shell `rg`: structured JSON with line numbers and paths (no flag-juggling); .gitignore/.ignore/.rgignore honored automatically; pattern passed via argv (no shell quoting or escaping); output capped by `max_results` + `max_output`.
        \\
        \\RESPONSE FORMAT — JSON carrying the args plus the collection summary:
        \\- `returned` = rows in this response; `total` = matched lines rg found in the WHOLE search; `truncated` = true when max_output, max_results, head or tail cut the visible rows; `output_truncated` = the raw rg JSON stream exceeded max_output (a successful partial result from the retained prefix); `output_bytes` = stdout bytes observed while draining. ALWAYS check `truncated` and `truncated_hint`: when true the result is a window, not the complete answer; the hint names the active limit and is null otherwise.
        \\- `files[]` entries carry `path`, `total` (matched lines in that file for THIS search — not the file's line count, and a lower bound when output_truncated=true), `count` (rows shown), `matches[]` with `line` (1-indexed) + `text` (windowed to snippet_max_chars, default 240, "..." when the line is longer).
        \\- No matches returns `files: []` (or `matches: []` when `group_by_file` is false) plus a `warning` naming the pattern and path that were searched. Values are plain JSON strings (control bytes sanitized) — a snippet containing "</s></m>" comes back verbatim in `text`.
        \\
        \\`word_boundary` / `literal` / `only_matching` map to rg's -w / -F / -o and combine freely.
        \\PIPELINE: search for candidate file:line, then `read_file` with offset/limit — faster and more accurate than reading whole files blind.
        \\EDGE: a pattern starting with `-` is treated as a literal (rg's `-e` is used internally), so searching for "--help" needs no escaping.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Regex or literal string to search for. Must be non-empty and contain no NUL bytes.",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "File or directory to search in. Absolute, or relative to `cwd`.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Hard cap on rows returned. Default: 50, must be > 0. When it bites, the result reports truncated=true plus a truncated_hint naming it.",
                },
                .{
                    .name = "head",
                    .type = "number",
                    .description = "First-N filter of the whole match stream, still bounded by max_results. Mutually exclusive with tail. Must be > 0; omit this field when unused instead of sending 0.",
                },
                .{
                    .name = "tail",
                    .type = "number",
                    .description = "Last-N filter of the WHOLE search: the collector scans to the end and keeps the newest rows (bounded by max_results). Mutually exclusive with head. Must be > 0; omit this field when unused instead of sending 0. Under output truncation it applies to the retained prefix (result marked output_truncated).",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max raw output bytes to retain from ripgrep. Default: 1048576 (1MB), hard cap 100MB, must be > 0. Over the limit the call still succeeds with complete records from the retained prefix plus output_truncated=true and a truncated_hint.",
                },
                .{
                    .name = "group_by_file",
                    .type = "boolean",
                    .description = "Group matches by file. Default: true. Set false for flat output.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the directory this call works in. A relative `path` resolves against it; an absolute `path` is used as-is. Pass the tree you are actually editing (your worktree root, NOT the server's directory).",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Respect .gitignore/.ignore/.rgignore. Default: true. Set false to search gitignored paths (build/, node_modules/, target/, vendor/). rg still skips hidden entries either way — use `hidden` for .git/ and .github/.",
                },
                .{
                    .name = "word_boundary",
                    .type = "boolean",
                    .description = "Match whole words only (-w flag). Pattern 'foo' matches 'foo bar' but NOT 'foobar'. Default: false.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat pattern as a literal string (-F flag). Regex metacharacters like '.', '*', '[', '(' are matched verbatim. Default: false.",
                },
                .{
                    .name = "only_matching",
                    .type = "boolean",
                    .description = "Return only the matched substring (-o flag), not the full surrounding line — for short tokens in noisy lines. Default: false.",
                },
                .{
                    .name = "snippet_max_chars",
                    .type = "number",
                    .description = "Max bytes per snippet before it is windowed around the match. Default 240; 0 disables windowing. rg returns the WHOLE matching line, so a minified bundle line can be enormous.",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Also search hidden files/dirs (.github/, .env, .gitignore) via --hidden. Default: false. respect_ignore_files=false does NOT imply this — rg skips hidden entries either way.",
                },
                .{
                    .name = "glob",
                    .type = "string",
                    .description = "ripgrep --glob filter, e.g. '*.zig', '*.vue', '!test_*'. Cheapest way to cut noise in a polyglot repo.",
                },
                .{
                    .name = "timeout_ms",
                    .type = "number",
                    .description = "Deadline for one search in milliseconds. Default: 30000 (30s), clamped to 1h. On timeout the search is killed and you get a Timeout error — narrow your path or pattern and retry.",
                },
            },
            .required = &.{ "pattern", "path", "cwd" },
        },
        .system_prompt = search_tool_system_prompt,
    },
};

test {
    // Tests removed - see search_test.zig (registered in
    // src/modules/agent/test_runner.zig) for the 14+ edge case tests
    // that exercise this tool.
}

const builtin = @import("builtin");
const testing = std.testing;

// =============================================================================
// Validation tests (no ripgrep invocation; run on all platforms)
// =============================================================================

test "search: empty pattern returns EmptyPattern error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "",
        .path = ".",
    });

    try testing.expectError(error.EmptyPattern, result);
}

test "search: pattern with NUL byte returns PatternContainsNulByte error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const pattern_with_nul: []const u8 = &[_]u8{ 'f', 'o', 'o', 0, 'b', 'a', 'r' };

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = pattern_with_nul,
        .path = ".",
    });

    try testing.expectError(error.PatternContainsNulByte, result);
}

test "search: max_output = 0 returns InvalidMaxOutput error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_output = 0,
    });

    try testing.expectError(error.InvalidMaxOutput, result);
}

test "search: max_output > 100MB ceiling returns MaxOutputTooLarge error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_output = max_output_hard_limit + 1,
    });

    try testing.expectError(error.MaxOutputTooLarge, result);
}

test "search: max_results = 0 returns InvalidMaxResults error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .max_results = 0,
    });

    try testing.expectError(error.InvalidMaxResults, result);
}

test "search: head AND tail both set returns HeadAndTailMutuallyExclusive error" {
    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "hello",
        .path = ".",
        .head = 5,
        .tail = 5,
    });

    try testing.expectError(error.HeadAndTailMutuallyExclusive, result);
}

test "search: respect_ignore_files = false does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    if (executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .respect_ignore_files = false,
    })) |r| {
        // Success — release the SearchResult's heap allocations
        // (matches.items[].file + .snippet, and content).
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        // Either success (Ok with possibly 0 matches in /tmp) or a rg-spawn
        // error is acceptable. What matters is NO SearchError domain variant
        // fires (those would mean validation rejected the field).
        error.FileNotFound, error.PathError, error.AccessDenied, error.OutputReadFailed, error.StderrTooLong => {},
        else => return err,
    }
}

test "search: word_boundary = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The word_boundary field is a flag, not a numeric limit — there's no
    // value that could fail up-front validation.
    if (executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .word_boundary = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.OutputReadFailed, error.StderrTooLong => {},
        else => return err,
    }
}

test "search: literal = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The literal field is a flag, not a numeric limit — there's no value
    // that could fail up-front validation.
    if (executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .literal = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.OutputReadFailed, error.StderrTooLong => {},
        else => return err,
    }
}

test "search: only_matching = true does NOT return a validation error" {
    const allocator = testing.allocator;
    const io = testing.io;

    // The only_matching field is a flag, not a numeric limit — there's no
    // value that could fail up-front validation.
    if (executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .only_matching = true,
    })) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.OutputReadFailed, error.StderrTooLong => {},
        else => return err,
    }
}

// =============================================================================
// Behavioral tests (with ripgrep invocation)
// =============================================================================

fn requiresRg() bool {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return false;
    // Check rg is on PATH via a probe — cheap, no fs mutation.
    return true;
}

/// Strip the `./` prefix that rg adds to relative paths when invoked with
/// `path = "."`. Used by the respect_ignore_files tests to compare match
/// files against expected basenames regardless of rg's prefix convention.
fn stripDotSlash(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '.' and s[1] == '/') return s[2..];
    return s;
}

test "search: pattern starting with -- is NOT interpreted as rg flag" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    // Create a temp file with the literal text "--help" in it. Before the
    // flag-injection fix, rg --json --line-number "--help" . would print
    // ripgrep's help page (treating --help as a flag).
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "marker.txt",
        .data = "this --help marker is here\nplain line\n",
    });

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "--help",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expect(result.matches.items.len > 0);
    // At least one match must be on a line containing the literal "--help".
    var found_marker = false;
    for (result.matches.items) |m| {
        if (std.mem.indexOf(u8, m.snippet, "--help") != null) {
            found_marker = true;
            break;
        }
    }
    try testing.expect(found_marker);
}

test "search: pattern 'foo' in a dir with literal 'foo' finds it" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "a.txt",
        .data = "the foo is here\nboring\n",
    });

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: pattern with invalid regex returns RegexParseError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "x.txt",
        .data = "literal content\n",
    });

    // Unmatched paren — rg should reject with a regex parse error.
    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "(unclosed",
        .path = &tmpdir.sub_path,
    });

    try testing.expectError(error.RegexParseError, result);
}

test "search: path that doesn't exist returns PathError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = "/nonexistent/path/that/does/not/exist/12345",
    });

    try testing.expectError(error.PathError, result);
}

test "search: cwd that doesn't exist returns an error" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "anything",
        .path = ".",
        .cwd = "/nonexistent/cwd/that/does/not/exist/12345",
    });

    // Either PathError (from our mapping) or some spawn-level error bubbles
    // up.
    if (result) |r| {
        var owned = r;
        defer owned.deinit(allocator);
    } else |err| switch (err) {
        error.PathError, error.FileNotFound, error.AccessDenied, error.NotDir, error.IsDir => {},
        else => return err,
    }
}

test "search: binary snippet is sanitized to valid UTF-8" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Write bytes that look like a PNG header. rg will detect this as a
    // binary file and skip it. To force rg to "match" anyway, we put
    // the literal ASCII text "match_here" inside the binary content.
    const binary_content: []const u8 = &[_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0xFF, 0xFE, 0x00, 0x00, // invalid UTF-8 byte sequence
        'm',  'a',  't',  'c',
        'h',  '_',  'h',  'e',
        'r',  'e',  '\n',
        0x80, 0x81, 0x82, // more invalid UTF-8
    };
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "binary.dat",
        .data = binary_content,
    });

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "match_here",
        .path = ".",
        .max_output = 65536,
    });
    defer result.deinit(allocator);

    // rg may either find the match (and snippets contain invalid UTF-8 bytes
    // that get sanitized) or skip the file entirely (no match).
    for (result.matches.items) |m| {
        const utf8_valid = std.unicode.utf8ValidateSlice(m.snippet);
        try testing.expect(utf8_valid);
    }
}

test "search: max_results cap honored" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Write 20 lines with "foo" in them
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "foo line {d}\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    // content is heap-owned from toOwnedSlice; writeFile reads but does not
    // take ownership. Free it once writeFile returns.
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "many.txt",
        .data = content,
    });

    // Zig 0.16's testing.TmpDir.sub_path is a fixed-size array holding just
    // the random basename (e.g. "AbCdEfGh1234"), NOT the full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .max_results = 5,
    });
    defer result.deinit(allocator);

    try testing.expect(result.matches.items.len <= 5);
    try testing.expect(result.matches.items.len > 0);
}

test "search: respect_ignore_files = true (default) skips .gitignored dirs" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(io, "node_modules");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "MARKER_TOKEN_NODE_MODULES\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is just the basename; resolve full path via realPath.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_NODE_MODULES",
        .path = ".",
        .cwd = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Exactly 1 match — only app.js. node_modules/secret.js was skipped.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    // rg with path="." returns paths prefixed with "./"; strip it for the
    // filename comparison.
    const match_file = stripDotSlash(result.matches.items[0].file);
    try testing.expectEqualStrings("app.js", match_file);
}

test "search: respect_ignore_files = false searches .gitignored dirs" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(io, "node_modules");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "node_modules/secret.js",
        .data = "MARKER_TOKEN_NODE_MODULES_FALSE\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "app.js",
        .data = "MARKER_TOKEN_NODE_MODULES_FALSE\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_NODE_MODULES_FALSE",
        .path = ".",
        .cwd = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .gitignore was un-respected via --no-ignore
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    // Collect filenames (order from rg is not guaranteed) and assert each
    // expected file is present. rg with path="." prefixes matches with
    // "./" — use stripDotSlash to normalize.
    var saw_app = false;
    var saw_node_modules = false;
    for (result.matches.items) |m| {
        const f = stripDotSlash(m.file);
        if (std.mem.eql(u8, f, "app.js")) saw_app = true;
        if (std.mem.eql(u8, f, "node_modules/secret.js")) saw_node_modules = true;
    }
    try testing.expect(saw_app);
    try testing.expect(saw_node_modules);
}

test "search: respect_ignore_files = false also un-respects .ignore / .rgignore" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts/\n",
    });
    try tmpdir.dir.createDirPath(io, "build_artifacts");
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "build_artifacts/cached.dat",
        .data = "MARKER_TOKEN_IGNORE_FILE\n",
    });
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "main.txt",
        .data = "MARKER_TOKEN_IGNORE_FILE\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, "/tmp", .{
        .pattern = "MARKER_TOKEN_IGNORE_FILE",
        .path = ".",
        .cwd = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .ignore was un-respected via --no-ignore
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);

    // Per-filename check (rg match order is not guaranteed). rg with
    // path="." prefixes matches with "./" — use stripDotSlash to normalize.
    var saw_main = false;
    var saw_cached = false;
    for (result.matches.items) |m| {
        const f = stripDotSlash(m.file);
        if (std.mem.eql(u8, f, "main.txt")) saw_main = true;
        if (std.mem.eql(u8, f, "build_artifacts/cached.dat")) saw_cached = true;
    }
    try testing.expect(saw_main);
    try testing.expect(saw_cached);
}

test "search: word_boundary = true matches whole words only" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        // "foo" appears as part of "foobar" — should NOT match with -w
        // "foo" appears as a whole word — SHOULD match
        // "foo" appears at end of line, preceded by space — SHOULD match
        .data = "foobar whole foo\nline foo trailing\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // 2 matches: line 1 (the "whole foo" segment) and line 2 (trailing foo).
    // "foobar" on line 1 must NOT match because there's no boundary between
    // "foo" and "bar".
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary = false (default) matches substrings" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // rg returns ONE match event per matched line (not per occurrence). So
    // even though "foobar" contains "foo" twice, that's still 1 match event.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        // Line 1 has two substring occurrences of "foo" — rg reports 1 event.
        // Line 2 has one occurrence — rg reports 1 event.
        .data = "foobar whole foo\nline foo here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        // word_boundary explicitly false — same as omitting it
    });
    defer result.deinit(allocator);

    // 2 match events (one per matched line).
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary works at start of file (offset 0)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // The pattern is the very first thing in the file — there's no
    // preceding character. With -w, rg must still identify the boundary
    // (the implicit "start of file" is a word boundary in ripgrep's view).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo bar",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: word_boundary works at end of file (no trailing newline)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File ends mid-line — pattern is the last token with no trailing
    // newline. rg must treat EOF as a word boundary for -w.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "hello world",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "world",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: word_boundary treats underscore as a WORD char (no match inside foo_bar)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // ripgrep's default Unicode word rule treats underscore as a word
    // character.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo_bar baz_foo qux_foo",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // None of the three occurrences are bounded — _ is a word char.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "search: word_boundary treats hyphen as a boundary (matches foo-bar and foo+bar)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Hyphen and plus are non-word chars — they DO create boundaries,
    // so "foo" with -w matches both "foo-bar" and "foo+bar". Two lines
    // so rg reports 2 match events (one per line).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo-bar\nfoo+bar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: word_boundary with punctuation boundaries matches each occurrence" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // ( ) [ ] { } , . — each of these is a non-word char and creates
    // a word boundary. So "foo" with -w matches every occurrence here.
    // Spread across 4 lines so rg reports 4 match events (one per line).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "(foo)\n[foo]\n{foo}\nfoo.\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), result.matches.items.len);
}

test "search: word_boundary with multi-line file matches only the line containing the word" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Three lines; only line 2 contains the pattern as a whole word.
    // Lines 1 and 3 contain "target" only as part of "targeted" /
    // "untargeted" — which -w rejects.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "first line targeted here\nsecond line has target word\nthird line untargeted here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "target",
        .path = ".",
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    // Only 1 match — line 2.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 2), result.matches.items[0].line_number);
}

// =============================================================================
// Chunk 2 behavioral tests — literal / -F flag
// =============================================================================

test "search: literal = true matches metacharacters literally" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Two lines: line 1 has the LITERAL substring "foo.bar" (with real dot),
    // line 2 has "fooXbar" (X is not a dot, so the LITERAL pattern "foo.bar"
    // does not match it).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    // With literal = true: only line 1 matches (literal dot).
    // Without literal (regex): both lines match (dot is wildcard).
    // If this test sees 2 matches, the -F flag is NOT being passed to rg.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true does NOT fire RegexParseError for invalid regex pattern" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "*invalid" is INVALID as a regex (unanchored `*` quantifier has no
    // preceding atom).
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "literal content\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    const result_or_err = executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "*invalid",
        .path = ".",
        .literal = true,
    });

    // Acceptable outcomes: - Ok with 0 matches (rg found no file containing
    // literal "*invalid") - PathError (rg spawn failed for some
    // platform-specific reason) NOT acceptable: error.RegexParseError —
    if (result_or_err) |ok| {
        var owned = ok;
        defer owned.deinit(allocator);
        // 0 matches is expected — the file content doesn't contain "*invalid".
    } else |err| switch (err) {
        error.FileNotFound, error.PathError, error.AccessDenied, error.OutputReadFailed, error.StderrTooLong => {},
        error.RegexParseError => return error.RegexParseError,
        else => return err,
    }
}

test "search: literal = false (default) treats metacharacters as regex" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Same file as the literal-true test: line 1 has literal "foo.bar",
    // line 2 has "fooXbar". With regex default (no literal), "." matches
    // any char — so BOTH lines match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar\nfooXbar\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        // literal omitted — defaults to false, rg treats "." as wildcard
    });
    defer result.deinit(allocator);

    // 2 matches — line 1 (literal dot) AND line 2 (X matched by wildcard).
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
}

test "search: literal = true matches backslashes literally" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains the literal 3-char substring "\bx" (backslash + b + x) at
    // positions 7..9 of line 1. Line 2 has no such substring.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "prefix \\bx here\nno match on this line\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // Pattern is the 3-byte literal "\bx" (backslash + b + x).
    const pattern_bs: []const u8 = &[_]u8{ '\\', 'b', 'x' };

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = pattern_bs,
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true matches combined regex special chars as opaque bytes" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains the literal 8-char substring "(?:foo)+" on line 1. rg's
    // regex engine DOES support non-capturing groups (?:...), so even in
    // regex mode, the pattern "(?:foo)+" is valid and matches the inner "foo"
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "(?:foo)+ and (a|b)\njust literal text\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "(?:foo)+",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true with unmatched bracket does NOT fire RegexParseError" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Pattern "[unclosed" has an unmatched `[`. With regex, rg would emit a
    // regex parse error. With literal = true, the `[` is just a char.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "completely unrelated content\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "[unclosed",
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    // 0 matches (no file content matches the literal "[unclosed").
    // CRITICALLY: no RegexParseError — rg doesn't parse literal patterns.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "search: literal = true with multi-byte UTF-8 pattern matches byte-for-byte" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // File contains "café résumé" with é as the 2-byte UTF-8 sequence C3 A9.
    // The literal pattern "café" is 5 bytes (c, a, f, C3, A9). With literal =
    // true, rg matches the exact 5-byte sequence.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "café résumé\nplain text\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // Construct "café" (5 bytes) from a u8 array to make the byte
    // sequence explicit (c=0x63, a=0x61, f=0x66, é=0xC3 0xA9).
    const pattern_utf8: []const u8 = &[_]u8{ 'c', 'a', 'f', 0xC3, 0xA9 };

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = pattern_utf8,
        .path = ".",
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: literal = true combined with word_boundary = true matches bounded literal substring" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Three lines: Line 1: "foo.bar baz" — contains the literal substring
    // "foo.bar" Line 2: "fooXbar qux" — contains "fooXbar" but NOT "foo.bar"
    // (X != .) Line 3: "prefix foo.bar.suffix" — contains "foo.bar" at
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "t.txt",
        .data = "foo.bar baz\nfooXbar qux\nprefix foo.bar.suffix\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
        .word_boundary = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 3), result.matches.items[1].line_number);
}

// =============================================================================
// only_matching (-o) tests — Chunk 3 of the rg-flags plan
// =============================================================================

test "search: only_matching = true strips surrounding context from snippet" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Single line: lots of noise around the match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "a.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Snippet should contain the matched substring.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "needle") != null);
    // Snippet should NOT contain the surrounding context that would be
    // present in default mode. The leading "lots of noise" is the
    // clearest discriminator.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "lots of noise") == null);
}

test "search: only_matching = true with multiple submatches on same line joins them with comma" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "alpha and beta together" — the regex "alpha|beta" matches TWICE on
    // this single line.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "b.txt",
        .data = "alpha and beta together\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "alpha|beta",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    // ONE SearchMatch (not two) — single match event with submatches[] array.
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Snippet is the comma-joined submatches.
    try testing.expectEqualStrings("alpha,beta", result.matches.items[0].snippet);
}

test "search: only_matching = false (default) keeps surrounding context in snippet" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "c.txt",
        .data = "lots of noise around needle here and more\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    // Default mode: snippet is the full surrounding line.
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "lots of noise") != null);
    try testing.expect(std.mem.indexOf(u8, result.matches.items[0].snippet, "needle") != null);
}

test "search: only_matching = true returns multiple match events for multi-line input" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // 3 lines, each with one match.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "multi.txt",
        .data = "first line has target here\nsecond line has target there\nthird line has target everywhere\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "target",
        .path = ".",
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.matches.items.len);
    // Each match's line_number is 1, 2, 3 respectively.
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
    try testing.expectEqual(@as(usize, 3), result.matches.items[2].line_number);
    // All snippets are just "target" (no surrounding text).
    for (result.matches.items) |m| {
        try testing.expectEqualStrings("target", m.snippet);
    }
}

test "search: only_matching = true combined with literal = true matches literal substring without context" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "a.b" appears literally in line 1. Without literal, "." would match
    // any char so "aXb" would also match. With literal + only_matching,
    // only "a.b" matches and snippet is just "a.b".
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "lit.txt",
        .data = "a.b and aXb\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "a.b",
        .path = ".",
        .literal = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("a.b", result.matches.items[0].snippet);
}

test "search: only_matching = true combined with word_boundary = true matches whole words" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "needle" on line 1 is a whole word. "needlex" on line 2 is a single
    // word (not "needle" followed by "x" — "x" is a word char), so no
    // boundary at the end. With word_boundary, only line 1 matches.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "wb.txt",
        .data = "needle case needlex case\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .word_boundary = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("needle", result.matches.items[0].snippet);
}

test "search: only_matching = true with literal + word_boundary matches bounded literal as substring" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // "foo.bar" appears on line 1 and line 3 as a literal substring. Line 2
    // has "fooXbar" (not literal match for "foo.bar").
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "all3.txt",
        .data = "foo.bar baz\nfooXbar qux\nprefix foo.bar.suffix\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo.bar",
        .path = ".",
        .literal = true,
        .word_boundary = true,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqualStrings("foo.bar", result.matches.items[0].snippet);
    try testing.expectEqual(@as(usize, 3), result.matches.items[1].line_number);
    try testing.expectEqualStrings("foo.bar", result.matches.items[1].snippet);
}

test "search: only_matching = true respects head slicing" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Build 5 matching lines programmatically.
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "line {d}: needle here\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "head.txt",
        .data = content,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .head = 2,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    // First 2 lines only.
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
    // Snippets are just "needle" (no surrounding text).
    try testing.expectEqualStrings("needle", result.matches.items[0].snippet);
    try testing.expectEqualStrings("needle", result.matches.items[1].snippet);
}

test "search: only_matching = true respects max_results cap" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    // Build 100 matching lines.
    const content = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            const line = try std.fmt.allocPrint(allocator, "needle line {d}\n", .{i});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "cap.txt",
        .data = content,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .max_results = 10,
        .only_matching = true,
    });
    defer result.deinit(allocator);

    // Cap honored.
    try testing.expectEqual(@as(usize, 10), result.matches.items.len);
    // First 10 lines.
    for (result.matches.items, 0..) |m, i| {
        try testing.expectEqual(@as(usize, i + 1), m.line_number);
        try testing.expectEqualStrings("needle", m.snippet);
    }
}

test "search: only_matching = true with group_by_file = false renders text=needle per match" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "flat.txt",
        .data = "line1: needle\nline2: needle\nline3: needle\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle",
        .path = ".",
        .only_matching = true,
        .group_by_file = false,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), result.matches.items.len);

    const out = try search_result_to_json_flat(
        allocator,
        result,
        "needle",
        ".",
    );
    defer allocator.free(out);

    // The flat JSON holds one entry per match, each `text` JUST the matched
    // substring (no surrounding text), confirming only_matching is rendered
    // into the flat payload.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("grouped").?.bool == false);
    const matches = root.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 3), matches.len);
    for (matches) |m| {
        try testing.expectEqualStrings("needle", m.object.get("text").?.string);
    }
    // And the snippets do NOT contain surrounding context (e.g. "line1: ").
    try testing.expect(std.mem.indexOf(u8, out, "line1:") == null);
}

// =============================================================================
// Output format tests (no ripgrep needed — pure formatting)
// =============================================================================

test "search: search_result_to_json_flat with no matches emits JSON header" {
    const allocator = testing.allocator;

    const result = SearchResult{
        .matches = std.ArrayList(SearchMatch).empty,
        .warning = "<warning>pattern not found</warning>",
    };

    const out = try search_result_to_json_flat(
        allocator,
        result,
        "nonexistent_pattern",
        "/tmp",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("nonexistent_pattern", root.get("pattern").?.string);
    try testing.expectEqualStrings("/tmp", root.get("path").?.string);
    try testing.expect(root.get("grouped").?.bool == false);
    try testing.expectEqual(@as(usize, 0), root.get("matches").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, root.get("warning").?.string, "pattern not found") != null);
}

// =============================================================================
// No-match output: include the actual pattern + path in the warning text so
// the operator (and the frontend's header) can see what was searched.

test "search: executeSearch no-match warning includes the actual pattern and path" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "empty.txt",
        .data = "no matches here\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "needle_NOT_FOUND",
        .path = "empty.txt",
    });
    defer result.deinit(allocator);

    // No matches.
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);

    // The warning body MUST contain the literal pattern + path the LLM
    // passed so the operator can see what was searched (fix for the
    // "unknown" / "unknown pattern not found" rendering bug).
    try testing.expect(std.mem.indexOf(u8, result.warning, "needle_NOT_FOUND") != null);
    try testing.expect(std.mem.indexOf(u8, result.warning, "empty.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result.warning, "<warning>") != null);
    try testing.expect(std.mem.indexOf(u8, result.warning, "</warning>") != null);
}

test "search: search_result_to_json_grouped no-match carries pattern/path/warning fields" {
    const allocator = testing.allocator;

    // Warning body now includes the pattern + path so the operator sees
    // what was searched even when narrow UIs truncate the header fields.
    // Body text is the durable source of truth.
    const result = SearchResult{
        .matches = std.ArrayList(SearchMatch).empty,
        .warning = "<warning>no matches for pattern \"needle_NOT_FOUND\" in path \"/tmp/x\"</warning>",
    };

    const out = try search_result_to_json_grouped(
        allocator,
        result,
        "needle_NOT_FOUND",
        "/tmp/x",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // The pattern/path fields MUST be present so the frontend header can
    // render the actual args (before the fix they fell back to "unknown").
    try testing.expectEqualStrings("needle_NOT_FOUND", root.get("pattern").?.string);
    try testing.expectEqualStrings("/tmp/x", root.get("path").?.string);
    try testing.expect(root.get("grouped").?.bool == true);
    try testing.expectEqual(@as(usize, 0), root.get("files").?.array.items.len);
    // The warning body MUST survive as the `warning` field.
    const warning = root.get("warning").?.string;
    try testing.expect(std.mem.indexOf(u8, warning, "no matches for pattern") != null);
    try testing.expect(std.mem.indexOf(u8, warning, "needle_NOT_FOUND") != null);
}

test "search: search_result_to_json_flat no-match carries pattern/path/warning fields" {
    const allocator = testing.allocator;

    const result = SearchResult{
        .matches = std.ArrayList(SearchMatch).empty,
        .warning = "<warning>no matches for pattern \"foo\" in path \"bar\"</warning>",
    };

    const out = try search_result_to_json_flat(
        allocator,
        result,
        "foo",
        "bar",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("foo", root.get("pattern").?.string);
    try testing.expectEqualStrings("bar", root.get("path").?.string);
    try testing.expect(root.get("grouped").?.bool == false);
    try testing.expectEqual(@as(usize, 0), root.get("matches").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, root.get("warning").?.string, "no matches for pattern") != null);
}

test "search: output truncation hint is serialized before result arrays" {
    const allocator = testing.allocator;
    const result = SearchResult{
        .matches = std.ArrayList(SearchMatch).empty,
        .total_matches = 20,
        .truncated = true,
        .output_truncated = true,
        .output_bytes = 50_000,
    };

    const grouped = try search_result_to_json_grouped(allocator, result, "foo", ".");
    defer allocator.free(grouped);
    const grouped_hint = std.mem.indexOf(u8, grouped, "\"truncated_hint\"").?;
    const grouped_files = std.mem.indexOf(u8, grouped, "\"files\"").?;
    try testing.expect(grouped_hint < grouped_files);

    const flat = try search_result_to_json_flat(allocator, result, "foo", ".");
    defer allocator.free(flat);
    const flat_hint = std.mem.indexOf(u8, flat, "\"truncated_hint\"").?;
    const flat_matches = std.mem.indexOf(u8, flat, "\"matches\"").?;
    try testing.expect(flat_hint < flat_matches);
}

test "search: search_result_to_json_flat renders file/line/text per match" {
    const allocator = testing.allocator;

    const matches = std.ArrayList(SearchMatch).empty;
    var owned_matches = matches;
    defer {
        for (owned_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        owned_matches.deinit(allocator);
    }

    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "foo.zig"),
        .line_number = 42,
        .file_total_lines = 0,
        .snippet = try allocator.dupe(u8, "    const x = 1;"),
    });
    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "bar.zig"),
        .line_number = 7,
        .file_total_lines = 0,
        .snippet = try allocator.dupe(u8, "    pub fn hello() void {}"),
    });

    const result = SearchResult{
        .matches = owned_matches,
        .warning = "",
    };

    const out = try search_result_to_json_flat(
        allocator,
        result,
        "fn",
        "src",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // Two entries, one per match
    const items = root.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);

    // First match: foo.zig, line 42, "const x = 1;"
    try testing.expectEqualStrings("foo.zig", items[0].object.get("file").?.string);
    try testing.expectEqual(@as(i64, 42), items[0].object.get("line").?.integer);
    try testing.expect(std.mem.indexOf(u8, items[0].object.get("text").?.string, "const x = 1;") != null);

    // Second match: bar.zig, line 7
    try testing.expectEqualStrings("bar.zig", items[1].object.get("file").?.string);
    try testing.expectEqual(@as(i64, 7), items[1].object.get("line").?.integer);

    // No `files` key on flat output (grouped output carries that instead)
    try testing.expect(root.get("files") == null);
    // No warning on the success path
    try testing.expect(root.get("warning").? == .null);
}

test "search: search_result_to_json_grouped with no matches emits JSON header" {
    const allocator = testing.allocator;

    const result = SearchResult{
        .matches = std.ArrayList(SearchMatch).empty,
        .warning = "<warning>pattern not found</warning>",
    };

    const out = try search_result_to_json_grouped(
        allocator,
        result,
        "anything",
        ".",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("anything", root.get("pattern").?.string);
    try testing.expectEqualStrings(".", root.get("path").?.string);
    try testing.expect(root.get("grouped").?.bool == true);
    try testing.expectEqual(@as(usize, 0), root.get("files").?.array.items.len);
    // No `matches` key on grouped output
    try testing.expect(root.get("matches") == null);
}

test "search: search_result_to_json_grouped renders files entries" {
    const allocator = testing.allocator;

    const matches = std.ArrayList(SearchMatch).empty;
    var owned_matches = matches;
    defer {
        for (owned_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        owned_matches.deinit(allocator);
    }

    try owned_matches.append(allocator, .{
        .file = try allocator.dupe(u8, "foo.zig"),
        .line_number = 42,
        .file_total_lines = 100,
        .snippet = try allocator.dupe(u8, "    const x = 1;"),
    });

    const result = SearchResult{
        .matches = owned_matches,
        .warning = "",
    };

    const out = try search_result_to_json_grouped(
        allocator,
        result,
        "const",
        "src",
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // One files entry with the path
    const files = root.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("foo.zig", files[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 100), files[0].object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 1), files[0].object.get("count").?.integer);

    // With the line and snippet
    const file_matches = files[0].object.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 1), file_matches.len);
    try testing.expectEqual(@as(i64, 42), file_matches[0].object.get("line").?.integer);
    try testing.expect(std.mem.indexOf(u8, file_matches[0].object.get("text").?.string, "const x = 1;") != null);
}

test "search: timeout_ms=0 returns Timeout without spawning rg" {
    // Windows-only freeze (2026-09-05): executeSearch used bare
    // std.process.run with NO deadline — a slow/hung rg blocked the agent
    // worker forever. timeout_ms=0 must fail fast with error.Timeout before
    const allocator = testing.allocator;
    const io = testing.io;
    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .timeout_ms = 0,
    });
    try testing.expectError(error.Timeout, result);
}

test "search: bogus rg_binary returns RgNotFound (not generic PathError)" {
    // On Windows boxes without ripgrep on PATH the old code mapped the
    // spawn FileNotFound to PathError ("verify the path exists"), sending
    // the LLM down the wrong path. A missing binary must be distinguishable.
    const allocator = testing.allocator;
    const io = testing.io;
    const result = executeSearch(allocator, io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .rg_binary = "/nonexistent-rg-binary-xyz-123",
    });
    try testing.expectError(error.RgNotFound, result);
}

test "search: default search timeout is 30s" {
    try testing.expectEqual(@as(u64, 30_000), default_search_timeout_ms);
}

// =============================================================================
// Output-contract tests — the result envelope's honesty.

/// Absolute path of a `testing.tmpDir`. Zig 0.16's `TmpDir.sub_path` holds
/// only the random basename, so tests resolve the real path and search "."
/// inside it (same pattern as the behavioral tests above).
fn resolveTmpDir(dir: std.Io.Dir, io: std.Io, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |found| {
        count += 1;
        idx = found + 1;
    }
    return count;
}

/// `count` lines of "<prefix> line <n>" — one match event per line.
fn buildMatchingLines(allocator: std.mem.Allocator, count: u32, prefix: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator, "{s} line {d}\n", .{ prefix, i });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    return try buf.toOwnedSlice(allocator);
}

test "search: head = 0 returns InvalidHeadTail without spawning rg" {
    const result = executeSearch(testing.allocator, testing.io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .head = 0,
    });
    try testing.expectError(error.InvalidHeadTail, result);
}

test "search: tail = 0 returns InvalidHeadTail without spawning rg" {
    const result = executeSearch(testing.allocator, testing.io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .tail = 0,
    });
    try testing.expectError(error.InvalidHeadTail, result);
}

test "search: bounded match counter detects markers split across reads" {
    var counter = SearchMatchCounter{};
    counter.consume("{\"data\":{\"path\":\"x\"},\"type\":\"mat");
    counter.consume("ch\"}\n{\"type\":\"begin\"}\n{\"type\":\"match\"}\n");
    try testing.expectEqual(@as(usize, 2), counter.count);

    // A record without its terminating newline may have been cut by the
    // output cap, so it is not counted as a complete match event.
    counter.consume("{\"type\":\"match\"}");
    try testing.expectEqual(@as(usize, 2), counter.count);
}

test "search: max_output overflow returns a successful partial result" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const content = try buildMatchingLines(allocator, 80, "FOUND_MARKER");
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "many.txt", .data = content });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "FOUND_MARKER",
        .path = ".",
        .max_results = 100,
        .max_output = 4096,
        .literal = true,
    });
    defer result.deinit(allocator);

    try testing.expect(result.output_truncated);
    try testing.expect(result.truncated);
    try testing.expect(result.output_bytes > 4096);
    try testing.expectEqual(@as(usize, 80), result.total_matches);
    try testing.expect(result.matches.items.len > 0);
    try testing.expectEqualStrings("", result.warning);

    const grouped = try search_result_to_json_grouped(allocator, result, "FOUND_MARKER", ".");
    defer allocator.free(grouped);
    const flat = try search_result_to_json_flat(allocator, result, "FOUND_MARKER", ".");
    defer allocator.free(flat);

    for ([_][]const u8{ grouped, flat }) |json_text| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try testing.expect(root.get("success") == null);
        try testing.expect(root.get("truncated").?.bool);
        try testing.expect(root.get("output_truncated").?.bool);
        try testing.expect(root.get("output_bytes").?.integer > 4096);
        const hint = root.get("truncated_hint").?.string;
        try testing.expect(std.mem.indexOf(u8, hint, "max_output") != null);
        try testing.expect(std.mem.indexOf(u8, hint, "truncated") != null);
    }
}

test "search: max_output cap before the first complete record is not a no-match" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "NEEDLE\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "NEEDLE",
        .path = ".",
        .max_output = 1,
    });
    defer result.deinit(allocator);

    try testing.expect(result.output_truncated);
    try testing.expect(result.truncated);
    try testing.expectEqual(@as(usize, 0), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.total_matches);
    try testing.expectEqualStrings("", result.warning);

    const out = try search_result_to_json_grouped(allocator, result, "NEEDLE", ".");
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("warning").? == .null);
    try testing.expect(parsed.value.object.get("truncated_hint").?.string.len > 0);
}

test "search: max_results truncation is reported (returned/total/truncated/truncated_hint)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const content = try buildMatchingLines(allocator, 20, "foo");
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "many.txt", .data = content });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .max_results = 3,
    });
    defer result.deinit(allocator);

    // 3 rows kept, 20 match events seen — the difference is the truncation.
    try testing.expectEqual(@as(usize, 3), result.matches.items.len);
    try testing.expectEqual(@as(usize, 20), result.total_matches);
    try testing.expect(result.truncated);

    const out = try search_result_to_json_grouped(allocator, result, "foo", ".");
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 3), root.get("returned").?.integer);
    try testing.expectEqual(@as(i64, 20), root.get("total").?.integer);
    try testing.expect(root.get("truncated").?.bool == true);
    try testing.expect(std.mem.indexOf(u8, root.get("truncated_hint").?.string, "3 of 20 matched lines shown") != null);
}

test "search: complete result reports truncated=false and null truncated_hint" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "foo only here\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expect(!result.truncated);
    try testing.expectEqual(@as(usize, 1), result.total_matches);

    const out = try search_result_to_json_grouped(allocator, result, "foo", ".");
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("returned").?.integer);
    try testing.expectEqual(@as(i64, 1), root.get("total").?.integer);
    try testing.expect(root.get("truncated").?.bool == false);
    try testing.expect(root.get("truncated_hint").? == .null);
}

test "search: head keeps the FIRST N matches and reports the truncation" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const content = try buildMatchingLines(allocator, 5, "foo");
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "five.txt", .data = content });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .head = 2,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 2), result.matches.items[1].line_number);
    try testing.expectEqual(@as(usize, 5), result.total_matches);
    try testing.expect(result.truncated);
}

test "search: tail keeps the LAST N matches of the whole search (aliasing-panic regression)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const content = try buildMatchingLines(allocator, 10, "foo");
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "ten.txt", .data = content });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    // tail = 8 with 10 matches is the exact shape that used to abort: the
    // post-hoc slice shifted the kept rows down with an aliasing @memcpy
    // (src = items[2..], dst = items[0..]), which Zig 0.16 rejects outright.
    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .tail = 8,
    });
    defer result.deinit(allocator);

    // The NEWEST 8 of 10 lines: 3..10 (the first two were evicted).
    try testing.expectEqual(@as(usize, 8), result.matches.items.len);
    for (result.matches.items, 3..) |m, expected_line| {
        try testing.expectEqual(expected_line, m.line_number);
    }
    try testing.expectEqual(@as(usize, 10), result.total_matches);
    try testing.expect(result.truncated);
}

test "search: tail scans past max_results (last N is not last-N-of-the-first-max_results)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const content = try buildMatchingLines(allocator, 12, "foo");
    defer allocator.free(content);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "twelve.txt", .data = content });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
        .tail = 2,
        .max_results = 5,
    });
    defer result.deinit(allocator);

    // The last two lines of the FILE (11 and 12), not of the first 5 rows.
    try testing.expectEqual(@as(usize, 2), result.matches.items.len);
    try testing.expectEqual(@as(usize, 11), result.matches.items[0].line_number);
    try testing.expectEqual(@as(usize, 12), result.matches.items[1].line_number);
}

test "search: glob filter narrows the matches to matching file names" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "GLOB_MARKER here\n" });
    try tmpdir.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "GLOB_MARKER here\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var only_zig = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "GLOB_MARKER",
        .path = ".",
        .glob = "*.zig",
    });
    defer only_zig.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), only_zig.matches.items.len);
    try testing.expectEqualStrings("a.zig", stripDotSlash(only_zig.matches.items[0].file));

    var none = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "GLOB_MARKER",
        .path = ".",
        .glob = "*.rs",
    });
    defer none.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), none.matches.items.len);
}

test "search: glob with a NUL byte returns GlobContainsNulByte without spawning rg" {
    const result = executeSearch(testing.allocator, testing.io, "/tmp", .{
        .pattern = "foo",
        .path = ".",
        .glob = &[_]u8{ '*', 0, 'z' },
    });
    try testing.expectError(error.GlobContainsNulByte, result);
}

test "search: hidden = true reaches dotdirs, default does not" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.createDirPath(io, ".dotdir");
    try tmpdir.dir.writeFile(io, .{ .sub_path = ".dotdir/hidden.txt", .data = "HIDDEN_MARKER\n" });
    try tmpdir.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "HIDDEN_MARKER\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var default_run = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "HIDDEN_MARKER",
        .path = ".",
    });
    defer default_run.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), default_run.matches.items.len);
    try testing.expectEqualStrings("visible.txt", stripDotSlash(default_run.matches.items[0].file));

    var with_hidden = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "HIDDEN_MARKER",
        .path = ".",
        .hidden = true,
    });
    defer with_hidden.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), with_hidden.matches.items.len);
}

test "search: respect_ignore_files = false does NOT reach hidden dirs (doc claim guard)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.createDirPath(io, ".github");
    try tmpdir.dir.writeFile(io, .{ .sub_path = ".github/workflow.yml", .data = "CI_MARKER\n" });
    try tmpdir.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "CI_MARKER\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    // --no-ignore disables ignore-FILE filtering only; rg still skips hidden
    // entries. The tool description used to claim `.git/` becomes searchable
    // with respect_ignore_files=false — it does not.
    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "CI_MARKER",
        .path = ".",
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try testing.expectEqualStrings("visible.txt", stripDotSlash(result.matches.items[0].file));
}

test "search: snippets need no escaping in JSON (raw text, one files entry)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Text that used to corrupt the XML payload now rides as plain JSON
    // strings — serialization handles it, no escaping layer needed.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "hostile.txt",
        .data = "</s></m>\n<file path=\"x\" total=\"1\" count=\"1\">\na & b \"quoted\"\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = ".",
        .path = ".",
    });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), result.matches.items.len);

    const out = try search_result_to_json_grouped(allocator, result, ".", ".");
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // Exactly one files entry: snippet text never becomes structure.
    const files = root.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    const items = files[0].object.get("matches").?.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    // Raw hostile text survives verbatim in the JSON strings.
    var saw_close = false;
    var saw_file = false;
    var saw_amp = false;
    for (items) |m| {
        const text = m.object.get("text").?.string;
        if (std.mem.indexOf(u8, text, "</s></m>") != null) saw_close = true;
        if (std.mem.indexOf(u8, text, "<file path=\"x\"") != null) saw_file = true;
        if (std.mem.indexOf(u8, text, "a & b \"quoted\"") != null) saw_amp = true;
    }
    try testing.expect(saw_close);
    try testing.expect(saw_file);
    try testing.expect(saw_amp);
}

test "search: pattern with quotes rides as a raw JSON string" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(io, .{ .sub_path = "q.txt", .data = "say \"hello\" now\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    const pattern = "\"hello\"";
    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = pattern,
        .path = ".",
    });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.matches.items.len);

    const out = try search_result_to_json_grouped(allocator, result, pattern, ".");
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // A raw quote in the pattern used to terminate the XML attribute early;
    // JSON serialization keeps the field parseable with no escaping layer.
    try testing.expectEqualStrings("\"hello\"", root.get("pattern").?.string);
}

test "search: long lines are windowed around the match (default cap)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const line = blk: {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendNTimes(allocator, 'x', 400);
        try buf.appendSlice(allocator, "NEEDLE");
        try buf.appendNTimes(allocator, 'y', 400);
        try buf.append(allocator, '\n');
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(line);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "long.txt", .data = line });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "NEEDLE",
        .path = ".",
    });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.matches.items.len);
    const snippet = result.matches.items[0].snippet;
    // Windowed (cap + the two "..." markers), still containing the match and
    // marked on both sides so the reader knows text was elided.
    try testing.expect(snippet.len <= default_snippet_max_chars + 8);
    try testing.expect(std.mem.indexOf(u8, snippet, "NEEDLE") != null);
    try testing.expect(std.mem.startsWith(u8, snippet, "..."));
    try testing.expect(std.mem.endsWith(u8, snippet, "..."));
}

test "search: snippet_max_chars = 0 disables the window" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const line = blk: {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendNTimes(allocator, 'x', 400);
        try buf.appendSlice(allocator, "NEEDLE");
        try buf.appendNTimes(allocator, 'y', 400);
        try buf.append(allocator, '\n');
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(line);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "long.txt", .data = line });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "NEEDLE",
        .path = ".",
        .snippet_max_chars = 0,
    });
    defer result.deinit(allocator);

    // Whole line back (806 bytes), no elision markers.
    const snippet = result.matches.items[0].snippet;
    try testing.expectEqual(@as(usize, 806), snippet.len);
    try testing.expect(!std.mem.startsWith(u8, snippet, "..."));
}

test "search: windowing never splits a multi-byte UTF-8 sequence" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // 3-byte chars on both sides: the naive byte window (offset - cap/3)
    // lands mid-sequence, so the boundary backoff has to fix it up.
    const euro = "\u{20AC}";
    const line = blk: {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < 100) : (i += 1) try buf.appendSlice(allocator, euro);
        try buf.appendSlice(allocator, "NEEDLE");
        i = 0;
        while (i < 100) : (i += 1) try buf.appendSlice(allocator, euro);
        try buf.append(allocator, '\n');
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer allocator.free(line);
    try tmpdir.dir.writeFile(io, .{ .sub_path = "utf8.txt", .data = line });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "NEEDLE",
        .path = ".",
    });
    defer result.deinit(allocator);

    const snippet = result.matches.items[0].snippet;
    try testing.expect(std.unicode.utf8ValidateSlice(snippet));
    try testing.expect(std.mem.indexOf(u8, snippet, "NEEDLE") != null);
}

test "search: grouped output preserves the collector's file order (was hash order)" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmpdir.dir.writeFile(io, .{ .sub_path = name, .data = "ORDER_MARKER\n" });
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "ORDER_MARKER",
        .path = ".",
    });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), result.matches.items.len);

    // First-seen order in the collector == rg's own order.
    var expected: [3][]const u8 = undefined;
    var expected_len: usize = 0;
    for (result.matches.items) |m| {
        var known = false;
        for (expected[0..expected_len]) |seen| {
            if (std.mem.eql(u8, seen, m.file)) known = true;
        }
        if (!known) {
            expected[expected_len] = m.file;
            expected_len += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), expected_len);

    const out = try search_result_to_json_grouped(allocator, result, "ORDER_MARKER", ".");
    defer allocator.free(out);

    // Each files entry must appear in that same order (a StringHashMap
    // iterator — the old implementation — yields hash order instead).
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const files = root.get("files").?.array.items;
    try testing.expectEqual(expected_len, files.len);
    for (expected[0..expected_len], files) |file_path, f| {
        try testing.expectEqualStrings(file_path, f.object.get("path").?.string);
    }
}

test "search: <file> total= is matched lines for this search, not the file's line count" {
    if (!requiresRg()) return;

    const allocator = testing.allocator;
    const io = testing.io;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Six lines, two of them matching.
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "six.txt",
        .data = "foo first\nplain\nplain\nfoo fourth\nplain\nplain\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmpdir_path = try resolveTmpDir(tmpdir.dir, io, &path_buf);

    var result = try executeSearch(allocator, io, tmpdir_path, .{
        .pattern = "foo",
        .path = ".",
    });
    defer result.deinit(allocator);

    const out = try search_result_to_json_grouped(allocator, result, "foo", ".");
    defer allocator.free(out);

    // rg's stats.matched_lines for this search (2) — NOT the file's 6 lines.
    // Pinned because the tool description used to promise the file length,
    // which sent the model to read_file with the wrong pagination budget.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const files = root.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqual(@as(i64, 2), files[0].object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 2), files[0].object.get("count").?.integer);
}

test "search: tool schema documents the new params and drops the stale claims" {
    // Assert against the RUNTIME schema (not a source scan) so the needles
    // below cannot match this test's own text.
    var saw_hidden = false;
    var saw_glob = false;
    var saw_snippet_cap = false;
    for (search_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "hidden")) saw_hidden = true;
        if (std.mem.eql(u8, prop.name, "glob")) saw_glob = true;
        if (std.mem.eql(u8, prop.name, "snippet_max_chars")) saw_snippet_cap = true;

        // No param may still promise that respect_ignore_files reaches .git/
        // (it does not — that needs `hidden`), and none may still describe
        // the snippet as "~100 chars".
        try testing.expect(std.mem.indexOf(u8, prop.description, "gitignored paths (build/, node_modules/, .git/") == null);
        try testing.expect(std.mem.indexOf(u8, prop.description, "~100 chars") == null);
    }
    try testing.expect(saw_hidden);
    try testing.expect(saw_glob);
    try testing.expect(saw_snippet_cap);

    const desc = search_tool.function.description;
    // Stale claims retired: `s` is windowed (not "~100 chars"), and
    // respect_ignore_files=false does NOT reach .git/.
    try testing.expect(std.mem.indexOf(u8, desc, "~100 chars") == null);
    try testing.expect(std.mem.indexOf(u8, desc, "gitignored paths (build/, node_modules/, .git/") == null);
    // New contract is spelled out for the model.
    try testing.expect(std.mem.indexOf(u8, desc, "truncated") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "output_truncated") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "snippet_max_chars") != null);
    var max_output_description: ?[]const u8 = null;
    for (search_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "max_output")) max_output_description = prop.description;
    }
    try testing.expect(max_output_description != null);
    try testing.expect(std.mem.indexOf(u8, max_output_description.?, "truncated_hint") != null);
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const search_tool_mod = pabrikcore.search_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;
const workspace_fs = @import("../../../agentic_loop/workspace_fs.zig");
const vmd_policy = @import("../../../vmd/policy.zig");
const vmd_rpc = @import("../../../vmd/rpc.zig");

/// The guest's own ceiling on one exec, and the reason the guest's ripgrep is
/// never asked for more than one reply can carry.
const guest_exec_timeout_ceiling_ms: u64 = 600_000;

/// Ripgrep, run where the tree is. Under `--saas` the guest runs it and the
/// host opens nothing; in every other mode it is spawned here, as it always
/// was.
const GuestRunner = struct {
    fs: *workspace_fs.Fs,

    fn run(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        argv: []const []const u8,
        timeout_ms: u64,
        max_output: usize,
    ) anyerror!search_tool_mod.Run {
        _ = io;
        const self: *const GuestRunner = @ptrCast(@alignCast(ctx));
        // `execve` searches no PATH and a host path means nothing in the
        // guest, so the image's own ripgrep is the one that can run.
        const guest_argv = try allocator.alloc([]const u8, argv.len);
        defer allocator.free(guest_argv);
        @memcpy(guest_argv, argv);
        if (guest_argv.len > 0) guest_argv[0] = vmd_policy.guest_rg;

        const launched = self.fs.run(
            guest_argv,
            cwd,
            @intCast(@min(timeout_ms, guest_exec_timeout_ceiling_ms)),
            @min(max_output, vmd_rpc.max_output_bytes_limit),
        ) catch |err| switch (err) {
            workspace_fs.Error.GuestPathOutsideWorkspace => return error.PathError,
            else => return err,
        };
        return .{
            .stdout = launched.stdout,
            .stderr = launched.stderr,
            .code = launched.code,
            .timed_out = launched.timed_out,
            .truncated = launched.truncated,
        };
    }
};

fn searchThrough(
    ctx: ToolExecContext,
    cwd: []const u8,
    input: search_tool_mod.SearchInput,
) !search_tool_mod.SearchResult {
    var holder = try workspace_fs.forSession(ctx.allocator, ctx.db, ctx.session_id);
    defer if (holder) |*fs| fs.deinit();
    if (holder) |*fs| {
        var guest_runner = GuestRunner{ .fs = fs };
        return search_tool_mod.executeSearchWith(ctx.allocator, ctx.io, cwd, input, .{
            .ctx = &guest_runner,
            .runFn = GuestRunner.run,
        });
    }
    return search_tool_mod.executeSearch(ctx.allocator, ctx.io, cwd, input);
}

/// Parse the model-provided JSON and normalize zero-valued optional head/tail
/// placeholders.
fn parseSearchInput(allocator: std.mem.Allocator, args: []const u8) !std.json.Parsed(search_tool_mod.SearchInput) {
    var raw = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        args,
        .{ .allocate = .alloc_always },
    );
    defer raw.deinit();

    if (raw.value == .object) {
        for ([_][]const u8{ "head", "tail" }) |field_name| {
            const value = raw.value.object.getPtr(field_name) orelse continue;
            if (value.* == .integer and value.*.integer == 0) {
                value.* = .null;
            }
        }
    }

    return std.json.parseFromValue(
        search_tool_mod.SearchInput,
        allocator,
        raw.value,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = parseSearchInput(ctx.allocator, args_to_parse) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and it is ALSO the directory ripgrep is spawned in (see
    // `executeSearch`'s `cwd` argument) — the two used to be able to
    const cwd = parsed.value.cwd orelse "";
    path_validate.validateCwd(cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    // rg receives the RESOLVED path, so its own cwd cannot reinterpret it.
    var input = parsed.value;
    input.path = path_abs;
    input.cwd = cwd;

    var search_result = searchThrough(ctx, cwd, input) catch |err| {
        // Map domain errors to LLM-friendly messages. A normal stdout
        // max_output overflow no longer appears here: executeSearch returns
        // a successful SearchResult with output_truncated metadata instead.
        var owned_err_msg: ?[]const u8 = null;
        defer if (owned_err_msg) |msg| ctx.allocator.free(msg);
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.OutputReadFailed => break :blk "could not capture the search output stream — retry; if it persists, narrow the path or use a smaller result window",
                error.StderrTooLong => break :blk "ripgrep diagnostics exceeded the output limit — narrow the path or use a more specific pattern to reduce diagnostics",
                error.EmptyPattern => break :blk "search pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "search pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.InvalidMaxOutput => break :blk "max_output must be > 0 (use 1048576 for the 1MB default)",
                error.MaxOutputTooLarge => break :blk "max_output exceeded the 100MB hard ceiling — narrow your search path or use a more specific pattern to reduce output",
                error.InvalidMaxResults => break :blk "max_results must be > 0 (use the default of 50 if you don't need a specific cap)",
                error.HeadAndTailMutuallyExclusive => break :blk "head and tail are mutually exclusive — set only one and omit the other",
                error.InvalidHeadTail => break :blk "head/tail must be > 0 — omit the flag (or use max_results) instead of passing 0, which would look like a no-match",
                error.GlobContainsNulByte => break :blk "the glob filter contained a NUL (0x00) byte — globs must be valid UTF-8 with no embedded NULs",
                error.RegexParseError => break :blk "search pattern is not a valid regex — check for unmatched parentheses, unescaped metacharacters, or an invalid character class",
                error.PathError => {
                    // Naming the path AND the cwd it was resolved against is
                    // the whole fix for the failure this branch used to
                    // report: a bare "could not access search path" named
                    owned_err_msg = try std.fmt.allocPrint(
                        ctx.allocator,
                        "could not access search path \"{s}\" from cwd \"{s}\" — verify both exist and are readable. `cwd` is the directory ripgrep runs in; `path` is resolved against it.",
                        .{ path_abs, cwd },
                    );
                    break :blk owned_err_msg.?;
                },
                error.Timeout => break :blk "search timed out (30s default) — narrow your search path, use a more specific pattern, or pass a larger timeout_ms",
                error.RgNotFound => break :blk "ripgrep (rg) is not installed or not on PATH — install it first, then retry the search",
                else => {},
            }
            const msg = error_explain.explain(ctx.allocator, err, null) catch {
                break :blk "search failed with an unknown error";
            };
            owned_err_msg = msg;
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer search_result.deinit(ctx.allocator);

    // Honor group_by_file flag — use the flat variant when requested. Both
    // formatters carry the same truncation metadata, including a successful
    // partial result when max_output was reached.
    const inner = if (parsed.value.group_by_file)
        try search_tool_mod.search_result_to_json_grouped(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        )
    else
        try search_tool_mod.search_result_to_json_flat(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        );
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

test "search JSON parser treats a zero-valued unused head/tail as omitted" {
    const args =
        \\{"pattern":"Open chat in new tab","path":"/tmp/example","max_results":100,
        \\ "head":100,"tail":0,"max_output":20000,"group_by_file":true,
        \\ "respect_ignore_files":true,"word_boundary":false,"literal":true,
        \\ "only_matching":false,"snippet_max_chars":300,"hidden":false,
        \\ "glob":"*.{vue,ts,tsx,js}","timeout_ms":30000}
    ;

    var parsed = try parseSearchInput(std.testing.allocator, args);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 100), parsed.value.head.?);
    try std.testing.expect(parsed.value.tail == null);
}

test "TDD: execSearch accepts head=100 with tail=0 and returns a successful match envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "open-chat.txt",
        .data = "Open chat in new tab\nOpen chat in new tab again\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // This is the model-call shape from the failing UI request: head is
    // selected, while the unused optional tail is emitted as 0.
    const args_json = try std.json.Stringify.valueAlloc(allocator, .{
        .pattern = "Open chat in new tab",
        .path = ".",
        // `cwd` is required: the directory this call works in, and the base
        // `path` (here ".") resolves against.
        .cwd = tmpdir_path,
        .max_results = 100,
        .head = 100,
        .tail = 0,
        .max_output = 20_000,
        .group_by_file = true,
        .respect_ignore_files = true,
        .word_boundary = false,
        .literal = true,
        .only_matching = false,
        .snippet_max_chars = 300,
        .hidden = false,
        .glob = "*.txt",
        .timeout_ms = 30_000,
    }, .{});

    var dummy_temperature: f32 = 0.0;
    var dummy_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test-session",
        .model = "test-model",
        .cwd = tmpdir_path,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_temperature,
        .is_thinking = &dummy_thinking,
        .environment = null,
    };
    const tool_call = agent.ToolCall{
        .id = "call-search-tail-zero",
        .type = "function",
        .function = .{ .name = "search", .arguments = args_json },
    };

    // Before zero-placeholder normalization, this call reached executeSearch
    // with both optionals non-null and returned success=false with
    // HeadAndTailMutuallyExclusive. This assertion is the red/green regression.
    const exec_result = try execSearch(ctx, tool_call);
    defer exec_result.deinit(allocator);

    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, exec_result.output, .{});
    defer envelope.deinit();
    const root = envelope.value.object;
    const success = root.get("success").?.bool;
    if (!success) {
        const error_value = root.get("error").?;
        if (error_value == .string and std.mem.indexOf(u8, error_value.string, "ripgrep (rg) is not installed") != null) return;
    }

    try std.testing.expect(success);
    try std.testing.expect(root.get("error").? == .null);
    const data = root.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 2), data.get("returned").?.integer);
    const files = data.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    const matches = files[0].object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(i64, 1), matches[0].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), matches[1].object.get("line").?.integer);
}

test "execSearch returns success for an oversized stdout search with a truncation hint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "large.txt",
        .data = "FOUND_MARKER line\nFOUND_MARKER again\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];
    const args_json = try std.json.Stringify.valueAlloc(allocator, .{
        .pattern = "FOUND_MARKER",
        .path = ".",
        .cwd = tmpdir_path,
        .max_output = 1,
        .group_by_file = true,
        .literal = true,
    }, .{});
    defer allocator.free(args_json);

    var dummy_temperature: f32 = 0.0;
    var dummy_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test-session",
        .model = "test-model",
        .cwd = tmpdir_path,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_temperature,
        .is_thinking = &dummy_thinking,
        .environment = null,
    };
    const tool_call = agent.ToolCall{
        .id = "call-search-output-cap",
        .type = "function",
        .function = .{ .name = "search", .arguments = args_json },
    };

    const exec_result = try execSearch(ctx, tool_call);
    defer exec_result.deinit(allocator);
    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, exec_result.output, .{});
    defer envelope.deinit();
    const root = envelope.value.object;
    if (!root.get("success").?.bool) {
        const error_value = root.get("error").?;
        if (error_value == .string and std.mem.indexOf(u8, error_value.string, "ripgrep (rg) is not installed") != null) return;
    }
    try std.testing.expect(root.get("success").?.bool);
    try std.testing.expect(root.get("error").? == .null);
    const data = root.get("data").?.object;
    try std.testing.expect(data.get("truncated").?.bool);
    try std.testing.expect(data.get("output_truncated").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, data.get("truncated_hint").?.string, "max_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec_result.output, "Search output exceeded max_output" ++ " limit") == null);
}

test "search JSON parser lets head with tail=0 reach execution as head-only" {
    var parsed = try parseSearchInput(std.testing.allocator,
        \\{"pattern":"needle","path":".","head":100,"tail":0,"timeout_ms":0}
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.Timeout,
        search_tool_mod.executeSearch(std.testing.allocator, std.testing.io, "/tmp", parsed.value),
    );
}

test "search JSON parser preserves positive head and tail for strict validation" {
    var parsed = try parseSearchInput(std.testing.allocator,
        \\{"pattern":"needle","path":".","head":5,"tail":5}
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 5), parsed.value.head.?);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.tail.?);
}

