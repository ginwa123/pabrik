//! Codec + policy for chat file attachments (PDF and documents). One wire field carries them:
//! `file_attachments`, a JSON array of `{name, mime, b64}`. The backend classifies each file ONCE,
//! at the HTTP boundary, so the model path never re-decodes them.
const std = @import("std");
const testing = std.testing;

/// A file as the client sends it: base64 payload, no data-URL prefix.
pub const RequestFile = struct {
    name: []const u8,
    mime: []const u8,
    b64: []const u8,
};

/// A file as the backend stores it. A text-like document carries `text`, a
/// binary file carries `b64`. Exactly one of the two is set.
pub const StoredFile = struct {
    name: []const u8,
    mime: []const u8,
    bytes: u64 = 0,
    text: ?[]const u8 = null,
    b64: ?[]const u8 = null,
};

/// A file as the READ path emits it: enough to render a chip, never the bytes.
pub const Meta = struct {
    name: []const u8,
    mime: []const u8,
    bytes: u64 = 0,
};

/// What kind of file this is, and therefore which wire shape can carry it.
pub const Kind = enum {
    /// Text the model reads directly — a plain `text` content part.
    text_like,
    /// A PDF — a provider file part.
    pdf,
    /// A rich binary document (doc/docx/xls/xlsx/ppt/pptx/odt) — a provider
    /// file part, but only the Responses API accepts one.
    rich_binary,
    /// A type the model has no way to read.
    unsupported,
};

/// Cap on the decoded size of every file in one message, together.
pub const MAX_TOTAL_BYTES: u64 = 10 * 1024 * 1024;

/// Cap on how many files one message may carry.
pub const MAX_FILE_COUNT: usize = 8;

/// MIME types that are text in practice even though they are not `text/*`.
const TEXTUAL_MIMES = [_][]const u8{
    "application/json",
    "application/xml",
    "application/javascript",
    "application/x-javascript",
    "application/ecmascript",
    "application/typescript",
    "application/x-yaml",
    "application/yaml",
    "application/toml",
    "application/sql",
    "application/x-sh",
    "application/x-httpd-php",
    "application/graphql",
    "application/x-ndjson",
};

/// MIME types of the rich binary documents the Responses API accepts.
const RICH_BINARY_MIMES = [_][]const u8{
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.oasis.opendocument.text",
    "application/vnd.oasis.opendocument.spreadsheet",
    "application/vnd.oasis.opendocument.presentation",
    "application/rtf",
};

/// Extensions that are text even when the browser reports no MIME type.
const TEXTUAL_EXTENSIONS = [_][]const u8{
    "txt",        "md",       "markdown", "csv",    "tsv",   "json",  "jsonl",   "ndjson",
    "xml",        "yaml",     "yml",      "toml",   "ini",   "cfg",   "conf",    "log",
    "html",       "htm",      "css",      "scss",   "less",  "sql",   "graphql", "gql",
    "js",         "mjs",      "cjs",      "ts",     "tsx",   "jsx",   "vue",     "svelte",
    "py",         "rb",       "go",       "rs",     "java",  "kt",    "kts",     "c",
    "h",          "cc",       "cpp",      "hpp",    "cs",    "php",   "sh",      "bash",
    "zsh",        "fish",     "swift",    "m",      "mm",    "pl",    "pm",      "lua",
    "dart",       "scala",    "hs",       "ex",     "exs",   "erl",   "clj",     "zig",
    "nim",        "r",        "jl",       "tf",     "hcl",   "proto", "env",     "gitignore",
    "dockerfile", "makefile", "mk",       "gradle", "cmake", "patch", "diff",
};

/// Extensions of the rich binary documents, for browsers that report no MIME.
const RICH_BINARY_EXTENSIONS = [_][]const u8{
    "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf",
};

