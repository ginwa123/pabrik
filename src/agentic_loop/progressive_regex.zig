//! Tiny in-process regex engine for `search_tool`'s catalog query. Why
//! hand-rolled: the catalog is an in-memory list of `AgentTool`s.

const std = @import("std");

pub const Error = error{ InvalidPattern, PatternTooLong, OutOfMemory };

pub const Options = struct {
    /// ASCII case folding, both for the pattern and for the text.
    case_insensitive: bool = true,
};

/// Compiled program cap. `a{0,900}{0,900}` would otherwise expand to 810k
/// instructions from a 15-byte pattern.
pub const MAX_INSTRS: usize = 1024;

/// Per-`isMatch` budget, counted in thread insertions. A real catalog query
/// uses a few thousand; the cap only exists so a hostile pattern cannot stall
/// the agent worker. Tripping it is reported via `exhausted()`.
pub const MAX_STEPS: usize = 2_000_000;

const Inst = union(enum) {
    char: u8,
    any,
    class: u32,
    split: struct { a: u32, b: u32 },
    jmp: u32,
    assert_start,
    assert_end,
    word_boundary: bool,
    match,
};

const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: u32,
    assert_start,
    assert_end,
    word_boundary: bool,
    star: u32,
    plus: u32,
    opt: u32,
    repeat: struct { node: u32, min: u32, max: ?u32 },
    concat: []const u32,
    alt: []const u32,
};

const ClassSet = [256]bool;

const ThreadList = struct {
    pcs: std.ArrayList(u32) = .empty,
    /// `seen[pc] == gen` ⇔ this pc is already in this list for this position.
    seen: []u32 = &.{},
    gen: u32 = 0,

    fn reset(self: *ThreadList) void {
        self.gen +%= 1;
        if (self.gen == 0) {
            @memset(self.seen, 0);
            self.gen = 1;
        }
        self.pcs.clearRetainingCapacity();
    }
};

pub const Regex = struct {
    allocator: std.mem.Allocator,
    insts: []Inst,
    classes: []ClassSet,
    case_insensitive: bool,
    list_a: ThreadList = .{},
    list_b: ThreadList = .{},
    steps: usize = 0,
    exhausted_flag: bool = false,

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.insts);
        self.allocator.free(self.classes);
        self.allocator.free(self.list_a.seen);
        self.allocator.free(self.list_b.seen);
        self.list_a.pcs.deinit(self.allocator);
        self.list_b.pcs.deinit(self.allocator);
        self.* = undefined;
    }

    /// True when the last `isMatch` hit the step budget — results from that
    /// call are incomplete (false negatives possible).
    pub fn exhausted(self: *const Regex) bool {
        return self.exhausted_flag;
    }

    /// Unanchored search: the pattern may match anywhere unless it asserts `^`.
    pub fn isMatch(self: *Regex, text: []const u8) bool {
        self.steps = 0;
        self.exhausted_flag = false;

        var cur: *ThreadList = &self.list_a;
        var next: *ThreadList = &self.list_b;
        cur.reset();

        var pos: usize = 0;
        while (true) {
            // The unanchored prefix: a fresh attempt starting at every position.
            self.addThread(cur, 0, pos, text);

            for (cur.pcs.items) |pc| {
                if (std.meta.activeTag(self.insts[pc]) == .match) return true;
            }
            if (pos == text.len) return false;

            next.reset();
            const b = text[pos];
            for (cur.pcs.items) |pc| {
                switch (self.insts[pc]) {
                    .char => |ch| {
                        if (self.foldByte(b) == ch) self.addThread(next, pc + 1, pos + 1, text);
                    },
                    .any => {
                        if (b != '\n') self.addThread(next, pc + 1, pos + 1, text);
                    },
                    .class => |class_idx| {
                        if (self.classes[class_idx][self.foldByte(b)]) self.addThread(next, pc + 1, pos + 1, text);
                    },
                    else => {},
                }
            }

            const tmp = cur;
            cur = next;
            next = tmp;
            pos += 1;
        }
    }

    fn foldByte(self: *const Regex, b: u8) u8 {
        return if (self.case_insensitive) std.ascii.toLower(b) else b;
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }

    fn addThread(self: *Regex, list: *ThreadList, pc: u32, pos: usize, text: []const u8) void {
        if (self.exhausted_flag) return;
        self.steps += 1;
        if (self.steps > MAX_STEPS) {
            self.exhausted_flag = true;
            return;
        }
        if (pc >= self.insts.len) return;
        if (list.seen[pc] == list.gen) return;
        list.seen[pc] = list.gen;

        switch (self.insts[pc]) {
            .jmp => |target| self.addThread(list, target, pos, text),
            .split => |s| {
                self.addThread(list, s.a, pos, text);
                self.addThread(list, s.b, pos, text);
            },
            .assert_start => if (pos == 0) self.addThread(list, pc + 1, pos, text),
            .assert_end => if (pos == text.len) self.addThread(list, pc + 1, pos, text),
            .word_boundary => |want| {
                const left = if (pos > 0) isWordByte(text[pos - 1]) else false;
                const right = if (pos < text.len) isWordByte(text[pos]) else false;
                if ((left != right) == want) self.addThread(list, pc + 1, pos, text);
            },
            else => list.pcs.append(self.allocator, pc) catch {
                self.exhausted_flag = true;
            },
        }
    }
};

