//! Turning a stored document into a file a browser can download, and a set of
//! documents into one zip. The HTTP handlers and the headless CLI both go
//! through here, so a download and a `pabrik headless documents export` produce
//! the same bytes.

const std = @import("std");
const documents_store = @import("documents_store.zig");

/// A markdown document exports as its own body, so the extension is the one a
/// text editor opens.
pub const MARKDOWN_EXT = ".md";

/// An office document's body is the Univer snapshot envelope. JSON is the only
/// faithful representation we hold, and it round-trips back into the editor.
pub const OFFICE_EXT = ".json";

/// The name a document with no usable title exports as.
pub const FALLBACK_STEM = "document";

/// Longest stem kept, in bytes. A 4 KiB title is legal in the database and
/// illegal in most filesystems; 80 bytes leaves room for the extension and a
/// ` (12)` de-duplication suffix.
pub const MAX_STEM_BYTES: usize = 80;

/// The zip's own name, so a caller never has to invent one.
pub const ZIP_NAME = "documents.zip";

pub const ExportError = error{
    IdsRequired,
    NoDocuments,
    NotFound,
    QueryFailed,
    TooManyEntries,
    OutOfMemory,
};

/// The extension a document of `format` exports as.
pub fn extensionFor(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, documents_store.FORMAT_OFFICE)) return OFFICE_EXT;
    return MARKDOWN_EXT;
}

/// The `Content-Type` a document of `format` exports as.
pub fn mimeFor(format: []const u8) []const u8 {
    if (std.mem.eql(u8, format, documents_store.FORMAT_OFFICE)) return "application/json";
    return "text/markdown; charset=utf-8";
}

/// True for a byte a filesystem or a `Content-Disposition` header cannot carry
/// verbatim. Everything at or above 0x80 is a UTF-8 lead or continuation byte
/// and is kept — a title in Indonesian or Japanese must survive.
fn isUnsafeNameByte(byte: u8) bool {
    if (byte < 0x20 or byte == 0x7f) return true;
    return switch (byte) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|' => true,
        else => false,
    };
}

/// `<title><ext>`, safe to hand to a filesystem and to a header. Unsafe bytes
/// become `-`, runs of them collapse to one, and leading/trailing spaces and
/// dots are dropped (Windows refuses a trailing dot, and a leading space is
/// invisible in a download shelf). A title with nothing usable left becomes
/// `document`.
pub fn fileName(
    allocator: std.mem.Allocator,
    title: []const u8,
    format: []const u8,
) ExportError![]u8 {
    const ext = extensionFor(format);

    var stem: std.ArrayList(u8) = .empty;
    defer stem.deinit(allocator);

    var last_was_dash = false;
    for (title) |byte| {
        if (isUnsafeNameByte(byte)) {
            if (!last_was_dash and stem.items.len > 0) try stem.append(allocator, '-');
            last_was_dash = true;
            continue;
        }
        last_was_dash = false;
        try stem.append(allocator, byte);
        if (stem.items.len >= MAX_STEM_BYTES) break;
    }

    const trimmed = trimStem(stem.items);
    const kept = if (trimmed.len == 0) FALLBACK_STEM else trimmed;

    return std.mem.concat(allocator, u8, &.{ kept, ext });
}

/// Drop leading and trailing spaces and dots, and cut a trailing partial UTF-8
/// sequence so the name is always valid text.
fn trimStem(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start < raw.len and (raw[start] == ' ' or raw[start] == '.')) start += 1;
    var end: usize = raw.len;
    while (end > start and (raw[end - 1] == ' ' or raw[end - 1] == '.')) end -= 1;
    // The byte cap can cut a multi-byte character in half. Walk back only while
    // the slice is still invalid — a complete trailing character is kept.
    while (end > start and !std.unicode.utf8ValidateSlice(raw[start..end])) end -= 1;
    return raw[start..end];
}

