const std = @import("std");

const IDS = @import("list.zig");
const nbt_zig = @import("nbt.zig");

const vector = @import("vector.zig");
const V3f = vector.V3f;
const V3i = vector.V3i;

const Queue = std.atomic.Queue;

//TODO Edit api to use vector structs for everything

const Serv = std.net.Stream.Writer;
pub const PacketCtx = struct {
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
        try self.packet.varInt(0x31);
        try self.packet.varInt(@enumToInt(hand));
        try self.packet.iposition(block_pos);
        try self.packet.varInt(@enumToInt(face));
        try self.packet.float(cx);
        try self.packet.float(cy);
        try self.packet.float(cz);
        try self.packet.boolean(head_in_block);
        try self.packet.varInt(sequence);
        try self.packet.writeToServer(self.server);
    }

    pub fn sendChat(self: *@This(), msg: []const u8) !void {
        if (msg.len > 255) return error.msgToLong;
        try self.packet.clear();
        try self.packet.varInt(0x05);
        try self.packet.string(msg);
        try self.packet.long(0);
        try self.packet.long(0);
        try self.packet.boolean(false);
        try self.packet.int32(0);
        try self.packet.writeToServer(self.server);
    }

    pub fn playerAction(self: *@This(), status: PlayerActionStatus, block_pos: vector.V3i) !void {
        try self.packet.clear();
        try self.packet.varInt(0x1C); //Packet id
        try self.packet.varInt(@enumToInt(status));
        try self.packet.iposition(block_pos);
        try self.packet.ubyte(0); //Face of block
        try self.packet.varInt(0);
        try self.packet.writeToServer(self.server);
    }

    pub fn handshake(self: *@This(), hostname: []const u8, port: u16) !void {
        try self.packet.clear();
        try self.packet.varInt(0); //Packet id
        try self.packet.varInt(761); //Protocol version
        try self.packet.string(hostname);
        try self.packet.short(port);
        try self.packet.varInt(2); //Next state
        try self.packet.writeToServer(self.server);
    }

    pub fn clientCommand(self: *@This(), action: u8) !void {
        try self.packet.clear();
        try self.packet.varInt(0x06);
        try self.packet.varInt(action);
        try self.packet.writeToServer(self.server);
    }

    pub fn completeLogin(self: *@This()) !void {
        try self.packet.clear();
        try self.packet.varInt(0x06);
        try self.packet.varInt(0x0);
        try self.packet.writeToServer(self.server);
    }

    pub fn loginStart(self: *@This(), username: []const u8) !void {
        try self.packet.clear();
        try self.packet.varInt(0); //Packet id
        try self.packet.string(username);
        try self.packet.boolean(false); //No uuid
        try self.packet.writeToServer(self.server);
    }

    pub fn keepAlive(self: *@This(), id: i64) !void {
        try self.packet.clear();
        try self.packet.varInt(0x11);
        try self.packet.long(id);
        try self.packet.writeToServer(self.server);
    }

    pub fn setPlayerRot(self: *@This(), yaw: f32, pitch: f32, grounded: bool) !void {
        try self.packet.clear();
        try self.packet.varInt(0x15);
        try self.packet.float(yaw);
        try self.packet.float(pitch);
        try self.packet.boolean(grounded);
        try self.packet.writeToServer(self.server);
    }

    pub fn setPlayerPositionRot(self: *@This(), pos: V3f, yaw: f32, pitch: f32, grounded: bool) !void {
        try self.packet.clear();
        try self.packet.varInt(0x14);
        try self.packet.double(pos.x);
        try self.packet.double(pos.y);
        try self.packet.double(pos.z);
        try self.packet.float(yaw);
        try self.packet.float(pitch);
        try self.packet.boolean(grounded);
        //std.debug.print("MOVE PACKET {d} {d} {d} {any}\n", .{ pos.x, pos.y, pos.z, grounded });
        try self.packet.writeToServer(self.server);
    }

    pub fn confirmTeleport(self: *@This(), id: i32) !void {
        try self.packet.clear();
        try self.packet.varInt(0);
        try self.packet.varInt(id);
        try self.packet.writeToServer(self.server);
    }

    pub fn pluginMessage(self: *@This(), brand: []const u8) !void {
        try self.packet.clear();
        try self.packet.varInt(0x0C);
        try self.packet.string(brand);
        try self.packet.writeToServer(self.server);
    }

    pub fn clientInfo(self: *@This(), locale: []const u8, render_dist: u8, main_hand: u8) !void {
        try self.packet.clear();
        try self.packet.varInt(0x07); //client info packet
        try self.packet.string(locale);
        try self.packet.ubyte(render_dist);
        try self.packet.varInt(0); //Chat mode, enabled
        try self.packet.boolean(true); //Chat colors enabled
        try self.packet.ubyte(0); // what parts are shown of skin
        try self.packet.varInt(main_hand);
        try self.packet.boolean(false); //No text filtering
        try self.packet.boolean(true); //Allow this bot to be listed
        try self.packet.writeToServer(self.server);
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
    return (~@as(u64, 0x0)) >> @intCast(u6, 64 - num_bits);

    //From wiki.vg/chunk_format:
    //For block states with bits per entry <= 4, 4 bits are used to represent a block.
    //For block states and bits per entry between 5 and 8, the given value is used.
    //For biomes the given value is always used, and will be <= 3
}