/// The MIME each rich binary extension really is. A browser reports
/// `application/octet-stream` (or nothing) for these, and the provider needs
/// the true type, so the extension decides.
const RICH_BINARY_MIME_BY_EXTENSION = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = "doc", .mime = "application/msword" },
    .{ .ext = "docx", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ .ext = "xls", .mime = "application/vnd.ms-excel" },
    .{ .ext = "xlsx", .mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ .ext = "ppt", .mime = "application/vnd.ms-powerpoint" },
    .{ .ext = "pptx", .mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ .ext = "odt", .mime = "application/vnd.oasis.opendocument.text" },
    .{ .ext = "ods", .mime = "application/vnd.oasis.opendocument.spreadsheet" },
    .{ .ext = "odp", .mime = "application/vnd.oasis.opendocument.presentation" },
    .{ .ext = "rtf", .mime = "application/rtf" },
};

/// The lowercased extension of `name`, without the dot. Empty when there is none.
pub fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot + 1 >= name.len) return "";
    return name[dot + 1 ..];
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn inList(list: []const []const u8, needle: []const u8) bool {
    for (list) |entry| {
        if (equalsIgnoreCase(entry, needle)) return true;
    }
    return false;
}

/// True when the MIME is one the model reads as plain text.
pub fn isTextualMime(mime: []const u8) bool {
    if (mime.len == 0) return false;
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    return inList(&TEXTUAL_MIMES, mime);
}

/// True when the MIME is a PDF.
pub fn isPdfMime(mime: []const u8) bool {
    return equalsIgnoreCase(mime, "application/pdf");
}

/// True when the MIME is a rich binary document.
pub fn isRichBinaryMime(mime: []const u8) bool {
    return inList(&RICH_BINARY_MIMES, mime);
}

/// The kind of file this is. A browser that reports no MIME type is judged
/// by its extension, so a `.md` file still arrives as text. A type the model
/// has no way to read is `unsupported` — it is rejected, never dropped.
pub fn classify(name: []const u8, mime: []const u8) Kind {
    if (isPdfMime(mime) or equalsIgnoreCase(extensionOf(name), "pdf")) return .pdf;
    if (isRichBinaryMime(mime)) return .rich_binary;
    if (isTextualMime(mime)) return .text_like;
    const ext = extensionOf(name);
    if (equalsIgnoreCase(ext, "pdf")) return .pdf;
    if (inList(&RICH_BINARY_EXTENSIONS, ext)) return .rich_binary;
    if (inList(&TEXTUAL_EXTENSIONS, ext)) return .text_like;
    return .unsupported;
}

/// The MIME a provider should be told for this file. A rich binary document
/// takes the MIME its extension really is, because the browser reports
/// `application/octet-stream` for those.
pub fn providerMime(kind: Kind, name: []const u8, mime: []const u8) []const u8 {
    return switch (kind) {
        .pdf => "application/pdf",
        .text_like => if (mime.len > 0) mime else "text/plain",
        .rich_binary => richBinaryMime(name) orelse (if (mime.len > 0) mime else "application/octet-stream"),
        .unsupported => "application/octet-stream",
    };
}

/// The true MIME of a rich binary document, by its extension.
fn richBinaryMime(name: []const u8) ?[]const u8 {
    const ext = extensionOf(name);
    for (RICH_BINARY_MIME_BY_EXTENSION) |entry| {
        if (equalsIgnoreCase(entry.ext, ext)) return entry.mime;
    }
    return null;
}

/// True when this wire style can carry a file of this kind. Chat Completions
/// takes PDF only; the Responses API takes the rich binary documents too;
/// Anthropic takes PDF only.
pub fn styleCarries(url_style: []const u8, kind: Kind) bool {
    return switch (kind) {
        .text_like => true,
        .pdf => true,
        .rich_binary => std.mem.eql(u8, url_style, "openai-response"),
        .unsupported => false,
    };
}

/// True when this wire style can carry a file of this kind AS A FILE PART.
/// A text-like document never rides as a file part — it is sent as text,
/// which every style accepts.
pub fn styleCarriesFile(url_style: []const u8, kind: Kind) bool {
    if (kind == .text_like) return false;
    return styleCarries(url_style, kind);
}

/// The text a model reads for a text-like document. The header names the
/// file so the model knows what the block is.
pub fn textPart(allocator: std.mem.Allocator, file: StoredFile) ![]u8 {
    const text = file.text orelse return error.NotATextFile;
    return std.fmt.allocPrint(allocator, "[Attached file: {s}]\n{s}", .{ file.name, text });
}

