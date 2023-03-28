const std = @import("std");

const mc = @import("listener.zig");
const id_list = @import("list.zig");

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

const c = @import("c.zig").c;

const fbsT = std.io.FixedBufferStream([]const u8);

pub fn RingBuf(comptime n: usize, comptime T: type) type {
    return struct {
        buf: [n]T,
        index: usize = 0,

        pub fn insert(self: *@This(), item: T) void {
            self.index = @mod(self.index + 1, self.buf.len);
            self.buf[self.index] = item;
        }

        pub fn init(val: T) @This() {
            return .{
                .buf = .{val} ** n,
            };
        }
    };
}

pub const PacketCache = struct {};

pub fn botJoin(alloc: std.mem.Allocator, bot_name: []const u8) !Bot {
    var bot1 = Bot.init(alloc, bot_name);
    const s = try std.net.tcpConnectToHost(alloc, "localhost", 25565);
    bot1.fd = s.handle;
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = s.writer(), .mutex = &bot1.write_mutex };
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
    return bot1;
}

pub const McWorld = struct {
    const Self = @This();

    pub const Action_List = struct {
        pub const ListItem = struct {
            list: std.ArrayList(astar.AStarContext.PlayerActionItem),
            bot_id: i32,

            pub fn deinit(self: *@This()) void {
                self.list.deinit();
            }
        };
        items: std.ArrayList(ListItem),
        mutex: std.Thread.Mutex = .{},

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .items = std.ArrayList(ListItem).init(alloc),
            };
        }

        pub fn addList(self: *@This(), item: ListItem) !void {
            self.mutex.lock();
            try self.items.append(item);
            defer self.mutex.unlock();
        }

        pub fn deinit(self: *@This()) void {
            for (self.items.items) |*ite| {
                ite.deinit();
            }
            self.items.deinit();
        }
    };

    chunk_data: mc.ChunkMap,

    //TODO make entities and bots thread safe
    entities: std.AutoHashMap(i32, Entity),
    bots: std.AutoHashMap(i32, Bot),
    tag_table: mc.TagRegistry,

    packet_cache: struct {
        chat_time_stamps: RingBuf(32, u64) = RingBuf(32, u64).init(0),
    },

    action_lists: Action_List,

    has_tag_table: bool = false,

    master_id: ?i32,

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .packet_cache = .{},
            .chunk_data = mc.ChunkMap.init(alloc),
            .entities = std.AutoHashMap(i32, Entity).init(alloc),
            .bots = std.AutoHashMap(i32, Bot).init(alloc),
            .master_id = null,
            .tag_table = mc.TagRegistry.init(alloc),
            .action_lists = Action_List.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunk_data.deinit();
        self.entities.deinit();
        self.bots.deinit();
        self.tag_table.deinit();
        self.action_lists.deinit();
    }
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

