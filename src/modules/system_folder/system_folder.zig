//! System folder path utilities
//! 
//! Provides utilities for resolving paths relative to home directory.

const std = @import("std");
const builtin = @import("builtin");
const git_hardening = @import("helpers").git_hardening;

/// Error set for system folder operations
pub const SystemFolderError = error{
    HomeNotFound,
    OutOfMemory,
    InvalidPath,
    AccessDenied,
    NotDirectory,
};

/// Directory entry for folder listing
pub const FolderEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

/// Namespace containing system folder utilities
pub const SystemFolder = struct {
    /// Get the relative path from home directory If `full_path` starts with
    /// `home`, returns the portion after home. Otherwise, returns the
    /// original `full_path` unchanged.
    pub fn getRelativePathFromHome(allocator: std.mem.Allocator, full_path: []const u8, home: []const u8) SystemFolderError![]u8 {
        // Normalize home path (remove trailing slash or backslash).
        // Windows homes look like `C:\Users\ginwa` (or `C:/Users/ginwa`
        // under Git Bash) — strip one trailing separator of either kind.
        const normalized_home = if (home.len > 0 and (home[home.len - 1] == '/' or home[home.len - 1] == '\\'))
            home[0..home.len - 1]
        else
            home;

        // Normalize full_path to remove trailing slash/backslash (but keep
        // filesystem roots like `/`, `C:\`, `C:/` intact).
        const normalized_path = if (full_path.len > 1 and (full_path[full_path.len - 1] == '/' or full_path[full_path.len - 1] == '\\'))
            full_path[0..full_path.len - 1]
        else
            full_path;
        
        // Check if full_path starts with home
        if (!std.mem.startsWith(u8, normalized_path, normalized_home)) {
            // Path doesn't start with home, return absolute path unchanged
            return allocator.dupe(u8, full_path);
        }
        
        // Check if path equals home exactly
        const after_home = normalized_path[normalized_home.len..];
        
        if (after_home.len == 0) {
            // Path equals home exactly
            return allocator.dupe(u8, "/");
        }
        
        // Remove leading slash/backslash from the remainder
        // (Windows remainder looks like `\Documents` when home is
        // `C:\Users\ginwa`).
        const remainder = if (after_home.len > 0 and (after_home[0] == '/' or after_home[0] == '\\'))
            after_home[1..]
        else
            after_home;
        
        // Build result with leading slash
        const result = try std.fmt.allocPrint(allocator, "/{s}", .{remainder});
        return result;
    }
    
    /// Get home directory from environment On POSIX the canonical var is
    /// `HOME`.
    pub fn getHomeDirectory(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const env = environment orelse return SystemFolderError.HomeNotFound;
        if (env.get("HOME")) |h| {
            if (h.len > 0) return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        if (env.get("USERPROFILE")) |u| {
            if (u.len > 0) return allocator.dupe(u8, u) catch return SystemFolderError.OutOfMemory;
        }
        // Last resort on Windows: HOMEDRIVE (e.g. "C:") + HOMEPATH (e.g. "\Users\ginwa")
        if (env.get("HOMEDRIVE")) |drive| {
            if (env.get("HOMEPATH")) |hpath| {
                if (drive.len > 0 and hpath.len > 0) {
                    const joined = std.fs.path.join(allocator, &.{ drive, hpath }) catch return SystemFolderError.OutOfMemory;
                    return joined;
                }
            }
        }
        // Compat: on POSIX an explicitly-set-but-empty HOME historically
        // succeeded with "" (see test "HOME=empty string still succeeds").
        if (env.get("HOME")) |h| {
            return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        return SystemFolderError.HomeNotFound;
    }
    
    /// Get the current working directory
    pub fn getCurrentWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
        return std.process.getCwdAlloc(allocator);
    }
    
    /// Get relative path from home for current working directory
    pub fn getCwdRelativeToHome(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        const cwd = try getCurrentWorkingDirectory(allocator);
        defer allocator.free(cwd);

        return getRelativePathFromHome(allocator, cwd, home);
    }

    /// Resolve a relative path to absolute path (relative to home)
    pub fn resolvePath(allocator: std.mem.Allocator, relative_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Check if path already starts with home directory (absolute path)
        if (std.mem.startsWith(u8, relative_path, home)) {
            return allocator.dupe(u8, relative_path);
        }

        // If path starts with /, it's an absolute Unix path - return as-is
        if (std.mem.startsWith(u8, relative_path, "/")) {
            return allocator.dupe(u8, relative_path);
        }

        // Windows absolute path: drive letter (`C:\...`, `C:/...`) or
        // UNC (`\\server\share`). Return as-is so `listDirectory` can
        // open it directly via `openDirAbsolute`.
        if (relative_path.len >= 2 and std.ascii.isAlphabetic(relative_path[0]) and relative_path[1] == ':') {
            return allocator.dupe(u8, relative_path);
        }
        if (std.mem.startsWith(u8, relative_path, "\\\\") or std.mem.startsWith(u8, relative_path, "//")) {
            return allocator.dupe(u8, relative_path);
        }

        // Otherwise treat as absolute path
        return allocator.dupe(u8, relative_path);
    }

    /// List directory contents (first level only)
    pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) SystemFolderError![]FolderEntry {
        if (!std.fs.path.isAbsolute(dir_path)) return SystemFolderError.InvalidPath;

        var entries = std.ArrayList(FolderEntry).empty;
        errdefer entries.deinit(allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            return SystemFolderError.InvalidPath;
        };
        defer std.Io.Dir.close(dir, io);

        // First pass: collect non-hidden dir/file children. Names are duped
        // (iterator buffers are reused on next()) so the git batch below can
        // hold them all at once.
        const RawChild = struct {
            name: []u8,
            is_dir: bool,
        };
        var children = std.ArrayList(RawChild).empty;
        defer {
            for (children.items) |c| allocator.free(c.name);
            children.deinit(allocator);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const name = entry.name;
            if (name.len == 0) break;

            // Skip hidden files/folders (starting with .)
            if (name.len > 0 and name[0] == '.') continue;

            const is_dir = entry.kind == .directory;
            const is_file = entry.kind == .file;

            if (!is_dir and !is_file) continue;
            const dup = allocator.dupe(u8, name) catch continue;
            children.append(allocator, .{ .name = dup, .is_dir = is_dir }) catch {
                allocator.free(dup);
                continue;
            };
        }

        // ONE `git check-ignore` for the whole directory (was: one spawn per
        // entry — ~30ms each on macOS).
        var batch_names = std.ArrayList([]const u8).empty;
        defer batch_names.deinit(allocator);
        for (children.items) |c| batch_names.append(allocator, c.name) catch break;
        const ignored = batchIgnoredNames(allocator, io, dir_path, batch_names.items);
        defer freeIgnored(allocator, ignored);

        // Second pass: drop gitignored rows, keep the rest.
        for (children.items) |c| {
            if (isIgnored(ignored, c.name)) continue;
            const entry_name = allocator.dupe(u8, c.name) catch continue;
            const full_path = std.fs.path.join(allocator, &.{ dir_path, c.name }) catch {
                allocator.free(entry_name);
                continue;
            };

            entries.append(allocator, FolderEntry{
                .name = entry_name,
                .path = full_path,
                .is_directory = c.is_dir,
                // Symlinks never reach here (kind filter above drops
                // them) — same as the old per-entry code where
                // `is_symlink` was always false for kept rows.
                .is_symlink = false,
            }) catch {
                allocator.free(entry_name);
                allocator.free(full_path);
                continue;
            };
        }

        // Sort: directories first, then files, alphabetically
        std.mem.sort(FolderEntry, entries.items, {}, struct {
            fn less(_: void, a: FolderEntry, b: FolderEntry) bool {
                if (a.is_directory != b.is_directory) {
                    return a.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);

        return entries.toOwnedSlice(allocator);
    }

    /// Exact entry names never descended into (nor returned) by
    /// `searchFiles`. Single const array so `listDirectory` and search
    /// share it later. Case-sensitive exact match on the entry name.
    pub const search_skip_names: []const []const u8 = &.{
        "node_modules",
        "zig-out",
        ".zig-cache",
        "zig-cache",
        "target",
        "dist",
    };

    fn isSearchSkipped(name: []const u8) bool {
        // Dotfiles/dot-dirs skipped, mirroring listDirectory.
        if (name.len > 0 and name[0] == '.') return true;
        for (search_skip_names) |skip| {
            if (std.mem.eql(u8, name, skip)) return true;
        }
        return false;
    }

    /// Batch `git check-ignore` for every entry name in ONE directory. Why
    /// batched: the old code spawned one `git -C <dir> check-ignore <name>`
    /// per ENTRY.
    fn batchIgnoredNames(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        names: []const []const u8,
    ) ?[][]const u8 {
        if (names.len == 0) return null;
        var ignored = std.ArrayList([]const u8).empty;
        var offset: usize = 0;
        while (offset < names.len) {
            const end = @min(offset + 500, names.len);
            const chunk = names[offset..end];
            offset = end;
            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);
            // `--` ends option parsing so names starting with `-` are treated
            // as paths (the old per-entry form had no `--` and mis-checked
            // such names as flags — this is strictly more correct, same
            git_hardening.appendGit(&argv, allocator) catch break;
            argv.appendSlice(allocator, &.{ "-C", dir_path, "check-ignore", "--" }) catch break;
            argv.appendSlice(allocator, chunk) catch break;
            const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch continue;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            // exit 0 = >=1 ignored (parse stdout); 1 = none ignored;
            // 128/fatal = not a repo -> none ignored (fall-through).
            if (result.term.exited != 0) continue;
            var it = std.mem.splitScalar(u8, result.stdout, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r");
                if (trimmed.len == 0) continue;
                // git echoes the input basename for each ignored path.
                const dup = allocator.dupe(u8, trimmed) catch continue;
                ignored.append(allocator, dup) catch {
                    allocator.free(dup);
                    continue;
                };
            }
        }
        if (ignored.items.len == 0) {
            ignored.deinit(allocator);
            return null;
        }
        const out = ignored.toOwnedSlice(allocator) catch {
            for (ignored.items) |s| allocator.free(s);
            ignored.deinit(allocator);
            return null;
        };
        return out;
    }

    fn isIgnored(ignored: ?[][]const u8, name: []const u8) bool {
        const list = ignored orelse return false;
        for (list) |ig| {
            if (std.mem.eql(u8, ig, name)) return true;
        }
        return false;
    }

    fn freeIgnored(allocator: std.mem.Allocator, ignored: ?[][]const u8) void {
        const list = ignored orelse return;
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }

    /// Case-insensitive ASCII substring check (mirrors the
    /// lessThanIgnoreCase sort used below).
    pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// Case-insensitive subsequence check (FileInput `matchesOutOfOrder`
    /// semantics): every needle char appears in haystack in order, gaps
    /// OK — so `tst` still matches `test`, `cmps` matches `components`.
    pub fn matchesSubsequenceIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var hi: usize = 0;
        for (needle) |nc| {
            const lower_nc = std.ascii.toLower(nc);
            var found = false;
            while (hi < haystack.len) : (hi += 1) {
                if (std.ascii.toLower(haystack[hi]) == lower_nc) {
                    hi += 1;
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Match rank: 0 = case-insensitive substring (best), 1 =
    /// subsequence-only. Null when the name does not match at all.
    /// Empty query matches everything at rank 0 (top-N listing).
    fn matchRank(name: []const u8, query: []const u8) ?u8 {
        if (query.len == 0) return 0;
        if (containsIgnoreCase(name, query)) return 0;
        if (matchesSubsequenceIgnoreCase(name, query)) return 1;
        return null;
    }

    /// Parse the `limit` query param: default 50, clamp 1..200 (hard cap),
    /// garbage → default. Pure helper so the HTTP layer is unit-testable.
    pub fn parseSearchLimit(raw: ?[]const u8) usize {
        const s = raw orelse "";
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return 50;
        const n = std.fmt.parseInt(usize, trimmed, 10) catch return 50;
        if (n < 1) return 1;
        if (n > 200) return 200;
        return n;
    }

    /// Parse the `max_depth` query param: default 8, clamp 1..16,
    /// garbage → default. Pure helper so the HTTP layer is unit-testable.
    pub fn parseSearchMaxDepth(raw: ?[]const u8) usize {
        const s = raw orelse "";
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return 8;
        const n = std.fmt.parseInt(usize, trimmed, 10) catch return 8;
        if (n < 1) return 1;
        if (n > 16) return 16;
        return n;
    }

    const SearchHit = struct {
        entry: FolderEntry,
        rank: u8,
    };

    /// Recursive file search under `root_path` (iterative stack, NOT
    /// recursion).
    pub fn searchFiles(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_path: []const u8,
        query: []const u8,
        limit: usize,
        max_depth: usize,
    ) SystemFolderError![]FolderEntry {
        if (!std.fs.path.isAbsolute(root_path)) return SystemFolderError.InvalidPath;

        const cap: usize = if (limit == 0) 50 else if (limit > 200) 200 else limit;
        const depth_cap: usize = if (max_depth == 0) 8 else max_depth;

        var matches = std.ArrayList(SearchHit).empty;
        defer matches.deinit(allocator);

        const StackFrame = struct {
            path: []const u8,
            depth: usize,
        };
        var stack = std.ArrayList(StackFrame).empty;
        defer {
            for (stack.items) |frame| allocator.free(frame.path);
            stack.deinit(allocator);
        }

        const root_dup = allocator.dupe(u8, root_path) catch return SystemFolderError.OutOfMemory;
        stack.append(allocator, .{ .path = root_dup, .depth = 0 }) catch return SystemFolderError.OutOfMemory;

        while (stack.items.len > 0) {
            const frame = stack.pop().?;
            defer allocator.free(frame.path);

            var dir = std.Io.Dir.openDirAbsolute(io, frame.path, .{ .iterate = true }) catch continue;
            defer std.Io.Dir.close(dir, io);

            // First pass: collect candidates passing skip-list / kind / depth
            // (duped names — iterator buffers are reused on next()).
            const child_depth = frame.depth + 1;
            const RawChild = struct {
                name: []u8,
                is_dir: bool,
            };
            var children = std.ArrayList(RawChild).empty;
            defer {
                for (children.items) |c| allocator.free(c.name);
                children.deinit(allocator);
            }
            var iter = dir.iterate();
            while (iter.next(io) catch null) |entry| {
                const name = entry.name;
                if (name.len == 0) break;

                if (isSearchSkipped(name)) continue;

                const is_dir = entry.kind == .directory;
                const is_file = entry.kind == .file;
                if (!is_dir and !is_file) continue;

                if (child_depth > depth_cap) continue;

                const dup = allocator.dupe(u8, name) catch continue;
                children.append(allocator, .{ .name = dup, .is_dir = is_dir }) catch {
                    allocator.free(dup);
                    continue;
                };
            }

            // ONE `git check-ignore` for the whole directory (was: one spawn
            // per entry — ~30ms each on macOS, ~312 spawns for the 300-file
            // fixture).
            var batch_names = std.ArrayList([]const u8).empty;
            defer batch_names.deinit(allocator);
            for (children.items) |c| batch_names.append(allocator, c.name) catch break;
            const ignored = batchIgnoredNames(allocator, io, frame.path, batch_names.items);
            defer freeIgnored(allocator, ignored);

            // Second pass: descend + match (identical semantics to the old
            // loop — non-matching dirs are still descended into since
            // their children may match).
            for (children.items) |c| {
                if (isIgnored(ignored, c.name)) continue;

                // Non-matching dirs are still descended into (their
                // children may match); non-matching files are dropped.
                if (c.is_dir and child_depth < depth_cap) {
                    const dir_path = std.fs.path.join(allocator, &.{ frame.path, c.name }) catch continue;
                    stack.append(allocator, .{ .path = dir_path, .depth = child_depth }) catch {
                        allocator.free(dir_path);
                        continue;
                    };
                }

                const rank = matchRank(c.name, query) orelse continue;
                const entry_name = allocator.dupe(u8, c.name) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ frame.path, c.name }) catch {
                    allocator.free(entry_name);
                    continue;
                };
                matches.append(allocator, SearchHit{
                    .entry = FolderEntry{
                        .name = entry_name,
                        .path = full_path,
                        .is_directory = c.is_dir,
                        // Symlinks never reach here (kind filter above
                        // drops them) — same as the old per-entry code
                        // where `is_symlink` was always false for hits.
                        .is_symlink = false,
                    },
                    .rank = rank,
                }) catch {
                    allocator.free(entry_name);
                    allocator.free(full_path);
                    continue;
                };
            }
        }

        // Rank: substring hits first, then dirs-first, then
        // case-insensitive name order.
        std.mem.sort(SearchHit, matches.items, {}, struct {
            fn less(_: void, a: SearchHit, b: SearchHit) bool {
                if (a.rank != b.rank) return a.rank < b.rank;
                if (a.entry.is_directory != b.entry.is_directory) {
                    return a.entry.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.entry.name, b.entry.name);
            }
        }.less);

        var out = std.ArrayList(FolderEntry).empty;
        const n = @min(cap, matches.items.len);
        for (matches.items[0..n]) |hit| {
            out.append(allocator, hit.entry) catch continue;
        }
        // Dropped tail keeps no ownership — free its strings; the
        // transferred head is owned by `out`. The `matches` backing
        // array itself is freed by the top-of-function defer.
        for (matches.items[n..]) |hit| {
            allocator.free(hit.entry.name);
            allocator.free(hit.entry.path);
        }

        return out.toOwnedSlice(allocator);
    }

    /// Do two spellings of a path name the same directory?
    fn eqlSameDir(a: []const u8, b: []const u8) bool {
        if (builtin.os.tag != .windows) return std.mem.eql(u8, a, b);
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const fa = std.ascii.toLower(if (ca == '/') '\\' else ca);
            const fb = std.ascii.toLower(if (cb == '/') '\\' else cb);
            if (fa != fb) return false;
        }
        return true;
    }

    /// Get parent directory path
    pub fn getParentPath(allocator: std.mem.Allocator, dir_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError!?[]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Don't go above home.
        const norm_dir = if (dir_path.len > 1 and dir_path[dir_path.len - 1] == '\\')
            dir_path[0..dir_path.len - 1]
        else if (builtin.os.tag == .windows and dir_path.len > 1 and dir_path[dir_path.len - 1] == '/')
            dir_path[0..dir_path.len - 1]
        else
            dir_path;
        const norm_home = if (home.len > 1 and home[home.len - 1] == '\\')
            home[0..home.len - 1]
        else if (builtin.os.tag == .windows and home.len > 1 and home[home.len - 1] == '/')
            home[0..home.len - 1]
        else if (home.len == 1 and (home[0] == '/' or home[0] == '\\'))
            home[0..0] // root "/" normalizes to "" so "/"+trailing variants compare equal
        else
            home;
        // Also treat a single trailing `\` on a multi-char home (e.g.
        // `C:\Users\ginwa\`) as equal — covered by the first branch above for
        // dir; for home the `len > 1` backslash branch handles it.
        const norm_home_adj = if (home.len == 1 and home[0] == '\\') home[0..0] else norm_home;
        if (eqlSameDir(norm_dir, norm_home_adj)) {
            return null;
        }
        // POSIX dirname handles `/`-separated paths (including a trailing
        // `/`, which it strips before finding the parent).
        if (std.fs.path.dirname(dir_path)) |p| {
            return try allocator.dupe(u8, p);
        }
        // Manual Windows-separator parent: strip one trailing separator,
        // then cut at the last `/` or `\`. Drive roots (`C:\`, `C:/`, `/`,
        // `\`) have no parent -> null.
        var stripped = dir_path;
        if (stripped.len > 1 and (stripped[stripped.len - 1] == '/' or stripped[stripped.len - 1] == '\\')) {
            stripped = stripped[0..stripped.len - 1];
        }
        const last_sep: ?usize = blk: {
            const b = std.mem.lastIndexOfScalar(u8, stripped, '\\');
            const f = std.mem.lastIndexOfScalar(u8, stripped, '/');
            if (b != null and f != null) break :blk @max(b.?, f.?);
            break :blk b orelse f;
        };
        const idx = last_sep orelse return null;
        if (idx == 0) return null; // `/foo` -> parent is `/`, but bare `/` root -> null; `idx==0` means root-level
        if (idx == 2 and stripped.len >= 3 and std.ascii.isAlphabetic(stripped[0]) and stripped[1] == ':' and (stripped[2] == '/' or stripped[2] == '\\')) {
            // `C:\foo` -> parent is the drive root `C:\` (keep separator style of input)
            return try allocator.dupe(u8, stripped[0..3]);
        }
        // `C:` alone or empty prefix -> null
        if (idx == 0) return null;
        return try allocator.dupe(u8, stripped[0..idx]);
    }
};

// ===== Tests merged from system_folder_test.zig (2026-09-29 flatten) =====
//
// Edge-case tests for src/modules/system_folder/system_folder.zig.

const testing = std.testing;
const helpers = @import("helpers");

const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupTmpRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const abs = try allocator.dupe(u8, path_buf[0..n]);
    return .{ .tmp_dir = tmp, .root_abs = abs };
}

/// Same as setupTmpRoot but the temp dir is NOT inside a gitignored parent.
const ExternalTestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *ExternalTestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        // testing.TmpDir.cleanup() removes the dir + all contents.
        // (Tolerates failures silently.)
        self.tmp_dir.cleanup();
    }
};

