//! THE parser and renderer for the `---` block at the top of a skill body.
//!
//! Two hand-written parsers used to live on either side of the skill write
//! path — one in `modules/agent/tools/skills.zig` for the importer, one in
//! `skill_tools.zig` for `add_skill`/`edit_skill` — and they disagreed about
//! duplicate keys and about what a value is. Everything that needs to read
//! or write frontmatter goes through this file instead.
//!
//! Three keys are PROMOTED: `name`, `description` and `is_can_auto_improve`
//! have columns on `skills`, so `parse` lifts them into `Header` and never
//! repeats them in `pairs`. Everything else is metadata, and metadata is a
//! table row (`skill_metadata`), not a block somebody re-scans per request.
//!
//! The body keeps its fence: `skills.content` is stored byte-exact because a
//! `skill_eval` identity is sha256(body), so this module never rewrites a
//! body on its own — `render` is only called by a caller that is already
//! replacing it.

const std = @import("std");

/// Longest accepted frontmatter key. A key becomes a `skill_metadata.key`
/// column and a JSON field name, so a paragraph with a colon in it is not
/// one.
pub const MAX_KEY_BYTES: usize = 64;

/// The keys `skills` keeps in typed columns rather than in `skill_metadata`.
pub const PROMOTED_KEYS = [_][]const u8{ "name", "description", "is_can_auto_improve" };

/// True when `key` has a dedicated column, i.e. must not also become a
/// metadata row (one fact, one home).
pub fn isPromoted(key: []const u8) bool {
    for (PROMOTED_KEYS) |promoted| {
        if (std.mem.eql(u8, key, promoted)) return true;
    }
    return false;
}

/// The promoted keys, typed. Owned strings, except an absent one, which is
/// the empty literal.
pub const Header = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    /// Only an explicit truthy/falsey token counts; anything else leaves
    /// the column's default in place.
    is_can_auto_improve: ?bool = null,
};

/// One frontmatter key that has no column. Owned strings.
pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

/// A parsed body. `header` and `pairs` are owned; `body` points INTO the
/// content that was parsed, so the caller keeps that buffer alive.
pub const Parsed = struct {
    header: Header = .{},
    pairs: []const Pair = &.{},
    /// Everything after the closing fence. The whole input when
    /// `has_fence` is false.
    body: []const u8 = "",
    has_fence: bool = false,

    pub fn deinit(self: *const Parsed, allocator: std.mem.Allocator) void {
        if (self.header.name.len > 0) allocator.free(self.header.name);
        if (self.header.description.len > 0) allocator.free(self.header.description);
        for (self.pairs) |pair| {
            allocator.free(pair.key);
            allocator.free(pair.value);
        }
        if (self.pairs.len > 0) allocator.free(self.pairs);
    }
};

/// The value of `key` in `pairs`, or null.
pub fn find(pairs: []const Pair, key: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return null;
}

const Fence = struct {
    block: []const u8,
    body: []const u8,
};

/// Split a leading `---` … `---` fence off `content`. Null when the input
/// does not OPEN with a fence line or the fence is never closed — a `---`
/// in the middle of a body is prose, not a delimiter.
fn splitFence(content: []const u8) ?Fence {
    if (!std.mem.startsWith(u8, content, "---")) return null;
    var i: usize = 3;
    if (i < content.len and content[i] == '\r') i += 1;
    if (i >= content.len or content[i] != '\n') return null;
    i += 1;

    const rest = content[i..];
    var line_start: usize = 0;
    while (line_start <= rest.len) {
        const newline = std.mem.indexOfScalarPos(u8, rest, line_start, '\n');
        const line_end = newline orelse rest.len;
        var line = rest[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.eql(u8, line, "---")) {
            const body_start = if (newline) |n| n + 1 else rest.len;
            return .{ .block = rest[0..line_start], .body = rest[body_start..] };
        }
        if (newline == null) break;
        line_start = newline.? + 1;
    }
    return null;
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_KEY_BYTES) return false;
    if (!std.ascii.isAlphanumeric(key[0]) and key[0] != '_') return false;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// One layer of matching quotes off, with the escapes a double-quoted YAML
/// string can carry. The result is owned.
fn valueAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0) return &.{};

    const quoted = trimmed.len >= 2 and
        ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''));

    if (!quoted) return allocator.dupe(u8, trimmed);

    const inner = trimmed[1 .. trimmed.len - 1];
    if (trimmed[0] == '\'') return allocator.dupe(u8, inner);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\' or i + 1 >= inner.len) {
            try out.append(allocator, inner[i]);
            continue;
        }
        i += 1;
        try out.append(allocator, switch (inner[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => inner[i],
        });
    }
    return out.toOwnedSlice(allocator);
}

