const std = @import("std");
const Proto = @import("protocol.zig");
const nbt_zig = @import("nbt.zig");
const dreg = @import("data_reg.zig");

const vector = @import("vector.zig");
const V3f = vector.V3f;
const V3i = vector.V3i;

const Queue = std.atomic.Queue;

const com = @import("common.zig");

//TODO Edit api to use vector structs for everything

const Serv = std.net.Stream.Writer;
pub const PacketCtx = struct {
    const Play = Proto.Play_Serverbound;
    const MAX_CHAT_LEN = 256;

    pub const PlayerActionStatus = enum(i32) {
        start_digging,
        cancel_digging,
        finish_digging,
        drop_item_stack,
        drop_item,
        shoot_arrowEat,
        swap_item_in_hand,
    };

    packet: Packet,
    server: Serv,
    mutex: *std.Thread.Mutex,

    pub fn deinit(self: *@This()) void {
        self.packet.deinit();
    }

    pub fn wr(self: *@This()) !void {
        try self.packet.writeToServer(self.server, self.mutex);
    }

    pub fn useItem(self: *@This(), hand: enum { main, off_hand }, sequence: i32) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.use_item);
        try self.packet.varInt(@intFromEnum(hand));
        try self.packet.varInt(sequence);
        try self.wr();
    }

    pub fn useItemOn(
        self: *@This(),
        hand: enum { main, off_hand },
        block_pos: V3i,
        face: enum { bottom, top, north, south, west, east },
        cx: f32,
        cy: f32,
        cz: f32,
        head_in_block: bool,
        sequence: i32,
    ) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.block_place);
        try self.packet.varInt(@intFromEnum(hand));
        try self.packet.iposition(block_pos);
        try self.packet.varInt(@intFromEnum(face));
        try self.packet.float(cx);
        try self.packet.float(cy);
        try self.packet.float(cz);
        try self.packet.boolean(head_in_block);
        try self.packet.varInt(sequence);
        try self.wr();
    }

    pub fn pickItem(self: *@This(), sloti: usize) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.pick_item);
        try self.packet.varInt(@as(i32, @intCast(sloti)));

        //try self.packet.writeToServer(self.server);
        try self.wr();
    }

    pub fn setHeldItem(self: *@This(), index: u8) !void {
        try self.packet.clear();

        try self.packet.packetId(Play.held_item_slot);
        try self.packet.short(@as(u16, @intCast(index)));
        try self.wr();
    }

    pub fn closeContainer(self: *@This(), win_id: u8) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.close_window);
        try self.packet.ubyte(win_id);
        try self.wr();
    }

    pub fn clickContainer(
        self: *@This(),
        win: u8,
        state_id: i32,
        slot: u32,
        button: u8,
        mode: u8,
        new_slot_data: []const struct { sloti: u32, slot: ?Slot },
        held_slot: ?Slot,
    ) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.window_click);
        try self.packet.ubyte(win);
        try self.packet.varInt(state_id);
        try self.packet.short(@as(u16, @intCast(slot)));
        try self.packet.ubyte(button);
        try self.packet.varInt(mode);
        try self.packet.varInt(@as(i32, @intCast(new_slot_data.len)));
        for (new_slot_data) |item| {
            try self.packet.short(@as(u16, @intCast(item.sloti)));
            try self.packet.slot(item.slot);
        }
        try self.packet.slot(held_slot);

        try self.wr();
    }

    pub fn sendChat(self: *@This(), msg: []const u8) !void {
        const len = if (msg.len > MAX_CHAT_LEN) MAX_CHAT_LEN else msg.len;
        try self.packet.clear();
        try self.packet.packetId(Play.chat_message);
        try self.packet.string(msg[0..len]);
        try self.packet.long(0);
        try self.packet.long(0);
        try self.packet.boolean(false);
        try self.packet.int32(0);
        try self.wr();

        if (len < msg.len)
            try self.sendChat(msg[len..msg.len]);
    }

    ///If the message exceeds MAX_CHAT_LEN, silently returns without sending message
    pub fn sendChatFmt(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        var buf: [MAX_CHAT_LEN]u8 = undefined;
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        try self.sendChat(fbs.getWritten());
    }

    pub fn playerAction(self: *@This(), status: PlayerActionStatus, block_pos: vector.V3i) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.block_dig); //Packet id
        try self.packet.varInt(@intFromEnum(status));
        try self.packet.iposition(block_pos);
        try self.packet.ubyte(0); //Face of block
        try self.packet.varInt(0);
        try self.wr();
    }

    pub fn handshake(self: *@This(), hostname: []const u8, port: u16, protocol_version: u32) !void {
        try self.packet.clear();
        try self.packet.packetId(Proto.Handshake_Serverbound.set_protocol); //Packet id
        try self.packet.varInt(@intCast(protocol_version)); //Protocol version
        try self.packet.string(hostname);
        try self.packet.short(port);
        try self.packet.varInt(2); //Next state
        try self.wr();
    }

    pub fn clientCommand(self: *@This(), action: u8) !void {
        //action == 0, player respawn, action == 1, player opened stats window
        try self.packet.clear();
        try self.packet.packetId(Play.client_command);
        try self.packet.varInt(action);
        try self.wr();
    }

    pub fn completeLogin(self: *@This()) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.client_command);
        try self.packet.varInt(0x0);
        try self.wr();
    }

    pub fn loginStart(self: *@This(), username: []const u8) !void {
        try self.packet.clear();
        try self.packet.packetId(Proto.Login_Serverbound.login_start); //Packet id
        try self.packet.string(username);
        try self.packet.boolean(false); //No uuid
        try self.wr();
    }

    pub fn keepAlive(self: *@This(), id: i64) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.keep_alive);
        try self.packet.long(id);
        try self.wr();
    }

    pub fn setPlayerRot(self: *@This(), yaw: f32, pitch: f32, grounded: bool) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.look);
        try self.packet.float(yaw);
        try self.packet.float(pitch);
        try self.packet.boolean(grounded);
        try self.wr();
    }

    pub fn setPlayerPositionRot(self: *@This(), pos: V3f, yaw: f32, pitch: f32, grounded: bool) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.position_look);
        try self.packet.double(pos.x);
        try self.packet.double(pos.y);
        try self.packet.double(pos.z);
        try self.packet.float(yaw);
        try self.packet.float(pitch);
        try self.packet.boolean(grounded);
        //std.debug.print("MOVE PACKET {d} {d} {d} {any}\n", .{ pos.x, pos.y, pos.z, grounded });
        try self.wr();
    }

    pub fn confirmTeleport(self: *@This(), id: i32) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.teleport_confirm);
        try self.packet.varInt(id);
        try self.wr();
    }

    pub fn pluginMessage(self: *@This(), brand: []const u8) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.custom_payload);
        try self.packet.string(brand);
        try self.wr();
    }

    pub fn clientInfo(self: *@This(), locale: []const u8, render_dist: u8, main_hand: u8) !void {
        try self.packet.clear();
        try self.packet.packetId(Play.settings); //client info packet
        try self.packet.string(locale);
        try self.packet.ubyte(render_dist);
        try self.packet.varInt(0); //Chat mode, enabled
        try self.packet.boolean(true); //Chat colors enabled
        try self.packet.ubyte(0); // what parts are shown of skin
        try self.packet.varInt(main_hand);
        try self.packet.boolean(false); //No text filtering
        try self.packet.boolean(true); //Allow this bot to be listed
        try self.wr();
    }
};

