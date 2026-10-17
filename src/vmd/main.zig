//! `pabrik-vmd` — the VM manager. `run` boots a workspace's VM for one command
//! and stops it; `serve` is the daemon the Pabrik server calls over a unix
//! socket. Every path comes from the workspace id, never from the caller.

const std = @import("std");
const linux = std.os.linux;
const vm_client = @import("vm_client.zig");
const vmd_client = @import("vmd_client.zig");
const daemon = @import("daemon.zig");
const policy = @import("policy.zig");
const reconciler = @import("reconciler.zig");
const rpc = @import("rpc.zig");

const usage =
    \\usage: pabrik-vmd <command> [options]
    \\
    \\  run     --workspace-id ID --base-image IMG --kernel K [--fc BIN] [-- <argv...>]
    \\  serve   --socket PATH --base-image IMG --kernel K [--root DIR] [--allowed-uid N]
    \\  ping    --socket PATH
    \\  exec    --socket PATH --workspace-id ID [--cwd-rel R] [--timeout-ms N] -- <argv...>
    \\  status  --socket PATH --workspace-id ID
    \\  stop    --socket PATH --workspace-id ID
    \\  spawn   --socket PATH --workspace-id ID [--cwd-rel R] [--log-name NAME] -- <argv...>
    \\  probe   --socket PATH --workspace-id ID --pid N
    \\  signal  --socket PATH --workspace-id ID --pid N [--signal N]
    \\  log     --socket PATH --workspace-id ID --log-name NAME [--offset N] [--max-bytes N]
    \\
    \\  --workspace-id ID    the only identifier the manager takes; every path for
    \\                       this workspace is derived from it
    \\  --base-image IMG     sealed base ext4 image, cloned per workspace
    \\  --kernel K           guest kernel (ELF vmlinux)
    \\  --fc BIN             firecracker binary (default: firecracker from PATH)
    \\  --root DIR           VM root (default: $PABRIK_VM_DIR, else ~/.local/share/pabrik/vms)
    \\  --socket PATH        daemon socket (default: $PABRIK_VMD_SOCKET)
    \\  --allowed-uid N      uid the daemon accepts (default: its own)
    \\  --sweep-interval-ms N  how often every workspace is reconciled (default 15000, 0 = off)
    \\  --backoff-base-ms N  first retry delay after a failed boot (default 1000)
    \\  --mem MIB            guest memory (default 512)
    \\  --cwd DIR            working directory inside the guest for `run` (default /workspace)
    \\  --cwd-rel R          workspace-relative directory for `exec` (default: the root)
    \\  --timeout-ms N       per-command deadline (default 10000)
    \\  --max-output-bytes N captured bytes per stream (default 256 KiB)
    \\  --log-name NAME      a detached job's log NAME (the daemon owns the path)
    \\  --pid N              the guest pid a `spawn` reported
    \\  --signal N           signal number for `signal` (default 9)
    \\  --offset N           byte offset for `log` (default 0)
    \\  --max-bytes N        bytes for `log` to return (default 16 KiB)
    \\
;

const Options = struct {
    workspace_id: []const u8 = "",
    base_image: []const u8 = "",
    kernel: []const u8 = "",
    fc_bin: []const u8 = "firecracker",
    root: []const u8 = "",
    socket: []const u8 = "",
    allowed_uid: ?u32 = null,
    mem_mib: u32 = vm_client.default_mem_mib,
    cwd: []const u8 = policy.guest_root,
    cwd_rel: []const u8 = "",
    timeout_ms: u32 = rpc.default_timeout_ms,
    max_output_bytes: usize = rpc.default_max_output_bytes,
    sweep_interval_ms: u32 = reconciler.default_sweep_interval_ms,
    backoff_base_ms: i64 = reconciler.default_backoff_base_ms,
    log_name: []const u8 = "",
    pid: i64 = 0,
    sig: i64 = 9,
    offset: i64 = 0,
    max_bytes: usize = rpc.default_max_log_bytes,
    command: []const []const u8 = &.{},
};

/// Raw writes: this binary runs before any Io runtime is set up.
fn emit(fd: linux.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeRaw(fd, text);
}