fn setupRootInTmp(allocator: std.mem.Allocator) !ExternalTestEnv {
    var tmp = std.testing.tmpDir(.{});

    // Resolve to absolute path for the tests (which use it as a
    // stringly-typed path argument).
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try allocator.dupe(u8, path_buf[0..dir_len]);

    // `git init` so `git check-ignore` recognises this as a git tree (and
    // finds no .gitignore rules → returns "not ignored" for every entry).
    const git_init = std.process.run(allocator, testing.io, .{
        .argv = &.{ "git", "-C", root_abs, "init", "--initial-branch=main", "--quiet" },
    }) catch null;
    if (git_init) |gr| {
        allocator.free(gr.stdout);
        allocator.free(gr.stderr);
    }

    return .{ .tmp_dir = tmp, .root_abs = root_abs };
}

fn makeEnvMap(allocator: std.mem.Allocator, home_value: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    try env.put("HOME", home_value);
    return env;
}

fn makeEnvMapNoHome(allocator: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(allocator);
}

// getRelativePathFromHome tests
test "getRelativePathFromHome: path equals home returns /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: path equals home with trailing slash returns /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: home with trailing slash input handles it" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/docs",
        "/home/user/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/docs", rel);
}

test "getRelativePathFromHome: deeper subdirectory returns /a/b/c" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/projects/pabrik/zig/src",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/projects/pabrik/zig/src", rel);
}