pub fn parseSwitch(alloc: std.mem.Allocator, bot1: *Bot, packet_buf: []const u8, world: *McWorld, reg: *const Reg.DataReg) !void {
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

    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = server_stream.writer(), .mutex = &bot1.write_mutex };
    defer pctx.packet.deinit();

    if (bot1.connection_state != .play)
        return error.invalidConnectionState;
    switch (@intToEnum(id_list.packet_enum, pid)) {
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
        .Update_Entity_Position => {
            const data = parser.parse(PT(&.{ P(.varInt, "ent_id"), P(.shortV3i, "del"), P(.boolean, "grounded") }));
            if (world.entities.getPtr(data.ent_id)) |e| {
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
                const bid = @intCast(u16, bd >> 12);
                const lx = @intCast(i32, (bd >> 8) & 15);
                const lz = @intCast(i32, (bd >> 4) & 15);
                const ly = @intCast(i32, bd & 15);
                try world.chunk_data.setBlockChunk(chunk_pos, V3i.new(lx, ly, lz), bid);
            }
        },
        .Block_Update => {
            const pos = parse.position();
            const new_id = parse.varInt();
            try world.chunk_data.setBlock(pos, @intCast(mc.BLOCK_ID_INT, new_id));
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
            try chunk_data.resize(@intCast(usize, data_size));
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

                        const num_longs = @intCast(u32, mc.readVarInt(cr));
                        try cr.skipBytes(num_longs * @sizeOf(u64), .{});
                    }
                }
            }

            try world.chunk_data.insertChunkColumn(cx, cy, chunk);

            const num_block_ent = parse.varInt();
            var ent_i: u32 = 0;
            while (ent_i < num_block_ent) : (ent_i += 1) {
                const be = parse.blockEntity();
                _ = be;
            }
        },
        //Keep track of what bots have what chunks loaded and only unload chunks if none have it loaded
        .Unload_Chunk => {
            const data = parser.parse(PT(&.{ P(.int, "cx"), P(.int, "cz") }));
            world.chunk_data.removeChunkColumn(data.cx, data.cz);
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
            bot1.view_dist = @intCast(u8, data.sim_dist);
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
            const slot_i = @intCast(u16, parse.int(i16));
            const data = parse.slot();
            if (win_id == 0) {
                bot1.container_state = state_id;
                bot1.inventory[slot_i] = data;
                std.debug.print("updating slot {any}\n", .{data});
            }
        },
        .Set_Container_Content => {
            const win_id = parse.int(u8);
            const state_id = parse.varInt();
            const item_count = parse.varInt();
            var i: u32 = 0;
            if (win_id == 0) {
                while (i < item_count) : (i += 1) {
                    bot1.container_state = state_id;
                    const s = parse.slot();
                    bot1.inventory[i] = s;
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
        .Acknowledge_Block_Change => {

            //TODO use this to advance to next break_block item
        },
        .Set_Health => {
            bot1.health = parse.float(f32);
            bot1.food = @intCast(u8, parse.varInt());
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
                            try ids.resize(@intCast(usize, num_ids));
                            var ni: u32 = 0;
                            while (ni < num_ids) : (ni += 1)
                                ids.items[ni] = @intCast(u32, parse.varInt());
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
                std.debug.print("NOT SUPPORTED \n", .{});
                unreachable;
            }

            const msg = try parse.string(null);

            const timestamp = parse.int(u64);
            if (std.mem.indexOfScalar(u64, &world.packet_cache.chat_time_stamps.buf, timestamp) != null) {
                return;
            }
            world.packet_cache.chat_time_stamps.insert(timestamp);

            const eql = std.mem.eql;

            var it = std.mem.tokenize(u8, msg, " ");
            const key = it.next().?;

            var ret_msg_buf = std.ArrayList(u8).init(alloc);
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
                var bp = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = (std.net.Stream{ .handle = cbot.fd }).writer(), .mutex = &cbot.write_mutex };
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
                } else if (eql(u8, com, "say")) {
                    var ite = it.next();
                    while (ite != null) : (ite = it.next()) {
                        try m_wr.print("{s} ", .{ite.?});
                    }

                    try bp.sendChat(ret_msg_buf.items);
                } else if (eql(u8, com, "path")) {
                    _ = try std.Thread.spawn(.{}, basicPathfindThread, .{ alloc, world, reg, cbot.pos.?, player_info.?.pos, cbot.fd });
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
                for (bot1.inventory) |optslot| {
                    if (optslot) |slot| {
                        const itemd = reg.getItem(slot.item_id);
                        try m_wr.print("{s}: {d}, ", .{ itemd.name, slot.count });
                    }
                }
                try pctx.sendChat(ret_msg_buf.items);
            } else if (eql(u8, key, "axe")) {
                for (bot1.inventory) |optslot, si| {
                    if (optslot) |slot| {
                        //TODO in mc 19.4 tags have been added for axes etc, for now just do a string search
                        const name = reg.getItem(slot.item_id).name;
                        const inde = std.mem.indexOf(u8, name, "axe");
                        if (inde) |in| {
                            std.debug.print("found axe at {d} {any}\n", .{ si, bot1.inventory[si] });
                            _ = in;
                            //try pctx.pickItem(si - 10);
                            try pctx.clickContainer(0, bot1.container_state, @intCast(i16, si), 0, 2, &.{});
                            try pctx.setHeldItem(0);
                            break;
                        }
                        //std.debug.print("item: {s}\n", .{item_table.getName(slot.item_id)});
                    }
                }
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
                const bid = world.chunk_data.getBlock(qb);
                try m_wr.print("Block {s} id: {d}", .{
                    reg.getBlockFromState(bid).name,
                    bid,
                });
                try pctx.sendChat(ret_msg_buf.items);
                std.debug.print("{}", .{reg.getBlockFromState(bid)});
                //try pctx.sendChat(m_fbs.getWritten());
            }
        },
        else => {
            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, pid)]});
        },
    }
}

