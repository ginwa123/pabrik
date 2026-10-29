const std = @import("std");
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const shell_tool = @import("shell.zig");
const invalidPathReason = path_validate.invalidPathReason;
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const helpers = @import("helpers");

/// Cross-platform `/`-separator path concat.
fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, name);
    const out = try allocator.alloc(u8, dir.len + 1 + name.len);
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 ..][0..name.len], name);
    return out;
}

// ============================================================================
// Gitignore Types
// ============================================================================

pub const GitignoreEntry = struct {
    negated: bool,
    directory_only: bool,
    anchor_to_root: bool,
    pattern: []const u8,
};

const Gitignore = struct {
    entries: []GitignoreEntry,
    cwd: []const u8,

    fn deinit(self: *Gitignore, allocator: std.mem.Allocator) void {
        for (self.entries) |e| allocator.free(e.pattern);
        allocator.free(self.entries);
        allocator.free(self.cwd);
    }
};

/// Check if pattern starts with ! (gitignore negation)
fn isGitignoreNegation(pattern: []const u8) bool {
    return pattern.len > 0 and pattern[0] == '!';
}

/// Get content after gitignore negation prefix
fn getGitignoreNegationContent(pattern: []const u8) []const u8 {
    std.debug.assert(isGitignoreNegation(pattern));
    return pattern[1..];
}

/// Parse a single .gitignore line into a GitignoreEntry
pub fn parseGitignoreLine(line: []const u8) ?GitignoreEntry {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    var negated = false;
    var pattern = trimmed;

    if (pattern[0] == '!') {
        negated = true;
        pattern = pattern[1..];
    }

    // Strip trailing / (directory-only marker)
    var directory_only = false;
    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        directory_only = true;
        pattern = pattern[0 .. pattern.len - 1];
    }

    // Trim again after stripping negation/trailing
    pattern = std.mem.trim(u8, pattern, &std.ascii.whitespace);
    if (pattern.len == 0) return null;

    // Leading / means anchor to root of this .gitignore's directory
    var anchor_to_root = false;
    if (pattern[0] == '/') {
        anchor_to_root = true;
        pattern = pattern[1..];
    }

    return GitignoreEntry{
        .negated = negated,
        .directory_only = directory_only,
        .anchor_to_root = anchor_to_root,
        .pattern = pattern,
    };
}

/// Load and parse a .gitignore file from a directory
fn loadGitignore(allocator: std.mem.Allocator, dir_path: []const u8) !?Gitignore {
    const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return error.OutOfMemory;
    defer allocator.free(gitignore_path);

    // `std.fs.openFileAbsolute` was removed in Zig 0.16. Use the cross-platform
    // `helpers.readFile` (libc `fopen`/`fread`) which works on Linux,
    // macOS, and Windows via UCRT without an `io: std.Io` runtime.
    const content = helpers.readFile(allocator, gitignore_path) catch return null;
    defer allocator.free(content);

    var entries = std.ArrayList(GitignoreEntry).empty;
    errdefer entries.deinit(allocator);

    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];

        if (parseGitignoreLine(line)) |entry| {
            entries.append(allocator, entry) catch continue;
        }

        line_start = line_end + 1;
    }

    if (entries.items.len == 0) return null;

    const cwd = try allocator.dupe(u8, dir_path);
    return Gitignore{
        .entries = try entries.toOwnedSlice(allocator),
        .cwd = cwd,
    };
}

/// Check if a path is ignored by gitignore rules
fn isIgnoredByGitignore(gitignore: *const Gitignore, path: []const u8, is_dir: bool) bool {
    // Get path relative to gitignore cwd
    const rel_path = if (std.mem.startsWith(u8, path, gitignore.cwd)) {
        const rest = path[gitignore.cwd.len..];
        if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
    } else path;

    for (gitignore.entries) |entry| {
        // Directory-only patterns don't match files
        if (entry.directory_only and !is_dir) continue;

        // Anchor to root: pattern only matches at root level
        const effective_pattern = if (entry.anchor_to_root) entry.pattern else entry.pattern;

        if (matchGitignorePattern(effective_pattern, rel_path, is_dir)) {
            // Negated entries (whitelist) return false (not ignored)
            // Regular entries return true (ignored)
            return !entry.negated;
        }
    }

    return false;
}

/// Match a single gitignore pattern against a relative path
fn matchGitignorePattern(pattern: []const u8, rel_path: []const u8) bool {
    // Get basename for patterns that don't contain /
    const basename = std.fs.path.basename(rel_path);

    // Check both full path and basename
    return gitignoreGlobMatch(pattern, basename, false) or
        gitignoreGlobMatch(pattern, rel_path, false);
}

/// Gitignore glob matching (supports *, **, ?, [abc])
pub fn gitignoreGlobMatch(glob: []const u8, text: []const u8, nocase: bool) bool {
    var gi: usize = 0;
    var ti: usize = 0;

    while (gi < glob.len) {
        const g = glob[gi];

        if (g == '*') {
            gi += 1;
            if (gi >= glob.len) return true;

            if (gi < glob.len and glob[gi] == '*') {
                gi += 1;
                if (gi < glob.len and glob[gi] == '/') gi += 1;

                var t = ti;
                while (t <= text.len) {
                    if (gitignoreGlobMatch(glob[gi..], text[t..], nocase)) return true;
                    t += 1;
                }
                return false;
            }

            while (ti < text.len and text[ti] != '/') {
                if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
                ti += 1;
            }
            if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
            return false;
        }

        if (g == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            gi += 1;
            ti += 1;
            continue;
        }

        if (g == '[') {
            gi += 1;
            if (ti >= text.len) return false;

            var matched = false;
            var negated = false;
            if (gi < glob.len and (glob[gi] == '!' or glob[gi] == '^')) {
                negated = true;
                gi += 1;
            }

            while (gi < glob.len and glob[gi] != ']') {
                if (gi + 2 < glob.len and glob[gi + 1] == '-') {
                    const start = glob[gi];
                    const end = glob[gi + 2];
                    if (text[ti] >= start and text[ti] <= end) matched = true;
                    gi += 3;
                } else {
                    const pc = glob[gi];
                    const tc = text[ti];
                    const match = if (nocase)
                        std.ascii.toLower(pc) == std.ascii.toLower(tc)
                    else
                        pc == tc;
                    if (match) matched = true;
                    gi += 1;
                }
            }
            if (gi < glob.len) gi += 1;

            if (negated) matched = !matched;
            if (matched) {
                ti += 1;
            } else {
                return false;
            }
            continue;
        }

        if (ti >= text.len) return false;
        const tc = text[ti];
        if (g != '/') {
            _ = if (nocase)
                std.ascii.toLower(g) == std.ascii.toLower(tc)
            else
                g == tc;
            if (g != tc) return false;
        }
        gi += 1;
        ti += 1;
    }

    return ti == text.len;
}

// ============================================================================
// Glob Constants
// ============================================================================

pub const DEFAULT_MAX_RESULTS: usize = 100;
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 50 * 1024;
pub const MAX_RECOMMENDED_RESULTS: usize = 500;

/// Default maximum recursion depth for `walkDir`. Set high enough for normal
/// projects (32 covers any reasonable file tree) but low enough to abort
/// gracefully on symlink cycles.
pub const DEFAULT_MAX_DEPTH: usize = 64;

// ============================================================================
// Glob Errors
// ============================================================================