test "getRelativePathFromHome: full_path trailing slash is normalized away" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/docs/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/docs", rel);
}

test "getRelativePathFromHome: full_path does not start with home returns unchanged" {
    const allocator = testing.allocator;
    const original = "/etc/passwd";
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        original,
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings(original, rel);
}

test "getRelativePathFromHome: empty full_path returns empty" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("", rel);
}

test "getRelativePathFromHome: empty home returns / for empty full_path" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "",
        "",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: home as root / gives /subdir for /subdir" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/etc",
        "/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/etc", rel);
}

test "getRelativePathFromHome: home as / gives / for /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/",
        "/",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "getRelativePathFromHome: deep path with trailing slash normalizes correctly" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/a/b/c/",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/a/b/c", rel);
}

test "getRelativePathFromHome: returns heap-owned copies (two calls yield distinct ptrs)" {
    const allocator = testing.allocator;
    const a = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/foo",
        "/home/user",
    );
    const b = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/foo",
        "/home/user",
    );
    defer allocator.free(a);
    defer allocator.free(b);
    try testing.expect(a.ptr != b.ptr);
    try testing.expectEqualStrings(a, b);
}

test "getRelativePathFromHome: unicode path segments pass through verbatim" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/données/фу/日本語",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/données/фу/日本語", rel);
}

