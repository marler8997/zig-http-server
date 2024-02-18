const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    {
        const exe = b.addExecutable(.{
            .name = "fileserver",
            .root_source_file = .{ .path = "fileserver.zig" },
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const serve_step = b.step("fileserver", "Run the fileserver");
        serve_step.dependOn(&run_cmd.step);
    }
}
