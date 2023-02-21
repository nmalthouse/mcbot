const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

const nbt_zig = @import("nbt.zig");

const c = @cImport({
    @cInclude("libnbt/libnbt.h");
    @cInclude("libnbt/nbt_utils.h");
});

pub fn readJsonFile(filename: []const u8, alloc: std.mem.Allocator, comptime T: type) !T {
    const cwd = std.fs.cwd();
    const f = cwd.openFile(filename, .{}) catch null;
    if (f) |cont| {
        var buf: []const u8 = try cont.readToEndAlloc(alloc, 1024 * 1024 * 1024);
        defer alloc.free(buf);

        var ts = std.json.TokenStream.init(buf);
        var ret = try std.json.parse(T, &ts, .{ .allocator = alloc });
        //defer std.json.parseFree(T, ret, .{ .allocator = alloc });
        return ret;
    }
    return error.fileNotFound;
}

pub fn freeJson(comptime T: type, alloc: std.mem.Allocator, item: T) void {
    std.json.parseFree(T, item, .{ .allocator = alloc });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const server = try std.net.tcpConnectToHost(alloc, "localhost", 25565);
    defer server.close();

    const block_ids = readJsonFile("blocks.json", alloc, []mc.BlockIdJson) catch unreachable;
    defer freeJson([]mc.BlockIdJson, alloc, block_ids);

    var world = mc.ChunkMap.init(alloc);
    defer world.deinit();

    if (false) {
        const cwd = std.fs.cwd();
        const f = cwd.openFile("an.json", .{}) catch null;
        if (f) |cont| {
            var buf: []const u8 = try cont.readToEndAlloc(alloc, 1024 * 1024 * 1024);
            defer alloc.free(buf);

            var ts = std.json.TokenStream.init(buf);
            var ret = try std.json.parse([]mc.PacketAnalysisJson, &ts, .{ .allocator = alloc });
            defer std.json.parseFree([]mc.PacketAnalysisJson, ret, .{ .allocator = alloc });

            for (ret) |s| {
                var fbs = std.io.FixedBufferStream([]const u8){ .buffer = s.data, .pos = 0 };
                const r = fbs.reader();
                const plen = mc.readVarInt(r);
                _ = plen;
                const pid = mc.readVarInt(r);
                if (std.mem.eql(u8, s.bound_to, "s")) {
                    std.debug.print("{d} S pid {s}\n", .{ s.timestamp, id_list.packet_ids[@intCast(u32, pid)] });
                } else {
                    std.debug.print("{d} C pid {s}\n", .{ s.timestamp, id_list.ServerBoundPlayIds[@intCast(u32, pid)] });
                }
            }
        } else {
            std.debug.print("analysis file not found\n", .{});
        }
    }

    //if (true) {
    //return;
    //}

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

    var cmd_thread = try std.Thread.spawn(
        .{},
        mc.cmdThread,
        .{ alloc, &queue, &q_cond },
    );
    defer cmd_thread.join();

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

    var start_rot: bool = false;
    var player_id: ?u32 = null;

    var px: ?f64 = null;
    var py: ?f64 = null;
    var pz: ?f64 = null;

    var dx: f64 = 0;
    var delt: f64 = 0.2;

    while (true) {
        if (px != null and py != null and pz != null) {
            dx += delt;
            px.? += delt;
            if (dx > 4) {
                delt = -0.1;
            }
            if (dx < -4) {
                delt = 0.1;
            }
            try packet.clear();
            try packet.varInt(0x14);
            try packet.double(px.?);
            try packet.double(py.?);
            try packet.double(pz.?);
            try packet.float(@floatCast(f32, dx) * 90);
            try packet.float(@floatCast(f32, dx) * 20);
            try packet.boolean(true);
            _ = try server.write(packet.getWritableBuffer());
        }
        std.time.sleep(@floatToInt(u64, std.time.ns_per_s * (1.0 / 20.0)));
        //q_cond.wait(&q_mutex);
        while (queue.get()) |item| {
            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, item.data.id)]});
            switch (item.data.msg_type) {
                .server => {
                    switch (@intToEnum(id_list.packet_enum, item.data.id)) {
                        .Keep_Alive => {
                            try packet.clear();
                            try packet.varInt(0x11);
                            try packet.slice(item.data.buffer.items);
                            _ = try server.write(packet.getWritableBuffer());
                            std.debug.print("keep alive\n", .{});
                        },
                        .Login => {
                            std.debug.print("Login\n", .{});
                            var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                            const reader = fbs.reader();
                            const p_id = try reader.readInt(u32, .Big);
                            std.debug.print("\tid: {d}\n", .{p_id});
                            player_id = p_id;
                            start_rot = true;
                        },
                        .Spawn_Entity => {
                            var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                            const reader = fbs.reader();
                            const ent_id = mc.readVarInt(reader);
                            const uuid = try reader.readInt(u128, .Big);

                            const type_id = mc.readVarInt(reader);
                            const x = @bitCast(f64, try reader.readInt(u64, .Big));
                            const y = @bitCast(f64, try reader.readInt(u64, .Big));
                            const z = @bitCast(f64, try reader.readInt(u64, .Big));
                            std.debug.print("Ent id: {d}, {x}, {d}\n\tx: {d}, y: {d} z: {d}\n", .{ ent_id, uuid, type_id, x, y, z });
                        },
                        .Synchronize_Player_Position => {
                            var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                            const reader = fbs.reader();
                            const x = @bitCast(f64, try reader.readInt(u64, .Big));
                            const y = @bitCast(f64, try reader.readInt(u64, .Big));
                            const z = @bitCast(f64, try reader.readInt(u64, .Big));
                            const yaw = @bitCast(f32, try reader.readInt(u32, .Big));
                            const pitch = @bitCast(f32, try reader.readInt(u32, .Big));
                            const flags = try reader.readInt(u8, .Big);
                            const tel_id = mc.readVarInt(reader);
                            const should_dismount = try reader.readInt(u8, .Big);
                            _ = should_dismount;
                            std.debug.print(
                                "Sync pos: x: {d}, y: {d}, z: {d}, yaw {d}, pitch : {d} flags: {b}, tel_id: {}\n",
                                .{ x, y, z, yaw, pitch, flags, tel_id },
                            );
                            px = x;
                            py = y;
                            pz = z;

                            try packet.clear();
                            try packet.varInt(0);
                            try packet.varInt(tel_id);
                            _ = try server.write(packet.getWritableBuffer());
                        },

                        .Update_Entity_Position, .Update_Entity_Position_and_Rotation, .Update_Entity_Rotation => {
                            var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                            const reader = fbs.reader();
                            const ent_id = mc.readVarInt(reader);
                            if (player_id) |pid| {
                                if (ent_id == pid) {
                                    std.debug.print("Update ent pos: {d}\n", .{ent_id});
                                }
                            }
                        },

                        .Chunk_Data_and_Update_Light => {
                            var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                            const reader = fbs.reader();
                            const cx = try reader.readInt(i32, .Big);
                            const cy = try reader.readInt(i32, .Big);

                            var nbt_data = try nbt_zig.parseAsCompoundEntry(alloc, reader);
                            _ = nbt_data;
                            const data_size = mc.readVarInt(reader);
                            var chunk_data = std.ArrayList(u8).init(alloc);
                            defer chunk_data.deinit();
                            try chunk_data.resize(@intCast(usize, data_size));
                            try reader.readNoEof(chunk_data.items);

                            //TODO iterate all the chunk sections not just the first
                            var chunk: mc.Chunk = undefined;
                            var chunk_i: u32 = 0;
                            while (chunk_i < 16) : (chunk_i += 1) { //TODO determine number of chunk sections some other way
                                var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
                                const cr = chunk_fbs.reader();

                                const block_count = try cr.readInt(i16, .Big);
                                _ = block_count;
                                var chunk_section = mc.ChunkSection.init(alloc);
                                defer chunk[chunk_i] = chunk_section;

                                { //BLOCK STATES palated container
                                    //TODO handle other number of bits aswell not just 4
                                    const bp_entry = try cr.readInt(u8, .Big);
                                    switch (bp_entry) {
                                        4 => {
                                            const num_pal_entry = mc.readVarInt(cr);

                                            var i: u32 = 0;
                                            while (i < num_pal_entry) : (i += 1) {
                                                const mapping = mc.readVarInt(cr);
                                                try chunk_section.mapping.append(@intCast(mc.BLOCK_ID_INT, mapping));
                                            }

                                            const num_longs = mc.readVarInt(cr);
                                            var j: u32 = 0;

                                            while (j < num_longs) : (j += 1) {
                                                const d = try cr.readInt(u64, .Big);
                                                try chunk_section.data.append(d);
                                            }
                                        },
                                        else => {
                                            std.debug.print("NUMBER OF BITS NOT SUPPORTED YET\n", .{});
                                        },
                                    }
                                }
                            }

                            const ymap = try world.x.getOrPut(cx);
                            if (!ymap.found_existing) {
                                ymap.value_ptr.* = mc.ChunkMap.YTYPE.init(alloc);
                            }

                            const chunk_entry = try ymap.value_ptr.getOrPut(cy);
                            if (chunk_entry.found_existing) {
                                for (chunk_entry.value_ptr.*) |*cs| {
                                    cs.deinit();
                                }
                            }
                            chunk_entry.value_ptr.* = chunk;
                            //ymap.value_ptr.put(chunk);

                            const num_block_ent = mc.readVarInt(reader);
                            std.debug.print("{d} CHUNK {d} {d}, bec: {d}\n", .{ item.data.len, cx, cy, num_block_ent });
                        },
                        else => {},
                    }
                    item.data.buffer.deinit();
                },
                .local => {
                    if (std.mem.eql(u8, "move", item.data.buffer.items[0 .. item.data.buffer.items.len - 1])) {
                        if (start_rot and px != null and py != null and pz != null) {
                            std.debug.print("Moving {d} {d} {d}\n", .{ px.?, py.?, pz.? });
                            py.? -= 1;
                            try packet.clear();
                            try packet.varInt(0x13);
                            try packet.double(px.?);
                            try packet.double(py.?);
                            try packet.double(pz.?);
                            try packet.boolean(true);
                            _ = try server.write(packet.getWritableBuffer());
                        }
                    }
                    item.data.buffer.deinit();
                },
            }
        }
    }

    const out = try std.fs.cwd().createFile("out.dump", .{});
    defer out.close();
    _ = try out.write(packet.getWritableBuffer());

    defer packet.deinit();
}
