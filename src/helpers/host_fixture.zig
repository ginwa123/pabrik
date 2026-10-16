//! host_fixture — a fixture program that runs on EVERY host.
//! `writeProgram` renders one `Payload` as a `#!/bin/sh` script on POSIX
//! and a `.cmd` batch file on Windows, so no test needs `/bin/sh`.

const std = @import("std");
const builtin = @import("builtin");

/// What a fixture program should do. Every field is optional; the defaults
/// produce a program that prints nothing and exits 0.
pub const Payload = struct {
    /// Text printed to stdout, verbatim, with no trailing newline added.
    stdout: []const u8 = "",
    /// Text printed to stderr, verbatim, with no trailing newline added.
    stderr: []const u8 = "",
    /// Process exit code.
    exit_code: u8 = 0,
    /// When set, the program writes its own argv (one per line, argv[0]
    /// excluded) to this path before doing anything else. This is how the
    /// suites prove which argv was actually spawned.
    argv_file: ?[]const u8 = null,
    /// When set, the program writes this text to `argv_file` instead of its
    /// argv. Used by fixtures that need to record a computed value.
    argv_file_body: ?[]const u8 = null,
    /// When set, the program creates this (empty) file. A sentinel: if the
    /// file exists afterwards, the program ran.
    touch_file: ?[]const u8 = null,
    /// When true, the program prints its working directory to stdout.
    print_cwd: bool = false,
    /// When true, the program sleeps for `sleep_ms` before anything else.
    /// A fixture that outlives the caller's deadline.
    sleep_ms: ?u32 = null,
    /// When true, the program kills itself with a signal (POSIX) or exits
    /// with a distinctive code (Windows, which has no signal to send).
    kill_self: bool = false,
    /// When true, the program writes `repeat` copies of `stdout` to stdout.
    /// Used by the large-output tests.
    repeat: ?usize = null,
    /// When true, the program writes `repeat` copies of `stderr` to stderr.
    repeat_stderr: ?usize = null,
};

/// A throwaway directory under `.zig-cache/tmp` plus fixture programs inside
/// it. `root` is the absolute path; programs are marked executable on POSIX
/// (Windows needs no permission bit, and `cmd.exe` runs a `.cmd` directly).
pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [512]u8 = undefined;
        const root = try tmp.dir.realPath(std.testing.io, &buf);
        const owned = try allocator.dupe(u8, buf[0..root]);
        return .{ .tmp = tmp, .root = owned, .allocator = allocator };
    }

    pub fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
    }

    /// Write a fixture program named `name` that behaves as `payload`
    /// describes, and return its absolute path. On Windows the file is
    /// `<name>.cmd`: an extension-less file is looked up as a binary.
    pub fn writeProgram(self: *Fixture, name: []const u8, payload: Payload) ![]u8 {
        const script = try renderProgram(self.allocator, payload);
        defer self.allocator.free(script);
        // On Windows the payloads live in sidecar data files the batch file
        // relays to its streams (`cmdEmitLine`). Both files, even an empty
        // one: a script may reference a stream through `repeat` alone.
        if (builtin.os.tag == .windows) {
            try self.tmp.dir.writeFile(std.testing.io, .{
                .sub_path = sidecarFileName(.stdout),
                .data = payload.stdout,
            });
            try self.tmp.dir.writeFile(std.testing.io, .{
                .sub_path = sidecarFileName(.stderr),
                .data = payload.stderr,
            });
        }
        return self.writeProgramText(name, script);
    }

    /// `writeProgram` for a body the caller rendered (`git_pr_close.ghScript`).
    /// On Windows such a body must write its own sidecar data files, or it
    /// names files that do not exist and emits nothing.
    pub fn writeProgramText(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        const file_name = try self.programFileName(name);
        defer self.allocator.free(file_name);
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = file_name,
            .data = script,
        });
        if (builtin.os.tag != .windows) {
            try self.tmp.dir.setFilePermissions(std.testing.io, file_name, .executable_file, .{});
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, file_name });
    }

    /// The on-disk name of a fixture program: `name` on POSIX,
    /// `name.cmd` on Windows.
    fn programFileName(self: *Fixture, name: []const u8) ![]u8 {
        if (builtin.os.tag == .windows) {
            return std.fmt.allocPrint(self.allocator, "{s}.cmd", .{name});
        }
        return self.allocator.dupe(u8, name);
    }

    /// A subdirectory of the fixture root, created on demand.
    pub fn subDir(self: *Fixture, name: []const u8) ![]u8 {
        self.tmp.dir.createDirPath(std.testing.io, name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }
};

