//! The guest↔host vsock contract, in one place: the ports each side owns, the
//! frame ceiling both ends enforce, and the reply budget that follows from it.
//! `src/vm_agent` and `src/vmd` both import this, and neither re-declares it.

const std = @import("std");

/// The address family of the guest↔host transport (`AF_VSOCK`).
pub const vsock_af: u32 = 40;
/// virtio-vsock's host CID; a guest listener binds `cid_any` instead.
pub const cid_host: u32 = 2;
pub const cid_any: u32 = 0xFFFF_FFFF;

/// The guest's listener: the daemon dials it to run one command in a workspace.
pub const agent_port: u32 = 5000;
/// The guest's two dials out: the network forwarder's egress and resolver.
pub const egress_port: u32 = 5001;
pub const resolver_port: u32 = 5002;
/// The host's dial back in: a guest's `/init` asks for the current agent.
pub const agent_service_port: u32 = 5003;

/// One framed JSON payload, each way: four big-endian length bytes, then the
/// payload. A reader refuses a longer one, so a writer must never make one.
pub const max_frame: usize = 64 * 1024;

/// The JSON around a reply's bytes — `{"type":"fs.read","id":1,…}` — plus slack.
pub const reply_envelope_bytes: usize = 512;

/// The most raw bytes one reply may carry. Base64 pays 4 bytes per 3, so 48 KiB
/// of bytes encode to a whole frame and leave the envelope no room; this is the
/// largest whole KiB that still fits both.
pub const max_reply_chunk: usize = 47 * 1024;

/// Whether `raw` bytes, base64-encoded and wrapped, still fit one frame.
pub fn encodedReplyFits(raw: usize) bool {
    return std.base64.standard.Encoder.calcSize(raw) + reply_envelope_bytes <= max_frame;
}

/// One frame's length prefix, as both ends write it.
pub fn frameHeader(payload_len: usize, out: *[4]u8) void {
    std.mem.writeInt(u32, out, @intCast(payload_len), .big);
}

/// The payload length a frame's header announces.
pub fn framePayloadLen(header: *const [4]u8) usize {
    return std.mem.readInt(u32, header, .big);
}

// The reply budget is the whole point of this file, so breaking it is a build
// error and not a test: `src/vm_agent`'s `fs.read` chunk used to be 64 KiB.
comptime {
    if (!encodedReplyFits(max_reply_chunk)) {
        @compileError("vm_wire.max_reply_chunk does not fit one frame once encoded");
    }
}
