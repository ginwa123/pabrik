//! `pabrik-vmd` — the VM manager. P2a scope: one process that boots a
//! workspace's VM, runs a command in it, prints the result and stops it.
//! The socket-facing daemon (workspace_id-only RPC, SO_PEERCRED) is P2b.

const std = @import("std");
const linux = std.os.linux;
const vm_client = @import("vm_client.zig");

const usage =
    \\usage: pabrik-vmd run --workspace-id ID --base-image IMG --kernel K [options] -- <argv...>
    \\
    \\  --workspace-id ID   the only identifier the manager takes; every path for
    \\                      this workspace is derived from it
    \\  --base-image IMG    sealed base ext4 image, cloned per workspace
    \\  --kernel K          guest kernel (ELF vmlinux)
    \\  --fc BIN            firecracker binary (default: firecracker from PATH)
    \\  --root DIR          VM root (default: $PABRIK_VM_DIR, else ~/.local/share/pabrik/vms)
    \\  --mem MIB           guest memory (default 512)
    \\  --cwd DIR           working directory inside the guest (default /workspace)
    \\  --timeout-ms N      per-command deadline (default 10000)
    \\
;

const Options = struct {
    workspace_id: []const u8 = "",
    base_image: []const u8 = "",
    kernel: []const u8 = "",
    fc_bin: []const u8 = "firecracker",
    root: []const u8 = "",
    mem_mib: u32 = vm_client.default_mem_mib,
    cwd: []const u8 = "/workspace",
    timeout_ms: u32 = 10_000,
    command: []const []const u8 = &.{},
};

/// Raw writes: this binary runs before any Io runtime is set up.
fn emit(fd: linux.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var off: usize = 0;
    while (off < text.len) {
        const rc = linux.write(fd, text.ptr + off, text.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
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

fn parseArgs(args: []const []const u8) Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "run")) continue;
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
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            options.cwd = valueAt(args, i);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--mem")) {
            options.mem_mib = std.fmt.parseInt(u32, valueAt(args, i), 10) catch fail("--mem wants a number", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            options.timeout_ms = std.fmt.parseInt(u32, valueAt(args, i), 10) catch fail("--timeout-ms wants a number", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            emit(1, "{s}", .{usage});
            std.process.exit(0);
        } else {
            fail("unknown argument: {s}", .{arg});
        }
    }
    return options;
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

    var options = parseArgs(argv.items);
    if (options.workspace_id.len == 0) fail("--workspace-id is required", .{});
    if (options.base_image.len == 0) fail("--base-image is required", .{});
    if (options.kernel.len == 0) fail("--kernel is required", .{});
    if (options.command.len == 0) fail("no command given (put it after --)", .{});
    if (options.root.len == 0) {
        if (init.environ_map.get("PABRIK_VM_DIR")) |dir| {
            options.root = dir;
        } else {
            const home = init.environ_map.get("HOME") orelse fail("HOME is not set; pass --root", .{});
            options.root = try std.fmt.allocPrint(aa, "{s}/.local/share/pabrik/vms", .{home});
        }
    }

    var vm = vm_client.boot(allocator, .{
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
        const excerpt = vm_client.readSerialExcerpt(aa, vm.layout, 1024) catch "";
        emit(2, "pabrik-vmd: guest never became ready: {s}\n{s}\n", .{ @errorName(err), excerpt });
        vm_client.stop(&vm);
        vm.deinit();
        std.process.exit(1);
    };

    const result = vm_client.exec(allocator, vm.layout, .{
        .argv = options.command,
        .cwd = options.cwd,
        .timeout_ms = options.timeout_ms,
    }) catch |err| {
        const excerpt = vm_client.readSerialExcerpt(aa, vm.layout, 2048) catch "";
        emit(2, "pabrik-vmd: exec failed: {s}\n--- guest serial ---\n{s}\n", .{ @errorName(err), excerpt });
        vm_client.stop(&vm);
        vm.deinit();
        std.process.exit(1);
    };
    defer result.deinit(allocator);

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