/// `attachment; filename="<ascii>"; filename*=UTF-8''<pct-encoded>`. The plain
/// `filename` is the fallback every client understands; `filename*` (RFC 5987)
/// is what carries a non-ASCII title without mangling it.
pub fn contentDisposition(allocator: std.mem.Allocator, name: []const u8) ExportError![]u8 {
    var ascii: std.ArrayList(u8) = .empty;
    defer ascii.deinit(allocator);
    for (name) |byte| {
        try ascii.append(allocator, if (byte < 0x20 or byte >= 0x7f) '_' else byte);
    }

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try encoded.append(allocator, byte);
        } else {
            try encoded.append(allocator, '%');
            try encoded.append(allocator, hex[byte >> 4]);
            try encoded.append(allocator, hex[byte & 0x0f]);
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "attachment; filename=\"{s}\"; filename*=UTF-8''{s}",
        .{ ascii.items, encoded.items },
    );
}

/// One file inside the archive.
pub const Entry = struct {
    name: []const u8,
    bytes: []const u8,
};

/// A stored-method (uncompressed) zip holding `entries`, in the order given.
///
/// Store, not deflate: the bodies are already small, and a compression
/// dependency would be a new build input for a feature that only has to hand
/// the user their own bytes back. The timestamp is fixed at 1980-01-01 so the
/// same documents always produce the same archive — a test can compare bytes.
pub fn buildZip(allocator: std.mem.Allocator, entries: []const Entry) ExportError![]u8 {
    if (entries.len > std.math.maxInt(u16)) return error.TooManyEntries;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(offsets);

    for (entries, 0..) |entry, i| {
        if (entry.name.len > std.math.maxInt(u16)) return error.TooManyEntries;
        if (entry.bytes.len > std.math.maxInt(u32)) return error.TooManyEntries;
        offsets[i] = @intCast(out.items.len);
        try writeLocalHeader(allocator, &out, entry);
    }

    const central_start: u32 = @intCast(out.items.len);
    for (entries, 0..) |entry, i| {
        try writeCentralHeader(allocator, &out, entry, offsets[i]);
    }
    const central_size: u32 = @intCast(out.items.len - central_start);

    try writeEndRecord(allocator, &out, @intCast(entries.len), central_size, central_start);
    return out.toOwnedSlice(allocator);
}

/// 1980-01-01 00:00:00 in MS-DOS form: the earliest instant the format can
/// express, and therefore the one that never depends on the clock.
const DOS_TIME: u16 = 0;
const DOS_DATE: u16 = 0x0021;

fn writeU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeLocalHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
) ExportError!void {
    const crc = std.hash.Crc32.hash(entry.bytes);
    try writeU32(out, allocator, 0x04034b50);
    try writeU16(out, allocator, 20);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, DOS_TIME);
    try writeU16(out, allocator, DOS_DATE);
    try writeU32(out, allocator, crc);
    try writeU32(out, allocator, @intCast(entry.bytes.len));
    try writeU32(out, allocator, @intCast(entry.bytes.len));
    try writeU16(out, allocator, @intCast(entry.name.len));
    try writeU16(out, allocator, 0);
    try out.appendSlice(allocator, entry.name);
    try out.appendSlice(allocator, entry.bytes);
}

fn writeCentralHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
    local_offset: u32,
) ExportError!void {
    const crc = std.hash.Crc32.hash(entry.bytes);
    try writeU32(out, allocator, 0x02014b50);
    try writeU16(out, allocator, 20);
    try writeU16(out, allocator, 20);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, DOS_TIME);
    try writeU16(out, allocator, DOS_DATE);
    try writeU32(out, allocator, crc);
    try writeU32(out, allocator, @intCast(entry.bytes.len));
    try writeU32(out, allocator, @intCast(entry.bytes.len));
    try writeU16(out, allocator, @intCast(entry.name.len));
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU32(out, allocator, 0);
    try writeU32(out, allocator, local_offset);
    try out.appendSlice(allocator, entry.name);
}

fn writeEndRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    count: u16,
    central_size: u32,
    central_start: u32,
) ExportError!void {
    try writeU32(out, allocator, 0x06054b50);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, 0);
    try writeU16(out, allocator, count);
    try writeU16(out, allocator, count);
    try writeU32(out, allocator, central_size);
    try writeU32(out, allocator, central_start);
    try writeU16(out, allocator, 0);
}

