const std = @import("std");

/// Forge provider for an attached pull/merge request. `github` covers
/// github.com AND GitHub Enterprise (custom domains) — the tool caller passes
/// the explicit override when host sniffing cannot tell.
pub const PrProvider = enum {
    github,
    gitlab,
    generic,

    pub fn toString(self: PrProvider) []const u8 {
        return switch (self) {
            .github => "github",
            .gitlab => "gitlab",
            .generic => "generic",
        };
    }

    pub fn fromString(s: []const u8) ?PrProvider {
        if (std.mem.eql(u8, s, "github")) return .github;
        if (std.mem.eql(u8, s, "gitlab")) return .gitlab;
        if (std.mem.eql(u8, s, "generic")) return .generic;
        return null;
    }
};

/// Parsed PR reference. `number` is the pull number (GitHub) or MR iid
/// (GitLab); null for `generic` (no number to parse).
pub const PrRef = struct {
    provider: PrProvider,
    repo_path: []const u8,
    number: ?[]const u8,
};

/// Normalize a PR/MR URL for persistence.
pub fn normalizePrUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const trimmed: []const u8 = std.mem.trim(u8, url, " \t\r\n");

    // Strip credentials: scheme://creds@rest → scheme://rest.
    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_end| {
        const after_scheme = trimmed[scheme_end + 3 ..];
        if (std.mem.indexOfScalar(u8, after_scheme, '@')) |at| {
            // Only treat as credentials when the '@' comes before the
            // first '/' (i.e. inside the authority, not the path).
            const slash = std.mem.indexOfScalar(u8, after_scheme, '/');
            if (slash == null or at < slash.?) {
                const stripped = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ trimmed[0..scheme_end], after_scheme[at + 1 ..] });
                // `stripped` is owned ([]u8); normalizeTail may shorten
                // it in place and either returns or frees it.
                return normalizeTail(allocator, stripped);
            }
        }
    }
    const duped = try allocator.dupe(u8, trimmed);
    return normalizeTail(allocator, duped);
}

fn normalizeTail(allocator: std.mem.Allocator, owned: []u8) ![]u8 {
    var len = owned.len;
    while (len > 0 and owned[len - 1] == '/') len -= 1;
    // Strip forge UI tails ("/files", "/commits[/<sha>]", "/checks",
    // "/diffs") — but ONLY after a PR marker, so a repo literally named
    // "files" is never mangled. Keeps just the number/IID segment.
    const markers = [_][]const u8{ "/pull/", "/-/merge_requests/", "/merge_requests/" };
    for (markers) |m| {
        const at = std.mem.indexOf(u8, owned[0..len], m) orelse continue;
        const tail = owned[at + m.len .. len];
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse continue;
        len = at + m.len + slash;
        break;
    }
    while (len > 0 and owned[len - 1] == '/') len -= 1;
    // Drop a trailing ".git" (defensive; PR URLs rarely carry it).
    if (len > 4 and std.mem.endsWith(u8, owned[0..len], ".git")) len -= 4;
    if (len == owned.len) return owned;
    defer allocator.free(owned);
    return try allocator.dupe(u8, owned[0..len]);
}

