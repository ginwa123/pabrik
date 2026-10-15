//! 16-color ANSI palette. Maps each named color to its SGR foreground code
//! (30–37 for normal, 90–97 for bright). Background codes are foreground +
//! 10.

pub const Color = enum(u8) {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    brightBlack,
    brightRed,
    brightGreen,
    brightYellow,
    brightBlue,
    brightMagenta,
    brightCyan,
    brightWhite,

    /// SGR parameter for using this color as a FOREGROUND (30–37 / 90–97).
    pub fn fgCode(self: Color) u8 {
        const v = @intFromEnum(self);
        return if (v < 8) 30 + v else 90 + (v - 8);
    }

    /// SGR parameter for using this color as a BACKGROUND (40–47 / 100–107).
    pub fn bgCode(self: Color) u8 {
        return self.fgCode() + 10;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "Color: normal fg codes start at 30" {
    try testing.expectEqual(@as(u8, 30), Color.black.fgCode());
    try testing.expectEqual(@as(u8, 31), Color.red.fgCode());
    try testing.expectEqual(@as(u8, 37), Color.white.fgCode());
}

test "Color: bright fg codes start at 90" {
    try testing.expectEqual(@as(u8, 90), Color.brightBlack.fgCode());
    try testing.expectEqual(@as(u8, 97), Color.brightWhite.fgCode());
}

test "Color: bg codes are fg + 10" {
    try testing.expectEqual(@as(u8, 40), Color.black.bgCode());
    try testing.expectEqual(@as(u8, 44), Color.blue.bgCode());
    try testing.expectEqual(@as(u8, 107), Color.brightWhite.bgCode());
}
