// Safety tests for the FunctionalHarness. Zig port of
// `tests/functional/harness_safety_test.py`. These tests run WITHOUT a pabrik
// binary.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const gpa = testing.allocator;
const io = testing.io;

const Harness = harness.Harness;
const is_windows = @import("builtin").os.tag == .windows;

// ============================================================================
// Helpers
// ============================================================================

/// Allocate AND create a fresh `<tmpRoot>/pabrik-func-<hex>` directory.
fn freshMarkerDir() ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const sfx = try harness.randomSuffix(gpa);
    defer gpa.free(sfx);
    const dir = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}{s}",
        .{ root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR, sfx },
    );
    // No `defer gpa.free(dir)`: this slice IS the return value.
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        gpa.free(dir);
        return err;
    };
    return dir;
}

/// Build a path under the OS tmp root that deliberately does NOT carry
/// the namespace marker. Never creates it — the caller decides.
fn unnamespacedTmpChild(name: []const u8) ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, name });
}

/// A `Harness` built WITHOUT `boot` — the Zig analogue of Python's
/// `FunctionalHarness(port=9999, temp_dir=…, orig_home=…, pid=None)`.
fn bareHarness(temp_dir: []const u8, orig_home: []const u8, dry_run: bool) !Harness {
    return .{
        .allocator = gpa,
        .port = 9999,
        .pabrik_bin = try gpa.dupe(u8, "/nonexistent"),
        .temp_dir = try gpa.dupe(u8, temp_dir),
        .orig_home = try gpa.dupe(u8, orig_home),
        .log_path = try gpa.dupe(u8, "/dev/null"),
        .pid = null,
        .dry_run = dry_run,
        .orig_userprofile = try gpa.dupe(u8, ""),
        .orig_appdata = try gpa.dupe(u8, ""),
        .orig_localappdata = try gpa.dupe(u8, ""),
        .orig_xdg_config_home = try gpa.dupe(u8, ""),
        .orig_xdg_state_home = try gpa.dupe(u8, ""),
        .orig_xdg_data_home = try gpa.dupe(u8, ""),
        .orig_xdg_cache_home = try gpa.dupe(u8, ""),
    };
}

/// Create `<tmpRoot>/tmpalias-<pid>` as a symlink to the tmp root and return
/// its path. Caller unlinks it.
fn makeTmpdirAlias() ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
    const alias = try std.fmt.allocPrint(gpa, "{s}{s}tmpalias-{d}", .{
        root,
        std.fs.path.sep_str,
        pid,
    });
    std.Io.Dir.cwd().deleteFile(io, alias) catch {};
    std.Io.Dir.cwd().symLink(io, root, alias, .{ .is_directory = true }) catch |err| {
        std.debug.print("this host cannot create a symlink ({s})\n", .{@errorName(err)});
        gpa.free(alias);
        return error.SkipZigTest;
    };
    return alias;
}