fn boolValue(raw: []const u8) ?bool {
    const v = std.mem.trim(u8, raw, " \t\r\"'");
    if (v.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no")) return false;
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "0")) return false;
    return null;
}

fn freePairs(allocator: std.mem.Allocator, pairs: []const Pair) void {
    for (pairs) |pair| {
        allocator.free(pair.key);
        allocator.free(pair.value);
    }
    if (pairs.len > 0) allocator.free(pairs);
}

/// Parse the frontmatter of `content`. Never fails on malformed input: a
/// line that is not `key: value` is not metadata, and an unusable body
/// still yields `has_fence = false` so the caller falls back to the whole
/// input as the body.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) error{OutOfMemory}!Parsed {
    const fence = splitFence(content) orelse return .{ .body = content };

    var header: Header = .{};
    errdefer {
        if (header.name.len > 0) allocator.free(header.name);
        if (header.description.len > 0) allocator.free(header.description);
    }

    var pairs: std.ArrayList(Pair) = .empty;
    errdefer {
        freePairs(allocator, pairs.items);
        pairs.deinit(allocator);
    }

    const block = fence.block;
    var idx: usize = 0;
    while (idx < block.len) {
        const newline = std.mem.indexOfScalarPos(u8, block, idx, '\n');
        const line_end = newline orelse block.len;
        var line = block[idx..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        idx = if (newline) |n| n + 1 else block.len;

        const trimmed = trimLine(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.ascii.isWhitespace(line[0])) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!isValidKey(key)) continue;

        const inline_value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        var continuation: std.ArrayList(u8) = .empty;
        defer continuation.deinit(allocator);
        if (inline_value.len == 0) {
            while (idx < block.len) {
                const nl2 = std.mem.indexOfScalarPos(u8, block, idx, '\n');
                const le2 = nl2 orelse block.len;
                var l2 = block[idx..le2];
                if (l2.len > 0 and l2[l2.len - 1] == '\r') l2 = l2[0 .. l2.len - 1];
                const t2 = trimLine(l2);
                if (t2.len == 0 or !std.ascii.isWhitespace(l2[0])) break;
                idx = if (nl2) |n| n + 1 else block.len;
                if (continuation.items.len > 0) try continuation.append(allocator, '\n');
                try continuation.appendSlice(allocator, t2);
            }
        }

        const raw = if (inline_value.len > 0) inline_value else continuation.items;

        if (std.mem.eql(u8, key, "name")) {
            if (header.name.len > 0) allocator.free(header.name);
            header.name = try valueAlloc(allocator, raw);
            continue;
        }
        if (std.mem.eql(u8, key, "description")) {
            if (header.description.len > 0) allocator.free(header.description);
            header.description = try valueAlloc(allocator, raw);
            continue;
        }
        if (std.mem.eql(u8, key, "is_can_auto_improve")) {
            header.is_can_auto_improve = boolValue(raw);
            continue;
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try valueAlloc(allocator, raw);
        errdefer allocator.free(owned_value);

        var replaced = false;
        for (pairs.items) |*existing| {
            if (!std.mem.eql(u8, existing.key, owned_key)) continue;
            allocator.free(existing.value);
            existing.value = owned_value;
            allocator.free(owned_key);
            replaced = true;
            break;
        }
        if (!replaced) try pairs.append(allocator, .{ .key = owned_key, .value = owned_value });
    }

    return .{
        .header = header,
        .pairs = try pairs.toOwnedSlice(allocator),
        .body = fence.body,
        .has_fence = true,
    };
}

fn needsQuoting(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value, 0..) |c, i| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\t') return true;
        if (c == ':' and i + 1 < value.len and value[i + 1] == ' ') return true;
        if (c == '#' and i > 0 and value[i - 1] == ' ') return true;
    }
    return value[0] == ' ' or value[value.len - 1] == ' ' or
        value[0] == '[' or value[0] == '{' or value[0] == '\'' or value[0] == '#' or value[0] == '-';
}

