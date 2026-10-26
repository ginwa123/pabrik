const std = @import("std");

pub const vsock_af: u32 = 40;
pub const cid_host: u32 = 2;
pub const cid_any: u32 = 0xFFFF_FFFF;

pub const agent_port: u32 = 5000;
pub const egress_port: u32 = 5001;
pub const resolver_port: u32 = 5002;
pub const agent_service_port: u32 = 5003;

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
}