pub fn numBitsRequired(count: usize) usize {
    return std.math.log2_int_ceil(usize, count);
}

test "num bits req" {
    std.debug.print("req {d}\n", .{numBitsRequired(4)});
    std.debug.print("req {d}\n", .{numBitsRequired(5)});
    std.debug.print("16 req {d}\n", .{numBitsRequired(16)});
    std.debug.print("17 req {d}\n", .{numBitsRequired(17)});
}

pub fn getBitMask(num_bits: usize) u64 {
    return (~@as(u64, 0x0)) >> @as(u6, @intCast(64 - num_bits));

    //From wiki.vg/chunk_format:
    //For block states with bits per entry <= 4, 4 bits are used to represent a block.
    //For block states and bits per entry between 5 and 8, the given value is used.
    //For biomes the given value is always used, and will be <= 3
}

pub const Packet = struct {
    const Self = @This();

    buffer: std.ArrayList(u8),
    comp_thresh: i32 = -1,

    pub fn init(alloc: std.mem.Allocator, comp_thresh: i32) !Self {
        var ret = Self{
            .comp_thresh = comp_thresh,
            .buffer = std.ArrayList(u8).init(alloc),
        };

        return ret;
    }

    pub fn clear(self: *Self) !void {
        try self.buffer.resize(0);
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn boolean(self: *Self, val: bool) !void {
        try self.buffer.writer().writeByte(if (val) 0x01 else 0x00);
    }

    pub fn slot(self: *Self, val: ?Slot) !void {
        const wr = self.buffer.writer();
        try self.boolean(val != null);
        if (val) |sl| {
            try self.varInt(sl.item_id);
            try self.ubyte(sl.count);
            if (sl.nbt_buffer) |buf| {
                _ = try wr.write(buf);
            } else {
                try self.ubyte(0);
            }
        }
    }

    pub fn packetId(self: *Self, val: anytype) !void {
        try self.varInt(@intFromEnum(val));
    }

    pub fn varInt(self: *Self, int: i32) !void {
        var val = toVarInt(int);
        const wr = self.buffer.writer();
        _ = try wr.write(val.getSlice());
    }

    pub fn iposition(self: *Self, v: vector.V3i) !void {
        try self.long((@as(i64, v.x & 0x3FFFFFF) << 38) | ((v.z & 0x3FFFFFF) << 12) | (v.y & 0xFFF));
    }

    pub fn slice(self: *Self, sl: []const u8) !void {
        try self.buffer.appendSlice(sl);
    }

    pub fn string(self: *Self, str: []const u8) !void {
        try self.varInt(@as(i32, @intCast(str.len)));
        const wr = self.buffer.writer();
        _ = try wr.write(str);
    }

    pub fn float(self: *Self, f: f32) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u32, @as(u32, @bitCast(f)), .Big);
    }

    pub fn ubyte(self: *Self, b: u8) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u8, b, .Big);
    }

    pub fn long(self: *Self, l: i64) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(i64, l, .Big);
    }

    pub fn int32(self: *Self, i: u32) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u32, i, .Big);
    }

    pub fn double(self: *Self, f: f64) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u64, @as(u64, @bitCast(f)), .Big);
    }

    pub fn short(self: *Self, val: u16) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u16, val, .Big);
    }

    pub fn writeToServer(self: *Self, server: std.net.Stream.Writer, mutex: *std.Thread.Mutex) !void {
        //TODO if blocking becomes an issue for keep alives and the like, do a try lock and create a queue of packets to send
        mutex.lock();
        defer mutex.unlock();
        const comp_enable = (self.comp_thresh > -1);
        //_ = try server.writeByte(0);
        var len = toVarInt(@as(i32, @intCast(self.buffer.items.len)) + @as(i32, if (comp_enable) 1 else 0));
        _ = try server.write(len.getSlice());
        if (comp_enable)
            _ = try server.writeByte(0);

        _ = try server.write(self.buffer.items[0..]);
    }

    //pub fn getWritableBuffer(self: *Self) []const u8 {
    //    var len = toVarInt(@intCast(i32, self.buffer.items.len - RESERVED_BYTE_COUNT));
    //    std.mem.copy(u8, self.buffer.items[RESERVED_BYTE_COUNT - len.len ..], len.getSlice());
    //    return self.buffer.items[RESERVED_BYTE_COUNT - len.len ..];
    //}
};

