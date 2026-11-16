const std = @import("std");

// Although this function looks imperative, it does not perform the build directly and instead it mutates the build graph (`b`) that will be then executed by an …
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose what target to build for.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features of this build script using `b.option()`.

    // This creates a module, which represents a collection of source files alongside some compilation options, such as optimization mode and linked system libraries.
    const mod = b.addModule("gilvec_db", .{
        // The root source file is the "entry point" of this module.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable.
    const exe = b.addExecutable(.{
        .name = "gilvec_db",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but, unlike b.addModule, it does not expose the module to consumers of this package, which is why in …
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when defining an executable or library (in the root module), and you can also hardcode a specific …
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the root module.
            .imports = &.{
                // Here "gilvec_db" is the name you will use in your source code to import this module (e.g.
                .{ .name = "gilvec_db", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the install prefix when running `zig build` (i.e. when executing the default step).
    b.installArtifact(exe);

    // This creates a top level step.
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's root module.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple times and since the two run steps do not depend on one another, this will make the two …
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
}