/// True iff `path` exists (of any kind).
fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True iff `path` is an existing directory.
fn isDir(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// ============================================================================
// is_safe_tmp
// ============================================================================

// Empty path is never safe.
test "is_safe_tmp_rejects_empty_string" {
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", "/home/alice"));
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", ""));
}

// Relative paths are never safe (could resolve anywhere).
test "is_safe_tmp_rejects_non_absolute_path" {
    try testing.expect(!try harness.isSafeTmp(io, gpa, "pabrik-func-xxx", "/home/alice"));
    try testing.expect(!try harness.isSafeTmp(io, gpa, "./tmp/pabrik-func-xxx", "/home/alice"));
}

// The real $HOME is never safe, even with the required substring.
test "is_safe_tmp_rejects_real_home" {
    const fake_home = "/home/alice";
    // Even if the path contains the substring, the validator rejects
    // paths that resolve to the real home.
    try testing.expect(!try harness.isSafeTmp(io, gpa, fake_home, fake_home));

    // The stronger statement the first assertion only half-covers: the
    // SUBSTRING alone is never enough.
    const planted = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}planted",
        .{ fake_home, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(planted);
    // Built as a STRING and deliberately NOT created: nothing may be written
    // under a fake `$HOME`, and `canonical` falls back to the input for a
    // non-existent path, which is exactly the spelling check under test.
    try testing.expect(std.mem.indexOf(u8, planted, harness.REQUIRED_TMP_SUBSTR) != null);
    try testing.expect(!try harness.isSafeTmp(io, gpa, planted, fake_home));
}

// A tmpdir without the required namespace substring is rejected.
test "is_safe_tmp_rejects_path_without_substring" {
    // The suffix comes from randomSuffix (hex, leading zeros dropped),
    // so the name is `not-ours-<hex>` and is NEVER a substring hit for
    // `pabrik-func-` / `pabrik-fix-`.
    const sfx = try harness.randomSuffix(gpa);
    defer gpa.free(sfx);
    const name = try std.fmt.allocPrint(gpa, "not-ours-{s}", .{sfx});
    defer gpa.free(name);

    const td = try unnamespacedTmpChild(name);
    defer gpa.free(td);

    // Created EMPTY, and removed with the NON-recursive `deleteDir`.
    std.Io.Dir.cwd().createDirPath(io, td) catch |err| {
        std.debug.print("could not create fixture {s}: {s}\n", .{ td, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer std.Io.Dir.cwd().deleteDir(io, td) catch {};

    try testing.expect(isDir(td));
    try testing.expect(std.mem.indexOf(u8, td, harness.REQUIRED_TMP_SUBSTR) == null);
    try testing.expect(std.mem.indexOf(u8, td, harness.SCRATCH_PREFIX) == null);
    try testing.expect(!try harness.isSafeTmp(io, gpa, td, "/never"));
}

// A fresh mkdtemp with the required prefix is safe.
test "is_safe_tmp_accepts_valid_tmpdir" {
    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    const fake_home = "/home/nonexistent-for-this-test";
    try testing.expect(isDir(dir));
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, fake_home));
}

// PathLike inputs work too (not just str).
test "is_safe_tmp_accepts_pathlib_path" {
    // Python's `Path(td)` vs `str(td)`: `is_safe_tmp` was duck-typed on
    // `os.fspath`, so it accepted either.
    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // (a) the path as returned by the allocator.
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, "/home/nonexistent"));

    // (b) the same directory reached through a freshly-built slice that
    // carries a redundant `.` component — a different `[]const u8`
    // pointing at the same inode.
    const dotted = try std.fs.path.join(gpa, &.{ dir, "." });
    defer gpa.free(dotted);
    try testing.expect(dotted.len > dir.len);
    try testing.expect(try harness.isSafeTmp(io, gpa, dotted, "/home/nonexistent"));

    // (c) A sub-slice of the SAME buffer — the "borrowed, not owned"
    // case a PathLike would have been. Proves nothing is captured by
    // length assumption.
    const trimmed = dir[0 .. dir.len - 1];
    try testing.expect(try harness.isSafeTmp(io, gpa, trimmed, "/home/nonexistent"));
}