pub const VarInt = struct {
    bytes: [5]u8,
    len: u8,

    pub fn getSlice(self: *@This()) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const VarLong = struct {
    bytes: [10]u8,
    len: u8,

    pub fn getSlice(self: *@This()) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn toVarLong(input: i64) VarLong {
    const CONT: u64 = 0x80;
    const SEG: u64 = 0x7f;

    var ret = VarLong{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 0 };
    var value = @as(u64, @bitCast(input));

    while (true) {
        if ((value & ~SEG) == 0) {
            ret.bytes[ret.len] = @as(u8, @intCast(value & SEG));
            ret.len += 1;
            return ret;
        }

        ret.bytes[ret.len] = @as(u8, @intCast((value & SEG) | CONT));
        ret.len += 1;

        if (ret.len >= 10) {
            unreachable;
        }

        value >>= 7;
    }
}

pub fn toVarInt(input: i32) VarInt {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var ret = VarInt{ .bytes = .{ 0, 0, 0, 0, 0 }, .len = 0 };
    var value = @as(u32, @bitCast(input));

    while (true) {
        if ((value & ~SEG) == 0) {
            ret.bytes[ret.len] = @as(u8, @intCast(value & SEG));
            ret.len += 1;
            return VarInt{ .bytes = ret.bytes, .len = ret.len };
        }

        ret.bytes[ret.len] = @as(u8, @intCast((value & SEG) | CONT));
        ret.len += 1;

        if (ret.len >= 5) {
            unreachable;
        }

        value >>= 7;
    }
}

pub const Slot = struct {
    item_id: u16,
    count: u8,
    nbt_buffer: ?[]u8 = null,
};

pub const BlockEntityP = struct {
    rel_x: u4,
    rel_z: u4,
    abs_y: i16,
    type: i32,
    nbt: nbt_zig.Entry,
};

pub const AutoParse = struct {
    ///Defines names of types we can parse, the .Type indicates what this field will be in the returned struct
    const TypeItem = struct { name: []const u8, Type: type };
    pub const TypeList = [_]TypeItem{
        .{ .name = "boolean", .Type = bool },

        .{ .name = "long", .Type = i64 },
        .{ .name = "byte", .Type = i8 },
        .{ .name = "ubyte", .Type = u8 },
        .{ .name = "short", .Type = i16 },
        .{ .name = "ushort", .Type = u16 },
        .{ .name = "int", .Type = i32 },
        .{ .name = "uuid", .Type = u128 },

        .{ .name = "string", .Type = []const u8 },
        .{ .name = "chat", .Type = []const u8 },
        .{ .name = "identifier", .Type = []const u8 },

        .{ .name = "float", .Type = f32 },
        .{ .name = "double", .Type = f64 },

        .{ .name = "varInt", .Type = i32 },
        .{ .name = "varLong", .Type = i64 },

        .{ .name = "entityMetadata", .Type = u0 },
        .{ .name = "slot", .Type = u0 },
        .{ .name = "nbtTag", .Type = u0 },

        .{ .name = "position", .Type = V3i },
        .{ .name = "angle", .Type = f32 },

        .{ .name = "V3f", .Type = V3f },
        .{ .name = "shortV3i", .Type = vector.shortV3i },

        .{ .name = "stringList", .Type = [][]const u8 },
    };

    ///Generate an enum where the enum values map to the original list so types can be retrieved,
    ///needed instead of a union so that instatiation is not needed when specifing a struct by listing fields, see fn parseType
    fn genTypeListEnum(comptime list: []const TypeItem) type {
        var enum_fields: [list.len]std.builtin.Type.EnumField = undefined;
        for (list, 0..) |it, i| {
            enum_fields[i] = .{ .name = it.name, .value = i };
        }
        return @Type(std.builtin.Type{
            .Enum = .{
                .tag_type = usize,
                .fields = &enum_fields,
                .is_exhaustive = true,
                .decls = &.{},
            },
        });
    }

    pub const Types = genTypeListEnum(&TypeList);

    pub const ParseItem = struct {
        type_: Types,
        name: []const u8,
    };

    pub fn P(comptime type_: Types, comptime name: []const u8) ParseItem {
        return .{ .type_ = type_, .name = name };
    }

    const parseTypeReturnType = struct {
        t: type,
        list: []const ParseItem,
    };
    pub fn parseType(comptime parse_items: []const ParseItem) parseTypeReturnType {
        var struct_fields: [parse_items.len]std.builtin.Type.StructField = undefined;
        for (parse_items, 0..) |item, i| {
            struct_fields[i] = .{
                .name = item.name,
                .type = TypeList[@intFromEnum(item.type_)].Type,
                .is_comptime = false,
                .default_value = null,
                .alignment = 0,
            };
        }
        return .{ .t = @Type(std.builtin.Type{
            .Struct = .{
                .layout = .Auto,
                .backing_integer = null,
                .fields = &struct_fields,
                .decls = &.{},
                .is_tuple = false,
            },
        }), .list = parse_items };
    }
};

pub fn packetParseCtx(comptime readerT: type) type {
    return struct {
        const Self = @This();
        const Reader = readerT;

        //This structure makes no attempt to keep track of memory it allocates, as much of what is parsed is
        //garbage
        //use an arena allocator and copy over values that you need
        //TODO internally use an arena
        pub fn init(reader: readerT, alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .reader = reader,
            };
        }

        pub fn float(self: *Self, comptime fT: type) fT {
            if (fT == f32) {
                return @as(f32, @bitCast(self.int(u32)));
            }
            if (fT == f64) {
                return @as(f64, @bitCast(self.int(u64)));
            }
            unreachable;
        }

        pub fn chunk_position(self: *Self) vector.V3i {
            const pos = self.int(i64);
            return .{
                .x = @as(i32, @intCast(pos >> 42)),
                .y = @as(i32, @intCast(pos << 44 >> 44)),
                .z = @as(i32, @intCast(pos << 22 >> 42)),
            };
        }

        pub fn position(self: *Self) vector.V3i {
            const pos = self.int(i64);
            return .{
                .x = @as(i32, @intCast(pos >> 38)),
                .y = @as(i32, @intCast(pos << 52 >> 52)),
                .z = @as(i32, @intCast(pos << 26 >> 38)),
            };
        }

        pub fn v3f(self: *Self) V3f {
            return .{
                .x = self.float(f64),
                .y = self.float(f64),
                .z = self.float(f64),
            };
        }

        pub fn int(self: *Self, comptime intT: type) intT {
            return self.reader.readInt(intT, .Big) catch unreachable;
        }

        pub fn string(self: *Self, max_len: ?usize) ![]const u8 {
            const len = @as(u32, @intCast(readVarInt(self.reader)));
            if (max_len) |l|
                if (len > l) return error.StringExceedsMaxLen;
            const slice = try self.alloc.alloc(u8, len);
            try self.reader.readNoEof(slice);
            return slice;
        }

        pub fn boolean(self: *Self) bool {
            return (self.int(u8) == 1);
        }

        pub fn varInt(self: *Self) i32 {
            return readVarInt(self.reader);
        }

        pub fn varLong(self: *Self) i64 {
            return readVarLong(self.reader);
        }

        pub fn blockEntity(self: *Self) BlockEntityP {
            //TODO make this actually return something
            const pxz = self.int(u8);
            const y = self.int(i16);
            const btype = self.varInt();
            const tr = nbt_zig.TrackingReader(@TypeOf(self.reader));
            var tracker = tr.init(self.alloc, self.reader);
            const nbt = nbt_zig.parse(self.alloc, tracker.reader()) catch unreachable;
            return BlockEntityP{
                .rel_x = @intCast(pxz >> 4),
                .rel_z = @intCast(pxz & 0xf),
                .abs_y = y,
                .type = btype,
                .nbt = nbt.entry,
            };
        }

        pub fn slot(self: *Self) ?Slot {
            if (self.boolean()) { //Is item present
                var s = Slot{
                    .item_id = @as(u16, @intCast(self.varInt())),
                    .count = self.int(u8),
                    .nbt_buffer = null,
                };

                const tr = nbt_zig.TrackingReader(@TypeOf(self.reader));
                var tracker = tr.init(self.alloc, self.reader);

                const nbt = nbt_zig.parse(self.alloc, tracker.reader()) catch unreachable;
                if (tracker.buffer.items.len > 1) {
                    s.nbt_buffer = tracker.buffer.items;
                    _ = nbt;
                    //std.debug.print("NBT: {s}\n", .{nbt.name.?});
                    //nbt.entry.format("", .{}, std.io.getStdErr().writer()) catch unreachable;
                }

                return s;
            }
            return null;
        }

        pub fn auto(self: *Self, comptime p_type: AutoParse.parseTypeReturnType) p_type.t {
            const r = self.reader;
            var ret: p_type.t = undefined;
            const info = @typeInfo(p_type.t).Struct.fields;
            inline for (p_type.list, 0..) |item, i| {
                @field(ret, info[i].name) = blk: {
                    switch (item.type_) {
                        .long, .byte, .ubyte, .short, .ushort, .int, .uuid => {
                            break :blk self.reader.readInt(info[i].type, .Big) catch unreachable;
                        },
                        .boolean => break :blk (r.readInt(u8, .Big) catch unreachable == 0x1),
                        .string, .chat, .identifier => break :blk self.string(null) catch unreachable,
                        .float, .double => break :blk self.float(info[i].type),
                        .varInt => break :blk readVarInt(r),
                        .position => break :blk self.position,
                        .V3f => break :blk self.v3f(),
                        .angle => break :blk @as(f32, @floatFromInt(self.int(u8))) / (256.0 / 360.0),
                        .shortV3i => {
                            break :blk .{
                                .x = self.int(i16),
                                .y = self.int(i16),
                                .z = self.int(i16),
                            };
                        },

                        .stringList => {
                            const len = readVarInt(r);
                            var strs = self.alloc.alloc([]const u8, @as(u32, @intCast(len))) catch unreachable;
                            var n: u32 = 0;
                            while (n < len) : (n += 1) {
                                strs[n] = self.string(null) catch unreachable;
                            }
                            break :blk strs;
                        },
                        .nbtTag => {
                            const nbt = nbt_zig.parse(self.alloc, r) catch unreachable;
                            _ = nbt;
                            break :blk 0;
                        },
                        else => {
                            std.debug.print("{}\n", .{item.type_});
                            @compileError("Type not supported");
                        },
                    }
                };
            }
            return ret;
        }

        reader: readerT,
        alloc: std.mem.Allocator,
    };
}

pub fn readVarLong(reader: anytype) i64 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u64 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = reader.readByte() catch unreachable;
        value |= @as(u64, @intCast(current_byte & SEG)) << @as(u5, @intCast(pos));
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 64) unreachable;
    }

    return @as(i64, @bitCast(value));
}