pub const PacketReader = struct {};

pub const Packet = struct {
    const Self = @This();
    const RESERVED_BYTE_COUNT: usize = 5;

    buffer: std.ArrayList(u8),
    comp_thresh: i32 = -1,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var ret = Self{
            .buffer = std.ArrayList(u8).init(alloc),
        };
        try ret.buffer.resize(RESERVED_BYTE_COUNT);

        return ret;
    }

    pub fn clear(self: *Self) !void {
        try self.buffer.resize(RESERVED_BYTE_COUNT);
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn boolean(self: *Self, val: bool) !void {
        try self.buffer.writer().writeByte(if (val) 0x01 else 0x00);
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
        try self.varInt(@intCast(i32, str.len));
        const wr = self.buffer.writer();
        _ = try wr.write(str);
    }

    pub fn float(self: *Self, f: f32) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u32, @bitCast(u32, f), .Big);
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
        _ = try wr.writeInt(u64, @bitCast(u64, f), .Big);
    }

    pub fn short(self: *Self, val: u16) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u16, val, .Big);
    }

    pub fn writeToServer(self: *Self, server: std.net.Stream.Writer) !void {
        const comp_enable = (self.comp_thresh > -1);
        //_ = try server.writeByte(0);
        var len = toVarInt(@intCast(i32, self.buffer.items.len - RESERVED_BYTE_COUNT) + @as(i32, if (comp_enable) 1 else 0));
        _ = try server.write(len.getSlice());
        if (comp_enable)
            _ = try server.writeByte(0);

        _ = try server.write(self.buffer.items[RESERVED_BYTE_COUNT..]);
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
    var value = @bitCast(u64, input);

    while (true) {
        if ((value & ~SEG) == 0) {
            ret.bytes[ret.len] = @intCast(u8, value & SEG);
            ret.len += 1;
            return ret;
        }

        ret.bytes[ret.len] = @intCast(u8, (value & SEG) | CONT);
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
    var value = @bitCast(u32, input);

    while (true) {
        if ((value & ~SEG) == 0) {
            ret.bytes[ret.len] = @intCast(u8, value & SEG);
            ret.len += 1;
            return VarInt{ .bytes = ret.bytes, .len = ret.len };
        }

        ret.bytes[ret.len] = @intCast(u8, (value & SEG) | CONT);
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
    //TODO nbt

};

const reader_type = std.net.Stream.Reader;

pub fn packetParseCtx(comptime readerT: type) type {
    return struct {
        const Self = @This();

        //This structure makes no attempt to keep track of memory it allocates, as much of what is parsed is
        //garbage
        //use an arena allocator and copy over values that you need
        pub fn init(reader: readerT, alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .reader = reader,
            };
        }

        pub fn int(self: *Self, comptime intT: type) intT {
            return self.reader.readInt(intT, .Big) catch unreachable;
        }

        pub fn blockEntity(self: *Self) u8 {
            const pxz = self.int(u8);
            const y = self.int(i16);
            const btype = self.varInt();
            const nbt = nbt_zig.parse(self.alloc, self.reader) catch unreachable;
            _ = nbt;
            _ = pxz;
            _ = y;
            _ = btype;
            return 0;
        }

        pub fn slot(self: *Self) ?Slot {
            if (self.boolean()) { //Is item present

                const s = Slot{
                    .item_id = @intCast(u16, self.varInt()),
                    .count = self.int(u8),
                };
                const nbt = nbt_zig.parse(self.alloc, self.reader) catch unreachable;
                _ = nbt;
                return s;
            }
            return null;
        }

        pub fn float(self: *Self, comptime fT: type) fT {
            if (fT == f32) {
                return @bitCast(f32, self.int(u32));
            }
            if (fT == f64) {
                return @bitCast(f64, self.int(u64));
            }
            unreachable;
        }

        pub fn v3f(self: *Self) V3f {
            return .{
                .x = self.float(f64),
                .y = self.float(f64),
                .z = self.float(f64),
            };
        }

        pub fn cposition(self: *Self) vector.V3i {
            const pos = self.int(i64);
            return .{
                .x = @intCast(i32, pos >> 42),
                .y = @intCast(i32, pos << 44 >> 44),
                .z = @intCast(i32, pos << 22 >> 42),
            };
        }

        pub fn position(self: *Self) vector.V3i {
            const pos = self.int(i64);
            return .{
                .x = @intCast(i32, pos >> 38),
                .y = @intCast(i32, pos << 52 >> 52),
                .z = @intCast(i32, pos << 26 >> 38),
            };
        }

        pub fn varInt(self: *Self) i32 {
            return readVarInt(self.reader);
        }

        pub fn varLong(self: *Self) i64 {
            return readVarLong(self.reader);
        }

        pub fn boolean(self: *Self) bool {
            return (self.int(u8) == 1);
        }

        pub fn string(self: *Self, max_len: ?usize) ![]const u8 {
            const len = @intCast(u32, readVarInt(self.reader));
            if (max_len) |l|
                if (len > l) return error.StringExceedsMaxLen;
            const slice = try self.alloc.alloc(u8, len);
            try self.reader.readNoEof(slice);
            return slice;
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
        value |= @intCast(u64, current_byte & SEG) << @intCast(u5, pos);
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 64) unreachable;
    }

    return @bitCast(i64, value);
}

pub fn readVarInt(reader: anytype) i32 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u32 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = reader.readByte() catch unreachable;
        value |= @intCast(u32, current_byte & SEG) << @intCast(u5, pos);
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 32) unreachable;
    }

    return @bitCast(i32, value);
}