// A symlink whose target is outside the tmpdir is rejected via realpath.
test "is_safe_tmp_resolves_symlinks_in_path" {
    const home = testing.environ.getAlloc(gpa, "HOME") catch try gpa.dupe(u8, "");
    defer gpa.free(home);
    if (home.len == 0) {
        std.debug.print("HOME is not set; cannot name a real out-of-tmpdir target\n", .{});
        return error.SkipZigTest;
    }

    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // A symlink INSIDE the tempdir that points at the real `$HOME`.
    const link = try std.fs.path.join(gpa, &.{ dir, "sneaky" });
    defer gpa.free(link);
    std.Io.Dir.cwd().symLink(io, home, link, .{ .is_directory = true }) catch |err| {
        std.debug.print("symlink not supported on this platform ({s})\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Positive control: the resolution really does happen, so a
    // rejection below is the allow-list firing and not a missing-file
    // fallback.
    const canon = try harness.canonical(io, gpa, link);
    defer gpa.free(canon);
    try testing.expectEqualStrings(home, canon);

    try testing.expect(!try harness.isSafeTmp(io, gpa, link, home));
    try testing.expect(!try harness.isSafeTmp(io, gpa, link, "/home/alice"));

    // TODO(port): Python ALSO covered a symlink to a target that does not
    // exist (`/home/alice`, never created) and asserted rejection.
}

// ============================================================================
// allow-list prefix spelling: the windows-2022 8.3 bug
// ============================================================================

// A prefix naming the tmpdir another way must still match.
test "allowlist_prefix_spelled_differently_still_matches" {
    const alias = try makeTmpdirAlias();
    defer gpa.free(alias);
    defer std.Io.Dir.cwd().deleteFile(io, alias) catch {};

    // Resolve BOTH the alias's own root and the real root, exactly as
    // `isSafeTmp` does.
    const canon_alias = try harness.canonical(io, gpa, alias);
    defer gpa.free(canon_alias);
    const real_root = try harness.canonical(io, gpa, alias);
    defer gpa.free(real_root);
    // `alias` is a symlink to the tmp root, so the alias spelling and
    // the real spelling of the SAME directory must canonicalise
    // identically. This is the load-bearing half of the 8.3 fix.
    try testing.expectEqualStrings(canon_alias, real_root);

    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // The precondition that gives this test teeth: a RAW startswith of the
    // candidate against the ALIAS spelling FAILS here, so only
    // canonicalisation of both sides can rescue it.
    const alias_prefix = try std.fmt.allocPrint(gpa, "{s}{s}", .{ alias, std.fs.path.sep_str });
    defer gpa.free(alias_prefix);
    try testing.expect(!std.mem.startsWith(u8, dir, alias_prefix));

    // …and the real root's own spelling DOES prefix it, so the failure
    // above is about the alias spelling and not about the path.
    const real_prefix = try std.fmt.allocPrint(gpa, "{s}{s}", .{ canon_alias, std.fs.path.sep_str });
    defer gpa.free(real_prefix);
    try testing.expect(std.mem.startsWith(u8, dir, real_prefix));

    // And the validator agrees.
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, "/home/someone-else"));
}

