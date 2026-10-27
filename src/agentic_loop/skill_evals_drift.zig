//! Tier 0 of a skill eval: the deterministic half. No LLM, no tokens. A skill
//! names things — file paths, commands, `file:line` references.

const std = @import("std");
const testing = std.testing;
const skill_evals_db = @import("skill_evals_db.zig");
const Verdict = skill_evals_db.Verdict;

/// Cap on the paths checked per skill.
pub const MAX_REFERENCED_PATHS = 50;

/// A skill larger than this is a smell (`MAX_SKILLS_SIZE` in `skills.zig`).
pub const MAX_BODY_BYTES = 100 * 1024;

pub const Finding = struct {
    dimension: []const u8,
    severity: []const u8,
    claim: []const u8,
    evidence: []const u8,
};

pub const Analysis = struct {
    verdict: Verdict = .keep,
    /// Always false — see the module doc. Present so the caller does not have
    /// to know that.
    has_high: bool = false,
    findings_json: []u8 = &.{},
    referenced_paths_json: []u8 = &.{},
    missing_paths_json: []u8 = &.{},
    finding_count: u32 = 0,
    missing_count: u32 = 0,

    pub fn deinit(self: Analysis, allocator: std.mem.Allocator) void {
        if (self.findings_json.len > 0) allocator.free(self.findings_json);
        if (self.referenced_paths_json.len > 0) allocator.free(self.referenced_paths_json);
        if (self.missing_paths_json.len > 0) allocator.free(self.missing_paths_json);
    }
};

fn jsonQuoted(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, s, .{});
}