/// Unbounded writes for command output (never through the 4 KiB formatter).
fn writeRaw(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    emit(2, "pabrik-vmd: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn valueAt(args: []const []const u8, index: usize) []const u8 {
    if (index + 1 >= args.len) fail("{s} needs a value", .{args[index]});
    return args[index + 1];
}

fn number(comptime T: type, name: []const u8, text: []const u8) T {
    return std.fmt.parseInt(T, text, 10) catch fail("{s} wants a number", .{name});
}

fn parse(args: []const []const u8, options: *Options) void {
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command = args[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "--workspace-id")) {
            options.workspace_id = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--base-image")) {
            options.base_image = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            options.kernel = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fc")) {
            options.fc_bin = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--root")) {
            options.root = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            options.socket = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--allowed-uid")) {
            options.allowed_uid = number(u32, "--allowed-uid", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            options.cwd = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cwd-rel")) {
            options.cwd_rel = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--mem")) {
            options.mem_mib = number(u32, "--mem", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            options.timeout_ms = number(u32, "--timeout-ms", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--max-output-bytes")) {
            options.max_output_bytes = number(usize, "--max-output-bytes", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--sweep-interval-ms")) {
            options.sweep_interval_ms = number(u32, "--sweep-interval-ms", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-name")) {
            options.log_name = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--pid")) {
            options.pid = number(i64, "--pid", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--signal")) {
            options.sig = number(i64, "--signal", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            options.offset = number(i64, "--offset", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            options.max_bytes = number(usize, "--max-bytes", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--backoff-base-ms")) {
            options.backoff_base_ms = number(i64, "--backoff-base-ms", valueAt(args, i));
            i += 1;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            emit(1, "{s}", .{usage});
            std.process.exit(0);
        } else {
            fail("unknown argument: {s}", .{arg});
        }
    }
    if (!cwdInsideWorkspace(options.cwd)) {
        fail("--cwd must be {s} or a directory under it, got {s}", .{ policy.guest_root, options.cwd });
    }
}

/// `run` boots one VM for one command, so its cwd is a guest path. Allowing an
/// arbitrary one would hand the VMM a working directory outside the workspace.
fn cwdInsideWorkspace(cwd: []const u8) bool {
    if (std.mem.eql(u8, cwd, policy.guest_root)) return true;
    return policy.relativeToRoot(policy.guest_root, cwd) != null;
}

fn resolveRoot(init: std.process.Init, options: *Options, arena: std.mem.Allocator) void {
    if (options.root.len > 0) return;
    if (init.environ_map.get("PABRIK_VM_DIR")) |dir| {
        options.root = dir;
        return;
    }
    const home = init.environ_map.get("HOME") orelse fail("HOME is not set; pass --root", .{});
    options.root = std.fmt.allocPrint(arena, "{s}/.local/share/pabrik/vms", .{home}) catch
        fail("out of memory", .{});
}

fn resolveSocket(init: std.process.Init, options: *Options) void {
    if (options.socket.len > 0) return;
    options.socket = init.environ_map.get("PABRIK_VMD_SOCKET") orelse
        fail("--socket is required (or set PABRIK_VMD_SOCKET)", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (args_iter.next()) |arg| try argv.append(allocator, arg);

    if (argv.items.len < 2) {
        emit(2, "{s}", .{usage});
        std.process.exit(2);
    }
    const command = argv.items[1];
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        emit(1, "{s}", .{usage});
        std.process.exit(0);
    }

    var options = Options{};
    parse(argv.items, &options);

    if (std.mem.eql(u8, command, "run")) return run(init, aa, &options);
    if (std.mem.eql(u8, command, "serve")) return serve(init, aa, &options);
    if (std.mem.eql(u8, command, "ping")) return ping(init, aa, &options);
    if (std.mem.eql(u8, command, "exec")) return execCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "status")) return statusCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "stop")) return stopCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "spawn")) return spawnCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "probe")) return probeCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "signal")) return signalCommand(init, aa, &options);
    if (std.mem.eql(u8, command, "log")) return logCommand(init, aa, &options);
    fail("unknown command: {s}\n{s}", .{ command, usage });
}

