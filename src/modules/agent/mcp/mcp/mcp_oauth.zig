const std = @import("std");

pub const Error = error{
    InvalidUrl,
    InvalidMetadata,
    InvalidTokenResponse,
    OutOfMemory,
};

pub const BearerChallenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    error_description: ?[]const u8 = null,

    pub fn deinit(self: *const BearerChallenge, allocator: std.mem.Allocator) void {
        if (self.resource_metadata) |v| allocator.free(v);
        if (self.scope) |v| allocator.free(v);
        if (self.error_code) |v| allocator.free(v);
        if (self.error_description) |v| allocator.free(v);
    }
};

const Param = struct { name: []const u8, value: []const u8 };

const ParamList = struct {
    items: std.ArrayList(Param) = .empty,
    end: usize = 0,

    fn deinit(self: *ParamList, allocator: std.mem.Allocator) void {
        for (self.items.items) |p| {
            allocator.free(p.name);
            allocator.free(p.value);
        }
        self.items.deinit(allocator);
    }

    fn get(self: *const ParamList, name: []const u8) ?[]const u8 {
        for (self.items.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) return p.value;
        }
        return null;
    }
};

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn parseAuthParams(allocator: std.mem.Allocator, s: []const u8, start: usize) !ParamList {
    var out = ParamList{};
    errdefer out.deinit(allocator);
    var i = start;
    while (true) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == ',')) i += 1;
        if (i >= s.len) {
            out.end = i;
            return out;
        }
        const name_start = i;
        while (i < s.len and isTokenChar(s[i])) i += 1;
        if (i == name_start) {
            out.end = i;
            return out;
        }
        const name = s[name_start..i];
        var j = i;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
        if (j >= s.len or s[j] != '=') {
            out.end = name_start;
            return out;
        }
        j += 1;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;

        var value: []const u8 = undefined;
        if (j < s.len and s[j] == '"') {
            j += 1;
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            while (j < s.len and s[j] != '"') {
                if (s[j] == '\\' and j + 1 < s.len) j += 1;
                try buf.append(allocator, s[j]);
                j += 1;
            }
            if (j < s.len) j += 1;
            value = try buf.toOwnedSlice(allocator);
        } else {
            const v_start = j;
            while (j < s.len and isTokenChar(s[j])) j += 1;
            value = try allocator.dupe(u8, s[v_start..j]);
        }
        errdefer allocator.free(value);
        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        try out.items.append(allocator, .{ .name = name_dup, .value = value });
        i = j;
    }
}

pub fn parseBearerChallenge(allocator: std.mem.Allocator, header: []const u8) !?BearerChallenge {
    var i: usize = 0;
    while (i < header.len) {
        while (i < header.len and (header[i] == ' ' or header[i] == '\t' or header[i] == ',')) i += 1;
        if (i >= header.len) break;
        const scheme_start = i;
        while (i < header.len and isTokenChar(header[i])) i += 1;
        if (i == scheme_start) {
            i += 1;
            continue;
        }
        const scheme = header[scheme_start..i];
        var params = try parseAuthParams(allocator, header, i);
        if (std.ascii.eqlIgnoreCase(scheme, "Bearer")) {
            var out = BearerChallenge{};
            errdefer out.deinit(allocator);
            if (params.get("resource_metadata")) |v| out.resource_metadata = try allocator.dupe(u8, v);
            if (params.get("scope")) |v| out.scope = try allocator.dupe(u8, v);
            if (params.get("error")) |v| out.error_code = try allocator.dupe(u8, v);
            if (params.get("error_description")) |v| out.error_description = try allocator.dupe(u8, v);
            params.deinit(allocator);
            return out;
        }
        i = params.end;
        params.deinit(allocator);
    }
    return null;
}

pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: ?[]const u8,
};