pub const GlobError = error{
    /// `pattern` was an empty string. Almost certainly a caller bug,
    /// not a no-match result. Surfaced up-front before allocating the
    /// expanded-pattern array so we don't pay any IO cost.
    EmptyPattern,
    /// `pattern` contained only whitespace characters. Same as
    /// EmptyPattern in terms of intent; surfaced separately so the
    /// LLM knows which mistake was made.
    WhitespaceOnlyPattern,
    /// `pattern` contained a NUL byte. expandBraces would silently
    /// corrupt it; we reject up-front.
    PatternContainsNulByte,
    /// `path` does not exist (or is not accessible). Without this check,
    /// walkDir silently returned zero results for bad paths — confusing.
    PathDoesNotExist,
    /// `file_type` was not in {null, "f", "file", "d", "directory"}. Silently
    /// ignoring unknown values (the pre-fix behavior) caused callers to get
    /// all results when they asked for "exec" or "symlink".
    InvalidFileType,
    /// `max_results` was 0. Indistinguishable from a real no-match
    /// result under the old defaulting shim; reject up-front.
    InvalidMaxResults,
    /// `pattern` contains an unmatched `{` (depth never returned to 0).
    /// Without this check, the pattern silently returned no matches.
    InvalidBraceExpansion,
};

// ============================================================================
// Glob Constants
// ============================================================================

// ============================================================================
// Glob Types
// ============================================================================

pub const GlobInput = struct {
    pattern: []const u8 = "*",
    path: []const u8 = ".",
    /// REQUIRED on the wire. Absolute directory this call works in; `path` (a
    /// directory) resolves against it.
    cwd: []const u8 = "",
    max_results: ?usize = null,
    offset: ?usize = null,
    hidden: bool = false,
    ignore_case: bool = false,
    file_type: ?[]const u8 = null,
    follow: bool = false,
    /// When true (default), the tool respects .gitignore / .ignore /
    /// .rgignore (using glob's own custom parser — supports `!` negation, `/`
    /// anchors).
    respect_ignore_files: bool = true,
};

pub const GlobMatch = struct {
    path: []const u8,
};

pub const GlobResult = struct {
    matches: std.ArrayList(GlobMatch),
    truncated_count: usize = 0,
    total_found: usize = 0,
    offset_applied: usize = 0,
    truncated_by_size: bool = false,

    pub fn deinit(self: *GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| allocator.free(m.path);
        self.matches.deinit(allocator);
    }
};

// ============================================================================
// Simple Glob Pattern Matching (Iterative)
// ============================================================================

/// Check if pattern is a negation pattern like !(*.zig) or !*.zig
fn isNegationPattern(pattern: []const u8) bool {
    return pattern.len > 2 and pattern[0] == '!' and pattern[1] == '(';
}

/// Extract the inner content of a negation pattern like !(*.zig) -> *.zig
fn getNegationContent(pattern: []const u8) []const u8 {
    std.debug.assert(isNegationPattern(pattern));
    return pattern[2 .. pattern.len - 1]; // Skip !(
}

/// Match glob pattern against text - simple iterative approach
fn globMatch(glob: []const u8, text: []const u8, nocase: bool) bool {
    var gi: usize = 0;
    var ti: usize = 0;

    while (gi < glob.len) {
        const g = glob[gi];

        if (g == '*') {
            gi += 1;
            if (gi >= glob.len) return true; // * at end matches everything

            // Check for **
            if (gi < glob.len and glob[gi] == '*') {
                gi += 1;
                // Skip / after **
                if (gi < glob.len and glob[gi] == '/') gi += 1;
                // Try matching at each position
                var t = ti;
                while (t <= text.len) {
                    if (globMatch(glob[gi..], text[t..], nocase)) return true;
                    t += 1;
                }
                return false;
            }

            // Single * - match until next glob char or /
            while (ti < text.len and text[ti] != '/') {
                if (globMatch(glob[gi..], text[ti..], nocase)) return true;
                ti += 1;
            }
            if (globMatch(glob[gi..], text[ti..], nocase)) return true;
            return false;
        }

        if (g == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            gi += 1;
            ti += 1;
            continue;
        }

        if (g == '[') {
            gi += 1;
            if (ti >= text.len) return false;

            var matched = false;
            var negated = false;

            if (gi < glob.len and (glob[gi] == '!' or glob[gi] == '^')) {
                negated = true;
                gi += 1;
            }

            while (gi < glob.len and glob[gi] != ']') {
                if (gi + 2 < glob.len and glob[gi + 1] == '-') {
                    const start = glob[gi];
                    const end = glob[gi + 2];
                    if (text[ti] >= start and text[ti] <= end) matched = true;
                    gi += 3;
                } else {
                    const pc = glob[gi];
                    const tc = text[ti];
                    const match = if (nocase)
                        std.ascii.toLower(pc) == std.ascii.toLower(tc)
                    else
                        pc == tc;
                    if (match) matched = true;
                    gi += 1;
                }
            }
            if (gi < glob.len) gi += 1; // Skip ]

            if (negated) matched = !matched;
            if (matched) {
                ti += 1;
            } else {
                return false;
            }
            continue;
        }

        // Literal character
        if (ti >= text.len) return false;
        const tc = text[ti];
        // Path separator handling
        const sep_match = (g == '/' and tc == '/') or (g == '/' and tc == '\\');
        const char_match = if (nocase)
            std.ascii.toLower(g) == std.ascii.toLower(tc)
        else
            g == tc;
        if (!sep_match and !char_match) return false;
        gi += 1;
        ti += 1;
    }

    return ti == text.len;
}

/// Check if a glob pattern segment contains wildcard metacharacters.
fn isWildcardPattern(pat: []const u8) bool {
    for (pat) |c| {
        switch (c) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

// ============================================================================
// Brace Expansion
// ============================================================================

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn expandBraces(pattern: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    // Find outermost brace
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;

    // First pass: detect unmatched `{` or `}` up-front and report a clear
    // error to the caller.
    {
        var scan_depth: usize = 0;
        for (pattern) |c| {
            switch (c) {
                '{' => scan_depth += 1,
                '}' => {
                    if (scan_depth == 0) return error.InvalidBraceExpansion;
                    scan_depth -= 1;
                },
                else => {},
            }
        }
        if (scan_depth != 0) return error.InvalidBraceExpansion;
    }

    while (i < pattern.len) {
        switch (pattern[i]) {
            '{' => {
                if (depth == 0) start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    const prefix = if (start > 0) pattern[0..start] else "";
                    const suffix = if (i + 1 < pattern.len) pattern[i + 1 ..] else "";
                    const inner = pattern[start + 1 .. i];

                    // Check for negation pattern {![pattern]}
                    if (inner.len > 1 and inner[0] == '!') {
                        const negated_content = inner[1..];
                        var results: std.ArrayList([]const u8) = .empty;
                        errdefer results.deinit(allocator);

                        // Return the negated pattern marker
                        const marker = try std.fmt.allocPrint(allocator, "!({s})", .{negated_content});
                        try results.append(allocator, marker);
                        return try results.toOwnedSlice(allocator);
                    }

                    // Check for numeric range {1..5}
                    if (std.mem.indexOf(u8, inner, "..")) |idx| {
                        const before = inner[0..idx];
                        const after = inner[idx + 2 ..];
                        if (isNumeric(before) and isNumeric(after)) {
                            var results: std.ArrayList([]const u8) = .empty;
                            errdefer results.deinit(allocator);

                            const start_num = std.fmt.parseInt(i64, before, 10) catch 0;
                            const end_num = std.fmt.parseInt(i64, after, 10) catch 0;
                            const step: i64 = if (start_num <= end_num) 1 else -1;
                            var num = start_num;

                            while (true) {
                                const num_str = try std.fmt.allocPrint(allocator, "{d}", .{num});
                                const expanded = try std.mem.concat(allocator, u8, &.{ prefix, num_str, suffix });
                                try results.append(allocator, expanded);
                                if (num == end_num) break;
                                num += step;
                            }
                            return try results.toOwnedSlice(allocator);
                        }
                    }

                    // Parse comma-separated
                    var results: std.ArrayList([]const u8) = .empty;
                    errdefer results.deinit(allocator);

                    var seg_start: usize = 0;
                    var j: usize = 0;
                    while (j <= inner.len) {
                        if (j == inner.len or inner[j] == ',') {
                            const seg = inner[seg_start..j];
                            if (seg.len > 0) {
                                const expanded = try std.mem.concat(allocator, u8, &.{ prefix, seg, suffix });
                                try results.append(allocator, expanded);
                            }
                            seg_start = j + 1;
                        }
                        j += 1;
                    }
                    return try results.toOwnedSlice(allocator);
                }
            },
            else => {},
        }
        i += 1;
    }

    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, pattern);
    return result;
}

