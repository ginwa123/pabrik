const std = @import("std");

pub const Key = union(enum) {
    /// A printable rune (Unicode scalar value).
    rune: u21,
    enter,
    tab,
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    /// SGR-encoded mouse wheel up (button 64). See the test block
    /// below for the wire shape.
    wheel_up,
    /// SGR-encoded mouse wheel down (button 65).
    wheel_down,
    ctrl_c,
    ctrl_d,
    ctrl_u,
    ctrl_w,
    ctrl_l,
};

/// Result of parsing one input chunk.
pub const ParseResult = struct {
    key: ?Key,
    len: usize,
};

pub fn parse(buf: []const u8) ParseResult {
    if (buf.len == 0) return .{ .key = null, .len = 0 };
    const b = buf[0];
    switch (b) {
        0x03 => return .{ .key = .ctrl_c, .len = 1 },
        0x04 => return .{ .key = .ctrl_d, .len = 1 },
        0x08, 0x7F => return .{ .key = .backspace, .len = 1 },
        0x09 => return .{ .key = .tab, .len = 1 },
        0x0A, 0x0D => return .{ .key = .enter, .len = 1 },
        0x0C => return .{ .key = .ctrl_l, .len = 1 },
        0x15 => return .{ .key = .ctrl_u, .len = 1 },
        0x17 => return .{ .key = .ctrl_w, .len = 1 },
        0x1B => {
            if (buf.len == 1) return .{ .key = .escape, .len = 1 };
            // CSI sequences: ESC [ <params> <final>
            if (buf[1] == '[') {
                // SGR mouse: ESC [ < button ; col ; row M (or m for release).
                // Distinguish from ordinary CSI by the '<' prefix character
                // and the final byte (M or m).
                if (buf.len > 2 and buf[2] == '<') {
                    var i: usize = 3;
                    while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == ';')) : (i += 1) {}
                    if (i >= buf.len) return .{ .key = null, .len = 0 }; // incomplete
                    const final = buf[i];
                    if (final != 'M' and final != 'm') return .{ .key = null, .len = i + 1 }; // not SGR mouse — consume to skip
                    const consumed = i + 1;
                    // Parse the button field (params[0]) — col/row are
                    // ignored in v1 (no click handling). button is the
                    // FIRST ';'-separated number after '<'.
                    const semicolon = std.mem.indexOfScalar(u8, buf[3..i], ';') orelse 0;
                    const button_str = buf[3 .. 3 + semicolon];
                    const button = std.fmt.parseInt(u16, button_str, 10) catch {
                        // Malformed button field — consume the bytes
                        // anyway so the dispatcher doesn't replay them
                        // as runes (the original bug).
                        return .{ .key = null, .len = consumed };
                    };
                    const k: ?Key = switch (button) {
                        64 => .wheel_up,
                        65 => .wheel_down,
                        else => null, // 0/1/2 = clicks, 27 = movement — ignore for v1
                    };
                    if (k) |key| return .{ .key = key, .len = consumed };
                    // Complete SGR mouse event but unhandled button.
                    return .{ .key = null, .len = consumed };
                }

                var i: usize = 2;
                while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == ';')) : (i += 1) {}
                if (i >= buf.len) return .{ .key = null, .len = 0 }; // incomplete — need more bytes
                const final = buf[i];
                const params = buf[2..i];
                const consumed = i + 1;
                const k: ?Key = switch (final) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    '~' => blk: {
                        if (params.len == 1 and std.ascii.isDigit(params[0])) {
                            switch (params[0]) {
                                '3' => break :blk .delete,
                                '5' => break :blk .page_up,
                                '6' => break :blk .page_down,
                                else => break :blk null,
                            }
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (k) |key| return .{ .key = key, .len = consumed };
                // Unknown CSI — swallow it so we don't loop forever.
                return .{ .key = .escape, .len = consumed };
            }
            // Unknown escape prefix (e.g. Alt-key) — consume ESC only.
            return .{ .key = .escape, .len = 1 };
        },
        else => {
            // UTF-8 rune. Determine sequence length from the lead byte.
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(b) catch {
                // Invalid lead byte — skip it.
                return .{ .key = .{ .rune = 0xFFFD }, .len = 1 };
            };
            if (buf.len < seq_len) return .{ .key = null, .len = 0 }; // incomplete
            const cp = std.unicode.utf8Decode(buf[0..seq_len]) catch {
                return .{ .key = .{ .rune = 0xFFFD }, .len = seq_len };
            };
            return .{ .key = .{ .rune = cp }, .len = seq_len };
        },
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parse: ascii runes" {
    const r = parse("a");
    try testing.expectEqual(Key{ .rune = 'a' }, r.key.?);
    try testing.expectEqual(@as(usize, 1), r.len);

    const z = parse("Z");
    try testing.expectEqual(Key{ .rune = 'Z' }, z.key.?);

    const five = parse("5");
    try testing.expectEqual(Key{ .rune = '5' }, five.key.?);
}

