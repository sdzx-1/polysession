const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("polysession", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_infos: []const struct {
        name: []const u8,
        path: []const u8,
    } = &.{
        // zig fmt: off
        .{ .name = "simple", .path = "examples/simple.zig" },
        .{ .name = "2pc",    .path = "examples/two_phase_commit.zig" },
        //zig fmt: on
    };

    inline for (exe_infos) |info| {
        const exe = b.addExecutable(.{
            .name = info.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(info.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "polysession", .module = mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_step = b.step(info.name, "Run the " ++ info.name);

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
