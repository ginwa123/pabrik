//! `zginlint` entry point: collect argv, run the CLI, flush, exit.

const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    _ = args.next();
    while (args.next()) |argument| try argv.append(allocator, argument);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_buffer: [8192]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);

    const code = try cli.run(allocator, io, argv.items, &stdout.interface, &stderr.interface);
    try stdout.interface.flush();
    try stderr.interface.flush();
    std.process.exit(code);
}