test "getRelativePathFromHome: single-segment subdir returns /name" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/user/proj",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/proj", rel);
}

test "getRelativePathFromHome: home-prefix without separator is treated as a subpath" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "/home/userproj",
        "/home/user",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/proj", rel);
}

// getHomeDirectory tests
test "getHomeDirectory: returns HOME value from env" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/test_user");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("/home/test_user", home);
}

test "getHomeDirectory: returns heap-owned copy that can be read independently" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/heap_test");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expect(std.mem.eql(u8, home, "/home/heap_test"));
}

test "getHomeDirectory: environment null yields HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.getHomeDirectory(allocator, null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getHomeDirectory: environment without HOME yields HomeNotFound" {
    const allocator = testing.allocator;
    var env = makeEnvMapNoHome(allocator);
    defer env.deinit();
    const result = SystemFolder.getHomeDirectory(allocator, &env);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getHomeDirectory: HOME=empty string still succeeds (empty path)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "");
    defer env.deinit();
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("", home);
}

// resolvePath tests
test "resolvePath: relative path returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "docs/file.txt", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("docs/file.txt", resolved);
}

test "resolvePath: absolute non-home path returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "/tmp/data.json", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/tmp/data.json", resolved);
}

test "resolvePath: absolute path inside home returns unchanged" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "/home/user/file.txt", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/home/user/file.txt", resolved);
}

