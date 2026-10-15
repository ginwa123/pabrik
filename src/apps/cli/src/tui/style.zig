//! ANSI SGR (Select Graphic Rendition) style helpers. Every helper returns a
//! NEW heap-allocated string with the escape codes wrapped around `text`.

const std = @import("std");
const color = @import("color.zig");

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    fg: ?color.Color = null,
    bg: ?color.Color = null,

    /// Compose the full SGR prefix for this style, e.g. `\x1b[1;31m`.
    /// Writes into `buf` (must be ≥ 16 bytes) and returns the written
    /// prefix slice.
    pub fn sgrPrefix(self: Style, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        _ = &w;
        const w0 = &w;
        w0.writeAll("\x1b[") catch return "";
        var first = true;
        if (self.bold) {
            w0.writeAll("1") catch return "";
            first = false;
        }
        if (self.dim) {
            if (!first) w0.writeAll(";") catch return "";
            w0.writeAll("2") catch return "";
            first = false;
        }
        if (self.fg) |fgc| {
            if (!first) w0.writeAll(";") catch return "";
            w0.print("{d}", .{fgc.fgCode()}) catch return "";
            first = false;
        }
        if (self.bg) |bgc| {
            if (!first) w0.writeAll(";") catch return "";
            w0.print("{d}", .{bgc.bgCode()}) catch return "";
        }
        w0.writeAll("m") catch return "";
        return w0.buffered();
    }

    /// Wrap `text` in this style's SGR codes + reset. Caller owns.
    pub fn render(self: Style, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var prefix_buf: [32]u8 = undefined;
        const prefix = self.sgrPrefix(&prefix_buf);
        return std.fmt.allocPrint(allocator, "{s}{s}\x1b[0m", .{ prefix, text });
    }
};

/// Convenience: bold text. Caller owns the returned slice.
pub fn bold(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return (Style{ .bold = true }).render(allocator, text);
}

/// Convenience: dim text. Caller owns the returned slice.
pub fn dim(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return (Style{ .dim = true }).render(allocator, text);
}

/// Convenience: colored foreground text. Caller owns the slice.
pub fn fg(allocator: std.mem.Allocator, c: color.Color, text: []const u8) ![]u8 {
    return (Style{ .fg = c }).render(allocator, text);
}

/// Convenience: background-colored text. Caller owns the slice.
pub fn bg(allocator: std.mem.Allocator, c: color.Color, text: []const u8) ![]u8 {
    return (Style{ .bg = c }).render(allocator, text);
}

/// The reset sequence, as a compile-time constant.
pub const reset = "\x1b[0m";

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "Style: bold renders 1m + reset" {
    const out = try bold(testing.allocator, "hi");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[1mhi\x1b[0m", out);
}

test "Style: dim renders 2m + reset" {
    const out = try dim(testing.allocator, "hi");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[2mhi\x1b[0m", out);
}

test "Style: fg red renders 31m + reset" {
    const out = try fg(testing.allocator, .red, "alert");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[31malert\x1b[0m", out);
}

test "Style: bg blue renders 44m + reset" {
    const out = try bg(testing.allocator, .blue, "hi");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[44mhi\x1b[0m", out);
}

test "Style: combined bold+red composes with semicolons" {
    const s = Style{ .bold = true, .fg = .green };
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[1;32m", s.sgrPrefix(&buf));
}

test "Style: empty style renders bare SGR close + reset" {
    const s = Style{};
    const out = try s.render(testing.allocator, "x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[mx\x1b[0m", out);
}