fn appendQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// A whole skill body: the fence rebuilt from `header` + `pairs`, then
/// `body` verbatim.
///
/// `is_can_auto_improve` is never written: the lock is a column, and
/// re-emitting it would change the sha256 of every body on every edit.
/// Promoted keys in `pairs` are skipped for the same reason — the header
/// already carries them.
pub fn render(
    allocator: std.mem.Allocator,
    header: Header,
    pairs: []const Pair,
    body: []const u8,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "---\n");
    try out.appendSlice(allocator, "name: ");
    try out.appendSlice(allocator, header.name);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "description: ");
    try appendQuoted(allocator, &out, header.description);
    try out.append(allocator, '\n');
    for (pairs) |pair| {
        if (isPromoted(pair.key)) continue;
        try out.appendSlice(allocator, pair.key);
        try out.append(allocator, ':');
        if (pair.value.len == 0) {
            try out.append(allocator, '\n');
            continue;
        }
        try out.append(allocator, ' ');
        if (needsQuoting(pair.value)) {
            try appendQuoted(allocator, &out, pair.value);
        } else {
            try out.appendSlice(allocator, pair.value);
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "---\n");
    try out.appendSlice(allocator, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try out.append(allocator, '\n');

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// skill_frontmatter — inline tests
// ============================================================================

const testing = std.testing;

const MANIFEST =
    \\---
    \\name: pdf
    \\description: "Use when the user wants anything with a PDF file."
    \\origin: ECC
    \\tags: [workflow, documents]
    \\license: Proprietary. LICENSE.txt has complete terms
    \\---
    \\## When to Use
    \\
    \\Run `scripts/convert.py`.
;

test "parse lifts the three promoted keys and leaves the rest as metadata" {
    const alloc = testing.allocator;
    var parsed = try parse(alloc, MANIFEST);
    defer parsed.deinit(alloc);

    try testing.expect(parsed.has_fence);
    try testing.expectEqualStrings("pdf", parsed.header.name);
    try testing.expectEqualStrings("Use when the user wants anything with a PDF file.", parsed.header.description);

    try testing.expectEqual(@as(usize, 3), parsed.pairs.len);
    try testing.expectEqualStrings("origin", parsed.pairs[0].key);
    try testing.expectEqualStrings("ECC", parsed.pairs[0].value);
    try testing.expectEqualStrings("[workflow, documents]", find(parsed.pairs, "tags").?);
    try testing.expectEqualStrings("Proprietary. LICENSE.txt has complete terms", find(parsed.pairs, "license").?);

    for (parsed.pairs) |pair| {
        try testing.expect(!isPromoted(pair.key));
    }
}

test "parse returns the body after the closing fence, byte for byte" {
    const alloc = testing.allocator;
    var parsed = try parse(alloc, MANIFEST);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("## When to Use\n\nRun `scripts/convert.py`.", parsed.body);
}

test "a body with no fence is all body, and no key is invented" {
    const alloc = testing.allocator;
    const bare = "## When to Use\n\n---\nnot a fence because it is not at the top\n";

    var parsed = try parse(alloc, bare);
    defer parsed.deinit(alloc);

    try testing.expect(!parsed.has_fence);
    try testing.expectEqualStrings(bare, parsed.body);
    try testing.expectEqual(@as(usize, 0), parsed.pairs.len);
    try testing.expectEqualStrings("", parsed.header.name);
}

test "an unterminated fence is not treated as frontmatter" {
    const alloc = testing.allocator;
    const open = "---\nname: half-written\n";

    var parsed = try parse(alloc, open);
    defer parsed.deinit(alloc);

    try testing.expect(!parsed.has_fence);
    try testing.expectEqualStrings(open, parsed.body);
    try testing.expectEqualStrings("", parsed.header.name);
}

test "a closing fence at end of input still closes the block" {
    const alloc = testing.allocator;
    var parsed = try parse(alloc, "---\nname: tiny\ntags: [a]\n---");
    defer parsed.deinit(alloc);

    try testing.expect(parsed.has_fence);
    try testing.expectEqualStrings("tiny", parsed.header.name);
    try testing.expectEqualStrings("", parsed.body);
    try testing.expectEqualStrings("[a]", find(parsed.pairs, "tags").?);
}

test "quotes are stripped, escapes resolved, and a quoted colon keeps its spaces" {
    const alloc = testing.allocator;
    const content =
        \\---
        \\name: quoted
        \\description: "He said \"go\" and then\tleft"
        \\plain: no quotes here
        \\single: 'keep: this as one value'
        \\---
        \\body
    ;
    var parsed = try parse(alloc, content);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("He said \"go\" and then\tleft", parsed.header.description);
    try testing.expectEqualStrings("no quotes here", find(parsed.pairs, "plain").?);
    try testing.expectEqualStrings("keep: this as one value", find(parsed.pairs, "single").?);
}

test "is_can_auto_improve is lifted as a boolean and never becomes metadata" {
    const alloc = testing.allocator;
    inline for ([_][]const u8{ "false", "no", "0", "\"false\"" }) |token| {
        const content = try std.fmt.allocPrint(alloc, "---\nname: pinned\nis_can_auto_improve: {s}\n---\nbody", .{token});
        defer alloc.free(content);

        var parsed = try parse(alloc, content);
        defer parsed.deinit(alloc);
        try testing.expect(parsed.header.is_can_auto_improve == false);
        try testing.expect(find(parsed.pairs, "is_can_auto_improve") == null);
    }

    var unknown = try parse(alloc, "---\nis_can_auto_improve: maybe\n---\n");
    defer unknown.deinit(alloc);
    try testing.expect(unknown.header.is_can_auto_improve == null);
}

test "a repeated key keeps the last value and produces one row" {
    const alloc = testing.allocator;
    var parsed = try parse(alloc, "---\norigin: first\norigin: second\n---\n");
    defer parsed.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), parsed.pairs.len);
    try testing.expectEqualStrings("second", parsed.pairs[0].value);
}

