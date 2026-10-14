//! ansi.zig — remove terminal escape sequences from captured process output.
//! Plenty of real toolchains colour their diagnostics even when stdout is a
//! pipe rather than a TTY.

const std = @import("std");

/// The C0 control that introduces every ECMA-48 escape sequence.
const ESC: u8 = 0x1B;
/// Bell — the legacy terminator for OSC / DCS payloads.
const BEL: u8 = 0x07;

/// Strip ANSI/ECMA-48 escape sequences from `s`. Returns an owned slice; the
/// caller must free it. Input without an `ESC` byte is copied verbatim
/// (including its length), so the result never aliases the argument.
pub fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Fast path — the overwhelming majority of captured output has no
    // escapes at all (git, gh, most build tools on POSIX).
    if (std.mem.indexOfScalar(u8, s, ESC) == null) return allocator.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != ESC) {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        }

        i += 1; // consume the ESC itself
        if (i >= s.len) break; // trailing lone ESC — nothing follows it

        switch (s[i]) {
            // CSI: ESC '[' parameters/intermediates, ended by one byte in
            // 0x40..0x7E.
            '[' => {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7E)) i += 1;
                if (i < s.len) i += 1; // consume the final byte
            },

            // OSC: ESC ']' payload, ended by BEL or ST (ESC '\').
            ']' => i = skipStringPayload(s, i + 1),

            // DCS / SOS / PM / APC — same ST-or-BEL termination.
            'P', 'X', '^', '_' => i = skipStringPayload(s, i + 1),

            // Everything else is a two-character escape, optionally with
            // intermediate bytes in 0x20..0x2F before the final byte (charset
            // designation `ESC ( B`, DECALN `ESC # 8`, RIS `ESC c`, keypad
            0x20...0x2F, 0x30...0x3F => {
                // Only an intermediate byte (0x20..0x2F) means another
                // byte follows; `ESC =` is complete at `=` and must not
                // swallow the first character of the payload.
                const has_intermediates = s[i] >= 0x20 and s[i] <= 0x2F;
                i += 1; // the byte immediately after ESC
                if (has_intermediates) {
                    while (i < s.len and s[i] >= 0x20 and s[i] <= 0x2F) i += 1;
                    if (i < s.len) i += 1; // the final byte
                }
            },

            // A bare ESC followed by anything else: both bytes go.
            else => i += 1,
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Resume index just past an OSC/DCS-style string payload starting at
/// `start`.
fn skipStringPayload(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        if (s[i] == BEL) return i + 1;
        if (s[i] == ESC and i + 1 < s.len and s[i + 1] == '\\') return i + 2;
        i += 1;
    }
    return s.len;
}

// ─── Tests
// ────────────────────────────────────────────────────────────────── These
// assert BEHAVIOUR on real byte sequences (the exact shapes MSBuild,

const testing = std.testing;

test "stripAnsi: MSBuild warning colour codes vanish, the words survive" {
    // Byte-for-byte what `dotnet build` piped through `Select-String`
    // hands back: reverse-video "warning", bold "MSB", then reset.
    const input =
        "targets(4919,5): \x1b[7mwarning \x1b[0m\x1b[1mMSB\x1b[0m3026: Could not copy the file";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "targets(4919,5): warning MSB3026: Could not copy the file",
        out,
    );
}

test "stripAnsi: no ESC remains anywhere in the output" {
    // The shape of the bug report: a log whose every colour code turned
    // into a U+FFFD run. After stripping, not one ESC may survive.
    const input =
        "\x1b[7mwarning \x1b[0m\x1b[1mMSB\x1b[0m3026: \x1b[0m\x1b[7m\x1b[0mCould \x1b[0m";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOfScalar(u8, out, 0x1B) == null);
    try testing.expect(std.mem.indexOf(u8, out, "[7m") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[0m") == null);
}

test "stripAnsi: erase-screen and cursor sequences are removed" {
    const input = "\x1b[2J\x1b[HBuilding...\x1b[1;1HDone";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Building...Done", out);
}

test "stripAnsi: private-mode sequences (ESC[?25l) are removed" {
    // `ESC[?` — the '?' is a parameter byte (0x3F), below the 0x40
    // terminator, so a naive "stop at '[' or 'm'" scan leaves `?25l`
    // behind. That is the classic half-stripped tail.
    const input = "\x1b[?25lhidden\x1b[?25h";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hidden", out);
}

test "stripAnsi: OSC window title is removed through its ST terminator" {
    const input = "\x1b]0;my title\x07visible\x1b]7;file:///tmp\x1b\\tail";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("visibletail", out);
}

test "stripAnsi: two-byte and intermediate escapes are removed" {
    // Charset designation `ESC ( B`, DECALN `ESC # 8`, RIS `ESC c`,
    // keypad application mode `ESC =` — all leave no residue, and none
    // of them eats the first character of the payload that follows.
    const input = "\x1b(B\x1b#8\x1bc\x1b=ok";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ok", out);
}

test "stripAnsi: a lone trailing ESC is dropped, not emitted" {
    const input = "text\x1b";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("text", out);
}

test "stripAnsi: an unterminated sequence eats the rest, never leaks a fragment" {
    // Truncated capture mid-sequence (the cap in run_shell_command cuts
    // at max_output bytes). Whatever survives must not start with '['.
    const input = "good\x1b[7m";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("good", out);
}

test "stripAnsi: text with no escapes comes back byte-identical" {
    const input = "Build succeeded.\n    0 Warning(s)\n    0 Error(s)\n";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(input, out);
}

test "stripAnsi: a real UTF-8 payload passes through untouched" {
    // Stripping must not corrupt multi-byte UTF-8 — a build log with a
    // path like C:\\Users\\gilang is exactly the case that regressed
    // into mojibake before ANSI handling existed at all.
    const input = "\x1b[32m✓ C:\\Users\\gilang\\proyek — 3 done\x1b[0m";
    const out = try stripAnsi(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("✓ C:\\Users\\gilang\\proyek — 3 done", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}