/// Split a normalized URL into scheme/host/path. Returns null when
/// there is no `://` or no host. Slices borrow from the input.
fn splitUrl(url: []const u8) ?struct { scheme: []const u8, host: []const u8, path: []const u8 } {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const after = url[scheme_end + 3 ..];
    if (after.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const host = after[0..slash];
    if (host.len == 0) return null;
    const path = if (slash < after.len) after[slash..] else "/";
    return .{ .scheme = url[0..scheme_end], .host = host, .path = path };
}

/// Auto-detect the provider from a (normalized) URL.
pub fn detectProvider(url: []const u8) PrProvider {
    const parts = splitUrl(url) orelse return .generic;
    // Lowercase the host into a stack buffer for substring matching.
    var host_buf: [256]u8 = undefined;
    const host_len = @min(parts.host.len, host_buf.len);
    for (parts.host[0..host_len], 0..) |c, i| host_buf[i] = std.ascii.toLower(c);
    const host = host_buf[0..host_len];
    if (std.mem.indexOf(u8, host, "github") != null) return .github;
    if (std.mem.indexOf(u8, host, "gitlab") != null) return .gitlab;
    if (std.mem.indexOf(u8, parts.path, "/-/merge_requests/") != null) return .gitlab;
    if (std.mem.indexOf(u8, parts.path, "/merge_requests/") != null) return .gitlab;
    if (std.mem.indexOf(u8, parts.path, "/pull/") != null) return .github;
    return .generic;
}

/// Longest host we will lowercase in a stack buffer. Real hosts are far
/// shorter; anything past this is a malformed remote, not a forge.
const MAX_SNIFF_HOST = 256;

/// Provider implied by a bare host string, by name only. No allocation
/// and no path knowledge, so it is safe to call on a host slice taken
/// straight out of a remote string.
fn providerFromHost(host: []const u8) PrProvider {
    if (host.len == 0) return .generic;
    var host_buf: [MAX_SNIFF_HOST]u8 = undefined;
    const n = @min(host.len, host_buf.len);
    for (host[0..n], 0..) |c, i| host_buf[i] = std.ascii.toLower(c);
    const lowered = host_buf[0..n];
    // GitHub first, matching `detectProvider`'s precedence.
    if (std.mem.indexOf(u8, lowered, "github") != null) return .github;
    if (std.mem.indexOf(u8, lowered, "gitlab") != null) return .gitlab;
    return .generic;
}

/// Detect the provider from a `git remote get-url` value.
pub fn detectProviderFromRemote(remote: []const u8) PrProvider {
    const trimmed = std.mem.trim(u8, remote, " \t\r\n");
    if (trimmed.len == 0) return .generic;

    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_end| {
        // `https://host/path` — the host is bounded by the next slash.
        const after = trimmed[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const by_host = providerFromHost(after[0..slash]);
        if (by_host != .generic) return by_host;
        // A scheme-less host name can still be identified by the path.
        if (std.mem.indexOf(u8, trimmed, "/-/merge_requests/") != null) return .gitlab;
        return .generic;
    }

    // scp-like: [user@]host:path
    const after_user = if (std.mem.indexOfScalar(u8, trimmed, '@')) |at| trimmed[at + 1 ..] else trimmed;
    const colon = std.mem.indexOfScalar(u8, after_user, ':') orelse return .generic;
    const by_host = providerFromHost(after_user[0..colon]);
    if (by_host != .generic) return by_host;
    if (std.mem.indexOf(u8, trimmed, "/-/merge_requests/") != null) return .gitlab;
    return .generic;
}

/// Parse owner/repo + number out of a normalized URL for the given
/// provider. Returns null when the shape does not match (the caller
/// surfaces a validation error). Slices borrow from `url`.
pub fn parsePrRef(url: []const u8, provider: PrProvider) ?PrRef {
    const parts = splitUrl(url) orelse return null;
    switch (provider) {
        .github => {
            // /owner/repo/pull/N
            const marker = "/pull/";
            const at = std.mem.indexOf(u8, parts.path, marker) orelse return null;
            const repo_path = std.mem.trim(u8, parts.path[0..at], "/");
            if (repo_path.len == 0) return null;
            if (std.mem.indexOfScalar(u8, repo_path, '/') == null) return null; // need owner/repo
            const num = std.mem.trim(u8, parts.path[at + marker.len ..], "/");
            if (num.len == 0) return null;
            for (num) |c| {
                if (c < '0' or c > '9') return null;
            }
            return .{ .provider = .github, .repo_path = repo_path, .number = num };
        },
        .gitlab => {
            // /[groups/.../]repo/-/merge_requests/IID
            const marker = "/-/merge_requests/";
            const at = std.mem.indexOf(u8, parts.path, marker) orelse return null;
            const repo_path = std.mem.trim(u8, parts.path[0..at], "/");
            if (repo_path.len == 0) return null;
            const num = std.mem.trim(u8, parts.path[at + marker.len ..], "/");
            if (num.len == 0) return null;
            for (num) |c| {
                if (c < '0' or c > '9') return null;
            }
            return .{ .provider = .gitlab, .repo_path = repo_path, .number = num };
        },
        .generic => {
            return .{ .provider = .generic, .repo_path = "", .number = null };
        },
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "normalizePrUrl strips credentials, slashes and UI suffixes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "https://github.com/acme/app/pull/42", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "  https://github.com/acme/app/pull/42/  ", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "https://user:tok123@github.com/acme/app/pull/42", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "https://github.com/acme/app/pull/42/files", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "https://github.com/acme/app/pull/42/commits", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "https://github.com/acme/app/pull/42/commits/abc123def", .out = "https://github.com/acme/app/pull/42" },
        .{ .in = "https://gitlab.com/g/r/-/merge_requests/7/diffs", .out = "https://gitlab.com/g/r/-/merge_requests/7" },
        .{ .in = "https://git.corp.example.com/files/app/pull/9/files", .out = "https://git.corp.example.com/files/app/pull/9" },
        .{ .in = "https://gitlab.com/g/sub/repo/-/merge_requests/7", .out = "https://gitlab.com/g/sub/repo/-/merge_requests/7" },
    };
    for (cases) |c| {
        const got = try normalizePrUrl(alloc, c.in);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "detectProvider sniffs github, gitlab, generic" {
    try std.testing.expectEqual(PrProvider.github, detectProvider("https://github.com/a/b/pull/1"));
    try std.testing.expectEqual(PrProvider.github, detectProvider("https://ghe.corp.example.com/a/b/pull/1"));
    try std.testing.expectEqual(PrProvider.gitlab, detectProvider("https://gitlab.com/a/b/-/merge_requests/2"));
    try std.testing.expectEqual(PrProvider.gitlab, detectProvider("https://git.corp.example.com/g/sub/r/-/merge_requests/3"));
    try std.testing.expectEqual(PrProvider.generic, detectProvider("https://git.corp.example.com/a/b/changes/9"));
    try std.testing.expectEqual(PrProvider.generic, detectProvider("not a url"));
}

test "detectProviderFromRemote sniffs both https and scp-like remotes" {
    // The scp-like rows are the point of this helper: a GitLab repo
    // cloned over SSH has no `://`, so `detectProvider` alone would
    // report every SSH remote as `generic`.
    const cases = [_]struct { in: []const u8, out: PrProvider }{
        .{ .in = "https://github.com/acme/app.git", .out = .github },
        .{ .in = "https://gitlab.com/group/sub/repo.git", .out = .gitlab },
        .{ .in = "git@github.com:acme/app.git", .out = .github },
        .{ .in = "git@gitlab.com:group/sub/repo.git", .out = .gitlab },
        .{ .in = "  git@gitlab.com:group/repo.git\n", .out = .gitlab },
        .{ .in = "ssh://git@gitlab.com/group/repo.git", .out = .gitlab },
        // A host with no forge name in it and no MR marker is still
        // generic — the caller passes an explicit override there.
        .{ .in = "git@git.corp.example.com:group/repo.git", .out = .generic },
        .{ .in = "", .out = .generic },
        .{ .in = "not a remote", .out = .generic },
    };
    for (cases) |c| try std.testing.expectEqual(c.out, detectProviderFromRemote(c.in));
}

test "parsePrRef extracts github owner/repo/number" {
    const r = parsePrRef("https://github.com/acme/app/pull/42", .github) orelse return error.RefMissing;
    try std.testing.expectEqualStrings("acme/app", r.repo_path);
    try std.testing.expectEqualStrings("42", r.number.?);
    try std.testing.expect(parsePrRef("https://github.com/acme/app/pull/abc", .github) == null);
    try std.testing.expect(parsePrRef("https://github.com/acme/app/issues/1", .github) == null);
}

test "parsePrRef extracts gitlab namespaced path + iid" {
    const r = parsePrRef("https://git.corp.example.com/g/sub/repo/-/merge_requests/99", .gitlab) orelse return error.RefMissing;
    try std.testing.expectEqualStrings("g/sub/repo", r.repo_path);
    try std.testing.expectEqualStrings("99", r.number.?);
    try std.testing.expect(parsePrRef("https://gitlab.com/a/b/-/merge_requests/x", .gitlab) == null);
}

test "PrProvider fromString round-trips" {
    try std.testing.expectEqual(PrProvider.github, PrProvider.fromString("github").?);
    try std.testing.expectEqual(PrProvider.gitlab, PrProvider.fromString("gitlab").?);
    try std.testing.expectEqual(PrProvider.generic, PrProvider.fromString("generic").?);
    try std.testing.expect(PrProvider.fromString("bitbucket") == null);
    try std.testing.expectEqualStrings("github", PrProvider.github.toString());
}

test "detectProviderFromRemote survives a remote longer than PATH_MAX" {
    // Two bugs in one test.
    const padding = "a" ** 8192;
    const cases = [_]struct { in: []const u8, out: PrProvider }{
        .{
            .in = "https://gitlab.com/group/sub/repo.git?" ++ padding,
            .out = .gitlab,
        },
        .{
            .in = "git@github.com:acme/app.git?" ++ padding,
            .out = .github,
        },
        .{
            .in = "https://git.corp.example.com/g/s/r/-/merge_requests/3?" ++ padding,
            .out = .gitlab,
        },
    };
    for (cases) |c| try std.testing.expectEqual(c.out, detectProviderFromRemote(c.in));
}

test "detectProviderFromRemote keeps path-marker detection for scheme remotes" {
    // A self-hosted GitLab on a host with no forge name in it is only
    // identifiable from the MR path marker.
    try std.testing.expectEqual(
        PrProvider.gitlab,
        detectProviderFromRemote("https://git.corp.example.com/g/s/r/-/merge_requests/3.git"),
    );
    try std.testing.expectEqual(
        PrProvider.generic,
        detectProviderFromRemote("https://git.corp.example.com/g/s/r.git"),
    );
}
