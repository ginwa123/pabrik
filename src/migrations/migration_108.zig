const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;

/// Migration 108 — remember how much of a process's log the agent has been
/// shown.
///
/// `background_persistence` is silent by design: nobody tells the agent its dev
/// server said something. So the agent asks, and the only useful answer to
/// "what has it said?" is the part it has NOT seen. Without a stored cursor
/// every read returns the same head of the file, and a model polling a growing
/// log re-reads — and re-pays for — the same lines on every poll, while the new
/// ones sit past whatever a fixed `tail -n N` happens to cover.
///
/// WHY A BYTE OFFSET AND NOT A LINE COUNT
///
/// The log is appended to by another process while we read it, so a line count
/// would have to be recomputed by scanning from the start on every read — the
/// cost we are trying to remove — and it is ambiguous the moment a line is
/// written without a trailing newline. A byte offset is what `pread` needs, is
/// stable under concurrent appends, and degrades honestly: a partial line at
/// the end is returned now and the remainder on the next read.
///
/// WHY `NOT NULL DEFAULT 0`
///
/// `0` is the correct value for every pre-108 row: nothing has been read yet, so
/// the whole log is new. A NULL would turn every comparison into NULL (never
/// true) and the read would either return the entire file for ever or nothing
/// at all, depending on which way the expression was written.
pub const Migration108AddBackgroundProcessReadOffset = struct {
    pub const version: u32 = 108;
    pub const name = "add_background_process_read_offset";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\ALTER TABLE session_background_process
            \\    ADD COLUMN last_read_offset INTEGER NOT NULL DEFAULT 0
        , &[_][]const u8{});
    }
};
