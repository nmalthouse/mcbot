const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

const nbt_zig = @import("nbt.zig");
const astar = @import("astar.zig");
const Bot = @import("bot.zig").Bot;

const math = std.math;

const vector = @import("vector.zig");
const V3f = vector.V3f;

const c = @import("c.zig").c;

pub const V2i = struct {
    x: i32,
    y: i32,
};

pub fn quadFGreater(a: f64, b: f64, C: f64) ?f64 {
    const disc = std.math.pow(f64, b, 2) - (4 * a * C);
    if (disc < 0) return null;
    return (-b + @sqrt(disc)) / (2 * a);
}

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

pub const MoveItem = struct {
    pub const MoveKind = enum {
        walk,
        fall,
        jump,
    };

    kind: MoveKind = .walk,
    pos: V3f,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    const server = blk: {
        const hosts_to_try = [_]struct { hostname: []const u8, port: u16 }{
            .{ .hostname = "localhost", .port = 25565 },
            .{ .hostname = "24.148.84.56", .port = 59438 },
        };
        for (hosts_to_try) |h| {
            const s = std.net.tcpConnectToHost(alloc, h.hostname, h.port) catch |err| switch (err) {
                error.ConnectionRefused => {
                    continue;
                },
                else => {
                    return err;
                },
            };
            std.debug.print("Connecting to: {s} : {d}\n", .{ h.hostname, h.port });
            break :blk s;
        }
        unreachable;
    };

    var block_table = try mc.BlockRegistry.init(alloc, "json/id_array.json", "json/block_info_array.json");
    defer block_table.deinit(alloc);

    var tag_table = mc.TagRegistry.init(alloc);
    defer tag_table.deinit();

    var world = mc.ChunkMap.init(alloc);
    defer world.deinit();

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
    defer server.close();

    var bot1 = Bot.init(alloc, "Tony");
    defer bot1.deinit();

    var cmd_thread = try std.Thread.spawn(
        .{},
        mc.cmdThread,
        .{ alloc, &queue, &q_cond },
    );
    defer cmd_thread.join();

    const swr = server.writer();
    var packet = try mc.Packet.init(alloc);
    try mc.handshake(&packet, swr, "localhost", 25565);
    try mc.loginStart(&packet, swr, bot1.name);

    var pathctx = astar.AStarContext.init(alloc);
    defer pathctx.deinit();

    var start_rot: bool = false;
    var player_id: ?u32 = null;

    var px: ?f64 = null;
    var py: ?f64 = null;
    var pz: ?f64 = null;

    var move_vecs = std.ArrayList(MoveItem).init(alloc);
    defer move_vecs.deinit();

    var complete_login = false;

    var do_move = true;
    var old_pos = V3f.new(0, 0, 0);

    var goal: ?MoveItem = null;
    const speed: f64 = 4; //BPS
    var draw = false;

    var maj_goal: ?V3f = null;
    var do_jump = false;
    var jump_timer: f64 = 0;

    if (draw) {
        c.InitWindow(1800, 1000, "Window");
    }
    //defer c.CloseWindow();

    //BEGIN RAYLIB
    var camera: c.Camera3D = undefined;
    camera.position = .{ .x = 15.0, .y = 10.0, .z = 15.0 }; // Camera position
    camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 }; // Camera looking at point
    camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 }; // Camera up vector (rotation towards target)
    camera.fovy = 90.0; // Camera field-of-view Y
    camera.projection = c.CAMERA_PERSPECTIVE;
    //c.DisableCursor();
    c.SetCameraMode(camera, c.CAMERA_FREE);

    var run = true;
    while (run) {
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
                        const color = switch (mv.kind) {
                            .walk => c.BLUE,
                            .jump => c.RED,
                            .fall => c.GREEN,
                        };
                        c.DrawCube(mv.pos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 0.3, 0.3, 0.3, color);
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

            const pow = std.math.pow;

            if (do_jump and false) {
                var new_y = (-16 * pow(f64, jump_timer - @sqrt(0.1), 2)) + 1.6;

                var grounded = false;
                if (jump_timer > 0 and new_y <= 0) {
                    grounded = true;
                    do_jump = false;
                    new_y = 0;
                }

                jump_timer += dt;

                try mc.setPlayerPositionRot(
                    &packet,
                    swr,
                    .{ .x = px.?, .y = py.? + new_y, .z = pz.? },
                    0,
                    0,
                    grounded,
                );
            } else {
                //do_jump = true;
                //jump_timer = 0;
            }
            if (goal) |gvec| {
                //goal = null;
                const pos = V3f.new(px.?, py.?, pz.?);
                const move_vec = gvec.pos.subtract(pos);
                switch (gvec.kind) {
                    .jump => {
                        const jump_speed = 1;
                        const mv = V3f.new(move_vec.x, 0, move_vec.z);
                        const dv = mv.getUnitVec().smul(jump_speed * dt);

                        const max_dt = quadFGreater(-16.0, 32.0 * @sqrt(0.1), -1) orelse unreachable; //Solve for y = 1
                        std.debug.print("MAX DT{d}\n", .{max_dt});
                        if (jump_timer + dt > max_dt) {
                            jump_timer = 0;
                            goal.?.kind = .walk; //Finish this move with a walk
                            py.? += 1;
                        } else {
                            jump_timer += dt;
                        }
                        px.? += dv.x;
                        pz.? += dv.z;

                        var new_y = (-16 * pow(f64, jump_timer - @sqrt(0.1), 2)) + 1.6;
                        std.debug.print("NEW {d}\n", .{new_y});
                        try mc.setPlayerPositionRot(
                            &packet,
                            swr,
                            .{ .x = px.?, .y = py.? + new_y, .z = pz.? },
                            0,
                            0,
                            false,
                        );
                    },
                    .fall => {},
                    .walk => {

                        //const max_dt = pow(f64, move_vec.magnitude(), 2);
                        const max_dt = move_vec.magnitude() / speed;

                        var dv = (move_vec.getUnitVec()).smul(speed * dt);
                        if ((max_dt) < dt) {
                            dv = (move_vec.getUnitVec()).smul(speed * max_dt);
                            goal = move_vecs.popOrNull();
                            jump_timer = 0;
                        }

                        px.? += dv.x;
                        py.? += dv.y;
                        pz.? += dv.z;
                        const pandw = mc.lookAtBlock(pos, V3f.new(11, 10, 32));

                        try mc.setPlayerPositionRot(
                            &packet,
                            swr,
                            .{ .x = px.?, .y = py.?, .z = pz.? },
                            pandw.yaw,
                            pandw.pitch,
                            true,
                        );
                    },
                }
            }
        }
        std.time.sleep(@floatToInt(u64, std.time.ns_per_s * (1.0 / 20.0)));
        //q_cond.wait(&q_mutex);
        while (queue.get()) |item| {
            var arena_allocs = std.heap.ArenaAllocator.init(alloc);
            defer arena_allocs.deinit();
            const arena_alloc = arena_allocs.allocator();
            defer alloc.destroy(item);
            defer item.data.buffer.deinit();
            switch (item.data.msg_type) {
                .server => {
                    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                    const reader = fbs.reader();
                    switch (@intToEnum(id_list.packet_enum, item.data.id)) {
                        .Keep_Alive => {
                            const kid = try reader.readInt(i64, .Big);
                            try mc.keepAlive(&packet, swr, kid);
                        },
                        .Login => {
                            std.debug.print("Login\n", .{});
                            const p_id = try reader.readInt(u32, .Big);
                            std.debug.print("\tid: {d}\n", .{p_id});
                            bot1.e_id = p_id;
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

                            try mc.pluginMessage(&packet, swr, "tony:brand");
                            try mc.clientInfo(&packet, swr, "en_US", 2, 1);
                        },
                        .Change_Difficulty => {
                            const diff = try reader.readByte();
                            const locked = try reader.readByte();
                            std.debug.print("Set difficulty: {d}, Locked: {d}\n", .{ diff, locked });
                        },
                        .Player_Abilities => {
                            std.debug.print("Player Abilities\n", .{});
                        },
                        .Feature_Flags => {
                            const num_feature = mc.readVarInt(reader);
                            var strbuf = std.ArrayList(u8).init(alloc);
                            defer strbuf.deinit();
                            std.debug.print("Feature_Flags: \n", .{});

                            var i: u32 = 0;
                            while (i < num_feature) : (i += 1) {
                                const str_len = mc.readVarInt(reader);
                                try strbuf.resize(@intCast(usize, str_len));
                                try reader.readNoEof(strbuf.items);
                                std.debug.print("\t{s}\n", .{strbuf.items});
                            }
                        },
                        .Player_Info_Update => {
                            const action_mask = try reader.readInt(u8, .Big);
                            const num_actions = mc.readVarInt(reader);
                            //std.debug.print("Player info update: \n", .{});

                            var i: u32 = 0;
                            while (i < num_actions) : (i += 1) {
                                const uuid = try reader.readInt(u128, .Big);
                                _ = uuid;
                                //std.debug.print("\tUUID: {d}\n", .{uuid});
                                if (action_mask & 0x01 == 1) { //Add player
                                    var strbuf = std.ArrayList(u8).init(alloc);
                                    defer strbuf.deinit();
                                    const str_len = mc.readVarInt(reader);
                                    try strbuf.resize(@intCast(usize, str_len));
                                    try reader.readNoEof(strbuf.items);
                                    //std.debug.print("\tPlayer: {s}\n", .{strbuf.items});

                                    const num_properties = mc.readVarInt(reader);
                                    var np: u32 = 0;
                                    while (np < num_properties) : (np += 1) {
                                        const slen = mc.readVarInt(reader);
                                        try strbuf.resize(@intCast(usize, slen));
                                        try reader.readNoEof(strbuf.items);
                                        //std.debug.print("\t\tProperty: {s}\n", .{strbuf.items});
                                        const vlen = mc.readVarInt(reader);
                                        try strbuf.resize(@intCast(usize, vlen));
                                        try reader.readNoEof(strbuf.items);
                                        //std.debug.print("\t\tValue: {s}\n", .{strbuf.items});
                                        const is_signed = try reader.readInt(u8, .Big);
                                        if (is_signed == 1) {
                                            const siglen = mc.readVarInt(reader);
                                            try strbuf.resize(@intCast(usize, siglen));
                                            try reader.readNoEof(strbuf.items);
                                        }
                                    }
                                }
                                if (action_mask & 0b10 != 0) {}
                                break;
                            }
                        },
                        .Game_Event => {
                            const Events = enum {
                                no_respawn_block,
                                end_rain,
                                begin_rain,
                                change_gamemode,
                                win_game,
                                demo,
                                arrow_hit_player,
                                rain_change,
                                thunder_change,
                                pufferfish,
                                elder_guardian,
                                respawn_screen,
                            };
                            const event_id = @intToEnum(Events, try reader.readInt(u8, .Big));
                            const value = @bitCast(f32, try reader.readInt(u32, .Big));
                            std.debug.print("Game event :{} {d}\n", .{ event_id, value });
                        },
                        .Set_Container_Content => {
                            const win_id = mc.readVarInt(reader);
                            const state_id = mc.readVarInt(reader);
                            const item_count = mc.readVarInt(reader);
                            _ = win_id;
                            _ = state_id;
                            //std.debug.print("Set Container content id: {d}, state: {d}, count: {d}\n", .{ win_id, state_id, item_count });
                            var i: u32 = 0;
                            while (i < item_count) : (i += 1) {
                                const item_present = try reader.readInt(u8, .Big);
                                if (item_present == 1) {
                                    const item_id = mc.readVarInt(reader);
                                    const count = try reader.readInt(u8, .Big);

                                    const nbt = try nbt_zig.parse(arena_alloc, reader);
                                    _ = item_id;
                                    _ = count;
                                    _ = nbt;
                                    //std.debug.print("\tItem:{d} id: {d}, count: {d}\n{}\n", .{
                                    //    i,
                                    //    item_id,
                                    //    count,
                                    //    nbt.entry,
                                    //});
                                }
                            }
                            { //Held item
                                const item_present = try reader.readInt(u8, .Big);
                                if (item_present == 1) {
                                    const item_id = mc.readVarInt(reader);
                                    const count = try reader.readInt(u8, .Big);
                                    const nbt = try nbt_zig.parse(arena_alloc, reader);
                                    _ = nbt;
                                    _ = count;
                                    _ = item_id;
                                    //std.debug.print("\tHeld Item:{d} id: {d}, count: {d}\n{}\n", .{
                                    //    i,
                                    //    item_id,
                                    //    count,
                                    //    nbt.entry,
                                    //});
                                }
                            }
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

                            try mc.confirmTeleport(&packet, swr, tel_id);

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
                        .Set_Health => {
                            bot1.health = @bitCast(f32, (try reader.readInt(u32, .Big)));
                            bot1.food = @intCast(u8, mc.readVarInt(reader));
                            bot1.food_saturation = @bitCast(f32, (try reader.readInt(u32, .Big)));
                        },
                        .Set_Entity_Metadata => {
                            const e_id = mc.readVarInt(reader);
                            std.debug.print("Set Entity Metadata: {d}\n", .{e_id});
                            if (e_id == bot1.e_id)
                                std.debug.print("\tFOR PLAYER\n", .{});

                            var index = try reader.readInt(u8, .Big);
                            while (index != 0xff) : (index = try reader.readInt(u8, .Big)) {
                                //std.debug.print("\tIndex {d}\n", .{index});
                                const metatype = @intToEnum(mc.MetaDataType, mc.readVarInt(reader));
                                //std.debug.print("\tMetadata: {}\n", .{metatype});
                                switch (metatype) {
                                    else => {
                                        //std.debug.print("\tENTITY METADATA TYPE NOT IMPLEMENTED\n", .{});
                                        break;
                                    },
                                }
                            }
                        },
                        .Update_Time => {},
                        .Update_Tags => {
                            const num_tags = mc.readVarInt(reader);

                            var identifier = std.ArrayList(u8).init(alloc);
                            defer identifier.deinit();

                            var n: u32 = 0;
                            while (n < num_tags) : (n += 1) {
                                const i_len = mc.readVarInt(reader);
                                try identifier.resize(@intCast(usize, i_len));
                                try reader.readNoEof(identifier.items);
                                { //TAG
                                    const n_tags = mc.readVarInt(reader);
                                    var nj: u32 = 0;

                                    var ident = std.ArrayList(u8).init(alloc);
                                    defer ident.deinit();

                                    while (nj < n_tags) : (nj += 1) {
                                        const l = mc.readVarInt(reader);
                                        try ident.resize(@intCast(usize, l));
                                        try reader.readNoEof(ident.items);
                                        const num_ids = mc.readVarInt(reader);

                                        var ids = std.ArrayList(u32).init(alloc);
                                        defer ids.deinit();
                                        try ids.resize(@intCast(usize, num_ids));
                                        var ni: u32 = 0;
                                        while (ni < num_ids) : (ni += 1)
                                            ids.items[ni] = @intCast(u32, mc.readVarInt(reader));
                                        try tag_table.addTag(identifier.items, ident.items, ids.items);
                                    }
                                }
                            }
                        },
                        .Chunk_Data_and_Update_Light => {
                            const cx = try reader.readInt(i32, .Big);
                            const cy = try reader.readInt(i32, .Big);

                            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, reader);
                            _ = nbt_data;
                            const data_size = mc.readVarInt(reader);
                            var chunk_data = std.ArrayList(u8).init(alloc);
                            defer chunk_data.deinit();
                            try chunk_data.resize(@intCast(usize, data_size));
                            try reader.readNoEof(chunk_data.items);

                            var chunk: mc.Chunk = undefined;
                            var chunk_i: u32 = 0;
                            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
                            const cr = chunk_fbs.reader();
                            //TODO determine number of chunk sections some other way
                            while (chunk_i < 16) : (chunk_i += 1) {

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
                        .System_Chat_Message => {
                            const chat_len = mc.readVarInt(reader);
                            var chat_buffer = std.ArrayList(u8).init(alloc);
                            defer chat_buffer.deinit();
                            try chat_buffer.resize(@intCast(usize, chat_len));
                            try reader.readNoEof(chat_buffer.items);
                            const is_actionbar = try reader.readInt(u8, .Big);
                            std.debug.print("System msg: {s} {d}\n", .{ chat_buffer.items, is_actionbar });
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
                                    const goal_posy: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const goal_posz: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));

                                    maj_goal = V3f.newi(
                                        goal_posx,
                                        goal_posy,
                                        goal_posz,
                                    );

                                    while (true) {
                                        const current_n = pathctx.popLowestFOpen() orelse break;

                                        if (current_n.x == goal_posx and current_n.z == goal_posz and current_n.y == goal_posy) {
                                            var parent: ?*astar.AStarContext.Node = current_n;
                                            try move_vecs.resize(0);
                                            var last_y = goal_posy;
                                            while (parent.?.parent != null) : (parent = parent.?.parent) {
                                                //if (last_y != parent.?.y) {
                                                //    try move_vecs.append(.{
                                                //    .pos =     V3f.newi(parent.?.x, last_y, parent.?.z).subtract(V3f.new(
                                                //            -0.5,
                                                //            0,
                                                //            -0.5,
                                                //        )),
                                                //    }
                                                //    );
                                                //}

                                                if (parent.?.y < last_y) {
                                                    move_vecs.items[move_vecs.items.len - 1].kind = .jump;
                                                } else if (parent.?.y > last_y) {
                                                    move_vecs.items[move_vecs.items.len - 1].kind = .fall;
                                                }
                                                try move_vecs.append(.{
                                                    //.kind = if (last_y != parent.?.y) .jump else .walk,
                                                    .pos = V3f.newi(parent.?.x, parent.?.y, parent.?.z).subtract(V3f.new(
                                                        -0.5,
                                                        0,
                                                        -0.5,
                                                    )),
                                                });
                                                last_y = parent.?.y;
                                            }

                                            if (!draw)
                                                goal = move_vecs.pop();
                                            jump_timer = 0;
                                            break;
                                        }

                                        var new_adj: [8][8]bool = undefined;

                                        //var adj_open: [8]bool = undefined;
                                        for (ADJ) |a_vec, adj_i| {
                                            const bx = current_n.x + a_vec.x;
                                            const bz = current_n.z + a_vec.y;
                                            const by = current_n.y;
                                            //const floor_block = world.getBlock(bx, by - 1, bz);
                                            //const column = world.getBlock(bx, by, bz) | world.getBlock(bx, by + 1, bz);

                                            //adj_open[adj_i] = (floor_block != 0 and column == 0);

                                            {
                                                var i: u32 = 0;
                                                while (i < 8) : (i += 1) {
                                                    new_adj[adj_i][i] = @bitCast(bool, world.getBlock(bx, by - 2 + @intCast(i32, i), bz) != 0);
                                                }
                                            }
                                        }
                                        //Four types of nodes to check
                                        //strait
                                        //diagonal //just fagat
                                        //jump
                                        //drop
                                        //
                                        //1 3 5 7
                                        { //This is the strait
                                            //const indicis = [_]usize{ 1, 3, 5, 7 };
                                            for (new_adj) |adj, adj_i| {

                                                //if (std.mem.indexOfScalar(usize, &indicis, adj_i) == null)
                                                //    continue;

                                                var y_offset: i32 = 0;
                                                if (adj[1] and !adj[2] and !adj[3]) { //Is it free to walk into
                                                    //add the node
                                                    y_offset = 0;
                                                } else if (adj[2] and !adj[3] and !adj[4]) { //We can jump
                                                    y_offset = 1;
                                                } else if (adj[0] and !adj[1] and !adj[2] and !adj[3]) { //We can drop onto this block
                                                    y_offset = -1;
                                                } else {
                                                    continue;
                                                }

                                                if (@mod(adj_i, 2) == 0) {
                                                    const l_i = @intCast(u32, @mod(@intCast(i32, adj_i) - 1, 8));
                                                    const r_i = @mod(adj_i + 1, 8);
                                                    if (y_offset == 0) {
                                                        const l = new_adj[l_i];
                                                        const r = new_adj[r_i];
                                                        if ((l[1] and !l[2] and !l[3]) and (r[1] and !r[2] and !r[3])) {
                                                            //continue;
                                                        } else {
                                                            continue;
                                                        }
                                                    } else {
                                                        continue;
                                                    }
                                                }

                                                {
                                                    const avec = ADJ[adj_i];
                                                    var new_node = astar.AStarContext.Node{
                                                        .x = current_n.x + avec.x,
                                                        .z = current_n.z + avec.y,
                                                        .y = current_n.y + y_offset,
                                                        .G = ADJ_COST[adj_i] + current_n.G + @intCast(u32, (try std.math.absInt(y_offset)) * 1),
                                                        //TODO fix the hurestic
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

                                        //for (adj_open) |adj, adj_i| {
                                        //    if (adj) {
                                        //        const avec = ADJ[adj_i];
                                        //        var new_node = astar.AStarContext.Node{
                                        //            .x = current_n.x + avec.x,
                                        //            .z = current_n.z + avec.y,
                                        //            .y = current_n.y,
                                        //            .G = ADJ_COST[adj_i] + current_n.G,
                                        //            .H = @intCast(u32, try std.math.absInt(goal_posx - (current_n.x + avec.x)) +
                                        //                try std.math.absInt(goal_posz - (current_n.z + avec.y))),
                                        //        };

                                        //        var is_on_closed = false;
                                        //        for (pathctx.closed.items) |cl| {
                                        //            if (cl.x == new_node.x and cl.y == new_node.y and cl.z == new_node.z) {
                                        //                is_on_closed = true;
                                        //                //std.debug.print("CLOSED\n", .{});
                                        //                break;
                                        //            }
                                        //        }
                                        //        new_node.parent = current_n;
                                        //        if (!is_on_closed) {
                                        //            var old_open: ?*astar.AStarContext.Node = null;
                                        //            for (pathctx.open.items) |op| {
                                        //                if (op.x == new_node.x and op.y == new_node.y and op.z == new_node.z) {
                                        //                    old_open = op;
                                        //                    //std.debug.print("EXISTS BEFORE\n", .{});
                                        //                    break;
                                        //                }
                                        //            }

                                        //            if (old_open) |op| {
                                        //                if (new_node.G < op.G) {
                                        //                    op.parent = current_n;
                                        //                    op.G = new_node.G;
                                        //                }
                                        //            } else {
                                        //                try pathctx.addOpen(new_node);
                                        //            }
                                        //        }
                                        //    }
                                        //}
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
                                        goal = .{ .pos = V3f.new(
                                            px.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                            py.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                            pz.? + @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                        ) };
                                    }
                                } else if (eql(u8, key, "lookat")) {
                                    const v = V3f.new(
                                        @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                        @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                        @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
                                    );
                                    const pw = mc.lookAtBlock(V3f.new(px.?, py.?, pz.?), v);
                                    try mc.setPlayerPositionRot(&packet, swr, V3f.new(px.?, py.?, pz.?), pw.yaw, pw.pitch, true);
                                } else if (eql(u8, key, "jump")) {
                                    if (do_jump == false) {
                                        try mc.sendChat(&packet, server.writer(), "jumping");
                                        do_jump = true;
                                        jump_timer = 0;
                                    }
                                } else if (eql(u8, key, "query")) {
                                    const qbx: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const qby: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const qbz: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));

                                    const bid = world.getBlock(qbx, qby, qbz);
                                    m_fbs.reset();
                                    try m_wr.print("Block {s} id: {d}", .{
                                        block_table.findBlockName(bid),
                                        bid,
                                    });
                                    try mc.sendChat(&packet, server.writer(), m_fbs.getWritten());
                                }
                            }
                        },
                        else => {
                            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, item.data.id)]});
                        },
                    }
                },
                .local => {
                    if (std.mem.eql(u8, "exit", item.data.buffer.items[0 .. item.data.buffer.items.len - 1])) {
                        run = false;
                    }
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
                },
            }
        }
    }

    //const out = try std.fs.cwd().createFile("out.dump", .{});
    //defer out.close();
    //_ = try out.write(packet.getWritableBuffer());

    packet.deinit();
}
