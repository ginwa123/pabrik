//! `present_files` — an agent tool that presents workspace files of ANY
//! type (text, jpg/png, pdf, zip, code, html, etc.) as rich inline-preview
//! cards in the chat transcript.
//!
//! The LLM calls this tool with a list of ABSOLUTE file paths. The
//! server stats each file (existence, size, mime) and returns a JSON
//! object listing them. The frontend's `<PresentFiles>` card renders
//! one section per file with an inline preview plus a download action:
//! images (`image/*`) render full-width, html renders in a sandboxed
//! iframe, text/markdown/code render fetched source inline, pdf renders
//! in an embedded frame, video/audio render native players, and anything
//! else falls back to a generic row. Every row links to
//! `GET /api/files/download?disposition=attachment` so clicking
//! downloads the bytes with the original filename (cookie-based auth,
//! so plain `<a href>` + `<img src>` carry credentials). Inline bytes
//! come from `GET /api/files/download?disposition=inline`.
//!
//! Response shape (per project convention, like `generate_image.zig`):
//!   {"status":"presented","count":2,"files":[
//!     {"path":"/abs/a.txt","bytes":12,"mime":"text/plain; charset=utf-8","label":"notes"},
//!     {"path":"/abs/b.jpg","bytes":48211,"mime":"image/jpeg","label":"b.jpg"}
//!   ],"error":null}
//!
//! On error (any file fails validation):
//!   {"status":null,"count":0,"files":[],"error":"..."}
//!
//! Design: docs/plans/2026-09-14-agent-tool-present-files.md
//! This tool never reads file bytes — only `stat` — so the SSE payload
//! stays tiny and previews render via URL instead of data URI. To show
//! LLM-generated content inline, first persist it with `write_file`,
//! then present the saved file.

const std = @import("std");
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const AgentTool = schemas.AgentTool;
// The one containment rule shared with GET /api/files/download. Imported,
// never re-implemented here: the two disagreed once and every presented file
// outside the session working directory became a card that 403s on every
// fetch. See docs/plans/2026-09-29-present-files-sandbox-parity.md.
const file_sandbox = @import("file_sandbox.zig");

/// Maximum number of files per call. Keeps the card scannable and the
/// envelope small; the LLM can split larger sets across calls.
pub const MAX_FILES: usize = 10;

/// Maximum per-file size (50 MiB). Matches the download handler's cap
/// (`files_download.zig`) so a presented file is always downloadable.
/// Larger files are rejected with a clear error so the LLM can explain
/// instead of emitting a dead link.
pub const MAX_FILE_BYTES: usize = 50 * 1024 * 1024;

/// One file reference from the LLM.
pub const PresentFileRef = struct {
    /// ABSOLUTE path to a workspace file.
    path: []const u8,
    /// Optional short display name shown in the card. Falls back to the
    /// basename when absent or empty.
    label: ?[]const u8 = null,
    /// Optional longer note shown below the row.
    caption: ?[]const u8 = null,
};

/// Input structure for the `present_files` tool.
pub const PresentFilesInput = struct {
    files: []PresentFileRef,
    /// REQUIRED on the wire. Absolute directory this call works in; a
    /// relative entry `path` resolves against it. Empty by default so the
    /// struct stays constructible in tests that do not exercise the `cwd`
    /// rule — `path_validate.validateCwd` rejects the empty value at exec
    /// time.
    cwd: []const u8 = "",
};

/// Top-level tool definition exposed to the LLM.
pub const present_files_tool_system_prompt =
    \\## Present Files Tool — Behavior
    \\Use `present_files` to present workspace files (any type: text, images, pdf, zip, code, html, video, audio) as inline-preview cards in the chat.
    \\- `cwd` is REQUIRED: the absolute directory this call works in. A relative entry `path` resolves against it; an absolute `path` is used as-is.
    \\- Provide `files` with `path` entries (1-10, absolute or relative to `cwd`). Each file must exist, be ≤ 50 MiB, and live INSIDE the session working directory — the browser is only served files from there, so a path outside it (e.g. under ~/Downloads) is rejected. To show such a file, copy it into the working directory first (e.g. `bash cp "<path>" "<working-dir>/"`), then present the copy.
    \\- The card renders each file inline: images full-width, html in a sandboxed iframe, text/markdown/code as fetched source, pdf embedded, video/audio with native players; anything else shows a file row with a download button.
    \\- To show generated content inline, first save it with `write_file`, then present the saved file.
    \\- Optional `label` overrides the displayed name; optional `caption` adds a note below the row.
    \\