pub fn parseUrl(s: []const u8) Error!Url {
    const sep = std.mem.indexOf(u8, s, "://") orelse return error.InvalidUrl;
    const scheme = s[0..sep];
    if (scheme.len == 0) return error.InvalidUrl;
    var rest = s[sep + 3 ..];

    var authority_end = rest.len;
    for (rest, 0..) |c, idx| {
        if (c == '/' or c == '?' or c == '#') {
            authority_end = idx;
            break;
        }
    }
    const authority = rest[0..authority_end];
    rest = rest[authority_end..];
    if (authority.len == 0) return error.InvalidUrl;

    var host: []const u8 = authority;
    var port: ?u16 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len and authority[close + 1] == ':') {
            port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (host.len == 0) return error.InvalidUrl;

    var path: []const u8 = "";
    var query: ?[]const u8 = null;
    if (rest.len > 0 and rest[0] == '/') {
        var path_end = rest.len;
        for (rest, 0..) |c, idx| {
            if (c == '?' or c == '#') {
                path_end = idx;
                break;
            }
        }
        path = rest[0..path_end];
        rest = rest[path_end..];
    }
    if (rest.len > 0 and rest[0] == '?') {
        var q_end = rest.len;
        for (rest, 0..) |c, idx| {
            if (c == '#') {
                q_end = idx;
                break;
            }
        }
        query = rest[1..q_end];
    }
    return .{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query };
}

pub fn origin(allocator: std.mem.Allocator, url: Url) ![]u8 {
    if (url.port) |p| {
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ url.scheme, url.host, p });
    }
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ url.scheme, url.host });
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

pub fn protectedResourceMetadataUrl(allocator: std.mem.Allocator, resource_url: []const u8) ![]u8 {
    const u = try parseUrl(resource_url);
    const o = try origin(allocator, u);
    defer allocator.free(o);
    const path = trimTrailingSlash(u.path);
    return std.fmt.allocPrint(allocator, "{s}/.well-known/oauth-protected-resource{s}", .{ o, path });
}

pub fn authorizationServerMetadataUrls(allocator: std.mem.Allocator, issuer: []const u8) ![][]const u8 {
    const u = try parseUrl(issuer);
    const o = try origin(allocator, u);
    defer allocator.free(o);
    const path = trimTrailingSlash(u.path);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.well-known/oauth-authorization-server{s}", .{ o, path }));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.well-known/openid-configuration{s}", .{ o, path }));
    if (path.len > 0) {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}/.well-known/openid-configuration", .{ o, path }));
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub fn percentEncode(allocator: std.mem.Allocator, s: []const u8, space_as_plus: bool) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else if (c == ' ' and space_as_plus) {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const AuthorizationRequest = struct {
    authorization_endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
    scope: []const u8 = "",
    resource: []const u8 = "",
};

fn appendQueryParam(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sep: *u8,
    name: []const u8,
    value: []const u8,
) !void {
    try out.append(allocator, sep.*);
    sep.* = '&';
    try out.appendSlice(allocator, name);
    try out.append(allocator, '=');
    const enc = try percentEncode(allocator, value, false);
    defer allocator.free(enc);
    try out.appendSlice(allocator, enc);
}

pub fn buildAuthorizationUrl(allocator: std.mem.Allocator, req: AuthorizationRequest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, req.authorization_endpoint);
    var sep: u8 = if (std.mem.indexOfScalar(u8, req.authorization_endpoint, '?') != null) '&' else '?';
    try appendQueryParam(allocator, &out, &sep, "response_type", "code");
    try appendQueryParam(allocator, &out, &sep, "client_id", req.client_id);
    try appendQueryParam(allocator, &out, &sep, "redirect_uri", req.redirect_uri);
    try appendQueryParam(allocator, &out, &sep, "code_challenge", req.code_challenge);
    try appendQueryParam(allocator, &out, &sep, "code_challenge_method", "S256");
    try appendQueryParam(allocator, &out, &sep, "state", req.state);
    if (req.scope.len > 0) try appendQueryParam(allocator, &out, &sep, "scope", req.scope);
    if (req.resource.len > 0) try appendQueryParam(allocator, &out, &sep, "resource", req.resource);
    return out.toOwnedSlice(allocator);
}

pub const TokenRequest = struct {
    grant_type: []const u8,
    code: []const u8 = "",
    redirect_uri: []const u8 = "",
    client_id: []const u8 = "",
    code_verifier: []const u8 = "",
    refresh_token: []const u8 = "",
    resource: []const u8 = "",
    scope: []const u8 = "",
};