// ─── Parser ───

const Bounds = struct { min: u32, max: ?u32 };

const Parser = struct {
    arena: std.mem.Allocator,
    pattern: []const u8,
    pos: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(ClassSet) = .empty,
    case_insensitive: bool,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn add(self: *Parser, node: Node) Error!u32 {
        try self.nodes.append(self.arena, node);
        return @intCast(self.nodes.items.len - 1);
    }

    fn addClass(self: *Parser, set: ClassSet) Error!u32 {
        try self.classes.append(self.arena, set);
        return @intCast(self.classes.items.len - 1);
    }

    fn foldByte(self: *Parser, b: u8) u8 {
        return if (self.case_insensitive) std.ascii.toLower(b) else b;
    }

    fn parse(self: *Parser) Error!u32 {
        const root = try self.parseAlt();
        if (self.pos != self.pattern.len) return error.InvalidPattern; // stray ')'
        return root;
    }

    fn parseAlt(self: *Parser) Error!u32 {
        var branches: std.ArrayList(u32) = .empty;
        try branches.append(self.arena, try self.parseConcat());
        while (self.peek() == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.add(.{ .alt = try self.arena.dupe(u32, branches.items) });
    }

    fn parseConcat(self: *Parser) Error!u32 {
        var parts: std.ArrayList(u32) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.arena, try self.parseRepeat());
        }
        if (parts.items.len == 0) return self.add(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return self.add(.{ .concat = try self.arena.dupe(u32, parts.items) });
    }

    fn parseRepeat(self: *Parser) Error!u32 {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        switch (c) {
            '*' => {
                self.pos += 1;
                self.skipLazy();
                return self.add(.{ .star = atom });
            },
            '+' => {
                self.pos += 1;
                self.skipLazy();
                return self.add(.{ .plus = atom });
            },
            '?' => {
                self.pos += 1;
                self.skipLazy();
                return self.add(.{ .opt = atom });
            },
            '{' => {
                const save = self.pos;
                const bounds = try self.parseBraces() orelse {
                    self.pos = save; // not a quantifier — '{' is a literal
                    return atom;
                };
                self.skipLazy();
                return self.add(.{ .repeat = .{ .node = atom, .min = bounds.min, .max = bounds.max } });
            },
            else => return atom,
        }
    }

    /// Lazy markers (`*?`) are semantically irrelevant here: the caller only
    /// asks whether a match exists, and every quantifier alternative is
    /// explored anyway. Accept and drop so the agent can copy a PCRE habit.
    fn skipLazy(self: *Parser) void {
        if (self.peek() == '?') self.pos += 1;
    }

    fn parseBraces(self: *Parser) Error!?Bounds {
        var i = self.pos + 1; // past '{'
        const lo_start = i;
        while (i < self.pattern.len and std.ascii.isDigit(self.pattern[i])) i += 1;
        if (i == lo_start) return null;
        const min = std.fmt.parseInt(u32, self.pattern[lo_start..i], 10) catch return null;
        if (i < self.pattern.len and self.pattern[i] == '}') {
            self.pos = i + 1;
            return Bounds{ .min = min, .max = min };
        }
        if (i >= self.pattern.len or self.pattern[i] != ',') return null;
        i += 1;
        if (i < self.pattern.len and self.pattern[i] == '}') {
            self.pos = i + 1;
            return Bounds{ .min = min, .max = null };
        }
        const hi_start = i;
        while (i < self.pattern.len and std.ascii.isDigit(self.pattern[i])) i += 1;
        if (i == hi_start or i >= self.pattern.len or self.pattern[i] != '}') return null;
        const max = std.fmt.parseInt(u32, self.pattern[hi_start..i], 10) catch return null;
        if (max < min) return error.InvalidPattern;
        self.pos = i + 1;
        return Bounds{ .min = min, .max = max };
    }

    fn parseAtom(self: *Parser) Error!u32 {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '(' => {
                self.pos += 1;
                if (self.peek() == '?') {
                    self.pos += 1;
                    // `(?:` is the only supported extension; the rest
                    // (`(?=`, `(?!`, `(?<`, `(?i`) is an explicit error.
                    if (self.peek() != ':') return error.InvalidPattern;
                    self.pos += 1;
                }
                const inner = try self.parseAlt();
                if (self.peek() != ')') return error.InvalidPattern;
                self.pos += 1;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.add(.any);
            },
            '^' => {
                self.pos += 1;
                return self.add(.assert_start);
            },
            '$' => {
                self.pos += 1;
                return self.add(.assert_end);
            },
            '\\' => return self.parseEscape(),
            // A quantifier with nothing to repeat — Python and RE2 both reject.
            '*', '+', '?' => return error.InvalidPattern,
            else => {
                self.pos += 1;
                return self.add(.{ .literal = self.foldByte(c) });
            },
        }
    }

    fn parseEscape(self: *Parser) Error!u32 {
        self.pos += 1; // past '\'
        const c = self.peek() orelse return error.InvalidPattern;
        self.pos += 1;
        switch (c) {
            'd' => return self.addClassNode(&digitSet, false),
            'D' => return self.addClassNode(&digitSet, true),
            'w' => return self.addClassNode(&wordSet, false),
            'W' => return self.addClassNode(&wordSet, true),
            's' => return self.addClassNode(&spaceSet, false),
            'S' => return self.addClassNode(&spaceSet, true),
            'b' => return self.add(.{ .word_boundary = true }),
            'B' => return self.add(.{ .word_boundary = false }),
            'n' => return self.add(.{ .literal = '\n' }),
            't' => return self.add(.{ .literal = '\t' }),
            'r' => return self.add(.{ .literal = '\r' }),
            'f' => return self.add(.{ .literal = 0x0c }),
            'v' => return self.add(.{ .literal = 0x0b }),
            '0' => return self.add(.{ .literal = 0 }),
            else => {
                // Unknown alphabetic escapes (`\q`, `\A`, `\z`, `\G`, …) are an
                // explicit error, never a silently different literal.
                if (std.ascii.isAlphanumeric(c)) return error.InvalidPattern;
                return self.add(.{ .literal = self.foldByte(c) });
            },
        }
    }

    fn addClassNode(self: *Parser, base: *const ClassSet, negate: bool) Error!u32 {
        var set = base.*;
        if (self.case_insensitive) foldSet(&set);
        if (negate) negateSet(&set);
        const class_idx = try self.addClass(set);
        return self.add(.{ .class = class_idx });
    }

    fn parseClass(self: *Parser) Error!u32 {
        self.pos += 1; // past '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var set = [_]bool{false} ** 256;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern; // unterminated
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;

            // A `\d`-style class contributes its whole set and cannot start a range.
            if (c == '\\') {
                self.pos += 1;
                const e = self.peek() orelse return error.InvalidPattern;
                self.pos += 1;
                const whole: ?*const ClassSet = switch (e) {
                    'd' => &digitSet,
                    'w' => &wordSet,
                    's' => &spaceSet,
                    else => null,
                };
                if (whole) |base| {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (base[i]) set[i] = true;
                    }
                    continue;
                }
                const lo = try escapeChar(e);
                try self.classRange(&set, lo);
                continue;
            }

            self.pos += 1;
            try self.classRange(&set, c);
        }
        if (self.case_insensitive) foldSet(&set);
        if (negated) negateSet(&set);
        const class_idx = try self.addClass(set);
        return self.add(.{ .class = class_idx });
    }

    /// After a class element `lo`: consume `-hi` when a range is present.
    fn classRange(self: *Parser, set: *ClassSet, lo: u8) Error!void {
        if (self.peek() == '-') {
            const after = self.pos + 1;
            if (after < self.pattern.len and self.pattern[after] != ']') {
                self.pos += 1; // past '-'
                const c = self.peek() orelse return error.InvalidPattern;
                self.pos += 1;
                const hi = if (c == '\\') blk: {
                    const e = self.peek() orelse return error.InvalidPattern;
                    self.pos += 1;
                    break :blk try escapeChar(e);
                } else c;
                if (hi < lo) return error.InvalidPattern;
                var b: usize = lo;
                while (b <= hi) : (b += 1) set[b] = true;
                return;
            }
        }
        set[lo] = true;
    }

    fn escapeChar(e: u8) Error!u8 {
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            '0' => 0,
            'd', 'D', 'w', 'W', 's', 'S' => error.InvalidPattern, // handled by the caller
            else => if (std.ascii.isAlphanumeric(e) and e != 'd' and e != 'w' and e != 's') error.InvalidPattern else e,
        };
    }
};