pub fn readVarInt(reader: anytype) i32 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u32 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = reader.readByte() catch unreachable;
        value |= @as(u32, @intCast(current_byte & SEG)) << @as(u5, @intCast(pos));
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 32) unreachable;
    }

    return @as(i32, @bitCast(value));
}

pub fn readVarIntWithError(reader: anytype) !i32 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u32 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = try reader.readByte();
        value |= @as(u32, @intCast(current_byte & SEG)) << @as(u5, @intCast(pos));
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 32) unreachable;
    }

    return @as(i32, @bitCast(value));
}

test "toVarLong" {
    const expect = std.testing.expect;

    const values = [_]i64{
        0,
        1,
        2,
        127,

        128,
        255,
        2147483647,
        9223372036854775807,

        -1,
        -2147483648,
        -9223372036854775808,
    };
    const expected = [_][]const u8{
        &.{0x0},
        &.{0x1},
        &.{0x02},
        &.{0x7f},

        &.{ 0x80, 0x01 },
        &.{ 0xff, 0x1 },
        &.{ 0xff, 0xff, 0xff, 0xff, 0x07 },
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f },

        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        &.{ 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01 },
        &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 },
    };

    for (values, 0..) |v, i| {
        var vi = toVarLong(v);
        const sl = vi.getSlice();
        try expect(std.mem.eql(u8, sl, expected[i]));
    }
}

test "toVarInt" {
    const expect = std.testing.expect;

    const values = [_]i32{
        0,
        1,
        2,
        127,
        128,
        255,
        25565,
        2097151,
        2147483647,
        -1,
        -2147483648,
    };
    const expected = [_][]const u8{
        &.{0x0},
        &.{0x1},
        &.{0x02},
        &.{0x7f},
        &.{ 0x80, 0x01 },
        &.{ 0xff, 0x01 },
        &.{ 0xdd, 0xc7, 0x01 },
        &.{ 0xff, 0xff, 0x7f },
        &.{ 0xff, 0xff, 0xff, 0xff, 0x07 },
        &.{ 0xff, 0xff, 0xff, 0xff, 0x0f },
        &.{ 0x80, 0x80, 0x80, 0x80, 0x08 },
    };

    for (values, 0..) |v, i| {
        var vi = toVarInt(v);
        const sl = vi.getSlice();
        try expect(std.mem.eql(u8, sl, expected[i]));
    }
}

