//! The manager a `--saas` boot starts when it finds none: resolve the host
//! artifacts, fork `pabrik-vmd serve` into its own session, wait for its ping.
//! The candidate lists are env-only, so their order is testable off-box.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const vmd_client = @import("vmd_client.zig");
const lifecycle = @import("lifecycle.zig");

/// A cold manager binds its socket, then answers — 5 s covers a loaded box.
pub const default_wait_ms: u32 = 5_000;
const poll_ms: i64 = 50;
const ping_guard_ms: u32 = 250;

pub const Refusal = enum {
    unsupported_platform,
    vmd_binary,
    base_image,
    kernel,
    firecracker,
    spawn_failed,
    never_answered,
};

/// One line each, naming the exact thing the operator has to supply.
pub fn message(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .unsupported_platform => "--saas needs Linux with KVM; this host keeps the local runtime",
        .vmd_binary => "--saas cannot find pabrik-vmd: put it beside this binary, on PATH, or set PABRIK_VMD_BIN",
        .base_image => "--saas needs a guest image: set PABRIK_VM_BASE_IMAGE (scripts/build-guest-image.sh --out IMG)",
        .kernel => "--saas needs a guest kernel: set PABRIK_GUEST_KERNEL to a vmlinux, or put one in the VM root",
        .firecracker => "--saas needs firecracker: set PABRIK_FC_BIN, or put `firecracker` on PATH",
        .spawn_failed => "--saas could not fork pabrik-vmd; see vmd.log in the VM root",
        .never_answered => "--saas started pabrik-vmd but it never answered a ping; see vmd.log in the VM root",
    };
}

/// Everything the forked manager needs, resolved to a real absolute path.
pub const Artifacts = struct {
    vmd: []const u8,
    base_image: []const u8,
    kernel: []const u8,
    fc: []const u8,
    root: []const u8,
    /// The agent the manager serves to a guest's bootstrap. Empty means it
    /// serves none, and every guest runs the agent on its own disk.
    agent: []const u8 = "",
};

pub const Plan = union(enum) {
    spawn: Artifacts,
    refused: Refusal,
};

/// What the filesystem search found; `plan` is the pure half that judges it.
pub const Found = struct {
    vmd: ?[]const u8 = null,
    base_image: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    fc: ?[]const u8 = null,
    root: []const u8 = "",
    agent: ?[]const u8 = null,
};

pub fn plan(found: Found) Plan {
    const vmd = found.vmd orelse return .{ .refused = .vmd_binary };
    const base_image = found.base_image orelse return .{ .refused = .base_image };
    const kernel = found.kernel orelse return .{ .refused = .kernel };
    const fc = found.fc orelse return .{ .refused = .firecracker };
    return .{ .spawn = .{
        .vmd = vmd,
        .base_image = base_image,
        .kernel = kernel,
        .fc = fc,
        .root = found.root,
        .agent = found.agent orelse "",
    } };
}

pub const max_argv = 16;

/// The exact argv `pabrik-vmd serve` is forked with: program, command, pairs.
pub fn argvFor(artifacts: Artifacts, socket_path: []const u8, buf: *[max_argv][]const u8) []const []const u8 {
    var words = [_][]const u8{
        artifacts.vmd,  "serve",
        "--socket",     socket_path,
        "--base-image", artifacts.base_image,
        "--kernel",     artifacts.kernel,
        "--fc",         artifacts.fc,
        "--root",       artifacts.root,
        "",             "", // the agent, when there is one
    };
    // The twelve fixed words (the program, the command and five pairs); the
    // two agent slots follow when there is one.
    var len: usize = 12;
    if (artifacts.agent.len > 0) {
        words[len] = "--agent";
        len += 1;
        words[len] = artifacts.agent;
        len += 1;
    }
    @memcpy(buf[0..len], words[0..len]);
    return buf[0..len];
}

pub const Candidates = std.ArrayList([]const u8);

fn addOwned(list: *Candidates, a: std.mem.Allocator, path: []const u8) !void {
    try list.append(a, try a.dupe(u8, path));
}

fn addJoined(list: *Candidates, a: std.mem.Allocator, parts: []const []const u8) !void {
    try list.append(a, try std.fs.path.join(a, parts));
}

