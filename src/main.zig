const std = @import("std");

const graph = @import("graph");
const mcBlockAtlas = @import("mc_block_atlas.zig");
//const mcBlockAtlas = graph.mcblockatlas;

const mc = @import("listener.zig");
const id_list = @import("list.zig");
const eql = std.mem.eql;

const packet_analyze = @import("analyze_packet_json.zig");

const nbt_zig = @import("nbt.zig");
const astar = @import("astar.zig");
const bot = @import("bot.zig");
const Bot = bot.Bot;
const Reg = @import("data_reg.zig");

const math = std.math;

const vector = @import("vector.zig");
const V3f = vector.V3f;
const V3i = vector.V3i;
const V2i = vector.V2i;

const Parse = @import("parser.zig");
const common = @import("common.zig");

const c = @import("c.zig").c;

const fbsT = std.io.FixedBufferStream([]const u8);

const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;
const Entity = mcTypes.Entity;
const Lua = graph.Lua;

pub const PacketCache = struct {};

pub fn botJoin(alloc: std.mem.Allocator, bot_name: []const u8) !Bot {
    var bot1 = try Bot.init(alloc, bot_name);
    const s = try std.net.tcpConnectToHost(alloc, "localhost", 25565);
    bot1.fd = s.handle;
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = s.writer(), .mutex = &bot1.fd_mutex };
    defer pctx.packet.deinit();
    try pctx.handshake("localhost", 25565);
    try pctx.loginStart(bot1.name);
    bot1.connection_state = .login;
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();
    var comp_thresh: i32 = -1;

    while (bot1.connection_state == .login) {
        const pd = try mc.recvPacket(alloc, s.reader(), comp_thresh);
        defer alloc.free(pd);
        var fbs_ = fbsT{ .buffer = pd, .pos = 0 };
        const parseT = mc.packetParseCtx(fbsT.Reader);
        var parse = parseT.init(fbs_.reader(), arena_alloc);
        const pid = parse.varInt();
        switch (@as(id_list.login_packet_enum, @enumFromInt(pid))) {
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
                const n_props = @as(u32, @intCast(parse.varInt()));
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
    return bot1;
}

pub fn parseCoordOpt(it: *std.mem.TokenIterator(u8, .scalar)) ?vector.V3f {
    var ret = V3f{
        .x = @as(f64, @floatFromInt(std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null)),
        .y = @as(f64, @floatFromInt(std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null)),
        .z = @as(f64, @floatFromInt(std.fmt.parseInt(i64, it.next() orelse return null, 0) catch return null)),
    };
    return ret;
}

pub fn parseCoord(it: *std.mem.TokenIterator(u8, .scalar)) !vector.V3f {
    return .{
        .x = @as(f64, @floatFromInt(try std.fmt.parseInt(i64, it.next() orelse "0", 0))),
        .y = @as(f64, @floatFromInt(try std.fmt.parseInt(i64, it.next() orelse "0", 0))),
        .z = @as(f64, @floatFromInt(try std.fmt.parseInt(i64, it.next() orelse "0", 0))),
    };
}

const Queue = std.atomic.Queue;
pub const QItem = struct {
    fd: i32,
    buf: []u8,
};

pub const QType = Queue(QItem);

pub const PacketParse = struct {
    state: enum { len, data } = .len,
    buf: std.ArrayList(u8),
    data_len: ?u32 = null,
    len_len: ?u32 = null,
    num_read: u32 = 0,

    pub fn reset(self: *@This()) !void {
        try self.buf.resize(0);
        self.state = .len;
        self.data_len = null;
        self.len_len = null;
        self.num_read = 0;
    }
};

pub fn parseSwitch(alloc: std.mem.Allocator, bot1: *Bot, packet_buf: []const u8, world: *McWorld) !void {
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();

    var fbs_ = fbsT{ .buffer = packet_buf, .pos = 0 };
    const parseT = mc.packetParseCtx(fbsT.Reader);
    var parse = parseT.init(fbs_.reader(), arena_alloc);

    const parseTr = Parse.packetParseCtx(fbsT.Reader);
    var parser = parseTr.init(fbs_.reader(), arena_alloc);

    const plen = parse.varInt();
    _ = plen;
    const pid = parse.varInt();

    //if (plen > 4096)
    //std.debug.print("{d} over len: {s}\n", .{ plen, id_list.packet_ids[@intCast(u32, pid)] });

    const P = Parse.P;
    const PT = Parse.parseType;

    const server_stream = std.net.Stream{ .handle = bot1.fd };

    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = server_stream.writer(), .mutex = &bot1.fd_mutex };
    defer pctx.packet.deinit();

    if (bot1.connection_state != .play)
        return error.invalidConnectionState;
    switch (@as(id_list.packet_enum, @enumFromInt(pid))) {
        //WORLD specific packets
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
        .Spawn_Player => {
            const data = parser.parse(PT(&.{
                P(.varInt, "ent_id"),
                P(.uuid, "ent_uuid"),
                P(.V3f, "pos"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
            }));
            try world.entities.put(data.ent_id, .{
                .uuid = data.ent_uuid,
                .pos = data.pos,
                .pitch = data.pitch,
                .yaw = data.yaw,
            });
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

            try world.entities.put(data.ent_id, .{
                .uuid = data.ent_uuid,
                .pos = data.pos,
                .pitch = data.pitch,
                .yaw = data.yaw,
            });
        },
        .Remove_Entities => {
            const num_ent = parse.varInt();
            var n: u32 = 0;
            while (n < num_ent) : (n += 1) {
                const e_id = parse.varInt();
                _ = world.entities.remove(e_id);
            }
        },
        .Update_Entity_Rotation => {
            const data = parser.parse(PT(&.{
                P(.varInt, "ent_id"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
                P(.boolean, "grounded"),
            }));
            if (world.entities.getPtr(data.ent_id)) |e| {
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
            if (world.entities.getPtr(data.ent_id)) |e| {
                e.pos = vector.deltaPosToV3f(e.pos, data.del);
                e.pitch = data.pitch;
                e.yaw = data.yaw;
            }
        },
        .Entity_Effect => {
            const data = parser.parse(PT(&.{
                P(.varInt, "ent_id"),
                P(.varInt, "effect_id"),
                P(.byte, "amplifier"),
                P(.varInt, "duration_ticks"),
                P(.byte, "flags"),
            }));
            _ = data;
            //if (data.id == bot1.e_id) {}
        },
        .Update_Entity_Position => {
            const data = parser.parse(PT(&.{ P(.varInt, "ent_id"), P(.shortV3i, "del"), P(.boolean, "grounded") }));
            if (world.entities.getPtr(data.ent_id)) |e| {
                e.pos = vector.deltaPosToV3f(e.pos, data.del);
            }
        },
        .Block_Entity_Data => {
            const pos = parse.position();
            const btype = parse.varInt();
            const tr = nbt_zig.TrackingReader(@TypeOf(parse.reader));
            var tracker = tr.init(arena_alloc, parse.reader);
            defer tracker.deinit();

            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, tracker.reader());
            //std.debug.print("\n\n{}\n\n", .{nbt_data});
            _ = nbt_data;
            _ = pos;
            _ = btype;
            //_ = nbt_data;
        },
        .Teleport_Entity => {
            const data = parser.parse(PT(&.{
                P(.varInt, "ent_id"),
                P(.V3f, "pos"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
                P(.boolean, "grounded"),
            }));
            if (world.entities.getPtr(data.ent_id)) |e| {
                e.pos = data.pos;
                e.pitch = data.pitch;
                e.yaw = data.yaw;
            }
        },
        .Set_Entity_Metadata => {
            const e_id = parse.varInt();
            _ = e_id;
        },
        .Game_Event => {
            const event = parse.int(u8);
            const value = parse.float(f32);
            std.debug.print("GAME EVENT: {d} {d}\n", .{ event, value });
        },
        .Update_Section_Blocks => {
            const chunk_pos = parse.cposition();
            const sup_light = parse.boolean();
            _ = sup_light;
            const n_blocks = parse.varInt();
            var n: u32 = 0;
            while (n < n_blocks) : (n += 1) {
                const bd = parse.varLong();
                const bid = @as(u16, @intCast(bd >> 12));
                const lx = @as(i32, @intCast((bd >> 8) & 15));
                const lz = @as(i32, @intCast((bd >> 4) & 15));
                const ly = @as(i32, @intCast(bd & 15));
                try world.chunk_data.setBlockChunk(chunk_pos, V3i.new(lx, ly, lz), bid);
            }
        },
        .Block_Update => {
            const pos = parse.position();
            const new_id = parse.varInt();
            try world.chunk_data.setBlock(pos, @as(mc.BLOCK_ID_INT, @intCast(new_id)));
        },
        .Chunk_Data_and_Update_Light => {
            const cx = parse.int(i32);
            const cy = parse.int(i32);
            if (world.chunk_data.isLoaded(V3i.new(cx * 16, 0, cy * 16))) {
                //TODO may cause desyncs
                return;
            }

            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
            _ = nbt_data;
            const data_size = parse.varInt();
            var chunk_data = std.ArrayList(u8).init(alloc);
            defer chunk_data.deinit();
            try chunk_data.resize(@as(usize, @intCast(data_size)));
            try parse.reader.readNoEof(chunk_data.items);

            var chunk: mc.Chunk = undefined;
            var chunk_i: u32 = 0;
            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
            const cr = chunk_fbs.reader();
            //TODO determine number of chunk sections some other way
            while (chunk_i < 16) : (chunk_i += 1) {
                const block_count = try cr.readInt(i16, .Big);
                _ = block_count;
                chunk[chunk_i] = mc.ChunkSection.init(alloc);
                const chunk_section = &chunk[chunk_i];

                { //BLOCK STATES palated container
                    const bp_entry = try cr.readInt(u8, .Big);
                    {
                        if (bp_entry == 0) {
                            try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mc.readVarInt(cr))));
                        } else {
                            const num_pal_entry = mc.readVarInt(cr);
                            chunk_section.bits_per_entry = bp_entry;

                            var i: u32 = 0;
                            while (i < num_pal_entry) : (i += 1) {
                                const mapping = mc.readVarInt(cr);
                                try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mapping)));
                            }
                        }

                        const num_longs = mc.readVarInt(cr);
                        var j: u32 = 0;

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

                        const num_longs = @as(u32, @intCast(mc.readVarInt(cr)));
                        try cr.skipBytes(num_longs * @sizeOf(u64), .{});
                    }
                }
            }

            try world.chunk_data.insertChunkColumn(cx, cy, chunk);

            const num_block_ent = parse.varInt();
            var ent_i: u32 = 0;
            while (ent_i < num_block_ent) : (ent_i += 1) {
                const be = parse.blockEntity();
                const coord = V3i.new(cx * 16 + be.rel_x, be.abs_y, cy * 16 + be.rel_z);
                const id = world.chunk_data.getBlock(coord) orelse 0;
                const b = world.reg.getBlockFromState(id);
                if (world.tag_table.hasTag(b.id, "minecraft:block", "minecraft:signs")) {
                    if (be.nbt == .compound) {
                        if (be.nbt.compound.get("Text1")) |e| {
                            if (e == .string) {
                                const j = try std.json.parseFromSlice(struct { text: []const u8 }, arena_alloc, e.string, .{});
                                if (b.getState(id, .facing)) |facing| {
                                    const dvec = facing.sub.facing.reverse().toVec();
                                    const behind = coord.add(dvec);
                                    if (world.chunk_data.getBlock(behind)) |bid| {
                                        const bi = world.reg.getBlockFromState(bid);
                                        if (std.mem.eql(u8, "chest", bi.name)) {
                                            const name = try std.mem.concat(arena_alloc, u8, &.{ j.value.text, "_chest" });
                                            try world.putSignWaypoint(name, behind);
                                        } else if (std.mem.eql(u8, "dropper", bi.name)) {
                                            const name = try std.mem.concat(arena_alloc, u8, &.{ j.value.text, "_dropper" });
                                            try world.putSignWaypoint(name, behind);
                                        }
                                    }
                                }
                                try world.putSignWaypoint(j.value.text, coord);
                            }
                        }
                    }
                } else {
                    //std.debug.print("at {any}\n", .{coord});
                    if (std.mem.eql(u8, "chest", b.name)) {
                        //std.debug.print("t_ent {d} {d} {d}__{s}\n", .{ be.rel_x, be.rel_z, be.abs_y, b.name });
                        //be.nbt.format("", .{}, std.io.getStdErr().writer()) catch unreachable;
                    }
                }
            }
        },
        //Keep track of what bots have what chunks loaded and only unload chunks if none have it loaded
        .Unload_Chunk => {
            const data = parser.parse(PT(&.{ P(.int, "cx"), P(.int, "cz") }));
            try world.chunk_data.removeChunkColumn(data.cx, data.cz);
        },
        //BOT specific packets
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
            bot1.view_dist = @as(u8, @intCast(data.sim_dist));
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

            std.debug.print("Disconnect: {s}\n", .{reason});
        },
        .Set_Held_Item => {
            bot1.selected_slot = parse.int(u8);
            try pctx.setHeldItem(bot1.selected_slot);
        },
        .Set_Container_Slot => {
            const win_id = parse.int(u8);
            const state_id = parse.varInt();
            const slot_i = parse.int(i16);
            const data = parse.slot();
            if (win_id == -1 and slot_i == -1) {
                bot1.held_item = data;
            } else if (win_id == 0) {
                bot1.container_state = state_id;
                try bot1.inventory.setSlot(@intCast(slot_i), data);
                std.debug.print("SET CONTAINER SLOT slot {any}\n", .{data});
            } else if (bot1.interacted_inventory.win_id != null and win_id == bot1.interacted_inventory.win_id.?) {
                bot1.container_state = state_id;
                try bot1.interacted_inventory.setSlot(@intCast(slot_i), data);

                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 35);
                if (slot_i >= player_inv_start)
                    try bot1.inventory.setSlot(@intCast(slot_i - player_inv_start + 9), data);
            }
        },
        .Open_Screen => {
            const win_id = parse.varInt();
            const win_type = parse.varInt();
            bot1.interacted_inventory.win_type = @as(u32, @intCast(win_type));
            //bot1.interacted_inventory.win_id = win_id;
            const win_title = try parse.string(null);
            std.debug.print("open window: {d} {d}: {s}\n", .{ win_id, win_type, win_title });
        },
        .Set_Container_Content => {
            std.debug.print("SET CONT CONTENT\n", .{});
            const win_id = parse.int(u8);
            const state_id = parse.varInt();
            const item_count = @as(u32, @intCast(parse.varInt()));
            var i: u32 = 0;
            if (win_id == 0) {
                while (i < item_count) : (i += 1) {
                    bot1.container_state = state_id;
                    const s = parse.slot();
                    try bot1.inventory.setSlot(i, s);
                }
            } else {
                try bot1.interacted_inventory.setSize(item_count);
                bot1.interacted_inventory.win_id = win_id;
                bot1.container_state = state_id;
                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 35);
                while (i < item_count) : (i += 1) {
                    const s = parse.slot();
                    try bot1.interacted_inventory.setSlot(i, s);
                    const ii: i16 = @intCast(i);
                    if (i >= player_inv_start)
                        try bot1.inventory.setSlot(@intCast(ii - player_inv_start + 9), s);
                }
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

            if (bot1.pos != null)
                std.debug.print(
                    "Sync pos: x: {d}, y: {d}, z: {d}, yaw {d}, pitch : {d} flags: {b}, tel_id: {}\n\told_pos: {any}\n\tDisc: {d} {d} {d}\n",
                    .{
                        data.pos.x,
                        data.pos.y,
                        data.pos.z,
                        data.yaw,
                        data.pitch,
                        data.flags,
                        data.tel_id,
                        bot1.pos,
                        bot1.pos.?.x - data.pos.x,
                        bot1.pos.?.y - data.pos.y,
                        bot1.pos.?.z - data.pos.z,
                    },
                );
            //TODO use if relative flag
            bot1.pos = data.pos;
            _ = FieldMask;
            //bot1.action_index = null;

            try pctx.confirmTeleport(data.tel_id);

            if (bot1.handshake_complete == false) {
                bot1.handshake_complete = true;
                try pctx.completeLogin();
            }
        },
        .Acknowledge_Block_Change => {

            //TODO use this to advance to next break_block item
        },
        .Set_Health => {
            bot1.health = parse.float(f32);
            bot1.food = @as(u8, @intCast(parse.varInt()));
            bot1.food_saturation = parse.float(f32);
        },
        .Set_Head_Rotation => {},
        .Update_Time => {},
        .Update_Tags => {
            if (!world.has_tag_table) {
                world.has_tag_table = true;

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
                            try ids.resize(@as(usize, @intCast(num_ids)));
                            var ni: u32 = 0;
                            while (ni < num_ids) : (ni += 1)
                                ids.items[ni] = @as(u32, @intCast(parse.varInt()));
                            //std.debug.print("{s}: {s}: {any}\n", .{ identifier.items, ident.items, ids.items });
                            try world.tag_table.addTag(identifier, ident, ids.items);
                        }
                    }
                }
            }
        },
        .Set_Entity_Velocity => {},
        .System_Chat_Message => {
            //const msg = try parse.string(null);
            //const is_actionbar = parse.boolean();
            //std.debug.print("System msg: {s} {}\n", .{ msg, is_actionbar });
        },
        .Disguised_Chat_Message => {
            const msg = try parse.string(null);
            std.debug.print("System msg: {s}\n", .{msg});
        },
        .Player_Chat_Message => {
            const uuid = parse.int(u128);
            const index = parse.varInt();
            const sig_present_bool = parse.boolean();
            _ = index;
            if (sig_present_bool) {
                std.debug.print("CHAT SIG NOT SUPPORTED \n", .{});
                unreachable;
            }

            const msg = try parse.string(null);

            const timestamp = parse.int(u64);
            if (std.mem.indexOfScalar(u64, &world.packet_cache.chat_time_stamps.buf, timestamp) != null) {
                return;
            }
            world.packet_cache.chat_time_stamps.insert(timestamp);

            var it = std.mem.tokenizeScalar(u8, msg, ' ');
            const key = it.next().?;

            var ret_msg_buf = std.ArrayList(u8).init(alloc);
            defer ret_msg_buf.deinit();
            const m_wr = ret_msg_buf.writer();

            var lower_name: [16]u8 = undefined;
            const ln = std.ascii.lowerString(&lower_name, key);
            var bot_it = world.bots.iterator();
            var bot_i = bot_it.next();
            const bot_h = blk: {
                while (bot_i != null) : (bot_i = bot_it.next()) {
                    var lower_bname: [16]u8 = undefined;
                    const lnb = std.ascii.lowerString(&lower_bname, bot_i.?.value_ptr.name);
                    if (eql(u8, ln, lnb)) {
                        break :blk bot_i.?.value_ptr;
                    }
                }
                break :blk null;
            };
            if (bot_h) |cbot| {
                var bp = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = (std.net.Stream{ .handle = cbot.fd }).writer(), .mutex = &cbot.fd_mutex };
                defer bp.packet.deinit();
                var ent_it = world.entities.iterator();
                var ent = ent_it.next();
                const player_info: ?Entity = blk: {
                    while (ent != null) : (ent = ent_it.next()) {
                        if (ent.?.value_ptr.uuid == uuid) {
                            break :blk ent.?.value_ptr.*;
                        }
                    }
                    break :blk null;
                };
                const com = it.next() orelse return;
                if (eql(u8, com, "look")) {
                    if (parseCoordOpt(&it)) |coord| {
                        _ = coord;
                        std.debug.print("Has coord\n", .{});
                    }
                    const pw = mc.lookAtBlock(cbot.pos.?, player_info.?.pos.add(V3f.new(-0.3, 1, -0.3)));
                    try bp.setPlayerPositionRot(cbot.pos.?, pw.yaw, pw.pitch, true);
                } else if (eql(u8, com, "inspect")) {
                    if (parseCoordOpt(&it)) |coord| {
                        if (world.chunk_data.getBlock(coord.toI())) |id| {
                            const block = world.reg.getBlockFromState(id);
                            //_ = block.getState(id, .age);
                            try m_wr.print("Block: {s} {d}", .{ block.name, id });
                            try bp.sendChat(ret_msg_buf.items);
                        }
                    }
                } else if (eql(u8, com, "say")) {
                    var ite = it.next();
                    while (ite != null) : (ite = it.next()) {
                        try m_wr.print("{s} ", .{ite.?});
                    }

                    try bp.sendChat(ret_msg_buf.items);
                } else if (eql(u8, com, "path")) {
                    try bp.sendChat("pathing");
                    //_ = try std.Thread.spawn(.{}, basicPathfindThread, .{ alloc, world, reg, cbot.pos.?, player_info.?.pos, cbot.fd });
                }
            }

            if (eql(u8, key, "path")) {
                //var pathctx = astar.AStarContext.init(alloc, &world.chunk_data, &world.tag_table, reg);
                //defer pathctx.deinit();
                //const maj_goal = blk: {
                //    if (parseCoordOpt(&it)) |coord| {
                //        break :blk coord.add(V3f.new(0, 1, 0));
                //    }
                //    break :blk player_info.?.pos;
                //};

                //const found = try pathctx.pathfind(bot1.pos.?, maj_goal.?);
                //_ = found;
                //if (found) |*actions| {
                //    player_actions.deinit();
                //    player_actions = actions.*;
                //    for (player_actions.items) |pitem| {
                //        std.debug.print("action: {any}\n", .{pitem});
                //    }
                //    if (!draw) {
                //        current_action = player_actions.popOrNull();
                //        if (current_action) |acc| {
                //            switch (acc) {
                //                .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                //                .block_break => block_break_timer = null,
                //            }
                //        }
                //    }
                //}
            } else if (eql(u8, key, "toggle")) {} else if (eql(u8, key, "inventory")) {
                try m_wr.print("Items: ", .{});
                for (bot1.inventory.slots.items) |optslot| {
                    if (optslot) |slot| {
                        const itemd = world.reg.getItem(slot.item_id);
                        try m_wr.print("{s}: {d}, ", .{ itemd.name, slot.count });
                    }
                }
                try pctx.sendChat(ret_msg_buf.items);
            } else if (eql(u8, key, "report")) {
                try m_wr.print("Items: ", .{});
                for (bot1.interacted_inventory.slots.items) |optslot| {
                    if (optslot) |slot| {
                        const itemd = world.reg.getItem(slot.item_id);
                        try m_wr.print("{s}: {d}, ", .{ itemd.name, slot.count });
                    }
                }
                try pctx.sendChat(ret_msg_buf.items);
            } else if (eql(u8, key, "axe")) {
                //for (bot1.inventory) |optslot, si| {
                //if (optslot) |slot| {
                //    //TODO in mc 19.4 tags have been added for axes etc, for now just do a string search
                //    const name = reg.getItem(slot.item_id).name;
                //    const inde = std.mem.indexOf(u8, name, "axe");
                //    if (inde) |in| {
                //        std.debug.print("found axe at {d} {any}\n", .{ si, bot1.inventory[si] });
                //        _ = in;
                //        //try pctx.pickItem(si - 10);
                //        try pctx.clickContainer(0, bot1.container_state, @intCast(i16, si), 0, 2, &.{}, null);
                //        try pctx.setHeldItem(0);
                //        break;
                //    }
                //    //std.debug.print("item: {s}\n", .{item_table.getName(slot.item_id)});
                //}
                //}
            } else if (eql(u8, key, "dump")) {
                try pctx.sendChat("dumping");
                const inv = bot1.interacted_inventory;
                if (inv.win_type == 2) { //A single chest
                    var first_null_i: u32 = 0;
                    var num_null: u32 = 0;
                    var i: u32 = 0;
                    while (i < 27) : (i += 1) {
                        if (inv.slots.items[i] == null) {
                            first_null_i = i;
                            num_null += 1;
                            break;
                        }
                    }

                    i = 27;
                    while (i < 63) : (i += 1) {
                        if (num_null == 0)
                            break;

                        if (inv.slots.items[i] != null) {
                            num_null -= 1;
                            try pctx.clickContainer(inv.win_id.?, bot1.container_state, i, 0, 0, &.{.{ .sloti = i, .slot = null }}, inv.slots.items[i].?);
                            try pctx.clickContainer(inv.win_id.?, bot1.container_state, first_null_i, 0, 0, &.{.{ .sloti = first_null_i, .slot = inv.slots.items[i].? }}, null);
                            break;
                        }
                    }
                }
            } else if (eql(u8, key, "place")) {
                try pctx.sendChat("Trying to place above");
                try pctx.useItemOn(.main, bot1.pos.?.add(V3f.new(0, 2, 0)).toI(), .bottom, 0, 0, 0, false, 0);
            } else if (eql(u8, key, "close_chest")) {
                try pctx.sendChat("Trying to close chest");
                try pctx.closeContainer(bot1.interacted_inventory.win_id.?);
                //bot1.interacted_inventory.win_id = null;
            } else if (eql(u8, key, "open_chest")) {
                try pctx.sendChat("Trying to open chest");
                const v = try parseCoord(&it);
                try pctx.useItemOn(.main, v.toI(), .bottom, 0, 0, 0, false, 0);
            } else if (eql(u8, key, "tree")) {
                //if (try pathctx.findTree(bot1.pos.?)) |*actions| {
                //    player_actions.deinit();
                //    player_actions = actions.*;
                //    for (player_actions.items) |pitem| {
                //        std.debug.print("action: {any}\n", .{pitem});
                //    }
                //    current_action = player_actions.popOrNull();
                //    if (current_action) |acc| {
                //        switch (acc) {
                //            .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                //            .block_break => block_break_timer = null,
                //        }
                //    }
                //}
            } else if (eql(u8, key, "has_tag")) {
                //const v = try parseCoord(&it);
                //const tag = it.next() orelse unreachable;
                //if (pathctx.hasBlockTag(tag, v.toI())) {
                //    try pctx.sendChat("yes has tag");
                //} else {
                //    try pctx.sendChat("no tag");
                //}
            } else if (eql(u8, key, "jump")) {} else if (eql(u8, key, "query")) {
                const qb = (try parseCoord(&it)).toI();
                const bid = world.chunk_data.getBlock(qb) orelse 0;
                try m_wr.print("Block {s} id: {d}", .{
                    world.reg.getBlockFromState(bid).name,
                    bid,
                });
                try pctx.sendChat(ret_msg_buf.items);
                std.debug.print("{}", .{world.reg.getBlockFromState(bid)});
                //try pctx.sendChat(m_fbs.getWritten());
            }
        },
        else => {
            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, pid)]});
        },
    }
}