fn run(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    if (options.workspace_id.len == 0) fail("--workspace-id is required", .{});
    if (options.base_image.len == 0) fail("--base-image is required", .{});
    if (options.kernel.len == 0) fail("--kernel is required", .{});
    if (options.command.len == 0) fail("no command given (put it after --)", .{});
    resolveRoot(init, options, arena);

    var vm = vm_client.boot(arena, .{
        .workspace_id = options.workspace_id,
        .base_image = options.base_image,
        .kernel = options.kernel,
        .fc_bin = options.fc_bin,
        .root = options.root,
        .mem_mib = options.mem_mib,
    }) catch |err| {
        emit(2, "pabrik-vmd: boot failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    emit(2, "pabrik-vmd: vm up (pid={d}) disk={s}\n", .{ vm.pid, vm.layout.disk });

    vm_client.waitReady(vm.layout, vm_client.boot_timeout_ms) catch |err| {
        const excerpt = vm_client.readSerialExcerpt(arena, vm.layout, 1024) catch "";
        emit(2, "pabrik-vmd: guest never became ready: {s}\n{s}\n", .{ @errorName(err), excerpt });
        vm_client.stop(&vm);
        vm.deinit();
        std.process.exit(1);
    };

    const result = vm_client.exec(arena, vm.layout, .{
        .argv = options.command,
        .cwd = options.cwd,
        .timeout_ms = options.timeout_ms,
    }) catch |err| {
        const excerpt = vm_client.readSerialExcerpt(arena, vm.layout, 2048) catch "";
        emit(2, "pabrik-vmd: exec failed: {s}\n--- guest serial ---\n{s}\n", .{ @errorName(err), excerpt });
        vm_client.stop(&vm);
        vm.deinit();
        std.process.exit(1);
    };
    defer result.deinit(arena);

    writeRaw(1, result.stdout);
    writeRaw(2, result.stderr);
    emit(2, "pabrik-vmd: exit={d} timed_out={} truncated={} stdout={d}B stderr={d}B\n", .{
        result.code,
        result.timed_out,
        result.truncated,
        result.stdout.len,
        result.stderr.len,
    });

    vm_client.stop(&vm);
    vm.deinit();
    if (result.code != 0) std.process.exit(1);
}

fn serve(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    if (options.base_image.len == 0) fail("--base-image is required", .{});
    if (options.kernel.len == 0) fail("--kernel is required", .{});
    resolveRoot(init, options, arena);
    resolveSocket(init, options);

    emit(2, "pabrik-vmd: serving on {s} (root={s})\n", .{ options.socket, options.root });
    daemon.serve(init.gpa, .{
        .socket_path = options.socket,
        .base_image = options.base_image,
        .kernel = options.kernel,
        .root = options.root,
        .fc_bin = options.fc_bin,
        .mem_mib = options.mem_mib,
        .allowed_uid = options.allowed_uid,
        .sweep_interval_ms = options.sweep_interval_ms,
        .backoff_base_ms = options.backoff_base_ms,
    }) catch |err| {
        emit(2, "pabrik-vmd: serve failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    emit(2, "pabrik-vmd: stopped\n", .{});
}

fn requireWorkspace(options: *const Options) void {
    if (options.workspace_id.len == 0) fail("--workspace-id is required", .{});
    if (!policy.workspaceIdValid(options.workspace_id)) {
        fail("--workspace-id is not a workspace id: {s}", .{options.workspace_id});
    }
}

fn ping(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    var client = vmd_client.Client.init(init.gpa, options.socket);
    const version = client.ping() catch reportClientError(&client);
    defer init.gpa.free(version);
    emit(1, "pabrik-vmd {s}\n", .{version});
}

fn statusCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    var client = vmd_client.Client.init(init.gpa, options.socket);
    const state = client.status(options.workspace_id) catch reportClientError(&client);
    defer state.deinit(init.gpa);
    if (state.last_error.len > 0) {
        emit(1, "{s} pid={d} error=\"{s}\"\n", .{ state.state, state.pid, state.last_error });
    } else {
        emit(1, "{s} pid={d}\n", .{ state.state, state.pid });
    }
}

fn stopCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    var client = vmd_client.Client.init(init.gpa, options.socket);
    client.stop(options.workspace_id) catch reportClientError(&client);
    emit(1, "stopped {s}\n", .{options.workspace_id});
}

/// `spawn` needs a log name; the daemon derives the path from it.
fn requireLogName(options: *const Options) void {
    if (options.log_name.len == 0) fail("--log-name is required", .{});
    if (!policy.logNameValid(options.log_name)) {
        fail("--log-name is not a log name: {s}", .{options.log_name});
    }
}

fn spawnCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    requireLogName(options);
    if (options.command.len == 0) fail("no command given (put it after --)", .{});

    var client = vmd_client.Client.init(init.gpa, options.socket);
    const spawned = client.spawn(.{
        .workspace_id = options.workspace_id,
        .argv = options.command,
        .cwd_rel = options.cwd_rel,
        .log_name = options.log_name,
    }) catch reportClientError(&client);
    defer spawned.deinit(init.gpa);
    emit(1, "pid={d} log={s}\n", .{ spawned.pid, spawned.log_path });
}

fn probeCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    if (options.pid <= 0) fail("--pid is required", .{});

    var client = vmd_client.Client.init(init.gpa, options.socket);
    const probed = client.probe(options.workspace_id, options.pid) catch reportClientError(&client);
    defer probed.deinit(init.gpa);
    emit(1, "alive={s} state={s} boot_pid={d}\n", .{
        if (probed.alive) "true" else "false",
        probed.state,
        probed.boot_pid,
    });
}