/// `name`, or `name (2)`, `name (3)` … — whichever is not already in `taken`.
/// Two documents titled "Untitled document" must not collapse into one entry.
/// The returned slice is owned by the caller and is also appended to `taken`.
pub fn uniqueName(
    allocator: std.mem.Allocator,
    name: []const u8,
    taken: *std.ArrayList([]const u8),
) ExportError![]u8 {
    if (!containsName(taken.items, name)) {
        const owned = try allocator.dupe(u8, name);
        try taken.append(allocator, owned);
        return owned;
    }

    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    const stem = name[0..dot];
    const ext = name[dot..];

    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, n, ext });
        if (!containsName(taken.items, candidate)) {
            try taken.append(allocator, candidate);
            return candidate;
        }
        allocator.free(candidate);
    }
}

fn containsName(taken: []const []const u8, name: []const u8) bool {
    for (taken) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

/// One document, ready to be written to a response or a file.
pub const ExportedFile = struct {
    /// The name it is saved under, extension included.
    name: []u8,
    mime: []const u8,
    bytes: []u8,
};

/// One archive holding several documents.
pub const ExportedArchive = struct {
    name: []const u8,
    mime: []const u8,
    bytes: []u8,
    /// How many documents went in. The zip's own directory is the authority on
    /// the contents; this is what the caller reports.
    count: usize,
};

/// The single-document export: the stored body, under a name derived from the
/// title and the format.
pub fn exportOne(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    workspace_id: []const u8,
    document_id: []const u8,
) ExportError!ExportedFile {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

    const row = try store.getDocument(allocator, workspace_id, document_id);
    defer documents_store.freeDocumentRow(allocator, row);

    return .{
        .name = try fileName(allocator, row.title, row.format),
        .mime = mimeFor(row.format),
        .bytes = try allocator.dupe(u8, row.content),
    };
}

/// The multi-document export: one zip, one entry per document, in the order the
/// caller named them. A repeated title gets a numbered suffix rather than
/// overwriting its twin.
pub fn exportMany(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    workspace_id: []const u8,
    document_ids: []const []const u8,
) ExportError!ExportedArchive {
    if (workspace_id.len == 0) return error.IdsRequired;
    if (document_ids.len == 0) return error.NoDocuments;

    const entries = try allocator.alloc(Entry, document_ids.len);
    defer allocator.free(entries);

    var taken: std.ArrayList([]const u8) = .empty;
    defer {
        for (taken.items) |name| allocator.free(name);
        taken.deinit(allocator);
    }

    // The zip is built from copies: a row's body is freed with the row, and the
    // archive outlives every row it was built from.
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |body| allocator.free(body);
        bodies.deinit(allocator);
    }

    for (document_ids, 0..) |document_id, i| {
        if (document_id.len == 0) return error.IdsRequired;
        const row = try store.getDocument(allocator, workspace_id, document_id);
        defer documents_store.freeDocumentRow(allocator, row);

        const base = try fileName(allocator, row.title, row.format);
        defer allocator.free(base);
        const unique = try uniqueName(allocator, base, &taken);
        const body = try allocator.dupe(u8, row.content);
        try bodies.append(allocator, body);
        entries[i] = .{ .name = unique, .bytes = body };
    }

    return .{
        .name = ZIP_NAME,
        .mime = "application/zip",
        .bytes = try buildZip(allocator, entries),
        .count = document_ids.len,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "fileName: a markdown document exports as .md under its own title" {
    const alloc = testing.allocator;
    const name = try fileName(alloc, "Release plan", documents_store.FORMAT_MARKDOWN);
    defer alloc.free(name);
    try testing.expectEqualStrings("Release plan.md", name);
}

test "fileName: an office document exports as .json" {
    const alloc = testing.allocator;
    const name = try fileName(alloc, "Budget", documents_store.FORMAT_OFFICE);
    defer alloc.free(name);
    try testing.expectEqualStrings("Budget.json", name);
}

test "fileName: path separators and header-hostile characters become one dash" {
    const alloc = testing.allocator;
    const name = try fileName(alloc, "a/b\\c:d*e?f\"g<h>i|j", documents_store.FORMAT_MARKDOWN);
    defer alloc.free(name);
    try testing.expectEqualStrings("a-b-c-d-e-f-g-h-i-j.md", name);
}

test "fileName: a blank or all-unsafe title falls back to document" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "", "   ", "...", "///" }) |title| {
        const name = try fileName(alloc, title, documents_store.FORMAT_MARKDOWN);
        defer alloc.free(name);
        try testing.expectEqualStrings("document.md", name);
    }
}