/// Render `payload` as a script this host can execute. Private: a Windows
/// body NAMES the sidecar data files, and only `Fixture.writeProgram`
/// writes them — handing the text to `writeProgramText` emits nothing.
fn renderProgram(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => renderCmd(allocator, payload),
        else => renderSh(allocator, payload),
    };
}

/// Write `printf '%b' '<escaped>'` for `bytes`. `printf '%s'` cannot carry
/// a NUL, so non-printable bytes are octal-escaped — which is what keeps
/// the "non-UTF8 bytes survive capture" test honest.
fn writeShBytes(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeAll("printf '%b' '");
    for (bytes) |b| {
        if (b >= 0x20 and b < 0x7f and b != '\'' and b != '\\') {
            try w.writeByte(b);
        } else {
            try w.print("\\{o}", .{b});
        }
    }
    try w.writeAll("'");
}

fn renderSh(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const w = &aw.writer;

    try w.writeAll("#!/bin/sh\n");

    if (payload.argv_file) |path| {
        if (payload.argv_file_body) |body| {
            try w.print("printf '%s' '{s}' > '{s}'\n", .{ body, path });
        } else {
            try w.print("for a in \"$@\"; do printf '%s\\n' \"$a\"; done > '{s}'\n", .{path});
        }
    }
    if (payload.touch_file) |path| {
        try w.print(": > '{s}'\n", .{path});
    }
    if (payload.sleep_ms) |ms| {
        try w.print("sleep {d}\n", .{@as(f64, @floatFromInt(ms)) / 1000.0});
    }
    if (payload.print_cwd) {
        try w.writeAll("pwd\n");
    }
    if (payload.repeat_stderr) |n| {
        try w.print("i=0; while [ $i -lt {d} ]; do i=$((i+1)); ", .{n});
        try writeShBytes(w, payload.stderr);
        try w.writeAll(" 1>&2; done\n");
    } else if (payload.stderr.len > 0) {
        try writeShBytes(w, payload.stderr);
        try w.writeAll(" 1>&2\n");
    }
    if (payload.repeat) |n| {
        try w.print("i=0; while [ $i -lt {d} ]; do i=$((i+1)); ", .{n});
        try writeShBytes(w, payload.stdout);
        try w.writeAll("; done\n");
    } else if (payload.stdout.len > 0) {
        try writeShBytes(w, payload.stdout);
        try w.writeAll("\n");
    }
    if (payload.kill_self) {
        try w.writeAll("kill -9 $$\n");
    }
    try w.print("exit {d}\n", .{payload.exit_code});
    return aw.toOwnedSlice();
}

fn renderCmd(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const w = &aw.writer;

    // `@echo off` keeps the batch file's own commands out of stdout, which
    // every assertion below compares byte-for-byte.
    try w.writeAll("@echo off\n");

    // WHY NOT `echo`: it appends a space, ends with CRLF, and cannot emit a
    // NUL. `else if`, mirroring `renderSh`: `repeat` REPLACES the single
    // emission, or a `repeat = n` payload comes out n + 1 times.
    if (payload.repeat) |n| {
        try cmdEmitLine(w, .stdout, n);
    } else if (payload.stdout.len > 0) {
        try cmdEmitLine(w, .stdout, null);
    }
    if (payload.repeat_stderr) |n| {
        try cmdEmitLine(w, .stderr, n);
    } else if (payload.stderr.len > 0) {
        try cmdEmitLine(w, .stderr, null);
    }
    if (payload.argv_file) |path| {
        if (payload.argv_file_body) |body| {
            try w.print("> \"{s}\" echo {s}\n", .{ path, body });
        } else {
            // `%*` is the whole argument list, space-separated on one line.
            // The suites that assert on it compare against that shape (see
            // `argvRecordedShape`).
            try w.print("> \"{s}\" echo %*\n", .{path});
        }
    }
    if (payload.touch_file) |path| {
        try w.print("type nul > \"{s}\"\n", .{path});
    }
    if (payload.print_cwd) {
        try w.writeAll("cd\n");
    }
    if (payload.sleep_ms) |ms| {
        // `ping -n` is the portable Windows sleep. `timeout` is NOT used: it
        // refuses to run when stdin is redirected (which `run_captured`
        // always does) and exits at once, so the deadline test would fail.
        const secs = @max(2, @divTrunc(ms + 999, 1000));
        try w.print("ping -n {d} 127.0.0.1 > nul\n", .{secs});
    }
    if (payload.kill_self) {
        // Windows has no signal to send to yourself, so `exit /b` with a
        // distinctive code is the analogue; the suites assert the child did
        // not report success rather than naming a signal.
        try w.writeAll("exit /b 9\n");
    }
    try w.print("exit /b {d}\n", .{payload.exit_code});
    return aw.toOwnedSlice();
}

