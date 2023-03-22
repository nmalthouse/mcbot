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
const V3i = vector.V3i;
const V2i = vector.V2i;

const Parse = @import("parser.zig");

const c = @import("c.zig").c;

const fbsT = std.io.FixedBufferStream([]const u8);
//Mc data registryies
//
//Blocks:
//32 uniq hardness values, including none
//same for resistance
//3 unique stackSize: 1 16 64
//16 unique materials
//3 filter light
//12 emit light

//

//pub const Block = struct {
//    pub const Material = enum {
//        pickaxe,
//        axe,
//        shovel,
//        default,
//    };
//
//    id: u16,
//    name: []const u8,
//    hardness: f32,
//    resistance: f32,
//    stack_size: u8,
//    material: Material,
//    transparent: bool,
//    diggable: bool,
//    defaultState: u16,
//    minState: u16,
//    maxState: u16,
//    drops: []const u16,
//    harvest_tools: []const u16,
//};

//This structure should contain all data related to minecraft required for our bot
pub const DataReg = struct {
    pub const ItemId = u16;
    pub const BlockId = u16;

    pub const Material = struct {
        pub const Tool = struct {
            item_id: ItemId,
            multiplier: f32,
        };

        name: []const u8,
        tools: []const Tool,
    };

    pub const Item = struct {
        id: ItemId,
        name: []const u8,
        stack_size: u8,
    };

    pub const Block = struct {
        id: BlockId,
        name: []const u8,
        hardness: f32,
        resistance: f32,
        stack_size: u8,
        diggable: bool,
        material_i: u8,
        transparent: bool,
        default_state: BlockId,
        min_state: BlockId,
        max_state: BlockId,
        //TODO handle block states
    };

    blocks: []const Block, //Block information indexed by block id
    materials: []const Material, //indexed by material id
    items: []const Item,
};

pub fn parseCoordOpt(it: *std.mem.TokenIterator(u8)) ?vector.V3f {
    var ret = V3f{
        .x = @intToFloat(f64, std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null),
        .y = @intToFloat(f64, std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null),
        .z = @intToFloat(f64, std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null),
    };
    return ret;
}

pub fn parseCoord(it: *std.mem.TokenIterator(u8)) !vector.V3f {
    return .{
        .x = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
        .y = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
        .z = @intToFloat(f64, try std.fmt.parseInt(i64, it.next() orelse "0", 0)),
    };
}

//TODO deal with entity table

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

