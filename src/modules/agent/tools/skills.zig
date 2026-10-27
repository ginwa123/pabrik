//! Skill BODY helpers: bundle materialisation. Frontmatter is not parsed
//! here: `pabrikcore.skill_frontmatter` is the single parser, so the two
//! halves of the write path cannot disagree.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const skills_store = pabrikcore.skills_store;

/// Root for materialised asset directories.
const TMP_ROOT = "/tmp";

// ============================================================================
// Asset materialisation
// ============================================================================

/// Why a bundle could not be written out.
pub const MaterializeError = error{
    /// The skill has no companion files. A skill with no assets must
    /// return `asset_dir: null`, not an empty directory.
    NoAssets,
    /// `skill_name` is not a legal single-token name. It becomes a path
    /// segment of the materialisation directory, so `..` here would place
    /// the bundle somewhere else entirely.
    InvalidSkillName,
    /// A `rel_path` escapes the materialisation directory, or is absolute,
    /// or uses a backslash. See `isSafeRelPath`.
    UnsafeAssetPath,
    /// No free directory could be created under the temp root.
    CannotCreateTempDir,
};

/// True when `rel_path` is safe to join onto a directory we just created.
pub fn isSafeRelPath(rel_path: []const u8) bool {
    if (rel_path.len == 0) return false;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return false;
    if (rel_path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, rel_path, '\\') != null) return false;
    // `C:foo` / `Z:bar` — a drive-relative path, absolute for our purposes.
    if (rel_path.len >= 2 and std.ascii.isAlphabetic(rel_path[0]) and rel_path[1] == ':') return false;
    return true;
}

/// Create a fresh, uniquely-named directory under `TMP_ROOT`. Returns an
/// owned path the caller frees with `allocator.free`.
fn createUniqueAssetDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    skill_name: []const u8,
) ![]u8 {
    const stamp = std.Io.Timestamp.now(io, .real).nanoseconds;
    var attempt: u32 = 0;
    while (attempt < 16) : (attempt += 1) {
        var buf: [160]u8 = undefined;
        const leaf = std.fmt.bufPrint(&buf, "pabrik-skill-assets-{s}-{d}-{d}", .{
            skill_name,
            stamp,
            attempt,
        }) catch return error.CannotCreateTempDir;
        const dir = try std.fs.path.join(alloc, &.{ TMP_ROOT, leaf });
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            alloc.free(dir);
            // A name collision is the only expected failure: everything
            // else (permissions, ENOSPC, a missing temp root) is a real
            // filesystem problem the caller has to hear about.
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return dir;
    }
    return error.CannotCreateTempDir;
}

/// Write every companion file of one skill into a fresh directory and return
/// it.
pub fn materializeAssetDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    skill_name: []const u8,
    assets: []const skills_store.SkillAssetRow,
) !struct { dir: []const u8, file_count: usize } {
    if (assets.len == 0) return error.NoAssets;
    if (!skills_store.isValidSkillName(skill_name)) return error.InvalidSkillName;
    for (assets) |a| {
        if (!isSafeRelPath(a.rel_path)) return error.UnsafeAssetPath;
    }

    const dir = try createUniqueAssetDir(io, alloc, skill_name);
    // Everything below is a partial-materialisation failure from here on,
    // so unwind the tree rather than leaving an orphan directory holding
    // half a bundle.
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    for (assets) |a| {
        const full = try std.fs.path.join(alloc, &.{ dir, a.rel_path });
        defer alloc.free(full);

        // `dirname` yields `dir` itself for a top-level file, and
        // `createDirPath` on an existing directory is a no-op.
        const parent = std.fs.path.dirname(full) orelse dir;
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| return err;

        const file = std.Io.Dir.createFileAbsolute(io, full, .{}) catch |err| return err;
        defer std.Io.File.close(file, io);
        std.Io.File.writeStreamingAll(file, io, a.content) catch |err| return err;
    }

    return .{ .dir = dir, .file_count = assets.len };
}

// ============================================================================
// skills.zig — inline tests
// ============================================================================

const testing = std.testing;

