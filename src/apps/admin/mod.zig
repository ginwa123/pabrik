//! The admin console: a static page plus the endpoints behind it. The owner
//! can list accounts, create them, change their role, switch them off and
//! reset a password: the "forgot password" case.

pub const admin_common = @import("admin_common.zig");
pub const runtime = @import("runtime.zig");
pub const admin_store = @import("admin_store.zig");
pub const admin_api = @import("admin_api.zig");
pub const admin_page = @import("admin_page.zig");
pub const admin_machines = @import("admin_machines.zig");

pub const adminOverviewHandler = admin_api.adminOverviewHandler;
pub const adminUsersListHandler = admin_api.adminUsersListHandler;
pub const adminUserCreateHandler = admin_api.adminUserCreateHandler;
pub const adminUserUpdateHandler = admin_api.adminUserUpdateHandler;
pub const adminUserPasswordHandler = admin_api.adminUserPasswordHandler;

pub const adminVmsListHandler = admin_machines.listHandler;
pub const adminVmResizeHandler = admin_machines.resizeHandler;

pub const adminPageHandler = admin_page.adminPageHandler;
pub const adminCssHandler = admin_page.adminCssHandler;
pub const adminJsHandler = admin_page.adminJsHandler;

test {
    // The console's own tests, for `zig build test` inside this folder.
    _ = admin_common;
    _ = admin_store;
    _ = admin_api;
    _ = admin_page;
    _ = admin_machines;
    _ = runtime;
}