test "fileName: a non-ASCII title survives intact" {
    const alloc = testing.allocator;
    const name = try fileName(alloc, "Rencana rilis — 日本語", documents_store.FORMAT_MARKDOWN);
    defer alloc.free(name);
    try testing.expectEqualStrings("Rencana rilis — 日本語.md", name);
}

test "fileName: a very long title is cut to the stem cap and stays valid UTF-8" {
    const alloc = testing.allocator;
    const long = "é" ** 200;
    const name = try fileName(alloc, long, documents_store.FORMAT_MARKDOWN);
    defer alloc.free(name);
    try testing.expect(name.len <= MAX_STEM_BYTES + MARKDOWN_EXT.len);
    try testing.expect(std.unicode.utf8ValidateSlice(name));
}

test "contentDisposition: an ASCII name is quoted and percent-encoded identically" {
    const alloc = testing.allocator;
    const value = try contentDisposition(alloc, "Release plan.md");
    defer alloc.free(value);
    try testing.expectEqualStrings(
        "attachment; filename=\"Release plan.md\"; filename*=UTF-8''Release%20plan.md",
        value,
    );
}

test "contentDisposition: a non-ASCII name keeps an ASCII fallback and an encoded form" {
    const alloc = testing.allocator;
    const value = try contentDisposition(alloc, "Rencana — 日本語.md");
    defer alloc.free(value);

    // The plain `filename` is what a client that ignores RFC 5987 reads, so it
    // must be pure ASCII — one `_` per non-ASCII byte, never a raw UTF-8 byte.
    const fallback_end = std.mem.indexOf(u8, value, "\"; filename*=") orelse
        return error.MissingEncodedForm;
    try testing.expect(std.mem.startsWith(u8, value, "attachment; filename=\"Rencana "));
    for (value[0..fallback_end]) |byte| try testing.expect(byte < 0x7f);

    // The encoded form carries the real title, with the em dash percent-encoded.
    try testing.expect(std.mem.indexOf(u8, value, "filename*=UTF-8''Rencana%20%E2%80%94%20") != null);
}

/// One entry read back out of an archive by walking its central directory —
/// the same path an unzip tool takes, so a malformed header fails here.
const ReadBack = struct { name: []const u8, bytes: []const u8 };

