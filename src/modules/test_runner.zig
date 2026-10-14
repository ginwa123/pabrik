// Test discovery for the `src/modules/` tree.

test {
    _ = @import("static_files.zig");
    _ = @import("system_folder/system_folder.zig");
    _ = @import("../service/state_file.zig");
    _ = @import("../service/daemon.zig");
    _ = @import("../service/signal_handlers.zig");
    _ = @import("../service/main_service.zig");
}