fn buildStringArray(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try out.append(allocator, ',');
        const q = try jsonQuoted(allocator, s);
        defer allocator.free(q);
        try out.appendSlice(allocator, q);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn buildFindings(allocator: std.mem.Allocator, findings: []const Finding) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (findings, 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        const d = try jsonQuoted(allocator, f.dimension);
        defer allocator.free(d);
        const sv = try jsonQuoted(allocator, f.severity);
        defer allocator.free(sv);
        const c = try jsonQuoted(allocator, f.claim);
        defer allocator.free(c);
        const e = try jsonQuoted(allocator, f.evidence);
        defer allocator.free(e);
        const one = try std.fmt.allocPrint(allocator, "{{\"dimension\":{s},\"severity\":{s},\"claim\":{s},\"evidence\":{s}}}", .{ d, sv, c, e });
        defer allocator.free(one);
        try out.appendSlice(allocator, one);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

/// Delimiters that end a candidate path token. `/`, `.`, `-`, `_`, `:` and
/// digits are deliberately NOT delimiters — they are what makes a token look
/// like a path, and `:` is needed for the `file:line` form.
const token_delims = " \t\r\n`\"'()[]{}<>,;|*!?=";

/// Strip a trailing `:LINE` (or `:LINE:COL`) from a `file:line` reference.
fn stripLineSuffix(token: []const u8) []const u8 {
    // Loops rather than stripping once, so `file:line:col` collapses to `file`
    // as well as `file:line` does.
    var t = token;
    while (true) {
        const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return t;
        if (colon == 0 or colon + 1 >= t.len) return t;
        var all_digits = true;
        for (t[colon + 1 ..]) |ch| {
            if (!std.ascii.isDigit(ch)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) return t;
        t = t[0..colon];
    }
}

fn looksLikePath(token: []const u8) bool {
    if (token.len < 3 or token.len > 200) return false;
    // A `/` is what makes a token a path.
    if (std.mem.indexOfScalar(u8, token, '/') == null) return false;
    // A trailing slash is a directory prefix, not a file — and it is what a
    // glob like `src/**/*.zig` leaves behind once the `*` segments are
    // tokenized away. Stat'ing `src/` would be a meaningless check.
    if (token[token.len - 1] == '/') return false;
    return true;
}

/// True when a segment is a bare file extension (`.ts`) rather than a real
/// name.
fn isBareExtension(seg: []const u8) bool {
    if (seg.len < 2 or seg.len > 5) return false;
    if (seg[0] != '.') return false;
    for (seg[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

/// Tokens that are path-SHAPED but are prose, so stat'ing them can only ever
/// report them missing.
fn isProsePlaceholder(token: []const u8) bool {
    var all_single_char = true;
    var saw_segment = false;
    var it = std.mem.splitScalar(u8, token, '/');
    while (it.next()) |seg| {
        // An absolute path opens with `/`, which yields an empty first segment.
        // That is an artefact of the split, not evidence of anything.
        if (seg.len == 0) continue;
        saw_segment = true;
        if (seg.len != 1) all_single_char = false;
        // `.vue/.ts/.mts/.tsx` — a list of file globs, not one location. A
        // path's OWN extension is short and legitimate (`src/a.zig`), so the
        // discriminator is a bare extension standing as a whole segment.
        if (isBareExtension(seg)) return true;
    }
    // `N/N`, `X/Y` — the format placeholders in a summary line (`Build
    // Summary: N/N steps succeeded; X/Y tests passed`).
    return all_single_char and saw_segment;
}

fn shouldSkip(token: []const u8) bool {
    // URLs are not repo paths. Match the scheme delimiter rather than a bare
    // "http" prefix, which would also swallow real files like `http_server.zig`.
    if (std.mem.indexOf(u8, token, "://") != null) return true;
    if (std.mem.startsWith(u8, token, "//")) return true;
    // A leading slash means an absolute path OR a route.
    if (token.len > 0 and token[0] == '/') {
        if (!hasKnownExtension(token)) return true;
    }
    // Glob-ish or template-ish tokens: not a single concrete path.
    if (std.mem.indexOfAny(u8, token, "*?<>$") != null) return true;
    return false;
}

/// True when the token ends in one of the extensions a repo file plausibly has.
/// Used only to tell an absolute FILE path from a route.
fn hasKnownExtension(token: []const u8) bool {
    const known = [_][]const u8{
        ".zig", ".md",  ".ts",   ".vue", ".json", ".toml", ".sh",
        ".py",  ".yml", ".yaml", ".sql", ".txt",  ".rs",
    };
    for (known) |ext| {
        if (std.mem.endsWith(u8, token, ext)) return true;
    }
    return false;
}

/// Extract the de-duplicated path-ish tokens from a skill body, in order.
/// Caller owns the returned slice and each entry.
pub fn extractPaths(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, body, token_delims);
    while (it.next()) |raw| {
        if (out.items.len >= MAX_REFERENCED_PATHS) break;
        // Trailing `.`/`,`/`;`/`:` is sentence punctuation and must go, but a
        // LEADING `.` is part of the path: `.` is not in `token_delims`, so
        // trimming it here turned `.github/workflows/ci.yml` into
        const token = std.mem.trimEnd(u8, raw, ".,;:");
        if (!looksLikePath(token)) continue;
        if (shouldSkip(token)) continue;
        const base = stripLineSuffix(token);
        if (!looksLikePath(base)) continue;
        if (shouldSkip(base)) continue;
        if (isProsePlaceholder(base)) continue;

        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p, base)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try out.append(allocator, try allocator.dupe(u8, base));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Structural checks that need no filesystem at all.
fn structuralFindings(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Finding)) !void {
    if (body.len == 0) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "medium",
            .claim = "the skill body is empty",
            .evidence = "read 0 bytes",
        });
        return;
    }
    if (body.len > MAX_BODY_BYTES) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "medium",
            .claim = "the skill body is larger than the 100 KB listing cap, so its discovery cost is high",
            .evidence = "body exceeds MAX_SKILLS_SIZE (skills.zig)",
        });
    }
    // The frontmatter the prompt mandates. A missing `name:` means the skill
    // cannot be listed correctly, which is a real defect worth surfacing.
    if (std.mem.indexOf(u8, body, "name:") == null) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "low",
            .claim = "no `name:` in the frontmatter",
            .evidence = "no 'name:' token found in the body",
        });
    }
    if (std.mem.indexOf(u8, body, "description:") == null) {
        try out.append(allocator, .{
            .dimension = "structural",
            .severity = "low",
            .claim = "no `description:`, so the skill cannot be discovered by scanning list_skills",
            .evidence = "no 'description:' token found in the body",
        });
    }
}