const digitSet = blk: {
    var s = [_]bool{false} ** 256;
    for ('0'..'9' + 1) |c| s[c] = true;
    break :blk s;
};

const wordSet = blk: {
    var s = [_]bool{false} ** 256;
    for ('a'..'z' + 1) |c| s[c] = true;
    for ('A'..'Z' + 1) |c| s[c] = true;
    for ('0'..'9' + 1) |c| s[c] = true;
    s['_'] = true;
    break :blk s;
};

const spaceSet = blk: {
    var s = [_]bool{false} ** 256;
    for ([_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c }) |c| s[c] = true;
    break :blk s;
};

fn foldSet(set: *ClassSet) void {
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        if (!set[b]) continue;
        const ch: u8 = @intCast(b);
        if (std.ascii.isAscii(ch)) set[std.ascii.toLower(ch)] = true;
    }
}

fn negateSet(set: *ClassSet) void {
    var b: usize = 0;
    while (b < 256) : (b += 1) set[b] = !set[b];
}

// ─── Emitter (Thompson construction) ───

const Emitter = struct {
    allocator: std.mem.Allocator,
    nodes: []const Node,
    insts: std.ArrayList(Inst) = .empty,

    fn append(self: *Emitter, inst: Inst) Error!u32 {
        if (self.insts.items.len >= MAX_INSTRS) return error.PatternTooLong;
        try self.insts.append(self.allocator, inst);
        return @intCast(self.insts.items.len - 1);
    }

    fn here(self: *const Emitter) u32 {
        return @intCast(self.insts.items.len);
    }

    fn emit(self: *Emitter, index: u32) Error!void {
        switch (self.nodes[index]) {
            .empty => {},
            .literal => |b| _ = try self.append(.{ .char = b }),
            .any => _ = try self.append(.any),
            .class => |class_idx| _ = try self.append(.{ .class = class_idx }),
            .assert_start => _ = try self.append(.assert_start),
            .assert_end => _ = try self.append(.assert_end),
            .word_boundary => |want| _ = try self.append(.{ .word_boundary = want }),
            .concat => |parts| for (parts) |p| try self.emit(p),
            .alt => |branches| try self.emitAlt(branches),
            .star => |body| {
                // L: split(body, after); body; jmp L; after:
                const split_idx = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                const body_start = self.here();
                try self.emit(body);
                _ = try self.append(.{ .jmp = split_idx });
                self.insts.items[split_idx] = .{ .split = .{ .a = body_start, .b = self.here() } };
            },
            .plus => |body| {
                // body; split(body_start, after); after:
                const body_start = self.here();
                try self.emit(body);
                _ = try self.append(.{ .split = .{ .a = body_start, .b = self.here() + 1 } });
            },
            .opt => |body| {
                const split_idx = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                const body_start = self.here();
                try self.emit(body);
                self.insts.items[split_idx] = .{ .split = .{ .a = body_start, .b = self.here() } };
            },
            .repeat => |r| {
                var k: u32 = 0;
                while (k < r.min) : (k += 1) try self.emit(r.node);
                if (r.max) |max| {
                    // Sequential splits give `body (body …)?` — i.e. {min,max}.
                    var j: u32 = r.min;
                    while (j < max) : (j += 1) {
                        const split_idx = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                        const body_start = self.here();
                        try self.emit(r.node);
                        self.insts.items[split_idx] = .{ .split = .{ .a = body_start, .b = self.here() } };
                    }
                } else {
                    const split_idx = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
                    const body_start = self.here();
                    try self.emit(r.node);
                    _ = try self.append(.{ .jmp = split_idx });
                    self.insts.items[split_idx] = .{ .split = .{ .a = body_start, .b = self.here() } };
                }
            },
        }
    }

    fn emitAlt(self: *Emitter, branches: []const u32) Error!void {
        var end_jmps: std.ArrayList(u32) = .empty;
        defer end_jmps.deinit(self.allocator);

        for (branches, 0..) |branch, i| {
            if (i == branches.len - 1) {
                try self.emit(branch);
                break;
            }
            const split_idx = try self.append(.{ .split = .{ .a = 0, .b = 0 } });
            const body_start = self.here();
            try self.emit(branch);
            const jmp_idx = try self.append(.{ .jmp = 0 });
            try end_jmps.append(self.allocator, jmp_idx);
            self.insts.items[split_idx] = .{ .split = .{ .a = body_start, .b = self.here() } };
        }

        const end = self.here();
        for (end_jmps.items) |jmp_idx| self.insts.items[jmp_idx] = .{ .jmp = end };
    }
};