pub fn readVarIntWithError(reader: anytype) !i32 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u32 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = try reader.readByte();
        value |= @intCast(u32, current_byte & SEG) << @intCast(u5, pos);
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 32) unreachable;
    }

    return @bitCast(i32, value);
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

    for (values) |v, i| {
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

    for (values) |v, i| {
        var vi = toVarInt(v);
        const sl = vi.getSlice();
        try expect(std.mem.eql(u8, sl, expected[i]));
    }
}

//TODO remove the id and len field and replace with a slice
pub const ParsedPacket = struct {
    const Self = @This();

    id: i32,
    len: i32,
    buffer: std.ArrayList(u8),
    msg_type: MsgType = .server,

    pub const MsgType = enum {
        server,
        local,
    };

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{ .buffer = std.ArrayList(u8).init(alloc), .id = 0, .len = 0 };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }
};

pub const PacketQueueType = Queue(ParsedPacket);

pub fn cmdThread(
    alloc: std.mem.Allocator,
    queue: *PacketQueueType,
    q_cond: *std.Thread.Condition,
) void {
    const stdin = std.io.getStdIn();
    const reader = stdin.reader();
    var buf: [512]u8 = undefined;

    while (true) {
        const len = reader.read(&buf) catch unreachable;
        const read = buf[0..len];
        const node = alloc.create(PacketQueueType.Node) catch unreachable;
        var msg = std.ArrayList(u8).init(alloc);
        msg.appendSlice(read) catch unreachable;

        if ((msg.items.len == 1 and msg.items[0] != '\n') or msg.items.len == 0) {
            msg.resize(0) catch unreachable;
            msg.appendSlice("exit\n") catch unreachable;
        }

        node.* = .{ .prev = null, .next = null, .data = .{ .id = 0, .len = 0, .buffer = msg, .msg_type = .local } };
        queue.put(node);
        q_cond.signal();

        if (std.mem.eql(u8, "exit", msg.items[0 .. msg.items.len - 1])) {
            return;
        }
    }
}