threadlocal var lss: ?*LuaApi = null;
pub const LuaApi = struct {
    const Self = @This();
    thread_data: *bot.BotScriptThreadData,
    vm: *Lua,
    pathctx: astar.AStarContext,
    world: *McWorld,
    bo: *Bot,

    fn stripErrorUnion(comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .ErrorUnion) @compileError("stripErrorUnion expects an error union!");
        return info.ErrorUnion.payload;
    }

    fn log(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }

    fn errc(to_check: anytype) ?stripErrorUnion(@TypeOf(to_check)) {
        return to_check catch |err| {
            std.debug.print("{any}\n", .{err});
            return null;
        };
    }

    pub fn init(alloc: std.mem.Allocator, world: *McWorld, bo: *Bot, thread_data: *bot.BotScriptThreadData, vm: *Lua) Self {
        const info = @typeInfo(Api);
        inline for (info.Struct.decls) |decl| {
            var buf: [128]u8 = undefined;
            if (buf.len <= decl.name.len)
                @compileError("function name to long");
            @memcpy(buf[0..decl.name.len], decl.name);
            buf[decl.name.len] = 0;
            log("Registering lua function: {s}\n", .{decl.name});
            const tinfo = @typeInfo(@TypeOf(@field(Api, decl.name)));
            const lua_name = @as([*c]const u8, @ptrCast(&buf[0]));
            switch (tinfo) {
                .Fn => vm.reg(lua_name, @field(Api, decl.name)),
                else => vm.setGlobal(lua_name, @field(Api, decl.name)),
                //else => @compileError("unsupported type for lua api: " ++ decl.name ++ " typeof: " ++ @typeName(@TypeOf(@field(Api, decl.name)))),
            }
        }

        return .{
            .thread_data = thread_data,
            .vm = vm,
            .pathctx = astar.AStarContext.init(alloc, world),
            .bo = bo,
            .world = world,
        };
    }
    pub fn deinit(self: *Self) void {
        self.pathctx.deinit();
    }

    pub fn beginHalt(self: *Self) void {
        self.thread_data.lock(.script_thread);
        if (self.thread_data.u_status == .terminate_thread) {
            std.debug.print("Stopping botScript thread\n", .{});
            self.thread_data.unlock(.script_thread);
            _ = Lua.c.luaL_error(self.vm.state, "TERMINATING LUA SCRIPT");
            return;
        }
    }
    pub fn endHalt(self: *Self) void {
        self.thread_data.unlock(.script_thread);
        std.time.sleep(std.time.ns_per_s / 10);
    }

    /// Everything inside this Api struct is exported to lua using the given name
    pub const Api = struct {
        pub export fn testff(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const ret = self.vm.getArg(L, []const f32, 1);
            std.debug.print("{any}\n", .{ret});
            return 0;
        }

        ///Args: x, y, z
        ///returns nothing
        pub export fn blockInfo(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            const vm = self.vm;
            Lua.c.lua_settop(L, 1);
            const p = vm.getArg(L, V3i, 1);

            if (self.world.chunk_data.getBlock(p)) |id| {
                const block = self.world.reg.getBlockFromState(id);
                var buf: [6]Reg.Block.State = undefined;
                if (block.getAllStates(id, &buf)) |states| {
                    Lua.c.lua_newtable(L);

                    Lua.pushV(L, @as([]const u8, "name"));
                    Lua.pushV(L, block.name);
                    Lua.c.lua_settable(L, -3);

                    Lua.pushV(L, @as([]const u8, "state"));
                    Lua.c.lua_newtable(L);
                    for (states) |st| {
                        const info = @typeInfo(Reg.Block.State.SubState);
                        inline for (info.Union.fields, 0..) |f, fi| {
                            if (fi == @intFromEnum(st.sub)) {
                                Lua.pushV(L, f.name);
                                Lua.pushV(L, @field(st.sub, f.name));
                                Lua.c.lua_settable(L, -3);
                            }
                        }
                    }
                    Lua.c.lua_settable(L, -3);
                    return 1;
                }
            }
            return 0;
        }

        pub export fn sleepms(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const n_ms = self.vm.getArg(L, u64, 1);
            self.beginHalt();
            defer self.endHalt();
            std.time.sleep(n_ms * std.time.ns_per_ms);
            return 0;
        }

        pub export fn gotoLandmark(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const str = self.vm.getArg(L, []const u8, 1);
            self.beginHalt();
            defer self.endHalt();

            self.pathctx.reset() catch unreachable;
            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            self.bo.modify_mutex.unlock();
            const coord = self.world.getSignWaypoint(str) orelse {
                std.debug.print("Cant find tools waypoint\n", .{});
                return 0;
            };
            const found = self.pathctx.pathfind(pos, coord.toF()) catch unreachable;
            if (found) |*actions|
                self.thread_data.setActions(actions.*, pos);

            return 0;
        }

        //Arg x y z, item_name
        pub export fn placeBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            const bpos = self.vm.getArg(L, V3i, 1);
            const item_name = self.vm.getArg(L, []const u8, 2);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            defer self.bo.modify_mutex.unlock();
            if (self.bo.inventory.findItem(self.world.reg, item_name)) |found| {
                std.debug.print("Found item {s} {any}\n", .{ item_name, found });
                var actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(self.world.alloc);
                errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(found.index)) } })) orelse return 0;
                self.thread_data.setActions(actions, pos);
            }
            return 0;
        }

        pub export fn breakBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const bpos = self.vm.getArg(L, V3i, 1);
            self.beginHalt();
            defer self.endHalt();

            const sid = self.world.chunk_data.getBlock(bpos) orelse return 0;
            const block = self.world.reg.getBlockFromState(sid);

            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            const pos = self.bo.pos.?;
            if (self.bo.inventory.findToolForMaterial(self.world.reg, block.material)) |match| {
                const hardness = block.hardness orelse return 0;
                const btime = Reg.calculateBreakTime(match.mul, hardness, .{});
                var actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(self.world.alloc);
                errc(actions.append(.{ .block_break = .{ .pos = bpos, .break_time = @as(f64, @floatFromInt(btime)) / 20 } })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(match.slot_index)) } })) orelse return 0;
                self.thread_data.setActions(actions, pos);
            }
            return 0;
        }

        pub export fn gotoCoord(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, V3f, 1);
            self.beginHalt();
            defer self.endHalt();
            errc(self.pathctx.reset()) orelse return 0;
            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            self.bo.modify_mutex.unlock();
            const found = errc(self.pathctx.pathfind(pos, p)) orelse return 0;
            if (found) |*actions|
                self.thread_data.setActions(actions.*, pos);

            return 0;
        }

        pub export fn chopNearestTree(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            self.beginHalt();
            defer self.endHalt();
            errc(self.pathctx.reset()) orelse return 0;
            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            if (self.bo.inventory.findToolForMaterial(self.world.reg, "mineable/axe")) |match| {
                const wood_hardness = 2;
                const btime = Reg.calculateBreakTime(match.mul, wood_hardness, .{});
                //block hardness
                //tool_multiplier
                self.bo.modify_mutex.unlock();
                const tree_o = errc(self.pathctx.findTree(pos, match.slot_index, @as(f64, (@floatFromInt(btime))) / 20)) orelse return 0;
                if (tree_o) |*tree| {
                    self.thread_data.setActions(tree.*, pos);
                    for (tree.items) |item| {
                        std.debug.print("{any}\n", .{item});
                    }
                }
            } else {
                self.bo.modify_mutex.unlock();
            }

            return 0;
        }

        pub export fn getBlockId(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            self.beginHalt();
            defer self.endHalt();
            const name = self.vm.getArg(L, []const u8, 1);
            const id = self.world.reg.getBlockFromName(name);
            Lua.pushV(L, id);
            return 1;
        }

        pub export fn getBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            self.beginHalt();
            defer self.endHalt();

            const name = self.vm.getArg(L, []const u8, 1);
            const id = self.world.reg.getBlockFromNameI(name);
            Lua.pushV(L, id);
            return 1;
        }

        ///Args: landmarkName, blockname to search
        ///Returns, array of v3i
        pub export fn getFieldFlood(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            self.beginHalt();
            defer self.endHalt();
            const landmark = self.vm.getArg(L, []const u8, 1);
            const block_name = self.vm.getArg(L, []const u8, 2);
            const id = self.world.reg.getBlockFromName(block_name) orelse return 0;
            const coord = self.world.getSignWaypoint(landmark) orelse {
                std.debug.print("cant find waypoint: {s}\n", .{landmark});
                return 0;
            };
            //errc(self.pathctx.reset()) orelse return 0;
            const flood_pos = errc(self.pathctx.floodfillCommonBlock(coord.toF(), id)) orelse return 0;
            if (flood_pos) |fp| {
                Lua.pushV(L, fp.items);
                fp.deinit();
                return 1;
            }
            return 0;
        }

        //Arg chest_waypoint_name
        pub export fn interactChest(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 2);
            const name = self.vm.getArg(L, []const u8, 1);
            const to_move = self.vm.getArg(L, []const union(enum) {
                deposit: struct { name: []const u8 },
            }, 2);
            self.beginHalt();
            defer self.endHalt();
            const coord = self.world.getSignWaypoint(name) orelse return 0;
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            const pos = self.bo.pos.?;
            var actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(self.world.alloc);
            errc(actions.append(.{ .close_chest = {} })) orelse return 0;
            errc(actions.append(.{ .wait_ms = 2000 })) orelse return 0;
            for (to_move) |ac| {
                errc(actions.append(.{ .wait_ms = 500 })) orelse return 0;
                switch (ac) {
                    .deposit => |d| {
                        if (self.world.reg.getItemFromName(d.name)) |id| {
                            errc(actions.append(.{ .inventory = .{ .deposit = .{ .id = id.id, .kind = .all } } })) orelse break;
                        }
                    },
                }
            }
            errc(actions.append(.{ .open_chest = .{ .pos = coord } })) orelse return 0;
            self.thread_data.setActions(actions, pos);
            std.debug.print("interct with chest\n", .{});
            return 0;
        }
    };
};
pub fn luaBotScript(bo: *Bot, alloc: std.mem.Allocator, thread_data: *bot.BotScriptThreadData, world: *McWorld) !void {
    if (lss != null)
        return error.lua_script_state_AlreadyInit;
    var luavm = Lua.init();
    var script_state = LuaApi.init(alloc, world, bo, thread_data, &luavm);
    defer script_state.deinit();
    lss = &script_state;
    luavm.loadAndRunFile("bot.lua");
    while (true) {
        luavm.callLuaFunction("loop") catch |err| {
            switch (err) {
                error.luaError => break,
            }
        };
    }
}