test "resolvePath: empty path returns empty" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const resolved = try SystemFolder.resolvePath(allocator, "", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("", resolved);
}

test "resolvePath: null environment returns HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.resolvePath(allocator, "foo", null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

// getParentPath tests
test "getParentPath: dir_path == home returns null (do not go above home)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/home/user", &env);
    try testing.expect(result == null);
}

test "getParentPath: dir_path == home with trailing slash still returns parent" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/home/user/", &env);
    if (result) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: dir_path is subdir of home returns /home/user (parent)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const parent = try SystemFolder.getParentPath(allocator, "/home/user/docs", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home/user", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: deeper subdir returns intermediate parent" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const parent = try SystemFolder.getParentPath(
        allocator,
        "/home/user/projects/pabrik/zig",
        &env,
    );
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("/home/user/projects/pabrik", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: filename without separator returns null (dirname rejects bare files)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "filename.txt", &env);
    try testing.expect(result == null);
}

test "getParentPath: root path returns null (dirname rejects '/')" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();
    const result = try SystemFolder.getParentPath(allocator, "/", &env);
    try testing.expect(result == null);
}

test "getParentPath: null environment yields HomeNotFound" {
    const allocator = testing.allocator;
    const result = SystemFolder.getParentPath(allocator, "/home/user/docs", null);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getParentPath: env without HOME yields HomeNotFound" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = makeEnvMapNoHome(allocator);
    defer env.deinit();
    const result = SystemFolder.getParentPath(allocator, "/home/user/docs", &env);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

// listDirectory tests
test "listDirectory: relative path returns InvalidPath" {
    const result = SystemFolder.listDirectory(
        testing.allocator,
        testing.io,
        "relative/path",
    );
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: empty path returns InvalidPath" {
    const result = SystemFolder.listDirectory(
        testing.allocator,
        testing.io,
        "",
    );
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: nonexistent path returns InvalidPath" {
    const allocator = testing.allocator;
    const io = testing.io;
    const result = SystemFolder.listDirectory(
        allocator,
        io,
        "/this/path/does/not/exist/anywhere",
    );
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: file path returns InvalidPath (not a directory)" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "single.txt", .{});
        defer f.close(testing.io);
    }
    const file_path = try std.fs.path.join(allocator, &.{ tenv.root_abs, "single.txt" });
    defer allocator.free(file_path);
    const result = SystemFolder.listDirectory(allocator, testing.io, file_path);
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "listDirectory: empty directory returns empty entries" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "listDirectory: skips dotfiles" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "visible.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, ".hidden", .{});
        defer f.close(testing.io);
    }
    try tenv.tmp_dir.dir.createDirPath(testing.io, ".hidden_dir");

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("visible.txt", entries[0].name);
    try testing.expect(!entries[0].is_directory);
    try testing.expect(!entries[0].is_symlink);
}

test "listDirectory: directories sort before files" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "z_subdir");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "a_subdir");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "z_file.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "a_file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 4), entries.len);

    try testing.expect(entries[0].is_directory);
    try testing.expectEqualStrings("a_subdir", entries[0].name);
    try testing.expect(entries[1].is_directory);
    try testing.expectEqualStrings("z_subdir", entries[1].name);
    try testing.expect(!entries[2].is_directory);
    try testing.expectEqualStrings("a_file.txt", entries[2].name);
    try testing.expect(!entries[3].is_directory);
    try testing.expectEqualStrings("z_file.txt", entries[3].name);
}

test "listDirectory: is_directory and is_symlink flags are set correctly" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "real_dir");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "real_file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }

    var found_real_dir = false;
    var found_real_file = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "real_dir")) {
            try testing.expect(e.is_directory);
            try testing.expect(!e.is_symlink);
            found_real_dir = true;
        } else if (std.mem.eql(u8, e.name, "real_file.txt")) {
            try testing.expect(!e.is_directory);
            try testing.expect(!e.is_symlink);
            found_real_file = true;
        }
    }
    try testing.expect(found_real_dir);
    try testing.expect(found_real_file);
}

test "listDirectory: an empty subdir is reported as is_directory=true" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "empty_subdir");

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("empty_subdir", entries[0].name);
    try testing.expect(entries[0].is_directory);
}

test "listDirectory: nested directory listing does not recurse (first-level only)" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "outer");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "outer/inner");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "outer/inner/file.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("outer", entries[0].name);
    // Linux/macOS use `/`; Windows native separator is `\`. Accept
    // either so the test runs cross-platform.
    try testing.expect(
        std.mem.endsWith(u8, entries[0].path, "/outer") or
            std.mem.endsWith(u8, entries[0].path, "\\outer"),
    );
}

