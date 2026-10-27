const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration054MakeSessionQueueMessageNullable = struct {
    pub const version: u32 = 54;
    pub const name = "make_session_queue_messages_message_nullable";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Detect whether image_url column exists (added in Migration 037).
        const has_image_url = blk: {
            var q = try db.query(allocator,
                "SELECT 1 FROM pragma_table_info('session_queue_messages') " ++
                "WHERE name = 'image_url' LIMIT 1",
                &[_][]const u8{},
            );
            defer q.deinit();
            if (try q.next()) |row| {
                defer row.deinit(allocator);
                break :blk true;
            }
            break :blk false;
        };

        // 2. Rename existing table out of the way.
        try db.exec(allocator,
            "ALTER TABLE session_queue_messages " ++
            "RENAME TO _session_queue_messages_old",
            &[_][]const u8{},
        );

        // 3. Recreate with `message` nullable (the actual fix).
        try db.exec(allocator,
            \\CREATE TABLE session_queue_messages (
            \\    id TEXT NOT NULL,
            \\    session_id TEXT NOT NULL,
            \\    message TEXT,
            \\    image_url TEXT,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 4. Copy all existing rows. The image_url column defaults to NULL
        //    on DBs that pre-date Migration 037 (which is harmless — the
        //    application treats NULL and "" identically on read).
        if (has_image_url) {
            try db.exec(allocator,
                \\INSERT INTO session_queue_messages
                \\  (id, session_id, message, image_url, created_at)
                \\SELECT id, session_id, message, image_url, created_at
                \\  FROM _session_queue_messages_old
            , &[_][]const u8{});
        } else {
            try db.exec(allocator,
                \\INSERT INTO session_queue_messages
                \\  (id, session_id, message, created_at)
                \\SELECT id, session_id, message, created_at
                \\  FROM _session_queue_messages_old
            , &[_][]const u8{});
        }

        // 5. Drop the renamed table.
        try db.exec(allocator,
            "DROP TABLE _session_queue_messages_old",
            &[_][]const u8{},
        );

        // 6. Recreate the index Migration 018 added.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session " ++
            "ON session_queue_messages(session_id)",
            &[_][]const u8{},
        );
    }
};