fn signalCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    if (options.pid <= 0) fail("--pid is required", .{});

    var client = vmd_client.Client.init(init.gpa, options.socket);
    client.signal(options.workspace_id, options.pid, options.sig) catch reportClientError(&client);
    emit(1, "signalled pid={d} signal={d}\n", .{ options.pid, options.sig });
}

fn logCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    requireLogName(options);

    var client = vmd_client.Client.init(init.gpa, options.socket);
    const chunk = client.readLog(
        options.workspace_id,
        options.log_name,
        options.offset,
        options.max_bytes,
    ) catch reportClientError(&client);
    defer chunk.deinit(init.gpa);

    writeRaw(1, chunk.bytes);
    emit(2, "pabrik-vmd: bytes={d} size={d} eof={} missing={}\n", .{
        chunk.bytes.len,
        chunk.size,
        chunk.eof,
        chunk.missing,
    });
}

fn execCommand(init: std.process.Init, arena: std.mem.Allocator, options: *Options) !void {
    _ = arena;
    resolveSocket(init, options);
    requireWorkspace(options);
    if (options.command.len == 0) fail("no command given (put it after --)", .{});

    var client = vmd_client.Client.init(init.gpa, options.socket);
    const outcome = client.exec(.{
        .workspace_id = options.workspace_id,
        .argv = options.command,
        .cwd_rel = options.cwd_rel,
        .timeout_ms = options.timeout_ms,
        .max_output_bytes = options.max_output_bytes,
    }) catch reportClientError(&client);
    defer outcome.deinit(init.gpa);

    writeRaw(1, outcome.stdout);
    writeRaw(2, outcome.stderr);
    emit(2, "pabrik-vmd: exit={d} timed_out={} truncated={} stdout={d}B stderr={d}B\n", .{
        outcome.code,
        outcome.timed_out,
        outcome.truncated,
        outcome.stdout.len,
        outcome.stderr.len,
    });
    if (outcome.code != 0) std.process.exit(1);
}

/// A refused call must name the daemon's reason, not just an error enum.
fn reportClientError(client: *const vmd_client.Client) noreturn {
    if (client.lastFailure()) |failure| {
        emit(2, "pabrik-vmd: refused: {s}: {s}\n", .{ failure.code.name(), failure.text() });
        std.process.exit(3);
    }
    emit(2, "pabrik-vmd: call failed\n", .{});
    std.process.exit(1);
}

// `zig test` only reaches a file's `test` blocks through a reference from the
// test root, and this binary is the root of the vmd suite.
test {
    _ = @import("policy.zig");
    _ = @import("reconciler.zig");
    _ = @import("rpc.zig");
    _ = @import("vmd_client.zig");
    _ = @import("daemon.zig");
    _ = @import("vm_client.zig");
}