fn addOnPath(list: *Candidates, a: std.mem.Allocator, path_env: ?[]const u8, name: []const u8) !void {
    const path = path_env orelse return;
    var parts = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (parts.next()) |dir| {
        if (dir.len == 0) continue;
        try addJoined(list, a, &.{ dir, name });
    }
}

pub fn freeCandidates(list: *Candidates, a: std.mem.Allocator) void {
    for (list.items) |path| a.free(path);
    list.deinit(a);
}

/// `PABRIK_VMD_BIN`, then beside this executable, then every PATH entry.
pub fn vmdCandidates(a: std.mem.Allocator, env: *const std.process.Environ.Map, exe_dir: ?[]const u8) !Candidates {
    var list: Candidates = .empty;
    errdefer freeCandidates(&list, a);
    if (env.get("PABRIK_VMD_BIN")) |path| try addOwned(&list, a, path);
    if (exe_dir) |dir| try addJoined(&list, a, &.{ dir, "pabrik-vmd" });
    try addOnPath(&list, a, env.get("PATH"), "pabrik-vmd");
    return list;
}

/// `PABRIK_VM_AGENT`, then beside the manager binary. The agent is optional:
/// without one every guest runs the agent on its own disk.
pub fn agentCandidates(a: std.mem.Allocator, env: *const std.process.Environ.Map, exe_dir: ?[]const u8) !Candidates {
    var list: Candidates = .empty;
    errdefer freeCandidates(&list, a);
    if (env.get("PABRIK_VM_AGENT")) |path| try addOwned(&list, a, path);
    if (exe_dir) |dir| try addJoined(&list, a, &.{ dir, "pabrik-vm-agent" });
    return list;
}

/// `PABRIK_VM_BASE_IMAGE`, then the VM root, then the image-build default.
pub fn baseImageCandidates(a: std.mem.Allocator, env: *const std.process.Environ.Map, home: []const u8, root: []const u8) !Candidates {
    var list: Candidates = .empty;
    errdefer freeCandidates(&list, a);
    if (env.get("PABRIK_VM_BASE_IMAGE")) |path| try addOwned(&list, a, path);
    try addJoined(&list, a, &.{ root, "base.ext4" });
    try addJoined(&list, a, &.{ home, ".cache", "pabrik-vm", "images", "base.ext4" });
    return list;
}

/// `PABRIK_GUEST_KERNEL`, then the VM root, then the dev image cache.
pub fn kernelCandidates(a: std.mem.Allocator, env: *const std.process.Environ.Map, home: []const u8, root: []const u8) !Candidates {
    var list: Candidates = .empty;
    errdefer freeCandidates(&list, a);
    if (env.get("PABRIK_GUEST_KERNEL")) |path| try addOwned(&list, a, path);
    try addJoined(&list, a, &.{ root, "vmlinux" });
    try addJoined(&list, a, &.{ home, ".cache", "pabrik-vm", "vmlinux" });
    return list;
}

/// `PABRIK_FC_BIN`, then PATH, then the firecracker-demo checkout.
pub fn fcCandidates(a: std.mem.Allocator, env: *const std.process.Environ.Map, home: []const u8) !Candidates {
    var list: Candidates = .empty;
    errdefer freeCandidates(&list, a);
    if (env.get("PABRIK_FC_BIN")) |path| try addOwned(&list, a, path);
    try addOnPath(&list, a, env.get("PATH"), "firecracker");
    try addJoined(&list, a, &.{ home, "firecracker-demo", "firecracker" });
    return list;
}

/// The manager's own default: `PABRIK_VM_DIR`, else `~/.local/share/pabrik/vms`.
pub fn vmRoot(a: std.mem.Allocator, env: *const std.process.Environ.Map, home: []const u8) ![]const u8 {
    if (env.get("PABRIK_VM_DIR")) |dir| return a.dupe(u8, dir);
    return std.fs.path.join(a, &.{ home, ".local", "share", "pabrik", "vms" });
}

pub const Result = union(enum) {
    started: void,
    refused: Refusal,
};