pub fn recvPacket(alloc: std.mem.Allocator, reader: std.net.Stream.Reader, comp_threshold: i32) ![]const u8 {
    const comp_enabled = (comp_threshold > -1);
    const total_len = @intCast(u32, readVarInt(reader));
    //const is_compressed = blk: {
    //    if (comp_enabled)
    //        break :blk (readVarInt(reader) != 0);
    //    break :blk false;
    //};

    const buf = try alloc.alloc(u8, total_len);
    errdefer alloc.free(buf);
    var n: u32 = 0;
    while (n < total_len) : (n += 1) {
        buf[n] = try reader.readByte();
    }

    if (comp_enabled) {
        var in_stream = std.io.FixedBufferStream([]const u8){ .buffer = buf, .pos = 0 };
        const comp_len = readVarInt(in_stream.reader());
        if (comp_len == 0)
            return buf[in_stream.pos..];
        var zlib_stream = try std.compress.zlib.zlibStream(alloc, in_stream.reader());
        defer zlib_stream.deinit();
        const ubuf = try zlib_stream.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        alloc.free(buf);
        return ubuf;
    }
    return buf;
}

pub const ServerListener = struct {
    pub const PacketStateUncompressed = enum {
        parsing_length,
        parsing_id,
        parsing_data,
        invalid,
    };

    pub const PacketStateCompressed = enum {
        complete,
        parsing_packet_length,
        parsing_uncompressed_length,
        parsing_compressed_id,
        parsing_compressed_data,
        invalid,
    };

    pub fn parserThread(
        alloc: std.mem.Allocator,
        reader: std.net.Stream.Reader,
        queue: *PacketQueueType,
        q_cond: *std.Thread.Condition,
        comp_thresh: i32,
    ) void {
        var parsed = ParsedPacket.init(alloc);
        //defer parsed.deinit();

        const value = blk: {
            while (true) {
                const pd = recvPacket(alloc, reader, comp_thresh) catch |err| break :blk err;
                //parsed.len = @intCast(i32, pd.len);
                //var in_stream = std.io.FixedBufferStream([]const u8){ .buffer = pd, .pos = 0 };
                //parsed.id = readVarInt(in_stream.reader());
                parsed.buffer.appendSlice(pd) catch unreachable;
                alloc.free(pd);
                const node = alloc.create(PacketQueueType.Node) catch unreachable;
                node.* = .{ .prev = null, .next = null, .data = parsed };
                queue.put(node);
                parsed = ParsedPacket.init(alloc);
                q_cond.signal();
            }
        };
        switch (value) {
            error.NotOpenForReading => {
                return;
            },
            else => {
                std.debug.print("Value {}\n", .{value});
                unreachable;
            },
        }
    }
};