pub fn updateBots(alloc: std.mem.Allocator, world: *McWorld, reg: *const Reg.DataReg, exit_mutex: *std.Thread.Mutex) !void {
    _ = reg;
    while (true) {
        if (exit_mutex.tryLock()) {
            return;
        }
        //const uuid = 0;
        //var ent_it = world.entities.iterator();
        //var ent = ent_it.next();
        //const player_info: ?Entity = blk: {
        //    while (ent != null) : (ent = ent_it.next()) {
        //        if (ent.?.value_ptr.uuid == uuid) {
        //            break :blk ent.?.value_ptr.*;
        //        }
        //    }
        //    break :blk null;
        //};

        var bot_it = world.bots.iterator();
        var bot_i = bot_it.next();
        while (bot_i != null) : (bot_i = bot_it.next()) {
            const bo = bot_i.?.value_ptr;
            if (!bo.handshake_complete)
                continue;
            var bp = mc.PacketCtx{ .packet = try mc.Packet.init(alloc), .server = (std.net.Stream{ .handle = bo.fd }).writer(), .mutex = &bo.write_mutex };
            const pw = mc.lookAtBlock(bo.pos.?, V3f.new(-0.3, 1, -0.3));
            try bp.setPlayerPositionRot(bo.pos.?, pw.yaw, pw.pitch, true);
        }

        std.time.sleep(@floatToInt(u64, std.time.ns_per_s * (1.0 / 20.0)));
    }
}

