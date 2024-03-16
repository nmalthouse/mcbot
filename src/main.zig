const std = @import("std");

const graph = @import("graph");
const mcBlockAtlas = @import("mc_block_atlas.zig");

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

const common = @import("common.zig");

const fbsT = std.io.FixedBufferStream([]const u8);
const AutoParse = mc.AutoParse;

const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;
const Entity = mcTypes.Entity;
const Lua = graph.Lua;

pub const PacketCache = struct {};

pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = myLogFn;
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default
    //const scope_prefix = "(" ++ switch (scope) {
    //    .my_project, .nice_library, std.log.default_log_scope => @tagName(scope),
    //    else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
    //        @tagName(scope)
    //    else
    //        return,
    //} ++ "): ";
    if (level == .info) {
        switch (scope) {
            .inventory,
            .world,
            .lua,
            .SDL,
            => return,
            else => {},
        }
    }
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn botJoin(alloc: std.mem.Allocator, bot_name: []const u8, script_name: ?[]const u8, ip: []const u8, port: u16) !Bot {
    const log = std.log.scoped(.parsing);
    var bot1 = try Bot.init(alloc, bot_name, script_name);
    errdefer bot1.deinit();
    const s = try std.net.tcpConnectToHost(alloc, ip, port);
    bot1.fd = s.handle;
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = s.writer(), .mutex = &bot1.fd_mutex };
    defer pctx.packet.deinit();
    try pctx.handshake(ip, port);
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
                log.warn("Disconnected: {s}\n", .{reason});
            },
            .Set_Compression => {
                const threshold = parse.varInt();
                comp_thresh = threshold;
                log.info("Setting Compression threshhold: {d}\n", .{threshold});
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
                log.err("Encryption_request: {any} {any} {any} EXITING\n", .{ server_id, public_key, verify_token });
                return error.notImplemented;
            },
            .Login_Success => {
                const uuid = parse.int(u128);
                const username = try parse.string(16);
                const n_props = @as(u32, @intCast(parse.varInt()));
                log.info("Login Success: {d}: {s}", .{ uuid, username });
                var n: u32 = 0;
                while (n < n_props) : (n += 1) {
                    const prop_name = try parse.string(null);
                    const value = try parse.string(null);
                    if (parse.boolean()) {
                        const sig = try parse.string(null);
                        _ = sig;
                    }
                    _ = prop_name;
                    _ = value;
                    //log.info("\t{s}: {s}\n", .{ prop_name, value });
                }

                bot1.uuid = uuid;
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
    const log = std.log.scoped(.parsing);
    const inv_log = std.log.scoped(.inventory);
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();

    var fbs_ = fbsT{ .buffer = packet_buf, .pos = 0 };
    const parseT = mc.packetParseCtx(fbsT.Reader);
    var parse = parseT.init(fbs_.reader(), arena_alloc);

    const plen = parse.varInt();
    _ = plen;
    const pid = parse.varInt();

    const P = AutoParse.P;
    const PT = AutoParse.parseType;

    const server_stream = std.net.Stream{ .handle = bot1.fd };

    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(arena_alloc), .server = server_stream.writer(), .mutex = &bot1.fd_mutex };
    //defer pctx.packet.deinit();

    if (bot1.connection_state != .play)
        return error.invalidConnectionState;
    const penum = @as(id_list.packet_enum, @enumFromInt(pid));
    switch (penum) {
        //WORLD specific packets
        .Plugin_Message => {
            const channel_name = try parse.string(null);
            log.info("{s}: {s}", .{ @tagName(penum), channel_name });

            try pctx.pluginMessage("tony:brand");
            try pctx.clientInfo("en_US", bot1.view_dist, 1);
        },
        .Change_Difficulty => {
            const diff = parse.int(u8);
            const locked = parse.int(u8);
            log.info("Set difficulty: {d}, Locked: {d}", .{ diff, locked });
        },
        .Player_Abilities => {
            log.info("Player Abilities packet", .{});
        },
        .Feature_Flags => {
            const num_feature = parse.varInt();
            log.info("Feature_Flags:", .{});

            var i: u32 = 0;
            while (i < num_feature) : (i += 1) {
                const feat = try parse.string(null);
                log.info("\t{s}", .{feat});
            }
        },
        .Spawn_Player => {
            const data = parse.auto(PT(&.{
                P(.varInt, "ent_id"),
                P(.uuid, "ent_uuid"),
                P(.V3f, "pos"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
            }));
            //log.info("Spawn player: {any}", .{data});
            try world.putEntity(data.ent_id, .{
                .kind = .@"minecraft:player",
                .uuid = data.ent_uuid,
                .pos = data.pos,
                .pitch = data.pitch,
                .yaw = data.yaw,
            });
        },
        .Spawn_Entity => {
            const Lt = PT(&.{
                P(.varInt, "ent_id"),
                P(.uuid, "ent_uuid"),
                P(.varInt, "ent_type"),
                P(.V3f, "pos"),
                P(.angle, "pitch"),
                P(.angle, "yaw"),
                P(.angle, "head_yaw"),
                P(.varInt, "data"),
                P(.shortV3i, "vel"),
            });
            const data = parse.auto(Lt);
            //std.debug.print("Spawn ent {any}\n", .{data});
            const ent_t = @as(id_list.entity_type_enum, @enumFromInt(data.ent_type));
            _ = ent_t;
            //std.debug.print("ent t: {s}\n", .{@tagName(ent_t)});

            try world.entities.put(data.ent_id, .{
                .kind = @enumFromInt(data.ent_type),
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
                world.removeEntity(e_id);
            }
        },
        .Update_Entity_Rotation => {
            const data = parse.auto(PT(&.{
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
            const data = parse.auto(PT(&.{
                P(.varInt, "ent_id"),
                P(.shortV3i, "del"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
                P(.boolean, "grounded"),
            }));
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
            if (world.entities.getPtr(data.ent_id)) |e| {
                e.pos = vector.deltaPosToV3f(e.pos, data.del);
                e.pitch = data.pitch;
                e.yaw = data.yaw;
            }
        },
        .Entity_Effect => {
            const data = parse.auto(PT(&.{
                P(.varInt, "ent_id"),
                P(.varInt, "effect_id"),
                P(.byte, "amplifier"),
                P(.varInt, "duration_ticks"),
                P(.byte, "flags"),
            }));
            _ = data;
            //if (data.id == bot1.e_id) {}
        },
        //TODO until we have some kind of ownership, entities will have invalid positions when multiple bots exists
        .Update_Entity_Position => {
            const data = parse.auto(PT(&.{ P(.varInt, "ent_id"), P(.shortV3i, "del"), P(.boolean, "grounded") }));
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
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
            _ = nbt_data;
            _ = pos;
            _ = btype;
            //_ = nbt_data;
        },
        .Teleport_Entity => {
            const data = parse.auto(PT(&.{
                P(.varInt, "ent_id"),
                P(.V3f, "pos"),
                P(.angle, "yaw"),
                P(.angle, "pitch"),
                P(.boolean, "grounded"),
            }));
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
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
            log.info("Game event: {d} {d}", .{ event, value });
        },
        .Update_Section_Blocks => {
            const chunk_pos = parse.chunk_position();
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
            if (!try world.chunk_data.tryOwn(cx, cy, bot1.uuid)) {
                //TODO keep track of owners better
                return;
            }

            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
            _ = nbt_data;
            const data_size = parse.varInt();
            var chunk_data = std.ArrayList(u8).init(alloc);
            defer chunk_data.deinit();
            try chunk_data.resize(@as(usize, @intCast(data_size)));
            try parse.reader.readNoEof(chunk_data.items);

            var chunk = mc.Chunk.init(alloc);
            try chunk.owners.put(bot1.uuid, {});
            var chunk_i: u32 = 0;
            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
            const cr = chunk_fbs.reader();
            while (chunk_i < mc.NUM_CHUNK_SECTION) : (chunk_i += 1) {
                const block_count = try cr.readInt(i16, .Big);
                _ = block_count;
                const chunk_section = &chunk.sections[chunk_i];

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
                                        if (eql(u8, "chest", bi.name)) {
                                            const name = try std.mem.concat(arena_alloc, u8, &.{ j.value.text, "_chest" });
                                            try world.putSignWaypoint(name, behind);
                                        } else if (eql(u8, "dropper", bi.name)) {
                                            const name = try std.mem.concat(arena_alloc, u8, &.{ j.value.text, "_dropper" });
                                            try world.putSignWaypoint(name, behind);
                                        } else if (eql(u8, "crafting_table", bi.name)) {
                                            const name = try std.mem.concat(arena_alloc, u8, &.{ j.value.text, "_craft" });
                                            try world.putSignWaypoint(name, behind);
                                        }
                                    }
                                }
                                try world.putSignWaypoint(j.value.text, coord);
                            }
                        }
                    }
                } else {
                    if (std.mem.eql(u8, "chest", b.name)) {
                        //be.nbt.format("", .{}, std.io.getStdErr().writer()) catch unreachable;
                    }
                }
            }
        },
        //Keep track of what bots have what chunks loaded and only unload chunks if none have it loaded
        .Unload_Chunk => {
            const data = parse.auto(PT(&.{ P(.int, "cx"), P(.int, "cz") }));
            try world.chunk_data.removeChunkColumn(data.cx, data.cz, bot1.uuid);
        },
        //BOT specific packets
        .Keep_Alive => {
            const data = parse.auto(PT(&.{P(.long, "keep_alive_id")}));

            try pctx.keepAlive(data.keep_alive_id);
        },
        .Login => {
            const data = parse.auto(PT(&.{
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
            log.warn("Combat death, id: {d}, killer_id: {d}, msg: {s}", .{ id, killer_id, msg });

            try pctx.clientCommand(0);
        },
        .Disconnect => {
            const reason = try parse.string(null);
            log.warn("Disconnected. Reason:  {s}", .{reason});
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
            inv_log.info("set_slot: win_id: {d}, state: {d}: slot_i: {d}, data: {any}", .{ win_id, state_id, slot_i, data });
            if (win_id == -1 and slot_i == -1) {
                bot1.held_item = data;
            } else if (win_id == 0) {
                bot1.container_state = state_id;
                try bot1.inventory.setSlot(@intCast(slot_i), data);
            } else if (bot1.interacted_inventory.win_id != null and win_id == bot1.interacted_inventory.win_id.?) {
                bot1.container_state = state_id;
                try bot1.interacted_inventory.setSlot(@intCast(slot_i), data);

                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 36);
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
            inv_log.info("open_win: win_id: {d}, win_type: {d}, title: {s}", .{ win_id, win_type, win_title });
        },
        .Set_Container_Content => {
            inv_log.info("set content packet", .{});
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
                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 36);
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
            const data = parse.auto(PT(&.{
                P(.V3f, "pos"),
                P(.float, "yaw"),
                P(.float, "pitch"),
                P(.byte, "flags"),
                P(.varInt, "tel_id"),
                P(.boolean, "should_dismount"),
            }));
            const Coord_fmt = "[{d:.2}, {d:.2}, {d:.2}]";

            log.warn("Sync Pos: new: " ++ Coord_fmt ++ " tel_id: {d}", .{ data.pos.x, data.pos.y, data.pos.z, data.tel_id });
            if (bot1.pos) |p|
                log.warn("\told: " ++ Coord_fmt ++ " diff: " ++ Coord_fmt, .{
                    p.x,              p.y,              p.z,
                    p.x - data.pos.x, p.y - data.pos.y, p.z - data.pos.z,
                });
            bot1.pos = data.pos;
            _ = FieldMask;

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
            _ = uuid;
            const index = parse.varInt();
            const sig_present_bool = parse.boolean();
            _ = index;
            if (sig_present_bool) {
                std.debug.print("CHAT SIG NOT SUPPORTED \n", .{});
                return error.notImplemented;
            }

            const msg = try parse.string(null);
            _ = msg;

            const timestamp = parse.int(u64);
            if (std.mem.indexOfScalar(u64, &world.packet_cache.chat_time_stamps.buf, timestamp) != null) {
                return;
            }
            world.packet_cache.chat_time_stamps.insert(timestamp);
        },
        else => {
            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, pid)]});
        },
    }
}