pub const Chunk = [16]ChunkSection;
pub const ChunkMapCoord = std.AutoHashMap(i32, Chunk);
pub const ChunkMap = struct {
    const Self = @This();

    pub const XTYPE = std.AutoHashMap(i32, ChunkMapCoord);
    pub const ZTYPE = ChunkMapCoord;

    x: XTYPE,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .x = XTYPE.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        var it = self.x.iterator();
        while (it.next()) |kv| {
            var zit = kv.value_ptr.iterator();
            while (zit.next()) |kv2| {
                for (kv2.value_ptr.*) |*section| {
                    section.deinit();
                }
            }
            kv.value_ptr.deinit();
        }

        self.x.deinit();
    }

    pub fn removeChunkColumn(self: *Self, cx: i32, cz: i32) void {
        if (self.x.getPtr(cx)) |zw| {
            if (zw.getPtr(cz)) |*cc| {
                for (cc.*) |*section| {
                    section.deinit();
                }
                _ = zw.remove(cz);
            }
        }
    }

    pub fn isLoaded(self: *Self, pos: V3i) bool {
        return (self.getChunkSectionPtr(pos) != null);
        //const co = getChunkCoord(pos);
        //if (self.x.get(co.x)) |z| {
        //    return z.contains(co.z);
        //}
        //return false;
    }

    pub fn getChunkCoord(pos: V3i) V3i {
        const cx = @intCast(i32, @divFloor(pos.x, 16));
        const cz = @intCast(i32, @divFloor(pos.z, 16));
        const cy = @intCast(i32, @divFloor(pos.y + 64, 16));
        return .{ .x = cx, .y = cy, .z = cz };
    }

    pub fn getChunkSectionPtr(self: *Self, pos: V3i) ?*ChunkSection {
        const ch = ChunkMap.getChunkCoord(pos);

        const world_z = self.x.getPtr(ch.x) orelse return null;
        const column = world_z.getPtr(ch.z) orelse return null;
        return &column[@intCast(u32, ch.y)];
    }

    pub fn getBlock(self: *Self, pos: V3i) BLOCK_ID_INT {
        const ch = ChunkMap.getChunkCoord(pos);

        const rx = @mod(pos.x, 16);
        const rz = @mod(pos.z, 16);
        const ry = @mod(pos.y + 64, 16);

        const world_z = self.x.getPtr(ch.x) orelse unreachable;
        const column = world_z.getPtr(ch.z) orelse unreachable;
        const section = column[@intCast(u32, ch.y)];
        switch (section.bits_per_entry) {
            0 => {
                return section.mapping.items[0];
            },
            1...3 => unreachable,
            else => {
                const block_index = rx + (rz * 16) + (ry * 256);
                const blocks_per_long = @divTrunc(64, section.bits_per_entry);
                const data_index = @intCast(u32, @divTrunc(block_index, blocks_per_long));
                const shift_index = @rem(block_index, blocks_per_long);
                const mapping = (section.data.items[data_index] >> @intCast(u6, (shift_index * section.bits_per_entry))) & getBitMask(section.bits_per_entry);
                switch (section.bits_per_entry) {
                    4...8 => { //Indirect mapping
                        return section.mapping.items[mapping];
                    },
                    else => { //Direct mapping for >= 9 bits_per_entry
                        return @intCast(BLOCK_ID_INT, mapping);
                    },
                }
            },
        }
    }

    pub fn setBlockChunk(self: *Self, chunk_pos: V3i, rel_pos: V3i, id: BLOCK_ID_INT) !void {
        const world_z = self.x.getPtr(chunk_pos.x) orelse unreachable;
        const column = world_z.getPtr(chunk_pos.z) orelse unreachable;
        const section = &column[@intCast(u32, chunk_pos.y + 4)];

        try section.setBlock(
            @intCast(u32, rel_pos.x),
            @intCast(u32, rel_pos.y),
            @intCast(u32, rel_pos.z),
            id,
        );
    }

    pub fn setBlock(self: *Self, pos: V3i, id: BLOCK_ID_INT) !void {
        const section = self.getChunkSectionPtr(pos) orelse unreachable;

        const rx = @intCast(u32, @mod(pos.x, 16));
        const rz = @intCast(u32, @mod(pos.z, 16));
        const ry = @intCast(u32, @mod(pos.y + 64, 16));

        try section.setBlock(rx, ry, rz, id);
    }
};

