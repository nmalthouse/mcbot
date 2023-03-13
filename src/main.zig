const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

const nbt_zig = @import("nbt.zig");
const astar = @import("astar.zig");
const bot = @import("bot.zig");
const Bot = bot.Bot;

const math = std.math;

const vector = @import("vector.zig");
const V3f = vector.V3f;

const c = @import("c.zig").c;

pub const V2i = struct {
    x: i32,
    y: i32,
};

pub fn parseCoord(it: *std.mem.TokenIterator(u8)) !vector.V3f {
    return .{
        .x = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
        .y = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
        .z = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
    };
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
    //var packet = try mc.Packet.init(alloc);
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = swr };
    defer pctx.packet.deinit();
    try pctx.handshake("localhost", 25565);
    try pctx.loginStart(bot1.name);

    var pathctx = astar.AStarContext.init(alloc, &world, &tag_table, &block_table);
    defer pathctx.deinit();

    var start_rot: bool = false;

    var move_vecs = std.ArrayList(astar.AStarContext.MoveItem).init(alloc);
    defer move_vecs.deinit();

    var goal: ?astar.AStarContext.MoveItem = null;
    const speed: f64 = 5; //BPS
    var draw = false;

    var maj_goal: ?V3f = null;

    var move_state: bot.MovementState = undefined;

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

            if (bot1.pos != null) {
                const playerpos = bot1.pos.?;
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
                            .ladder => c.BLACK,
                            .walk => c.BLUE,
                            .jump => c.RED,
                            .fall => c.GREEN,
                            else => unreachable,
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

        if (bot1.pos != null) {
            //TODO use actual dt
            const dt: f64 = 1.0 / 20.0;

            //const pow = std.math.pow;
            var adt = dt;
            var grounded = true;
            var moved = false;
            while (true) {
                if (goal) |gvec| {
                    var move_vec = blk: {
                        switch (gvec.kind) {
                            .walk => {
                                break :blk move_state.walk(speed, adt);
                            },
                            .jump => break :blk move_state.jump(speed, adt),
                            .fall => break :blk move_state.fall(speed, adt),
                            .ladder => break :blk move_state.ladder(2.35, adt),
                            .blocked => unreachable,

                            //else => {
                            //    unreachable;
                            //},
                        }
                    };
                    grounded = move_vec.grounded;

                    bot1.pos = move_vec.new_pos;
                    moved = true;

                    if (!move_vec.move_complete) {
                        break;
                    } else {
                        goal = move_vecs.popOrNull();
                        adt = move_vec.remaining_dt;
                        if (goal) |g| {
                            move_state.init_pos = move_vec.new_pos;
                            move_state.final_pos = g.pos;
                            move_state.time = 0;
                        } else {
                            break;
                        }
                    }
                    //move_vec = //above switch statement

                } else {
                    break;
                }
            }
            if (moved)
                try pctx.setPlayerPositionRot(bot1.pos.?, 0, 0, grounded);
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
                            try pctx.keepAlive(kid);
                        },
                        .Login => {
                            std.debug.print("Login\n", .{});
                            const p_id = try reader.readInt(u32, .Big);
                            std.debug.print("\tid: {d}\n", .{p_id});
                            bot1.e_id = p_id;
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

                            try pctx.pluginMessage("tony:brand");
                            try pctx.clientInfo("en_US", 6, 1);
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
                            bot1.pos = .{ .x = x, .y = y, .z = z };

                            try pctx.confirmTeleport(tel_id);

                            if (bot1.handshake_complete == false) {
                                bot1.handshake_complete = true;
                                try pctx.completeLogin();
                            }
                        },
                        .Update_Entity_Position, .Update_Entity_Position_and_Rotation, .Update_Entity_Rotation => {
                            const ent_id = mc.readVarInt(reader);
                            _ = ent_id;
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
                            //std.debug.print("Set Entity Metadata: {d}\n", .{e_id});
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
                            //TODO Does this packet replace all the tags or does it append to an existing
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
                                        //std.debug.print("{s}: {s}: {any}\n", .{ identifier.items, ident.items, ids.items });
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
                                    const goal_posx: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const goal_posy: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    const goal_posz: i32 = @intCast(i32, try std.fmt.parseInt(i64, it.next() orelse "0", 0));
                                    maj_goal = V3f.newi(goal_posx, goal_posy, goal_posz);
                                    try pathctx.pathfind(bot1.pos.?, maj_goal.?, &move_vecs);
                                    if (!draw) {
                                        goal = move_vecs.pop();
                                        if (goal) |g| {
                                            move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = g.pos, .time = 0 };
                                        }
                                    }
                                } else if (eql(u8, key, "bpe")) {} else if (eql(u8, key, "moverel")) {} else if (eql(u8, key, "lookat")) {
                                    const v = try parseCoord(&it);
                                    const pw = mc.lookAtBlock(bot1.pos.?, v);
                                    try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                                } else if (eql(u8, key, "jump")) {} else if (eql(u8, key, "query")) {
                                    const qb = (try parseCoord(&it)).toI();
                                    const bid = world.getBlock(qb.x, qb.y, qb.z);
                                    m_fbs.reset();
                                    try m_wr.print("Block {s} id: {d}", .{
                                        block_table.findBlockName(bid),
                                        bid,
                                    });
                                    try pctx.sendChat(m_fbs.getWritten());
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
                },
            }
        }
    }

    //pctx.deinit();
}