fn appendFormParam(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (out.items.len > 0) try out.append(allocator, '&');
    try out.appendSlice(allocator, name);
    try out.append(allocator, '=');
    const enc = try percentEncode(allocator, value, true);
    defer allocator.free(enc);
    try out.appendSlice(allocator, enc);
}

pub fn buildTokenRequestBody(allocator: std.mem.Allocator, req: TokenRequest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendFormParam(allocator, &out, "grant_type", req.grant_type);
    if (req.code.len > 0) try appendFormParam(allocator, &out, "code", req.code);
    if (req.redirect_uri.len > 0) try appendFormParam(allocator, &out, "redirect_uri", req.redirect_uri);
    if (req.client_id.len > 0) try appendFormParam(allocator, &out, "client_id", req.client_id);
    if (req.code_verifier.len > 0) try appendFormParam(allocator, &out, "code_verifier", req.code_verifier);
    if (req.refresh_token.len > 0) try appendFormParam(allocator, &out, "refresh_token", req.refresh_token);
    if (req.resource.len > 0) try appendFormParam(allocator, &out, "resource", req.resource);
    if (req.scope.len > 0) try appendFormParam(allocator, &out, "scope", req.scope);
    return out.toOwnedSlice(allocator);
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn stringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![][]const u8 {
    const v = obj.get(name) orelse return allocator.alloc([]const u8, 0);
    const arr = switch (v) {
        .array => |a| a,
        else => return allocator.alloc([]const u8, 0),
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (arr.items) |item| {
        switch (item) {
            .string => |s| try out.append(allocator, try allocator.dupe(u8, s)),
            else => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: ?u64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,

    pub fn deinit(self: *const TokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        if (self.refresh_token) |v| allocator.free(v);
        if (self.scope) |v| allocator.free(v);
    }
};

pub fn parseTokenResponse(allocator: std.mem.Allocator, body: []const u8) !TokenResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidTokenResponse;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidTokenResponse,
    };
    const access = stringField(obj, "access_token") orelse return error.InvalidTokenResponse;
    const token_type = stringField(obj, "token_type") orelse "Bearer";

    var expires_in: ?u64 = null;
    if (obj.get("expires_in")) |v| {
        expires_in = switch (v) {
            .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
            .float => |f| if (f >= 0) @as(u64, @intFromFloat(f)) else null,
            .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
            else => null,
        };
    }

    const access_dup = try allocator.dupe(u8, access);
    errdefer allocator.free(access_dup);
    const type_dup = try allocator.dupe(u8, token_type);
    errdefer allocator.free(type_dup);
    const refresh_dup = if (stringField(obj, "refresh_token")) |s| try allocator.dupe(u8, s) else null;
    errdefer if (refresh_dup) |v| allocator.free(v);
    const scope_dup = if (stringField(obj, "scope")) |s| try allocator.dupe(u8, s) else null;
    errdefer if (scope_dup) |v| allocator.free(v);

    return .{
        .access_token = access_dup,
        .token_type = type_dup,
        .expires_in = expires_in,
        .refresh_token = refresh_dup,
        .scope = scope_dup,
    };
}

pub const TokenError = struct {
    error_code: []const u8,
    error_description: ?[]const u8 = null,

    pub fn deinit(self: *const TokenError, allocator: std.mem.Allocator) void {
        allocator.free(self.error_code);
        if (self.error_description) |v| allocator.free(v);
    }
};

pub fn parseTokenError(allocator: std.mem.Allocator, body: []const u8) !TokenError {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidTokenResponse;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidTokenResponse,
    };
    const code = stringField(obj, "error") orelse return error.InvalidTokenResponse;
    const code_dup = try allocator.dupe(u8, code);
    errdefer allocator.free(code_dup);
    const desc_dup = if (stringField(obj, "error_description")) |s| try allocator.dupe(u8, s) else null;
    return .{ .error_code = code_dup, .error_description = desc_dup };
}

pub const ProtectedResourceMetadata = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8,
    bearer_methods_supported: []const []const u8,

    pub fn deinit(self: *const ProtectedResourceMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        freeStringList(allocator, self.authorization_servers);
        freeStringList(allocator, self.scopes_supported);
        freeStringList(allocator, self.bearer_methods_supported);
    }
};

