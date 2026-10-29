const std = @import("std");

/// `pabrik-admin` — the admin console as a program of its own:
/// `zig build run -- --db ~/.config/pabrik/agent.db`. It links the SQLite and
/// HTTP-server packages only, so it builds in seconds.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Same switch and same values as the server's `-Ddb_used`: `sqlite` (the
    // default) links no libpq, `sqlite,postgres` compiles the postgres backend
    // in and makes it the one this binary opens.
    const db_used = b.option(
        []const u8,
        "db_used",
        "Comma-separated database backends to compile: 'sqlite' (default, no libpq), add 'postgres' to also compile postgres (needs libpq)",
    ) orelse "sqlite";

    const databases_dep = b.dependency("databases", .{
        .target = target,
        .optimize = optimize,
        .db_used = db_used,
    });
    const kabelweb_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
    });

    const databases_mod = databases_dep.module("databases");
    // The SQL that differs between the two backends. Shared with the server, so
    // the console and pabrik spell `datetime('now')`/`sqlite_master` the same way.
    const dialect_mod = b.createModule(.{
        .root_source_file = b.path("../../dialect.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "databases", .module = databases_mod },
        },
    });
    // The session/password primitives are shared with the server, so they
    // live in `src/http_handlers/auth_core.zig`; a module may be rooted
    // outside this folder, an `@import` path may not.
    const auth_core_mod = b.createModule(.{
        .root_source_file = b.path("../../http_handlers/auth_core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "databases", .module = databases_mod },
        },
    });

    // The manager face: a client for `pabrik-vmd`'s socket plus the limits a
    // resize may ask for. Rooted in `src/vmd/` so it can reach its own files;
    // on a host that is not Linux it compiles to "not supported" instead.
    const manager_mod = b.createModule(.{
        .root_source_file = b.path("../../vmd/manager.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vm_wire", .module = b.createModule(.{
                .root_source_file = b.path("../../vm_wire.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });

    const imports = [_]std.Build.Module.Import{
        .{ .name = "databases", .module = databases_mod },
        .{ .name = "dialect", .module = dialect_mod },
        .{ .name = "kabelweb", .module = kabelweb_dep.module("kabelweb") },
        .{ .name = "auth_core", .module = auth_core_mod },
        .{ .name = "vmd_manager", .module = manager_mod },
    };

    const exe = b.addExecutable(.{
        .name = "pabrik-admin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &imports,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the admin console").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("mod.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the admin console's tests").dependOn(&run_tests.step);
}