test "listDirectory: entries.path is root_abs + '/' + name" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "foo.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.listDirectory(allocator, testing.io, tenv.root_abs);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    const expected_len = tenv.root_abs.len + 1 + "foo.txt".len;
    try testing.expectEqual(expected_len, entries[0].path.len);
    try testing.expectEqualStrings("foo.txt", entries[0].path[tenv.root_abs.len + 1 ..]);
}

// Integration test
test "integration: getParentPath + getRelativePathFromHome produces /-relative breadcrumbs" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var env = try makeEnvMap(allocator, "/home/user");
    defer env.deinit();

    const abs = "/home/user/projects/pabrik";
    const parent_opt = try SystemFolder.getParentPath(allocator, abs, &env);
    try testing.expect(parent_opt != null);
    const parent = parent_opt.?;
    defer allocator.free(parent);

    const parent_rel = try SystemFolder.getRelativePathFromHome(allocator, parent, "/home/user");
    defer allocator.free(parent_rel);
    try testing.expectEqualStrings("/projects", parent_rel);

    const abs_rel = try SystemFolder.getRelativePathFromHome(allocator, abs, "/home/user");
    defer allocator.free(abs_rel);
    try testing.expectEqualStrings("/projects/pabrik", abs_rel);
}

// ─── Windows regression tests (issue: kanban folder picker fails on Windows)
// ─── The picker calls GET /api/system/folder?action=list with no path, which
// hits getHomeDirectory.

test "getHomeDirectory: falls back to USERPROFILE when HOME is missing (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\testuser");
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("C:\\Users\\testuser", home);
}

test "getHomeDirectory: falls back to USERPROFILE when HOME is empty (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "");
    try env.put("USERPROFILE", "C:\\Users\\testuser");
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("C:\\Users\\testuser", home);
}

test "getHomeDirectory: prefers HOME over USERPROFILE when both set" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/testuser");
    try env.put("USERPROFILE", "C:\\Users\\testuser");
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("/home/testuser", home);
}

test "getHomeDirectory: falls back to HOMEDRIVE+HOMEPATH when HOME+USERPROFILE missing (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOMEDRIVE", "C:");
    try env.put("HOMEPATH", "\\Users\\testuser");
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    // std.fs.path.join normalizes to C:\Users\testuser (or C:/Users/testuser on POSIX)
    try testing.expect(home.len > 0);
    try testing.expect(std.mem.indexOf(u8, home, "testuser") != null);
}

test "getHomeDirectory: empty env yields HomeNotFound even on Windows" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const result = SystemFolder.getHomeDirectory(allocator, &env);
    try testing.expectError(SystemFolderError.HomeNotFound, result);
}

test "getRelativePathFromHome: Windows backslash subdir returns /Documents" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/Documents", rel);
}

test "getRelativePathFromHome: Windows home with trailing backslash handled" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa\\",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/Documents", rel);
}

test "getRelativePathFromHome: Windows path equals home returns /" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "C:\\Users\\ginwa",
        "C:\\Users\\ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/", rel);
}

test "resolvePath: Windows drive absolute path returns unchanged" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const resolved = try SystemFolder.resolvePath(allocator, "C:\\Users\\ginwa\\Documents", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("C:\\Users\\ginwa\\Documents", resolved);
}

test "resolvePath: Windows forward-slash drive path returns unchanged" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const resolved = try SystemFolder.resolvePath(allocator, "C:/Users/ginwa/Documents", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("C:/Users/ginwa/Documents", resolved);
}

test "getParentPath: Windows subdir returns Windows parent" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const parent = try SystemFolder.getParentPath(allocator, "C:\\Users\\ginwa\\Documents", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("C:\\Users\\ginwa", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: Windows home with trailing backslash returns null" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const result = try SystemFolder.getParentPath(allocator, "C:\\Users\\ginwa\\", &env);
    try testing.expect(result == null);
}

// ─── searchFiles tests (plan 2026-09-08-chatview-search-files-perf Task 1)
// ─── NOTE: `setupRootInTmp` roots live under `.zig-cache/tmp/<rand>/`, so
// the root_abs PREFIX itself contains ".zig-cache".

fn freeSearchResults(allocator: std.mem.Allocator, entries: []FolderEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    allocator.free(entries);
}

/// True when `needle` appears in the portion of `full_path` BELOW root.
/// (Strips the root_abs prefix so the `.zig-cache/tmp/...` tmp parent
/// never trips skip-list substring checks.)
fn relContains(root_abs: []const u8, full_path: []const u8, needle: []const u8) bool {
    const rel = if (std.mem.startsWith(u8, full_path, root_abs))
        full_path[root_abs.len..]
    else
        full_path;
    return std.mem.indexOf(u8, rel, needle) != null;
}

fn relContainsAny(root_abs: []const u8, entries: []FolderEntry, needle: []const u8) bool {
    for (entries) |e| {
        if (relContains(root_abs, e.path, needle)) return true;
    }
    return false;
}

test "searchFiles: relative root returns InvalidPath" {
    const result = SystemFolder.searchFiles(
        testing.allocator,
        testing.io,
        "relative/path",
        "comp",
        50,
        8,
    );
    try testing.expectError(SystemFolderError.InvalidPath, result);
}

test "searchFiles: skips node_modules, zig-out, zig-cache, target, dist" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "src/components");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "node_modules/big");
    try tenv.tmp_dir.dir.createDirPath(testing.io, ".zig-cache/tmp/x");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "zig-cache/y");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "target/z");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "dist/w");
    try tenv.tmp_dir.dir.createDirPath(testing.io, "zig-out/v");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "src/components/Button.vue", .{});
        defer f.close(testing.io);
    }
    // Decoys with matchable names inside skipped dirs — must never surface.
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "node_modules/big/comp_decoy.js", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "zig-out/v/comp_decoy2.js", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "target/z/comp_decoy3.js", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "comp", 50, 8);
    defer freeSearchResults(allocator, entries);

    try testing.expect(relContainsAny(tenv.root_abs, entries, "components"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, "node_modules"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, "zig-out"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, ".zig-cache"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, "zig-cache"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, "target"));
    try testing.expect(!relContainsAny(tenv.root_abs, entries, "dist"));
}