;

pub const present_files_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "present_files",
        .description =
        \\Present one or more workspace files as inline-preview cards in the chat transcript — when the user asks to "share", "attach", "present", "send", "show", "preview", "render" or "download" a file, or when you just created/edited one (report, image, export, notes, html page) and want it visible inline.
        \\
        \\Every entry must exist, be ≤ 50 MiB, contain no `..` and live INSIDE the session working directory — the only place the browser is served file bytes from, so a path outside it (e.g. under ~/Downloads) is rejected: copy the file in first (`bash cp "<path>" "<working-dir>/"`) and present the copy. A missing file, a directory and a relative path are rejected too, each with a structured error naming the offending path.
        \\
        \\The card previews images, html (sandboxed iframe), text/markdown/code, pdf and video/audio inline; any other type gets a file row with a download button. Bytes are served on demand from GET /api/files/download — the server stats each file and returns metadata only.
        \\
        \\OUTPUT (JSON): {"status":"presented","count":N,"files":[{"path":...,"bytes":...,"mime":...,"label":...}],"error":null}, or {"status":null,"count":0,"files":[],"error":"..."} on failure. This tool writes nothing to disk — to show generated content inline, save it with `write_file` first.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "files",
                    .type = "array",
                    .description = "1-10 files, each {path (absolute, or relative to `cwd`), label? (display name), caption? (note)}.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the directory this call works in — a relative `path` resolves against it, an absolute `path` is used as-is. Pass the tree you are actually editing (your worktree root, NOT the server's directory).",
                },
            },
            .required = &.{ "files", "cwd" },
        },
        .system_prompt = present_files_tool_system_prompt,
    },
};

// ─── JSON helpers ──────────────────────────────────────────────────────
//
// JSON payloads mirror the old `<present_files>` envelope 1:1: `status`,
// `count`, and `files` (one object per former `<file>` tag with `path`,
// `bytes`, `mime`, `label`). The old `<error>`-only envelope becomes the
// same object with an explicit `error` string and null `status`.
// Free-text fields are sanitized for control characters; `std.json`
// handles the remaining escaping.

pub const PresentFileJSON = struct {
    path: []const u8,
    bytes: u64,
    mime: []const u8,
    label: []const u8,
};

pub const PresentFilesJSON = struct {
    status: ?[]const u8 = null,
    count: usize = 0,
    files: []PresentFileJSON = &.{},
    @"error": ?[]const u8 = null,
};

const sanitize_control_chars = @import("helpers").sanitize_control_chars;

/// Build the error envelope: `{"error": ...}` with explicit nulls for
/// the success fields.
fn jsonErrorEnvelope(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize_control_chars(allocator, msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, PresentFilesJSON{
        .@"error" = clean,
    }, .{});
}

// ─── MIME detection ──────────────────────────────────────────────────────
//
// Extension-based, mirroring `static_files.zig:mimeForPath` (kept local
// per the tool self-containment convention). Unknown extensions fall
// back to `application/octet-stream` so the browser downloads instead
// of rendering.

const MimeEntry = struct {
    ext: []const u8,
    mime: []const u8,
};

const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = ".log", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".zig", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".ts", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".py", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".mp4", .mime = "video/mp4" },
};

