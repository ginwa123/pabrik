// src/service/mod.zig Re-exports every module in the `pabrik service
// {start,stop,status,restart}` lifecycle + crash reporting cluster. ## Why a
// single mod.zig All five modules exist for one purpose: make `pabrik`

pub const daemon = @import("daemon.zig");
pub const signal_handlers = @import("signal_handlers.zig");
pub const state_file = @import("state_file.zig");
pub const main_service = @import("main_service.zig");
pub const crash_handler = @import("crash_handler.zig");