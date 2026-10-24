//! The face the admin console sees of the manager: a client for `pabrik-vmd`'s
//! socket and the limits a resize may ask for. The daemon is Linux-only, so
//! `supported` is false elsewhere and the console says so.

const builtin = @import("builtin");

pub const supported = builtin.os.tag == .linux;

pub const limits = @import("vm_limits.zig");

const vm = if (supported) @import("vmd_client.zig") else struct {
    pub const Client = void;
    pub const WorkspaceState = void;
    pub const Error = error{};
    pub const Failure = struct {
        pub fn text(_: @This()) []const u8 {
            return "";
        }
    };
};

pub const Client = vm.Client;
pub const WorkspaceState = vm.WorkspaceState;
pub const Error = vm.Error;
pub const Failure = vm.Failure;