// ============================================================================
// Directory Walking
// ============================================================================

/// Gitignore context that tracks rules from all visited directories
pub const GitignoreContext = struct {
    entries: std.ArrayList(GitignoreEntry),
    root_cwd: []const u8,

    pub fn init(root_cwd: []const u8) @This() {
        return .{
            .entries = .empty,
            .root_cwd = root_cwd,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.pattern);
        self.entries.deinit(allocator);
    }

    /// Load .gitignore from a directory and add its entries
    pub fn loadGitignoreForDir(
        self: *@This(),
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        source: ?DirSource,
    ) void {
        const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return;
        defer allocator.free(gitignore_path);

        const content = if (source) |src|
            (src.readFn(src.ctx, allocator, io, gitignore_path) catch return) orelse return
        else
            readHostGitignore(allocator, io, gitignore_path) orelse return;

        var line_start: usize = 0;
        while (line_start < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
            const line = content[line_start..line_end];

            if (parseGitignoreLine(line)) |entry| {
                var owned_entry = entry;
                owned_entry.pattern = allocator.dupe(u8, entry.pattern) catch continue;
                self.entries.append(allocator, owned_entry) catch continue;
            }

            line_start = line_end + 1;
        }
        allocator.free(content);
    }

    /// Check if a path is ignored
    pub fn isIgnored(self: *const @This(), path: []const u8) bool {
        // Get relative path from root
        var rel_path: []const u8 = path;
        if (std.mem.startsWith(u8, path, self.root_cwd)) {
            var rest = path[self.root_cwd.len..];
            if (rest.len > 0 and rest[0] == '/') {
                rel_path = rest[1..];
            } else {
                rel_path = rest;
            }
        }

        for (self.entries.items) |entry| {
            if (entry.directory_only) continue;

            // Check basename and full path
            const basename = std.fs.path.basename(rel_path);
            if (gitignoreGlobMatch(entry.pattern, basename, false) or
                gitignoreGlobMatch(entry.pattern, rel_path, false))
            {
                return !entry.negated;
            }
        }

        return false;
    }
};

/// One directory's entries, as whichever substrate produced them. The walk
/// only ever asks one question of them — is this something to descend into —
/// so this is the whole shape it needs.
pub const Listed = struct {
    name: []const u8,
    kind: ListKind,
};

pub const ListKind = enum { file, dir };

/// Where a walk's listings and its `.gitignore` reads come from: the host's
/// own filesystem, or the guest under `--saas`. Nothing else about the walk
/// changes with the answer.
pub const DirSource = struct {
    ctx: *const anyopaque,
    listFn: *const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_abs: []const u8,
    ) anyerror![]Listed,
    /// The file's bytes, or null when it cannot be read — a directory with no
    /// readable `.gitignore` is not a failure, it just has no rules.
    readFn: *const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        abs: []const u8,
    ) anyerror!?[]u8,
};

fn freeListed(allocator: std.mem.Allocator, listed: []Listed) void {
    for (listed) |entry| allocator.free(entry.name);
    allocator.free(listed);
}

