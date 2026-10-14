const std = @import("std");
const Io = std.Io;

/// Resolve `~/.config/pabrik/agent.db`, creating the directory tree with
/// `mkdir -p` semantics if it does not yet exist.
pub fn getDbPath(allocator: std.mem.Allocator, io: std.Io, environment: *std.process.Environ.Map) ![:0]const u8 {
    // On POSIX systems, the canonical user-home env var is `HOME`.
    const home = blk: {
        if (environment.get("HOME")) |h| {
            if (h.len > 0) break :blk h;
        }
        if (environment.get("USERPROFILE")) |u| {
            if (u.len > 0) break :blk u;
        }
        std.log.err("Failed to get HOME/USERPROFILE environment variable", .{});
        return error.FailedToGetHome;
    };

    // `home` is fed to `openDirAbsolute` below, which ASSERTS the path is
    // absolute and ABORTS the whole process (Debug/ReleaseSafe) instead of
    // returning an error — a relative HOME/USERPROFILE would make pabrik
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("HOME/USERPROFILE is not an absolute path: {s}", .{home});
        return error.FailedToGetHome;
    }

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "pabrik",
    });
    defer allocator.free(config_dir);

    // mkdir -p semantics: open HOME as a Dir and createDirPath the rest.
    var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch |err| {
        std.log.err("Failed to open HOME directory {s}: {s}", .{ home, @errorName(err) });
        return err;
    };
    defer home_dir.close(io);
    home_dir.createDirPath(io, ".config/pabrik") catch |err| {
        std.log.err("Failed to create config directory {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    return try allocator.dupeZ(u8, db_path);
}
