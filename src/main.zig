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

const fbsT = std.io.FixedBufferStream([]const u8);

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
    bot1.connection_state = .login;

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

            var fbs_ = blk: {
                var in_stream = fbsT{ .buffer = item.data.buffer.items, .pos = 0 };
                if (bot1.compression_threshold) |thresh| {
                    if (item.data.len >= thresh) {
                        const data_len = @intCast(u32, mc.readVarInt(in_stream.reader()));
                        if (data_len != 0) {
                            std.debug.print("Parsing Compressed comp_len: {d}, len: {d}: ratio {d} \n", .{
                                item.data.buffer.items.len,
                                data_len,

                                @divTrunc(data_len, item.data.buffer.items.len),
                            });

                            var zlib_stream = try std.compress.zlib.zlibStream(alloc, in_stream.reader());
                            defer zlib_stream.deinit();
                            const buf = try zlib_stream.reader().readAllAlloc(alloc, std.math.maxInt(usize));
                            item.data.buffer.deinit();
                            item.data.buffer = std.ArrayList(u8).fromOwnedSlice(alloc, buf);
                            in_stream.buffer = item.data.buffer.items;
                            in_stream.pos = 0;
                        }
                    }
                    _ = mc.readVarInt(in_stream.reader());
                }
                item.data.id = mc.readVarInt(in_stream.reader());
                break :blk in_stream;
            };

            //var fbs_ = fbsT{ .buffer = item.data.buffer.items, .pos = 0 };
            const parseT = mc.packetParseCtx(fbsT.Reader);
            var parse = parseT.init(fbs_.reader(), arena_alloc);

            switch (bot1.connection_state) {
                .none => {},
                .login => switch (item.data.msg_type) {
                    .server => {
                        //var fbs = std.io.FixedBufferStream([]const u8){ .buffer = item.data.buffer.items, .pos = 0 };
                        //const reader = fbs.reader();
                        switch (@intToEnum(id_list.login_packet_enum, item.data.id)) {
                            .Disconnect => {
                                const reason = try parse.string(null);
                                std.debug.print("Disconnected: {s}\n", .{reason});
                            },
                            .Set_Compression => {
                                const threshold = parse.varInt();
                                std.debug.print("Setting Compression threshhold: {d}\n", .{threshold});
                                if (threshold < 0) {
                                    unreachable;
                                } else {
                                    bot1.compression_threshold = @intCast(u32, threshold);
                                }
                            },
                            .Encryption_Request => {
                                const server_id = try parse.string(20);
                                const public_key = try parse.string(null);
                                const verify_token = try parse.string(null);
                                std.debug.print("Encryption_request: {any} {any} {any} EXITING\n", .{ server_id, public_key, verify_token });
                                unreachable;
                            },
                            .Login_Success => {
                                const uuid = parse.int(u128);
                                const username = try parse.string(16);
                                const n_props = @intCast(u32, parse.varInt());
                                std.debug.print("Login Success: {d}: {s}\nPropertes:\n", .{ uuid, username });
                                var n: u32 = 0;
                                while (n < n_props) : (n += 1) {
                                    const prop_name = try parse.string(null);
                                    const value = try parse.string(null);
                                    if (parse.boolean()) {
                                        const sig = try parse.string(null);
                                        _ = sig;
                                    }
                                    std.debug.print("\t{s}: {s}\n", .{ prop_name, value });
                                }

                                bot1.connection_state = .play;
                            },
                            else => {},
                        }
                    },
                    else => {},
                },
                .play => switch (item.data.msg_type) {
                    .server => {
                        switch (@intToEnum(id_list.packet_enum, item.data.id)) {
                            .Keep_Alive => {
                                const kid = parse.int(i64);
                                try pctx.keepAlive(kid);
                            },
                            .Login => {
                                std.debug.print("Login\n", .{});
                                const p_id = parse.int(u32);
                                std.debug.print("\tid: {d}\n", .{p_id});
                                bot1.e_id = p_id;
                                start_rot = true;
                            },
                            .Plugin_Message => {
                                const channel_name = try parse.string(null);
                                std.debug.print("Plugin Message: {s}\n", .{channel_name});

                                try pctx.pluginMessage("tony:brand");
                                try pctx.clientInfo("en_US", 6, 1);
                            },
                            .Change_Difficulty => {
                                const diff = parse.int(u8);
                                const locked = parse.int(u8);
                                std.debug.print("Set difficulty: {d}, Locked: {d}\n", .{ diff, locked });
                            },
                            .Player_Abilities => {
                                std.debug.print("Player Abilities\n", .{});
                            },
                            .Feature_Flags => {
                                const num_feature = parse.varInt();
                                std.debug.print("Feature_Flags: \n", .{});

                                var i: u32 = 0;
                                while (i < num_feature) : (i += 1) {
                                    const feat = try parse.string(null);
                                    std.debug.print("\t{s}\n", .{feat});
                                }
                            },
                            .Set_Container_Content => {
                                //const win_id = mc.readVarInt(reader);
                                //const state_id = mc.readVarInt(reader);
                                //const item_count = mc.readVarInt(reader);
                                //_ = win_id;
                                //_ = state_id;
                                ////std.debug.print("Set Container content id: {d}, state: {d}, count: {d}\n", .{ win_id, state_id, item_count });
                                //var i: u32 = 0;
                                //while (i < item_count) : (i += 1) {
                                //    const item_present = try reader.readInt(u8, .Big);
                                //    if (item_present == 1) {
                                //        const item_id = mc.readVarInt(reader);
                                //        const count = try reader.readInt(u8, .Big);

                                //        const nbt = try nbt_zig.parse(arena_alloc, reader);
                                //        _ = item_id;
                                //        _ = count;
                                //        _ = nbt;
                                //        //std.debug.print("\tItem:{d} id: {d}, count: {d}\n{}\n", .{
                                //        //    i,
                                //        //    item_id,
                                //        //    count,
                                //        //    nbt.entry,
                                //        //});
                                //    }
                                //}
                                //{ //Held item
                                //    const item_present = try reader.readInt(u8, .Big);
                                //    if (item_present == 1) {
                                //        const item_id = mc.readVarInt(reader);
                                //        const count = try reader.readInt(u8, .Big);
                                //        const nbt = try nbt_zig.parse(arena_alloc, reader);
                                //        _ = nbt;
                                //        _ = count;
                                //        _ = item_id;
                                //        //std.debug.print("\tHeld Item:{d} id: {d}, count: {d}\n{}\n", .{
                                //        //    i,
                                //        //    item_id,
                                //        //    count,
                                //        //    nbt.entry,
                                //        //});
                                //    }
                                //}
                            },
                            //.Spawn_Entity => {
                            //    const ent_id = mc.readVarInt(reader);
                            //    const uuid = try reader.readInt(u128, .Big);

                            //    const type_id = mc.readVarInt(reader);
                            //    const x = @bitCast(f64, try reader.readInt(u64, .Big));
                            //    const y = @bitCast(f64, try reader.readInt(u64, .Big));
                            //    const z = @bitCast(f64, try reader.readInt(u64, .Big));
                            //    std.debug.print("Ent id: {d}, {x}, {d}\n\tx: {d}, y: {d} z: {d}\n", .{ ent_id, uuid, type_id, x, y, z });
                            //},
                            .Synchronize_Player_Position => {
                                const pos = parse.v3f();
                                const yaw = parse.float(f32);
                                const pitch = parse.float(f32);
                                const flags = parse.int(u8);
                                const tel_id = parse.varInt();
                                const should_dismount = parse.boolean();
                                _ = should_dismount;
                                std.debug.print(
                                    "Sync pos: x: {d}, y: {d}, z: {d}, yaw {d}, pitch : {d} flags: {b}, tel_id: {}\n",
                                    .{ pos.x, pos.y, pos.z, yaw, pitch, flags, tel_id },
                                );
                                bot1.pos = pos;

                                try pctx.confirmTeleport(tel_id);

                                if (bot1.handshake_complete == false) {
                                    bot1.handshake_complete = true;
                                    try pctx.completeLogin();
                                }
                            },
                            .Update_Entity_Position, .Update_Entity_Position_and_Rotation, .Update_Entity_Rotation => {
                                //const ent_id = mc.readVarInt(reader);
                                //_ = ent_id;
                            },
                            .Block_Update => {
                                const pos = parse.int(i64);
                                const bx = pos >> 38;
                                const by = pos << 52 >> 52;
                                const bz = pos << 26 >> 38;

                                const new_id = parse.varInt();
                                try world.setBlock(bx, by, bz, @intCast(mc.BLOCK_ID_INT, new_id));

                                std.debug.print("Block update {d} {d} {d} : {d}\n", .{ bx, by, bz, new_id });
                            },
                            .Set_Health => {
                                bot1.health = parse.float(f32);
                                bot1.food = @intCast(u8, parse.varInt());
                                bot1.food_saturation = parse.float(f32);
                            },
                            .Set_Entity_Metadata => {
                                const e_id = parse.varInt();
                                //std.debug.print("Set Entity Metadata: {d}\n", .{e_id});
                                if (e_id == bot1.e_id)
                                    std.debug.print("\tFOR PLAYER\n", .{});

                                var index = parse.int(u8);
                                while (index != 0xff) : (index = parse.int(u8)) {
                                    //std.debug.print("\tIndex {d}\n", .{index});
                                    const metatype = @intToEnum(mc.MetaDataType, parse.varInt());
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
                                const num_tags = parse.varInt();

                                var n: u32 = 0;
                                while (n < num_tags) : (n += 1) {
                                    const identifier = try parse.string(null);
                                    { //TAG
                                        const n_tags = parse.varInt();
                                        var nj: u32 = 0;

                                        while (nj < n_tags) : (nj += 1) {
                                            const ident = try parse.string(null);
                                            const num_ids = parse.varInt();

                                            var ids = std.ArrayList(u32).init(alloc);
                                            defer ids.deinit();
                                            try ids.resize(@intCast(usize, num_ids));
                                            var ni: u32 = 0;
                                            while (ni < num_ids) : (ni += 1)
                                                ids.items[ni] = @intCast(u32, parse.varInt());
                                            //std.debug.print("{s}: {s}: {any}\n", .{ identifier.items, ident.items, ids.items });
                                            try tag_table.addTag(identifier, ident, ids.items);
                                        }
                                    }
                                }
                            },
                            .Chunk_Data_and_Update_Light => {
                                const cx = parse.int(i32);
                                const cy = parse.int(i32);

                                var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
                                _ = nbt_data;
                                const data_size = parse.varInt();
                                var chunk_data = std.ArrayList(u8).init(alloc);
                                defer chunk_data.deinit();
                                try chunk_data.resize(@intCast(usize, data_size));
                                try parse.reader.readNoEof(chunk_data.items);

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

                                const num_block_ent = parse.varInt();
                                _ = num_block_ent;
                            },
                            .System_Chat_Message => {
                                const msg = try parse.string(null);
                                const is_actionbar = parse.boolean();
                                std.debug.print("System msg: {s} {}\n", .{ msg, is_actionbar });
                            },
                            .Player_Chat_Message => {
                                { //HEADER
                                    const uuid = parse.int(u128);
                                    const index = parse.varInt();
                                    const sig_present_bool = parse.boolean();
                                    _ = index;
                                    _ = uuid;
                                    //std.debug.print("Chat from UUID: {d} {d}\n", .{ uuid, index });
                                    //std.debug.print("sig_present {any}\n", .{sig_present_bool});
                                    if (sig_present_bool) {
                                        std.debug.print("NOT SUPPORTED \n", .{});
                                        unreachable;
                                    }

                                    const msg = try parse.string(null);
                                    const eql = std.mem.eql;

                                    var msg_buffer: [256]u8 = undefined;
                                    var m_fbs = std.io.FixedBufferStream([]u8){ .buffer = &msg_buffer, .pos = 0 };
                                    const m_wr = m_fbs.writer();

                                    var it = std.mem.tokenize(u8, msg, " ");

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
                                std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, item.data.id)]});
                            },
                        }
                    },
                    .local => {
                        if (std.mem.eql(u8, "exit", item.data.buffer.items[0 .. item.data.buffer.items.len - 1])) {
                            run = false;
                        }
                    },
                },
            }
        }
    }

    //pctx.deinit();
}