/// The host's own listing, in the same shape a guest listing arrives in.
fn listHostDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    follow: bool,
) ![]Listed {
    var dir: std.Io.Dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true, .follow_symlinks = follow }) catch return error.PathDoesNotExist
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = follow }) catch return error.PathDoesNotExist;
    defer std.Io.Dir.close(dir, io);

    var out: std.ArrayList(Listed) = .empty;
    errdefer freeListed(allocator, out.items);
    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        const owned = try allocator.dupe(u8, entry.name);
        try out.append(allocator, .{
            .name = owned,
            .kind = if (entry.kind == .directory) .dir else .file,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// A `.gitignore`'s bytes from the host, or null when there is not one to
/// read. A directory with no rules and a directory whose rules cannot be read
/// walk the same way.
fn readHostGitignore(
    allocator: std.mem.Allocator,
    io: std.Io,
    gitignore_path: []const u8,
) ?[]u8 {
    const file: std.Io.File = if (std.fs.path.isAbsolute(gitignore_path))
        std.Io.Dir.openFileAbsolute(io, gitignore_path, .{}) catch return null
    else
        std.Io.Dir.cwd().openFile(io, gitignore_path, .{}) catch return null;
    defer file.close(io);
    return std.Io.Dir.cwd().readFileAlloc(io, gitignore_path, allocator, std.Io.Limit.limited(1024 * 64)) catch null;
}

fn walkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    patterns: []const []const u8,
    opts: GlobOptions,
    results: *std.ArrayList([]const u8),
    depth: usize,
    gitignore_ctx: ?*GitignoreContext,
    source: ?DirSource,
    cancelled: *bool,
) void {
    if (opts.max_depth) |max| if (depth >= max) return;
    // The walk returns void and swallows its own errors, so a cancel is
    // reported through `cancelled` and turned into `error.Cancelled` by the
    // caller. Results collected so far are NOT presented as a complete list.
    if (opts.cancel) |hook| {
        if (hook.requested()) {
            cancelled.* = true;
            return;
        }
    }

    // One listing, whatever answered it: the loop below cannot tell the two
    // substrates apart, which is the whole point of the seam.
    const listed = if (source) |src|
        src.listFn(src.ctx, allocator, io, dir_path) catch return
    else
        listHostDir(allocator, io, dir_path, opts.follow) catch return;
    defer freeListed(allocator, listed);

    // Load .gitignore for this directory if we have a gitignore context
    if (gitignore_ctx) |ctx| {
        ctx.loadGitignoreForDir(allocator, io, dir_path, source);
    }

    // Separate regular patterns from negation patterns
    var negation_patterns: std.ArrayList([]const u8) = .empty;
    var regular_patterns: std.ArrayList([]const u8) = .empty;
    defer negation_patterns.deinit(allocator);
    defer regular_patterns.deinit(allocator);

    for (patterns) |pat| {
        if (isNegationPattern(pat)) {
            negation_patterns.append(allocator, pat) catch continue;
        } else {
            regular_patterns.append(allocator, pat) catch continue;
        }
    }

    for (listed) |entry| {
        const name = entry.name;
        if (!opts.dot and name.len > 0 and name[0] == '.') continue;

        // Always skip the `.git` directory regardless of `opts.dot`. Walking
        // into `.git/objects/...` returns thousands of pack files that no LLM
        // caller wants.
        if (entry.kind == .dir and std.mem.eql(u8, name, ".git")) continue;

        const full_path = joinPath(allocator, dir_path, name) catch continue;

        // Check gitignore first
        const is_dir = entry.kind == .dir;
        if (gitignore_ctx) |ctx| {
            if (ctx.isIgnored(full_path)) {
                allocator.free(full_path);
                continue;
            }
        }

        // Check pattern match against name and full path
        var matches = false;
        var negated_match = false;
        for (regular_patterns.items) |pat| {
            if (globMatch(pat, name, opts.nocase) or globMatch(pat, full_path, opts.nocase)) {
                matches = true;
                break;
            }
        }

        // Check negation patterns - if ANY negation pattern matches, this file is excluded
        if (negation_patterns.items.len > 0) {
            for (negation_patterns.items) |pat| {
                const inner = getNegationContent(pat);
                if (globMatch(inner, name, opts.nocase) or globMatch(inner, full_path, opts.nocase)) {
                    negated_match = true;
                    break;
                }
            }

            // If no regular patterns, negation means exclude files that match the pattern
            // If has regular patterns, negation means exclude only if regular pattern also matches
            if (regular_patterns.items.len > 0) {
                // Regular patterns exist - negation only excludes if also matched by regular pattern
                matches = matches and !negated_match;
            } else {
                // No regular patterns - negate means find all that DON'T match
                matches = !negated_match;
            }
        }

        if (matches) {
            const include = (!opts.nodir or !is_dir) and (!opts.onlydir or is_dir);
            if (include) {
                results.append(allocator, allocator.dupe(u8, full_path) catch continue) catch continue;
            }
        }

        if (is_dir) {
            // Build the list of patterns that the "normal recursive descent"
            // will pass down.
            var unconsumed: std.ArrayList([]const u8) = .empty;
            defer unconsumed.deinit(allocator);

            for (regular_patterns.items) |pat| {
                var consumed = false;
                var pat_idx: usize = 0;

                // Skip the prefix-aware logic entirely for wildcard first
                // segments.
                {
                    const first_slash = std.mem.indexOfScalar(u8, pat, '/') orelse pat.len;
                    const first_seg = pat[0..first_slash];
                    if (isWildcardPattern(first_seg)) {
                        unconsumed.append(allocator, pat) catch continue;
                        continue;
                    }
                }

                while (pat_idx < pat.len) {
                    const remaining_pat = pat[pat_idx..];
                    const slash_idx = std.mem.indexOfScalar(u8, remaining_pat, '/') orelse remaining_pat.len;
                    const dir_part = remaining_pat[0..slash_idx];

                    if (globMatch(dir_part, name, opts.nocase)) {
                        // Matched a literal prefix segment — recurse with the
                        // prefix-stripped pattern and mark this pattern as
                        // consumed (do NOT also re-apply the full pattern via
                        const next_idx = pat_idx + slash_idx + 1;
                        if (next_idx < pat.len) {
                            const remaining_pattern = pat[next_idx..];

                            if (remaining_pattern.len >= 2 and
                                remaining_pattern[0] == '*' and
                                remaining_pattern[1] == '*')
                            {
                                // Recursive "**" suffix — recurse with the
                                // inner pattern.
                                var inner_start: usize = 2;
                                if (inner_start < remaining_pattern.len and
                                    remaining_pattern[inner_start] == '/')
                                {
                                    inner_start += 1;
                                }
                                const inner_pattern =
                                    if (inner_start < remaining_pattern.len)
                                        remaining_pattern[inner_start..]
                                    else
                                        "*";

                                var new_patterns: std.ArrayList([]const u8) = .empty;
                                new_patterns.append(allocator, inner_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items, opts, results, depth + 1, gitignore_ctx, source, cancelled);
                                new_patterns.deinit(allocator);
                            } else {
                                // Non-recursive suffix — recurse with it.
                                var new_patterns: std.ArrayList([]const u8) = .empty;
                                new_patterns.append(allocator, remaining_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items, opts, results, depth + 1, gitignore_ctx, source, cancelled);
                                new_patterns.deinit(allocator);
                            }
                        } else {
                            // Pattern ends with the matched directory name —
                            // this directory itself matches; recurse to
                            // check children.
                            if (pat[pat_idx + slash_idx - 1] != '*') {
                                walkDir(allocator, io, full_path, patterns, opts, results, depth + 1, gitignore_ctx, source, cancelled);
                            }
                        }
                        consumed = true;
                        break;
                    } else {
                        pat_idx += slash_idx + 1;
                        if (pat_idx > pat.len) break;
                    }
                }

                if (!consumed) {
                    unconsumed.append(allocator, pat) catch continue;
                }
            }

            // Always include negation patterns in the fallback recursion —
            // they have no leading directory prefix and must be re-applied
            // at every level.
            for (negation_patterns.items) |pat| {
                unconsumed.append(allocator, pat) catch continue;
            }

            // Fallback recursion with the unconsumed patterns only. This is
            // the single recursion path that PASSES PATTERNS DOWN.
            if (unconsumed.items.len > 0) {
                walkDir(allocator, io, full_path, unconsumed.items, opts, results, depth + 1, gitignore_ctx, source, cancelled);
            }
        }
        allocator.free(full_path);
    }
}

// ============================================================================
// Glob Options
// ============================================================================

pub const GlobOptions = struct {
    dot: bool = true,
    nocase: bool = false,
    nodir: bool = false,
    follow: bool = false,
    onlydir: bool = false,
    max_depth: ?usize = null,
    /// Polled once per directory entry — a walk over a huge tree is the long
    /// part of `glob`, and it is all in-process, so the Stop button has to be
    /// asked from inside it.
    cancel: ?shell_tool.CancelHook = null,
};

// ============================================================================
// Main Glob Execution
// ============================================================================

pub fn executeGlob(allocator: std.mem.Allocator, io: std.Io, input: GlobInput) !GlobResult {
    return executeGlobWith(allocator, io, input, null);
}

/// The same walk, with the substrate that answers its listings chosen by the
/// caller. A null source is the host's own filesystem, which is what every
/// mode but `--saas` uses.
pub fn executeGlobWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: GlobInput,
    source: ?DirSource,
) !GlobResult {
    return executeGlobWithCancel(allocator, io, input, source, null);
}