test "searchFiles: subsequence 'comp' matches 'components' dir" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "src/components");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "src/components/Button.vue", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "comp", 50, 8);
    defer freeSearchResults(allocator, entries);

    var found_components = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "components")) {
            try testing.expect(e.is_directory);
            found_components = true;
        }
    }
    try testing.expect(found_components);
}

test "searchFiles: pure-subsequence query (no substring) still matches" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "src/components");

    // "cmps" is a subsequence of "components" (c-...-m-p-...-s) but NOT a
    // substring — locks in the subsequence fallback.
    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "cmps", 50, 8);
    defer freeSearchResults(allocator, entries);

    var found = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "components")) found = true;
    }
    try testing.expect(found);
}

test "searchFiles: limit caps result count" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "file_{d:0>2}.txt", .{i});
        defer allocator.free(name);
        const f = try tenv.tmp_dir.dir.createFile(testing.io, name, .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "file_", 3, 8);
    defer freeSearchResults(allocator, entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
}

test "searchFiles: empty query returns top-N, not the whole tree" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "note_{d:0>2}.txt", .{i});
        defer allocator.free(name);
        const f = try tenv.tmp_dir.dir.createFile(testing.io, name, .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "", 4, 8);
    defer freeSearchResults(allocator, entries);

    try testing.expectEqual(@as(usize, 4), entries.len);
}

test "searchFiles: substring hits rank before subsequence hits" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "compass.txt", .{});
        defer f.close(testing.io);
    }
    {
        // Matches "comp" by subsequence only (c-_-o-_-m-_-p), not substring.
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "c_o_m_p.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "comp", 50, 8);
    defer freeSearchResults(allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("compass.txt", entries[0].name);
    try testing.expectEqualStrings("c_o_m_p.txt", entries[1].name);
}

test "searchFiles: max_depth bounds descent" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    try tenv.tmp_dir.dir.createDirPath(testing.io, "outer/inner");
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "outer/top.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "outer/inner/deep.txt", .{});
        defer f.close(testing.io);
    }

    // depth: outer=1, top.txt=2, inner=2, deep.txt=3. max_depth=1 visits
    // only root children → "deep" matches nothing.
    const shallow = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "deep", 50, 1);
    defer freeSearchResults(allocator, shallow);
    try testing.expectEqual(@as(usize, 0), shallow.len);

    const deep = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "deep", 50, 8);
    defer freeSearchResults(allocator, deep);
    try testing.expectEqual(@as(usize, 1), deep.len);
    try testing.expectEqualStrings("deep.txt", deep[0].name);
}

test "searchFiles: dotfiles and dot-dirs are skipped" {
    const allocator = testing.allocator;
    var tenv = try setupRootInTmp(allocator);
    defer tenv.deinit(allocator);

    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, ".hidden_comp.txt", .{});
        defer f.close(testing.io);
    }
    {
        const f = try tenv.tmp_dir.dir.createFile(testing.io, "visible_comp.txt", .{});
        defer f.close(testing.io);
    }

    const entries = try SystemFolder.searchFiles(allocator, testing.io, tenv.root_abs, "comp", 50, 8);
    defer freeSearchResults(allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("visible_comp.txt", entries[0].name);
}

test "parseSearchLimit: defaults, clamps 1..200, rejects garbage" {
    try testing.expectEqual(@as(usize, 50), SystemFolder.parseSearchLimit(null));
    try testing.expectEqual(@as(usize, 50), SystemFolder.parseSearchLimit(""));
    try testing.expectEqual(@as(usize, 10), SystemFolder.parseSearchLimit("10"));
    try testing.expectEqual(@as(usize, 1), SystemFolder.parseSearchLimit("0"));
    try testing.expectEqual(@as(usize, 1), SystemFolder.parseSearchLimit("1"));
    try testing.expectEqual(@as(usize, 200), SystemFolder.parseSearchLimit("200"));
    try testing.expectEqual(@as(usize, 200), SystemFolder.parseSearchLimit("5000"));
    try testing.expectEqual(@as(usize, 50), SystemFolder.parseSearchLimit("abc"));
}

test "parseSearchMaxDepth: defaults, clamps 1..16, rejects garbage" {
    try testing.expectEqual(@as(usize, 8), SystemFolder.parseSearchMaxDepth(null));
    try testing.expectEqual(@as(usize, 8), SystemFolder.parseSearchMaxDepth(""));
    try testing.expectEqual(@as(usize, 3), SystemFolder.parseSearchMaxDepth("3"));
    try testing.expectEqual(@as(usize, 1), SystemFolder.parseSearchMaxDepth("0"));
    try testing.expectEqual(@as(usize, 16), SystemFolder.parseSearchMaxDepth("16"));
    try testing.expectEqual(@as(usize, 16), SystemFolder.parseSearchMaxDepth("99"));
    try testing.expectEqual(@as(usize, 8), SystemFolder.parseSearchMaxDepth("abc"));
}

// ─── Windows path-shape tests (UNC, drive roots, mixed separators) ────────
// The block above covers `USERPROFILE` and a plain backslash subdir.

// resolvePath: UNC in both spellings passes through untouched.
test "resolvePath: UNC backslash path returns unchanged (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "\\\\fileserver\\share\\ginwa");
    const resolved = try SystemFolder.resolvePath(allocator, "\\\\fileserver\\share\\ginwa\\Documents", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("\\\\fileserver\\share\\ginwa\\Documents", resolved);
}

test "resolvePath: UNC forward-slash path returns unchanged (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "\\\\fileserver\\share\\ginwa");
    const resolved = try SystemFolder.resolvePath(allocator, "//fileserver/share/ginwa/Documents", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("//fileserver/share/ginwa/Documents", resolved);
}

test "resolvePath: drive-relative C:file is returned unchanged, NOT treated as absolute" {
    // `C:notes.txt` is drive-RELATIVE on Windows: `std.fs.path.isAbsolute` is
    // false for it, so the handler's gate rejects it with 400 "path must be
    // absolute".
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const resolved = try SystemFolder.resolvePath(allocator, "C:notes.txt", &env);
    defer allocator.free(resolved);
    try testing.expectEqualStrings("C:notes.txt", resolved);
}