/// The decoded byte count of a base64 payload. The trailing `=` characters are
/// already accounted for by the leftover-character count, so they are not
/// subtracted a second time.
pub fn decodedSize(b64: []const u8) u64 {
    var len = b64.len;
    while (len > 0 and b64[len - 1] == '=') len -= 1;
    const groups = len / 4;
    const rest = len % 4;
    var bytes = groups * 3;
    if (rest == 2) bytes += 1;
    if (rest == 3) bytes += 2;
    return bytes;
}

/// Decode a base64 payload into bytes.
pub fn decodeBase64(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, b64);
    return out;
}

/// Validate a batch of incoming files and normalize them for storage.
pub fn normalize(allocator: std.mem.Allocator, files: []const RequestFile) ![]StoredFile {
    if (files.len > MAX_FILE_COUNT) return error.TooManyFiles;
    var total: u64 = 0;
    for (files) |file| {
        total += decodedSize(file.b64);
        if (total > MAX_TOTAL_BYTES) return error.FilesTooLarge;
    }

    const out = try allocator.alloc(StoredFile, files.len);
    errdefer allocator.free(out);
    for (files, 0..) |file, i| {
        const kind = classify(file.name, file.mime);
        if (kind == .unsupported) return error.UnsupportedFileType;
        var stored = StoredFile{
            .name = file.name,
            .mime = providerMime(kind, file.name, file.mime),
            .bytes = decodedSize(file.b64),
        };
        if (kind == .text_like) {
            const raw = try decodeBase64(allocator, file.b64);
            defer allocator.free(raw);
            if (!std.unicode.utf8ValidateSlice(raw)) return error.NotValidUtf8;
            stored.text = try allocator.dupe(u8, raw);
        } else {
            stored.b64 = try allocator.dupe(u8, file.b64);
        }
        out[i] = stored;
    }
    return out;
}

/// The JSON shape the client sends: an array of `{name, mime, b64}`.
const RequestFileJson = struct {
    name: []const u8 = "",
    mime: []const u8 = "",
    b64: []const u8 = "",
};

/// A parsed `file_attachments` request field. The strings live in its arena.
pub const RequestFiles = struct {
    arena: std.heap.ArenaAllocator,
    files: []const RequestFile,

    pub fn deinit(self: *RequestFiles) void {
        self.arena.deinit();
    }
};

/// Parse the `file_attachments` wire field — a JSON array of
/// `{name, mime, b64}`. An empty string means "no attachments".
pub fn parseRequest(allocator: std.mem.Allocator, text: []const u8) !RequestFiles {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (text.len == 0) return .{ .arena = arena, .files = try a.alloc(RequestFile, 0) };
    const parsed = try std.json.parseFromSliceLeaky([]RequestFileJson, a, text, .{
        .ignore_unknown_fields = true,
    });
    const out = try a.alloc(RequestFile, parsed.len);
    for (parsed, 0..) |file, i| {
        out[i] = .{ .name = file.name, .mime = file.mime, .b64 = file.b64 };
    }
    return .{ .arena = arena, .files = out };
}

/// Free what `normalize` allocated.
pub fn freeStored(allocator: std.mem.Allocator, files: []StoredFile) void {
    for (files) |file| {
        if (file.text) |text| allocator.free(text);
        if (file.b64) |b64| allocator.free(b64);
    }
    allocator.free(files);
}

/// Serialize stored files into the JSON text the payload column holds.
pub fn encodeStored(allocator: std.mem.Allocator, files: []const StoredFile) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeByte('[');
    for (files, 0..) |file, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, file.name);
        try w.writeAll(",\"mime\":");
        try writeJsonString(w, file.mime);
        try w.print(",\"bytes\":{d}", .{file.bytes});
        if (file.text) |text| {
            try w.writeAll(",\"text\":");
            try writeJsonString(w, text);
        }
        if (file.b64) |b64| {
            try w.writeAll(",\"b64\":");
            try writeJsonString(w, b64);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return aw.toOwnedSlice();
}