pub fn simpleBotScript(bo: *Bot, alloc: std.mem.Allocator, thread_data: *bot.BotScriptThreadData, world: *McWorld) !void {
    const disable = false;
    const locations = [_]V3f{
        //V3f.new(-225, 68, 209),
        V3f.new(-236, 69, 204),
        //V3f.new(-216, 68, 184),
        //V3f.new(-278, 69, 195),
        //V3f.new(-326, 71, 115),
        //V3f.new(-278, 69, 195),
    };

    const waypoints = [_][]const u8{ "tools", "wood_drop", "mine1" };
    var waypoint_index: usize = 0;
    var location_index: usize = 0;
    var bot_command_index: u32 = 0;

    var pathctx = astar.AStarContext.init(alloc, world);
    defer pathctx.deinit();

    while (true) {
        thread_data.lock(.script_thread);
        if (thread_data.u_status == .terminate_thread) {
            std.debug.print("Stopping botScript thread\n", .{});
            thread_data.unlock(.script_thread);
            return;
        }

        defer bot_command_index += 1;
        defer std.time.sleep(std.time.ns_per_s / 10); //This sleep is here so updateBots has time to tryLock()
        defer thread_data.unlock(.script_thread);
        if (disable)
            continue;
        //Fake a coroutine
        switch (bot_command_index) {
            1 => {
                try pathctx.reset();
                bo.modify_mutex.lock();
                const pos = bo.pos.?;
                bo.modify_mutex.unlock();
                const found = try pathctx.pathfind(pos, locations[location_index]);
                location_index = (location_index + 1) % locations.len;
                if (found) |*actions|
                    thread_data.setActions(actions.*, pos);
            },
            2 => {
                bo.modify_mutex.lock();
                defer bo.modify_mutex.unlock();
                if (bo.inventory.findToolForMaterial(world.reg, "mineable/pickaxe")) |index| {
                    try thread_data.setActionSlice(alloc, &.{.{ .hold_item = .{ .slot_index = @as(u16, @intCast(index.slot_index)) } }}, V3i.new(0, 0, 0).toF());
                }
            },
            3 => {
                try pathctx.reset();
                bo.modify_mutex.lock();
                const pos = bo.pos.?;
                bo.modify_mutex.unlock();
                const coord = world.getSignWaypoint(waypoints[waypoint_index]) orelse {
                    std.debug.print("Cant find tools waypoint\n", .{});
                    continue;
                };
                waypoint_index = (waypoint_index + 1) % waypoints.len;
                const found = try pathctx.pathfind(pos, coord.toF());
                if (found) |*actions|
                    thread_data.setActions(actions.*, pos);
            },
            4 => {},
            5 => {
                try pathctx.reset();
                bo.modify_mutex.lock();
                const pos = bo.pos.?;
                if (bo.inventory.findToolForMaterial(world.reg, "mineable/axe")) |match| {
                    const wood_hardness = 2;
                    const btime = Reg.calculateBreakTime(match.mul, wood_hardness, .{});
                    //block hardness
                    //tool_multiplier
                    bo.modify_mutex.unlock();
                    const tree_o = try pathctx.findTree(pos, match.slot_index, @as(f64, (@floatFromInt(btime))) / 20);
                    if (tree_o) |*tree| {
                        thread_data.setActions(tree.*, pos);
                    }
                } else {
                    bo.modify_mutex.unlock();
                }
            },
            //2 => {
            //    var pathctx = astar.AStarContext.init(alloc, &world.chunk_data, &world.tag_table, reg);
            //    defer pathctx.deinit();
            //    bo.modify_mutex.lock();
            //    const found = try pathctx.findTree(bo.pos.?);
            //    if (found) |*actions|
            //        thread_data.setActions(actions.*, bo.pos.?);
            //    bo.modify_mutex.unlock();
            //},
            6 => std.time.sleep(std.time.ns_per_s),
            else => bot_command_index = 0,
        }
    }
}

