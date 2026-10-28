const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration077AddUsersAndRbacSchema = struct {
    pub const version: u32 = 77;
    pub const name = "add_users_and_rbac_schema";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // tx (db.begin/tx.exec/tx.commit) — atomic; see "Why the tx" in the
        // docstring above.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // 1. users — identity table.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id TEXT PRIMARY KEY,
            \\    email TEXT NOT NULL UNIQUE,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    password_hash TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'bot')),
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    last_login_at TIMESTAMP DEFAULT NULL
            \\)
        , &[_][]const u8{});

        // 2. user_companies — org / tenant entity.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_companies (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    slug TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    is_active INTEGER NOT NULL DEFAULT 1,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    created_by TEXT
            \\)
        , &[_][]const u8{});

        // 3. user_company_members — many-to-many user ↔ company.
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS user_company_members (
            \\    user_id TEXT NOT NULL,
            \\    user_company_id TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'guest')),
            \\    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    invited_by TEXT,
            \\    PRIMARY KEY (user_id, user_company_id)
            \\)
        , &[_][]const u8{});

        // 4. workspaces.user_id — additive, nullable, no FK.
        try addColumnIfMissing(
            .{ .tx = &tx },
            allocator,
            "workspaces",
            "user_id",
            "user_id TEXT",
        );

        // 5. sessions.user_id — same shape as workspaces.user_id.
        try addColumnIfMissing(
            .{ .tx = &tx },
            allocator,
            "sessions",
            "user_id",
            "user_id TEXT",
        );

        // 6. Indexes — 6 total. CREATE INDEX IF NOT EXISTS is idempotent.
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_slug ON user_companies(slug)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_companies_active ON user_companies(is_active)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_user ON user_company_members(user_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_user_company_members_company ON user_company_members(user_company_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id)",
            &[_][]const u8{});
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)",
            &[_][]const u8{});

        // 7. Default user_system — the conflict clause makes it idempotent.
        //    See the spec §3.6 for the full reasoning (password_hash
        //    sentinel, is_active=0, system@local reserved per RFC 6762).
        try tx.exec(allocator,
            dialect.insert_ignore_prefix ++
                " INTO users (id, email, name, password_hash, role, is_active) " ++
                "VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)" ++
                dialect.conflict_ignore,
            &[_][]const u8{});

        // 8. Backfill — convert every legacy row (workspaces, sessions) WHERE
        // user_id IS NULL to user_id='user_system'.
        try tx.exec(allocator,
            "UPDATE workspaces SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});
        try tx.exec(allocator,
            "UPDATE sessions SET user_id = 'user_system' WHERE user_id IS NULL",
            &[_][]const u8{});

        // Commit the transaction. After this, the new schema is durable.
        try tx.commit();

        // Refresh query-planner stats so the new indexes are picked on
        // pre-existing databases (mirrors the ANALYZE-after-CREATE-INDEX
        // pattern used by Migrations 041/042/043/048/049/050/051/052/070/072).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