/// Compile `pattern`. The returned `Regex` owns its memory; call `deinit`.
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) Error!Regex {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = Parser{
        .arena = arena,
        .pattern = pattern,
        .case_insensitive = opts.case_insensitive,
    };
    const root = try parser.parse();

    var emitter = Emitter{ .allocator = allocator, .nodes = parser.nodes.items };
    errdefer emitter.insts.deinit(allocator);
    try emitter.emit(root);
    _ = try emitter.append(.match);

    const insts = try emitter.insts.toOwnedSlice(allocator);
    errdefer allocator.free(insts);

    const classes = try allocator.dupe(ClassSet, parser.classes.items);
    errdefer allocator.free(classes);

    const seen_a = try allocator.alloc(u32, insts.len);
    errdefer allocator.free(seen_a);
    const seen_b = try allocator.alloc(u32, insts.len);
    errdefer allocator.free(seen_b);
    @memset(seen_a, 0);
    @memset(seen_b, 0);

    return .{
        .allocator = allocator,
        .insts = insts,
        .classes = classes,
        .case_insensitive = opts.case_insensitive,
        .list_a = .{ .seen = seen_a, .gen = 0 },
        .list_b = .{ .seen = seen_b, .gen = 0 },
    };
}

/// Convenience for one-shot callers/tests: compile + single match.
pub fn matches(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, opts: Options) Error!bool {
    var re = try compile(allocator, pattern, opts);
    defer re.deinit();
    return re.isMatch(text);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const ci = Options{ .case_insensitive = true };
const cs = Options{ .case_insensitive = false };

fn pair(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    return matches(allocator, pattern, text, ci);
}

test "literal patterns behave as case-insensitive substring search" {
    try testing.expect(try pair(testing.allocator, "read", "read_file"));
    try testing.expect(try pair(testing.allocator, "READ_FILE", "read_file"));
    try testing.expect(!try pair(testing.allocator, "write", "read_file"));
    try testing.expect(try pair(testing.allocator, "read_file", "read_file (line numbers)"));
}

test "case_insensitive = false is case sensitive" {
    try testing.expect(try matches(testing.allocator, "Read", "Read_file", cs));
    try testing.expect(!try matches(testing.allocator, "read", "Read_file", cs));
}

test "dot matches any byte except newline" {
    try testing.expect(try pair(testing.allocator, "a.c", "abc"));
    try testing.expect(try pair(testing.allocator, "a.c", "a c"));
    try testing.expect(!try pair(testing.allocator, "a.c", "a\nc"));
}

test "star, plus and question" {
    try testing.expect(try pair(testing.allocator, "ab*c", "ac"));
    try testing.expect(try pair(testing.allocator, "ab*c", "abbbc"));
    try testing.expect(!try pair(testing.allocator, "ab+c", "ac"));
    try testing.expect(try pair(testing.allocator, "ab+c", "abc"));
    try testing.expect(try pair(testing.allocator, "ab?c", "ac"));
    try testing.expect(try pair(testing.allocator, "ab?c", "abc"));
    try testing.expect(!try pair(testing.allocator, "ab?c", "abbc"));
}

test "bounded repetition" {
    try testing.expect(!try pair(testing.allocator, "ab{2}c", "abc"));
    try testing.expect(try pair(testing.allocator, "ab{2}c", "abbc"));
    try testing.expect(try pair(testing.allocator, "ab{2,}c", "abbbbc"));
    try testing.expect(try pair(testing.allocator, "ab{1,3}c", "abbc"));
    try testing.expect(!try pair(testing.allocator, "ab{2,3}c", "abbbbc"));
    // Lazy markers are accepted and irrelevant to match existence.
    try testing.expect(try pair(testing.allocator, "ab+?c", "abbc"));
    try testing.expect(try pair(testing.allocator, "a{1,2}?", "aa"));
}

test "character classes, ranges and negation" {
    try testing.expect(try pair(testing.allocator, "[abc]d", "bd"));
    try testing.expect(!try pair(testing.allocator, "[abc]d", "ed"));
    try testing.expect(try pair(testing.allocator, "[a-c]d", "cd"));
    try testing.expect(!try pair(testing.allocator, "[a-c]d", "dd"));
    try testing.expect(try pair(testing.allocator, "[^abc]d", "zd"));
    try testing.expect(!try pair(testing.allocator, "[^abc]d", "ad"));
    // Case folding must not leak into the negated set ([^a] must reject "A").
    try testing.expect(!try pair(testing.allocator, "[^a]x", "Ax"));
    // A leading ']' is a literal member.
    try testing.expect(try pair(testing.allocator, "[]]x", "]x"));
    // Escapes inside a class.
    try testing.expect(try pair(testing.allocator, "[\\d_]x", "7x"));
    try testing.expect(try pair(testing.allocator, "[\\d_]x", "_x"));
    try testing.expect(!try pair(testing.allocator, "[\\d_]x", "ax"));
    try testing.expect(try pair(testing.allocator, "[\\w-]+", "snake_case-tool"));
}

test "shorthand classes outside a class" {
    try testing.expect(try pair(testing.allocator, "\\d\\d", "v12"));
    try testing.expect(!try pair(testing.allocator, "\\d", "abc"));
    try testing.expect(try pair(testing.allocator, "\\w+_tool", "search_tool"));
    try testing.expect(try pair(testing.allocator, "\\sX", "a X"));
    try testing.expect(try pair(testing.allocator, "\\W", "a-b"));
    try testing.expect(!try pair(testing.allocator, "\\W", "ab"));
    try testing.expect(try pair(testing.allocator, "\\S", "a b"));
}

test "word boundaries" {
    try testing.expect(try pair(testing.allocator, "\\bsearch\\b", "search the catalog"));
    try testing.expect(!try pair(testing.allocator, "\\bsearch\\b", "searcher"));
    try testing.expect(try pair(testing.allocator, "\\Bsearch", "research"));
    // '_' is a word byte, exactly like rg's -w and PCRE.
    try testing.expect(!try pair(testing.allocator, "\\bread\\b", "read_file"));
}

test "anchors" {
    try testing.expect(try pair(testing.allocator, "^mcp_", "mcp_ctx_query"));
    try testing.expect(!try pair(testing.allocator, "^mcp_", "get_mcp_ctx"));
    try testing.expect(try pair(testing.allocator, "_tool$", "search_tool"));
    try testing.expect(!try pair(testing.allocator, "_tool$", "search_tools"));
    try testing.expect(try pair(testing.allocator, "^.*_tool$", "search_tool"));
}

test "alternation and groups" {
    try testing.expect(try pair(testing.allocator, "doc|docs", "docs"));
    try testing.expect(try pair(testing.allocator, "doc|docs", "documentation"));
    try testing.expect(!try pair(testing.allocator, "(cat|dog)s", "dog"));
    try testing.expect(try pair(testing.allocator, "(cat|dog)s", "dogs"));
    try testing.expect(try pair(testing.allocator, "mcp_.*_create", "mcp_linear_create-issue"));
    try testing.expect(!try pair(testing.allocator, "^mcp_.*_create$", "mcp_linear_create-issue"));
    try testing.expect(try pair(testing.allocator, "(?:ab)+", "abab"));
    try testing.expect(try pair(testing.allocator, "memory.*(save|store)", "memory_store_fact"));
}

test "empty pattern matches everything; empty alternatives work" {
    try testing.expect(try pair(testing.allocator, "", "anything"));
    try testing.expect(try pair(testing.allocator, "a|", "zzz"));
    try testing.expect(try pair(testing.allocator, "(|a)b", "b"));
}

test "nested repetition over an empty-matching body terminates" {
    try testing.expect(try pair(testing.allocator, "(a*)*b", "aaab"));
    try testing.expect(try pair(testing.allocator, "(?:)*", "x"));
    try testing.expect(!try pair(testing.allocator, "(a*)*b", "aaac"));
}

test "invalid patterns are rejected, never reinterpreted" {
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "(", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "a)", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "[abc", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "[z-a]", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "\\", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "\\q", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "*abc", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "+abc", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "?abc", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "(?=abc)", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "(?<name>x)", "x", ci));
    try testing.expectError(error.InvalidPattern, matches(testing.allocator, "a{3,2}", "x", ci));
}