pub const Entity = struct {
    uuid: u128,
    pos: V3f,
    yaw: f32,
    pitch: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    //errdefer _ = gpa.detectLeaks();
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
        std.debug.print("Unable to connect to anything\n", .{});
        return error.noServers;
    };

    var item_table = try mc.ItemRegistry.init(alloc, "json/items.json");
    defer item_table.deinit();
    std.debug.print("{s}\n", .{item_table.getName(1)});

    var block_table = try mc.BlockRegistry.init(alloc, "json/id_array.json", "json/block_info_array.json");
    defer block_table.deinit(alloc);

    var tag_table = mc.TagRegistry.init(alloc);
    defer tag_table.deinit();

    var world = mc.ChunkMap.init(alloc);
    defer world.deinit();

    var bot1 = Bot.init(alloc, "Tony");
    defer bot1.deinit();

    var entities = std.AutoHashMap(i32, Entity).init(alloc);
    defer entities.deinit();

    const swr = server.writer();
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = swr };
    defer pctx.packet.deinit();
    {
        try pctx.handshake("localhost", 25565);
        try pctx.loginStart(bot1.name);
        bot1.connection_state = .login;
        var arena_allocs = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocs.deinit();
        const arena_alloc = arena_allocs.allocator();
        var comp_thresh: i32 = -1;

        while (bot1.connection_state == .login) {
            const pd = try mc.recvPacket(alloc, server.reader(), comp_thresh);
            defer alloc.free(pd);
            var fbs_ = fbsT{ .buffer = pd, .pos = 0 };
            const parseT = mc.packetParseCtx(fbsT.Reader);
            var parse = parseT.init(fbs_.reader(), arena_alloc);
            const pid = parse.varInt();
            switch (@intToEnum(id_list.login_packet_enum, pid)) {
                .Disconnect => {
                    const reason = try parse.string(null);
                    std.debug.print("Disconnected: {s}\n", .{reason});
                },
                .Set_Compression => {
                    const threshold = parse.varInt();
                    comp_thresh = threshold;
                    std.debug.print("Setting Compression threshhold: {d}\n", .{threshold});
                    if (threshold < 0) {
                        unreachable;
                    } else {
                        bot1.compression_threshold = threshold;
                        pctx.packet.comp_thresh = threshold;
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
        }
    }

    var niklas_id: ?i32 = 0;
    const max_niklas_cooldown: f64 = 0.2;
    var niklas_cooldown: f64 = 0;

    var q_cond: std.Thread.Condition = .{};
    var q_mutex: std.Thread.Mutex = .{};
    q_mutex.lock();
    var queue = mc.PacketQueueType.init();
    var listener_thread = try std.Thread.spawn(
        .{},
        mc.ServerListener.parserThread,
        .{ alloc, server.reader(), &queue, &q_cond, bot1.compression_threshold },
    );
    //defer listener_thread.join();
    defer server.close();

    var cmd_thread = try std.Thread.spawn(
        .{},
        mc.cmdThread,
        .{ alloc, &queue, &q_cond },
    );
    _ = cmd_thread;
    _ = listener_thread;
    //defer cmd_thread.join();

    var pathctx = astar.AStarContext.init(alloc, &world, &tag_table, &block_table);
    defer pathctx.deinit();

    var player_actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(alloc);
    defer player_actions.deinit();

    var current_action: ?astar.AStarContext.PlayerActionItem = null;

    const speed: f64 = 7; //BPS
    var draw = false;

    var maj_goal: ?V3f = null;

    var move_state: bot.MovementState = undefined;

    var block_break_timer: ?f64 = null;

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
                    const pi = playerpos.toI();
                    const section = world.getChunkSectionPtr(playerpos.toI());
                    const cc = mc.ChunkMap.getChunkCoord(playerpos.toI());

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
                        const offset = pi.add(V3i.new(adj.x * 16, 0, adj.y * 16));
                        const section1 = world.getChunkSectionPtr(offset);
                        const cc1 = mc.ChunkMap.getChunkCoord(offset);
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

                    for (player_actions.items) |act| {
                        switch (act) {
                            .movement => |mv| {
                                const color = switch (mv.kind) {
                                    .ladder => c.BLACK,
                                    .walk => c.BLUE,
                                    .jump => c.RED,
                                    .fall => c.GREEN,
                                    else => unreachable,
                                };
                                c.DrawCube(mv.pos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 0.3, 0.3, 0.3, color);
                            },
                            else => {},
                        }
                    }

                    //for (pathctx.closed.items) |op| {
                    //    const w = 0.3;
                    //    c.DrawCube(
                    //        V3f.newi(op.x, op.y, op.z).toRay(),
                    //        w,
                    //        w,
                    //        w,
                    //        c.BLUE,
                    //    );
                    //}
                }
                c.DrawCube(playerpos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 1.0, 1.0, 1.0, c.RED);
            }

            c.DrawGrid(10, 1.0);

            c.EndMode3D();

            c.EndDrawing();
        }

        if (bot1.handshake_complete) {
            const dt: f64 = 1.0 / 20.0;
            if (current_action) |action| {
                switch (action) {
                    .movement => |move_| {
                        var move = move_;
                        var adt = dt;
                        var grounded = true;
                        var moved = false;
                        var pw = mc.lookAtBlock(bot1.pos.?, move.pos.add(V3f.new(0, 0.6, 0)));
                        while (true) {
                            var move_vec = blk: {
                                switch (move.kind) {
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
                                if (player_actions.items.len > 0) {
                                    switch (player_actions.items[player_actions.items.len - 1]) {
                                        .movement => {
                                            adt = move_vec.remaining_dt;
                                            current_action = player_actions.pop();
                                            move = current_action.?.movement;
                                            move_state.init_pos = move_vec.new_pos;
                                            move_state.final_pos = move.pos;
                                            move_state.time = 0;
                                        },
                                        else => {
                                            current_action = player_actions.pop();
                                            if (current_action) |acc| {
                                                switch (acc) {
                                                    .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                                    .block_break => block_break_timer = null,
                                                }
                                            }
                                            break;
                                        },
                                    }
                                } else {
                                    current_action = null;
                                    break;
                                }
                            }
                            //move_vec = //above switch statement
                        }
                        if (moved) {
                            try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, grounded);
                        }
                    },
                    .block_break => |bb| {
                        if (block_break_timer == null) {
                            const pw = mc.lookAtBlock(bot1.pos.?, bb.pos.toF());
                            try pctx.setPlayerRot(pw.yaw, pw.pitch, true);
                            try pctx.playerAction(.start_digging, bb.pos);
                            block_break_timer = dt;
                        } else {
                            block_break_timer.? += dt;
                            if (block_break_timer.? >= bb.break_time) {
                                block_break_timer = null;
                                try pctx.playerAction(.finish_digging, bb.pos);
                                current_action = player_actions.popOrNull();
                                if (current_action) |acc| {
                                    switch (acc) {
                                        .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                        .block_break => block_break_timer = null,
                                    }
                                }
                            }
                        }
                    },
                }
            } else {
                if (niklas_id) |nid| {
                    niklas_cooldown += dt;
                    if (niklas_cooldown > max_niklas_cooldown) {
                        if (entities.get(nid)) |ne| {
                            const pw = mc.lookAtBlock(bot1.pos.?, ne.pos.add(V3f.new(-0.3, 1, -0.3)));
                            try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                        }
                        niklas_cooldown = 0;
                    }
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

            var fbs_ = fbsT{ .buffer = item.data.buffer.items, .pos = 0 };
            const parseT = mc.packetParseCtx(fbsT.Reader);
            var parse = parseT.init(fbs_.reader(), arena_alloc);

            const parseTr = Parse.packetParseCtx(fbsT.Reader);
            var parser = parseTr.init(fbs_.reader(), arena_alloc);

            const pid = parse.varInt();

            const P = Parse.P;
            const PT = Parse.parseType;

            switch (bot1.connection_state) {
                else => {},
                .play => switch (item.data.msg_type) {
                    .server => {
                        switch (@intToEnum(id_list.packet_enum, pid)) {
                            .Keep_Alive => {
                                const data = parser.parse(PT(&.{P(.long, "keep_alive_id")}));

                                try pctx.keepAlive(data.keep_alive_id);
                            },
                            .Login => {
                                const data = parser.parse(PT(&.{
                                    P(.int, "ent_id"),
                                    P(.boolean, "is_hardcore"),
                                    P(.ubyte, "gamemode"),
                                    P(.byte, "prev_gamemode"),
                                    P(.stringList, "dimension_names"),
                                    P(.nbtTag, "reg"),
                                    P(.identifier, "dimension_type"),
                                    P(.identifier, "dimension_name"),
                                    P(.long, "hashed_seed"),
                                    P(.varInt, "max_players"),
                                    P(.varInt, "view_dist"),
                                    P(.varInt, "sim_dist"),
                                    P(.boolean, "reduced_debug_info"),
                                    P(.boolean, "enable_respawn_screen"),
                                    P(.boolean, "is_debug"),
                                    P(.boolean, "is_flat"),
                                    P(.boolean, "has_death_location"),
                                }));
                                bot1.view_dist = @intCast(u8, data.sim_dist);
                                std.debug.print("Login {any}\n", .{data});
                            },
                            .Combat_Death => {
                                const id = parse.varInt();
                                const killer_id = parse.int(i32);
                                const msg = try parse.string(null);
                                std.debug.print("You died lol {d} {d} {s}\n", .{ id, killer_id, msg });

                                try pctx.clientCommand(0);
                            },
                            .Disconnect => {
                                const reason = try parse.string(null);
                                run = false;

                                std.debug.print("Disconnect: {s}\n", .{reason});
                            },
                            .Plugin_Message => {
                                const channel_name = try parse.string(null);
                                std.debug.print("Plugin Message: {s}\n", .{channel_name});

                                try pctx.pluginMessage("tony:brand");
                                try pctx.clientInfo("en_US", bot1.view_dist, 1);
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
                                const win_id = parse.int(u8);
                                std.debug.print("SETTING CONTAINER: {d}\n", .{win_id});
                                const state_id = parse.varInt();
                                _ = state_id;
                                const item_count = parse.varInt();
                                var i: u32 = 0;
                                while (i < item_count) : (i += 1) {
                                    const s = parse.slot();
                                    bot1.inventory[i] = s;
                                }
                            },
                            .Spawn_Player => {
                                const data = parser.parse(PT(&.{
                                    P(.varInt, "ent_id"),
                                    P(.uuid, "ent_uuid"),
                                    P(.V3f, "pos"),
                                    P(.angle, "yaw"),
                                    P(.angle, "pitch"),
                                }));
                                niklas_id = data.ent_id;
                                try entities.put(data.ent_id, .{
                                    .uuid = data.ent_uuid,
                                    .pos = data.pos,
                                    .pitch = data.pitch,
                                    .yaw = data.yaw,
                                });
                                std.debug.print("Spawn player: {d}\n", .{data.ent_uuid});
                            },
                            .Spawn_Entity => {
                                const data = parser.parse(PT(&.{
                                    P(.varInt, "ent_id"),
                                    P(.uuid, "ent_uuid"),
                                    P(.varInt, "ent_type"),
                                    P(.V3f, "pos"),
                                    P(.angle, "pitch"),
                                    P(.angle, "yaw"),
                                    P(.angle, "head_yaw"),
                                    P(.varInt, "data"),
                                    P(.shortV3i, "vel"),
                                }));
                                try entities.put(data.ent_id, .{
                                    .uuid = data.ent_uuid,
                                    .pos = data.pos,
                                    .pitch = data.pitch,
                                    .yaw = data.yaw,
                                });
                                //std.debug.print("Spawn_Entity: {}\n", .{data});
                                //   std.debug.print("Spawn: {d} {d} {s}\n", .{
                                //       data.ent_uuid,
                                //       data.ent_type,
                                //       id_list.Entity_Types[@intCast(u32, data.ent_type)],
                                //   });
                            },
                            .Remove_Entities => {
                                const num_ent = parse.varInt();
                                var n: u32 = 0;
                                while (n < num_ent) : (n += 1) {
                                    const e_id = parse.varInt();
                                    _ = entities.remove(e_id);
                                }
                            },
                            .Synchronize_Player_Position => {
                                const FieldMask = enum(u8) {
                                    X = 0x01,
                                    Y = 0x02,
                                    Z = 0x04,
                                    Y_ROT = 0x08,
                                    x_ROT = 0x10,
                                };
                                const data = parser.parse(PT(&.{
                                    P(.V3f, "pos"),
                                    P(.float, "yaw"),
                                    P(.float, "pitch"),
                                    P(.byte, "flags"),
                                    P(.varInt, "tel_id"),
                                    P(.boolean, "should_dismount"),
                                }));

                                std.debug.print(
                                    "Sync pos: x: {d}, y: {d}, z: {d}, yaw {d}, pitch : {d} flags: {b}, tel_id: {}\n",
                                    .{ data.pos.x, data.pos.y, data.pos.z, data.yaw, data.pitch, data.flags, data.tel_id },
                                );
                                //TODO use if relative flag
                                bot1.pos = data.pos;
                                _ = FieldMask;

                                try pctx.confirmTeleport(data.tel_id);

                                if (bot1.handshake_complete == false) {
                                    bot1.handshake_complete = true;
                                    try pctx.completeLogin();
                                }
                            },
                            .Update_Entity_Rotation => {
                                const data = parser.parse(PT(&.{
                                    P(.varInt, "ent_id"),
                                    P(.angle, "yaw"),
                                    P(.angle, "pitch"),
                                    P(.boolean, "grounded"),
                                }));
                                if (entities.getPtr(data.ent_id)) |e| {
                                    e.pitch = data.pitch;
                                    e.yaw = data.yaw;
                                }
                            },
                            .Update_Entity_Position_and_Rotation => {
                                const data = parser.parse(PT(&.{
                                    P(.varInt, "ent_id"),
                                    P(.shortV3i, "del"),
                                    P(.angle, "yaw"),
                                    P(.angle, "pitch"),
                                    P(.boolean, "grounded"),
                                }));
                                if (entities.getPtr(data.ent_id)) |e| {
                                    e.pos = vector.deltaPosToV3f(e.pos, data.del);
                                    e.pitch = data.pitch;
                                    e.yaw = data.yaw;
                                }
                            },
                            .Update_Entity_Position => {
                                const data = parser.parse(PT(&.{ P(.varInt, "ent_id"), P(.shortV3i, "del"), P(.boolean, "grounded") }));
                                if (entities.getPtr(data.ent_id)) |e| {
                                    e.pos = vector.deltaPosToV3f(e.pos, data.del);
                                }
                            },
                            .Block_Entity_Data => {
                                const pos = parse.position();
                                const btype = parse.varInt();
                                var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
                                _ = pos;
                                _ = btype;
                                _ = nbt_data;
                            },
                            .Acknowledge_Block_Change => {

                                //TODO use this to advance to next break_block item
                            },
                            .Block_Update => {
                                const pos = parse.position();
                                const new_id = parse.varInt();

                                try world.setBlock(pos, @intCast(mc.BLOCK_ID_INT, new_id));

                                std.debug.print("Block update {d} {d} {d} : {d}\n", .{ pos.x, pos.y, pos.z, new_id });
                            },
                            .Set_Health => {
                                bot1.health = parse.float(f32);
                                bot1.food = @intCast(u8, parse.varInt());
                                bot1.food_saturation = parse.float(f32);
                            },
                            .Set_Head_Rotation => {},
                            .Teleport_Entity => {
                                const data = parser.parse(PT(&.{
                                    P(.varInt, "ent_id"),
                                    P(.V3f, "pos"),
                                    P(.angle, "yaw"),
                                    P(.angle, "pitch"),
                                    P(.boolean, "grounded"),
                                }));
                                if (entities.getPtr(data.ent_id)) |e| {
                                    e.pos = data.pos;
                                    e.pitch = data.pitch;
                                    e.yaw = data.yaw;
                                }
                            },
                            .Set_Entity_Metadata => {
                                const e_id = parse.varInt();
                                _ = e_id;
                                //for (entities.items) |it| {
                                //    if (it.id == e_id) {
                                //        std.debug.print("Set Metadata for: {s}\n", .{id_list.Entity_Types[it.type_id]});
                                //        break;
                                //    }
                                //}
                                //if (e_id == bot1.e_id)
                                //    std.debug.print("\tFOR PLAYER\n", .{});

                                //var index = parse.int(u8);
                                //while (index != 0xff) : (index = parse.int(u8)) {
                                //    //std.debug.print("\tIndex {d}\n", .{index});
                                //    const metatype = @intToEnum(mc.MetaDataType, parse.varInt());
                                //    //std.debug.print("\tMetadata: {}\n", .{metatype});
                                //    switch (metatype) {
                                //        else => {
                                //            //std.debug.print("\tENTITY METADATA TYPE NOT IMPLEMENTED\n", .{});
                                //            break;
                                //        },
                                //    }
                                //}
                            },
                            .Game_Event => {
                                const event = parse.int(u8);
                                const value = parse.float(f32);
                                std.debug.print("GAME EVENT: {d} {d}\n", .{ event, value });
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
                            .Unload_Chunk => {
                                const data = parser.parse(PT(&.{ P(.int, "cx"), P(.int, "cz") }));
                                world.removeChunkColumn(data.cx, data.cz);
                            },
                            .Set_Entity_Velocity => {},
                            .Update_Section_Blocks => {
                                const chunk_pos = parse.cposition();
                                const sup_light = parse.boolean();
                                _ = sup_light;
                                const n_blocks = parse.varInt();
                                var n: u32 = 0;
                                while (n < n_blocks) : (n += 1) {
                                    const bd = parse.varLong();
                                    const bid = @intCast(u16, bd >> 12);
                                    const lx = @intCast(i32, (bd >> 8) & 15);
                                    const lz = @intCast(i32, (bd >> 4) & 15);
                                    const ly = @intCast(i32, bd & 15);
                                    try world.setBlockChunk(chunk_pos, V3i.new(lx, ly, lz), bid);
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
                                var ent_i: u32 = 0;
                                while (ent_i < num_block_ent) : (ent_i += 1) {
                                    const be = parse.blockEntity();
                                    _ = be;
                                }
                            },
                            .System_Chat_Message => {
                                const msg = try parse.string(null);
                                const is_actionbar = parse.boolean();
                                std.debug.print("System msg: {s} {}\n", .{ msg, is_actionbar });
                            },
                            .Disguised_Chat_Message => {
                                const msg = try parse.string(null);
                                std.debug.print("System msg: {s}\n", .{msg});
                            },
                            .Player_Chat_Message => {
                                { //HEADER
                                    const uuid = parse.int(u128);
                                    const index = parse.varInt();
                                    const sig_present_bool = parse.boolean();
                                    _ = index;
                                    //std.debug.print("Chat from UUID: {d} {d}\n", .{ uuid, index });
                                    //std.debug.print("sig_present {any}\n", .{sig_present_bool});
                                    if (sig_present_bool) {
                                        std.debug.print("NOT SUPPORTED \n", .{});
                                        unreachable;
                                    }

                                    var ent_it = entities.iterator();
                                    var ent = ent_it.next();
                                    const player_info: ?Entity = blk: {
                                        while (ent != null) : (ent = ent_it.next()) {
                                            if (ent.?.value_ptr.uuid == uuid) {
                                                std.debug.print("found enti\n", .{});
                                                break :blk ent.?.value_ptr.*;
                                            }
                                        }
                                        break :blk null;
                                    };

                                    const msg = try parse.string(null);
                                    const eql = std.mem.eql;

                                    var msg_buffer: [256]u8 = undefined;
                                    var m_fbs = std.io.FixedBufferStream([]u8){ .buffer = &msg_buffer, .pos = 0 };
                                    const m_wr = m_fbs.writer();

                                    var it = std.mem.tokenize(u8, msg, " ");

                                    const key = it.next().?;
                                    if (eql(u8, key, "path")) {
                                        maj_goal = blk: {
                                            if (parseCoordOpt(&it)) |coord| {
                                                break :blk coord.add(V3f.new(0, 1, 0));
                                            }
                                            break :blk player_info.?.pos;
                                        };

                                        const found = try pathctx.pathfind(bot1.pos.?, maj_goal.?);
                                        if (found) |*actions| {
                                            player_actions.deinit();
                                            player_actions = actions.*;
                                            for (player_actions.items) |pitem| {
                                                std.debug.print("action: {any}\n", .{pitem});
                                            }
                                            if (!draw) {
                                                current_action = player_actions.popOrNull();
                                                if (current_action) |acc| {
                                                    switch (acc) {
                                                        .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                                        .block_break => block_break_timer = null,
                                                    }
                                                }
                                            }
                                        }
                                    } else if (eql(u8, key, "axe")) {
                                        for (bot1.inventory) |optslot| {
                                            if (optslot) |slot| {
                                                //TODO in mc 19.4 tags have been added for axes etc, for now just do a string search
                                                const name = item_table.getName(slot.item_id);
                                                const inde = std.mem.indexOf(u8, name, "axe");
                                                if (inde) |in| {
                                                    _ = in;
                                                    std.debug.print("Found axe :{s}\n", .{name});
                                                }
                                                //std.debug.print("item: {s}\n", .{item_table.getName(slot.item_id)});
                                            }
                                        }
                                    } else if (eql(u8, key, "open_chest")) {
                                        try pctx.sendChat("Trying to open chest");
                                        const v = try parseCoord(&it);
                                        try pctx.useItemOn(.main, v.toI(), .bottom, 0, 0, 0, false, 0);
                                    } else if (eql(u8, key, "tree")) {
                                        if (try pathctx.findTree(bot1.pos.?)) |*actions| {
                                            player_actions.deinit();
                                            player_actions = actions.*;
                                            for (player_actions.items) |pitem| {
                                                std.debug.print("action: {any}\n", .{pitem});
                                            }
                                            current_action = player_actions.popOrNull();
                                            if (current_action) |acc| {
                                                switch (acc) {
                                                    .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                                    .block_break => block_break_timer = null,
                                                }
                                            }
                                        }
                                    } else if (eql(u8, key, "has_tag")) {
                                        const v = try parseCoord(&it);
                                        const tag = it.next() orelse unreachable;
                                        if (pathctx.hasBlockTag(tag, v.toI())) {
                                            try pctx.sendChat("yes has tag");
                                        } else {
                                            try pctx.sendChat("no tag");
                                        }
                                    } else if (eql(u8, key, "look")) {
                                        if (parseCoordOpt(&it)) |coord| {
                                            _ = coord;
                                            std.debug.print("Has coord\n", .{});
                                        }
                                        const pw = mc.lookAtBlock(bot1.pos.?, player_info.?.pos.add(V3f.new(-0.3, 1, -0.3)));
                                        try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                                    } else if (eql(u8, key, "dig")) {
                                        try pctx.sendChat("digging");
                                        const v = try parseCoord(&it);
                                        try pctx.playerAction(.start_digging, v.toI());
                                    } else if (eql(u8, key, "bpe")) {} else if (eql(u8, key, "moverel")) {} else if (eql(u8, key, "lookat")) {
                                        const v = try parseCoord(&it);
                                        const pw = mc.lookAtBlock(bot1.pos.?, v);
                                        try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                                    } else if (eql(u8, key, "jump")) {} else if (eql(u8, key, "query")) {
                                        const qb = (try parseCoord(&it)).toI();
                                        const bid = world.getBlock(qb);
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
                                //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, pid)]});
                            },
                        }
                    },
                    .local => {
                        var itt = std.mem.tokenize(u8, item.data.buffer.items[0 .. item.data.buffer.items.len - 1], " ");
                        const key = itt.next() orelse unreachable;
                        const eql = std.mem.eql;
                        if (eql(u8, "exit", key)) {
                            run = false;
                        } else if (eql(u8, "query", key)) {
                            if (itt.next()) |tag_type| {
                                const tags = tag_table.tags.getPtr(tag_type) orelse unreachable;
                                var kit = tags.keyIterator();
                                var ke = kit.next();
                                std.debug.print("Possible sub tag: \n", .{});
                                while (ke != null) : (ke = kit.next()) {
                                    std.debug.print("\t{s}\n", .{ke.?.*});
                                }
                            } else {
                                var kit = tag_table.tags.keyIterator();
                                var ke = kit.next();
                                std.debug.print("Possible tags: \n", .{});
                                while (ke != null) : (ke = kit.next()) {
                                    std.debug.print("\t{s}\n", .{ke.?.*});
                                }
                            }
                        }
                    },
                },
            }
        }
    }

    //pctx.deinit();
}