test "parse: backspace variants" {
    try testing.expectEqual(Key.backspace, (parse(&.{0x7F})).key.?);
    try testing.expectEqual(Key.backspace, (parse(&.{0x08})).key.?);
}

test "parse: ctrl-c" {
    try testing.expectEqual(Key.ctrl_c, (parse(&.{0x03})).key.?);
}

test "parse: tab / enter / ctrl-l" {
    try testing.expectEqual(Key.tab, (parse(&.{0x09})).key.?);
    try testing.expectEqual(Key.enter, (parse(&.{0x0A})).key.?);
    try testing.expectEqual(Key.enter, (parse(&.{0x0D})).key.?);
    try testing.expectEqual(Key.ctrl_l, (parse(&.{0x0C})).key.?);
}

test "parse: utf-8 multi-byte (€ = E2 82 AC)" {
    const r = parse("\xe2\x82\xac");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(u21, 0x20AC), r.key.?.rune);
}

test "parse: bare escape" {
    try testing.expectEqual(Key.escape, (parse("\x1b")).key.?);
}

test "parse: arrow keys" {
    try testing.expectEqual(Key.up, (parse("\x1b[A")).key.?);
    try testing.expectEqual(Key.down, (parse("\x1b[B")).key.?);
    try testing.expectEqual(Key.right, (parse("\x1b[C")).key.?);
    try testing.expectEqual(Key.left, (parse("\x1b[D")).key.?);
}

test "parse: incomplete escape returns len=0 (not nil)" {
    // Round-3 fix: an incomplete sequence now reports key=null, len=0 so the
    // dispatcher knows to KEEP the bytes for the next read rather than
    // dropping them (which would let residual bytes leak into the input
    const r = parse("\x1b[");
    try testing.expect(r.key == null);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "parse: home/end/delete/page keys" {
    try testing.expectEqual(Key.home, (parse("\x1b[H")).key.?);
    try testing.expectEqual(Key.end, (parse("\x1b[F")).key.?);
    try testing.expectEqual(Key.delete, (parse("\x1b[3~")).key.?);
    try testing.expectEqual(Key.page_up, (parse("\x1b[5~")).key.?);
    try testing.expectEqual(Key.page_down, (parse("\x1b[6~")).key.?);
}

// ----------------------------------------------------------------------------
// SGR mouse wheel (round-2 — Task 5)
// ----------------------------------------------------------------------------

test "parse: SGR mouse wheel up = button 64" {
    const got = parse("\x1b[<64;12;8M");
    try testing.expectEqual(Key.wheel_up, got.key.?);
    try testing.expectEqual(@as(usize, 11), got.len);
}

test "parse: SGR mouse wheel down = button 65" {
    const got = parse("\x1b[<65;12;8M");
    try testing.expectEqual(Key.wheel_down, got.key.?);
}

test "parse: complete SGR mouse movement (button 27) reports key=null, len=consumed" {
    // Round-3 fix: this is the sequence that previously broke scroll. The
    // bytes must be CONSUMED (so the dispatcher advances past them) but the
    // key is null (no scroll).
    const got = parse("\x1b[<27;14;14M");
    try testing.expect(got.key == null);
    try testing.expectEqual(@as(usize, 12), got.len);
}

test "parse: complete SGR click (button 0) reports key=null, len=consumed" {
    const got = parse("\x1b[<0;10;5M");
    try testing.expect(got.key == null);
    try testing.expectEqual(@as(usize, 10), got.len);
}

test "parse: complete SGR release (button 0, lowercase m) reports key=null, len=consumed" {
    const got = parse("\x1b[<0;10;5m");
    try testing.expect(got.key == null);
    try testing.expectEqual(@as(usize, 10), got.len);
}

test "parse: incomplete SGR sequence (no M/m) reports key=null, len=0" {
    // \x1b[<64 with no terminating M — caller MUST wait for more.
    const got = parse("\x1b[<64");
    try testing.expect(got.key == null);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "parse: malformed SGR button field still consumes the bytes" {
    // Button field has no digits (just semicolons) — parseInt fails.
    // Previously returned null and dropped the bytes; now we still
    // consume them so the dispatcher advances.
    const got = parse("\x1b[<;14;14M");
    try testing.expect(got.key == null);
    try testing.expectEqual(@as(usize, 10), got.len);
}