fn readBack(allocator: std.mem.Allocator, zip: []const u8) ![]ReadBack {
    const eocd_at = std.mem.lastIndexOfScalar(u8, zip, 0x50) orelse return error.NoEndRecord;
    if (eocd_at + 22 > zip.len) return error.NoEndRecord;
    if (!std.mem.eql(u8, zip[eocd_at..][0..4], "PK\x05\x06")) return error.NoEndRecord;

    const count = std.mem.readInt(u16, zip[eocd_at + 10 ..][0..2], .little);
    const central_size = std.mem.readInt(u32, zip[eocd_at + 12 ..][0..4], .little);
    const central_start = std.mem.readInt(u32, zip[eocd_at + 16 ..][0..4], .little);
    if (central_start + central_size > zip.len) return error.BadCentralDirectory;

    const out = try allocator.alloc(ReadBack, count);
    errdefer allocator.free(out);

    var at: usize = central_start;
    for (out) |*slot| {
        if (!std.mem.eql(u8, zip[at..][0..4], "PK\x01\x02")) return error.BadCentralHeader;
        const name_len = std.mem.readInt(u16, zip[at + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip[at + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, zip[at + 32 ..][0..2], .little);
        const local_offset = std.mem.readInt(u32, zip[at + 42 ..][0..4], .little);
        const name = zip[at + 46 ..][0..name_len];

        const local = local_offset;
        if (!std.mem.eql(u8, zip[local..][0..4], "PK\x03\x04")) return error.BadLocalHeader;
        const local_name_len = std.mem.readInt(u16, zip[local + 26 ..][0..2], .little);
        const local_extra_len = std.mem.readInt(u16, zip[local + 28 ..][0..2], .little);
        const size = std.mem.readInt(u32, zip[local + 18 ..][0..4], .little);
        const data_at = local + 30 + local_name_len + local_extra_len;

        slot.* = .{ .name = name, .bytes = zip[data_at..][0..size] };
        at += 46 + name_len + extra_len + comment_len;
    }
    return out;
}

test "buildZip: one entry round-trips through the central directory as the same bytes" {
    const alloc = testing.allocator;
    const zip = try buildZip(alloc, &.{.{ .name = "a.md", .bytes = "# hello" }});
    defer alloc.free(zip);

    const entries = try readBack(alloc, zip);
    defer alloc.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("a.md", entries[0].name);
    try testing.expectEqualStrings("# hello", entries[0].bytes);
}

test "buildZip: every entry keeps its own name and payload, in order" {
    const alloc = testing.allocator;
    const zip = try buildZip(alloc, &.{
        .{ .name = "a.md", .bytes = "one" },
        .{ .name = "b.json", .bytes = "{\"kind\":\"sheet\"}" },
    });
    defer alloc.free(zip);

    const entries = try readBack(alloc, zip);
    defer alloc.free(entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("a.md", entries[0].name);
    try testing.expectEqualStrings("one", entries[0].bytes);
    try testing.expectEqualStrings("b.json", entries[1].name);
    try testing.expectEqualStrings("{\"kind\":\"sheet\"}", entries[1].bytes);
}

test "buildZip: an empty body is a legal entry, not a skipped one" {
    const alloc = testing.allocator;
    const zip = try buildZip(alloc, &.{.{ .name = "blank.md", .bytes = "" }});
    defer alloc.free(zip);

    const entries = try readBack(alloc, zip);
    defer alloc.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("", entries[0].bytes);
}

test "buildZip: the same entries always produce the same archive" {
    const alloc = testing.allocator;
    const entries = [_]Entry{.{ .name = "a.md", .bytes = "one" }};
    const first = try buildZip(alloc, &entries);
    defer alloc.free(first);
    const second = try buildZip(alloc, &entries);
    defer alloc.free(second);
    try testing.expectEqualSlices(u8, first, second);
}

test "buildZip: an empty set is a valid empty archive, not an error" {
    const alloc = testing.allocator;
    const zip = try buildZip(alloc, &.{});
    defer alloc.free(zip);
    try testing.expectEqual(@as(usize, 22), zip.len);
    try testing.expect(std.mem.startsWith(u8, zip, "PK\x05\x06"));
}

test "uniqueName: a repeated title gets a numbered suffix before the extension" {
    const alloc = testing.allocator;
    var taken: std.ArrayList([]const u8) = .empty;
    defer {
        for (taken.items) |name| alloc.free(name);
        taken.deinit(alloc);
    }

    const first = try uniqueName(alloc, "Untitled document.md", &taken);
    const second = try uniqueName(alloc, "Untitled document.md", &taken);
    const third = try uniqueName(alloc, "Untitled document.md", &taken);

    try testing.expectEqualStrings("Untitled document.md", first);
    try testing.expectEqualStrings("Untitled document (2).md", second);
    try testing.expectEqualStrings("Untitled document (3).md", third);
}

test "uniqueName: a name with no extension still gets a distinct suffix" {
    const alloc = testing.allocator;
    var taken: std.ArrayList([]const u8) = .empty;
    defer {
        for (taken.items) |name| alloc.free(name);
        taken.deinit(alloc);
    }

    _ = try uniqueName(alloc, "notes", &taken);
    const second = try uniqueName(alloc, "notes", &taken);
    try testing.expectEqualStrings("notes (2)", second);
}