pub fn updateBots(alloc: std.mem.Allocator, world: *McWorld, exit_mutex: *std.Thread.Mutex) !void {
    var bot_it_1 = world.bots.iterator();
    const bot1 = bot_it_1.next();
    if (bot1 == null)
        return error.NoBotsToSpawnScriptsFor;
    const bo = bot1.?.value_ptr;

    var b1_thread_data = bot.BotScriptThreadData.init(alloc);
    defer b1_thread_data.deinit();
    b1_thread_data.lock(.bot_thread);
    //const b1_thread = try std.Thread.spawn(.{}, simpleBotScript, .{ bo, alloc, &b1_thread_data, world });
    const b1_thread = try std.Thread.spawn(.{}, luaBotScript, .{ bo, alloc, &b1_thread_data, world });
    defer b1_thread.join();

    var skip_ticks: i32 = 0;
    const dt: f64 = 1.0 / 20.0;
    while (true) {
        if (exit_mutex.tryLock()) {
            std.debug.print("Stopping updateBots thread\n", .{});
            b1_thread_data.lock(.bot_thread);
            b1_thread_data.u_status = .terminate_thread;
            b1_thread_data.unlock(.bot_thread);
            return;
        }

        //The scriptThread will be blocked whenever we are in this block until we notify we need more actions by unlocking
        if (b1_thread_data.trylock(.bot_thread)) {
            var bp = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = (std.net.Stream{ .handle = bo.fd }).writer(), .mutex = &bo.fd_mutex };
            defer bp.deinit();
            bo.modify_mutex.lock();
            defer bo.modify_mutex.unlock();
            if (!bo.handshake_complete)
                continue;

            if (skip_ticks > 0) {
                skip_ticks -= 1;
            } else {
                const bt = &b1_thread_data;
                if (bt.action_index) |action| {
                    switch (bt.actions.items[action]) {
                        .movement => |move_| {
                            var move = move_;
                            var adt = dt;
                            var grounded = true;
                            var moved = false;
                            var pw = mc.lookAtBlock(bo.pos.?, V3f.new(0, 0, 0));
                            while (true) {
                                var move_vec = bt.move_state.update(adt);
                                grounded = move_vec.grounded;

                                bo.pos = move_vec.new_pos;
                                moved = true;

                                if (move_vec.move_complete) {
                                    bt.nextAction(move_vec.remaining_dt, bo.pos.?);
                                    if (bt.action_index) |new_acc| {
                                        if (bt.actions.items[new_acc] != .movement) {
                                            break;
                                        } else if (bt.actions.items[new_acc].movement.kind == .jump and move.kind == .jump) {
                                            bt.move_state.time = 0;
                                            //skip_ticks = 100;
                                            break;
                                        }
                                    } else {
                                        bt.unlock(.bot_thread); //We have no more left so notify
                                        break;
                                    }
                                } else {
                                    //TODO signal error
                                    break;
                                }
                                //move_vec = //above switch statement
                            }
                            if (moved) {
                                try bp.setPlayerPositionRot(bo.pos.?, pw.yaw, pw.pitch, grounded);
                            }
                        },
                        .wait_ms => |wms| {
                            skip_ticks = @intFromFloat(@as(f64, @floatFromInt(wms)) / 1000 / dt);
                            bt.nextAction(0, bo.pos.?);
                        },
                        .hold_item => |si| {
                            try bp.setHeldItem(0);
                            try bp.clickContainer(0, bo.container_state, si.slot_index, 0, 2, &.{}, null);
                            bt.nextAction(0, bo.pos.?);
                        },
                        .inventory => |ii| {
                            switch (ii) {
                                .deposit => |d| {
                                    const magic_num = 35;
                                    if (bo.interacted_inventory.win_id) |wid| {
                                        const player_inv_start = bo.interacted_inventory.slots.items.len - magic_num;
                                        for (bo.interacted_inventory.slots.items[player_inv_start..], player_inv_start..) |slot, i| {
                                            if (slot) |s| {
                                                if (s.item_id == d.id) {
                                                    try bp.clickContainer(wid, bo.container_state, @intCast(i), 0, 1, &.{}, null);
                                                    if (d.kind == .one)
                                                        break;
                                                }
                                            }
                                        }
                                    }
                                },
                            }
                            bt.nextAction(0, bo.pos.?);
                        },
                        .place_block => |pb| {
                            const pw = mc.lookAtBlock(bo.pos.?, pb.pos.toF());
                            try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                            try bp.useItemOn(.main, pb.pos, .bottom, 0, 0, 0, false, 0);
                            bt.nextAction(0, bo.pos.?);
                        },
                        .open_chest => |ii| {
                            const pw = mc.lookAtBlock(bo.pos.?, ii.pos.toF());
                            try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                            try bp.useItemOn(.main, ii.pos, .bottom, 0, 0, 0, false, 0);
                            bt.nextAction(0, bo.pos.?);
                        },
                        .close_chest => {
                            try bp.closeContainer(bo.interacted_inventory.win_id.?);
                            //bo.interacted_inventory.win_id = null;
                            bt.nextAction(0, bo.pos.?);
                        },
                        .block_break => |bb| {
                            if (bt.timer == null) {
                                const pw = mc.lookAtBlock(bo.pos.?, bb.pos.toF());
                                try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                try bp.playerAction(.start_digging, bb.pos);
                                bt.timer = dt;
                            } else {
                                bt.timer.? += dt;
                                if (bt.timer.? >= bb.break_time) {
                                    bt.timer = null;
                                    try bp.playerAction(.finish_digging, bb.pos);
                                    bt.nextAction(0, bo.pos.?);
                                }
                            }
                        },
                    }
                } else {
                    bt.unlock(.bot_thread);
                }
            }
        }

        //std.time.sleep(@as(u64, @intFromFloat(std.time.ns_per_s * (1.0 / 20.0))));
        std.time.sleep(@as(u64, @intFromFloat(std.time.ns_per_s * dt)));
    }
}

