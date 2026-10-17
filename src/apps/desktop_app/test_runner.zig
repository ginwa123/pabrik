// src/apps/desktop_app/test_runner.zig Test discovery for the desktop-app
// test step.

test {
    _ = @import("port.zig");
    _ = @import("cli.zig");
    _ = @import("browser.zig");
    _ = @import("path_resolve.zig");
    _ = @import("subprocess.zig");
    _ = @import("extraction.zig");
    _ = @import("webview_lib.zig");
    _ = @import("attach.zig");
    _ = @import("tray.zig");
}