pub fn parseProtectedResourceMetadata(allocator: std.mem.Allocator, body: []const u8) !ProtectedResourceMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidMetadata;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMetadata,
    };
    const resource = stringField(obj, "resource") orelse return error.InvalidMetadata;
    const resource_dup = try allocator.dupe(u8, resource);
    errdefer allocator.free(resource_dup);
    const servers = try stringArray(allocator, obj, "authorization_servers");
    errdefer freeStringList(allocator, servers);
    const scopes = try stringArray(allocator, obj, "scopes_supported");
    errdefer freeStringList(allocator, scopes);
    const methods = try stringArray(allocator, obj, "bearer_methods_supported");
    return .{
        .resource = resource_dup,
        .authorization_servers = servers,
        .scopes_supported = scopes,
        .bearer_methods_supported = methods,
    };
}

pub const AuthorizationServerMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: []const []const u8,
    code_challenge_methods_supported: []const []const u8,
    token_endpoint_auth_methods_supported: []const []const u8,

    pub fn deinit(self: *const AuthorizationServerMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        allocator.free(self.authorization_endpoint);
        allocator.free(self.token_endpoint);
        if (self.registration_endpoint) |v| allocator.free(v);
        freeStringList(allocator, self.scopes_supported);
        freeStringList(allocator, self.code_challenge_methods_supported);
        freeStringList(allocator, self.token_endpoint_auth_methods_supported);
    }
};

pub fn parseAuthorizationServerMetadata(allocator: std.mem.Allocator, body: []const u8) !AuthorizationServerMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidMetadata;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMetadata,
    };
    const issuer = stringField(obj, "issuer") orelse return error.InvalidMetadata;
    const authz = stringField(obj, "authorization_endpoint") orelse return error.InvalidMetadata;
    const token = stringField(obj, "token_endpoint") orelse return error.InvalidMetadata;

    const issuer_dup = try allocator.dupe(u8, issuer);
    errdefer allocator.free(issuer_dup);
    const authz_dup = try allocator.dupe(u8, authz);
    errdefer allocator.free(authz_dup);
    const token_dup = try allocator.dupe(u8, token);
    errdefer allocator.free(token_dup);
    const reg_dup = if (stringField(obj, "registration_endpoint")) |s| try allocator.dupe(u8, s) else null;
    errdefer if (reg_dup) |v| allocator.free(v);
    const scopes = try stringArray(allocator, obj, "scopes_supported");
    errdefer freeStringList(allocator, scopes);
    const methods = try stringArray(allocator, obj, "code_challenge_methods_supported");
    errdefer freeStringList(allocator, methods);
    const auth_methods = try stringArray(allocator, obj, "token_endpoint_auth_methods_supported");
    errdefer freeStringList(allocator, auth_methods);

    return .{
        .issuer = issuer_dup,
        .authorization_endpoint = authz_dup,
        .token_endpoint = token_dup,
        .registration_endpoint = reg_dup,
        .scopes_supported = scopes,
        .code_challenge_methods_supported = methods,
        .token_endpoint_auth_methods_supported = auth_methods,
    };
}

pub fn supportsS256(meta: AuthorizationServerMetadata) bool {
    if (meta.code_challenge_methods_supported.len == 0) return true;
    for (meta.code_challenge_methods_supported) |m| {
        if (std.mem.eql(u8, m, "S256")) return true;
    }
    return false;
}

fn effectivePort(u: Url) u16 {
    if (u.port) |p| return p;
    if (std.ascii.eqlIgnoreCase(u.scheme, "https")) return 443;
    return 80;
}

pub fn resourceMatches(a: []const u8, b: []const u8) bool {
    const ua = parseUrl(a) catch return false;
    const ub = parseUrl(b) catch return false;
    if (!std.ascii.eqlIgnoreCase(ua.scheme, ub.scheme)) return false;
    if (!std.ascii.eqlIgnoreCase(ua.host, ub.host)) return false;
    if (effectivePort(ua) != effectivePort(ub)) return false;
    return std.mem.eql(u8, trimTrailingSlash(ua.path), trimTrailingSlash(ub.path));
}