pub fn basicPathfindThread(
    alloc: std.mem.Allocator,
    world: *McWorld,
    start: V3f,
    goal: V3f,
    bot_handle: i32,
    return_ctx_mutex: *std.Thread.Mutex,
    return_ctx: *?astar.AStarContext,
) !void {
    std.debug.print("PATHFIND CALLED \n", .{});
    var pathctx = astar.AStarContext.init(alloc, world);
    errdefer pathctx.deinit();

    const found = try pathctx.pathfind(start, goal);
    if (found) |*actions| {
        const player_actions = actions;
        for (player_actions.items) |pitem| {
            std.debug.print("action: {any}\n", .{pitem});
        }

        const botp = world.bots.getPtr(bot_handle) orelse return error.invalidBotHandle;
        botp.modify_mutex.lock();
        botp.action_list.deinit();
        botp.action_list = player_actions.*;
        botp.action_index = player_actions.items.len;
        botp.nextAction(0);
        botp.modify_mutex.unlock();
    }
    std.debug.print("FINISHED DUMPING\n", .{});

    return_ctx_mutex.lock();
    if (return_ctx.* != null) {
        return_ctx.*.?.deinit();
    }
    return_ctx.* = pathctx;
    return_ctx_mutex.unlock();
    std.debug.print("PATHFIND FINISHED\n", .{});
}

