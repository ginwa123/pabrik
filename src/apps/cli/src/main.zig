//! `pabrikcli` entry point. Boot sequence: 1.

const std = @import("std");
const cli = @import("cli");

/// Top-level entry. Receives `Init` so we can use stdlib's
/// pre-allocated arena (lives for the whole process) and the Io
/// runner.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const environment = init.environ_map;

    // The first argv entry is the binary name; skip it.
    const argv_full = try init.minimal.args.toSlice(allocator);
    const argv = if (argv_full.len > 0) argv_full[1..] else &[_][]const u8{};

    // ----- 1.
    var flag_server: ?[]const u8 = null;
    var flag_session: ?[]const u8 = null;
    var flag_profile: ?[]const u8 = null;

    // We allocate a fresh argv for the post-strip view. Worst-case
    // length equals the input length (every arg is preserved).
    var stripped = try std.ArrayList([]const u8).initCapacity(allocator, argv.len);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= argv.len) {
                std.log.err("--server requires a value", .{});
                return;
            }
            flag_server = argv[i];
        } else if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= argv.len) {
                std.log.err("--session requires a value", .{});
                return;
            }
            flag_session = argv[i];
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= argv.len) {
                std.log.err("--profile requires a value", .{});
                return;
            }
            flag_profile = argv[i];
        } else {
            stripped.appendAssumeCapacity(a);
        }
    }

    // ----- 2.
    var scratch: [32 * 1024]u8 = undefined;
    const cmd = try cli.commands.parseCommand(allocator, stripped.items, &scratch);

    // ----- 3. Load config (flags → env → defaults) ----------------------
    const cfg = try cli.config.load(allocator, environment, flag_server, flag_session, flag_profile);

    // ----- 4. Dispatch --------------------------------------------------
    const result = cli.commands.dispatch(cmd, cfg, io);

    // Drain stdout so buffered output flushes before we exit.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    stdout_file_writer.interface.flush() catch {};

    if (result == .err) {
        // Failures inside a subcommand logged the error via std.log; emit a
        // single trailing log line so wrappers can detect a non-zero exit.
        std.log.err("pabrikcli failed", .{});
    }
}

test "main: placeholder smoke test" {
    // Real CLI behaviour is exercised by the subcommand tests (the inline
    // tests in `commands/sessions.zig`, `commands/messages.zig`,
    // `commands/send.zig`, `commands/events.zig`); the `main` symbol itself
    try std.testing.expect(true);
}