/// Analyse one skill body against the code as it is now.
pub fn analyse(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    body: []const u8,
) !Analysis {
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(allocator);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    var referenced: std.ArrayList([]const u8) = .empty;
    defer referenced.deinit(allocator);

    try structuralFindings(allocator, body, &findings);

    const paths = try extractPaths(allocator, body);
    defer freePaths(allocator, paths);

    // A cwd that does not exist would turn every relative reference into a
    // false "missing" — and a removed git worktree is a routine event in this
    // repo, not an exotic one.
    const cwd_usable = if (cwd.len == 0) false else blk: {
        _ = std.Io.Dir.cwd().statFile(io, cwd, .{}) catch break :blk false;
        break :blk true;
    };

    for (paths) |p| {
        try referenced.append(allocator, p);
        if (p.len == 0) continue;

        // Resolve. Absolute stays as-is; relative joins onto cwd, which
        // `std.fs.path.join` keeps absolute when the root is absolute.
        const resolved: ?[]u8 = if (std.fs.path.isAbsolute(p))
            try allocator.dupe(u8, p)
        else if (cwd_usable)
            try std.fs.path.join(allocator, &.{ cwd, p })
        else
            null;
        if (resolved == null) continue;
        defer allocator.free(resolved.?);

        _ = std.Io.Dir.cwd().statFile(io, resolved.?, .{}) catch |err| {
            // Only a genuine "not there" is a stale path.
            if (err != error.FileNotFound) continue;
            try missing.append(allocator, p);
            try findings.append(allocator, .{
                .dimension = "stale_path",
                .severity = "medium",
                .claim = "this path does not exist any more",
                .evidence = p,
            });
            continue;
        };
    }

    const findings_json = try buildFindings(allocator, findings.items);
    errdefer allocator.free(findings_json);
    const referenced_json = try buildStringArray(allocator, referenced.items);
    errdefer allocator.free(referenced_json);
    const missing_json = try buildStringArray(allocator, missing.items);

    return .{
        .verdict = if (findings.items.len > 0) .update else .keep,
        .has_high = false,
        .findings_json = findings_json,
        .referenced_paths_json = referenced_json,
        .missing_paths_json = missing_json,
        .finding_count = @intCast(findings.items.len),
        .missing_count = @intCast(missing.items.len),
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

/// Parse the findings JSON and assert no finding claims severity `high`. This
/// is the real form of the module's central invariant.
fn assertNoHighSeverity(allocator: std.mem.Allocator, findings_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice([]Finding, allocator, findings_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    for (parsed.value) |f| {
        try testing.expect(!std.ascii.eqlIgnoreCase(f.severity, "high"));
    }
}

test "extractPaths finds path-shaped tokens and rejects the rest" {
    const alloc = testing.allocator;
    const body =
        \\## Procedure
        \\Run `rg foo src/agentic_loop/workflow.zig:1598` then read src/modules/config/Config.zig
        \\See docs/plans/2026-09-27-skill-evals.md for context.
        \\Call `zig build test --summary all`. Visit https://example.com/src/fake.zig
        \\The route is /api/skills/:name and the glob is src/**/*.zig
        \\The word workflow.zig is a bare filename and is NOT checkable.
    ;
    const paths = try extractPaths(alloc, body);
    defer freePaths(alloc, paths);

    // The exact set, in order. Asserting the whole slice is what makes this
    // test able to fail: the previous version scanned only the paths that were
    // KEPT, so its negative assertions passed vacuously.
    const expected = [_][]const u8{
        "src/agentic_loop/workflow.zig",
        "src/modules/config/Config.zig",
        "docs/plans/2026-09-27-skill-evals.md",
    };
    try testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
}

test "a bare filename is not treated as a checkable path" {
    const alloc = testing.allocator;
    // A bare filename would be stat'd against the repo root, where it almost
    // never lives, so a healthy skill mentioning `Sidebar.vue` would be
    // reported as stale — and that false positive is cached into the shared
    const paths = try extractPaths(alloc, "Edit Sidebar.vue and tsconfig.app.json, then run it.");
    defer freePaths(alloc, paths);
    try testing.expectEqual(@as(usize, 0), paths.len);

    // A token that is only an extension is not a path either.
    const ext_only = try extractPaths(alloc, "edit the .zig file");
    defer freePaths(alloc, ext_only);
    try testing.expectEqual(@as(usize, 0), ext_only.len);
}

test "a multi-segment absolute path is checked, a one-segment route is not" {
    const alloc = testing.allocator;
    const paths = try extractPaths(alloc, "Read /home/u/proj/src/a.zig but the route is /api/skills");
    defer freePaths(alloc, paths);
    // The absolute FILE path is kept; the route (no extension) is not.
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("/home/u/proj/src/a.zig", paths[0]);
}

test "a glob's directory prefix is not treated as a path" {
    const alloc = testing.allocator;
    // `src/**/*.zig` tokenizes to `src/` once the `*` segments are stripped;
    // stat'ing that would be a meaningless check on a directory prefix.
    const paths = try extractPaths(alloc, "the glob is src/**/*.zig and also src/agentic_loop/*.zig");
    defer freePaths(alloc, paths);
    try testing.expectEqual(@as(usize, 0), paths.len);
}

test "a real file whose name starts with http is not mistaken for a URL" {
    const alloc = testing.allocator;
    const paths = try extractPaths(alloc, "See src/net/http_server.zig and https://example.com/x.zig");
    defer freePaths(alloc, paths);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("src/net/http_server.zig", paths[0]);
}

test "stripLineSuffix removes a :line and a :line:col but not a plain path" {
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:12"));
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:12:5"));
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig"));
    // A colon that is not a line number is left alone.
    try testing.expectEqualStrings("a/b:c.zig", stripLineSuffix("a/b:c.zig"));
}

test "a missing referenced path is reported as needing an UPDATE, never a delete" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: probe
        \\description: probe
        \\---
        \\## Procedure
        \\Read src/this/path/does/not/exist.zig then continue.
    ;
    // The root is THIS checkout, never "/tmp": a root that does not exist makes
    // every relative reference uncheckable, so the module reports nothing
    // missing at all (and on Windows there is no /tmp to find).
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), a.missing_count);
    try testing.expectEqual(@as(u32, 1), a.finding_count);
    // The invariant this module exists to keep, asserted on the ACTUAL
    // severities rather than on the hard-coded `has_high` flag — which is a
    // literal `false` and so could never fail.
    try testing.expect(!a.has_high);
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expectEqual(Verdict.update, skill_evals_db.decideVerdict(a.verdict, a.has_high));
    try testing.expectEqualStrings("[\"src/this/path/does/not/exist.zig\"]", a.missing_paths_json);
    try assertNoHighSeverity(alloc, a.findings_json);
}