//TODO remove the id and len field and replace with a slice
pub const PacketData = struct {
    const Self = @This();

    buffer: std.ArrayList(u8),
    msg_type: MsgType = .server,

    pub const MsgType = enum {
        server,
        local,
    };

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{ .buffer = std.ArrayList(u8).init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }
};

pub const PacketQueueType = Queue(PacketData);

pub fn recvPacket(alloc: std.mem.Allocator, reader: std.net.Stream.Reader, comp_threshold: i32) ![]const u8 {
    const comp_enabled = (comp_threshold > -1);
    const total_len = @as(u32, @intCast(readVarInt(reader)));

    const buf = try alloc.alloc(u8, total_len);
    errdefer alloc.free(buf);
    var n: u32 = 0;
    while (n < total_len) : (n += 1) {
        buf[n] = try reader.readByte();
    }

    if (comp_enabled) {
        defer alloc.free(buf);
        var in_stream = std.io.FixedBufferStream([]const u8){ .buffer = buf, .pos = 0 };
        const comp_len = readVarInt(in_stream.reader());
        if (comp_len == 0) {
            const ret_buf = try alloc.dupe(u8, buf[in_stream.pos..]);
            return ret_buf;
        }
        var zlib_stream = try std.compress.zlib.decompressStream(alloc, in_stream.reader());
        defer zlib_stream.deinit();
        const ubuf = try zlib_stream.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        return ubuf;
    }
    return buf;
}

pub const NUM_CHUNK_SECTION = 24;
pub const Chunk = struct {
    sections: [NUM_CHUNK_SECTION]ChunkSection,
    owners: std.AutoHashMap(u128, void),

    pub fn init(alloc: std.mem.Allocator) @This() {
        var sec: [NUM_CHUNK_SECTION]ChunkSection = undefined;
        for (&sec) |*s|
            s.* = ChunkSection.init(alloc);
        return .{
            .sections = sec,
            .owners = std.AutoHashMap(u128, void).init(alloc),
        };
    }

    pub fn deinit(self: *Chunk) void {
        for (&self.sections) |*sec| {
            sec.deinit();
        }
        self.owners.deinit();
    }
};
pub const ChunkMapCoord = std.AutoHashMap(i32, Chunk);
pub const ChunkMap = struct {
    const Self = @This();

    pub const XTYPE = std.AutoHashMap(i32, ChunkMapCoord);
    pub const ZTYPE = ChunkMapCoord;

    x: XTYPE,
    alloc: std.mem.Allocator,

    //These are used for DrawThread
    rw_lock: std.Thread.RwLock = .{},
    rebuild_notify: std.ArrayList(vector.V2i),

    pub fn addNotify(self: *Self, cx: i32, cz: i32) !void {
        var found = false;
        for (self.rebuild_notify.items) |item| {
            if (item.x == cx and item.y == cz) {
                found = true;
                break;
            }
        }
        if (!found)
            try self.rebuild_notify.append(.{ .x = cx, .y = cz });
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .x = XTYPE.init(alloc),
            .alloc = alloc,
            .rebuild_notify = std.ArrayList(vector.V2i).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.x.iterator();
        while (it.next()) |kv| {
            var zit = kv.value_ptr.iterator();
            while (zit.next()) |kv2| {
                kv2.value_ptr.deinit();
            }
            kv.value_ptr.deinit();
        }

        self.rebuild_notify.deinit();
        self.x.deinit();
    }

    pub fn removeChunkColumn(self: *Self, cx: i32, cz: i32, owner: u128) !void {
        self.rw_lock.lock();
        if (self.x.getPtr(cx)) |zw| {
            if (zw.getPtr(cz)) |cc| {
                _ = cc.owners.remove(owner);
                if (cc.owners.count() == 0) {
                    try self.addNotify(cx, cz);
                    cc.deinit();
                    _ = zw.remove(cz);
                }
            }
        }
        self.rw_lock.unlock();
    }

    /// Tests if the current chunk is loaded and owned
    /// adds the "owner" to the chunk
    /// returns true if we own this chunk
    pub fn tryOwn(self: *Self, cx: i32, cz: i32, owner: u128) !bool {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();
        if (self.getChunkColumnPtr(cx, cz)) |col| {
            try col.owners.put(owner, {});
            if (col.owners.count() == 1) //We are the only owner
                return true;
            return false;
        }
        return true;
    }

    pub fn isLoaded(self: *Self, pos: V3i) bool {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();
        const ch = ChunkMap.getChunkCoord(pos);
        return self.getChunkColumnPtr(ch.x, ch.z) != null;
    }

    pub fn getChunkCoord(pos: V3i) V3i {
        const cx = @as(i32, @intCast(@divFloor(pos.x, 16)));
        const cz = @as(i32, @intCast(@divFloor(pos.z, 16)));
        const cy = @as(i32, @intCast(@divFloor(pos.y + 64, 16)));
        return .{ .x = cx, .y = cy, .z = cz };
    }

    fn getChunkColumnPtr(self: *Self, cx: i32, cz: i32) ?*Chunk {
        const world_z = self.x.getPtr(cx) orelse return null;
        return world_z.getPtr(cz);
    }

    fn getChunkSectionPtr(self: *Self, pos: V3i) ?*ChunkSection {
        const ch = ChunkMap.getChunkCoord(pos);

        const world_z = self.x.getPtr(ch.x) orelse return null;
        const column = world_z.getPtr(ch.z) orelse return null;
        return &column.sections[@as(u32, @intCast(ch.y))];
    }

    pub fn isOccluded(self: *Self, pos: V3i) bool {
        if ((self.getBlock(pos.add(V3i.new(0, 1, 0))) orelse return false) == 0)
            return false;
        if ((self.getBlock(pos.add(V3i.new(0, -1, 0))) orelse return false) == 0)
            return false;
        if ((self.getBlock(pos.add(V3i.new(1, 0, 0))) orelse return false) == 0)
            return false;
        if ((self.getBlock(pos.add(V3i.new(-1, 0, 0))) orelse return false) == 0)
            return false;
        if ((self.getBlock(pos.add(V3i.new(0, 0, 1))) orelse return false) == 0)
            return false;
        if ((self.getBlock(pos.add(V3i.new(0, 0, -1))) orelse return false) == 0)
            return false;
        return true;
    }

    pub fn getBlock(self: *Self, pos: V3i) ?BLOCK_ID_INT {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();
        const ch = ChunkMap.getChunkCoord(pos);
        if (pos.y < -64) return null;

        const rx = @mod(pos.x, 16);
        const rz = @mod(pos.z, 16);
        const ry = @mod(pos.y + 64, 16);

        const world_z = self.x.getPtr(ch.x) orelse return null;
        const column = world_z.getPtr(ch.z) orelse return null;
        const section = column.sections[@as(u32, @intCast(if (ch.y >= NUM_CHUNK_SECTION) return null else ch.y))];
        switch (section.bits_per_entry) {
            0 => {
                return section.mapping.items[0];
            },
            1...3 => unreachable,
            else => {
                const block_index = rx + (rz * 16) + (ry * 256);
                const blocks_per_long = @divTrunc(64, section.bits_per_entry);
                const data_index = @as(u32, @intCast(@divTrunc(block_index, blocks_per_long)));
                const shift_index = @rem(block_index, blocks_per_long);
                const mapping = (section.data.items[data_index] >> @as(u6, @intCast((shift_index * section.bits_per_entry)))) & getBitMask(section.bits_per_entry);
                switch (section.bits_per_entry) {
                    4...8 => { //Indirect mapping
                        return section.mapping.items[mapping];
                    },
                    else => { //Direct mapping for >= 9 bits_per_entry
                        return @as(BLOCK_ID_INT, @intCast(mapping));
                    },
                }
            },
        }
    }

    pub fn setBlockChunk(self: *Self, chunk_pos: V3i, rel_pos: V3i, id: BLOCK_ID_INT) !void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        try self.addNotify(chunk_pos.x, chunk_pos.z);
        const world_z = self.x.getPtr(chunk_pos.x) orelse return;
        const column = world_z.getPtr(chunk_pos.z) orelse return;
        const section = &column.sections[@as(u32, @intCast(chunk_pos.y + 4))];

        try section.setBlock(
            @as(u32, @intCast(rel_pos.x)),
            @as(u32, @intCast(rel_pos.y)),
            @as(u32, @intCast(rel_pos.z)),
            id,
        );
    }

    pub fn setBlock(self: *Self, pos: V3i, id: BLOCK_ID_INT) !void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        {
            const co = ChunkMap.getChunkCoord(pos);
            try self.addNotify(co.x, co.z);
        }
        const section = self.getChunkSectionPtr(pos) orelse {
            std.debug.print("setBlock, invalid chunk warn\n", .{});
            return;
        };

        const rx = @as(u32, @intCast(@mod(pos.x, 16)));
        const rz = @as(u32, @intCast(@mod(pos.z, 16)));
        const ry = @as(u32, @intCast(@mod(pos.y + 64, 16)));

        try section.setBlock(rx, ry, rz, id);
    }

    pub fn insertChunkColumn(self: *Self, cx: i32, cz: i32, chunk: Chunk) !void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        try self.addNotify(cx, cz);

        const zmap = try self.x.getOrPut(cx);
        if (!zmap.found_existing) {
            zmap.value_ptr.* = ChunkMap.ZTYPE.init(self.alloc);
        }

        const chunk_entry = try zmap.value_ptr.getOrPut(cz);
        if (chunk_entry.found_existing) {
            chunk_entry.value_ptr.deinit();
        }
        chunk_entry.value_ptr.* = chunk;
    }
};

