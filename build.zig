const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------- IMPORTS -----------------------------
    const clap = b.dependency("clap", .{}).module("clap");
    const eui = b.dependency("eui", .{}).module("eui");
    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------- WOL MODULE ---------------------------
    // note: wol module is created so that other projects can use it with zig fetch and @import("wol").
    const wol = b.addModule("wol", .{
        .root_source_file = b.path("src/wol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "eui", .module = eui },
        },
    });

    // --------------------------- EXECUTABLE ---------------------------
    // Create, add and install the exe
    const exe = b.addExecutable(.{
        .name = "zig-wol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "wol", .module = wol },
                .{ .name = "clap", .module = clap },
                .{ .name = "eui", .module = eui },
                .{ .name = "build_zig_zon", .module = build_zig_zon },
            },
        }),
    });

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
