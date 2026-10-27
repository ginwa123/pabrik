const std = @import("std");

pub const vsock_af: u32 = 40;
pub const cid_host: u32 = 2;
pub const cid_any: u32 = 0xFFFF_FFFF;

pub const agent_port: u32 = 5000;
pub const egress_port: u32 = 5001;
pub const resolver_port: u32 = 5002;
pub const agent_service_port: u32 = 5003;

/// A guest duplex (one MCP server's two byte streams) answers on its OWN
/// port, so a read that waits never queues behind a long `exec`.
pub const duplex_port_base: u32 = 5200;
pub const max_duplex: u32 = 8;
/// One read or write piece. A reply this size always fits one frame once
/// base64-encoded, which `encodedReplyFits` below proves at compile time.
pub const max_duplex_chunk: usize = 32 * 1024;

pub const max_frame: usize = 64 * 1024;
pub const reply_envelope_bytes: usize = 512;
pub const max_reply_chunk: usize = ((max_frame - reply_envelope_bytes) / 4) * 3;

pub fn encodedReplyFits(raw: usize) bool {
    return std.base64.standard.Encoder.calcSize(raw) + reply_envelope_bytes <= max_frame;
}

pub fn frameHeader(payload_len: usize, out: *[4]u8) void {
    std.mem.writeInt(u32, out, @intCast(payload_len), .big);
}

pub fn framePayloadLen(header: *const [4]u8) usize {
    return std.mem.readInt(u32, header, .big);
}

comptime {
    if (!encodedReplyFits(max_reply_chunk)) {
        @compileError("vm_wire.max_reply_chunk does not fit one frame once base64-encoded");
    }
    if (!encodedReplyFits(max_duplex_chunk)) {
        @compileError("vm_wire.max_duplex_chunk does not fit one frame once base64-encoded");
    }
}
