const std = @import("std");
/// This constant determines which version of java edition minecraft the bot will build for.
/// Maps to keys inside of minecraft-data/data/dataPaths.json["pc"]
const MC_VERSION_STRING = "1.21.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_gen = b.addExecutable(.{
        .name = "proto_gen",
        .root_source_file = b.path("src/protocol_gen.zig"),
        .target = target,
        .optimize = optimize,
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
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    b.installArtifact(exe);
    exe.step.dependOn(&wf.step);

    const ratdep = b.dependency("ratgraph", .{ .target = target, .optimize = optimize });
    const ratmod = ratdep.module("ratgraph");
    exe.root_module.addImport("graph", ratmod);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const options = b.addOptions();
    options.addOption(bool, "verbose_logging", b.option(bool, "verbose", "log verbose") orelse false);
    options.addOption(u32, "MAX_BOTS", b.option(u32, "max_bots", "maximum number of bots this build can support") orelse 32);
    options.addOption(bool, "enable_draw", b.option(bool, "enable_draw", "compile with debug renderer option") orelse true);
    exe.root_module.addOptions("config", options);

    //dotracy(b, exe);
}
pub fn dotracy(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const opts = b.addOptions();
    const tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    const tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse (tracy != null);
    opts.addOption(bool, "enable_tracy", tracy != null);
    opts.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    opts.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    if (tracy) |tracy_path| {
        const client_cpp = std.fs.path.join(
            b.allocator,
            &[_][]const u8{ tracy_path, "public", "TracyClient.cpp" },
        ) catch unreachable;

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags = &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath(b.path(tracy_path));
        exe.addCSourceFile(.{ .file = b.path(client_cpp), .flags = tracy_c_flags });
        exe.linkSystemLibrary("c++");
        exe.linkLibC();
    }
    opts.addOption(bool, "enable_tracy", false);
    opts.addOption(bool, "enable_tracy_callstack", false);
    opts.addOption(bool, "enable_tracy_allocation", false);
}
