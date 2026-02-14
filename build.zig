const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Determine version string at build-time
    const version = b.option([]const u8, "version", "Override version string") orelse "dev";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = if (@hasField(std.Build.ExecutableOptions, "root_module"))
        b.addExecutable(.{
            .name = "melon",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        })
    else
        b.addExecutable(.{
            .name = "melon",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

    if (@hasDecl(@TypeOf(exe.*), "root_module")) {
        exe.root_module.addOptions("build_options", options);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run melon");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = if (@hasField(std.Build.TestOptions, "root_module"))
        b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        })
    else
        b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

    if (@hasDecl(@TypeOf(unit_tests.*), "root_module")) {
        unit_tests.root_module.addOptions("build_options", options);
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
