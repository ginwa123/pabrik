//! Path validation for agent tools whose `path` argument is chosen by the
//! LLM.

const std = @import("std");
const builtin = @import("builtin");

/// Both path separators, on every platform. A model may send either, and
/// `std.fs` on Windows accepts both, so a validator that only knows `\`
/// would let `/`-style names through on POSIX and vice versa.
pub fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// DOS device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9), with or without
/// extension. As a path component they open a device via NtCreateFile —
/// never something the delete tool should touch.
fn isReservedDosName(seg: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, seg, '.')) |idx| seg[0..idx] else seg;
    if (stem.len < 3 or stem.len > 4) return false;
    // Drive prefix `C:` has no dot and len 2 — excluded by the length check.
    var upper: [4]u8 = undefined;
    for (stem, 0..) |c, k| upper[k] = std.ascii.toUpper(c);
    const s = upper[0..stem.len];
    if (std.mem.eql(u8, s, "CON") or std.mem.eql(u8, s, "PRN") or
        std.mem.eql(u8, s, "AUX") or std.mem.eql(u8, s, "NUL")) return true;
    if (s.len == 4 and (std.mem.eql(u8, s[0..3], "COM") or std.mem.eql(u8, s[0..3], "LPT")) and
        s[3] >= '1' and s[3] <= '9') return true;
    return false;
}

/// The ONE rule every path-taking agent tool applies to a model-supplied
/// `cwd`.
pub const CwdError = error{ MandatoryCwdMissing, CwdNotAbsolute, CwdInvalid };

pub fn validateCwd(cwd: []const u8) CwdError!void {
    if (cwd.len == 0) return error.MandatoryCwdMissing;
    // Absolute-ness is checked BEFORE the name shape: on Windows
    // `invalidPathReason` also rejects a relative-looking name, and reporting
    // that as "contains an invalid character" would send the model looking
    if (!std.fs.path.isAbsolute(cwd)) return error.CwdNotAbsolute;
    // A `cwd` reaches `std.fs` / `spawn` exactly like `path` does, so it
    // needs the same Windows NT-status guard.
    if (invalidPathReason(cwd) != null) return error.CwdInvalid;
}

/// Resolve a model-supplied path against the `cwd` the same call supplied. A
/// relative `path` joins onto `cwd`; an absolute `path` is used as-is, so an
/// agent that already knows the full path is never forced to rewrite it.
pub fn resolveAgainstCwd(allocator: std.mem.Allocator, cwd: []const u8, raw: []const u8) ![]u8 {
    if (raw.len == 0 or std.mem.eql(u8, raw, ".")) return allocator.dupe(u8, cwd);
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    return std.fs.path.join(allocator, &.{ cwd, raw });
}

/// Windows NTSTATUS panic guard for a model-supplied path. std's Threaded Io
/// backend maps OBJECT_NAME_INVALID / INVALID_PARAMETER /
/// OBJECT_PATH_SYNTAX_BAD to ntstatusBug(), which PANICS and kills pabrik.exe
pub fn invalidPathReason(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 32767) return "path too long";
    for (path) |c| {
        if (c == 0) return "path contains NUL byte";
        if (c < 0x20) return "path contains control character";
    }
    if (builtin.os.tag != .windows) return null;
    // Unix-style `/foo`, bare names, and drive-relative `C:foo` all reach
    // NtQueryAttributesFile as malformed NT names -> process panic.
    if (!std.fs.path.isAbsoluteWindows(path)) {
        return "path must be an absolute Windows path (e.g. C:\\dir\\file)";
    }
    // Extended-length prefix `\\?\` / `\\.\` skips Win32 normalization;
    // remember it so the drive-colon check below stays correct.
    var rest: []const u8 = path;
    if (rest.len > 4 and (std.mem.startsWith(u8, rest, "\\\\?\\") or std.mem.startsWith(u8, rest, "\\\\.\\"))) {
        rest = rest[4..];
    }
    // Wildcards / reserved chars are never valid in NT names.
    for (rest) |c| {
        switch (c) {
            '*', '?', '<', '>', '|', '"' => return "path contains invalid character",
            else => {},
        }
    }
    // Colon is only legal as a drive prefix (`X:`); anything else is an
    // ADS suffix (`file:stream`) or garbage -> OBJECT_NAME_INVALID.
    for (rest, 0..) |c, i| {
        if (c != ':') continue;
        const ok_drive = i == 1 and std.ascii.isAlphabetic(rest[0]);
        if (!ok_drive) return "path contains invalid character";
    }
    // UNC paths need at least `\\server\share`; a bare `\\server` is not a
    // complete name for the NT syscalls below.
    var body: []const u8 = rest;
    if (body.len >= 2 and isSep(body[0]) and isSep(body[1])) {
        body = body[2..];
        if (body.len == 0) return "incomplete UNC path";
        var segs: usize = 0;
        var k: usize = 0;
        var seg_start: usize = 0;
        while (k <= body.len) : (k += 1) {
            const at_end = k == body.len;
            if (!at_end and !isSep(body[k])) continue;
            if (k - seg_start > 0) segs += 1;
            seg_start = k + 1;
        }
        if (segs < 2) return "incomplete UNC path";
    }
    // Per-segment checks: no empty segments (`C:\foo\\bar`), no `..`
    // (root escape: `C:\foo\..` resolves to the drive root), no trailing
    // dots/spaces, no reserved device names (they open devices, not files).
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and !isSep(body[i])) continue;
        const seg = body[seg_start..i];
        const is_first = seg_start == 0;
        if (seg.len == 0) {
            // Only the leading rooted `\` separator and the trailing
            // separator (stripped by stripTrailingSeps before FS calls)
            // may be empty. (`\\` UNC lead was consumed above.)
            if (!is_first and !at_end) return "path contains empty segment";
        } else {
            if (std.mem.eql(u8, seg, "..")) return "path must not contain ..";
            if (at_end and std.mem.eql(u8, seg, ".")) return "path must not end with .";
            if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') {
                return "path segment ends with dot or space";
            }
            if (isReservedDosName(seg)) return "path uses reserved device name";
        }
        seg_start = i + 1;
    }
    return null;
}