/// The JSON shape `parseStored` reads.
const StoredFileJson = struct {
    name: []const u8 = "",
    mime: []const u8 = "",
    bytes: u64 = 0,
    text: ?[]const u8 = null,
    b64: ?[]const u8 = null,
};

/// A parsed attachment list. The strings it holds live in its arena, so
/// `deinit` releases all of them at once.
pub const Stored = struct {
    arena: std.heap.ArenaAllocator,
    files: []const StoredFile,

    pub fn deinit(self: *Stored) void {
        self.arena.deinit();
    }
};

/// Parse the JSON text the payload column holds back into stored files.
pub fn parseStored(allocator: std.mem.Allocator, text: []const u8) !Stored {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (text.len == 0) return .{ .arena = arena, .files = try a.alloc(StoredFile, 0) };
    const parsed = try std.json.parseFromSliceLeaky([]StoredFileJson, a, text, .{
        .ignore_unknown_fields = true,
    });
    const out = try a.alloc(StoredFile, parsed.len);
    for (parsed, 0..) |file, i| {
        out[i] = StoredFile{
            .name = file.name,
            .mime = file.mime,
            .bytes = file.bytes,
            .text = file.text,
            .b64 = file.b64,
        };
    }
    return .{ .arena = arena, .files = out };
}

/// Project stored files to the metadata the read path emits.
pub fn toMeta(allocator: std.mem.Allocator, files: []const StoredFile) ![]Meta {
    const out = try allocator.alloc(Meta, files.len);
    for (files, 0..) |file, i| {
        out[i] = .{ .name = file.name, .mime = file.mime, .bytes = file.bytes };
    }
    return out;
}

/// Serialize metadata for the read path.
pub fn encodeMeta(allocator: std.mem.Allocator, files: []const StoredFile) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeByte('[');
    for (files, 0..) |file, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, file.name);
        try w.writeAll(",\"mime\":");
        try writeJsonString(w, file.mime);
        try w.print(",\"bytes\":{d}}}", .{file.bytes});
    }
    try w.writeByte(']');
    return aw.toOwnedSlice();
}

/// The JSON shape `parseMeta` reads.
const MetaJson = struct {
    name: []const u8 = "",
    mime: []const u8 = "",
    bytes: u64 = 0,
};

/// A parsed metadata list. The strings it holds live in its arena.
pub const ParsedMeta = struct {
    arena: std.heap.ArenaAllocator,
    files: []const Meta,

    pub fn deinit(self: *ParsedMeta) void {
        self.arena.deinit();
    }
};

/// Parse the JSON text the metadata column holds.
pub fn parseMeta(allocator: std.mem.Allocator, text: []const u8) !ParsedMeta {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (text.len == 0) return .{ .arena = arena, .files = try a.alloc(Meta, 0) };
    const parsed = try std.json.parseFromSliceLeaky([]MetaJson, a, text, .{
        .ignore_unknown_fields = true,
    });
    const out = try a.alloc(Meta, parsed.len);
    for (parsed, 0..) |file, i| {
        out[i] = .{ .name = file.name, .mime = file.mime, .bytes = file.bytes };
    }
    return .{ .arena = arena, .files = out };
}

/// Write a JSON string literal, escaping what RFC 8259 requires.
fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "classify reads a pdf by mime or by extension" {
    try testing.expectEqual(Kind.pdf, classify("a.pdf", "application/pdf"));
    try testing.expectEqual(Kind.pdf, classify("a.pdf", ""));
    try testing.expectEqual(Kind.pdf, classify("a.PDF", ""));
}

test "classify reads a text document by mime or by extension" {
    try testing.expectEqual(Kind.text_like, classify("a.md", "text/markdown"));
    try testing.expectEqual(Kind.text_like, classify("a.md", ""));
    try testing.expectEqual(Kind.text_like, classify("a.json", "application/json"));
    try testing.expectEqual(Kind.text_like, classify("a.zig", ""));
}