pub fn lookAtBlock(pos: V3f, block: V3f) struct { yaw: f32, pitch: f32 } {
    const vect = block.subtract((pos.add(V3f.new(0, 1.62, 0)))).add(V3f.new(0.5, 0.5, 0.5));

    const rads = std.math.radiansToDegrees;
    const asin = std.math.asin;
    const atan2 = std.math.atan2;
    return .{
        .pitch = -rads(f32, @as(f32, @floatCast(asin(vect.y / vect.magnitude())))),
        .yaw = -rads(f32, @as(f32, @floatCast(atan2(f64, vect.x, vect.z)))),
    };
}

pub const BLOCK_ID_INT = u16;
pub const ChunkSection = struct {
    const Self = @This();

    const BLOCKS_PER_SECTION = 16 * 16 * 16;
    const DIRECT_THRESHOLD = 9;
    const DIRECT_BIT_COUNT = 15;

    pub const BlockIndex = struct {
        index: usize,
        offset: usize,
        bit_count: u6,
    };

    pub const DataIterator = struct {
        buffer: []const u64,
        bits_per_entry: u8,
        buffer_index: usize = 0,
        shift_index: usize = 0,

        pub fn next(it: *DataIterator) ?usize {
            if (it.bits_per_entry == 0) return null;
            const entries_per_long = @divTrunc(64, it.bits_per_entry);
            if (((it.buffer_index) * entries_per_long) + it.shift_index >= BLOCKS_PER_SECTION) return null;
            const id = (it.buffer[it.buffer_index] >> @as(u6, @intCast(it.shift_index * it.bits_per_entry))) & getBitMask(it.bits_per_entry);
            it.shift_index += 1;
            if (it.shift_index >= entries_per_long) {
                it.shift_index = 0;
                it.buffer_index += 1;
            }

            //if (it.buffer_index >= it.buffer.len) return null;
            return id;
        }

        pub fn getCoord(it: *DataIterator) V3i {
            const i = (it.buffer_index * @divTrunc(64, it.bits_per_entry)) + it.shift_index;
            const y = @as(i32, @intCast(i >> 8));
            const z = @as(i32, @intCast((i >> 4) & 0xf));
            const x = @as(i32, @intCast(i & 0xf));
            return .{ .x = x, .y = y, .z = z };
        }
    };

    last_update_time: i64 = 0,
    mapping: std.ArrayList(BLOCK_ID_INT),
    data: std.ArrayList(u64),
    bits_per_entry: u8,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .mapping = std.ArrayList(BLOCK_ID_INT).init(alloc), .data = std.ArrayList(u64).init(alloc), .bits_per_entry = 0 };
    }

    pub fn getBlockIndex(self: *Self, rx: u32, ry: u32, rz: u32) BlockIndex {
        switch (self.bits_per_entry) {
            0 => {
                return BlockIndex{ .index = 0, .offset = 0, .bit_count = 0 };
            },
            1...3 => unreachable,
            else => {
                const block_index = rx + (rz * 16) + (ry * 256);
                const blocks_per_long = @divTrunc(64, self.bits_per_entry);
                const data_index = @as(u32, @intCast(@divTrunc(block_index, blocks_per_long)));
                const shift_index = @rem(block_index, blocks_per_long);
                //const mapping = (self.data.items[data_index] >> @intCast(u6, (shift_index * self.bits_per_entry))) & self.getBitMask();
                return BlockIndex{ .index = data_index, .offset = @as(usize, @intCast(shift_index)), .bit_count = @as(u6, @intCast(self.bits_per_entry)) };
            },
        }
    }

    pub fn getBlockFromIndex(self: *const Self, i: u32) struct { pos: V3i, block: BLOCK_ID_INT } {
        const blocks_per_long = @divTrunc(64, self.bits_per_entry);
        const data_index = @divTrunc(i, blocks_per_long);
        const shift_index = @rem(i, blocks_per_long);

        const id = (self.data.items[data_index] >> @as(u6, @intCast(shift_index * self.bits_per_entry))) & getBitMask(self.bits_per_entry);
        return .{ .block = self.mapping.items[id], .pos = V3i.new(@as(i32, @intCast(i & 0xf)), @as(i32, @intCast(i >> 8)), @as(i32, @intCast(i >> 4)) & 0xf) };
    }

    //This function sets the data array to whatever index is mapped to id,
    //The id MUST exist in the mapping.
    pub fn setData(self: *Self, rx: u32, ry: u32, rz: u32, id: BLOCK_ID_INT) void {
        const bi = self.getBlockIndex(rx, ry, rz);
        const long = &self.data.items[bi.index];
        const mask = getBitMask(self.bits_per_entry) << @as(u6, @intCast(bi.offset * bi.bit_count));
        const shifted_id = @as(u64, @intCast(self.getMapping(id) orelse unreachable)) << @as(u6, @intCast(bi.offset * bi.bit_count));
        long.* = (long.* & ~mask) | shifted_id;
    }

    //TODO Modify all relevent functions to support direct indexing for bits_per_entry > 8
    pub fn setBlock(self: *Self, rx: u32, ry: u32, rz: u32, id: BLOCK_ID_INT) !void {
        if (self.hasMapping(id)) { //No need to update just set relevent data
            self.setData(rx, ry, rz, id);
        } else {
            const max_mapping = std.math.pow(BLOCK_ID_INT, 2, self.bits_per_entry);
            if (max_mapping < self.mapping.items.len + 1) {
                const new_bpe = blk: {
                    const calc = numBitsRequired(self.mapping.items.len + 1);
                    if (calc < 4)
                        break :blk 4;
                    break :blk calc;
                };

                const new_bpl = @divTrunc(64, new_bpe);
                var new_data = std.ArrayList(u64).init(self.data.allocator);
                try new_data.resize(@divTrunc(BLOCKS_PER_SECTION, new_bpl) + 1);
                @memset(new_data.items, 0);
                //std.mem.set(u64, new_data.items, 0);

                var new_i: usize = 0;
                var new_shift_i: usize = 0;

                var old_it = DataIterator{ .buffer = self.data.items, .bits_per_entry = self.bits_per_entry };
                var old_dat = old_it.next();
                while (old_dat != null) : (old_dat = old_it.next()) {
                    //std.debug.print("{d} {d}: {d}\n", .{ i, new_i, new_shift_i });
                    const long = &new_data.items[new_i];
                    const mask = getBitMask(new_bpe) << @as(u6, @intCast(new_shift_i * new_bpe));
                    const shifted_id = old_dat.? << @as(u6, @intCast(new_shift_i * new_bpe));
                    long.* = (long.* & ~mask) | shifted_id;

                    //TODO is this math correct
                    //and Is dataIterator correctly iterating
                    new_shift_i += 1;
                    if (new_shift_i >= new_bpl) {
                        new_shift_i = 0;
                        new_i += 1;
                    }
                }

                try self.mapping.append(id);
                self.data.deinit();
                self.data = new_data;
                self.bits_per_entry = @as(u8, @intCast(new_bpe));
                self.setData(rx, ry, rz, id);
            } else {
                try self.mapping.append(id);
                self.setData(rx, ry, rz, id);
            }
        }
    }

    pub fn hasMapping(self: *Self, id: BLOCK_ID_INT) bool {
        return (std.mem.indexOfScalar(BLOCK_ID_INT, self.mapping.items, id) != null);
    }

    pub fn getMapping(self: *Self, id: BLOCK_ID_INT) ?usize {
        return std.mem.indexOfScalar(BLOCK_ID_INT, self.mapping.items, id);
    }

    pub fn deinit(self: *Self) void {
        self.mapping.deinit();
        self.data.deinit();
    }
};