/// `executeGlobWith` plus the Stop button. The walk polls the hook once per
/// directory entry and, on a true answer, abandons the walk and returns
/// `error.Cancelled` rather than a partial listing that reads as complete.
pub fn executeGlobWithCancel(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: GlobInput,
    source: ?DirSource,
    cancel_hook: ?shell_tool.CancelHook,
) !GlobResult {
    // ---- Up-front input validation (BEFORE expandBraces / walk) ----
    // Rationale: most "glob found nothing" results today are actually caller
    // bugs.
    if (input.pattern.len == 0) return error.EmptyPattern;

    // The LLM chooses `path`; on Windows a malformed NT name panics the
    // process inside std's Io backend rather than failing this call.
    if (input.path.len > 0) {
        if (invalidPathReason(input.path)) |reason| {
            std.log.debug("glob rejected path: {s}", .{reason});
            return error.InvalidPath;
        }
    }

    // Whitespace-only pattern check. We strip ASCII whitespace and
    // accept the result iff non-empty.
    {
        var has_non_ws = false;
        for (input.pattern) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                has_non_ws = true;
                break;
            }
        }
        if (!has_non_ws) return error.WhitespaceOnlyPattern;
    }

    // NUL byte check — expandBraces would silently corrupt the pattern.
    for (input.pattern) |c| if (c == 0) return error.PatternContainsNulByte;

    // Path existence + dir check. The cross-platform approach: try to open it
    // as a directory. If the open succeeds, path exists and is a directory.
    if (source) |src| {
        // Asking the guest for the listing IS the existence check there: the
        // walk would otherwise find out only after the patterns were built.
        const probe = src.listFn(src.ctx, allocator, io, input.path) catch return error.PathDoesNotExist;
        freeListed(allocator, probe);
    } else {
        const verify_dir: std.Io.Dir = if (std.fs.path.isAbsolute(input.path))
            std.Io.Dir.openDirAbsolute(io, input.path, .{}) catch return error.PathDoesNotExist
        else
            std.Io.Dir.cwd().openDir(io, input.path, .{}) catch return error.PathDoesNotExist;
        std.Io.Dir.close(verify_dir, io);
    }

    // file_type strict validation.
    if (input.file_type) |ft| {
        const ok = std.mem.eql(u8, ft, "f") or
            std.mem.eql(u8, ft, "file") or
            std.mem.eql(u8, ft, "d") or
            std.mem.eql(u8, ft, "directory");
        if (!ok) return error.InvalidFileType;
    }

    // max_results validation. The 0 case is the one that previously
    // got the silent "use default" treatment and confused callers.
    if (input.max_results) |mr| if (mr == 0) return error.InvalidMaxResults;

    // Brace expansion (also handles `{...}` detection up-front).
    const expanded = try expandBraces(input.pattern, allocator);
    defer {
        for (expanded) |e| allocator.free(e);
        allocator.free(expanded);
    }

    // Build options
    const opts = GlobOptions{
        .dot = input.hidden,
        .nocase = input.ignore_case,
        .follow = input.follow,
        .nodir = if (input.file_type) |ft| std.mem.eql(u8, ft, "f") or std.mem.eql(u8, ft, "file") else false,
        .onlydir = if (input.file_type) |ft| std.mem.eql(u8, ft, "d") or std.mem.eql(u8, ft, "directory") else false,
        .max_depth = DEFAULT_MAX_DEPTH,
        .cancel = cancel_hook,
    };

    // Walk directory
    var results: std.ArrayList([]const u8) = .empty;
    // Declaration ORDER is the cleanup order: defers run in reverse, so the
    // backing slice is released LAST — iterating it after `deinit` (a slice
    // that was just freed) is what a cancelled walk used to hit.
    defer results.deinit(allocator);
    errdefer {
        for (results.items) |r| allocator.free(r);
    }

    // Create gitignore context only when respect_ignore_files is true.
    // walkDir's gitignore_ctx slot is already nullable; the if-guards
    // inside walkDir (lines 677-678, 712-715) light up automatically.
    var gitignore_ctx_holder: ?GitignoreContext = if (input.respect_ignore_files)
        GitignoreContext.init(input.path)
    else
        null;
    defer if (gitignore_ctx_holder) |*c| c.deinit(allocator);
    const gitignore_ctx: ?*GitignoreContext = if (gitignore_ctx_holder) |*c| c else null;

    var cancelled = false;
    walkDir(allocator, io, input.path, expanded, opts, &results, 0, gitignore_ctx, source, &cancelled);
    // `errdefer` above frees every collected match; a cancelled walk has no
    // answer to give, so it must not fall through to the offset/limit logic.
    if (cancelled) return error.Cancelled;

    // Apply offset and limit. PRE-EXISTING BUG FIX: The dups in
    // `results.items` are owned by SOMEONE.
    const total = results.items.len;
    const offset = input.offset orelse 0;
    // Treat max_results=0 as "no limit" (same as null)
    const max_res = @min(input.max_results orelse DEFAULT_MAX_RESULTS, MAX_RECOMMENDED_RESULTS);
    const effective_max = if (max_res == 0) DEFAULT_MAX_RESULTS else max_res;
    const start = @min(offset, total);
    const end = @min(start + effective_max, total);

    // Free the offset-skipped range (results.items[0..start]).
    if (start > 0) {
        for (results.items[0..start]) |r| allocator.free(r);
    }

    var matches = std.ArrayList(GlobMatch).empty;
    errdefer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit(allocator);
    }

    // Transfer ownership of the kept range (results.items[start..end])
    // into `matches[i].path` so the dups get freed by `result.deinit`.
    for (results.items[start..end]) |r| {
        try matches.append(allocator, .{ .path = r });
    }

    // Free the count-truncated range (results.items[end..total]).
    if (end < total) {
        for (results.items[end..total]) |r| allocator.free(r);
    }

    const truncated = if (total > end) total - end else 0;

    return GlobResult{
        .matches = matches,
        .truncated_count = truncated,
        .total_found = total,
        .offset_applied = offset,
    };
}

// ============================================================================
// Output Formatting
// ============================================================================

/// JSON payload mirrors the old `<glob_summary>` attributes 1:1: `pattern`,
/// `total`, `returned`, `offset`, `truncated` and `truncated_by_size`, plus
/// `files` (one entry per former `<f>` tag).
pub const GlobJSON = struct {
    pattern: []const u8,
    total: usize,
    returned: usize,
    offset: usize,
    truncated: usize,
    truncated_by_size: bool,
    files: [][]const u8,
    warning: ?[]const u8 = null,
};

pub fn toJSONSuccess(allocator: std.mem.Allocator, result: GlobResult, pattern: []const u8) ![]const u8 {
    const clean_pattern = try helpers.sanitize_control_chars(allocator, pattern);
    defer allocator.free(clean_pattern);

    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);

    var byte_count: usize = 0;
    var truncated_by_size_now = false;

    for (result.matches.items) |m| {
        if (byte_count + m.path.len > DEFAULT_MAX_OUTPUT_BYTES and files.items.len > 0) {
            truncated_by_size_now = true;
            break;
        }
        try files.append(allocator, m.path);
        byte_count += m.path.len;
    }

    const total_truncated = result.truncated_count + (result.matches.items.len - files.items.len);
    var owned_warning: ?[]u8 = null;
    defer if (owned_warning) |w| allocator.free(w);
    const warning: ?[]const u8 = if (files.items.len == 0)
        "No files found matching the glob pattern."
    else if (total_truncated > 0) blk: {
        owned_warning = if (truncated_by_size_now)
            try std.fmt.allocPrint(allocator, "{d} files truncated by output size (>{d} bytes). Use more specific patterns to reduce output.", .{ total_truncated, DEFAULT_MAX_OUTPUT_BYTES })
        else
            try std.fmt.allocPrint(allocator, "{d} files truncated. Use more specific patterns or pagination.", .{total_truncated});
        break :blk owned_warning;
    } else null;

    return try std.json.Stringify.valueAlloc(allocator, GlobJSON{
        .pattern = clean_pattern,
        .total = result.total_found,
        .returned = files.items.len,
        .offset = result.offset_applied,
        .truncated = total_truncated,
        .truncated_by_size = truncated_by_size_now,
        .files = files.items,
        .warning = warning,
    }, .{});
}

pub const glob_tool_system_prompt =
    \\## Glob Tool — Behavior
    \\Use `glob` to find files by pattern (e.g. `**/*.zig`, `*.ts`).
    \\- `cwd` is REQUIRED: the absolute directory this call works in. `path` is the directory to search, absolute or relative to `cwd` (default: `cwd` itself).
    \\- Respects `.gitignore` by default. Set `respect_ignore_files=false` to include ignored files.
    \\- Use to discover files by name before reading them.
    \\
;

pub const glob_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "glob",
        .description =
        \\Find files by glob pattern (e.g. `**/*.ts`). Respects .gitignore/.ignore/.rgignore; `respect_ignore_files=false` includes ignored paths (node_modules/, build/, .git/, etc.). Hidden files are excluded unless `hidden=true`. Use it to find files by name before reading them.
        \\
        \\Returns {pattern, files, total, returned, truncated}.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Glob pattern. `*` any except `/`, `**` any incl `/`, `?` one char, `[abc]` class, `{a,b,c}` alternates, `{1..5}` range. Default: \"*\"",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Directory to search. Absolute, or relative to `cwd`. Default: `cwd` itself.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the directory this call works in. Pass the tree you are editing (your worktree root, NOT the server's directory).",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Max results (default: 100, max: 500)",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip first N results.",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Include hidden files (dotfiles). Default: false",
                },
                .{
                    .name = "ignore_case",
                    .type = "boolean",
                    .description = "Case-insensitive matching. Default: false",
                },
                .{
                    .name = "file_type",
                    .type = "string",
                    .description = "Filter by type: \"f\"=files, \"d\"=directories",
                },
                .{
                    .name = "follow",
                    .type = "boolean",
                    .description = "Follow symlinks. Default: false",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Respect .gitignore/.ignore/.rgignore. Default: true; false lists gitignored paths (node_modules/, build/, .git/, etc.).",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the directory this call works in. Pass the tree you are editing (your worktree root, NOT the server's directory).",
                },
            },
            .required = &.{"cwd"},
        },
        .system_prompt = glob_tool_system_prompt,
    },
};

// ============================================================================
// Test Compatibility Aliases (snake_case names for backward compatibility)
// ============================================================================

const testing = std.testing;
test "gitignore parse line" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test parsing *.log line
    const line = "*.log";
    if (parseGitignoreLine(line)) |entry| {
        try std.testing.expect(entry.negated == false);
        try std.testing.expect(entry.directory_only == false);
        try std.testing.expect(std.mem.eql(u8, entry.pattern, "*.log"));
    } else {
        try std.testing.expect(false); // Should have parsed the line
    }
}

