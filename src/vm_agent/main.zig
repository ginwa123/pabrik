//! `pabrik-vm-agent` — guest PID 1. Phase P1 scope: mount the pseudo
//! filesystems, announce itself on the serial console, answer one framed
//! `hello` over vsock, and power the VM off on `shutdown`. Exec, file RPC and
//! port forwarding land in P2; this exists so a bootable image can be proven.

const std = @import("std");
const linux = std.os.linux;

const vsock_af: u32 = 40;
const sock_stream: u32 = 1;
const cid_any: u32 = 0xFFFF_FFFF;
const agent_port: u32 = 5000;
const max_frame: usize = 4096;

const hello_json = "{\"type\":\"hello\",\"agent\":\"pabrik-vm-agent\",\"version\":\"0.1\"}";
const bye_json = "{\"type\":\"bye\"}";

/// Kernel layout: 2 + 2 + 4 + 4 bytes plus 4 of zero padding = 16.
const SockaddrVm = extern struct {
    family: u16,
    reserved: u16 = 0,
    port: u32,
    cid: u32,
    zero: [4]u8 = .{0} ** 4,
};

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
}

fn logLine(bytes: []const u8) void {
    writeAll(1, "[pabrik-vm-agent] ");
    writeAll(1, bytes);
    writeAll(1, "\n");
}

fn mountPseudo(fstype: [*:0]const u8, target: [*:0]const u8) bool {
    const rc = linux.mount("none", target, fstype, 0, 0);
    return linux.errno(rc) == .SUCCESS;
}

fn readExact(fd: linux.fd_t, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn writeFrame(fd: linux.fd_t, payload: []const u8) void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    writeAll(fd, &header);
    writeAll(fd, payload);
}

fn powerOff() noreturn {
    const magic1: usize = 0xfee1dead;
    const magic2: usize = 672274793;
    const cmd_power_off: usize = 0x4321fedc;
    _ = linux.syscall3(.reboot, magic1, magic2, cmd_power_off);
    linux.exit(0);
}

/// Framed requests until `shutdown`. `hello` is answered; anything else gets
/// an error frame, so a wrong request is visible rather than a dropped peer.
fn serve(conn_fd: linux.fd_t) void {
    while (true) {
        var header: [4]u8 = undefined;
        if (!readExact(conn_fd, &header)) return;
        const len = std.mem.readInt(u32, &header, .big);
        if (len == 0 or len > max_frame) return;

        var payload: [max_frame]u8 = undefined;
        if (!readExact(conn_fd, payload[0..len])) return;
        const request = payload[0..len];

        if (std.mem.indexOf(u8, request, "shutdown") != null) {
            writeFrame(conn_fd, bye_json);
            // Close the write side so the muxer forwards the frame before the
            // VM disappears; powering off first loses it.
            _ = linux.shutdown(conn_fd, 1);
            logLine("shutdown requested");
            powerOff();
        }
        if (std.mem.indexOf(u8, request, "hello") != null) {
            writeFrame(conn_fd, hello_json);
            logLine("answered hello over vsock");
            continue;
        }
        writeFrame(conn_fd, "{\"type\":\"error\",\"message\":\"unknown request\"}");
    }
}

pub fn main() void {
    writeAll(1, "\n[pabrik-vm-agent] booting as PID 1\n");
    // Logged one per line: P2 needs to know exactly which of these the guest
    // kernel supports (PTY support, for instance, needs devtmpfs and devpts).
    logLine(if (mountPseudo("proc", "/proc")) "mounted proc" else "MISSING proc");
    logLine(if (mountPseudo("sysfs", "/sys")) "mounted sysfs" else "MISSING sysfs");
    logLine(if (mountPseudo("devtmpfs", "/dev")) "mounted devtmpfs" else "MISSING devtmpfs");

    const sock_rc = linux.socket(vsock_af, sock_stream, 0);
    if (linux.errno(sock_rc) != .SUCCESS) {
        logLine("vsock socket failed");
        powerOff();
    }
    const listen_fd: linux.fd_t = @intCast(sock_rc);

    var addr = SockaddrVm{ .family = vsock_af, .port = agent_port, .cid = cid_any };
    if (linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) != .SUCCESS) {
        logLine("vsock bind failed");
        powerOff();
    }
    if (linux.errno(linux.listen(listen_fd, 4)) != .SUCCESS) {
        logLine("vsock listen failed");
        powerOff();
    }
    logLine("listening on vsock port 5000");

    var peer: SockaddrVm = undefined;
    var peer_len: linux.socklen_t = @sizeOf(SockaddrVm);
    const conn_rc = linux.accept(listen_fd, @ptrCast(&peer), &peer_len);
    if (linux.errno(conn_rc) != .SUCCESS) {
        logLine("vsock accept failed");
        powerOff();
    }
    logLine("vsock connection accepted");
    serve(@intCast(conn_rc));
    powerOff();
}