test "chunk section" {
    const alloc = std.testing.allocator;
    var section = ChunkSection.init(alloc);
    defer section.deinit();

    try section.mapping.resize(32);
    section.bits_per_entry = 5;
    try section.data.resize(@divTrunc(4096, 12) + 1);
    std.mem.set(BLOCK_ID_INT, section.mapping.items, 0);
    std.mem.set(u64, section.data.items, 0);

    try section.setBlock(0, 0, 0, 1);
}

pub const BlockIdJson = struct {
    name: []u8,
    ids: []u16,
};

pub const ItemJson = struct {
    name: []u8,
    id: u16,

    fn compare(ctx: u8, key: ItemJson, actual: ItemJson) std.math.Order {
        _ = ctx;
        if (key.id >= actual.id and key.id <= actual.id) return .eq;
        if (key.id > actual.id) return .gt;
        if (key.id < actual.id) return .lt;
        return .eq;
    }
};

pub const TagRegistry = struct {
    const Self = @This();

    const TagJson = struct {
        values: []const []const u8,
    };

    strings: std.ArrayList(std.ArrayList(u8)),

    tags: std.StringHashMap(std.StringHashMap(std.ArrayList(u32))),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .strings = std.ArrayList(std.ArrayList(u8)).init(alloc),
            .tags = std.StringHashMap(std.StringHashMap(std.ArrayList(u32))).init(alloc),
            .alloc = alloc,
        };
    }

    /// Given a path to a minecraft datapacks folder, attempts to add any item tags. With the following restrictions:
    /// Tag files can only contain minecraft:item_name values, no tag references: "#minecraft:tag_name".
    /// The values must be in the "minecraft:" namespace.
    /// Tags are added to the "minecraft:item" namespace under the datapacks specified namespace.
    /// Ex: my_datapack/data/my_ns/data/tags/items/my_item_tag.json -> minecraft:item my_ns:my_item_tag
    pub fn addUserDatapacksTags(self: *Self, dir: std.fs.Dir, datapacks_folder_path: []const u8, reg: *const dreg.DataReg) !void {
        const m = std.mem;

        var str_buf: [256]u8 = undefined;
        var str_fbs = std.io.FixedBufferStream([]u8){ .buffer = &str_buf, .pos = 0 };

        var id_list = std.ArrayList(u32).init(self.alloc);
        defer id_list.deinit();
        var itdir = try dir.openIterableDir(datapacks_folder_path, .{});
        defer itdir.close();
        var dir_it = itdir.iterate();
        while (try dir_it.next()) |pack| {
            if (pack.kind != .directory) continue;
            var pdir = try dir_it.dir.openDir(pack.name, .{});
            defer pdir.close();
            var ns_it_dir = try pdir.openIterableDir("data", .{});
            defer ns_it_dir.close();
            var ns_it = ns_it_dir.iterate();
            while (try ns_it.next()) |ns| {
                if (ns.kind != .directory) continue;
                var ns_dir = try ns_it_dir.dir.openDir(ns.name, .{});
                defer ns_dir.close();
                var item_dir_it = try ns_dir.openIterableDir("tags/items", .{});
                defer item_dir_it.close();
                var item_it = item_dir_it.iterate();
                while (try item_it.next()) |item| {
                    const file_extension = ".json";
                    if (!m.endsWith(u8, item.name, file_extension)) {
                        std.debug.print("Ignoring non json file: {s}\n", .{item.name});
                        continue;
                    }
                    id_list.clearRetainingCapacity();
                    const tj = try com.readJson(item_dir_it.dir, item.name, self.alloc, TagJson);
                    defer tj.deinit();
                    for (tj.value.values) |value| {
                        const allowed_ns = "minecraft:";
                        if (m.startsWith(u8, value, "#")) {
                            const v = value[1..];
                            if (!m.startsWith(u8, v, allowed_ns))
                                return error.namespaceNotSupported;
                            return error.tagsNotSupported;
                        } else {
                            if (!m.startsWith(u8, value, allowed_ns))
                                return error.namespaceNotSupported;

                            const f_item = reg.getItemFromName(value[allowed_ns.len..]) orelse {
                                std.debug.print("tags: invalid item: {s}\n", .{value});
                                continue;
                            };
                            try id_list.append(@intCast(f_item.id));
                        }
                    }
                    str_fbs.reset();
                    const no_file_ext_name = item.name[0 .. item.name.len - file_extension.len];
                    try str_fbs.writer().print("{s}:{s}", .{ ns.name, no_file_ext_name }); //Namespace the new tag
                    try self.addTag("minecraft:item", str_fbs.getWritten(), id_list.items);
                }
            }
        }
    }

    pub fn addTag(self: *Self, tag_ident: []const u8, tag_name: []const u8, id_list: []const u32) !void {
        const r = try self.tags.getOrPut(tag_ident);
        if (!r.found_existing) {
            r.value_ptr.* = std.StringHashMap(std.ArrayList(u32)).init(self.alloc);
            try self.strings.append(std.ArrayList(u8).init(self.alloc));
            try self.strings.items[self.strings.items.len - 1].appendSlice(tag_ident);
            r.key_ptr.* = self.strings.items[self.strings.items.len - 1].items;
        }

        const r2 = try r.value_ptr.getOrPut(tag_name);
        //const r2 = try (self.tags.getPtr(tag_ident) orelse unreachable).getOrPut(tag_name);
        if (!r2.found_existing) {
            r2.value_ptr.* = std.ArrayList(u32).init(self.alloc);

            try self.strings.append(std.ArrayList(u8).init(self.alloc));
            try self.strings.items[self.strings.items.len - 1].appendSlice(tag_name);
            r2.key_ptr.* = self.strings.items[self.strings.items.len - 1].items;
        } else {
            unreachable;
        }

        try r2.value_ptr.appendSlice(id_list);
    }

    pub fn hasTag(self: *Self, block_id: usize, tag_type: []const u8, tag: []const u8) bool {
        const tags = self.tags.getPtr(tag_type) orelse unreachable;
        for ((tags.getPtr(tag) orelse unreachable).items) |it| {
            if (it == block_id) {
                return true;
            }
        }
        return false;
    }

    //Returned memory owned by TagRegistry, only valid as until TagRegistry.deinit() is called.
    pub fn getIdList(self: *Self, namespace: []const u8, tag: []const u8) ?[]const u32 {
        const ns = self.tags.get(namespace) orelse return null;
        return (ns.get(tag) orelse return null).items;
    }

    //Generate a sorted list of ids that have any of the tags[]
    pub fn compileTagList(self: *Self, tag_type: []const u8, tags: []const []const u8) !std.ArrayList(u32) {
        var list = std.ArrayList(u32).init(self.alloc);
        for (tags) |tag| {
            for (((self.tags.getPtr(tag_type) orelse unreachable).getPtr(tag) orelse unreachable).items) |it| {
                var found = false;
                for (list.items) |item| {
                    if (item == it) {
                        found = true;
                        break;
                    }
                }
                if (!found)
                    try list.append(it);
            }
        }

        std.sort.sort(u32, list.items, void, std.sort.asc(u32));
        return list;
    }

    pub fn deinit(self: *Self) void {
        var it = self.tags.iterator();
        while (it.next()) |kv| {
            var tit = kv.value_ptr.iterator();
            while (tit.next()) |kv2| {
                kv2.value_ptr.deinit();
            }
            kv.value_ptr.deinit();
        }
        self.tags.deinit();

        for (self.strings.items) |*str| {
            str.deinit();
        }
        self.strings.deinit();
    }
};

pub const PacketAnalysisJson = struct {
    bound_to: []u8,
    data: []u8,
    timestamp: f32,
};