test "classify reads a rich binary document" {
    try testing.expectEqual(Kind.rich_binary, classify("a.docx", ""));
    try testing.expectEqual(
        Kind.rich_binary,
        classify("a.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    );
}

test "providerMime gives a rich binary document the mime its extension really is" {
    // A browser reports `application/octet-stream` for a .docx, and the
    // provider needs the true type.
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        providerMime(.rich_binary, "a.docx", "application/octet-stream"),
    );
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        providerMime(.rich_binary, "a.xlsx", ""),
    );
    try testing.expectEqualStrings("application/pdf", providerMime(.pdf, "a.pdf", "application/pdf"));
    try testing.expectEqualStrings("text/markdown", providerMime(.text_like, "a.md", "text/markdown"));
}

test "classify rejects a type the model has no way to read" {
    try testing.expectEqual(Kind.unsupported, classify("a.exe", "application/octet-stream"));
    try testing.expectEqual(Kind.unsupported, classify("a.bin", ""));
}

test "normalize rejects a file the model cannot read" {
    const files = [_]RequestFile{
        .{ .name = "a.exe", .mime = "application/octet-stream", .b64 = "aGk=" },
    };
    try testing.expectError(error.UnsupportedFileType, normalize(testing.allocator, &files));
}

test "parseRequest reads the wire array of name, mime and base64" {
    const text =
        \\[{"name":"a.pdf","mime":"application/pdf","b64":"aGk="},{"name":"b.md","mime":"text/markdown","b64":"aGk="}]
    ;
    var files = try parseRequest(testing.allocator, text);
    defer files.deinit();
    try testing.expectEqual(@as(usize, 2), files.files.len);
    try testing.expectEqualStrings("a.pdf", files.files[0].name);
    try testing.expectEqualStrings("application/pdf", files.files[0].mime);
    try testing.expectEqualStrings("aGk=", files.files[0].b64);
    try testing.expectEqualStrings("b.md", files.files[1].name);
}

test "parseRequest on an empty field means no attachments" {
    var files = try parseRequest(testing.allocator, "");
    defer files.deinit();
    try testing.expectEqual(@as(usize, 0), files.files.len);
}

test "styleCarriesFile never sends a text document as a file part" {
    try testing.expect(!styleCarriesFile("openai", .text_like));
    try testing.expect(!styleCarriesFile("openai-response", .text_like));
    try testing.expect(!styleCarriesFile("anthropic", .text_like));
    try testing.expect(styleCarriesFile("openai", .pdf));
    try testing.expect(styleCarriesFile("openai-response", .rich_binary));
    try testing.expect(!styleCarriesFile("openai", .rich_binary));
}

test "textPart names the file and carries the text the model reads" {
    const stored = [_]StoredFile{
        .{ .name = "notes.md", .mime = "text/markdown", .bytes = 5, .text = "hello" },
    };
    const text = try textPart(testing.allocator, stored[0]);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[Attached file: notes.md]\nhello", text);
}

test "textPart on a binary file is an error, not an empty part" {
    const stored = [_]StoredFile{
        .{ .name = "doc.pdf", .mime = "application/pdf", .bytes = 5, .b64 = "aGVsbG8=" },
    };
    try testing.expectError(error.NotATextFile, textPart(testing.allocator, stored[0]));
}

test "styleCarries accepts a pdf everywhere and a rich document only on the responses api" {
    try testing.expect(styleCarries("openai", .pdf));
    try testing.expect(styleCarries("openai-response", .pdf));
    try testing.expect(styleCarries("anthropic", .pdf));
    try testing.expect(styleCarries("openai", .text_like));
    try testing.expect(!styleCarries("openai", .rich_binary));
    try testing.expect(!styleCarries("anthropic", .rich_binary));
    try testing.expect(styleCarries("openai-response", .rich_binary));
}

test "decodedSize counts the bytes a base64 payload carries" {
    try testing.expectEqual(@as(u64, 0), decodedSize(""));
    try testing.expectEqual(@as(u64, 3), decodedSize("YWJj"));
    try testing.expectEqual(@as(u64, 2), decodedSize("YWI="));
    try testing.expectEqual(@as(u64, 1), decodedSize("YQ=="));
}

