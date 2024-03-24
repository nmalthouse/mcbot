const std = @import("std");
const ratgraph = @import("ratgraph/build.zig");
const MC_VERSION_STRING = "1.19.4";

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const proto_gen = b.addExecutable(.{
        .name = "proto_gen",
        .root_source_file = .{ .path = "src/protocol_gen.zig" },
    });
    const gen_step = b.addRunArtifact(proto_gen);

    const gen_proto = gen_step.addOutputFileArg("protocol.zig");
    gen_step.addArg(MC_VERSION_STRING);

    const wf = b.addWriteFiles();
    wf.addCopyFileToSource(gen_proto, "src/protocol.zig");

    const update_protocol_step = b.step("update-protocol", "update src/protocol_gen.zig to latest");
    update_protocol_step.dependOn(&wf.step);

    const exe = b.addExecutable(.{
        .name = "mcbot",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
        .link_libc = true,
    });
    b.installArtifact(exe);
    exe.step.dependOn(&wf.step);

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