/// Returns the mime string for `path`'s extension (case-insensitive
/// ASCII, last `.` after the final `/`). Unknown or missing extensions
/// yield `application/octet-stream`.
pub fn mimeForPath(path: []const u8) []const u8 {
    var dot_idx: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            dot_idx = null;
        } else if (c == '.') {
            dot_idx = i;
        }
    }
    const ext_start = dot_idx orelse return "application/octet-stream";
    const ext = path[ext_start..];
    for (mime_table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

// ─── Core execution ──────────────────────────────────────────────────────

/// Stat one file: open (rejecting directories) + size. Returns the size
/// on success. Errors:
///   - `error.FileNotFound` — missing, unreadable, or a directory.
///   - `error.FileTooLarge` — size exceeds `MAX_FILE_BYTES`.
fn statFileSize(io: std.Io, path: []const u8) !u64 {
    // Any open failure (missing, dir, permissions, device errors)
    // surfaces as FileNotFound — the caller reports "not found (or is
    // a directory)", which is the actionable signal for the LLM.
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return error.FileNotFound;
    defer std.Io.File.close(file, io);
    const stat = std.Io.File.stat(file, io) catch return error.FileNotFound;
    if (stat.size > MAX_FILE_BYTES) return error.FileTooLarge;
    return stat.size;
}

/// Execute the tool: validate every file, then build the success
/// object. Any validation failure yields an `{"error": ...}` object
/// naming the offending path (never a Zig error return — the LLM sees a
/// structured failure it can act on).
///
/// `sandbox_root` is the session working directory — the ONLY place the
/// browser can be served bytes from (`GET /api/files/download`). A file
/// outside it would render a card whose every fetch 403s with "Path escapes
/// the session working directory", so it is rejected here instead, with a
/// message the model can act on (copy the file in, or tell the user the
/// path). Pass `null` (or `""`) only from dispatches that have no session
/// row at all — the TUI and routines — which keep the un-sandboxed
/// behaviour they had before this rule existed.
pub fn executePresentFilesToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PresentFilesInput,
    sandbox_root: ?[]const u8,
) ![]u8 {
    if (input.files.len == 0) {
        return jsonErrorEnvelope(allocator, "present_files requires at least 1 file in `files`.");
    }
    // Every path here is model-supplied. On Windows a malformed NT name
    // panics the process inside std's Io backend instead of failing the
    // call, so validate before touching any of them.
    for (input.files) |f| {
        if (invalidPathReason(f.path)) |reason| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "present_files: path \"{s}\" is not a valid path on this platform: {s}",
                .{ f.path, reason },
            );
            defer allocator.free(msg);
            return jsonErrorEnvelope(allocator, msg);
        }
    }
    if (input.files.len > MAX_FILES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "present_files accepts at most {d} files per call (got {d}). Split across multiple calls.",
            .{ MAX_FILES, input.files.len },
        );
        defer allocator.free(msg);
        return jsonErrorEnvelope(allocator, msg);
    }

    var files = std.ArrayList(PresentFileJSON).empty;
    defer files.deinit(allocator);
    // Sanitized labels are owned here and freed after serialization
    // (`Stringify` copies every byte into the returned payload).
    var owned_labels = std.ArrayList([]u8).empty;
    defer {
        for (owned_labels.items) |l| allocator.free(l);
        owned_labels.deinit(allocator);
    }

    for (input.files) |f| {
        // Empty path is what an LLM that emits `"path": ""` produces
        // (the frontend's atomic-mode-switch trap in PR #291) — reject
        // with a clear message, never pass "" to isAbsolute/stat.
        if (f.path.len == 0) {
            return jsonErrorEnvelope(allocator, "present_files: one entry has an empty `path`. Each file needs a non-empty ABSOLUTE path.");
        }
        if (!std.fs.path.isAbsolute(f.path)) {
            const msg = try std.fmt.allocPrint(allocator, "present_files: path \"{s}\" is not absolute. Pass an ABSOLUTE path.", .{f.path});
            defer allocator.free(msg);
            return jsonErrorEnvelope(allocator, msg);
        }
        // Containment, through the same helper the download endpoint uses.
        // Runs BEFORE the stat so a file outside the working directory is
        // reported as such (the actionable signal) instead of a confusing
        // "not found", and so a symlink out of the root is caught at all —
        // `openFile` would happily read the target.
        if (sandbox_root) |root| {
            if (root.len > 0) {
                if (file_sandbox.resolveInsideRoot(io, allocator, root, f.path, file_sandbox.nativeStyle())) |canon| {
                    defer allocator.free(canon);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Missing file (or a directory we cannot canonicalize):
                    // fall through to the stat below, which words it as
                    // "not found (or is a directory)" — the actionable form.
                    error.TargetUnreachable => {},
                    error.NotAbsolute => {
                        const msg = try std.fmt.allocPrint(allocator, "present_files: path \"{s}\" is not absolute. Pass an ABSOLUTE path.", .{f.path});
                        defer allocator.free(msg);
                        return jsonErrorEnvelope(allocator, msg);
                    },
                    error.PathTraversal => {
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "present_files: path \"{s}\" contains a \"..\" segment. Pass the final absolute path — parent segments are refused by the download endpoint too.",
                            .{f.path},
                        );
                        defer allocator.free(msg);
                        return jsonErrorEnvelope(allocator, msg);
                    },
                    error.RootNotAbsolute, error.RootUnreachable => {
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "present_files: the session working directory \"{s}\" is not accessible, so no file can be presented. Tell the user the full path instead.",
                            .{root},
                        );
                        defer allocator.free(msg);
                        return jsonErrorEnvelope(allocator, msg);
                    },
                    error.OutsideRoot => {
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "present_files: \"{s}\" is outside the session working directory \"{s}\". The chat can only preview files from the working directory, so copy it in first (bash cp \"{s}\" \"{s}/\") and present the copy — or tell the user the full path so they can open it themselves.",
                            .{ f.path, root, f.path, root },
                        );
                        defer allocator.free(msg);
                        return jsonErrorEnvelope(allocator, msg);
                    },
                }
            }
        }
        const size = statFileSize(io, f.path) catch |err| switch (err) {
            error.FileNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file not found (or is a directory): \"{s}\".", .{f.path});
                defer allocator.free(msg);
                return jsonErrorEnvelope(allocator, msg);
            },
            error.FileTooLarge => {
                const msg = try std.fmt.allocPrint(allocator, "present_files: file \"{s}\" exceeds the {d} MiB limit.", .{ f.path, MAX_FILE_BYTES / (1024 * 1024) });
                defer allocator.free(msg);
                return jsonErrorEnvelope(allocator, msg);
            },
        };

        const mime = mimeForPath(f.path);
        const raw_label = f.label orelse "";
        const base_label: []const u8 = if (raw_label.len > 0) raw_label else std.fs.path.basename(f.path);
        const clean_label = try sanitize_control_chars(allocator, base_label);
        try owned_labels.append(allocator, clean_label);

        try files.append(allocator, .{
            .path = f.path,
            .bytes = size,
            .mime = mime,
            .label = clean_label,
        });
    }

    return try std.json.Stringify.valueAlloc(allocator, PresentFilesJSON{
        .status = "presented",
        .count = files.items.len,
        .files = files.items,
    }, .{});
}