pub fn drawThread(alloc: std.mem.Allocator, world: *McWorld, bot_fd: i32) !void {
    const InvMap = struct {
        default: []const [2]f32,
    };
    const inv_map = try common.readJson(std.fs.cwd(), "inv_map.json", alloc, InvMap);
    defer inv_map.deinit();

    var win = try graph.SDL.Window.createWindow("Debug mcbot Window", .{});
    defer win.destroyWindow();
    var ctx = try graph.GraphicsContext.init(alloc, 163);
    defer ctx.deinit();

    const mc_atlas = try mcBlockAtlas.buildAtlasGeneric(
        alloc,
        std.fs.cwd(),
        "res_pack",
        world.reg.blocks,
        "assets/minecraft/textures/block",
        "debug/mc_atlas.png",
    );
    defer mc_atlas.deinit(alloc);

    const item_atlas = try mcBlockAtlas.buildAtlasGeneric(
        alloc,
        std.fs.cwd(),
        "res_pack",
        world.reg.items,
        "assets/minecraft/textures/item",
        "debug/mc_itematlas.bmp",
    );
    defer item_atlas.deinit(alloc);

    var invtex = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "res_pack/assets/minecraft/textures/gui/container/inventory.png", .{});
    defer invtex.deinit();

    var camera = graph.Camera3D{};
    camera.pos.data = [_]f32{ -2.20040695e+02, 6.80385284e+01, 1.00785331e+02 };
    win.grabMouse(true);

    //A chunk is just a vertex array
    const ChunkVerts = struct {
        cubes: graph.Cubes,
    };
    var vert_map = std.AutoHashMap(i32, std.AutoHashMap(i32, ChunkVerts)).init(alloc);
    defer {
        var it = vert_map.iterator();
        while (it.next()) |kv| {
            var zit = kv.value_ptr.iterator();
            while (zit.next()) |zkv| { //Cubes
                zkv.value_ptr.cubes.deinit();
            }
            kv.value_ptr.deinit();
        }
        vert_map.deinit();
    }

    var position_synced = false;

    var font = try graph.Font.init(alloc, std.fs.cwd(), "dos.ttf", 16, 163, .{});
    defer font.deinit();

    var testmap = graph.Bind(&.{
        .{ "print_coord", "c" },
        .{ "toggle_draw_nodes", "t" },
    }).init();

    var draw_nodes: bool = false;

    //std.time.sleep(std.time.ns_per_s * 10);

    var cubes = graph.Cubes.init(alloc, mc_atlas.texture, ctx.tex_shad);
    defer cubes.deinit();

    const bot1 = world.bots.getPtr(bot_fd) orelse unreachable;
    const grass_block_id = world.reg.getBlockFromName("grass_block");

    var gctx = graph.NewCtx.init(alloc, 123);
    defer gctx.deinit();

    var astar_ctx_mutex: std.Thread.Mutex = .{};
    var astar_ctx: ?astar.AStarContext = null;
    defer {
        if (astar_ctx) |*actx| {
            actx.deinit();
        }
    }
    {
        try gctx.begin(0x263556ff);
        win.pumpEvents();
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        gctx.text(.{ .x = 40, .y = 30 }, "LOADING CHUNKS", &font, 72, 0xffffffff);
        gctx.end(win.screen_width, win.screen_height, graph.za.Mat4.zero());
        win.swap();
    }
    const wheat_id = world.reg.getBlockFromName("wheat") orelse 0;
    var wheat_pos: ?std.ArrayList(V3i) = null;
    defer {
        if (wheat_pos) |wh|
            wh.deinit();
    }
    var draw_inventory = true;

    //graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
    while (!win.should_exit) {
        try gctx.begin(0x2f2f2fff);
        try cubes.indicies.resize(0);
        try cubes.vertices.resize(0);
        win.pumpEvents(); //Important that this is called after beginDraw for input lag reasons

        for (win.keys.slice()) |key| {
            switch (testmap.get(key.scancode)) {
                .print_coord => std.debug.print("Camera pos: {any}\n", .{camera.pos}),
                .toggle_draw_nodes => draw_nodes = !draw_nodes,
                else => {},
            }
        }

        if (draw_nodes and astar_ctx_mutex.tryLock()) {
            if (astar_ctx) |actx| {
                for (actx.open.items) |item| {
                    try cubes.cube(
                        @as(f32, @floatFromInt(item.x)),
                        @as(f32, @floatFromInt(item.y)),
                        @as(f32, @floatFromInt(item.z)),
                        0.7,
                        0.2,
                        0.6,
                        mc_atlas.getTextureRec(1),
                        &[_]graph.CharColor{graph.itc(0xcb41dbff)} ** 6,
                    );
                }
                for (actx.closed.items) |item| {
                    try cubes.cube(
                        @as(f32, @floatFromInt(item.x)),
                        @as(f32, @floatFromInt(item.y)),
                        @as(f32, @floatFromInt(item.z)),
                        0.7,
                        0.2,
                        0.6,
                        mc_atlas.getTextureRec(1),
                        &[_]graph.CharColor{graph.itc(0xff0000ff)} ** 6,
                    );
                }
            }
            astar_ctx_mutex.unlock();
        }

        if (wheat_pos) |wh| {
            for (wh.items) |pos| {
                try cubes.cube(
                    @as(f32, @floatFromInt(pos.x)),
                    @as(f32, @floatFromInt(pos.y)) + 2,
                    @as(f32, @floatFromInt(pos.z)),
                    0.7,
                    0.2,
                    0.6,
                    mc_atlas.getTextureRec(1),
                    &[_]graph.CharColor{graph.itc(0xfffff0ff)} ** 6,
                );
            }
        }

        if (world.chunk_data.rw_lock.tryLockShared()) {
            defer world.chunk_data.rw_lock.unlockShared();
            {
                //Camera raycast to block
                const point_start = camera.pos;
                const count = 10;
                var t: f32 = 1;
                var i: u32 = 0;
                while (t < count) {
                    i += 1;
                    const mx = camera.front.data[0];
                    const my = camera.front.data[1];
                    const mz = camera.front.data[2];
                    t += 0.001;

                    const next_xt = if (@fabs(mx) < 0.001) 100000 else ((if (mx > 0) @ceil(mx * t + point_start.data[0]) else @floor(mx * t + point_start.data[0])) - point_start.data[0]) / mx;
                    const next_yt = if (@fabs(my) < 0.001) 100000 else ((if (my > 0) @ceil(my * t + point_start.data[1]) else @floor(my * t + point_start.data[1])) - point_start.data[1]) / my;
                    const next_zt = if (@fabs(mz) < 0.001) 100000 else ((if (mz > 0) @ceil(mz * t + point_start.data[2]) else @floor(mz * t + point_start.data[2])) - point_start.data[2]) / mz;
                    if (i > 10) break;

                    t = @min(next_xt, next_yt, next_zt);
                    if (t > count)
                        break;

                    const point = point_start.add(camera.front.scale(t + 0.01)).data;
                    //const point = point_start.lerp(point_end, t / count).data;
                    const pi = V3i{
                        .x = @as(i32, @intFromFloat(@floor(point[0]))),
                        .y = @as(i32, @intFromFloat(@floor(point[1]))),
                        .z = @as(i32, @intFromFloat(@floor(point[2]))),
                    };
                    if (world.chunk_data.getBlock(pi)) |block| {
                        if (block != 0) {
                            try cubes.cube(
                                @as(f32, @floatFromInt(pi.x)),
                                @as(f32, @floatFromInt(pi.y)),
                                @as(f32, @floatFromInt(pi.z)),
                                1.1,
                                1.2,
                                1.1,
                                mc_atlas.getTextureRec(1),
                                &[_]graph.CharColor{graph.itc(0xcb41db66)} ** 6,
                            );

                            if (win.mouse.left == .rising) {
                                bot1.modify_mutex.lock();
                                bot1.action_index = null;

                                _ = try std.Thread.spawn(.{}, basicPathfindThread, .{ alloc, world, bot1.pos.?, pi.toF().add(V3f.new(0, 1, 0)), bot1.fd, &astar_ctx_mutex, &astar_ctx });
                                bot1.modify_mutex.unlock();
                            }
                            if (win.mouse.right == .rising) {
                                std.debug.print("DOING THE FLOOD\n", .{});
                                if (wheat_pos) |wh| {
                                    wh.deinit();
                                }
                                wheat_pos = try astar_ctx.?.floodfillCommonBlock(pi.toF(), wheat_id);
                            }

                            break;
                        }
                    }
                }
            }

            for (world.chunk_data.rebuild_notify.items) |item| {
                const vx = try vert_map.getOrPut(item.x);
                if (!vx.found_existing) {
                    vx.value_ptr.* = std.AutoHashMap(i32, ChunkVerts).init(alloc);
                }
                const vz = try vx.value_ptr.getOrPut(item.y);
                if (!vz.found_existing) {
                    vz.value_ptr.cubes = graph.Cubes.init(alloc, mc_atlas.texture, ctx.tex_shad);
                } else {
                    try vz.value_ptr.cubes.indicies.resize(0);
                    try vz.value_ptr.cubes.vertices.resize(0);
                }

                if (world.chunk_data.x.get(item.x)) |xx| {
                    if (xx.get(item.y)) |chunk| {
                        for (chunk, 0..) |sec, sec_i| {
                            if (sec_i < 7) continue;
                            if (sec.bits_per_entry == 0) continue;
                            //var s_it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
                            //var block = s_it.next();

                            {
                                var i: u32 = 0;
                                while (i < 16 * 16 * 16) : (i += 1) {
                                    const block = sec.getBlockFromIndex(i);
                                    const itc = graph.itc;
                                    const bid = world.reg.getBlockIdFromState(block.block);
                                    if (bid == 0)
                                        continue;
                                    const colors = if (bid == grass_block_id) [_]graph.CharColor{itc(0x77c05aff)} ** 6 else null;
                                    const co = block.pos;
                                    const x = co.x + item.x * 16;
                                    const y = (co.y + @as(i32, @intCast(sec_i)) * 16) - 64;
                                    const z = co.z + item.y * 16;
                                    if (world.chunk_data.isOccluded(V3i.new(x, y, z)))
                                        continue;
                                    try vz.value_ptr.cubes.cube(
                                        @as(f32, @floatFromInt(x)),
                                        @as(f32, @floatFromInt(y)),
                                        @as(f32, @floatFromInt(z)),
                                        1,
                                        1,
                                        1,
                                        mc_atlas.getTextureRec(bid),
                                        if (colors) |col| &col else null,
                                    );
                                }
                            }
                        }
                        vz.value_ptr.cubes.setData();
                    } else {
                        vz.value_ptr.cubes.deinit();
                        _ = vx.value_ptr.remove(item.y);
                    }
                }
            }
            try world.chunk_data.rebuild_notify.resize(0);
        }

        { //Draw the chunks
            var it = vert_map.iterator();
            while (it.next()) |kv| {
                var zit = kv.value_ptr.iterator();
                while (zit.next()) |kv2| {
                    kv2.value_ptr.cubes.draw(win.screen_width, win.screen_height, camera.getMatrix(3840.0 / 2160.0, 85, 0.1, 100000));
                }
            }
        }

        {
            bot1.modify_mutex.lock();
            defer bot1.modify_mutex.unlock();
            if (bot1.pos) |bpos| {
                if (!position_synced) {
                    position_synced = true;
                    camera.pos = graph.za.Vec3.new(@floatCast(bpos.x), @floatCast(bpos.y + 3), @floatCast(bpos.z));
                }
                const p = bpos.toRay();
                try cubes.cube(
                    p.x - 0.3,
                    p.y,
                    p.z - 0.3,
                    0.6,
                    1.8,
                    0.6,
                    mc_atlas.getTextureRec(1),
                    &[_]graph.CharColor{graph.itc(0xcb41dbff)} ** 6,
                );
            }
            if (bot1.action_list.items.len > 0) {
                const list = bot1.action_list.items;
                var last_pos = bot1.pos.?;
                var i: usize = list.len;
                while (i > 0) : (i -= 1) {
                    switch (list[i - 1]) {
                        .movement => |move| {
                            const color: u32 = switch (move.kind) {
                                .walk => 0xff0000ff,
                                .fall => 0x0fff00ff,
                                .jump => 0x000fffff,
                                .ladder => 0x2222ffff,
                                .gap => 0x00ff00ff,
                                else => 0x000000ff,
                            };
                            const p = move.pos.toRay();
                            const lp = last_pos.toRay();
                            gctx.line3D(graph.Vec3f.new(lp.x, lp.y + 1, lp.z), graph.Vec3f.new(p.x, p.y + 1, p.z), 0xffffffff);
                            last_pos = move.pos;
                            try cubes.cube(
                                p.x,
                                p.y,
                                p.z,
                                0.2,
                                0.2,
                                0.2,
                                mc_atlas.getTextureRec(1),
                                &[_]graph.CharColor{graph.itc(color)} ** 6,
                            );
                        },
                        else => {},
                    }
                }
            }
        }

        cubes.setData();
        cubes.draw(win.screen_width, win.screen_height, camera.getMatrix(3840.0 / 2160.0, 85, 0.1, 100000));

        camera.update(&win);

        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        if (draw_inventory) {
            bot1.modify_mutex.lock();
            defer bot1.modify_mutex.unlock();
            const area = graph.Rec(0, 0, @divTrunc(win.screen_width, 3), @divTrunc(win.screen_width, 3));
            const sx = area.w / @as(f32, @floatFromInt(invtex.w));
            const sy = area.h / @as(f32, @floatFromInt(invtex.h));
            gctx.rectTex(area, invtex.rect(), 0xffffffff, invtex);
            for (bot1.inventory.slots.items, 0..) |slot, i| {
                const rr = inv_map.value.default[i];
                const rect = graph.Rec(area.x + rr[0] * sx, area.y + rr[1] * sy, 16 * sx, 16 * sy);
                if (slot) |s| {
                    if (item_atlas.getTextureRecO(s.item_id)) |tr| {
                        gctx.rectTex(rect, tr, 0xffffffff, item_atlas.texture);
                    } else {
                        const item = world.reg.getItem(s.item_id);
                        gctx.text(rect.pos(), item.name, &font, 14, 0xff);
                    }
                    gctx.textFmt(rect.pos().add(.{ .x = 0, .y = rect.h / 2 }), "{d}", .{s.count}, &font, 15, 0xff);
                }
            }

            if (bot1.interacted_inventory.win_id != null) {
                drawInventory(&gctx, &item_atlas, world.reg, &font, area.addV(area.w + 20, 0), &bot1.interacted_inventory);
            }
        }
        gctx.rect(graph.Rec(@divTrunc(win.screen_width, 2), @divTrunc(win.screen_height, 2), 10, 10), 0xffffffff);
        gctx.end(win.screen_width, win.screen_height, camera.getMatrix(3840.0 / 2160.0, 85, 0.1, 100000));
        //try ctx.beginDraw(graph.itc(0x2f2f2fff));
        //ctx.drawText(40, 40, "hello", &font, 16, graph.itc(0xffffffff));
        //ctx.endDraw(win.screen_width, win.screen_height);
        win.swap();
    }
}

