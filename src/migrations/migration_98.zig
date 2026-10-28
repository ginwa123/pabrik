const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration098CreateDocuments = struct {
    pub const version: u32 = 98;
    pub const name = "create_documents";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS documents (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    format TEXT NOT NULL DEFAULT 'markdown',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        // Every read is `WHERE workspace_id = ?` — the sidebar section, the
        // cross-workspace guard on every single-document read, and the agent
        // tools' own scope check.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_documents_workspace_id ON documents(workspace_id)",
            &[_][]const u8{});

        // Sidebar ordering: newest-updated first within a workspace, which
        // is what the DocumentsList component renders.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_documents_workspace_updated
            \\ON documents(workspace_id, updated_at DESC)
        , &[_][]const u8{});
    }
};