const testing = std.testing;
const present_files = @import("present_files.zig");

// ─── Helpers ─────────────────────────────────────────────────────────────

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Open a fresh `std.Io.Threaded` runtime. Mirrors the setup helper
/// in `kanban_list.zig` (same pattern).
fn setupIo() std.Io.Threaded {
    const threaded = std.Io.Threaded.init(testing.allocator, .{});
    return threaded;
}

// ─── Behavioral tests ────────────────────────────────────────────────────

test "executePresentFilesToString rejects empty files list" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const input = PresentFilesInput{ .files = @constCast(&[_]PresentFileRef{}) };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("status").? == .null);
    try testing.expect(obj.get("error").? == .string);
}

test "executePresentFilesToString rejects relative path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "relative/path.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("status").? == .null);

    // Two different guards reject a relative path, and which one fires
    // first is platform-dependent:
    //
    //   - POSIX: `invalidPathReason` returns null (the shape is merely
    //     unusual, not dangerous), so the `std.fs.path.isAbsolute` guard
    //     below it produces "... is not absolute. Pass an ABSOLUTE path."
    //   - Windows: the NT-name guard in helpers/path_validate.zig fires
    //     first — a bare name reaches NtCreateFile as a malformed NT
    //     name, which panics the process rather than failing the call —
    //     and produces "... is not a valid path on this platform: path
    //     must be an absolute Windows path (e.g. C:\dir\file)".
    //
    // Both refusals are correct; the test asserts the message that this
    // platform actually emits rather than the POSIX-shaped one.
    const err_msg = obj.get("error").?.string;
    if (builtin.os.tag == .windows) {
        try testing.expect(std.mem.indexOf(u8, err_msg, "absolute Windows path") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, err_msg, "not absolute") != null);
    }
}

test "executePresentFilesToString rejects empty path" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error").? == .string);
}

test "executePresentFilesToString rejects missing file" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs = [_]PresentFileRef{.{ .path = "/tmp/pabrik-present-files-does-not-exist-xyz.txt" }};
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "not found") != null);
}

test "executePresentFilesToString rejects too many files" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    var refs: [11]PresentFileRef = undefined;
    for (&refs) |*r| r.* = .{ .path = "/tmp/x.txt" };
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error").? == .string);
}