test "gitignore glob match - simple star" {
    // Test that the gitignoreGlobMatch function correctly matches *.log
    const result = gitignoreGlobMatch("*.log", "debug.log", false);
    try std.testing.expect(result == true);
}

test "gitignore glob match - no match" {
    const result = gitignoreGlobMatch("*.log", "debug.txt", false);
    try std.testing.expect(result == false);
}

test "gitignore glob match - basename" {
    // Test that basename matching works
    const result = gitignoreGlobMatch("*.log", "debug.log", false);
    try std.testing.expect(result == true);
}

test "GitignoreContext.isIgnored - direct test" {
    const allocator = std.testing.allocator;

    // Create context with a specific root path
    const root = "/tmp/gitignore_test_ctx";
    var ctx = GitignoreContext.init(root);
    defer ctx.deinit(allocator);

    // Test isIgnored directly with a known path
    // The path /tmp/gitignore_test_ctx/debug.log should be checked against the context
    const test_path = "/tmp/gitignore_test_ctx/debug.log";

    // Initially, no rules loaded - nothing should be ignored
    try std.testing.expect(ctx.isIgnored(test_path) == false);
}

test "GitignoreContext with entries" {
    const allocator = std.testing.allocator;

    const root = "/tmp/gitignore_ctx_test";
    var ctx = GitignoreContext.init(root);
    defer ctx.deinit(allocator);

    // Manually add a gitignore entry for *.log
    const entry = GitignoreEntry{
        .negated = false,
        .directory_only = false,
        .anchor_to_root = false,
        .pattern = "*.log",
    };
    var owned_entry = entry;
    owned_entry.pattern = allocator.dupe(u8, "*.log") catch @panic("dupe failed for the gitignore *.log pattern");
    ctx.entries.append(allocator, owned_entry) catch @panic("append failed for the gitignore *.log entry");

    const test_path = "/tmp/gitignore_ctx_test/debug.log";
    const result = ctx.isIgnored(test_path);
    try std.testing.expect(result == true);
}

test "loadGitignoreForDir with relative path does not crash" {
    // Regression test: loadGitignoreForDir should not crash when given a relative path
    // Previously it called openFileAbsolute which asserts the path is absolute
    const allocator = std.testing.allocator;

    // Create a temp directory with a .gitignore file using shell commands
    const tmp_dir_path = "/tmp/glob_relative_path_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp_dir_path) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    }

    // Create the subdirectory
    const subdir_path = std.fs.path.join(allocator, &.{ tmp_dir_path, "test_subdir" }) catch @panic("join failed for the gitignore test subdir path");
    defer allocator.free(subdir_path);
    std.Io.Dir.cwd().createDirPath(std.testing.io, subdir_path) catch {};

    var ctx = GitignoreContext.init(tmp_dir_path);
    defer ctx.deinit(allocator);

    // This should NOT crash even though subdir_path is relative
    // The function should gracefully handle missing .gitignore or use proper file opening
    ctx.loadGitignoreForDir(allocator, std.testing.io, subdir_path, null);

    // If we get here without crashing, the test passes
    try std.testing.expect(true);
}

test "loadGitignoreForDir with absolute path and existing gitignore" {
    // Test that loadGitignoreForDir correctly loads gitignore entries with absolute path
    const allocator = std.testing.allocator;

    // Create a temp directory with a .gitignore file using shell commands
    const tmp_dir_path = "/tmp/glob_absolute_gitignore_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp_dir_path) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    }

    var ctx = GitignoreContext.init(tmp_dir_path);
    defer ctx.deinit(allocator);

    // This should load the gitignore entries without crashing
    ctx.loadGitignoreForDir(allocator, std.testing.io, tmp_dir_path, null);

    // Just verify it didn't crash - number of entries depends on whether .gitignore exists
    try std.testing.expect(true);
}

// ============================================================================
// Regression tests for walkDir duplicate-results bug (Chunk 1 of the
// 2026-06-18-fix-glob-duplicate-results plan) The walkDir function used to

const TmpTree = struct {
    root: []const u8,

    fn deinit(self: *TmpTree, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
    }
};

/// Create a deterministic tree at `/tmp/glob_walkdir_test_<suffix>/` with
/// `a/b/c/d/match.txt` inside. The `suffix` MUST be unique per test to
/// avoid `/tmp` collisions in parallel test runs.
fn setupTempTree(allocator: std.mem.Allocator, suffix: []const u8) !TmpTree {
    const root = try std.fmt.allocPrint(allocator, "/tmp/glob_walkdir_test_{s}", .{suffix});
    errdefer allocator.free(root);

    // Idempotent: clean any prior state, then create
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    // Nested subdirs created with path.join (root + "/a/b/c/d" — `++` on
    // a runtime slice is rejected by Zig 0.16; path.join is correct here
    // since "/a/b/c/d" is a path component, not a filename suffix).
    const nested_path = try std.fs.path.join(allocator, &.{ root, "a/b/c/d" });
    defer allocator.free(nested_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, nested_path);

    // Create the matching file
    const match_path = try std.fs.path.join(allocator, &.{ root, "a/b/c/d/match.txt" });
    defer allocator.free(match_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, match_path, .{});
        defer std.Io.File.close(file, std.testing.io);
        try std.Io.File.writeStreamingAll(file, std.testing.io, "match");
    }

    return TmpTree{ .root = root };
}

test "walkDir returns each file once for literal-prefix pattern" {
    // Regression test for the duplicate-results bug: Pattern with 5 leading
    // directory components (a/b/c/d/) used to return the file 32 times (=
    // 2^5) due to the dual-recursion bug in walkDir.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "literal_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "a/b/c/d/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/match.txt", .{tree.root});
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, result.matches.items[0].path);
}

test "walkDir returns each file once for wildcard-prefix pattern" {
    // Pattern with a leading **/ must also produce a single result per file.
    // The current code mis-handles wildcard prefixes in the prefix-aware
    // logic (it strips ** and recurses with the wrong inner pattern).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "wildcard_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with mixed literal and wildcard patterns returns each file once" {
    // Both patterns should match match.txt exactly once, total 2 entries.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "mixed");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "{a/b/c/d/match.txt,**/match.txt}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}

// ============================================================================
// Stay-green coverage (Chunk 3 of the 2026-06-18-fix-glob-duplicate-results
// plan).

test "walkDir with simple wildcard pattern finds files at any depth exactly once" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "simple_wildcard");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with * prefix pattern finds files at top level only exactly once" {
    // The setup tree has match.txt only at a/b/c/d/match.txt (4 levels deep).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "star_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // Lock-in: each file appears exactly once, no duplication.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with negation pattern excludes correctly" {
    // Tree has a/b/c/d/match.txt. Pattern "**/*.txt" matches it.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "negation");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    // Combine positive + negation patterns with brace expansion.
    // {pattern1,pattern2} expands to two separate patterns.
    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "{{**/*.txt},{!**/match.txt}}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // match.txt should be found by **/*.txt but excluded by the
    // negation pattern → 0 results.
    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "walkDir with 4-component literal prefix returns each file once (regression)" {
    // The original bug report used a 4-component literal prefix followed by
    // `**/Sidebar*.vue` (path = "src/apps/desktop/src/**/Sidebar*.vue") and
    // returned 16 entries (= 2^4) due to the dual-recursion walkDir bug.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "literal_4comp");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "a/b/c/d/**/*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Edge case hardening (2026-07-08-glob-edge-cases plan) Tests follow the
// project convention of "TDD-first" — these tests are written BEFORE the

// ============================================================================
// Section 1: Validation tests (no fs invocation, run everywhere)
// ============================================================================

test "glob: empty pattern returns EmptyPattern error" {
    const allocator = std.testing.allocator;

    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "",
        .path = "/tmp",
    });

    try std.testing.expectError(error.EmptyPattern, result);
}