test "a healthy skill is a keep with no findings" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: healthy
        \\description: a skill whose references all resolve
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig for the details.
    ;
    // cwd "." rather than an absolute path to the developer's checkout: the
    // file referenced below is in THIS tree, and the test binary runs from it.
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 0), a.missing_count);
    try testing.expectEqual(@as(u32, 0), a.finding_count);
    try testing.expectEqual(Verdict.keep, a.verdict);
    try testing.expectEqualStrings("[]", a.findings_json);
    try testing.expectEqualStrings("[]", a.missing_paths_json);
}

test "structural problems are found without touching the filesystem" {
    const alloc = testing.allocator;
    const body = "no frontmatter at all, and no description either\n";
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 2), a.finding_count); // name + description
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expect(!a.has_high);
}

test "an empty body is a finding, not a crash" {
    const alloc = testing.allocator;
    const a = try analyse(alloc, testing.io, ".", "");
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), a.finding_count);
    try testing.expectEqual(Verdict.update, a.verdict);
    try testing.expect(!a.has_high);
}

test "a relative path is only checked when there is a cwd to resolve it against" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: rel
        \\description: rel
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    // With a cwd, the path resolves and is found.
    const with_cwd = try analyse(alloc, testing.io, ".", body);
    defer with_cwd.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), with_cwd.missing_count);
    try testing.expectEqual(Verdict.keep, with_cwd.verdict);

    // Without one we say NOTHING rather than reporting a false "missing" — an
    // honest unknown beats a wrong verdict.
    const without_cwd = try analyse(alloc, testing.io, "", body);
    defer without_cwd.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), without_cwd.missing_count);
}

test "analyse tolerates a body full of hostile tokens without aborting" {
    const alloc = testing.allocator;
    // Empty-ish, relative-only, absolute, glob, URL, and a bare slash: this is
    // the shape that used to be able to kill the process via the *Absolute
    // assert family. It must return a verdict instead.
    const body =
        \\.zig :12 / // ../..  ../../etc/passwd http://x/y.zig **/*.md ``
        \\C:\Users\fake\file.zig
    ;
    const a = try analyse(alloc, testing.io, "/tmp", body);
    defer a.deinit(alloc);
    // It RETURNED, which is the point — the *Absolute family would have
    // aborted the process here.
    try assertNoHighSeverity(alloc, a.findings_json);
    try testing.expect(skill_evals_db.decideVerdict(a.verdict, a.has_high) != .delete);
}

test "a mixed body reports only the path that is actually missing" {
    const alloc = testing.allocator;
    // The case that proves a present path was FOUND rather than skipped: an
    // all-missing body cannot distinguish "checked and failed" from "did not
    // check at all".
    const body =
        \\---
        \\name: mixed
        \\description: mixed
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig then src/gone/forever.zig
    ;
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), a.missing_count);
    try testing.expectEqualStrings("[\"src/gone/forever.zig\"]", a.missing_paths_json);
    // Both were referenced; only one is missing.
    try testing.expectEqualStrings(
        "[\"src/agentic_loop/skill_evals_drift.zig\",\"src/gone/forever.zig\"]",
        a.referenced_paths_json,
    );
}