/// Which stream a sidecar data file carries.
pub const DataStream = enum { stdout, stderr };

/// The sidecar data file a `.cmd` fixture relays one stream's bytes from.
/// One name per stream, so a payload writing both cannot clobber the other
/// and a caller-rendered `.cmd` body can name the same file.
pub fn sidecarFileName(stream: DataStream) []const u8 {
    return switch (stream) {
        .stdout => "pabrik-fixture-out.bin",
        .stderr => "pabrik-fixture-err.bin",
    };
}

/// Write the batch statement that relays a sidecar file's bytes to `stream`,
/// `repeat` times when given. WHY `type`, NOT `copy /b`: `copy` opens
/// `CON`/`NUL` itself, so a redirected stdout gets only its status line.
pub fn cmdEmitLine(w: *std.Io.Writer, stream: DataStream, repeat: ?usize) !void {
    // A redirection, not a second file: `1>&2` dups the child's own stderr
    // handle, which is the pipe the caller reads.
    const to_stderr = switch (stream) {
        .stdout => "",
        .stderr => " 1>&2",
    };
    if (repeat) |n| {
        try w.print("for /L %%i in (1,1,{d}) do type \"%~dp0{s}\"{s}\n", .{ n, sidecarFileName(stream), to_stderr });
    } else {
        try w.print("type \"%~dp0{s}\"{s}\n", .{ sidecarFileName(stream), to_stderr });
    }
}

/// How a fixture's recorded argv looks on this host: one argument per line
/// on POSIX, space-separated on Windows. Assert through the helpers below
/// rather than comparing against a literal.
pub const ArgvShape = enum {
    /// One argument per line, argv[0] excluded.
    one_per_line,
    /// All arguments on one line, space-separated, argv[0] excluded.
    one_line,
};

pub fn argvRecordedShape() ArgvShape {
    return switch (builtin.os.tag) {
        .windows => .one_line,
        else => .one_per_line,
    };
}

/// Everything a recorded argv can be split on: the POSIX shape's line break,
/// the Windows one's spaces, and `"` — a SEPARATOR, not data, because the
/// Windows record is cmd's tail and Zig quotes any argument with a comma.
const argv_separators = " \t\r\n\"";

/// True when the recorded argv contains `needle` as a whole argument,
/// whichever shape this host recorded it in.
pub fn recordedArgvContains(recorded: []const u8, needle: []const u8) bool {
    // Whole-argument match on BOTH shapes: a substring match would let
    // `--head-ref` satisfy a needle of `--head`, and the create suite
    // asserts that flag is ABSENT.
    var it = std.mem.tokenizeAny(u8, recorded, argv_separators);
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, needle)) return true;
    }
    return false;
}

/// True when the recorded argv contains `words` as a contiguous run of whole
/// arguments in order — the POSIX form is `a\nb\n`, the Windows form `a b`.
/// Used for the multi-word argv assertions.
pub fn recordedArgvContainsSequence(recorded: []const u8, words: []const []const u8) bool {
    if (words.len == 0) return true;
    var it = std.mem.tokenizeAny(u8, recorded, argv_separators);
    var matched: usize = 0;
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, words[matched])) {
            matched += 1;
            if (matched == words.len) return true;
        } else {
            // `words[0]` can be the very word that just broke the run, so
            // restart from it rather than from zero.
            matched = if (std.mem.eql(u8, word, words[0])) 1 else 0;
        }
    }
    return false;
}