/// Resolve, fork, wait. Never spawns outside Linux, and never leaves the caller
/// guessing: a refusal names the artifact that was missing.
pub fn ensure(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    exe_dir: ?[]const u8,
    socket_path: []const u8,
    wait_ms: u32,
) !Result {
    if (comptime builtin.os.tag != .linux) return .{ .refused = .unsupported_platform };

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try resolve(arena, io, env, exe_dir);
    switch (plan(found)) {
        .refused => |refusal| return .{ .refused = refusal },
        .spawn => |artifacts| {
            ensureDirPath(artifacts.root) catch return .{ .refused = .spawn_failed };
            const pid = spawnDetached(arena, artifacts, socket_path) orelse return .{ .refused = .spawn_failed };
            lifecycle.rememberSpawned(pid);
            std.log.info("--saas: started pabrik-vmd (pid {d}) on {s}", .{ pid, socket_path });
            if (!try waitForPing(arena, io, socket_path, wait_ms)) return .{ .refused = .never_answered };
            return .{ .started = {} };
        },
    }
}

fn resolve(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, exe_dir: ?[]const u8) !Found {
    const home = homeDir(env) orelse "";
    const root = try vmRoot(a, env, home);
    var found: Found = .{ .root = root };

    const vmd = try vmdCandidates(a, env, exe_dir);
    found.vmd = firstUsable(io, vmd.items, .{ .execute = true });

    const images = try baseImageCandidates(a, env, home, root);
    found.base_image = firstUsable(io, images.items, .{ .read = true });

    const kernels = try kernelCandidates(a, env, home, root);
    found.kernel = firstUsable(io, kernels.items, .{ .read = true });
    if (found.kernel == null) found.kernel = try scanKernel(a, io, home);

    const firecrackers = try fcCandidates(a, env, home);
    found.fc = firstUsable(io, firecrackers.items, .{ .execute = true });

    // The agent the manager serves to a guest's bootstrap. Optional: without
    // one every guest runs the agent that is on its own disk.
    const agents = try agentCandidates(a, env, exe_dir);
    found.agent = firstUsable(io, agents.items, .{ .read = true });
    return found;
}

fn homeDir(env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |home| if (home.len > 0) return home;
    if (env.get("USERPROFILE")) |home| if (home.len > 0) return home;
    return null;
}

fn firstUsable(io: std.Io, candidates: []const []const u8, options: std.Io.Dir.AccessOptions) ?[]const u8 {
    for (candidates) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;
        std.Io.Dir.accessAbsolute(io, path, options) catch continue;
        return path;
    }
    return null;
}

/// A dev box usually has a `vmlinux-<ver>` lying around; take the highest name.
fn scanKernel(a: std.mem.Allocator, io: std.Io, home: []const u8) !?[]const u8 {
    if (home.len == 0) return null;
    const dirs = [_][]const u8{
        try std.fs.path.join(a, &.{ home, ".cache", "pabrik-vm" }),
        try std.fs.path.join(a, &.{ home, "firecracker-demo" }),
    };
    var best: ?[]const u8 = null;
    var best_dir: []const u8 = "";
    for (dirs) |dir_path| {
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer std.Io.Dir.close(dir, io);
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "vmlinux")) continue;
            if (best) |current| {
                if (std.mem.order(u8, entry.name, current) != .gt) continue;
            }
            best = try a.dupe(u8, entry.name);
            best_dir = dir_path;
        }
    }
    const name = best orelse return null;
    return try std.fs.path.join(a, &.{ best_dir, name });
}

/// `mkdir -p`, one path segment at a time: the manager needs its root to exist.
fn ensureDirPath(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        buf[i] = 0;
        const rc = linux.mkdir(@ptrCast(&buf), 0o755);
        const errno = linux.errno(rc);
        if (errno != .SUCCESS and errno != .EXIST) return error.MkdirFailed;
        if (i != path.len) buf[i] = '/';
    }
}

/// `prctl(2)`'s PR_SET_PDEATHSIG: the signal the kernel sends this process
/// when its parent dies.
const pr_set_pdeathsig: i32 = 1;