pub fn lookAtBlock(pos: V3f, block: V3f) struct { yaw: f32, pitch: f32 } {
    const vect = block.subtract((pos.add(V3f.new(0, 1.62, 0)))).add(V3f.new(0.5, 0.5, 0.5));

    return .{
        //.pitch = 180 - std.math.radiansToDegrees(f32, @floatCast(f32, std.math.acos(V3f.new(0, 1, 0).dot(vect) / vect.magnitude()))),
        .pitch = -std.math.radiansToDegrees(f32, @floatCast(f32, std.math.asin(vect.y / vect.magnitude()))),
        //.yaw = 90 + std.math.radiansToDegrees(f32, std.math.acos(@floatCast(f32, vect.z / vect.magnitude()))),
        .yaw = -std.math.radiansToDegrees(f32, @floatCast(f32, std.math.atan2(f64, vect.x, vect.z))),
        //            yaw = -atan2(dx,dz)/PI*180
        //if yaw < 0 then
        //    yaw = 360 + yaw
        //pitch = -arcsin(dy/r)/PI*180

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
            const id = (it.buffer[it.buffer_index] >> @intCast(u6, it.shift_index * it.bits_per_entry)) & getBitMask(it.bits_per_entry);
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
            const y = @intCast(i32, @divTrunc(i, 256));
            const z = @intCast(i32, @divTrunc(@rem(i, 256), 16));
            const x = @intCast(i32, @rem(@rem(i, 256), 16));
            return .{ .x = x, .y = y, .z = z };
        }
    };

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
                const data_index = @intCast(u32, @divTrunc(block_index, blocks_per_long));
                const shift_index = @rem(block_index, blocks_per_long);
                //const mapping = (self.data.items[data_index] >> @intCast(u6, (shift_index * self.bits_per_entry))) & self.getBitMask();
                return BlockIndex{ .index = data_index, .offset = @intCast(usize, shift_index), .bit_count = @intCast(u6, self.bits_per_entry) };
            },
        }
    }

    //This function sets the data array to whatever index is mapped to id,
    //The id MUST exist in the mapping.
    pub fn setData(self: *Self, rx: u32, ry: u32, rz: u32, id: BLOCK_ID_INT) void {
        const bi = self.getBlockIndex(rx, ry, rz);
        const long = &self.data.items[bi.index];
        const mask = getBitMask(self.bits_per_entry) << @intCast(u6, bi.offset * bi.bit_count);
        const shifted_id = @intCast(u64, self.getMapping(id) orelse unreachable) << @intCast(u6, bi.offset * bi.bit_count);
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
                std.mem.set(u64, new_data.items, 0);

                var new_i: usize = 0;
                var new_shift_i: usize = 0;
                std.debug.print("New bpe : {d}, {d}\n", .{ new_bpe, self.mapping.items.len });

                var old_it = DataIterator{ .buffer = self.data.items, .bits_per_entry = self.bits_per_entry };
                var old_dat = old_it.next();
                while (old_dat != null) : (old_dat = old_it.next()) {
                    //std.debug.print("{d} {d}: {d}\n", .{ i, new_i, new_shift_i });
                    const long = &new_data.items[new_i];
                    const mask = getBitMask(new_bpe) << @intCast(u6, new_shift_i * new_bpe);
                    const shifted_id = old_dat.? << @intCast(u6, new_shift_i * new_bpe);
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
                self.bits_per_entry = @intCast(u8, new_bpe);
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

pub const ItemRegistry = struct {
    const Self = @This();

    data: []ItemJson,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, filename: []const u8) !Self {
        return Self{
            .data = try readJsonFile(filename, alloc, []ItemJson),
            .alloc = alloc,
        };
    }

    pub fn getName(self: *const Self, id: u16) []const u8 {
        const index = std.sort.binarySearch(ItemJson, .{ .id = id, .name = "" }, self.data, @as(u8, 0), ItemJson.compare);
        return self.data[index.?].name;
    }

    pub fn deinit(self: *Self) void {
        freeJson([]ItemJson, self.alloc, self.data);
    }
};

pub const TagRegistry = struct {
    const Self = @This();

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

pub const BlockRegistry = struct {
    const Self = @This();

    pub const IdRange = struct {
        lower: u16,
        upper: u16,

        fn compare(ctx: u8, key: IdRange, actual: IdRange) std.math.Order {
            _ = ctx;
            if (key.lower >= actual.lower and key.lower <= actual.upper) return .eq;
            if (key.lower > actual.upper) return .gt;
            if (key.lower < actual.lower) return .lt;
            return .eq;
        }
    };

    pub const BlockInfo = struct {
        pub const Property = union(enum(u32)) {
            //pub const Unimplemented = u32;
            pub const Facing = enum { north, south, west, east };
        };

        name: []const u8,
        id: u16,

        //properties: []const Property,
    };

    id_array: []IdRange,
    block_info_array: []BlockInfo,

    pub fn init(alloc: std.mem.Allocator, array_file: []const u8, block_table_file: []const u8) !Self {
        return Self{
            .id_array = try readJsonFile(array_file, alloc, []IdRange),
            .block_info_array = try readJsonFile(block_table_file, alloc, []BlockInfo),
        };
    }

    pub fn getBlockIndex(self: *Self, id: BLOCK_ID_INT) usize {
        const index = std.sort.binarySearch(IdRange, .{ .lower = id, .upper = 0 }, self.id_array, @as(u8, 0), BlockRegistry.IdRange.compare);
        return index.?;
    }

    pub fn findBlockName(self: *const Self, id: BLOCK_ID_INT) []const u8 {
        const index = std.sort.binarySearch(IdRange, .{ .lower = id, .upper = 0 }, self.id_array, @as(u8, 0), BlockRegistry.IdRange.compare);
        if (index) |i| {
            return self.block_info_array[i].name;
        }
        return "Block Not Found";
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        freeJson([]IdRange, alloc, self.id_array);
        freeJson([]BlockInfo, alloc, self.block_info_array);
    }
};

pub const PacketAnalysisJson = struct {
    bound_to: []u8,
    data: []u8,
    timestamp: f32,
};

pub const MetaDataType = enum {
    Byte, //
    VarInt, //
    VarLong, //
    Float, //
    String, //
    Chat, //
    OptChat, // (Boolean + Optional Chat) 	Chat is present if the Boolean is set to true
    Slot, //
    Boolean, //
    Rotation, // 	3 floats: rotation on x, rotation on y, rotation on z
    Position, //
    OptPosition, // (Boolean + Optional Position) 	Position is present if the Boolean is set to true
    Direction, // (VarInt) 	(Down = 0, Up = 1, North = 2, South = 3, West = 4, East = 5)
    OptUUID, // (Boolean + Optional UUID) 	UUID is present if the Boolean is set to true
    OptBlockID, // (VarInt) 	0 for absent (implies air); otherwise, a block state ID as per the global palette
    NBT, //
    Particle, //
    Villager, // Data 	3 VarInts: villager type, villager profession, level
    OptVarInt, // 	0 for absent; 1 + actual value otherwise. Used for entity IDs.
    Pose, // 	A VarInt enum: 0: STANDING, 1: FALL_FLYING, 2: SLEEPING, 3: SWIMMING, 4: SPIN_ATTACK, 5: SNEAKING, 6: LONG_JUMPING, 7: DYING, 8: CROAKING, 9: USING_TONGUE, 10: SITTING, 11: ROARING, 12: SNIFFING, 13: EMERGING, 14: DIGGING
    Cat, // Variant 	A VarInt that points towards the CAT_VARIANT registry.
    Frog, // Variant 	A VarInt that points towards the FROG_VARIANT registry.
    GlobalPos, // 	A dimension identifier and Position.
    Painting, // Variant 	A VarInt that points towards the PAINTING_VARIANT registry.

};