pub const verifier_bytes: usize = 48;

pub fn codeVerifierFromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

pub fn generateCodeVerifier(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    var bytes: [verifier_bytes]u8 = undefined;
    random.bytes(&bytes);
    return codeVerifierFromBytes(allocator, &bytes);
}

pub fn generateState(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    var bytes: [32]u8 = undefined;
    random.bytes(&bytes);
    return codeVerifierFromBytes(allocator, &bytes);
}

pub fn codeChallengeS256(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(digest.len));
    _ = enc.encode(out, &digest);
    return out;
}

pub fn expiresAt(now_seconds: i64, expires_in: ?u64) ?i64 {
    const e = expires_in orelse return null;
    return now_seconds + @as(i64, @intCast(e));
}

pub fn isExpired(expires_at_seconds: ?i64, now_seconds: i64, skew_seconds: u64) bool {
    const at = expires_at_seconds orelse return false;
    return now_seconds + @as(i64, @intCast(skew_seconds)) >= at;
}

pub fn bearerHeaderValue(allocator: std.mem.Allocator, access_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
}

pub const ClientRegistrationRequest = struct {
    client_name: []const u8,
    redirect_uris: []const []const u8,
    scope: []const u8 = "",
};

pub fn buildClientRegistrationBody(allocator: std.mem.Allocator, req: ClientRegistrationRequest) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .client_name = req.client_name,
        .redirect_uris = req.redirect_uris,
        .grant_types = &.{ "authorization_code", "refresh_token" },
        .response_types = &.{"code"},
        .token_endpoint_auth_method = "none",
        .scope = req.scope,
    }, .{});
}

pub const ClientRegistration = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,

    pub fn deinit(self: *const ClientRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        if (self.client_secret) |v| allocator.free(v);
    }
};

pub fn parseClientRegistration(allocator: std.mem.Allocator, body: []const u8) !ClientRegistration {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidMetadata;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMetadata,
    };
    const id = stringField(obj, "client_id") orelse return error.InvalidMetadata;
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const secret_dup = if (stringField(obj, "client_secret")) |s| try allocator.dupe(u8, s) else null;
    return .{ .client_id = id_dup, .client_secret = secret_dup };
}

const testing = std.testing;

test "a bearer challenge exposes the resource metadata url and scope" {
    const header = "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource/mcp\", scope=\"files:read files:write\"";
    const challenge = (try parseBearerChallenge(testing.allocator, header)) orelse return error.TestUnexpectedResult;
    defer challenge.deinit(testing.allocator);
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource/mcp", challenge.resource_metadata.?);
    try testing.expectEqualStrings("files:read files:write", challenge.scope.?);
    try testing.expectEqual(@as(?[]const u8, null), challenge.error_code);
}

test "a challenge with no parameters still parses as bearer" {
    const challenge = (try parseBearerChallenge(testing.allocator, "Bearer")) orelse return error.TestUnexpectedResult;
    defer challenge.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), challenge.resource_metadata);
    try testing.expectEqual(@as(?[]const u8, null), challenge.scope);
}

test "a non-bearer challenge is ignored" {
    const challenge = try parseBearerChallenge(testing.allocator, "Basic realm=\"mcp\"");
    try testing.expectEqual(@as(?BearerChallenge, null), challenge);
}

test "a bearer challenge after another scheme is still found" {
    const header = "Basic realm=\"mcp\", Bearer resource_metadata=\"https://as.example.com/prm\"";
    const challenge = (try parseBearerChallenge(testing.allocator, header)) orelse return error.TestUnexpectedResult;
    defer challenge.deinit(testing.allocator);
    try testing.expectEqualStrings("https://as.example.com/prm", challenge.resource_metadata.?);
}

