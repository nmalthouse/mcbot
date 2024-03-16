const std = @import("std");
const ratgraph = @import("ratgraph/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});

    const mode = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mcbot",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
        .link_libc = true,
    });
    b.installArtifact(exe);

    const module = ratgraph.module(b, exe);
    exe.addModule("graph", module);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