threadlocal var lss: ?*LuaApi = null;
pub const LuaApi = struct {
    const sToE = std.meta.stringToEnum;
    const log = std.log.scoped(.lua);
    const Self = @This();
    const ActionListT = std.ArrayList(astar.AStarContext.PlayerActionItem);
    const PlayerActionItem = astar.AStarContext.PlayerActionItem;
    thread_data: *bot.BotScriptThreadData,
    vm: *Lua,
    pathctx: astar.AStarContext,
    world: *McWorld,
    bo: *Bot,
    in_yield: bool = false,
    has_yield_fn: bool = false,

    fn stripErrorUnion(comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .ErrorUnion) @compileError("stripErrorUnion expects an error union!");
        return info.ErrorUnion.payload;
    }

    fn errc(to_check: anytype) ?stripErrorUnion(@TypeOf(to_check)) {
        return to_check catch |err| {
            lss.?.vm.putError(@errorName(err));
            return null;
        };
    }

    pub fn init(alloc: std.mem.Allocator, world: *McWorld, bo: *Bot, thread_data: *bot.BotScriptThreadData, vm: *Lua) Self {
        vm.registerAllStruct(Api);
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
        if (!self.in_yield and self.has_yield_fn) {
            self.in_yield = true;
            self.vm.callLuaFunction("onYield") catch {};
            self.in_yield = false;
        }

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
        pub const LUA_PATH: []const u8 = "?;?.lua;scripts/?.lua;scripts/?";

        pub export fn testff(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const ret = self.vm.getArg(L, []const f32, 1);
            std.debug.print("{any}\n", .{ret});
            return 0;
        }

        pub export fn floodFindColumn(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const ret = self.vm.getArg(L, []const union {
                one: struct {
                    y: i32 = 0, //If y isn't specified, use last y + 1
                    tag: []const u8,
                },
                n: struct {
                    y: i32 = 0,
                    max: i32,
                    tag: []const u8,
                },
            }, 1);
            for (ret) |r| {
                std.debug.print("{any}\n", .{r});
            }

            self.beginHalt();
            defer self.endHalt();
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
            std.debug.print("BLCK NOT FOUNd\n", .{});
            return 0;
        }

        pub export fn sleepms(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const n_ms = self.vm.getArg(L, u64, 1);
            const max_time_ms = 500;
            if (n_ms > max_time_ms) {
                var remaining = n_ms;
                while (remaining > max_time_ms) : (remaining -= max_time_ms) {
                    self.beginHalt();
                    defer self.endHalt();
                    std.time.sleep(max_time_ms * std.time.ns_per_ms);
                }
            }
            const stime = n_ms % max_time_ms;
            self.beginHalt();
            defer self.endHalt();
            std.time.sleep(stime);
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
                log.warn("Can't find waypoint: {s}", .{str});
                return 0;
            };
            const found = self.pathctx.pathfind(pos, coord.toF()) catch unreachable;
            if (found) |*actions|
                self.thread_data.setActions(actions.*, pos);

            return 0;
        }

        pub export fn assignMine(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.beginHalt();
            defer self.endHalt();

            self.world.mine_mutex.lock();
            defer self.world.mine_mutex.unlock();

            var buf: [20]u8 = undefined;
            var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
            fbs.writer().print("mine{d}", .{self.world.mine_index}) catch return 0;
            self.world.mine_index += 1;
            Lua.pushV(L, fbs.getWritten());
            return 1;
        }

        pub export fn findNearbyItems(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const max_dist = self.vm.getArg(L, f64, 1);
            self.beginHalt();
            defer self.endHalt();

            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            defer self.bo.modify_mutex.unlock();

            var list = std.ArrayList(V3i).init(self.vm.fba.allocator());

            self.world.entities_mutex.lock();
            defer self.world.entities_mutex.unlock();
            var e_it = self.world.entities.iterator();
            while (e_it.next()) |e| {
                if (e.value_ptr.kind == .@"minecraft:item") {
                    if (e.value_ptr.pos.subtract(pos).magnitude() < max_dist) {
                        const bpos = V3i.new(
                            @intFromFloat(@floor(e.value_ptr.pos.x)),
                            @intFromFloat(@floor(e.value_ptr.pos.y)),
                            @intFromFloat(@floor(e.value_ptr.pos.z)),
                        );
                        list.append(bpos) catch return 0;
                    }
                }
            }

            Lua.pushV(L, list.items);
            return 1;
        }

        pub export fn getLandmark(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const str = self.vm.getArg(L, []const u8, 1);
            self.beginHalt();
            defer self.endHalt();

            const coord = self.world.getSignWaypoint(str) orelse {
                log.warn("Can't find waypoint: {s}", .{str});
                return 0;
            };

            Lua.printStack(L);
            Lua.pushV(L, coord);
            _ = Lua.c.lua_getglobal(L, Lua.zstring("Vec3"));
            Lua.printStack(L);
            Lua.c.lua_setfield(L, -2, "__index");
            _ = Lua.c.lua_getglobal(L, Lua.zstring("Vec3"));
            _ = Lua.c.lua_setmetatable(L, -2);
            //Lua.c.lua_pop(L, 1);
            Lua.printStack(L);
            return 1;
        }

        //Arg x y z, item_name
        pub export fn placeBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            const bposf = self.vm.getArg(L, V3f, 1);
            const bpos = V3i.new(
                @intFromFloat(@floor(bposf.x)),
                @intFromFloat(@floor(bposf.y)),
                @intFromFloat(@floor(bposf.z)),
            );
            const item_name = self.vm.getArg(L, []const u8, 2);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            defer self.bo.modify_mutex.unlock();
            if (self.bo.inventory.findItem(self.world.reg, item_name)) |found| {
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
                        _ = item;
                        //std.debug.print("{any}\n", .{item});
                    }
                } else {
                    Lua.pushV(L, false);
                    return 1;
                }
            } else {
                self.bo.modify_mutex.unlock();
            }

            Lua.pushV(L, true);
            return 1;
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

        pub export fn craftingTest(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const name = self.vm.getArg(L, []const u8, 1);
            self.beginHalt();
            defer self.endHalt();
            var actions = ActionListT.init(self.world.alloc);
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            const pos = self.bo.pos.?;
            const coord = self.world.getSignWaypoint(name) orelse return 0;
            errc(actions.append(.{ .close_chest = {} })) orelse return 0;
            errc(actions.append(.{ .wait_ms = 2000 })) orelse return 0;
            errc(actions.append(.{ .craft = 0 })) orelse return 0;
            errc(actions.append(.{ .open_chest = .{ .pos = coord } })) orelse return 0;
            self.thread_data.setActions(actions, pos);
            return 0;
        }

        //Arg chest_waypoint_name
        //TODO support globbing *_axe matches diamond_axe, stone_axe
        pub export fn interactChest(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 2);
            const name = self.vm.getArg(L, []const u8, 1);
            const to_move = self.vm.getArg(L, [][]const u8, 2);
            self.beginHalt();
            defer self.endHalt();
            const coord = self.world.getSignWaypoint(name) orelse {
                std.debug.print("interactChest can't find waypoint {s}\n", .{name});
                return 0;
            };
            //std.debug.print("Interact chest query : {s}\n", .{to_move});
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            const pos = self.bo.pos.?;
            var actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(self.world.alloc);
            errc(actions.append(.{ .close_chest = {} })) orelse return 0;
            errc(actions.append(.{ .wait_ms = 2000 })) orelse return 0;
            var m_i = to_move.len;
            while (m_i > 0) {
                m_i -= 1;
                const mv_str = to_move[m_i];
                errc(actions.append(.{ .wait_ms = 500 })) orelse return 0;
                var it = std.mem.tokenizeScalar(u8, mv_str, ' ');
                // "DIRECTION COUNT MATCH_TYPE MATCH_PARAMS
                const dir_str = it.next() orelse {
                    self.vm.putErrorFmt("expected string", .{});
                    return 0;
                };
                const dir = sToE(PlayerActionItem.Inv.ItemMoveDirection, dir_str) orelse {
                    self.vm.putErrorFmt("invalid direction: {s}", .{dir_str});
                    return 0;
                };
                const count_str = it.next() orelse {
                    self.vm.putError("expected count");
                    return 0;
                };
                const count = if (eql(u8, count_str, "all")) 0xff else (std.fmt.parseInt(u8, count_str, 10)) catch {
                    self.vm.putErrorFmt("invalid count: {s}", .{count_str});
                    return 0;
                };
                const match_str = it.next() orelse {
                    self.vm.putError("expected match predicate");
                    return 0;
                };
                const match = sToE(enum { item, any, category }, match_str) orelse {
                    self.vm.putErrorFmt("invalid match predicate: {s}", .{match_str});
                    return 0;
                };
                errc(actions.append(.{
                    .inventory = .{
                        .direction = dir,
                        .count = count,
                        .match = blk: {
                            switch (match) {
                                .item => {
                                    const item_name = it.next() orelse {
                                        self.vm.putError("expected item name");
                                        return 0;
                                    };
                                    const item_id = self.world.reg.getItemFromName(item_name) orelse {
                                        self.vm.putErrorFmt("invalid item name: {s}", .{item_name});
                                        return 0;
                                    };
                                    break :blk .{ .by_id = item_id.id };
                                },
                                .any => break :blk .{ .match_any = {} },
                                .category => {
                                    const cat_str = it.next() orelse {
                                        self.vm.putError("expected category name");
                                        return 0;
                                    };
                                    const cat = sToE(PlayerActionItem.Inv.ItemCategory, cat_str) orelse {
                                        self.vm.putErrorFmt("unknown category: {s}", .{cat_str});
                                        return 0;
                                    };
                                    break :blk .{ .category = cat };
                                },
                            }
                        },
                    },
                })) orelse break;
            }
            errc(actions.append(.{ .open_chest = .{ .pos = coord } })) orelse return 0;
            self.thread_data.setActions(actions, pos);
            return 0;
        }

        pub export fn getPosition(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();

            Lua.pushV(L, self.bo.pos.?);
            return 1;
        }

        pub export fn getHunger(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();

            Lua.pushV(L, self.bo.food);
            return 1;
        }

        pub export fn timestamp(L: Lua.Ls) c_int {
            Lua.pushV(L, std.time.timestamp());
            return 1;
        }

        pub export fn itemCount(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const query = self.vm.getArg(L, []const u8, 1);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var it = std.mem.tokenizeScalar(u8, query, ' ');
            const match_str = it.next() orelse {
                self.vm.putErrorFmt("expected string", .{});
                return 0;
            };
            const match = sToE(enum { item, any, category }, match_str) orelse {
                self.vm.putErrorFmt("invalid match predicate: {s}", .{match_str});
                return 0;
            };
            var item_id: Reg.Item = undefined;
            var cat: PlayerActionItem.Inv.ItemCategory = undefined;
            switch (match) {
                .item => {
                    const item_name = it.next() orelse {
                        self.vm.putError("expected item name");
                        return 0;
                    };
                    item_id = self.world.reg.getItemFromName(item_name) orelse {
                        self.vm.putErrorFmt("invalid item name: {s}", .{item_name});
                        return 0;
                    };
                },
                .category => {
                    const cat_str = it.next() orelse {
                        self.vm.putError("expected category name");
                        return 0;
                    };
                    cat = sToE(PlayerActionItem.Inv.ItemCategory, cat_str) orelse {
                        self.vm.putErrorFmt("unknown category: {s}", .{cat_str});
                        return 0;
                    };
                },
                else => {},
            }
            var item_count: usize = 0;
            for (self.bo.inventory.slots.items) |sl| {
                const slot = sl orelse continue;

                switch (match) {
                    .item => {
                        if (slot.item_id == item_id.id)
                            item_count += slot.count;
                    },
                    .any => {
                        item_count += slot.count;
                    },
                    .category => {
                        switch (cat) {
                            .food => {
                                for (self.world.reg.foods) |food| {
                                    if (food.id == slot.item_id) {
                                        item_count += slot.count;
                                        break;
                                    }
                                }
                            },
                        }
                    },
                }
            }

            Lua.pushV(L, item_count);
            return 1;
        }

        pub export fn countFreeSlots(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            self.beginHalt();
            defer self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var count: usize = 0;
            for (self.bo.inventory.slots.items) |sl| {
                if (sl == null)
                    count += 1;
            }
            Lua.pushV(L, count);
            return 1;
        }

        pub export fn eatFood(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            self.beginHalt();
            defer self.endHalt();

            self.bo.modify_mutex.lock();
            const pos = self.bo.pos.?;
            defer self.bo.modify_mutex.unlock();
            if (self.bo.inventory.findItemFromList(self.world.reg.foods, "id")) |food_slot| {
                var actions = ActionListT.init(self.world.alloc);
                errc(actions.append(.{ .eat = {} })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(food_slot.index)) } })) orelse return 0;
                self.thread_data.setActions(actions, pos);
                Lua.pushV(L, true);
                return 1;
            }
            Lua.pushV(L, false);
            return 1;
        }
    };
};
pub fn luaBotScript(bo: *Bot, alloc: std.mem.Allocator, thread_data: *bot.BotScriptThreadData, world: *McWorld, filename: []const u8) !void {
    if (lss != null)
        return error.lua_script_state_AlreadyInit;
    var luavm = Lua.init();
    var script_state = LuaApi.init(alloc, world, bo, thread_data, &luavm);
    defer script_state.deinit();
    lss = &script_state;
    luavm.loadAndRunFile("scripts/common.lua");
    luavm.loadAndRunFile(filename);
    _ = Lua.c.lua_getglobal(luavm.state, "onYield");
    const t = Lua.c.lua_type(luavm.state, 1);
    Lua.c.lua_pop(luavm.state, 1);
    if (t == Lua.c.LUA_TFUNCTION) {
        script_state.has_yield_fn = true;
    }

    while (true) {
        luavm.callLuaFunction("loop") catch |err| {
            switch (err) {
                error.luaError => break,
            }
        };
    }
}