// ─── Tests ───────────────────────────────────────────────────────────────
// is that a fixture is host-portable, so its own tests must not decline a
// host either.

const testing = std.testing;

test "renderProgram: a POSIX payload is a shell script, a Windows one a batch file" {
    const a = testing.allocator;
    const script = try renderProgram(a, .{ .stdout = "hello" });
    defer a.free(script);
    if (builtin.os.tag == .windows) {
        try testing.expect(std.mem.startsWith(u8, script, "@echo off"));
        // The payload is NOT in the script on Windows: it lives in a sidecar
        // data file the batch file relays to the stream, because `echo`
        // cannot emit a byte-exact payload.
        try testing.expect(std.mem.indexOf(u8, script, sidecarFileName(.stdout)) != null);
    } else {
        try testing.expect(std.mem.startsWith(u8, script, "#!/bin/sh"));
        try testing.expect(std.mem.indexOf(u8, script, "printf '%b' 'hello'") != null);
    }
}

test "renderProgram: every payload field has a line in both dialects" {
    const a = testing.allocator;
    const full = Payload{
        .stdout = "OUT",
        .stderr = "ERR",
        .exit_code = 3,
        .argv_file = "/tmp/argv",
        .touch_file = "/tmp/sentinel",
        .print_cwd = true,
        .sleep_ms = 1000,
        .repeat = 4,
        .repeat_stderr = 2,
    };
    const script = try renderProgram(a, full);
    defer a.free(script);
    // The exit code is the last line in both dialects, and it is the one
    // field every caller depends on.
    const want_exit = if (builtin.os.tag == .windows) "exit /b 3" else "exit 3";
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, script, "\n"), want_exit));
    // Each optional field must have produced SOMETHING, or a caller that
    // sets it would silently get a no-op fixture on this host. On Windows
    // the payloads are sidecar files, so the script names them.
    try testing.expect(std.mem.indexOf(u8, script, "/tmp/argv") != null);
    try testing.expect(std.mem.indexOf(u8, script, "/tmp/sentinel") != null);
    if (builtin.os.tag == .windows) {
        try testing.expect(std.mem.indexOf(u8, script, sidecarFileName(.stdout)) != null);
        try testing.expect(std.mem.indexOf(u8, script, sidecarFileName(.stderr)) != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, script, "OUT") != null);
        try testing.expect(std.mem.indexOf(u8, script, "ERR") != null);
    }
}

test "writeProgram: the file it writes is executable on this host" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const prog = try fx.writeProgram("gh", .{ .stdout = "{\"number\":1}" });
    defer a.free(prog);

    // The path must end in the extension this host's spawn understands.
    if (builtin.os.tag == .windows) {
        try testing.expect(std.mem.endsWith(u8, prog, ".cmd"));
    } else {
        try testing.expect(std.mem.endsWith(u8, prog, "gh"));
    }
    // And it must actually run: spawn it and read back the payload.
    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqualStrings("{\"number\":1}", std.mem.trimEnd(u8, r.stdout, "\r\n"));
}

test "writeProgram: a fixture that records its argv records the args it was given" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const argv_file = try std.fmt.allocPrint(a, "{s}/argv", .{fx.root});
    defer a.free(argv_file);
    const prog = try fx.writeProgram("gh", .{ .argv_file = argv_file });
    defer a.free(prog);

    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{ prog, "pr", "view", "--json", "number" }, .{ .timeout_ms = 10_000 });
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.term.exited);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, argv_file, a, .limited(64 * 1024));
    defer a.free(recorded);
    try testing.expect(recordedArgvContains(recorded, "pr"));
    try testing.expect(recordedArgvContains(recorded, "view"));
    try testing.expect(recordedArgvContains(recorded, "--json"));
    try testing.expect(recordedArgvContains(recorded, "number"));
    // argv[0] is the program itself and must never be recorded.
    try testing.expect(!recordedArgvContains(recorded, "gh"));
}

test "writeProgram: a non-zero exit code survives the spawn" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const prog = try fx.writeProgram("gh", .{ .exit_code = 9 });
    defer a.free(prog);

    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 9), r.term.exited);
}