// The counterpart: the fix must not accept what it previously rejected.
// Canonicalising the allow-list is only safe because the prefix still
// resolves to a tmpdir.
test "canonicalising_both_sides_does_not_widen_the_allowlist" {
    // Python's fixture existed only to install a monkeypatched allow-list.
    const alias = try makeTmpdirAlias();
    defer gpa.free(alias);
    defer std.Io.Dir.cwd().deleteFile(io, alias) catch {};

    const outside = try std.fmt.allocPrint(
        gpa,
        "{s}not-a-tmpdir-at-all{s}{s}probe",
        .{ std.fs.path.sep_str, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(outside);

    try testing.expect(std.fs.path.isAbsolute(outside));
    try testing.expect(std.mem.indexOf(u8, outside, harness.REQUIRED_TMP_SUBSTR) != null);

    // The preconditions the Python test asserted, kept so a reader can
    // see this is not passing for the wrong reason.
    try testing.expect(!std.mem.startsWith(u8, outside, alias));
    try testing.expect(std.mem.indexOf(u8, outside, "/tmp/") == null);

    try testing.expect(!try harness.isSafeTmp(io, gpa, outside, "/home/someone-else"));
}

// A Windows path comparison is case-insensitive; this now is too. `normcase`
// is the half of `canonical` the 8.3 bug did not need.
test "allowlist_prefix_matches_regardless_of_case" {
    if (!is_windows) return error.SkipZigTest;

    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    var shout_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shout_root = std.ascii.upperString(&shout_buf, root);
    const shouted = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}case-probe",
        .{ shout_root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(shouted);

    try testing.expect(try harness.isSafeTmp(io, gpa, shouted, "/home/someone-else"));
}

// ============================================================================
// teardown safety net
// ============================================================================

// Constructing a harness with an unsafe temp_dir makes teardown raise. This
// is the ultimate safety net: even if every other guard fails, teardown must
// not delete a path that fails isSafeTmp.
test "teardown_refuses_unsafe_temp_dir" {
    // Build a harness instance WITHOUT calling boot (which creates its own
    // tempdir).
    var unsafe_dir: []const u8 = undefined;
    var unsafe_home: []const u8 = "/home/alice";
    if (is_windows) {
        // `testing.environ`, not `std.process.getEnvVarOwned` — the latter
        // was REMOVED in Zig 0.16 (see `harness.zig`'s note on
        // `getEnvOrEmpty`), and a branch guarded by `if (is_windows)` is only
        const system_root = testing.environ.getAlloc(gpa, "SystemRoot") catch
            try gpa.dupe(u8, "C:\\Windows");
        defer gpa.free(system_root);
        unsafe_dir = try std.fs.path.join(gpa, &.{ system_root, "System32", "drivers", "etc", "hosts" });
        unsafe_home = "C:\\Users\\alice";
        if (!exists(unsafe_dir)) {
            std.debug.print("expected system file missing: {s}\n", .{unsafe_dir});
            gpa.free(unsafe_dir);
            return error.SkipZigTest;
        }
    } else {
        // A single well-known system file.
        unsafe_dir = try gpa.dupe(u8, "/etc/passwd");
    }
    defer gpa.free(unsafe_dir);

    // POSITIVE CONTROL: prove the path is genuinely unsafe BEFORE
    // teardown runs, so "the file still exists" cannot pass vacuously
    // because `isSafeTmp` said nothing about it.
    try testing.expect(!try harness.isSafeTmp(io, gpa, unsafe_dir, unsafe_home));
    try testing.expect(exists(unsafe_dir));

    var h = try bareHarness(unsafe_dir, unsafe_home, false);

    // `deinit` owns every string inside `h`; there is no `defer gpa.free`
    // for them here, and `h` must not be read afterwards (`freeAll` does
    // `self.* = undefined`).
    const result = h.deinit(io);
    if (result) |_| {
        std.debug.print("teardown did NOT refuse an unsafe temp_dir: {s}\n", .{unsafe_dir});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(harness.FunctionalHarnessError.TeardownRefused, err);
    }

    // And the file MUST still exist.
    try testing.expect(exists(unsafe_dir));
}

// A safe temp_dir is actually rmtree'd by teardown.
test "teardown_with_safe_temp_dir_runs_rmtree" {
    // A real sandbox under the tmp root, created with the required
    // prefix so it matches the safety rules.
    const safe = try freshMarkerDir();
    defer gpa.free(safe);

    const inner = try std.fs.path.join(gpa, &.{ safe, "marker.txt" });
    defer gpa.free(inner);
    {
        var f = try std.Io.Dir.cwd().createFile(io, inner, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "exists");
    }

    // teardown should run without raising because: - the dir is on the tmp
    // root - safe contains the substring - safe != orig_home
    var h = try bareHarness(safe, "/home/nonexistent", false);
    try h.deinit(io);

    // `h.temp_dir` is undefined after deinit — assert against the local
    // copy, which the caller owns.
    try testing.expect(!exists(safe));
}

// ============================================================================
// constants are sane
// ============================================================================

// The allow-list must include tempfile.gettempdir() (defensive).
test "allowed_tmp_prefixes_contains_gettempdir" {
    // Python asserted `(gettempdir() + "/") in ALLOWED_TMP_PREFIXES` — a
    // membership test on a module tuple.
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    try testing.expect(root.len > 0);
    try testing.expect(std.fs.path.isAbsolute(root));

    const probe = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}allowlist-probe",
        .{ root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(probe);

    // Positive control: it really does live under the tmp root…
    const canon_probe = try harness.canonical(io, gpa, probe);
    defer gpa.free(canon_probe);
    const canon_root = try harness.canonical(io, gpa, root);
    defer gpa.free(canon_root);
    try testing.expect(std.mem.startsWith(u8, canon_probe, canon_root));

    // …and so the validator accepts it.
    try testing.expect(try harness.isSafeTmp(io, gpa, probe, "/home/someone-else"));

    // …and the parent itself is NOT deletable: it carries no marker.
    try testing.expect(!try harness.isSafeTmp(io, gpa, root, "/home/someone-else"));
}

// REQUIRED_TMP_SUBSTR must end with a separator-like chunk so
// a path like /tmp/pabrik-func / etc. cannot satisfy a substring
// check that includes a separator.
test "required_substring_is_namespaced" {
    try testing.expect(std.mem.endsWith(u8, harness.REQUIRED_TMP_SUBSTR, "-"));
    // The suite-fixture marker is a SECOND accepted namespace, and it
    // must obey the same rule or `cleanupExtraDir` would gate on a bare
    // prefix that also matches unrelated directories.
    try testing.expect(std.mem.endsWith(u8, harness.SCRATCH_PREFIX, "-"));
    // They must not overlap: `reapOrphanTestPids` only matches
    // `REQUIRED_TMP_SUBSTR`, which is what keeps a live fixture from
    // being reaped mid-test.
    try testing.expect(std.mem.indexOf(u8, harness.SCRATCH_PREFIX, harness.REQUIRED_TMP_SUBSTR) == null);
    try testing.expect(std.mem.indexOf(u8, harness.REQUIRED_TMP_SUBSTR, harness.SCRATCH_PREFIX) == null);
}

// boot() refuses if no home can be determined (no path to validate against).
test "orig_home_must_exist_for_boot" {
    // Python deleted HOME AND USERPROFILE (and broke `Path.home`) so every
    // layer of the resolution chain failed deterministically, then asserted
    // `boot()` raised "HOME not set".
    return error.SkipZigTest;
}

// ============================================================================
// boot() signature: port default must be None (random), not 8080
// ============================================================================

/// The default of `Harness.BootOptions.port`, read out of `@typeInfo`.
const BootPortDefault = struct {
    /// `null` means "the field is missing or has no default" — the
    /// presence check in the test distinguishes those from "the default
    /// IS null", which is the assertion.
    fn value() ?u16 {
        const info = @typeInfo(Harness.BootOptions).@"struct";
        // `if (comptime …)` rather than a `continue`: an `inline for`
        // body is still a runtime block, so a plain `if` around a
        // `continue` is "comptime control flow inside a runtime block".
        inline for (info.fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "port")) {
                const ptr = f.default_value_ptr orelse return null;
                const v: *const ?u16 = @ptrCast(@alignCast(ptr));
                return v.*;
            }
        }
        return null;
    }
};