test "a key with an indented block keeps the block instead of dropping the value" {
    const alloc = testing.allocator;
    const content =
        \\---
        \\name: nested
        \\metadata:
        \\  owner: docs-team
        \\  reviewed: 2026-10-01
        \\origin: ECC
        \\---
        \\body
    ;
    var parsed = try parse(alloc, content);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("owner: docs-team\nreviewed: 2026-10-01", find(parsed.pairs, "metadata").?);
    try testing.expectEqualStrings("ECC", find(parsed.pairs, "origin").?);
}

test "a line that is not key: value is skipped and never becomes a key" {
    const alloc = testing.allocator;
    const content =
        \\---
        \\name: junk
        \\just some prose
        \\- a list item
        \\key with spaces: nope
        \\ok: yes
        \\---
        \\body
    ;
    var parsed = try parse(alloc, content);
    defer parsed.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), parsed.pairs.len);
    try testing.expectEqualStrings("ok", parsed.pairs[0].key);
}

test "render rebuilds the fence and keeps every metadata key" {
    const alloc = testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "origin", .value = "ECC" },
        .{ .key = "tags", .value = "[workflow, documents]" },
        .{ .key = "license", .value = "Proprietary. LICENSE.txt has complete terms" },
    };
    const out = try render(alloc, .{ .name = "pdf", .description = "Work with PDFs." }, &pairs, "## Body\n");
    defer alloc.free(out);

    try testing.expectEqualStrings(
        "---\nname: pdf\ndescription: \"Work with PDFs.\"\n" ++
            "origin: ECC\ntags: \"[workflow, documents]\"\n" ++
            "license: Proprietary. LICENSE.txt has complete terms\n---\n## Body\n",
        out,
    );
}

test "render then parse is the same header and the same metadata" {
    const alloc = testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "origin", .value = "ECC" },
        .{ .key = "note", .value = "a value: with a colon" },
    };
    const rendered = try render(alloc, .{ .name = "round-trip", .description = "He said \"hi\"" }, &pairs, "Body line\n");
    defer alloc.free(rendered);

    var parsed = try parse(alloc, rendered);
    defer parsed.deinit(alloc);

    try testing.expectEqualStrings("round-trip", parsed.header.name);
    try testing.expectEqualStrings("He said \"hi\"", parsed.header.description);
    try testing.expectEqualStrings("ECC", find(parsed.pairs, "origin").?);
    try testing.expectEqualStrings("a value: with a colon", find(parsed.pairs, "note").?);
    try testing.expectEqualStrings("Body line\n", parsed.body);
}

test "render does not double the trailing newline a body already has" {
    const alloc = testing.allocator;
    const with_newline = try render(alloc, .{ .name = "a", .description = "d" }, &.{}, "Body\n");
    defer alloc.free(with_newline);
    try testing.expectEqualStrings("---\nname: a\ndescription: \"d\"\n---\nBody\n", with_newline);

    const without = try render(alloc, .{ .name = "a", .description = "d" }, &.{}, "Body");
    defer alloc.free(without);
    try testing.expectEqualStrings("---\nname: a\ndescription: \"d\"\n---\nBody\n", without);
}

test "render never writes the promoted keys it was handed as metadata" {
    const alloc = testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "name", .value = "not-the-header" },
        .{ .key = "is_can_auto_improve", .value = "false" },
        .{ .key = "origin", .value = "ECC" },
    };
    const out = try render(alloc, .{ .name = "kept", .description = "d" }, &pairs, "Body\n");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "name: kept") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not-the-header") == null);
    try testing.expect(std.mem.indexOf(u8, out, "is_can_auto_improve") == null);
    try testing.expect(std.mem.indexOf(u8, out, "origin: ECC") != null);
}