// getHomeDirectory: a UNC USERPROFILE is a valid home.
test "getHomeDirectory: UNC USERPROFILE is accepted verbatim (Windows)" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "\\\\fileserver\\share\\ginwa");
    const home = try SystemFolder.getHomeDirectory(allocator, &env);
    defer allocator.free(home);
    try testing.expectEqualStrings("\\\\fileserver\\share\\ginwa", home);
}

// getRelativePathFromHome: UNC + forward-slash spellings.
test "getRelativePathFromHome: UNC home subdir returns /Documents" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "\\\\fileserver\\share\\ginwa\\Documents",
        "\\\\fileserver\\share\\ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/Documents", rel);
}

test "getRelativePathFromHome: forward-slash Windows home and path agree" {
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "C:/Users/ginwa/Documents",
        "C:/Users/ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/Documents", rel);
}

test "getRelativePathFromHome: a path on another drive is returned unchanged" {
    // Not under home, so the wire `path` field is the absolute path —
    // the frontend navigates by `entries[].path`, never by this field, so
    // returning it verbatim (rather than a wrong "/...") is the contract.
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "D:\\Data\\notes",
        "C:\\Users\\ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("D:\\Data\\notes", rel);
}

test "getRelativePathFromHome: sibling sharing the home prefix is a subpath" {
    // `C:\Users\ginwa2` starts with `C:\Users\ginwa`, but it is NOT under
    // home.
    const allocator = testing.allocator;
    const rel = try SystemFolder.getRelativePathFromHome(
        allocator,
        "C:\\Users\\ginwa2",
        "C:\\Users\\ginwa",
    );
    defer allocator.free(rel);
    try testing.expectEqualStrings("/2", rel);
}

// getParentPath: drive roots have no parent.
test "getParentPath: Windows drive root returns null" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const result = try SystemFolder.getParentPath(allocator, "C:\\", &env);
    try testing.expect(result == null);
}

test "getParentPath: a child of the drive root returns C:\\" {
    // Above home, so the `dir == home` short-circuit does not apply.
    // Both paths agree on the answer: Windows `dirname` returns `c:\`,
    // and the POSIX-side manual split returns the same three bytes.
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const parent = try SystemFolder.getParentPath(allocator, "C:\\Users", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("C:\\", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: mixed separators resolve the parent" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const parent = try SystemFolder.getParentPath(allocator, "C:/Users/ginwa/Documents", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("C:/Users/ginwa", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: UNC dir outside home returns the share" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    // Home on drive C:, the directory being listed on a network share —
    // a client can ask for any absolute path, not only one under home.
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const parent = try SystemFolder.getParentPath(allocator, "\\\\fileserver\\share\\doc", &env);
    if (parent) |p| {
        defer allocator.free(p);
        // Windows `dirname` keeps the trailing separator
        // (`\\server\share\`); the POSIX-side manual split drops it. Both
        // name the same directory, so compare the directory.
        try testing.expectEqualStrings("\\\\fileserver\\share", std.mem.trimEnd(u8, p, "\\/"));
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: UNC subdir under a UNC home returns the intermediate parent" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "\\\\fileserver\\share\\ginwa");
    const parent = try SystemFolder.getParentPath(allocator, "\\\\fileserver\\share\\ginwa\\Documents\\2026", &env);
    if (parent) |p| {
        defer allocator.free(p);
        try testing.expectEqualStrings("\\\\fileserver\\share\\ginwa\\Documents", p);
    } else {
        try testing.expect(false);
    }
}

test "getParentPath: a trailing forward slash is only normalized on Windows" {
    // `C:/Users/ginwa/` is another spelling of home.
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const result = try SystemFolder.getParentPath(allocator, "C:/Users/ginwa/", &env);
    if (builtin.os.tag == .windows) {
        // Free before asserting: an assertion that fails while a returned
        // buffer is still alive ALSO reports a leak, and the leak trace
        // buries the actual failure in the CI log.
        defer if (result) |p| allocator.free(p);
        try testing.expect(result == null);
    } else {
        // The POSIX branch has no trailing-`/` normalization, so it falls
        // through to `dirname`, which strips the slash and cuts at the
        // previous one -> `C:/Users`.
        const p = result orelse return error.TestExpectedResult;
        defer allocator.free(p);
        try testing.expectEqualStrings("C:/Users", p);
    }
}

test "getParentPath: a differently-cased spelling of home still returns null" {
    // Windows compares path bytes case-insensitively, so `c:\USERS\Ginwa`
    // is home. Only `eqlSameDir` knows that; POSIX must not fold case, so
    // the OUTCOME differs by platform and both branches are asserted.
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const result = try SystemFolder.getParentPath(allocator, "c:\\USERS\\Ginwa", &env);
    if (builtin.os.tag == .windows) {
        defer if (result) |p| allocator.free(p);
        try testing.expect(result == null);
    } else {
        // `std.fs.path.dirname` finds no `/`, so the manual
        // Windows-separator split cuts at the last `\`.
        const p = result orelse return error.TestExpectedResult;
        defer allocator.free(p);
        try testing.expectEqualStrings("c:\\USERS", p);
    }
}

test "getParentPath: a lower-case forward-slash spelling of home still returns null" {
    // The exact shape a frontend builds: `${dir}/${name}` produces
    // `c:/users/ginwa/` where home is `C:\Users\ginwa` — different separator
    // AND different case, with a trailing slash.
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\ginwa");
    const result = try SystemFolder.getParentPath(allocator, "c:/users/ginwa/", &env);
    if (builtin.os.tag == .windows) {
        defer if (result) |p| allocator.free(p);
        try testing.expect(result == null);
    } else {
        // Trailing `/` is not stripped on POSIX, so `dirname` eats it and
        // cuts at the previous one -> `c:/users`. That is the escape the
        // Windows branch refuses, and the reason the fold is Windows-only.
        const p = result orelse return error.TestExpectedResult;
        defer allocator.free(p);
        try testing.expectEqualStrings("c:/users", p);
    }
}