test "normalize keeps a text document as text and a pdf as base64" {
    const files = [_]RequestFile{
        .{ .name = "notes.md", .mime = "text/markdown", .b64 = "aGVsbG8=" },
        .{ .name = "doc.pdf", .mime = "application/pdf", .b64 = "aGVsbG8=" },
    };
    const stored = try normalize(testing.allocator, &files);
    defer freeStored(testing.allocator, stored);

    try testing.expectEqualStrings("hello", stored[0].text.?);
    try testing.expect(stored[0].b64 == null);
    try testing.expectEqualStrings("aGVsbG8=", stored[1].b64.?);
    try testing.expect(stored[1].text == null);
    try testing.expectEqual(@as(u64, 5), stored[0].bytes);
}

test "normalize rejects a batch larger than the total byte cap" {
    // Each file decodes to just over a quarter of the cap, so four of them
    // cross it. The payload is base64 of zeroes — the cap is checked on the
    // DECODED size, before anything is decoded.
    const per_file_decoded = MAX_TOTAL_BYTES / 3;
    const per_file_b64 = per_file_decoded / 3 * 4;
    const big = try testing.allocator.alloc(u8, per_file_b64);
    defer testing.allocator.free(big);
    @memset(big, 'A');

    var files: [4]RequestFile = undefined;
    for (&files) |*f| f.* = .{ .name = "a.bin", .mime = "application/pdf", .b64 = big };
    try testing.expectError(error.FilesTooLarge, normalize(testing.allocator, &files));
}

test "normalize rejects more files than the count cap" {
    var files: [MAX_FILE_COUNT + 1]RequestFile = undefined;
    for (&files) |*f| f.* = .{ .name = "a.txt", .mime = "text/plain", .b64 = "" };
    try testing.expectError(error.TooManyFiles, normalize(testing.allocator, &files));
}

test "normalize rejects a text file that is not valid utf-8" {
    const files = [_]RequestFile{
        .{ .name = "a.txt", .mime = "text/plain", .b64 = "/w==" },
    };
    try testing.expectError(error.NotValidUtf8, normalize(testing.allocator, &files));
}

test "encodeStored and parseStored round trip a file" {
    const files = [_]RequestFile{
        .{ .name = "notes.md", .mime = "text/markdown", .b64 = "aGVsbG8=" },
    };
    const stored = try normalize(testing.allocator, &files);
    defer freeStored(testing.allocator, stored);

    const text = try encodeStored(testing.allocator, stored);
    defer testing.allocator.free(text);

    var back = try parseStored(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.files.len);
    try testing.expectEqualStrings("notes.md", back.files[0].name);
    try testing.expectEqualStrings("text/markdown", back.files[0].mime);
    try testing.expectEqualStrings("hello", back.files[0].text.?);
}

test "encodeStored escapes a name that carries a quote or a newline" {
    const stored = [_]StoredFile{
        .{ .name = "a\"b\nc", .mime = "text/plain", .bytes = 1, .text = "x" },
    };
    const text = try encodeStored(testing.allocator, &stored);
    defer testing.allocator.free(text);

    var back = try parseStored(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("a\"b\nc", back.files[0].name);
}

test "encodeMeta emits the name, the mime and the size but never the bytes" {
    const stored = [_]StoredFile{
        .{ .name = "doc.pdf", .mime = "application/pdf", .bytes = 5, .b64 = "aGVsbG8=" },
    };
    const text = try encodeMeta(testing.allocator, &stored);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "[{\"name\":\"doc.pdf\",\"mime\":\"application/pdf\",\"bytes\":5}]",
        text,
    );
}

test "encodeMeta and parseMeta round trip the metadata" {
    const stored = [_]StoredFile{
        .{ .name = "doc.pdf", .mime = "application/pdf", .bytes = 5, .b64 = "aGVsbG8=" },
    };
    const text = try encodeMeta(testing.allocator, &stored);
    defer testing.allocator.free(text);

    var back = try parseMeta(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.files.len);
    try testing.expectEqualStrings("doc.pdf", back.files[0].name);
    try testing.expectEqual(@as(u64, 5), back.files[0].bytes);
}

test "parseStored on an empty column yields no files" {
    var back = try parseStored(testing.allocator, "");
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.files.len);
}