test "writeProgram: stderr is captured separately from stdout" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const prog = try fx.writeProgram("gh", .{ .stdout = "OUT", .stderr = "ERR" });
    defer a.free(prog);

    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(a);
    try testing.expectEqualStrings("OUT", std.mem.trimEnd(u8, r.stdout, "\r\n"));
    try testing.expectEqualStrings("ERR", std.mem.trimEnd(u8, r.stderr, "\r\n"));
}

test "writeProgram: a sentinel file proves the program ran" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const sentinel = try std.fmt.allocPrint(a, "{s}/ran", .{fx.root});
    defer a.free(sentinel);
    const prog = try fx.writeProgram("gh", .{ .touch_file = sentinel });
    defer a.free(prog);

    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    const ran = if (std.Io.Dir.cwd().access(std.testing.io, sentinel, .{})) |_| true else |_| false;
    try testing.expect(ran);
}

test "writeProgram: print_cwd reports the directory the child ran in" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try fx.subDir("repo");
    defer a.free(repo);
    const prog = try fx.writeProgram("gh", .{ .print_cwd = true });
    defer a.free(prog);

    var r = try @import("run_captured.zig").run(a, std.testing.io, &.{prog}, .{
        .timeout_ms = 10_000,
        .cwd = repo,
    });
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    // The child's cwd is the directory we asked for, in the host's own
    // spelling — compare the tail, not the separators.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "repo") != null);
}

test "argvRecordedShape: one_per_line off Windows, one_line on it" {
    const shape = argvRecordedShape();
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(ArgvShape.one_line, shape);
    } else {
        try testing.expectEqual(ArgvShape.one_per_line, shape);
    }
}

test "recordedArgvContains: matches a whole argument, not a substring" {
    // `--head` must not be satisfied by `--head-ref` — the create suite
    // asserts the flag is ABSENT, and a substring match would pass while
    // the flag was actually there.
    try testing.expect(!recordedArgvContains("--head-ref\nmain\n", "--head"));
    try testing.expect(recordedArgvContains("--head-ref\nmain\n", "--head-ref"));
    try testing.expect(recordedArgvContains("--head-ref main", "--head-ref"));
    try testing.expect(!recordedArgvContains("--head-ref main", "--head"));
    // A QUOTED argument matches its bare needle: on Windows the quote is
    // cmd's, not the argument's (see `argv_separators`).
    try testing.expect(recordedArgvContains("pr view --json \"number,title\"", "number,title"));
    try testing.expect(recordedArgvContains("pr view --json \"number,title\"", "--json"));
}

test "recordedArgvContainsSequence: finds an ordered run in either host's shape" {
    // Both shapes on EVERY host: the POSIX record is one argument per line,
    // the Windows one cmd's single command tail, and the matcher has to read
    // either without knowing which host it is running on.
    const one_per_line = "pr\nview\n--json\nnumber,title\n";
    const one_line = "pr view --json number,title";
    // The Windows record arrives QUOTED whenever Zig had to quote an
    // argument — one comma in the field list is enough — so the needle must
    // survive the quotes (the CI regression this matcher is written for).
    const one_line_quoted = "pr view --json \"number,title\"";
    for ([_][]const u8{ one_per_line, one_line, one_line_quoted }) |recorded| {
        try testing.expect(recordedArgvContainsSequence(recorded, &.{ "pr", "view" }));
        try testing.expect(recordedArgvContainsSequence(recorded, &.{ "view", "--json", "number,title" }));
        // A single word is a sequence of one.
        try testing.expect(recordedArgvContainsSequence(recorded, &.{"--json"}));
        // An empty sequence is trivially present.
        try testing.expect(recordedArgvContainsSequence(recorded, &.{}));
        // Out of order is not a run, and neither is a word that never
        // appears.
        try testing.expect(!recordedArgvContainsSequence(recorded, &.{ "view", "pr" }));
        try testing.expect(!recordedArgvContainsSequence(recorded, &.{ "pr", "view", "create" }));
    }
    // `words[0]` appearing twice must not lose the run that follows it.
    try testing.expect(recordedArgvContainsSequence("pr pr view", &.{ "pr", "view" }));
}