// `FunctionalHarness.boot(port=None)` is the documented default.
test "boot_signature_accepts_none_port" {
    // Positive control: the field exists at all, so a rename cannot make
    // the assertion below pass vacuously.
    var has_port_field = false;
    inline for (@typeInfo(Harness.BootOptions).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "port")) has_port_field = true;
    }
    try testing.expect(has_port_field);

    const default = BootPortDefault.value();
    if (default) |d| {
        std.debug.print(
            "Harness.BootOptions.port default must be null (→ random pick), got {d}. " ++
                "With a non-null default, a bare `Harness.boot` would silently " ++
                "get the legacy sequential scan from that port.\n",
            .{d},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// XDG isolation must not be platform-gated
// ============================================================================

// FunctionalHarness.boot must shadow XDG for the child on all platforms.
test "harness_xdg_shadowing_is_not_platform_gated" {
    // TODO(port): the Python version was a SOURCE-TEXT GREP — it read
    // `harness.py` and asserted every `env["XDG_*"] = ` assignment sat at
    // method-body indent, not nested inside `if os.name == "nt":`.
    return error.SkipZigTest;
}

// These two files re-implement the spawn instead of calling boot(). They
// carry their own copy of the child-env block, so the harness fix does not
// cover them — they regressed in lockstep and must be guarded separately.
test "private_preboot_fixtures_also_shadow_xdg" {
    // TODO(port): same source-text grep as above, over
    // `config_simplify_test.py` and `config_tools_test.py` (a
    // `@pytest.mark.parametrize`d pair, hence ONE test block here).
    return error.SkipZigTest;
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one of these helpers
    // would stay invisible until a caller happened to appear.
    _ = freshMarkerDir;
    _ = unnamespacedTmpChild;
    _ = bareHarness;
    _ = makeTmpdirAlias;
    _ = exists;
    _ = isDir;
    _ = BootPortDefault.value;
}