test "a quoted value keeps an escaped quote" {
    const header = "Bearer error=\"invalid_token\", error_description=\"the token \\\"expired\\\"\"";
    const challenge = (try parseBearerChallenge(testing.allocator, header)) orelse return error.TestUnexpectedResult;
    defer challenge.deinit(testing.allocator);
    try testing.expectEqualStrings("invalid_token", challenge.error_code.?);
    try testing.expectEqualStrings("the token \"expired\"", challenge.error_description.?);
}

test "the protected resource metadata url inserts the resource path after the well-known segment" {
    const url = try protectedResourceMetadataUrl(testing.allocator, "https://mcp.example.com/mcp");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource/mcp", url);
}

test "a root resource url has no path suffix in its metadata url" {
    const url = try protectedResourceMetadataUrl(testing.allocator, "https://mcp.example.com/");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource", url);
}

test "a resource url with a port keeps the port in its metadata url" {
    const url = try protectedResourceMetadataUrl(testing.allocator, "http://127.0.0.1:8080/mcp");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp", url);
}

test "authorization server metadata candidates cover rfc 8414 and both oidc shapes" {
    const urls = try authorizationServerMetadataUrls(testing.allocator, "https://as.example.com/tenant1");
    defer freeStringList(testing.allocator, urls);
    try testing.expectEqual(@as(usize, 3), urls.len);
    try testing.expectEqualStrings("https://as.example.com/.well-known/oauth-authorization-server/tenant1", urls[0]);
    try testing.expectEqualStrings("https://as.example.com/.well-known/openid-configuration/tenant1", urls[1]);
    try testing.expectEqualStrings("https://as.example.com/tenant1/.well-known/openid-configuration", urls[2]);
}

test "an issuer with no path yields two candidates" {
    const urls = try authorizationServerMetadataUrls(testing.allocator, "https://as.example.com");
    defer freeStringList(testing.allocator, urls);
    try testing.expectEqual(@as(usize, 2), urls.len);
    try testing.expectEqualStrings("https://as.example.com/.well-known/oauth-authorization-server", urls[0]);
    try testing.expectEqualStrings("https://as.example.com/.well-known/openid-configuration", urls[1]);
}

