//! What a rule is: an id, an options fingerprint, and the check itself.
//! The engine owns the walk, the ordering and the report, and runs the rules
//! listed in `zginlint.rules`; a rule reads the `Options` field it owns.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const options_mod = @import("options.zig");

pub const Diagnostic = diagnostic.Diagnostic;
pub const Options = options_mod.Options;

pub const Rule = struct {
    /// ESLint-shaped id, e.g. `zginlint/max-comment-lines`.
    id: []const u8,
    /// The options this rule was read with, as a short string (`max=3`, or
    /// `-` for a rule with none). A pin records it and refuses a check whose
    /// fingerprint differs, so a pin can never be compared under other rules.
    fingerprint: *const fn (allocator: std.mem.Allocator, options: Options) anyerror![]u8,
    /// Append one diagnostic per finding in `source`.
    check: *const fn (
        allocator: std.mem.Allocator,
        source: []const u8,
        options: Options,
        out: *std.ArrayList(Diagnostic),
    ) anyerror!void,
};

/// The fingerprint of a rule that has no options.
pub const no_options = "-";