test "executePresentFilesToString returns success envelope for real files" {
    const alloc = testing.allocator;
    var threaded = setupIo();
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_dir = "/tmp/pabrik-present-files-test";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const txt_path = "/tmp/pabrik-present-files-test/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "hello world");
    }
    const jpg_path = "/tmp/pabrik-present-files-test/photo.jpg";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, jpg_path, .{});
        defer std.Io.File.close(f, io);
        // Minimal JPEG magic bytes (FF D8 FF) + payload.
        try std.Io.File.writeStreamingAll(f, io, &[_]u8{ 0xFF, 0xD8, 0xFF, 0x00, 0x01 });
    }

    var refs = [_]PresentFileRef{
        .{ .path = txt_path, .label = "notes" },
        .{ .path = jpg_path },
    };
    const input = PresentFilesInput{ .files = &refs };
    const payload = try present_files.executePresentFilesToString(alloc, io, input, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("presented", obj.get("status").?.string);
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const files = obj.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("notes", files[0].object.get("label").?.string);
    try testing.expectEqualStrings(txt_path, files[0].object.get("path").?.string);
    try testing.expectEqualStrings("text/plain; charset=utf-8", files[0].object.get("mime").?.string);
    try testing.expectEqual(@as(i64, 11), files[0].object.get("bytes").?.integer);
    try testing.expectEqualStrings("photo.jpg", files[1].object.get("label").?.string);
    try testing.expectEqualStrings("image/jpeg", files[1].object.get("mime").?.string);
    try testing.expect(obj.get("error").? == .null);
}

test "mimeForPath maps common extensions and falls back to octet-stream" {
    try testing.expectEqualStrings("image/jpeg", present_files.mimeForPath("/a/photo.JPG"));
    try testing.expectEqualStrings("image/png", present_files.mimeForPath("/a/img.png"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", present_files.mimeForPath("/a/notes.txt"));
    try testing.expectEqualStrings("application/pdf", present_files.mimeForPath("/a/doc.pdf"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/noext"));
    try testing.expectEqualStrings("application/octet-stream", present_files.mimeForPath("/a/file.unknownext"));
}

// ─── Sandbox tests ───────────────────────────────────────────────────────
//
// The reported bug: the tool returned `{"status":"presented"}` for a file the
// download endpoint refuses to serve, so the card rendered and every fetch
// 403'd with "Path escapes the session working directory" (Windows, a report
// the agent had written under `C:\Users\<user>\Downloads\`). The tool now
// applies the SAME rule as the endpoint, through `file_sandbox.zig`.
//
// Fixtures are built with `std.testing.tmpDir` (never a hardcoded
// `/tmp/...`, which is not absolute on Windows) so every case runs on all CI
// operating systems. "Inside" and "outside" are two sibling temp dirs.

const builtin = @import("builtin");

const Fixture = struct {
    inside: std.testing.TmpDir,
    outside: std.testing.TmpDir,
    inside_abs: []const u8,
    outside_abs: []const u8,
    io: std.Io,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.inside_abs);
        allocator.free(self.outside_abs);
        self.inside.cleanup();
        self.outside.cleanup();
    }
};

fn realPathOf(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(testing.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn setupFixture() !Fixture {
    const alloc = testing.allocator;
    var inside = testing.tmpDir(.{});
    errdefer inside.cleanup();
    var outside = testing.tmpDir(.{});
    errdefer outside.cleanup();
    const inside_abs = try realPathOf(alloc, inside.dir);
    errdefer alloc.free(inside_abs);
    const outside_abs = try realPathOf(alloc, outside.dir);
    return .{
        .inside = inside,
        .outside = outside,
        .inside_abs = inside_abs,
        .outside_abs = outside_abs,
        .io = testing.io,
    };
}

/// Write a file into the "outside" sibling dir; returns its absolute path.
fn makeOutsideFile(allocator: std.mem.Allocator, f: *const Fixture, rel: []const u8, body: []const u8) ![]u8 {
    if (std.fs.path.dirname(rel)) |parent| try f.outside.dir.createDirPath(f.io, parent);
    var file = try f.outside.dir.createFile(f.io, rel, .{});
    defer file.close(f.io);
    try file.writeStreamingAll(f.io, body);
    return std.fs.path.join(allocator, &.{ f.outside_abs, rel });
}

/// Write a file into the sandbox root; returns its absolute path.
fn makeInsideFile(allocator: std.mem.Allocator, f: *const Fixture, rel: []const u8, body: []const u8) ![]u8 {
    if (std.fs.path.dirname(rel)) |parent| try f.inside.dir.createDirPath(f.io, parent);
    var file = try f.inside.dir.createFile(f.io, rel, .{});
    defer file.close(f.io);
    try file.writeStreamingAll(f.io, body);
    return std.fs.path.join(allocator, &.{ f.inside_abs, rel });
}

fn callTool(allocator: std.mem.Allocator, f: *const Fixture, refs: []PresentFileRef, root: ?[]const u8) ![]u8 {
    const input = PresentFilesInput{ .files = refs };
    return present_files.executePresentFilesToString(allocator, f.io, input, root);
}

/// Assert the failure envelope shape and hand back the error string (the
/// parsed tree is freed with `parsed`, so the string is only valid for the
/// caller's own parse — see `errorMessage`).
fn expectErrorEnvelope(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    const obj = parsed.value.object;
    try testing.expect(obj.get("status").? == .null);
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("files").?.array.items.len);
    try testing.expect(obj.get("error").? == .string);
    return parsed;
}

fn errorMessage(parsed: *const std.json.Parsed(std.json.Value)) []const u8 {
    return parsed.value.object.get("error").?.string;
}

/// Present `refs` and return the error string of a failing envelope.
fn failureMessage(allocator: std.mem.Allocator, f: *const Fixture, refs: []PresentFileRef, root: ?[]const u8) ![]u8 {
    const payload = try callTool(allocator, f, refs, root);
    defer allocator.free(payload);
    var parsed = try expectErrorEnvelope(allocator, payload);
    defer parsed.deinit();
    return allocator.dupe(u8, errorMessage(&parsed));
}

/// Present `refs` and return the first file entry's label.
fn firstLabel(allocator: std.mem.Allocator, f: *const Fixture, refs: []PresentFileRef, root: ?[]const u8) ![]u8 {
    const payload = try callTool(allocator, f, refs, root);
    defer allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
    return allocator.dupe(u8, parsed.value.object.get("files").?.array.items[0].object.get("label").?.string);
}

test "present_files: a file inside the session working directory is presented" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const payload = try callTool(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("count").?.integer);
}

test "present_files: a nested file inside the working directory is presented" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "docs/reports/before-after.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const payload = try callTool(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
}

test "present_files: a file OUTSIDE the working directory is rejected" {
    // The reported Windows case: the agent wrote/kept a report under
    // `C:\Users\<user>\Downloads\…` while the session worked in its worktree.
    // The tool used to answer "presented" and the card 403'd on every fetch.
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "Downloads/report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "outside the session working directory"));
}

test "present_files: the outside-root message names BOTH the file and the working directory" {
    // The model can only act on the failure if it knows where the file was
    // and where it is allowed to put things.
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "Downloads/report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, path));
    try testing.expect(contains(msg, f.inside_abs));
}

test "present_files: the outside-root message tells the model to copy the file in" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "Downloads/report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "copy"));
}