test "a cwd that does not exist reports nothing rather than 50 false misses" {
    const alloc = testing.allocator;
    // A removed git worktree is a routine event in this repo, so a stale cwd is
    // a normal input, not an exotic one. Every relative path would fail to
    // stat, and reporting them all as rot would be 50 lies.
    const body =
        \\---
        \\name: gone-cwd
        \\description: gone-cwd
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    const a = try analyse(alloc, testing.io, "/tmp/definitely-not-a-real-dir-xyz", body);
    defer a.deinit(alloc);

    try testing.expectEqual(@as(u32, 0), a.missing_count);
    try testing.expectEqual(Verdict.keep, a.verdict);
}

test "a path that resolves to a directory is not a missing path" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: dir
        \\description: dir
        \\---
        \\See src/agentic_loop for the code.
    ;
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.missing_count);
}

test "extractPaths caps at MAX_REFERENCED_PATHS without erroring" {
    const alloc = testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    // 120 distinct paths, well past the 50 cap.
    var i: u32 = 0;
    while (i < 120) : (i += 1) {
        try body.appendSlice(alloc, "src/dir");
        var buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{i}) catch @panic("bufPrint failed formatting the skill-evals drift index");
        try body.appendSlice(alloc, n);
        try body.appendSlice(alloc, "/file.zig ");
    }
    const paths = try extractPaths(alloc, body.items);
    defer freePaths(alloc, paths);
    // The cap holds and the overflow is silent, not an error.
    try testing.expectEqual(MAX_REFERENCED_PATHS, paths.len);
}

test "extractPaths on a body of only delimiters or whitespace yields nothing" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "", "   \n\t  ", "//", "`` ``", "()[]{}<>,;|*!?=" }) |body| {
        const paths = try extractPaths(alloc, body);
        defer freePaths(alloc, paths);
        try testing.expectEqual(@as(usize, 0), paths.len);
    }
}

test "analyse is deterministic: the same body twice is byte-identical" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: det
        \\description: det
        \\---
        \\Read src/agentic_loop/skill_evals_drift.zig and src/nope/gone.zig
    ;
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    const b = try analyse(alloc, testing.io, ".", body);
    defer b.deinit(alloc);

    try testing.expectEqualStrings(a.findings_json, b.findings_json);
    try testing.expectEqualStrings(a.missing_paths_json, b.missing_paths_json);
    try testing.expectEqualStrings(a.referenced_paths_json, b.referenced_paths_json);
    try testing.expectEqual(a.verdict, b.verdict);
}

test "a body at exactly MAX_BODY_BYTES is not flagged, one byte over is" {
    const alloc = testing.allocator;
    // The structural check is `> MAX_BODY_BYTES`, so the boundary itself is
    // clean. Build a body with the frontmatter present so only the size
    // finding can fire.
    const prefix = "---\nname: big\ndescription: big\n---\n";
    const at_cap = try alloc.alloc(u8, MAX_BODY_BYTES);
    defer alloc.free(at_cap);
    @memcpy(at_cap[0..prefix.len], prefix);
    @memset(at_cap[prefix.len..], 'x');
    const a = try analyse(alloc, testing.io, ".", at_cap);
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.finding_count);

    const over = try alloc.alloc(u8, MAX_BODY_BYTES + 1);
    defer alloc.free(over);
    @memcpy(over[0..prefix.len], prefix);
    @memset(over[prefix.len..], 'x');
    const b = try analyse(alloc, testing.io, ".", over);
    defer b.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), b.finding_count);
    try testing.expectEqual(Verdict.update, b.verdict);
}

test "a path token containing quotes or a backslash survives JSON encoding" {
    const alloc = testing.allocator;
    const body =
        \\---
        \\name: hostile
        \\description: hostile
        \\---
        \\Read src/we"ird/pa'th.zig and src/back\slash/x.zig
    ;
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    // The emitted JSON must parse — a raw quote would make the whole field
    // unreadable for the client that parses it. Parsed as a generic Value
    // because the static parser would try to read a bare string as a number.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, a.missing_paths_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(parsed.value.array.items.len >= 1);
}