//TODO the bots scripts depend on the world being loaded for gotoWaypoint etc.
//currently we just sleep for some time, a better way would be to wait spawning the threads until some condition.
//Maybe having n chunks loaded or certain waypoints added
pub fn updateBots(alloc: std.mem.Allocator, world: *McWorld, exit_mutex: *std.Thread.Mutex) !void {
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();

    //BAD, give the bot time to load in chunks and inventory before we start the script
    std.time.sleep(std.time.ns_per_s * 2);

    var bot_threads = std.ArrayList(std.Thread).init(alloc);
    var bot_threads_data = std.ArrayList(*bot.BotScriptThreadData).init(alloc);
    defer {
        for (bot_threads.items) |th|
            th.join();
        bot_threads.deinit();

        for (bot_threads_data.items) |btd| {
            btd.deinit();
            alloc.destroy(btd);
        }
        bot_threads_data.deinit();
    }

    var bots_it = world.bots.iterator();
    while (bots_it.next()) |b| {
        b.value_ptr.modify_mutex.lock();
        defer b.value_ptr.modify_mutex.unlock();
        if (b.value_ptr.script_filename) |sn| {
            const btd = try alloc.create(bot.BotScriptThreadData);
            btd.* = bot.BotScriptThreadData.init(alloc, b.value_ptr);
            btd.lock(.bot_thread);
            try bot_threads_data.append(btd);
            try bot_threads.append(try std.Thread.spawn(.{}, luaBotScript, .{
                b.value_ptr,
                alloc,
                btd,
                world,
                sn,
            }));
        }
    }

    //var b1_thread_data = bot.BotScriptThreadData.init(alloc);
    //defer b1_thread_data.deinit();
    //b1_thread_data.lock(.bot_thread);
    //const b1_thread = try std.Thread.spawn(.{}, luaBotScript, .{ bo, alloc, &b1_thread_data, world });
    //defer b1_thread.join();

    var skip_ticks: i32 = 0;
    const dt: f64 = 1.0 / 20.0;
    while (true) {
        if (exit_mutex.tryLock()) {
            std.debug.print("Stopping updateBots thread\n", .{});
            for (bot_threads_data.items) |th_d| {
                th_d.lock(.bot_thread);
                defer th_d.unlock(.bot_thread);
                th_d.u_status = .terminate_thread;
            }
            return;
        } else if (world.bot_reload_mutex.tryLock()) {
            defer world.bot_reload_mutex.unlock();
            if (world.reload_bot_id) |id| {
                if (world.bots.get(id)) |b| {
                    for (bot_threads_data.items, 0..) |th_d, i| {
                        if (th_d.bot.fd == b.fd) {
                            th_d.lock(.bot_thread);
                            th_d.u_status = .terminate_thread;
                            th_d.unlock(.bot_thread);
                            bot_threads.items[i].join();
                            th_d.u_status = .actions_empty;

                            std.debug.print("Spawning new\n", .{});
                            bot_threads.items[i] = try std.Thread.spawn(.{}, luaBotScript, .{
                                th_d.bot,
                                alloc,
                                th_d,
                                world,
                                b.script_filename.?,
                            });
                            world.reload_bot_id = null;
                            break;
                        }
                    }
                }
            }
        }

        for (bot_threads_data.items) |th_d| {
            if (th_d.trylock(.bot_thread)) {
                const bo = th_d.bot;
                var bp = mc.PacketCtx{ .packet = try mc.Packet.init(arena_alloc), .server = (std.net.Stream{ .handle = bo.fd }).writer(), .mutex = &bo.fd_mutex };
                bo.modify_mutex.lock();
                defer bo.modify_mutex.unlock();
                if (!bo.handshake_complete)
                    continue;

                if (skip_ticks > 0) {
                    skip_ticks -= 1;
                } else {
                    if (th_d.action_index) |action| {
                        switch (th_d.actions.items[action]) {
                            .movement => |move_| {
                                var move = move_;
                                var adt = dt;
                                var grounded = true;
                                var moved = false;
                                var pw = mc.lookAtBlock(bo.pos.?, V3f.new(0, 0, 0));
                                while (true) {
                                    var move_vec = th_d.move_state.update(adt);
                                    grounded = move_vec.grounded;

                                    bo.pos = move_vec.new_pos;
                                    moved = true;

                                    if (move_vec.move_complete) {
                                        th_d.nextAction(move_vec.remaining_dt, bo.pos.?);
                                        if (th_d.action_index) |new_acc| {
                                            if (th_d.actions.items[new_acc] != .movement) {
                                                break;
                                            } else if (th_d.actions.items[new_acc].movement.kind == .jump and move.kind == .jump) {
                                                th_d.move_state.time = 0;
                                                //skip_ticks = 100;
                                                break;
                                            }
                                        } else {
                                            th_d.unlock(.bot_thread); //We have no more left so notify
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
                            .eat => {
                                const EATING_TIME_S = 1.61;
                                if (th_d.timer == null) {
                                    try bp.useItem(.main, 0);
                                    th_d.timer = dt;
                                } else {
                                    th_d.timer.? += dt;
                                    if (th_d.timer.? >= EATING_TIME_S) {
                                        try bp.playerAction(.shoot_arrowEat, .{ .x = 0, .y = 0, .z = 0 });
                                        th_d.nextAction(0, bo.pos.?);
                                    }
                                }
                            },
                            .wait_ms => |wms| {
                                skip_ticks = @intFromFloat(@as(f64, @floatFromInt(wms)) / 1000 / dt);
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .hold_item => |si| {
                                try bp.setHeldItem(0);
                                try bp.clickContainer(0, bo.container_state, si.slot_index, 0, 2, &.{}, null);
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .craft => |cr| {
                                _ = cr;
                                if (bo.interacted_inventory.win_id) |wid| {
                                    const magic_num = 35;
                                    const inv_len = bo.interacted_inventory.slots.items.len;
                                    const player_inv_start = inv_len - magic_num;
                                    const search_i = player_inv_start;
                                    const search_i_end = inv_len;
                                    const oak_log = world.reg.getItemFromName("oak_log") orelse unreachable;
                                    for (bo.interacted_inventory.slots.items[search_i..search_i_end], search_i..) |slot, i| {
                                        const s = slot orelse continue;
                                        if (s.item_id == oak_log.id) {
                                            try bp.clickContainer(wid, bo.container_state, @intCast(i), 0, 0, &.{}, slot);

                                            //Index 5 is middle of crafting table
                                            try bp.clickContainer(wid, bo.container_state, 5, 0, 0, &.{}, null);

                                            //index 0 is crafting result
                                            try bp.clickContainer(wid, bo.container_state, 0, 1, 0, &.{}, null);
                                        }
                                    }
                                }
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .inventory => |inv| {
                                if (bo.interacted_inventory.win_id) |wid| {
                                    //std.debug.print("Inventory interact:  {any}\n", .{inv});
                                    var num_transfered: u8 = 0;
                                    const magic_num = 36; //should this be 36?
                                    const inv_len = bo.interacted_inventory.slots.items.len;
                                    const player_inv_start = inv_len - magic_num;
                                    const search_i = if (inv.direction == .deposit) player_inv_start else 0;
                                    const search_i_end = if (inv.direction == .deposit) inv_len else player_inv_start;
                                    for (bo.interacted_inventory.slots.items[search_i..search_i_end], search_i..) |slot, i| {
                                        const s = slot orelse continue;
                                        var should_move = false;
                                        switch (inv.match) {
                                            .by_id => |match_id| {
                                                if (s.item_id == match_id) {
                                                    should_move = true;
                                                }
                                            },
                                            .match_any => should_move = true,
                                            .category => |cat| {
                                                switch (cat) {
                                                    .food => {
                                                        for (world.reg.foods) |food| {
                                                            if (food.id == s.item_id)
                                                                should_move = true;
                                                        }
                                                    },
                                                }
                                            },
                                        }
                                        if (should_move) {
                                            try bp.clickContainer(wid, bo.container_state, @intCast(i), 0, 1, &.{}, null);
                                            num_transfered += 1;
                                            if (num_transfered == inv.count)
                                                break;
                                        }
                                    }
                                }
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .place_block => |pb| {
                                const pw = mc.lookAtBlock(bo.pos.?, pb.pos.toF());
                                try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                try bp.useItemOn(.main, pb.pos, .bottom, 0, 0, 0, false, 0);
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .open_chest => |ii| {
                                const pw = mc.lookAtBlock(bo.pos.?, ii.pos.toF());
                                try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                try bp.useItemOn(.main, ii.pos, .bottom, 0, 0, 0, false, 0);
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .close_chest => {
                                try bp.closeContainer(bo.interacted_inventory.win_id.?);
                                //bo.interacted_inventory.win_id = null;
                                th_d.nextAction(0, bo.pos.?);
                            },
                            .block_break => |bb| {
                                if (th_d.timer == null) {
                                    const pw = mc.lookAtBlock(bo.pos.?, bb.pos.toF());
                                    try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                    try bp.playerAction(.start_digging, bb.pos);
                                    th_d.timer = dt;
                                } else {
                                    th_d.timer.? += dt;
                                    if (th_d.timer.? >= bb.break_time) {
                                        th_d.timer = null;
                                        try bp.playerAction(.finish_digging, bb.pos);
                                        th_d.nextAction(0, bo.pos.?);
                                    }
                                }
                            },
                        }
                    } else {
                        th_d.unlock(.bot_thread);
                    }
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
    return_ctx: *astar.AStarContext,
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
    return_ctx.*.deinit();
    return_ctx.* = pathctx;
    return_ctx_mutex.unlock();
    std.debug.print("PATHFIND FINISHED\n", .{});
}

fn drawTextCube(win: *graph.SDL.Window, gctx: *graph.NewCtx, cmatrix: graph.za.Mat4, cubes: *graph.Cubes, pos: V3f, tr: graph.Rect, text: []const u8, font: *graph.Font) !void {
    try cubes.cubeVec(pos, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, tr);
    const tpos = cmatrix.mulByVec4(graph.za.Vec4.new(
        @floatCast(pos.x),
        @floatCast(pos.y),
        @floatCast(pos.z),
        1,
    ));
    const w = tpos.w();
    const z = tpos.z();
    const pp = graph.Vec2f.new(tpos.x() / w, tpos.y() / -w);
    const dist_in_blocks = 10;
    if (z < dist_in_blocks and z > 0 and @fabs(pp.x) < 1 and @fabs(pp.y) < 1) {
        const sw = win.screen_dimensions.toF().smul(0.5);
        const spos = pp.mul(sw).add(sw);
        gctx.text(spos, text, font, 12, 0xffffffff);
    }
}

pub fn drawThread(alloc: std.mem.Allocator, world: *McWorld, bot_fd: i32) !void {
    const InvMap = struct {
        default: []const [2]f32,
        generic_9x3: []const [2]f32,
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

    var invtex = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "res_pack/assets/minecraft/textures/gui/container/inventory.png", .{ .mag_filter = graph.c.GL_NEAREST });
    defer invtex.deinit();

    var invtex2 = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "res_pack/assets/minecraft/textures/gui/container/shulker_box.png", .{});
    defer invtex2.deinit();

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

    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/fonts/roboto.ttf", 16, 163, .{});
    defer font.deinit();

    const KeyMap = graph.Bind(&.{
        .{ "print_coord", "c" },
        .{ "toggle_draw_nodes", "t" },
        .{ "toggle_inventory", "e" },
        .{ "toggle_caves", "f" },
    });
    var testmap = KeyMap.init();

    var draw_nodes: bool = false;

    //std.time.sleep(std.time.ns_per_s * 10);

    var cubes = graph.Cubes.init(alloc, mc_atlas.texture, ctx.tex_shad);
    defer cubes.deinit();

    const bot1 = world.bots.getPtr(bot_fd) orelse unreachable;
    const grass_block_id = world.reg.getBlockFromName("grass_block");

    var gctx = graph.NewCtx.init(alloc, 123);
    defer gctx.deinit();

    var astar_ctx_mutex: std.Thread.Mutex = .{};
    var astar_ctx = astar.AStarContext.init(alloc, world);
    defer astar_ctx.deinit();
    {
        try gctx.begin(0x263556ff, win.screen_dimensions.toF());
        win.pumpEvents();
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        gctx.text(.{ .x = 40, .y = 30 }, "LOADING CHUNKS", &font, 72, 0xffffffff);
        try gctx.end();
        win.swap();
    }
    const wheat_id = world.reg.getBlockFromName("wheat") orelse 0;
    var wheat_pos: ?std.ArrayList(V3i) = null;
    defer {
        if (wheat_pos) |wh|
            wh.deinit();
    }
    var draw_inventory = true;
    var display_caves = false;

    //graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
    while (!win.should_exit) {
        try gctx.begin(0x467b8cff, win.screen_dimensions.toF());
        try cubes.indicies.resize(0);
        try cubes.vertices.resize(0);
        win.pumpEvents();
        camera.update(&win);
        const cmatrix = camera.getMatrix(3840.0 / 2160.0, 85, 0.1, 100000);

        for (win.keys.slice()) |key| {
            switch (testmap.get(key.scancode)) {
                .print_coord => std.debug.print("Camera pos: {any}\n", .{camera.pos}),
                .toggle_draw_nodes => draw_nodes = !draw_nodes,
                .toggle_inventory => draw_inventory = !draw_inventory,
                .toggle_caves => display_caves = !display_caves,
                else => {},
            }
        }
        {
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
            var e_it = world.entities.valueIterator();
            while (e_it.next()) |e| {
                try drawTextCube(&win, &gctx, cmatrix, &cubes, e.pos, mc_atlas.getTextureRec(88), @tagName(e.kind), &font);
            }
        }
        {
            world.sign_waypoints_mutex.lock();
            defer world.sign_waypoints_mutex.unlock();
            var w_it = world.sign_waypoints.iterator();
            while (w_it.next()) |w| {
                try drawTextCube(&win, &gctx, cmatrix, &cubes, w.value_ptr.*.toF(), mc_atlas.getTextureRec(88), w.key_ptr.*, &font);
            }
        }

        if (draw_nodes and astar_ctx_mutex.tryLock()) {
            for (astar_ctx.open.items) |item| {
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
            for (astar_ctx.closed.items) |item| {
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
                                wheat_pos = try astar_ctx.floodfillCommonBlock(pi.toF(), wheat_id);
                            }

                            break;
                        }
                    }
                }
            }

            if (win.keyPressed(.G)) {
                bot1.modify_mutex.lock();
                defer bot1.modify_mutex.unlock();
                try astar_ctx.reset();
                if (try astar_ctx.findTree(
                    bot1.pos.?,
                    0,
                    0,
                )) |*acc| {
                    bot1.action_list.deinit();
                    bot1.action_list = acc.*;
                }
            }

            const max_chunk_build_time = std.time.ns_per_s / 8;
            var chunk_build_timer = try std.time.Timer.start();
            var num_removed: usize = 0;

            for (world.chunk_data.rebuild_notify.items, 0..) |item, rebuild_i| {
                if (chunk_build_timer.read() > max_chunk_build_time) {
                    num_removed = rebuild_i;
                    break;
                }
                defer num_removed += 1;

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
                        for (chunk.sections, 0..) |sec, sec_i| {
                            if (!display_caves and sec_i < 7) continue;
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
            for (0..num_removed) |i| {
                _ = i;
                _ = world.chunk_data.rebuild_notify.orderedRemove(0);
            }
        }

        { //Draw the chunks
            var it = vert_map.iterator();
            while (it.next()) |kv| {
                var zit = kv.value_ptr.iterator();
                while (zit.next()) |kv2| {
                    kv2.value_ptr.cubes.draw(win.screen_dimensions, cmatrix);
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
                const p = bpos.toF32();
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
                            const p = move.pos.toF32();
                            const lp = last_pos.toF32();
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
        cubes.draw(win.screen_dimensions, cmatrix);

        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        if (draw_inventory) {
            bot1.modify_mutex.lock();
            defer bot1.modify_mutex.unlock();
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
            const area = graph.Rec(0, 0, @divTrunc(win.screen_dimensions.x, 3), @divTrunc(win.screen_dimensions.x, 3));
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
            const statsr = graph.Rec(0, area.y + area.h, 400, 300);
            gctx.rect(statsr, 0xffffffff);
            gctx.textFmt(
                statsr.pos().add(.{ .x = 0, .y = 10 }),
                "health :{d}/20\nhunger: {d}/20\nName: {s}\nSaturation: {d}\nEnt id: {d}\nent count: {d}",
                .{
                    bot1.health,
                    bot1.food,
                    bot1.name,
                    bot1.food_saturation,
                    bot1.e_id,
                    world.entities.count(),
                },
                &font,
                15,
                0xff,
            );
        }
        gctx.rect(graph.Rec(@divTrunc(win.screen_dimensions.x, 2), @divTrunc(win.screen_dimensions.y, 2), 10, 10), 0xffffffff);

        { //binding info draw
            const num_lines = KeyMap.Map.len;
            const fs = 12;
            const px_per_line = font.ptToPixel(12);
            const h = num_lines * px_per_line;
            const area = graph.Rec(0, @as(f32, @floatFromInt(win.screen_dimensions.y)) - h, 500, h);
            var y = area.y;
            for (KeyMap.Map) |binding| {
                gctx.textFmt(.{ .x = area.x, .y = y }, "{s}: {s}", .{ binding[0], binding[1] }, &font, fs, 0xffffffff);
                y += px_per_line;
            }
        }
        try gctx.end();
        //try ctx.beginDraw(graph.itc(0x2f2f2fff));
        //ctx.drawText(40, 40, "hello", &font, 16, graph.itc(0xffffffff));
        //ctx.endDraw(win.screen_width, win.screen_height);
        win.swap();
    }
}

fn drawInventory(
    gctx: *graph.NewCtx,
    item_atlas: *const mcBlockAtlas.McAtlas,
    reg: *const Reg.DataReg,
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

    var dr = try Reg.DataReg.init(alloc, "1.19.3");
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
        if (eql(u8, action_arg, "rec")) {
            return;
        }
        if (eql(u8, action_arg, "draw")) {
            draw = true;
        }
        if (eql(u8, action_arg, "init")) {
            return;
        }
    }

    var config_vm = Lua.init();
    config_vm.loadAndRunFile("bot_config.lua");
    const bot_names = config_vm.getGlobal(config_vm.state, "bots", []struct {
        name: []const u8,
        script_name: []const u8,
    });
    Lua.printStack(config_vm.state);

    const port = config_vm.getGlobal(config_vm.state, "port", u16);
    const ip = config_vm.getGlobal(config_vm.state, "ip", []const u8);

    const epoll_fd = try std.os.epoll_create1(0);
    defer std.os.close(epoll_fd);

    var world = McWorld.init(alloc, &dr);
    defer world.deinit();

    var event_structs = std.ArrayList(std.os.linux.epoll_event).init(alloc);
    defer event_structs.deinit();
    try event_structs.resize(bot_names.len);
    //var event_structs: [bot_names.len]std.os.linux.epoll_event = undefined;
    var stdin_event: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = std.io.getStdIn().handle } };
    try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, std.io.getStdIn().handle, &stdin_event);

    var bot_fd: i32 = 0;
    for (bot_names, 0..) |bn, i| {
        const mb = try botJoin(alloc, bn.name, bn.script_name, ip, port);
        event_structs.items[i] = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = mb.fd } };
        try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, mb.fd, &event_structs.items[i]);
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
                } else if (eql(u8, "reload", key)) {
                    const bname = itt.next() orelse continue;
                    var b_it = world.bots.valueIterator();
                    while (b_it.next()) |b| {
                        if (eql(u8, b.name, bname)) {
                            std.debug.print("Reloading bot: {s}\n", .{b.name});
                            world.bot_reload_mutex.lock();
                            defer world.bot_reload_mutex.unlock();
                            world.reload_bot_id = b.fd;
                            break;
                        }
                    }
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