/// Fork the manager into its own session, with the VM root's log on both
/// streams: a manager's stdout is never the server's.
fn spawnDetached(a: std.mem.Allocator, artifacts: Artifacts, socket_path: []const u8) ?i32 {
    var words_buf: [max_argv][]const u8 = undefined;
    const words = argvFor(artifacts, socket_path, &words_buf);
    const argv = a.allocSentinel(?[*:0]const u8, words.len, null) catch return null;
    for (words, 0..) |word, i| {
        const copy = a.dupeZ(u8, word) catch return null;
        argv[i] = copy.ptr;
    }
    const log_text = std.fmt.allocPrint(a, "{s}/vmd.log", .{artifacts.root}) catch return null;
    const log_path = a.dupeZ(u8, log_text) catch return null;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", null };

    std.log.info("--saas: launching {s} {s} {s} {s} {s} {s}", .{
        words[0], words[1], words[2], words[3], words[4], words[5],
    });
    const parent_pid = linux.getpid();
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return null;
    if (child == 0) {
        _ = linux.setsid();
        // The kernel ends the manager when the server that started it dies:
        // SIGUSR1, because the service is gone and the manager takes the
        // workspace VMs it owns down with it.
        _ = linux.prctl(pr_set_pdeathsig, @intFromEnum(linux.SIG.USR1), 0, 0, 0);
        if (linux.getppid() != parent_pid) linux.exit(0);
        _ = linux.chdir("/");
        const rc = linux.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) {
            const log_fd: linux.fd_t = @intCast(rc);
            _ = linux.dup2(log_fd, 1);
            _ = linux.dup2(log_fd, 2);
            if (log_fd > 2) _ = linux.close(log_fd);
        }
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.execve(argv[0].?, @ptrCast(argv.ptr), @ptrCast(&envp));
        linux.exit(127);
    }
    return @intCast(child);
}

fn waitForPing(a: std.mem.Allocator, io: std.Io, socket_path: []const u8, wait_ms: u32) !bool {
    var waited: u32 = 0;
    while (waited <= wait_ms) : (waited += @intCast(poll_ms)) {
        var client = vmd_client.Client.init(a, socket_path);
        client.guard_ms = ping_guard_ms;
        if (client.ping()) |version| {
            a.free(version);
            return true;
        } else |_| {}
        std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
    }
    return false;
}

// ─── the pure half, asserted on every platform ───────────────────────────

const testing = std.testing;

fn testArtifacts() Artifacts {
    return .{
        .vmd = "/opt/pabrik/pabrik-vmd",
        .base_image = "/var/lib/pabrik/base.ext4",
        .kernel = "/var/lib/pabrik/vmlinux",
        .fc = "/usr/bin/firecracker",
        .root = "/var/lib/pabrik/vms",
    };
}

test "plan: the first missing artifact is refused, and its message names the fix" {
    const full = Found{
        .vmd = testArtifacts().vmd,
        .base_image = testArtifacts().base_image,
        .kernel = testArtifacts().kernel,
        .fc = testArtifacts().fc,
        .root = testArtifacts().root,
    };
    try testing.expectEqualStrings(testArtifacts().kernel, plan(full).spawn.kernel);

    const cases = [_]struct { drop: u8, refusal: Refusal }{
        .{ .drop = 0, .refusal = .vmd_binary },
        .{ .drop = 1, .refusal = .base_image },
        .{ .drop = 2, .refusal = .kernel },
        .{ .drop = 3, .refusal = .firecracker },
    };
    for (cases) |case| {
        var found = full;
        switch (case.drop) {
            0 => found.vmd = null,
            1 => found.base_image = null,
            2 => found.kernel = null,
            else => found.fc = null,
        }
        const decision = plan(found);
        try testing.expectEqual(case.refusal, decision.refused);
        try testing.expect(std.mem.indexOf(u8, message(case.refusal), "--saas") != null);
    }
}

test "plan: every refusal is a distinct sentence" {
    const all = [_]Refusal{ .unsupported_platform, .vmd_binary, .base_image, .kernel, .firecracker, .spawn_failed, .never_answered };
    for (all, 0..) |refusal, i| {
        try testing.expect(message(refusal).len > 0);
        for (all[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, message(refusal), message(other)));
        }
    }
}

test "argvFor: program and command first, then one value per flag" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = argvFor(testArtifacts(), "/run/user/1000/pabrik-vmd.sock", &buf);
    const expected = [_][]const u8{
        "/opt/pabrik/pabrik-vmd", "serve",
        "--socket",               "/run/user/1000/pabrik-vmd.sock",
        "--base-image",           "/var/lib/pabrik/base.ext4",
        "--kernel",               "/var/lib/pabrik/vmlinux",
        "--fc",                   "/usr/bin/firecracker",
        "--root",                 "/var/lib/pabrik/vms",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, 0..) |word, i| try testing.expectEqualStrings(word, argv[i]);
}