pub fn basicPathfindThread(alloc: std.mem.Allocator, world: *McWorld, reg: *const Reg.DataReg, start: V3f, goal: V3f, bot_handle: i32) !void {
    var pathctx = astar.AStarContext.init(alloc, &world.chunk_data, &world.tag_table, reg);
    defer pathctx.deinit();

    const found = try pathctx.pathfind(start, goal);
    if (found) |*actions| {
        const player_actions = actions;
        for (player_actions.items) |pitem| {
            std.debug.print("action: {any}\n", .{pitem});
        }
        try world.action_lists.addList(.{ .list = player_actions.*, .bot_id = bot_handle });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    const bot_names = [_]struct { name: []const u8, sex: enum { male, female } }{
        .{ .name = "John", .sex = .male },
        .{ .name = "James", .sex = .male },
        .{ .name = "Charles", .sex = .male },
        .{ .name = "George", .sex = .male },
        //.{ .name = "Henry", .sex = .male },
        //.{ .name = "Robert", .sex = .male },
        //.{ .name = "Harry", .sex = .male },
        //.{ .name = "Walter", .sex = .male },
        //.{ .name = "Fred", .sex = .male },
        //.{ .name = "Albert", .sex = .male },

        .{ .name = "Mary", .sex = .female },
        .{ .name = "Anna", .sex = .female },
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

    var world = McWorld.init(alloc);
    defer world.deinit();

    const reg = try Reg.DataReg.init(alloc, "mcproto/converted/all.json");
    defer reg.deinit(alloc);

    var event_structs: [bot_names.len]std.os.linux.epoll_event = undefined;
    var stdin_event: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = std.io.getStdIn().handle } };
    try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, std.io.getStdIn().handle, &stdin_event);

    for (bot_names) |bn, i| {
        const mb = try botJoin(alloc, bn.name);
        event_structs[i] = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = mb.fd } };
        try std.os.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, mb.fd, &event_structs[i]);
        try world.bots.put(mb.fd, mb);
    }

    var update_bots_exit_mutex: std.Thread.Mutex = .{};
    update_bots_exit_mutex.lock();
    const update_hand = try std.Thread.spawn(.{}, updateBots, .{ alloc, &world, &reg, &update_bots_exit_mutex });
    defer update_hand.join();

    var events: [256]std.os.linux.epoll_event = undefined;

    var run = true;
    var tb = PacketParse{ .buf = std.ArrayList(u8).init(alloc) };
    defer tb.buf.deinit();

    var bps_timer = try std.time.Timer.start();
    var bytes_read: usize = 0;
    while (run) {
        if (bps_timer.read() > std.time.ns_per_s) {
            bps_timer.reset();
            //std.debug.print("KBps: {d}\n", .{@divTrunc(bytes_read, 1000)});
            bytes_read = 0;
        }
        const e_count = std.os.epoll_wait(epoll_fd, &events, 1000);
        for (events[0..e_count]) |eve| {
            if (eve.data.fd == std.io.getStdIn().handle) {
                var msg: [256]u8 = undefined;
                const n = try std.os.read(eve.data.fd, &msg);
                var itt = std.mem.tokenize(u8, msg[0 .. n - 1], " ");
                const key = itt.next() orelse continue;
                std.debug.print("\"{s}\"\n", .{key});
                const eql = std.mem.eql;
                if (eql(u8, "exit", key)) {
                    update_bots_exit_mutex.unlock();
                    run = false;
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
                            pp.data_len = @intCast(u32, mc.readVarInt(fbs.reader()));
                            pp.len_len = @intCast(u32, ppos);

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

                            pp.num_read += @intCast(u32, nr);
                            if (nr == 0) //TODO properly support partial reads
                                unreachable;

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.bots.getPtr(eve.data.fd) orelse unreachable, pp.buf.items, &world, &reg);
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
                            pp.num_read += @intCast(u32, nr);

                            if (nr == 0) //TODO properly support partial reads
                                unreachable;

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.bots.getPtr(eve.data.fd) orelse unreachable, pbuf[0 .. pp.data_len.? + pp.len_len.?], &world, &reg);
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

    //var draw = false;

    //if (draw) {
    //    c.InitWindow(1800, 1000, "Window");
    //}
    ////defer c.CloseWindow();

    ////BEGIN RAYLIB
    //var camera: c.Camera3D = undefined;
    //camera.position = .{ .x = 15.0, .y = 10.0, .z = 15.0 }; // Camera position
    //camera.target = .{ .x = 0.0, .y = 0.0, .z = 0.0 }; // Camera looking at point
    //camera.up = .{ .x = 0.0, .y = 1.0, .z = 0.0 }; // Camera up vector (rotation towards target)
    //camera.fovy = 90.0; // Camera field-of-view Y
    //camera.projection = c.CAMERA_PERSPECTIVE;
    ////c.DisableCursor();
    //c.SetCameraMode(camera, c.CAMERA_FREE);

    //var run = true;
    //while (run) {
    //    //if (draw) {
    //    //    //c.BeginDrawing();
    //    //    c.ClearBackground(c.RAYWHITE);
    //    //    c.BeginMode3D(camera);

    //    //    c.UpdateCamera(&camera);

    //    //    if (bot1.pos != null) {
    //    //        const playerpos = bot1.pos.?;
    //    //        camera.target = playerpos.toRay();
    //    //        {
    //    //            const pi = playerpos.toI();
    //    //            const section = world.getChunkSectionPtr(playerpos.toI());
    //    //            const cc = mc.ChunkMap.getChunkCoord(playerpos.toI());

    //    //            if (section) |sec| {
    //    //                var it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
    //    //                var block = it.next();
    //    //                while (block != null) : (block = it.next()) {
    //    //                    if (sec.mapping.items[block.?] == 0)
    //    //                        continue;
    //    //                    const co = it.getCoord();
    //    //                    c.DrawCube(.{
    //    //                        .x = @intToFloat(f32, co.x + cc.x * 16),
    //    //                        .y = @intToFloat(f32, co.y + (cc.y - 4) * 16),
    //    //                        .z = @intToFloat(f32, co.z + cc.z * 16),
    //    //                    }, 1.0, 1.0, 1.0, c.GRAY);
    //    //                }
    //    //            }

    //    //            for (ADJ) |adj| {
    //    //                const offset = pi.add(V3i.new(adj.x * 16, 0, adj.y * 16));
    //    //                const section1 = world.getChunkSectionPtr(offset);
    //    //                const cc1 = mc.ChunkMap.getChunkCoord(offset);
    //    //                if (section1) |sec| {
    //    //                    var it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
    //    //                    var block = it.next();
    //    //                    while (block != null) : (block = it.next()) {
    //    //                        if (sec.mapping.items[block.?] == 0)
    //    //                            continue;
    //    //                        const co = it.getCoord();
    //    //                        c.DrawCube(.{
    //    //                            .x = @intToFloat(f32, co.x + cc1.x * 16),
    //    //                            .y = @intToFloat(f32, co.y + (cc1.y - 4) * 16),
    //    //                            .z = @intToFloat(f32, co.z + cc1.z * 16),
    //    //                        }, 1.0, 1.0, 1.0, c.GRAY);
    //    //                    }
    //    //                }
    //    //            }

    //    //            for (player_actions.items) |act| {
    //    //                switch (act) {
    //    //                    .movement => |mv| {
    //    //                        const color = switch (mv.kind) {
    //    //                            .ladder => c.BLACK,
    //    //                            .walk => c.BLUE,
    //    //                            .jump => c.RED,
    //    //                            .fall => c.GREEN,
    //    //                            else => unreachable,
    //    //                        };
    //    //                        c.DrawCube(mv.pos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 0.3, 0.3, 0.3, color);
    //    //                    },
    //    //                    else => {},
    //    //                }
    //    //            }

    //    //            //for (pathctx.closed.items) |op| {
    //    //            //    const w = 0.3;
    //    //            //    c.DrawCube(
    //    //            //        V3f.newi(op.x, op.y, op.z).toRay(),
    //    //            //        w,
    //    //            //        w,
    //    //            //        w,
    //    //            //        c.BLUE,
    //    //            //    );
    //    //            //}
    //    //        }
    //    //        c.DrawCube(playerpos.subtract(V3f.new(0.5, 0, 0.5)).toRay(), 1.0, 1.0, 1.0, c.RED);
    //    //    }

    //    //    c.DrawGrid(10, 1.0);

    //    //    c.EndMode3D();

    //    //    c.EndDrawing();
    //    //}

    //    //if (bot1.handshake_complete) {
    //    //    const dt: f64 = 1.0 / 20.0;
    //    //    if (current_action) |action| {
    //    //        switch (action) {
    //    //            .movement => |move_| {
    //    //                var move = move_;
    //    //                var adt = dt;
    //    //                var grounded = true;
    //    //                var moved = false;
    //    //                var pw = mc.lookAtBlock(bot1.pos.?, V3f.new(0, 0, 0));
    //    //                while (true) {
    //    //                    var move_vec = blk: {
    //    //                        switch (move.kind) {
    //    //                            .walk => {
    //    //                                break :blk move_state.walk(speed, adt);
    //    //                            },
    //    //                            .jump => break :blk move_state.jump(speed, adt),
    //    //                            .fall => break :blk move_state.fall(speed, adt),
    //    //                            .ladder => break :blk move_state.ladder(2.35, adt),
    //    //                            .blocked => unreachable,

    //    //                            //else => {
    //    //                            //    unreachable;
    //    //                            //},
    //    //                        }
    //    //                    };
    //    //                    grounded = move_vec.grounded;

    //    //                    bot1.pos = move_vec.new_pos;
    //    //                    moved = true;

    //    //                    if (!move_vec.move_complete) {
    //    //                        break;
    //    //                    } else {
    //    //                        if (player_actions.items.len > 0) {
    //    //                            switch (player_actions.items[player_actions.items.len - 1]) {
    //    //                                .movement => {
    //    //                                    adt = move_vec.remaining_dt;
    //    //                                    current_action = player_actions.pop();
    //    //                                    move = current_action.?.movement;
    //    //                                    move_state.init_pos = move_vec.new_pos;
    //    //                                    move_state.final_pos = move.pos;
    //    //                                    move_state.time = 0;
    //    //                                },
    //    //                                else => {
    //    //                                    current_action = player_actions.pop();
    //    //                                    if (current_action) |acc| {
    //    //                                        switch (acc) {
    //    //                                            .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
    //    //                                            .block_break => block_break_timer = null,
    //    //                                        }
    //    //                                    }
    //    //                                    break;
    //    //                                },
    //    //                            }
    //    //                        } else {
    //    //                            current_action = null;
    //    //                            break;
    //    //                        }
    //    //                    }
    //    //                    //move_vec = //above switch statement
    //    //                }
    //    //                if (moved) {
    //    //                    try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, grounded);
    //    //                }
    //    //            },
    //    //            .block_break => |bb| {
    //    //                if (block_break_timer == null) {
    //    //                    const pw = mc.lookAtBlock(bot1.pos.?, bb.pos.toF());
    //    //                    try pctx.setPlayerRot(pw.yaw, pw.pitch, true);
    //    //                    try pctx.playerAction(.start_digging, bb.pos);
    //    //                    block_break_timer = dt;
    //    //                } else {
    //    //                    block_break_timer.? += dt;
    //    //                    if (block_break_timer.? >= 0.5) {
    //    //                        block_break_timer = null;
    //    //                        try pctx.playerAction(.finish_digging, bb.pos);
    //    //                        current_action = player_actions.popOrNull();
    //    //                        if (current_action) |acc| {
    //    //                            switch (acc) {
    //    //                                .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
    //    //                                .block_break => block_break_timer = null,
    //    //                            }
    //    //                        }
    //    //                    }
    //    //                }
    //    //            },
    //    //        }
    //    //    } else {
    //    //        if (doit) {
    //    //            if (try pathctx.findTree(bot1.pos.?)) |*actions| {
    //    //                player_actions.deinit();
    //    //                player_actions = actions.*;
    //    //                for (player_actions.items) |pitem| {
    //    //                    std.debug.print("action: {any}\n", .{pitem});
    //    //                }
    //    //                current_action = player_actions.popOrNull();
    //    //                if (current_action) |acc| {
    //    //                    switch (acc) {
    //    //                        .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
    //    //                        .block_break => block_break_timer = null,
    //    //                    }
    //    //                }
    //    //            }
    //    //        }
    //    //        if (niklas_id) |nid| {
    //    //            niklas_cooldown += dt;
    //    //            if (niklas_cooldown > max_niklas_cooldown) {
    //    //                if (entities.get(nid)) |ne| {
    //    //                    const pw = mc.lookAtBlock(bot1.pos.?, ne.pos.add(V3f.new(-0.3, 1, -0.3)));
    //    //                    try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
    //    //                }
    //    //                niklas_cooldown = 0;
    //    //            }
    //    //        }
    //    //    }
    //    //}
    //    std.time.sleep(@floatToInt(u64, std.time.ns_per_s * (1.0 / 20.0)));
    //}
}