test "present_files: one out-of-root file fails the whole batch and names it" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const good = try makeInsideFile(alloc, &f, "notes.txt", "ok");
    defer alloc.free(good);
    const bad = try makeOutsideFile(alloc, &f, "Downloads/report.html", "<h1>hi</h1>");
    defer alloc.free(bad);

    var refs = [_]PresentFileRef{ .{ .path = good }, .{ .path = bad } };
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, bad));
    // …and the in-root file is not what got rejected.
    try testing.expect(!contains(msg, good));
}

test "present_files: a null sandbox root keeps the un-sandboxed legacy behaviour" {
    // TUI / routine dispatches have no session row, so they pass null and must
    // keep working exactly as before.
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const payload = try callTool(alloc, &f, &refs, null);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
}

test "present_files: an empty sandbox root is treated as no root, not as the filesystem root" {
    // `""` must never be handed to realPath — and it must not 403 every file
    // either (the empty-slice trap from PR #291 in a new costume).
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const payload = try callTool(alloc, &f, &refs, "");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
}

test "present_files: a symlink inside the working directory pointing outside is rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // symlinks need a privilege
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const secret = try makeOutsideFile(alloc, &f, "secret.txt", "s3cret");
    defer alloc.free(secret);
    const link = try std.fs.path.join(alloc, &.{ f.inside_abs, "link.txt" });
    defer alloc.free(link);
    try std.Io.Dir.symLinkAbsolute(f.io, secret, link, .{});

    var refs = [_]PresentFileRef{.{ .path = link }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "outside the session working directory"));
}