test "argvFor: the agent is handed to the manager when there is one" {
    var buf: [max_argv][]const u8 = undefined;
    var artifacts = testArtifacts();
    artifacts.agent = "/opt/pabrik/pabrik-vm-agent";
    const argv = argvFor(artifacts, "/run/user/1000/pabrik-vmd.sock", &buf);

    try testing.expectEqual(@as(usize, 14), argv.len);
    try testing.expectEqualStrings("--agent", argv[12]);
    try testing.expectEqualStrings("/opt/pabrik/pabrik-vm-agent", argv[13]);
}

/// The candidate lists are built with `std.fs.path.join`, so the expectations
/// have to be too: a join is host-separated and a literal "/" is not a path
/// on Windows.
fn expectPath(parts: []const []const u8, actual: []const u8) !void {
    const expected = try std.fs.path.join(testing.allocator, parts);
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, actual);
}

test "agentCandidates: the env override, then the binary beside the manager" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PABRIK_VM_AGENT", "/custom/pabrik-vm-agent");

    var list = try agentCandidates(a, &env, "/opt/pabrik");
    defer freeCandidates(&list, a);

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("/custom/pabrik-vm-agent", list.items[0]);
    try expectPath(&.{ "/opt/pabrik", "pabrik-vm-agent" }, list.items[1]);
}

test "vmdCandidates: env override, beside the binary, then PATH order" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const path = try std.fmt.allocPrint(a, "/first{c}/second", .{std.fs.path.delimiter});
    defer a.free(path);
    try env.put("PATH", path);
    try env.put("PABRIK_VMD_BIN", "/custom/pabrik-vmd");

    var list = try vmdCandidates(a, &env, "/opt/pabrik");
    defer freeCandidates(&list, a);
    const expected = [_][]const []const u8{
        &.{"/custom/pabrik-vmd"},
        &.{ "/opt/pabrik", "pabrik-vmd" },
        &.{ "/first", "pabrik-vmd" },
        &.{ "/second", "pabrik-vmd" },
    };
    try testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |parts, i| try expectPath(parts, list.items[i]);
}

test "vmdCandidates: no env override means beside the binary first" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var list = try vmdCandidates(a, &env, "/opt/pabrik");
    defer freeCandidates(&list, a);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try expectPath(&.{ "/opt/pabrik", "pabrik-vmd" }, list.items[0]);
}

test "baseImageCandidates: env, VM root, then the image-build cache" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PABRIK_VM_BASE_IMAGE", "/explicit/base.ext4");

    var list = try baseImageCandidates(a, &env, "/home/dev", "/vms");
    defer freeCandidates(&list, a);
    const expected = [_][]const []const u8{
        &.{"/explicit/base.ext4"},
        &.{ "/vms", "base.ext4" },
        &.{ "/home/dev", ".cache", "pabrik-vm", "images", "base.ext4" },
    };
    try testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |parts, i| try expectPath(parts, list.items[i]);
}

test "kernelCandidates and fcCandidates: the same precedence, artifact by artifact" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PABRIK_GUEST_KERNEL", "/explicit/vmlinux");
    try env.put("PABRIK_FC_BIN", "/explicit/firecracker");

    var kernels = try kernelCandidates(a, &env, "/home/dev", "/vms");
    defer freeCandidates(&kernels, a);
    try testing.expectEqualStrings("/explicit/vmlinux", kernels.items[0]);
    try expectPath(&.{ "/vms", "vmlinux" }, kernels.items[1]);
    try expectPath(&.{ "/home/dev", ".cache", "pabrik-vm", "vmlinux" }, kernels.items[2]);

    var firecrackers = try fcCandidates(a, &env, "/home/dev");
    defer freeCandidates(&firecrackers, a);
    try testing.expectEqualStrings("/explicit/firecracker", firecrackers.items[0]);
    try expectPath(&.{ "/home/dev", "firecracker-demo", "firecracker" }, firecrackers.items[firecrackers.items.len - 1]);
}

test "vmRoot: PABRIK_VM_DIR wins over the home default the manager uses" {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    const fallback = try vmRoot(a, &env, "/home/dev");
    defer a.free(fallback);
    try expectPath(&.{ "/home/dev", ".local", "share", "pabrik", "vms" }, fallback);

    try env.put("PABRIK_VM_DIR", "/srv/pabrik/vms");
    const explicit = try vmRoot(a, &env, "/home/dev");
    defer a.free(explicit);
    try testing.expectEqualStrings("/srv/pabrik/vms", explicit);
}