test "stripLineSuffix handles a huge line number and a trailing colon" {
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:999999999999"));
    try testing.expectEqualStrings("a/b.zig", stripLineSuffix("a/b.zig:12:5:9"));
    // A trailing colon is not a line suffix.
    try testing.expectEqualStrings("a/b.zig:", stripLineSuffix("a/b.zig:"));
    // A colon at index 0 is not a line suffix.
    try testing.expectEqualStrings(":12", stripLineSuffix(":12"));
}

test "a dot-directory path keeps its leading dot instead of being reported as rot" {
    const alloc = testing.allocator;
    // Both of these exist in this tree.
    const body =
        \\---
        \\name: dotpath
        \\description: dotpath
        \\---
        \\See .github/workflows/ci.yml:210 and .pabrik/hooks for the details.
    ;
    const paths = try extractPaths(alloc, body);
    defer freePaths(alloc, paths);

    var saw_github = false;
    var saw_hooks = false;
    for (paths) |p| {
        try testing.expect(!std.mem.eql(u8, p, "github/workflows/ci.yml"));
        try testing.expect(!std.mem.eql(u8, p, "pabrik/hooks"));
        if (std.mem.eql(u8, p, ".github/workflows/ci.yml")) saw_github = true;
        if (std.mem.eql(u8, p, ".pabrik/hooks")) saw_hooks = true;
    }
    try testing.expect(saw_github);
    // Without this the loop's two `expect` lines pass vacuously whenever the
    // extractor stops yielding the token at all, so the leading-dot behaviour
    // would go untested while the test stayed green.
    try testing.expect(saw_hooks);

    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.missing_count);
}

test "a dot-directory path that really is gone is still reported" {
    const alloc = testing.allocator;
    // The guard against "fix" meaning "skip anything dot-prefixed": a genuinely
    // absent dot-path must still reach the missing list, dot intact.
    const body =
        \\---
        \\name: dotgone
        \\description: dotgone
        \\---
        \\See .github/workflows/definitely-not-here.yml
    ;
    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), a.missing_count);
    try testing.expectEqualStrings("[\".github/workflows/definitely-not-here.yml\"]", a.missing_paths_json);
}

test "format placeholders and glob lists in prose are not stale paths" {
    const alloc = testing.allocator;
    // All three were recorded as "this path does not exist any more" against a
    // skill whose every real reference was fine. None is a location: two are
    // the summary placeholders, one is a list of file globs.
    const body =
        \\---
        \\name: prose
        \\description: prose
        \\---
        \\Read `Build Summary: N/N steps succeeded; X/Y tests passed`.
        \\The hook formats .vue/.ts/.mts/.tsx with prettier.
    ;
    const paths = try extractPaths(alloc, body);
    defer freePaths(alloc, paths);
    for (paths) |p| {
        try testing.expect(!std.mem.eql(u8, p, "N/N"));
        try testing.expect(!std.mem.eql(u8, p, "X/Y"));
        try testing.expect(!std.mem.startsWith(u8, p, ".vue/"));
    }

    const a = try analyse(alloc, testing.io, ".", body);
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.missing_count);
    try testing.expectEqual(Verdict.keep, a.verdict);
}

test "isProsePlaceholder spares every real dot-directory this repo contains" {
    // The length bound in `isBareExtension` is the only thing separating a
    // legitimate dot-directory from prose. These are the names that actually
    // occur here; move the bound and this is what catches it.
    for ([_][]const u8{
        ".github/workflows/ci.yml",
        ".zig-cache/tmp",
        ".pabrik/hooks/register_hook.lua",
        "src/apps/desktop",
        "src/agentic_loop/skill_evals_drift.zig",
        // An absolute path splits into an empty first segment plus ordinary
        // ones. The empty segment must not read as a placeholder, and neither
        // must the single-character `u` in the home directory.
        "/home/u/proj/src/a.zig",
    }) |p| {
        try testing.expect(!isProsePlaceholder(p));
    }
    for ([_][]const u8{ "N/N", "X/Y", ".vue/.ts/.mts/.tsx", ".ts" }) |p| {
        try testing.expect(isProsePlaceholder(p));
    }
}

test "trailing sentence punctuation is still stripped from a path token" {
    // `trimEnd` replaced `trim`, so the trailing behaviour is unchanged --
    // this is the assertion that says so.
    const alloc = testing.allocator;
    const paths = try extractPaths(alloc, "Read src/agentic_loop/skill_evals_drift.zig, then stop.");
    defer freePaths(alloc, paths);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("src/agentic_loop/skill_evals_drift.zig", paths[0]);
}