test "a malformed brace is a literal, not an error" {
    try testing.expect(try pair(testing.allocator, "a{", "xa{"));
    try testing.expect(try pair(testing.allocator, "a{x}", "a{x}"));
    try testing.expect(try pair(testing.allocator, "a{,3}", "a{,3}"));
}

test "quantifier expansion is capped instead of exploding" {
    try testing.expectError(error.PatternTooLong, matches(testing.allocator, "a{0,900}{0,900}", "x", ci));
    try testing.expectError(error.PatternTooLong, matches(testing.allocator, "(abcdefghij){0,400}", "x", ci));
}

test "escaped metacharacters are literal" {
    try testing.expect(try pair(testing.allocator, "\\.zig", "glob.zig"));
    try testing.expect(!try pair(testing.allocator, "\\.zig", "globxzig"));
    try testing.expect(try pair(testing.allocator, "\\(x\\)", "fn(x)"));
    try testing.expect(try pair(testing.allocator, "\\*", "*.zig"));
    try testing.expect(try pair(testing.allocator, "\\[\\]", "a[]"));
}

test "a pathological backtracking pattern stays linear" {
    // The classic catastrophic-backtracking shape: 30 a's + 'b'. A
    // backtracking engine blows up here; the NFA simulation must not.
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expect(!try pair(testing.allocator, "(a+)+b", text));
}