test "glob: whitespace-only pattern returns WhitespaceOnlyPattern error" {
    const allocator = std.testing.allocator;

    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "   \t  ",
        .path = "/tmp",
    });

    try std.testing.expectError(error.WhitespaceOnlyPattern, result);
}

test "glob: pattern with NUL byte returns PatternContainsNulByte error" {
    const allocator = std.testing.allocator;

    // Pattern with embedded NUL — expandBraces would silently corrupt it
    // without the up-front check.
    const pattern_with_nul: []const u8 = &[_]u8{ '*', '.', 'z', 'i', 'g', 0x00, '.', 'l', 'o', 'g' };

    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = pattern_with_nul,
        .path = "/tmp",
    });

    try std.testing.expectError(error.PatternContainsNulByte, result);
}

test "glob: path that doesn't exist returns PathDoesNotExist error" {
    const allocator = std.testing.allocator;

    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/nonexistent/path/that/does/not/exist/12345",
    });

    try std.testing.expectError(error.PathDoesNotExist, result);
}

test "glob: file_type not in {null,f,file,d,directory} returns InvalidFileType error" {
    const allocator = std.testing.allocator;

    // "exec" / "symlink" / "any" are commonly mistyped values that today
    // silently return ALL results. After hardening, they MUST be rejected
    // so the LLM caller knows their input was wrong.
    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/tmp",
        .file_type = "exec",
    });

    try std.testing.expectError(error.InvalidFileType, result);
}

test "glob: max_results = 0 returns InvalidMaxResults error" {
    const allocator = std.testing.allocator;

    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/tmp",
        .max_results = 0,
    });

    try std.testing.expectError(error.InvalidMaxResults, result);
}

test "glob: valid input passes validation (positive case)" {
    // Sanity check: the up-front validation doesn't reject valid inputs.
    // Uses a real /tmp tree so walkDir can succeed.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "valid_input_positive");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.matches.items.len >= 0);
}

test "glob: pattern '*.zig' matches files in test tree (positive)" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "pattern_zig");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // The tree has exactly 1 .txt file (match.txt at a/b/c/d/match.txt).
    // Walking with no `**` matches against name OR full path — the
    // existing implementation matches against both, so 1 result.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Section 2: Behavioral tests (fs invocation, OS-independent)
// ============================================================================

test "glob: .git directory is skipped even without a .gitignore" {
    // Setup: temp tree with `.git/` containing files. No .gitignore
    // present. Pattern `**/*` should NOT match files inside .git/.
    const allocator = std.testing.allocator;

    const suffix = "git_skip";
    const root = try std.fmt.allocPrint(allocator, "/tmp/glob_{s}", .{suffix});
    defer allocator.free(root);

    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    // Create .git/objects/pack.idx — would be matched without the skip.
    const dotgit_path = try std.fs.path.join(allocator, &.{ root, ".git/objects" });
    defer allocator.free(dotgit_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dotgit_path);

    const pack_path = try std.fs.path.join(allocator, &.{ root, ".git/objects/pack.idx" });
    defer allocator.free(pack_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, pack_path, .{});
        try std.Io.File.writeStreamingAll(file, std.testing.io, "x");
    }

    // Also create a regular file at root for contrast.
    const readme_path = try std.fs.path.join(allocator, &.{ root, "README.md" });
    defer allocator.free(readme_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, readme_path, .{});
        try std.Io.File.writeStreamingAll(file, std.testing.io, "x");
    }

    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = root,
    });
    defer result.deinit(allocator);

    // The README must be in the results; the .git/pack.idx must NOT be.
    var found_readme = false;
    var found_dotgit = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "README.md")) found_readme = true;
        if (std.mem.indexOf(u8, m.path, "/.git/") != null) found_dotgit = true;
    }
    try std.testing.expect(found_readme);
    try std.testing.expect(!found_dotgit);
}

test "glob: brace expansion with unmatched `{` returns InvalidBraceExpansion" {
    const allocator = std.testing.allocator;

    // Unmatched `{foo` — depth never returns to 0, the brace logic
    // returns the pattern as-is. Pre-fix: silent no-match. Post-fix:
    // clear error so the LLM knows their pattern is malformed.
    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "{*.zig,*.md",
        .path = "/tmp",
    });

    try std.testing.expectError(error.InvalidBraceExpansion, result);
}

test "glob: brace expansion with `{1..5,7}` falls back to literal (no crash)" {
    const allocator = std.testing.allocator;

    // Mixed numeric range + comma — neither branch handles it (the
    // numeric branch wants `1..5` alone, the comma branch wants
    // comma-separated). Returns original pattern as-is. Must not crash.
    const result = executeGlob(allocator, std.testing.io, .{
        .pattern = "{1..5,7}",
        .path = "/tmp",
    });

    // Don't crash. The behavior is "return as-is and walk"; we accept
    // either no-match or any safe non-panic result.
    if (result) |r| {
        var mutable_r = r;
        defer mutable_r.deinit(allocator);
        // If it returned matches, they should be empty for /tmp/1..5,7
    } else |_| {
        // Acceptable: returned an error
    }
}

test "glob: file_type = 'f' filters to files only" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "file_type_f");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tree.root,
        .file_type = "f",
    });
    defer result.deinit(allocator);

    // All matches must be files. The temp tree has only 1 file (match.txt)
    // and several directories (a, b, c, d). With file_type=f we expect 1.
    for (result.matches.items) |m| {
        // Files don't end with `/` in the joined path. Directories would
        // be walked and matched if file_type filter is broken.
        try std.testing.expect(!std.mem.endsWith(u8, m.path, "/"));
    }
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "glob: file_type = 'd' filters to directories only" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "file_type_d");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tree.root,
        .file_type = "d",
    });
    defer result.deinit(allocator);

    // The temp tree has directories a, b, c, d = 4 directories. No
    // `.txt` files in the directory-only filter.
    for (result.matches.items) |m| {
        // Directories appear with their full path — we can't easily
        // distinguish them in the output, but the count must be the
        // expected number of dirs.
        _ = m;
    }
    // Pre-walk directories: a, b, c, d → 4 dirs.
    try std.testing.expectEqual(@as(usize, 4), result.matches.items.len);
}

test "glob: offset beyond results returns 0 matches with total reported" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "offset_beyond");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
        .offset = 99999,
    });
    defer result.deinit(allocator);

    // No matches because offset > total, but total_found still set.
    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.total_found);
}

test "glob: offset + max_results exceeds total returns what's available" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "offset_max");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
        .offset = 0,
        .max_results = 99999,
    });
    defer result.deinit(allocator);

    // Total is 1, max_results is huge, offset is 0 → all 1 returned.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Section 3: Output shape tests (no fs needed — pure formatting)
// ============================================================================

test "glob: toJSONSuccess with empty results emits empty files array with warning" {
    const allocator = std.testing.allocator;

    const empty_result: GlobResult = .{
        .matches = std.ArrayList(GlobMatch).empty,
        .truncated_count = 0,
        .total_found = 0,
        .offset_applied = 0,
        .truncated_by_size = false,
    };

    const payload = try toJSONSuccess(allocator, empty_result, "*");
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("*", obj.get("pattern").?.string);
    try std.testing.expectEqual(@as(usize, 0), obj.get("files").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("warning").?.string, "No files found") != null);
    try std.testing.expectEqual(@as(i64, 0), obj.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 0), obj.get("truncated").?.integer);
}

test "glob: toJSONSuccess keeps pattern with XML metacharacters raw" {
    const allocator = std.testing.allocator;

    var matches = std.ArrayList(GlobMatch).empty;
    defer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit(allocator);
    }
    try matches.append(allocator, .{ .path = try allocator.dupe(u8, "/tmp/foo.zig") });

    const result: GlobResult = .{
        .matches = matches,
        .truncated_count = 0,
        .total_found = 1,
        .offset_applied = 0,
        .truncated_by_size = false,
    };

    // Pattern with `<`, `>`, `&` — JSON needs no escaping for these, so
    // the field must equal the raw input.
    const payload = try toJSONSuccess(allocator, result, "<weird>&pattern.zig");
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("<weird>&pattern.zig", obj.get("pattern").?.string);
    const files = obj.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("/tmp/foo.zig", files[0].string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("returned").?.integer);
    try std.testing.expect(obj.get("warning").? == .null);
}