fn drawInventory(
    gctx: *graph.NewCtx,
    item_atlas: *const mcBlockAtlas.McAtlas,
    reg: *const Reg.NewDataReg,
    font: *graph.Font,
    area: graph.Rect,
    inventory: *const bot.Inventory,
) void {
    const w = area.w;
    const icx = 9;
    const padding = 4;
    const iw: f32 = w / icx;
    //const h = w;
    for (inventory.slots.items, 0..) |slot, i| {
        const rr = graph.Rec(
            area.x + @as(f32, @floatFromInt(i % icx)) * iw,
            area.y + @as(f32, @floatFromInt(i / icx)) * iw,
            iw - padding,
            iw - padding,
        );
        gctx.rect(rr, 0xffffffff);
        if (slot) |s| {
            if (item_atlas.getTextureRecO(s.item_id)) |tr| {
                gctx.rectTex(rr, tr, 0xffffffff, item_atlas.texture);
            } else {
                const item = reg.getItem(s.item_id);
                gctx.text(rr.pos(), item.name, font, 12, 0xff);
            }
            gctx.textFmt(rr.pos().add(.{ .x = 0, .y = rr.h / 2 }), "{d}", .{s.count}, font, 20, 0xff);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var dr = try Reg.NewDataReg.init(alloc, "1.19.3");
    defer dr.deinit();

    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();
    const prog_name = arg_it.next() orelse unreachable;
    _ = prog_name;

    var draw = false;
    if (arg_it.next()) |action_arg| {
        if (eql(u8, action_arg, "analyze")) {
            //try packet_analyze.analyzeWalk(alloc, arg_it.next() orelse return);
            return;
        }
        if (eql(u8, action_arg, "draw")) {
            draw = true;
        }
        if (eql(u8, action_arg, "init")) {
            return;
        }
    }

    const bot_names = [_]struct { name: []const u8, sex: enum { male, female } }{
        .{ .name = "John", .sex = .male },
        //.{ .name = "James", .sex = .male },
        //.{ .name = "Charles", .sex = .male },
        //.{ .name = "George", .sex = .male },
        //.{ .name = "Henry", .sex = .male },
        //.{ .name = "Robert", .sex = .male },
        //.{ .name = "Harry", .sex = .male },
        //.{ .name = "Walter", .sex = .male },
        //.{ .name = "Fred", .sex = .male },
        //.{ .name = "Albert", .sex = .male },

        //.{ .name = "Mary", .sex = .female },
        //.{ .name = "Anna", .sex = .female },
        //.{ .name = "Emma", .sex = .female },
        //.{ .name = "Minnie", .sex = .female },
        //.{ .name = "Margaret", .sex = .female },
        //.{ .name = "Ada", .sex = .female },
        //.{ .name = "Annie", .sex = .female },
        //.{ .name = "Laura", .sex = .female },
        //.{ .name = "Rose", .sex = .female },
        //.{ .name = "Ethel", .sex = .female },
    };
    const epoll_fd = try std.os.epoll_create1(0);
    defer std.os.close(epoll_fd);

    var world = McWorld.init(alloc, &dr);
    defer world.deinit();

    //var creg = try Reg.DataRegContainer.init(alloc, std.fs.cwd(), "mcproto/converted/all.json");
    //defer creg.deinit();
    //const reg = creg.reg;

    var event_structs: [bot_names.len]std.os.linux.epoll_event = undefined;
    var stdin_event: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = std.io.getStdIn().handle } };
    try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, std.io.getStdIn().handle, &stdin_event);

    var bot_fd: i32 = 0;
    for (bot_names, 0..) |bn, i| {
        const mb = try botJoin(alloc, bn.name);
        event_structs[i] = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = mb.fd } };
        try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, mb.fd, &event_structs[i]);
        try world.bots.put(mb.fd, mb);
        if (bot_fd == 0)
            bot_fd = mb.fd;
    }

    var update_bots_exit_mutex: std.Thread.Mutex = .{};
    update_bots_exit_mutex.lock();
    const update_hand = try std.Thread.spawn(.{}, updateBots, .{ alloc, &world, &update_bots_exit_mutex });
    defer update_hand.join();

    var events: [256]std.os.linux.epoll_event = undefined;

    var run = true;
    var tb = PacketParse{ .buf = std.ArrayList(u8).init(alloc) };
    defer tb.buf.deinit();

    if (draw) {
        const draw_thread = try std.Thread.spawn(.{}, drawThread, .{ alloc, &world, bot_fd });
        draw_thread.detach();
    }

    var bps_timer = try std.time.Timer.start();
    var bytes_read: usize = 0;
    while (run) {
        if (bps_timer.read() > std.time.ns_per_s) {
            bps_timer.reset();
            //std.debug.print("KBps: {d}\n", .{@divTrunc(bytes_read, 1000)});
            bytes_read = 0;
        }
        const e_count = std.os.epoll_wait(epoll_fd, &events, 10);
        for (events[0..e_count]) |eve| {
            if (eve.data.fd == std.io.getStdIn().handle) {
                var msg: [256]u8 = undefined;
                const n = try std.os.read(eve.data.fd, &msg);
                var itt = std.mem.tokenize(u8, msg[0 .. n - 1], " ");
                const key = itt.next() orelse continue;
                std.debug.print("\"{s}\"\n", .{key});
                if (eql(u8, "exit", key)) {
                    update_bots_exit_mutex.unlock();
                    run = false;
                } else if (eql(u8, "draw", key)) {
                    const draw_thread = try std.Thread.spawn(.{}, drawThread, .{ alloc, &world, bot_fd });
                    draw_thread.detach();
                } else if (eql(u8, "query", key)) {
                    if (itt.next()) |tag_type| {
                        const tags = world.tag_table.tags.getPtr(tag_type) orelse unreachable;
                        var kit = tags.keyIterator();
                        var ke = kit.next();
                        std.debug.print("Possible sub tag: \n", .{});
                        while (ke != null) : (ke = kit.next()) {
                            std.debug.print("\t{s}\n", .{ke.?.*});
                        }
                    } else {
                        var kit = world.tag_table.tags.keyIterator();
                        var ke = kit.next();
                        std.debug.print("Possible tags: \n", .{});
                        while (ke != null) : (ke = kit.next()) {
                            std.debug.print("\t{s}\n", .{ke.?.*});
                        }
                    }
                }
                continue;
            }

            const pp = &tb;

            var pbuf: [4096]u8 = undefined;
            var ppos: u32 = 0;

            //TODO have early dropping of packets occur in this loop rather than in parseSwitch
            //parse the relevent fields to determine if a packet can be dropped, then use reader.skipBytes
            local: while (true) {
                switch (pp.state) {
                    .len => {
                        var buf: [1]u8 = .{0xff};
                        const n = try std.os.read(eve.data.fd, &buf);
                        if (n == 0)
                            unreachable;
                        //break :local;

                        pbuf[ppos] = buf[0];
                        ppos += 1;
                        //pp.buf.append(buf[0]) catch |err| break :blk err;
                        if (buf[0] & 0x80 == 0) {
                            var fbs = std.io.FixedBufferStream([]u8){ .buffer = pbuf[0..ppos], .pos = 0 };
                            pp.data_len = @as(u32, @intCast(mc.readVarInt(fbs.reader())));
                            pp.len_len = @as(u32, @intCast(ppos));

                            if (pp.data_len.? == 0)
                                unreachable;

                            pp.state = .data;
                            if (pp.data_len.? > pbuf.len - pp.len_len.?) {
                                try pp.buf.resize(pp.data_len.? + pp.len_len.?);
                                std.mem.copy(u8, pp.buf.items, pbuf[0..ppos]);
                                bytes_read += pp.data_len.?;
                            }
                        }
                    },
                    .data => {
                        const num_left_to_read = pp.data_len.? - pp.num_read;
                        const start = pp.len_len.? + pp.num_read;

                        if (pp.data_len.? > pbuf.len - pp.len_len.?) {
                            //TODO set this read to nonblocking?
                            const nr = try std.os.read(eve.data.fd, pp.buf.items[start .. start + num_left_to_read]);

                            pp.num_read += @as(u32, @intCast(nr));
                            if (nr == 0) //TODO properly support partial reads
                                unreachable;

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.bots.getPtr(eve.data.fd) orelse unreachable, pp.buf.items, &world);
                                //const node = alloc.create(QType.Node) catch |err| break :blk err;
                                //node.* = .{ .prev = null, .next = null, .data = .{ .fd = eve.data.fd, .buf = pp.buf.toOwnedSlice() } };
                                //q.put(node);
                                //pp.buf = std.ArrayList(u8).init(alloc);
                                try pp.buf.resize(0);
                                try pp.reset();
                                break :local;
                            }
                        } else {
                            const nr = try std.os.read(eve.data.fd, pbuf[start .. start + num_left_to_read]);
                            pp.num_read += @as(u32, @intCast(nr));

                            if (nr == 0) //TODO properly support partial reads
                                unreachable;

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.bots.getPtr(eve.data.fd) orelse unreachable, pbuf[0 .. pp.data_len.? + pp.len_len.?], &world);
                                bytes_read += pp.data_len.?;
                                try pp.reset();

                                break :local;
                            }
                        }

                        //break :local;

                    },
                }
            }
        }
    }
}
