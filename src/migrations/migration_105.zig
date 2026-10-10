const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;

/// Migration 105 - create `workspace_settings`, the per-workspace config
/// overlay.
///
/// One row per (owner, workspace_id) holding a SPARSE JSON overlay over the
/// user-level config: the keys present in `config_json` win, every other key
/// keeps its user-level value. That is what makes "Profiles / MCP Servers /
/// Tools / Skill Evals live in Workspace settings" honest - two workspaces
/// can run different profiles without editing one global file.
///
/// Three deliberate choices, each pinned by a test in `migration.zig`:
///
///   1. `config_json` is NULLABLE. "No overlay" is spelled as an ABSENT row
///      (see `workspace_settings_store.clear`), and a NULL column reads as
///      the same thing, so a hand-edited database degrades to "inherit"
///      rather than to a crash. NOT NULL would also be a trap: this backend
///      binds an empty slice as SQL NULL, so a writer that cleared the
///      overlay would hit a constraint error instead of inheriting.
///
///   2. The PRIMARY KEY is `(owner, workspace_id)`, not `workspace_id`. In
///      file mode `owner` is `''` and there is one overlay per workspace.
///      With `--auth` ON a workspace is shared between users, and keying on
///      the workspace alone would hand every user's profiles - and the API
///      keys inside them - to every other member of that workspace. The
///      composite key is the same isolation boundary `users.config_json`
///      already draws one level up.
///
///   3. The FOREIGN KEY is documentation. This project runs with
///      `PRAGMA foreign_keys` OFF, so the cascade never fires;
///      `workspace_delete.zig` deletes these rows explicitly in the same
///      transaction that removes the workspace, exactly like it does for
///      `workspace_secrets`.
pub const Migration105CreateWorkspaceSettings = struct {
    pub const version: u32 = 105;
    pub const name = "create_workspace_settings";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_settings (
            \\    owner TEXT NOT NULL DEFAULT '',
            \\    workspace_id TEXT NOT NULL,
            \\    config_json TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    PRIMARY KEY (owner, workspace_id),
            \\    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
    }
};