test "present_files: a symlink that stays inside the working directory is presented" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const real = try makeInsideFile(alloc, &f, "real.txt", "ok");
    defer alloc.free(real);
    const link = try std.fs.path.join(alloc, &.{ f.inside_abs, "link.txt" });
    defer alloc.free(link);
    try std.Io.Dir.symLinkAbsolute(f.io, real, link, .{});

    var refs = [_]PresentFileRef{.{ .path = link }};
    const payload = try callTool(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("presented", parsed.value.object.get("status").?.string);
}

test "present_files: a parent-segment path is rejected before the sandbox check" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "notes.txt", "ok");
    defer alloc.free(path);
    const dotdot = try std.fs.path.join(alloc, &.{ f.inside_abs, "..", "notes.txt" });
    defer alloc.free(dotdot);

    var refs = [_]PresentFileRef{.{ .path = dotdot }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, ".."));
}

test "present_files: a missing file inside the working directory reports not-found, not outside" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try std.fs.path.join(alloc, &.{ f.inside_abs, "nope.txt" });
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "not found"));
    try testing.expect(!contains(msg, "outside the session working directory"));
}

test "present_files: a directory inside the working directory is rejected as not-found" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    try f.inside.dir.createDirPath(f.io, "sub");
    const path = try std.fs.path.join(alloc, &.{ f.inside_abs, "sub" });
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "not found"));
}

test "present_files: the file-count cap is reported before the sandbox rule" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeOutsideFile(alloc, &f, "report.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs: [MAX_FILES + 1]PresentFileRef = undefined;
    for (&refs) |*r| r.* = .{ .path = path };
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "at most"));
    try testing.expect(!contains(msg, "outside the session working directory"));
}

test "present_files: the empty-list check runs before the sandbox rule" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);

    const msg = try failureMessage(alloc, &f, @constCast(&[_]PresentFileRef{}), f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "at least 1 file"));
}

test "present_files: an empty path is reported before the sandbox rule" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);

    var refs = [_]PresentFileRef{.{ .path = "" }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "empty"));
}

test "present_files: a Windows drive path is rejected as not-absolute on a posix host" {
    // `C:\Users\…` is not a path on Linux, and handing it to realPath aborts
    // the process (its isAbsolute assert), so the guard comes first.
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var refs = [_]PresentFileRef{.{ .path = "C:\\Users\\gilang\\Downloads\\report.html" }};
    const msg = try failureMessage(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(msg);
    try testing.expect(contains(msg, "not absolute"));
}

test "present_files: a file whose name contains spaces is presented" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "IRON-11463 SB-02 open endpoint.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const label = try firstLabel(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(label);
    try testing.expectEqualStrings("IRON-11463 SB-02 open endpoint.html", label);
}

test "present_files: a file whose name contains non-ascii is presented" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "rapor-akhir-印尼.html", "<h1>hi</h1>");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path }};
    const label = try firstLabel(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(label);
    try testing.expectEqualStrings("rapor-akhir-印尼.html", label);
}

test "present_files: NUL and C0/DEL control characters in a label are sanitized" {
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "notes.txt", "ok");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path, .label = "re\u{1}port\u{7f}" }};
    const label = try firstLabel(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(label);
    try testing.expect(!contains(label, "\u{1}"));
    try testing.expect(!contains(label, "\u{7f}"));
    // The readable parts survive so the card still names something useful.
    try testing.expect(contains(label, "re"));
    try testing.expect(contains(label, "port"));
}

test "present_files: a label keeps its tabs and newlines (sanitizeControlChars contract)" {
    // Not a wish of this test — the shared helper deliberately passes \t \n
    // through (they are legal in JSON/XLS text) and only replaces
    // 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F and 0x7F. Pinned here so nobody
    // "fixes" the card by double-escaping a legitimate label.
    const alloc = testing.allocator;
    var f = try setupFixture();
    defer f.deinit(alloc);
    const path = try makeInsideFile(alloc, &f, "notes.txt", "ok");
    defer alloc.free(path);

    var refs = [_]PresentFileRef{.{ .path = path, .label = "line1\nline2\tcol" }};
    const label = try firstLabel(alloc, &f, &refs, f.inside_abs);
    defer alloc.free(label);
    try testing.expect(contains(label, "\n"));
    try testing.expect(contains(label, "\t"));
}
