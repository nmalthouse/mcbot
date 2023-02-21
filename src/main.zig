const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const server = try std.net.tcpConnectToHost(alloc, "localhost", 25565);
    defer server.close();

    var q_cond: std.Thread.Condition = .{};
    var q_mutex: std.Thread.Mutex = .{};
    q_mutex.lock();
    var queue = mc.PacketQueueType.init();
    var listener_thread = try std.Thread.spawn(
        .{},
        mc.ServerListener.parserThread,
        .{ alloc, server.reader(), &queue, &q_cond },
    );
    defer listener_thread.join();

    var packet = try mc.Packet.init(alloc);
    try packet.varInt(0);
    try packet.varInt(761);
    try packet.string("localhost");
    try packet.short(25565);
    try packet.varInt(2);

    _ = try server.write(packet.getWritableBuffer());

    try packet.clear();
    try packet.varInt(0);
    try packet.string("rat");
    try packet.boolean(false);

    _ = try server.write(packet.getWritableBuffer());

    while (true) {
        q_cond.wait(&q_mutex);
        while (queue.get()) |item| {
            std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, item.data.id)]});
            if (item.data.id == 0x1F) {
                try packet.clear();
                try packet.varInt(0x11);
                try packet.slice(item.data.buffer.items);
                _ = try server.write(packet.getWritableBuffer());
            }
            item.data.buffer.deinit();
        }
    }

    const out = try std.fs.cwd().createFile("out.dump", .{});
    defer out.close();
    _ = try out.write(packet.getWritableBuffer());

    defer packet.deinit();
}
