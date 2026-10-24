//! The guest has no network device, so netd's loopback proxy is the only way
//! out — and nothing takes it unless it is told. main.zig's exec/tty env and
//! netd's login-shell profile both come from here.

const std = @import("std");
const builtin = @import("builtin");

/// netd's proxy: absolute-form for `http://`, `CONNECT` for `https://`.
pub const proxy_url = "http://127.0.0.1:3128";
/// Loopback is the guest itself — netd's own listeners and a workspace's dev
/// servers, which the preview tunnel fronts. Proxying those would loop.
pub const no_proxy_value = "localhost,127.0.0.1,::1";

/// Both spellings, because clients disagree: git, curl and python read the
/// lower-case names, wget and npm read the upper-case ones, and a client that
/// reads both must not see two different answers.
pub const http_proxy = "http_proxy=" ++ proxy_url;
pub const https_proxy = "https_proxy=" ++ proxy_url;
pub const http_proxy_upper = "HTTP_PROXY=" ++ proxy_url;
pub const https_proxy_upper = "HTTPS_PROXY=" ++ proxy_url;
pub const no_proxy = "no_proxy=" ++ no_proxy_value;
pub const no_proxy_upper = "NO_PROXY=" ++ no_proxy_value;

/// A login shell sources this, so `sh -l`, the terminal tab and anything a
/// workload re-execs through a login shell all inherit the same egress.
pub const profile_path = "/etc/profile.d/pabrik-egress.sh";

pub const profile_script =
    "# pabrik-vm-netd: this guest has no network device, so the loopback proxy\n" ++
    "# is the only way out. Sourced by every login shell.\n" ++
    "export " ++ http_proxy ++ "\n" ++
    "export " ++ https_proxy ++ "\n" ++
    "export " ++ http_proxy_upper ++ "\n" ++
    "export " ++ https_proxy_upper ++ "\n" ++
    "export " ++ no_proxy ++ "\n" ++
    "export " ++ no_proxy_upper ++ "\n";

test "a shell that sources the profile script inherits the proxy under every spelling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pabrik-egress.sh", .data = profile_script });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const script_path = try std.fs.path.join(allocator, &.{ path_buf[0..dir_len], "pabrik-egress.sh" });
    defer allocator.free(script_path);

    const run = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            \\. "$1" || exit 9
            \\printf '%s|%s|%s|%s|%s|%s' "$http_proxy" "$https_proxy" "$HTTP_PROXY" "$HTTPS_PROXY" "$no_proxy" "$NO_PROXY"
            ,
            "sh",
            script_path,
        },
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    const want = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}|{s}|{s}", .{
        proxy_url, proxy_url, proxy_url, proxy_url, no_proxy_value, no_proxy_value,
    });
    defer allocator.free(want);
    try std.testing.expectEqualStrings(want, run.stdout);
}