/// A `SkillAssetRow` without a database behind it. Every field is a plain
/// slice, so the materialiser's only real input is `(rel_path, content)`
/// and no store fixture is needed to exercise the traversal guard.
fn fakeAsset(rel_path: []const u8, content: []const u8) skills_store.SkillAssetRow {
    return .{
        .id = "sa_1",
        .skill_id = "sk_1",
        .rel_path = rel_path,
        .content = content,
        .created_at = "",
    };
}

test "materializeAssetDir writes each asset at its rel_path, creating parents" {
    const alloc = testing.allocator;
    const io = testing.io;

    const out = try materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts/convert.py", "print('hi')"),
        fakeAsset("references/schemas.md", "# ref"),
        fakeAsset("README.md", "top level"),
    });
    defer alloc.free(out.dir);
    defer std.Io.Dir.cwd().deleteTree(io, out.dir) catch {};

    try testing.expectEqual(@as(usize, 3), out.file_count);
    // Absolute, so the model can pass it to bash/read_file directly.
    try testing.expect(std.fs.path.isAbsolute(out.dir));
    try testing.expect(std.mem.indexOf(u8, out.dir, "pabrik-skill-assets-pdf-") != null);

    // Two levels of nesting created, relative paths preserved verbatim —
    // the body refers to these strings and nothing renames them.
    const nested = try std.fs.path.join(alloc, &.{ out.dir, "scripts", "convert.py" });
    defer alloc.free(nested);
    const script_body = try std.Io.Dir.cwd().readFileAlloc(io, nested, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(script_body);
    try testing.expectEqualStrings("print('hi')", script_body);

    const deep = try std.fs.path.join(alloc, &.{ out.dir, "references", "schemas.md" });
    defer alloc.free(deep);
    const deep_body = try std.Io.Dir.cwd().readFileAlloc(io, deep, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(deep_body);
    try testing.expectEqualStrings("# ref", deep_body);

    const top = try std.fs.path.join(alloc, &.{ out.dir, "README.md" });
    defer alloc.free(top);
    const top_body = try std.Io.Dir.cwd().readFileAlloc(io, top, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(top_body);
    try testing.expectEqualStrings("top level", top_body);
}

test "materializeAssetDir refuses a traversing / absolute / backslash rel_path" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Each of these would land outside the directory we just created.
    // Silently skipping one would hand the model a body that points at a
    // file that does not exist, so every arm must be an error.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("../../etc/passwd", "pwned"),
    }));
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts/../../escape.py", "pwned"),
    }));
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("/etc/passwd", "pwned"),
    }));
    // Backslash is a separator on Windows, so a path that is inert on
    // Linux is a traversal there.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("scripts\\..\\..\\escape.py", "pwned"),
    }));
    // NT drive prefix.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("C:payload", "pwned"),
    }));
    // Empty rel_path has no parent to write into.
    try testing.expectError(error.UnsafeAssetPath, materializeAssetDir(io, alloc, "pdf", &.{
        fakeAsset("", "pwned"),
    }));

    // A legal name is not caught by the same substring rule: the guard is
    // about escaping, not about punctuation.
    try testing.expect(isSafeRelPath("scripts/run_eval.py"));
    try testing.expect(isSafeRelPath("agents/grader.md"));
    try testing.expect(!isSafeRelPath("a..b"));
}

test "materializeAssetDir refuses a name that is not a single path-safe token" {
    const alloc = testing.allocator;
    const io = testing.io;

    // `skill_name` is a path SEGMENT of the materialisation directory, so the
    // same guard the store's `isValidSkillName` applies to the row key has to
    // apply here.
    try testing.expectError(error.InvalidSkillName, materializeAssetDir(io, alloc, "..", &.{
        fakeAsset("a.py", "x"),
    }));
    try testing.expectError(error.InvalidSkillName, materializeAssetDir(io, alloc, "a/b", &.{
        fakeAsset("a.py", "x"),
    }));
}

test "materializeAssetDir refuses an empty bundle instead of making an empty dir" {
    const alloc = testing.allocator;
    const io = testing.io;

    // `use_skill` returns `asset_dir: null` for a skill with no
    // companions; there is no directory at all in that case, so this must
    // not quietly create one.
    try testing.expectError(error.NoAssets, materializeAssetDir(io, alloc, "single-file", &.{}));
}