test "protected resource metadata parses the authorization servers and scopes" {
    const body =
        \\{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://as.example.com"],"scopes_supported":["files:read","files:write"],"bearer_methods_supported":["header"]}
    ;
    const meta = try parseProtectedResourceMetadata(testing.allocator, body);
    defer meta.deinit(testing.allocator);
    try testing.expectEqualStrings("https://mcp.example.com/mcp", meta.resource);
    try testing.expectEqual(@as(usize, 1), meta.authorization_servers.len);
    try testing.expectEqualStrings("https://as.example.com", meta.authorization_servers[0]);
    try testing.expectEqual(@as(usize, 2), meta.scopes_supported.len);
    try testing.expectEqualStrings("files:write", meta.scopes_supported[1]);
    try testing.expectEqualStrings("header", meta.bearer_methods_supported[0]);
}

test "protected resource metadata without a resource is rejected" {
    const body =
        \\{"authorization_servers":["https://as.example.com"]}
    ;
    try testing.expectError(error.InvalidMetadata, parseProtectedResourceMetadata(testing.allocator, body));
}

test "authorization server metadata parses the endpoints" {
    const body =
        \\{"issuer":"https://as.example.com","authorization_endpoint":"https://as.example.com/authorize","token_endpoint":"https://as.example.com/token","registration_endpoint":"https://as.example.com/register","code_challenge_methods_supported":["S256"],"scopes_supported":["files:read"]}
    ;
    const meta = try parseAuthorizationServerMetadata(testing.allocator, body);
    defer meta.deinit(testing.allocator);
    try testing.expectEqualStrings("https://as.example.com/authorize", meta.authorization_endpoint);
    try testing.expectEqualStrings("https://as.example.com/token", meta.token_endpoint);
    try testing.expectEqualStrings("https://as.example.com/register", meta.registration_endpoint.?);
    try testing.expect(supportsS256(meta));
}

test "authorization server metadata without a token endpoint is rejected" {
    const body =
        \\{"issuer":"https://as.example.com","authorization_endpoint":"https://as.example.com/authorize"}
    ;
    try testing.expectError(error.InvalidMetadata, parseAuthorizationServerMetadata(testing.allocator, body));
}

test "s256 is assumed supported when the server lists no challenge methods" {
    const meta = AuthorizationServerMetadata{
        .issuer = "",
        .authorization_endpoint = "",
        .token_endpoint = "",
        .scopes_supported = &.{},
        .code_challenge_methods_supported = &.{},
        .token_endpoint_auth_methods_supported = &.{},
    };
    try testing.expect(supportsS256(meta));
}

test "s256 is rejected when the server lists only plain" {
    const meta = AuthorizationServerMetadata{
        .issuer = "",
        .authorization_endpoint = "",
        .token_endpoint = "",
        .scopes_supported = &.{},
        .code_challenge_methods_supported = &.{"plain"},
        .token_endpoint_auth_methods_supported = &.{},
    };
    try testing.expect(!supportsS256(meta));
}

test "the code challenge is the base64url sha256 of the verifier" {
    const challenge = try codeChallengeS256(testing.allocator, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    defer testing.allocator.free(challenge);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "a verifier generated from fixed bytes is url safe and 64 characters" {
    var bytes: [verifier_bytes]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    const verifier = try codeVerifierFromBytes(testing.allocator, &bytes);
    defer testing.allocator.free(verifier);
    try testing.expectEqual(@as(usize, 64), verifier.len);
    for (verifier) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        try testing.expect(ok);
    }
}

test "a seeded generator produces the same verifier twice" {
    var prng_a = std.Random.DefaultPrng.init(7);
    var prng_b = std.Random.DefaultPrng.init(7);
    const a = try generateCodeVerifier(testing.allocator, prng_a.random());
    defer testing.allocator.free(a);
    const b = try generateCodeVerifier(testing.allocator, prng_b.random());
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "the authorization url carries pkce, state and the resource parameter" {
    const url = try buildAuthorizationUrl(testing.allocator, .{
        .authorization_endpoint = "https://as.example.com/authorize",
        .client_id = "client-1",
        .redirect_uri = "http://127.0.0.1:9999/callback",
        .code_challenge = "abc123",
        .state = "state-1",
        .scope = "files:read",
        .resource = "https://mcp.example.com/mcp",
    });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://as.example.com/authorize?response_type=code&client_id=client-1" ++
            "&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcallback" ++
            "&code_challenge=abc123&code_challenge_method=S256&state=state-1" ++
            "&scope=files%3Aread&resource=https%3A%2F%2Fmcp.example.com%2Fmcp",
        url,
    );
}

test "the authorization url appends to an endpoint that already has a query" {
    const url = try buildAuthorizationUrl(testing.allocator, .{
        .authorization_endpoint = "https://as.example.com/authorize?tenant=1",
        .client_id = "client-1",
        .redirect_uri = "http://127.0.0.1/cb",
        .code_challenge = "abc",
        .state = "s",
    });
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://as.example.com/authorize?tenant=1&response_type=code"));
    try testing.expect(std.mem.indexOf(u8, url, "&scope=") == null);
    try testing.expect(std.mem.indexOf(u8, url, "&resource=") == null);
}

test "the code exchange body is form encoded with the verifier and resource" {
    const body = try buildTokenRequestBody(testing.allocator, .{
        .grant_type = "authorization_code",
        .code = "code-1",
        .redirect_uri = "http://127.0.0.1:9999/callback",
        .client_id = "client-1",
        .code_verifier = "verifier-1",
        .resource = "https://mcp.example.com/mcp",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "grant_type=authorization_code&code=code-1" ++
            "&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcallback" ++
            "&client_id=client-1&code_verifier=verifier-1" ++
            "&resource=https%3A%2F%2Fmcp.example.com%2Fmcp",
        body,
    );
}

test "the refresh body carries the refresh token and no code" {
    const body = try buildTokenRequestBody(testing.allocator, .{
        .grant_type = "refresh_token",
        .refresh_token = "refresh-1",
        .client_id = "client-1",
        .resource = "https://mcp.example.com/mcp",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=client-1&refresh_token=refresh-1&resource=https%3A%2F%2Fmcp.example.com%2Fmcp",
        body,
    );
}

test "a token response exposes the access token and its lifetime" {
    const body =
        \\{"access_token":"at-1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-1","scope":"files:read"}
    ;
    const token = try parseTokenResponse(testing.allocator, body);
    defer token.deinit(testing.allocator);
    try testing.expectEqualStrings("at-1", token.access_token);
    try testing.expectEqualStrings("Bearer", token.token_type);
    try testing.expectEqual(@as(?u64, 3600), token.expires_in);
    try testing.expectEqualStrings("rt-1", token.refresh_token.?);
    try testing.expectEqualStrings("files:read", token.scope.?);
}

test "a token response with a string expires_in is accepted" {
    const body =
        \\{"access_token":"at-1","token_type":"Bearer","expires_in":"120"}
    ;
    const token = try parseTokenResponse(testing.allocator, body);
    defer token.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 120), token.expires_in);
    try testing.expectEqual(@as(?[]const u8, null), token.refresh_token);
}

test "a token response without an access token is rejected" {
    const body =
        \\{"token_type":"Bearer"}
    ;
    try testing.expectError(error.InvalidTokenResponse, parseTokenResponse(testing.allocator, body));
}

test "a token error response exposes the error code" {
    const body =
        \\{"error":"invalid_grant","error_description":"code expired"}
    ;
    const err = try parseTokenError(testing.allocator, body);
    defer err.deinit(testing.allocator);
    try testing.expectEqualStrings("invalid_grant", err.error_code);
    try testing.expectEqualStrings("code expired", err.error_description.?);
}

test "a token is expired after its lifetime" {
    const at = expiresAt(1_000, 60).?;
    try testing.expect(isExpired(at, 1_061, 0));
}

test "a token is valid one second before its lifetime ends" {
    const at = expiresAt(1_000, 60).?;
    try testing.expect(!isExpired(at, 1_059, 0));
}

test "a token is expired at its lifetime boundary" {
    const at = expiresAt(1_000, 60).?;
    try testing.expect(isExpired(at, 1_060, 0));
}

test "a token inside the refresh skew is treated as expired" {
    const at = expiresAt(1_000, 60).?;
    try testing.expect(isExpired(at, 1_030, 30));
}

test "a token with no expiry never expires" {
    try testing.expect(!isExpired(null, 9_999_999, 60));
}

test "the bearer header value prefixes the token" {
    const value = try bearerHeaderValue(testing.allocator, "at-1");
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("Bearer at-1", value);
}

test "a resource url matches its metadata resource ignoring a trailing slash" {
    try testing.expect(resourceMatches("https://mcp.example.com/mcp/", "https://mcp.example.com/mcp"));
}

test "a resource url does not match a different host" {
    try testing.expect(!resourceMatches("https://mcp.example.com/mcp", "https://evil.example.com/mcp"));
}

test "a resource url does not match a different port" {
    try testing.expect(!resourceMatches("https://mcp.example.com:8443/mcp", "https://mcp.example.com/mcp"));
}

test "the client registration body declares a public client with pkce" {
    const body = try buildClientRegistrationBody(testing.allocator, .{
        .client_name = "pabrik",
        .redirect_uris = &.{"http://127.0.0.1:9999/callback"},
        .scope = "files:read",
    });
    defer testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("pabrik", obj.get("client_name").?.string);
    try testing.expectEqualStrings("none", obj.get("token_endpoint_auth_method").?.string);
    try testing.expectEqualStrings("http://127.0.0.1:9999/callback", obj.get("redirect_uris").?.array.items[0].string);
    try testing.expectEqualStrings("authorization_code", obj.get("grant_types").?.array.items[0].string);
}

test "a client registration response exposes the client id" {
    const body =
        \\{"client_id":"client-9","client_secret":"shh"}
    ;
    const reg = try parseClientRegistration(testing.allocator, body);
    defer reg.deinit(testing.allocator);
    try testing.expectEqualStrings("client-9", reg.client_id);
    try testing.expectEqualStrings("shh", reg.client_secret.?);
}
