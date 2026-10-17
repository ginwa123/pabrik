//! Repository config can make `git` execute code: `core.fsmonitor` (`status`),
//! hooks (`checkout`, `worktree add`) and `diff.<driver>.textconv` (`diff`).
//! A command-line `-c` outranks every config file, so the argv prefix is policy.

const std = @import("std");

/// Global options that disable the repo-controlled exec paths. Order matters
/// only in that each `-c` owns the token after it; git reads them before the
/// subcommand, so callers append these directly after the program name.
const args_tuple = .{
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "diff.external=",
    "-c", "core.pager=cat",
    "-c", "core.sshCommand=",
    "-c", "protocol.ext.allow=never",
};

/// Slice view, for `ArrayList.appendSlice` call sites.
pub const CONFIG_ARGS: [args_tuple.len][]const u8 = args_tuple;

/// Tuple view, for call sites that build their argv as a literal.
pub const git_prefix = .{"git"} ++ args_tuple;

pub const program = "git";

/// Append `git` plus the hardening options. The caller appends `-C <dir>` and
/// the subcommand, since every call site already builds those itself.
pub fn appendGit(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, &CONFIG_ARGS);
}

/// Value of `-c <key>=<value>` for `key`, or null when this prefix does not
/// set it. Exposed so a caller can assert its own site is covered.
pub fn configValue(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < CONFIG_ARGS.len) : (i += 2) {
        const pair = CONFIG_ARGS[i + 1];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "every option is a -c pair whose right-hand side neutralises a setting" {
    try testing.expect(CONFIG_ARGS.len % 2 == 0);
    var i: usize = 0;
    while (i < CONFIG_ARGS.len) : (i += 2) {
        try testing.expectEqualStrings("-c", CONFIG_ARGS[i]);
        try testing.expect(std.mem.indexOfScalar(u8, CONFIG_ARGS[i + 1], '=') != null);
        try testing.expect(std.mem.indexOfScalar(u8, CONFIG_ARGS[i + 1], ' ') == null);
    }
}

test "the prefix disables fsmonitor, hooks, external diff and sshCommand" {
    try testing.expectEqualStrings("false", configValue("core.fsmonitor").?);
    try testing.expectEqualStrings("/dev/null", configValue("core.hooksPath").?);
    try testing.expectEqualStrings("", configValue("diff.external").?);
    try testing.expectEqualStrings("", configValue("core.sshCommand").?);
    try testing.expectEqual(@as(?[]const u8, null), configValue("difftool.prompt"));
}

test "appendGit leaves the program first and the subcommand last" {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try appendGit(&argv, testing.allocator);
    try argv.append(testing.allocator, "status");
    try testing.expectEqualStrings(program, argv.items[0]);
    try testing.expectEqualStrings("status", argv.items[argv.items.len - 1]);
    try testing.expectEqual(CONFIG_ARGS.len + 2, argv.items.len);
    try testing.expectEqualStrings("-c", argv.items[1]);
}
