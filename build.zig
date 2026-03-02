const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------- WOL MODULE ---------------------------
    // note: wol module is created so that other projects can use it with zig fetch and @import("wol").
    const wol_module = b.addModule("wol", .{
        .root_source_file = b.path("src/wol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------- EXECUTABLE ---------------------------
    // Create, add and install the exe
    const exe = b.addExecutable(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = true,
        }),
        .name = "zig-wol",
    });

    // Add dependencies from local modules
    exe.root_module.addImport("wol", wol_module);

    // Add dependencies from fetched third-party libs (see build.zig.zon)
    exe.root_module.addImport("clap", b.dependency("clap", .{}).module("clap"));

    // Create and import a module for build.zig.zon, allows using its .version field in the codebase
    exe.root_module.addImport("build_zig_zon", b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    }));

    b.installArtifact(exe);

    // ------------------------------ RUN -------------------------------
    const run_step = b.step("run", "Run the program");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ------------------------------ DOCS ------------------------------
    // Generate documentation step (run this with "zig build docs")
    const install_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // ------------------------------ TEST ------------------------------
    // Create a test step (run this with "zig build test") to run all tests in src/tests.zig
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