// ─── Oracle: expectations cross-checked against Python's `re` ─── Generated
// with Python 3 (`re.compile(pattern.encode())`, i.e.

const OracleCase = struct { pattern: []const u8, text: []const u8, want: bool };

const oracle_cases = [_]OracleCase{
    .{ .pattern = "read", .text = "read_file", .want = true },
    .{ .pattern = "read", .text = "write_file", .want = false },
    .{ .pattern = "^read", .text = "read_file", .want = true },
    .{ .pattern = "^read", .text = "thread_read", .want = false },
    .{ .pattern = "_file$", .text = "read_file", .want = true },
    .{ .pattern = "_file$", .text = "read_file_x", .want = false },
    .{ .pattern = "a.c", .text = "abc", .want = true },
    .{ .pattern = "a.c", .text = "a\nc", .want = false },
    .{ .pattern = "ab*c", .text = "ac", .want = true },
    .{ .pattern = "ab*c", .text = "abbbc", .want = true },
    .{ .pattern = "ab+c", .text = "ac", .want = false },
    .{ .pattern = "ab?c", .text = "abbc", .want = false },
    .{ .pattern = "ab{2,3}c", .text = "abbc", .want = true },
    .{ .pattern = "ab{2,3}c", .text = "abbbbc", .want = false },
    .{ .pattern = "ab{2,}c", .text = "abbbbbbc", .want = true },
    .{ .pattern = "[a-c]d", .text = "cd", .want = true },
    .{ .pattern = "[a-c]d", .text = "dd", .want = false },
    .{ .pattern = "[^a]x", .text = "ax", .want = false },
    .{ .pattern = "[^a]x", .text = "bx", .want = true },
    .{ .pattern = "[]]x", .text = "]x", .want = true },
    .{ .pattern = "[\\d_]x", .text = "7x", .want = true },
    .{ .pattern = "[\\d_]x", .text = "ax", .want = false },
    .{ .pattern = "\\d\\d", .text = "v12", .want = true },
    .{ .pattern = "\\d", .text = "abc", .want = false },
    .{ .pattern = "\\w+_tool", .text = "search_tool", .want = true },
    .{ .pattern = "\\sX", .text = "a X", .want = true },
    .{ .pattern = "\\W", .text = "ab", .want = false },
    .{ .pattern = "\\bsearch\\b", .text = "search the catalog", .want = true },
    .{ .pattern = "\\bsearch\\b", .text = "searcher", .want = false },
    .{ .pattern = "\\Bsearch", .text = "research", .want = true },
    .{ .pattern = "\\bread\\b", .text = "read_file", .want = false },
    .{ .pattern = "doc|docs", .text = "documentation", .want = true },
    .{ .pattern = "(cat|dog)s", .text = "dog", .want = false },
    .{ .pattern = "(cat|dog)s", .text = "dogs", .want = true },
    .{ .pattern = "mcp_.*_create", .text = "mcp_linear_create-issue", .want = true },
    .{ .pattern = "^mcp_.*_create$", .text = "mcp_linear_create-issue", .want = false },
    .{ .pattern = "(?:ab)+", .text = "abab", .want = true },
    .{ .pattern = "memory.*(save|store)", .text = "memory_store_fact", .want = true },
    .{ .pattern = "(a*)*b", .text = "aaac", .want = false },
    .{ .pattern = "(a*)*b", .text = "aaab", .want = true },
    .{ .pattern = "\\.zig", .text = "glob.zig", .want = true },
    .{ .pattern = "\\.zig", .text = "globxzig", .want = false },
    .{ .pattern = "\\(x\\)", .text = "fn(x)", .want = true },
    .{ .pattern = "\\*", .text = "*.zig", .want = true },
    .{ .pattern = "[\\w-]+", .text = "snake_case-tool", .want = true },
    .{ .pattern = "a|", .text = "zzz", .want = true },
    .{ .pattern = "(|a)b", .text = "b", .want = true },
    .{ .pattern = "x{0}", .text = "x", .want = true },
    .{ .pattern = "q{0,1}", .text = "abc", .want = true },
};

test "engine agrees with the Python re oracle on the supported subset" {
    for (oracle_cases) |case| {
        const got = matches(testing.allocator, case.pattern, case.text, cs) catch |err| {
            std.debug.print("oracle case failed to compile: {s} ({s})\n", .{ case.pattern, @errorName(err) });
            return err;
        };
        testing.expectEqual(case.want, got) catch |err| {
            std.debug.print("oracle mismatch: /{s}/ vs {s} → want {any}, got {any}\n", .{
                case.pattern, case.text, case.want, got,
            });
            return err;
        };
    }
}
