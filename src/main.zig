const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

const nbt_zig = @import("nbt.zig");
const astar = @import("astar.zig");

const math = std.math;

const c = @cImport({
    @cInclude("raylib.h");
});

pub const V2i = struct {
    x: i32,
    y: i32,
};

const ADJ = [8]V2i{
    .{ .x = -1, .y = 1 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 1 },
    .{ .x = 1, .y = 0 },

    .{ .x = 1, .y = -1 },
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = -1 },
    .{ .x = -1, .y = 0 },
};
//
//corner indices:
//0 2 4 6
//
//
//
//
//

const ADJ_COST = [8]u32{
    14,
    10,
    14,
    10,
    14,
    10,
    14,
    10,
};

pub const V3f = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn new(x_: f64, y_: f64, z_: f64) @This() {
        return .{ .x = x_, .y = y_, .z = z_ };
    }

    pub fn newi(x_: i64, y_: i64, z_: i64) @This() {
        return .{
            .x = @intToFloat(f64, x_),
            .y = @intToFloat(f64, y_),
            .z = @intToFloat(f64, z_),
        };
    }

    pub fn toRay(a: @This()) c.Vector3 {
        return .{
            .x = @floatCast(f32, a.x),
            .y = @floatCast(f32, a.y),
            .z = @floatCast(f32, a.z),
        };
    }

    pub fn magnitude(s: @This()) f64 {
        return math.sqrt(math.pow(f64, s.x, 2) +
            math.pow(f64, s.y, 2) +
            math.pow(f64, s.z, 2));
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    pub fn smul(s: @This(), scalar: f64) @This() {
        var r = s;
        r.x *= scalar;
        r.y *= scalar;
        r.z *= scalar;
        return r;
    }

    pub fn negate(s: @This()) @This() {
        return s.smul(-1);
    }

    pub fn subtract(a: @This(), b: @This()) @This() {
        return a.add(b.negate());
    }

    pub fn add(a: @This(), b: @This()) @This() {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn getUnitVec(v: @This()) @This() {
        return v.smul(1.0 / v.magnitude());
    }

    pub fn dot(v1: @This(), v2: @This()) f64 {
        return (v1.x * v2.x) + (v1.y * v2.y) + (v1.z * v2.z);
    }

    pub fn cross(a: @This(), b: @This()) @This() {
        return .{
            .x = (a.y * b.z - a.z * b.y),
            .y = -(a.x * b.z - a.z * b.x),
            .z = (a.x * b.y - a.y * b.x),
        };
    }
};

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
    errdefer _ = gpa.detectLeaks();
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

    //var cmd_thread = try std.Thread.spawn(
    //    .{},
    //    mc.cmdThread,
    //    .{ alloc, &queue, &q_cond },
    //);
    //defer cmd_thread.join();

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

    var pathctx = astar.AStarContext.init(alloc);
    defer pathctx.deinit();

    var start_rot: bool = false;
    var player_id: ?u32 = null;

    var px: ?f64 = null;
    var py: ?f64 = null;
    var pz: ?f64 = null;

    var dx: f64 = 0;

    var move_vecs = std.ArrayList(V3f).init(alloc);
    defer move_vecs.deinit();

    var complete_login = false;

    var do_move = true;
    var old_pos = V3f.new(0, 0, 0);

    var goal: ?V3f = null;
    const speed: f64 = 3; //BPS
    //
    var draw = false;

    if (draw) {
        c.InitWindow(1920, 1080, "Window");
    }
    //defer c.CloseWindow();

    //BEGIN RAYLIB
    var camera: c.Camera3D = undefined;
    camera.position = .{ .x = 15.0, .y = 10.0, .z = 15.0 }; // Camera position
    camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 }; // Camera looking at point
    camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 }; // Camera up vector (rotation towards target)
    camera.fovy = 90.0; // Camera field-of-view Y
    camera.projection = c.CAMERA_PERSPECTIVE;
    c.DisableCursor();
    c.SetCameraMode(camera, c.CAMERA_FREE);

    while (true) {
        if (draw) {
            //c.BeginDrawing();
            c.ClearBackground(c.RAYWHITE);
            c.BeginMode3D(camera);

            c.UpdateCamera(&camera);

            if (px != null and py != null and pz != null) {
                const playerpos = V3f.new(px.?, py.?, pz.?);
                camera.target = playerpos.toRay();
                {
                    const pix = @floatToInt(i64, playerpos.x);
                    const piy = @floatToInt(i64, playerpos.y);
                    const piz = @floatToInt(i64, playerpos.z);
                    const section = world.getChunkSectionPtr(pix, piy, piz);
                    const cc = mc.ChunkMap.getChunkCoord(pix, piy, piz);

                    if (section) |sec| {
                        var it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
                        var block = it.next();
                        while (block != null) : (block = it.next()) {
                            if (sec.mapping.items[block.?] == 0)
                                continue;
                            const co = it.getCoord();
                            c.DrawCube(.{
                                .x = @intToFloat(f32, co.x + cc.x * 16),
                                .y = @intToFloat(f32, co.y + (cc.y - 4) * 16),
                                .z = @intToFloat(f32, co.z + cc.z * 16),
                            }, 1.0, 1.0, 1.0, c.GRAY);
                        }
                    }

                    for (ADJ) |adj| {
                        const section1 = world.getChunkSectionPtr(pix + adj.x * 16, piy, piz + adj.y * 16);
                        const cc1 = mc.ChunkMap.getChunkCoord(pix + adj.x * 16, piy, piz + adj.y * 16);
                        if (section1) |sec| {
                            var it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
                            var block = it.next();
                            while (block != null) : (block = it.next()) {
                                if (sec.mapping.items[block.?] == 0)
                                    continue;
                                const co = it.getCoord();
                                c.DrawCube(.{
                                    .x = @intToFloat(f32, co.x + cc1.x * 16),
                                    .y = @intToFloat(f32, co.y + (cc1.y - 4) * 16),
                                    .z = @intToFloat(f32, co.z + cc1.z * 16),
                                }, 1.0, 1.0, 1.0, c.GRAY);
                            }
                        }
                    }

                    for (move_vecs.items) |mv| {
                        c.DrawCube(mv.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 0.3, 0.3, 0.3, c.BLUE);
                    }
                }
                c.DrawCube(playerpos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 1.0, 1.0, 1.0, c.RED);
            }

            c.DrawGrid(10, 1.0);

            c.EndMode3D();

            c.EndDrawing();
        }

        if (px != null and py != null and pz != null and do_move) {
            const dt: f64 = 1.0 / 20.0;
            if (goal) |gvec| {
                //goal = null;
                const pos = V3f.new(px.?, py.?, pz.?);
                const move_vec = gvec.subtract(pos);
                const dv = (move_vec.getUnitVec()).smul(speed * dt);
                if (move_vec.magnitude() > 0.1) {
                    px.? += dv.x;
                    py.? += dv.y;
                    pz.? += dv.z;

                    try packet.clear();
                    try packet.varInt(0x14);
                    try packet.double(px.?);
                    try packet.double(py.?);
                    try packet.double(pz.?);
                    try packet.float(@floatCast(f32, dx) * 90);
                    try packet.float(@floatCast(f32, dx) * 20);
                    try packet.boolean(true);
                    _ = try server.write(packet.getWritableBuffer());
                } else {
                    //goal = null;
                    goal = move_vecs.popOrNull();
                }
            }
        }
        std.time.sleep(@floatToInt(u64, std.time.ns_per_s * (1.0 / 20.0)));
        //q_cond.wait(&q_mutex);
        while (queue.get()) |item| {
            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, item.data.id)]});
            switch (item.data.msg_type) {
                .server => {
                    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                    const reader = fbs.reader();
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
                            const p_id = try reader.readInt(u32, .Big);
                            std.debug.print("\tid: {d}\n", .{p_id});
                            player_id = p_id;
                            start_rot = true;
                        },
                        .Plugin_Message => {
                            const ident_len = mc.readVarInt(reader);
                            var identifier = std.ArrayList(u8).init(alloc);
                            defer identifier.deinit();

                            var i: u32 = 0;
                            while (i < ident_len) : (i += 1) {
                                try identifier.append(try reader.readByte());
                            }
                            std.debug.print("Plugin Message: {s}\n", .{identifier.items});

                            try packet.clear();
                            try packet.varInt(0x0C);
                            try packet.string("tony:brand");
                            _ = try server.write(packet.getWritableBuffer());

                            try packet.clear();
                            try packet.varInt(0x07); //client info packet
                            try packet.string("en_US");
                            try packet.ubyte(2); //Render dist
                            try packet.varInt(0); //Chat mode, enabled
                            try packet.boolean(true);
                            try packet.ubyte(0); // what parts are shown of skin
                            try packet.varInt(1); //Dominant Hand
                            try packet.boolean(false);
                            try packet.boolean(true);
                            _ = try server.write(packet.getWritableBuffer());
                        },
                        .Change_Difficulty => {
                            const diff = try reader.readByte();
                            const locked = try reader.readByte();
                            std.debug.print("Set difficulty: {d} ,Locked: {d}\n", .{ diff, locked });
                        },
                        .Player_Abilities => {
                            std.debug.print("Player Abilities\n", .{});
                        },
                        .Spawn_Entity => {
                            const ent_id = mc.readVarInt(reader);
                            const uuid = try reader.readInt(u128, .Big);

                            const type_id = mc.readVarInt(reader);
                            const x = @bitCast(f64, try reader.readInt(u64, .Big));
                            const y = @bitCast(f64, try reader.readInt(u64, .Big));
                            const z = @bitCast(f64, try reader.readInt(u64, .Big));
                            std.debug.print("Ent id: {d}, {x}, {d}\n\tx: {d}, y: {d} z: {d}\n", .{ ent_id, uuid, type_id, x, y, z });
                        },
                        .Synchronize_Player_Position => {
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
                            old_pos = V3f.new(px.?, py.?, pz.?);

                            try packet.clear();
                            try packet.varInt(0);
                            try packet.varInt(tel_id);
                            _ = try server.write(packet.getWritableBuffer());

                            if (complete_login == false) {
                                complete_login = true;
                                try packet.clear();
                                try packet.varInt(0x06);
                                try packet.varInt(0);
                                _ = try server.write(packet.getWritableBuffer());
                            }
                        },

                        .Update_Entity_Position, .Update_Entity_Position_and_Rotation, .Update_Entity_Rotation => {
                            const ent_id = mc.readVarInt(reader);
                            if (player_id) |pid| {
                                if (ent_id == pid) {
                                    std.debug.print("Update ent pos: {d}\n", .{ent_id});
                                }
                            }
                        },

                        .Block_Update => {
                            const pos = try reader.readInt(i64, .Big);
                            const bx = pos >> 38;
                            const by = pos << 52 >> 52;
                            const bz = pos << 26 >> 38;

                            const new_id = mc.readVarInt(reader);
                            try world.setBlock(bx, by, bz, @intCast(mc.BLOCK_ID_INT, new_id));

                            std.debug.print("Block update {d} {d} {d} : {d}\n", .{ bx, by, bz, new_id });
                        },
                        .Chunk_Data_and_Update_Light => {
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
                            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
                            const cr = chunk_fbs.reader();
                            while (chunk_i < 16) : (chunk_i += 1) { //TODO determine number of chunk sections some other way

                                //std.debug.print(" CHUKN SEC {d}\n", .{chunk_i});
                                const block_count = try cr.readInt(i16, .Big);
                                _ = block_count;
                                chunk[chunk_i] = mc.ChunkSection.init(alloc);
                                const chunk_section = &chunk[chunk_i];

                                { //BLOCK STATES palated container
                                    const bp_entry = try cr.readInt(u8, .Big);
                                    {
                                        if (bp_entry == 0) {
                                            try chunk_section.mapping.append(@intCast(mc.BLOCK_ID_INT, mc.readVarInt(cr)));
                                        } else {
                                            const num_pal_entry = mc.readVarInt(cr);
                                            chunk_section.bits_per_entry = bp_entry;

                                            var i: u32 = 0;
                                            while (i < num_pal_entry) : (i += 1) {
                                                const mapping = mc.readVarInt(cr);
                                                try chunk_section.mapping.append(@intCast(mc.BLOCK_ID_INT, mapping));
                                            }
                                        }

                                        const num_longs = mc.readVarInt(cr);
                                        var j: u32 = 0;
                                        //std.debug.print("\t NUM LONGNS {d}\n", .{num_longs});

                                        while (j < num_longs) : (j += 1) {
                                            const d = try cr.readInt(u64, .Big);
                                            try chunk_section.data.append(d);
                                        }
                                    }
                                }
                                { //BIOME palated container
                                    const bp_entry = try cr.readInt(u8, .Big);
                                    {
                                        if (bp_entry == 0) {
                                            const id = mc.readVarInt(cr);
                                            _ = id;
                                        } else {
                                            const num_pal_entry = mc.readVarInt(cr);
                                            var i: u32 = 0;
                                            while (i < num_pal_entry) : (i += 1) {
                                                const mapping = mc.readVarInt(cr);
                                                _ = mapping;
                                                //try chunk_section.mapping.append(@intCast(mc.BLOCK_ID_INT, mapping));
                                            }
                                        }

                                        const num_longs = mc.readVarInt(cr);
                                        var j: u32 = 0;
                                        //std.debug.print("\t NUM LONGNS {d}\n", .{num_longs});

                                        while (j < num_longs) : (j += 1) {
                                            const d = try cr.readInt(u64, .Big);
                                            _ = d;
                                            //_ = try chunk_section.data.append(d);
                                        }
                                    }
                                }
                            }

                            const ymap = try world.x.getOrPut(cx);
                            if (!ymap.found_existing) {
                                ymap.value_ptr.* = mc.ChunkMap.ZTYPE.init(alloc);
                            }

                            const chunk_entry = try ymap.value_ptr.getOrPut(cy);
                            if (chunk_entry.found_existing) {
                                for (chunk_entry.value_ptr.*) |*cs| {
                                    cs.deinit();
                                }
                            }
                            chunk_entry.value_ptr.* = chunk;
                            //std.mem.copy(mc.ChunkSection, chunk_entry.value_ptr, &chunk);

                            const num_block_ent = mc.readVarInt(reader);
                            _ = num_block_ent;
                        },
                        .Player_Chat_Message => {
                            { //HEADER
                                const uuid = try reader.readInt(u128, .Big);
                                const index = mc.readVarInt(reader);
                                const sig_present = try reader.readInt(u8, .Big);
                                const sig_present_bool = if (sig_present == 0x1) true else false;
                                _ = index;
                                _ = uuid;
                                //std.debug.print("Chat from UUID: {d} {d}\n", .{ uuid, index });
                                //std.debug.print("sig_present {any}\n", .{sig_present_bool});
                                if (sig_present_bool) {
                                    std.debug.print("NOT SUPPORTED \n", .{});
                                    unreachable;
                                }

                                const msg_len = mc.readVarInt(reader);
                                var msg = std.ArrayList(u8).init(alloc);
                                try msg.resize(@intCast(u32, msg_len));
                                defer msg.deinit();
                                try reader.readNoEof(msg.items);
                                const eql = std.mem.eql;

                                var msg_buffer: [256]u8 = undefined;
                                var m_fbs = std.io.FixedBufferStream([]u8){ .buffer = &msg_buffer, .pos = 0 };
                                const m_wr = m_fbs.writer();

                                var it = std.mem.tokenize(u8, msg.items, " ");

                                const key = it.next().?;
                                if (eql(u8, key, "path")) {
                                    try pathctx.reset();
                                    try pathctx.addOpen(.{
                                        .x = @floatToInt(i32, px.?),
                                        .y = @floatToInt(i32, py.?),
                                        .z = @floatToInt(i32, pz.?),
                                    });

                                    m_fbs.reset();
                                    const goal_posx: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const goal_posz: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));

                                    while (true) {
                                        const current_n = pathctx.popLowestFOpen() orelse break;

                                        if (current_n.x == goal_posx and current_n.z == goal_posz) {
                                            var parent: ?*astar.AStarContext.Node = current_n;
                                            try move_vecs.resize(0);
                                            while (parent.?.parent != null) : (parent = parent.?.parent) {
                                                try move_vecs.append(
                                                    V3f.newi(parent.?.x, parent.?.y, parent.?.z).subtract(V3f.new(
                                                        //if (parent.?.x < 0) -0.5 else 0.5,
                                                        -0.5,
                                                        0,
                                                        -0.5,
                                                        //if (parent.?.z < 0) -0.5 else 0.5,
                                                        //0.5 * if (parent.?.y < 0) -1.0 else 1.0,
                                                    )),
                                                );
                                            }

                                            goal = move_vecs.pop();
                                            break;
                                        }

                                        var adj_open: [8]bool = undefined;
                                        for (ADJ) |a_vec, adj_i| {
                                            const bx = current_n.x + a_vec.x;
                                            const bz = current_n.z + a_vec.y;
                                            const by = current_n.y;
                                            const floor_block = world.getBlock(bx, by - 1, bz);
                                            const column = world.getBlock(bx, by, bz) | world.getBlock(bx, by + 1, bz);

                                            adj_open[adj_i] = (floor_block != 0 and column == 0);
                                        }

                                        adj_open[0] = adj_open[0] and adj_open[1] and adj_open[7];
                                        adj_open[2] = adj_open[2] and adj_open[1] and adj_open[3];
                                        adj_open[4] = adj_open[4] and adj_open[3] and adj_open[5];
                                        adj_open[6] = adj_open[6] and adj_open[5] and adj_open[7];

                                        for (adj_open) |adj, adj_i| {
                                            if (adj) {
                                                const avec = ADJ[adj_i];
                                                var new_node = astar.AStarContext.Node{
                                                    .x = current_n.x + avec.x,
                                                    .z = current_n.z + avec.y,
                                                    .y = current_n.y,
                                                    .G = ADJ_COST[adj_i] + current_n.G,
                                                    .H = @intCast(u32, try std.math.absInt(goal_posx - (current_n.x + avec.x)) +
                                                        try std.math.absInt(goal_posz - (current_n.z + avec.y))),
                                                };

                                                var is_on_closed = false;
                                                for (pathctx.closed.items) |cl| {
                                                    if (cl.x == new_node.x and cl.y == new_node.y and cl.z == new_node.z) {
                                                        is_on_closed = true;
                                                        //std.debug.print("CLOSED\n", .{});
                                                        break;
                                                    }
                                                }
                                                new_node.parent = current_n;
                                                if (!is_on_closed) {
                                                    var old_open: ?*astar.AStarContext.Node = null;
                                                    for (pathctx.open.items) |op| {
                                                        if (op.x == new_node.x and op.y == new_node.y and op.z == new_node.z) {
                                                            old_open = op;
                                                            //std.debug.print("EXISTS BEFORE\n", .{});
                                                            break;
                                                        }
                                                    }

                                                    if (old_open) |op| {
                                                        if (new_node.G < op.G) {
                                                            op.parent = current_n;
                                                            op.G = new_node.G;
                                                        }
                                                    } else {
                                                        try pathctx.addOpen(new_node);
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    //try mc.sendChat(&packet, server.writer(), m_fbs.getWritten());

                                    //var bi: i32 = -1;
                                    //while (bi < 2) : (bi += 1) {
                                    //    m_fbs.reset();
                                    //    const block_id = world.getBlockFloat(px.?, py.? + @intToFloat(f64, bi), pz.? + 1);
                                    //    try m_wr.print("Block: {s}", .{mc.findBlockNameFromId(block_ids, block_id)});
                                    //    try mc.sendChat(&packet, server.writer(), m_fbs.getWritten());
                                    //}
                                } else if (eql(u8, key, "bpe")) {
                                    const sec = world.getChunkSectionPtr(@floatToInt(i64, px.?), @floatToInt(i64, py.?), @floatToInt(i64, pz.?)).?;
                                    m_fbs.reset();
                                    try m_wr.print("Bits per entry: {d}", .{sec.bits_per_entry});
                                    try mc.sendChat(&packet, server.writer(), m_fbs.getWritten());
                                } else if (eql(u8, key, "moverel")) {
                                    {
                                        goal = V3f.new(
                                            px.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                            py.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                            pz.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                        );
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                    item.data.buffer.deinit();
                },
                .local => {
                    if (std.mem.eql(u8, "move", item.data.buffer.items[0 .. item.data.buffer.items.len - 1])) {
                        if (start_rot and px != null and py != null and pz != null) {
                            std.debug.print("Dump the chunk!\n", .{});
                            {
                                var jp: f64 = 0;
                                while (jp < 5) : (jp += 1) {
                                    const block_id = world.getBlockFloat(px.?, py.? - jp, pz.?);
                                    //const block_id = world.getBlock(0, 120, 0);
                                    std.debug.print("bLOCK ID {d}\n", .{block_id});
                                }

                                if (false) {
                                    const w = world.x.getPtr(0) orelse unreachable;
                                    const wz = w.getPtr(0) orelse unreachable;
                                    for (wz) |sec, cxi| {
                                        std.debug.print("CHUNK SECTION {d}\n", .{cxi});
                                        for (sec.data.items) |long| {
                                            var nn: u32 = 0;
                                            while (nn < 64) : (nn += 4) {
                                                const lc = long >> @intCast(u6, nn) & 0xf;
                                                std.debug.print("{d}\t", .{sec.mapping.items[lc]});
                                            }
                                            std.debug.print("\n", .{});
                                        }

                                        //var ix: i32 = 0;
                                        //var iy: i32 = 0;
                                        //var iz: i32 = 0;
                                        //while (iy < 16) : (iy += 1) {
                                        //    while (iz < 16) : (iz += 1) {
                                        //        while (ix < 16) : (ix += 1) {
                                        //            //const bl = world.getBlock(ix, iy, iz);
                                        //            std.debug.print("{d}\t", .{bl});
                                        //        }
                                        //        ix = 0;
                                        //        std.debug.print("\n", .{});
                                        //    }
                                        //    iz = 0;
                                        //    std.debug.print("---------\n", .{});
                                        //}
                                    }
                                }
                            }
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