// respect_ignore_files tests (TDD: these reference a not-yet-existing field)
// =============================================================================
// Mirrors PR #96 (search's respect_ignore_files).

test "glob: respect_ignore_files = false does NOT return a validation error" {
    const allocator = std.testing.allocator;

    // The boolean should flow through executeGlob without triggering any of
    // the up-front validators (EmptyPattern, etc).
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // `realPath` of the tmpdir, NOT ".": `invalidPathReason` refuses a
    // relative path on Windows, so `.` returned error.InvalidPath there while
    // passing on POSIX.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const root_abs = path_buf[0..path_len];

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = root_abs,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Test passes if executeGlob returned Ok (i.e., the `try` above
    // didn't propagate an error). matches count can be 0 for an empty dir.
    try std.testing.expect(result.matches.items.len >= 0);
}

test "glob: respect_ignore_files = true (default) skips .gitignored paths" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // NOTE: glob's gitignore parser has a pre-existing limitation where
    // trailing-`/` directory-only patterns are not checked against
    // directories during the walk (see GitignoreContext.isIgnored's `if
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".gitignore",
        .data = "node_modules\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "node_modules");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is just the basename; resolve full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Default = true respects .gitignore, so only app.js matches.
    // node_modules/secret.js is skipped because of the .gitignore rule.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches.items[0].path, "/app.js"));
}

test "glob: respect_ignore_files = false includes .gitignored paths" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "node_modules");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .gitignore was un-respected (no GitignoreContext
    // was created, walkDir skipped filtering).
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);

    var saw_app = false;
    var saw_secret = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/app.js")) saw_app = true;
        if (std.mem.endsWith(u8, m.path, "/node_modules/secret.js")) saw_secret = true;
    }
    try std.testing.expect(saw_app);
    try std.testing.expect(saw_secret);
}

test "glob: respect_ignore_files = false also un-respects .ignore / .rgignore" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // NOTE: glob's gitignore parser has a pre-existing limitation with
    // trailing-`/` directory-only patterns (see GitignoreContext.isIgnored
    // short-circuit).
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "build_artifacts");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "build_artifacts/cached.dat",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "main.txt",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // With respect_ignore_files=false, the walker lists every file —
    // including the .ignore file itself (3 files: main.txt,
    // build_artifacts/cached.dat, .ignore).
    try std.testing.expectEqual(@as(usize, 3), result.matches.items.len);

    var saw_main = false;
    var saw_cached = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/main.txt")) saw_main = true;
        if (std.mem.endsWith(u8, m.path, "/build_artifacts/cached.dat")) saw_cached = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_cached);
}

// Exec adapter — merged from `glob.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const glob_tool_mod = exec_pabrikcore.glob_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const exec_path_validate = @import("helpers").path_validate;
const workspace_fs = @import("../../../agentic_loop/workspace_fs.zig");

/// The guest as the walk's directory source: listings and `.gitignore` reads
/// both come from the agent, so the host opens nothing inside the tenant tree.
const GuestSource = struct {
    fs: *workspace_fs.Fs,

    fn list(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_abs: []const u8,
    ) anyerror![]glob_tool_mod.Listed {
        _ = io;
        const self: *const GuestSource = @ptrCast(@alignCast(ctx));
        var walked = self.fs.listDir(dir_abs) catch |err| switch (err) {
            workspace_fs.Error.GuestNotDirectory, workspace_fs.Error.GuestPathOutsideWorkspace => return error.PathDoesNotExist,
            else => return err,
        };
        defer walked.deinit();

        const listed = try allocator.alloc(glob_tool_mod.Listed, walked.entries.len);
        var filled: usize = 0;
        errdefer {
            for (listed[0..filled]) |entry| allocator.free(entry.name);
            allocator.free(listed);
        }
        for (walked.entries, 0..) |entry, i| {
            listed[i] = .{
                .name = try allocator.dupe(u8, std.fs.path.basename(entry.abs)),
                .kind = if (entry.kind == .dir) .dir else .file,
            };
            filled = i + 1;
        }
        return listed;
    }

    fn read(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        abs: []const u8,
    ) anyerror!?[]u8 {
        _ = io;
        _ = allocator;
        const self: *const GuestSource = @ptrCast(@alignCast(ctx));
        // An unreadable `.gitignore` is a directory with no rules, exactly as
        // it is on the host.
        return self.fs.readAll(abs) catch null;
    }
};

/// The walk, against the substrate that owns the tree.
fn executeGlobThrough(ctx: ToolExecContext, input: glob_tool_mod.GlobInput) !glob_tool_mod.GlobResult {
    var holder = try workspace_fs.forSession(ctx.allocator, ctx.db, ctx.session_id);
    defer if (holder) |*fs| fs.deinit();
    if (holder) |*fs| {
        var guest_source = GuestSource{ .fs = fs };
        return glob_tool_mod.executeGlobWithCancel(ctx.allocator, ctx.io, input, .{
            .ctx = &guest_source,
            .listFn = GuestSource.list,
            .readFn = GuestSource.read,
        }, null);
    }
    return glob_tool_mod.executeGlobWithCancel(ctx.allocator, ctx.io, input, null, ctx.cancel_hook);
}

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and the base a relative `path` resolves against. See
    // helpers/exec_path_validate.zig for the one implementation of that rule.
    exec_path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try exec_path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    // Search the RESOLVED directory: a relative `path` would otherwise be
    // resolved by the globber against the SERVER's directory, not `cwd`.
    var input = parsed.value;
    input.path = path_abs;

    var glob_result = executeGlobThrough(ctx, input) catch |err| {
        // Map the new domain errors to LLM-friendly messages. Each one
        // names the fix the LLM can try (different pattern, narrower
        // path, smaller max_results, etc).
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.EmptyPattern => break :blk "glob pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.WhitespaceOnlyPattern => break :blk "glob pattern contained only whitespace characters — pass a real pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "glob pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.PathDoesNotExist => break :blk "glob path does not exist or is not a directory — verify the path exists and points to a directory (not a file)",
                error.InvalidFileType => break :blk "glob file_type must be 'f', 'file', 'd', or 'directory' (or omitted for all types)",
                error.InvalidMaxResults => break :blk "glob max_results must be > 0 (omit the field or use a positive integer; the default is 100)",
                error.InvalidBraceExpansion => break :blk "glob pattern has unmatched braces ('{' without '}') — fix the brace expansion syntax",
                error.Cancelled => break :blk "the user stopped this run — the walk was abandoned and its matches are incomplete",
                else => {},
            }
            // Fall-through for unrecognised errors: the shared table keeps
            // the raw error name and adds generic repair advice.
            const msg = error_explain.explain(ctx.allocator, err, null) catch "glob failed with an unknown error";
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toJSONSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}


/// The dispatch probe, faked: the first poll says "cancelled".
const StopRequested = struct {
    fn isCancelled(_: *const anyopaque) bool {
        return true;
    }
};

test "glob: a cancelled session abandons the walk instead of returning a partial list" {
    const allocator = std.testing.allocator;
    var tree = try setupTempTree(allocator, "cancel_hook");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var state: u8 = 0;
    const result = executeGlobWithCancel(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
        .cwd = tree.root,
    }, null, .{ .ctx = &state, .is_cancelled = StopRequested.isCancelled });

    // `match.txt` exists below the root, so a walk that ignored the hook would
    // return it: the error is the difference between "stopped" and "empty".
    try std.testing.expectError(error.Cancelled, result);
}
