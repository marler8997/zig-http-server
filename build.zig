const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    {
        const exe = b.addExecutable("fileserver", "fileserver.zig");
        exe.single_threaded = true;
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const serve_step = b.step("fileserver", "Run the fileserver");
        serve_step.dependOn(&run_cmd.step);
    }
}
