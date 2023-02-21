const std = @import("std");

const IDS = @import("list.zig");

const Queue = std.atomic.Queue;

pub const Packet = struct {
    const Self = @This();
    const RESERVED_BYTE_COUNT: usize = 5;

    buffer: std.ArrayList(u8),

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

    pub fn double(self: *Self, f: f64) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u64, @bitCast(u64, f), .Big);
    }

    pub fn short(self: *Self, val: u16) !void {
        const wr = self.buffer.writer();
        _ = try wr.writeInt(u16, val, .Big);
    }

    pub fn getWritableBuffer(self: *Self) []const u8 {
        var len = toVarInt(@intCast(i32, self.buffer.items.len - RESERVED_BYTE_COUNT));
        std.mem.copy(u8, self.buffer.items[RESERVED_BYTE_COUNT - len.len ..], len.getSlice());
        return self.buffer.items[RESERVED_BYTE_COUNT - len.len ..];
    }
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

const reader_type = std.net.Stream.Reader;

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

//public int readVarInt() {
//    int value = 0;
//    int position = 0;
//    byte currentByte;
//
//    while (true) {
//        currentByte = readByte();
//        value |= (currentByte & SEGMENT_BITS) << position;
//
//        if ((currentByte & CONTINUE_BIT) == 0) break;
//
//        position += 7;
//
//        if (position >= 32) throw new RuntimeException("VarInt is too big");
//    }
//
//    return value;
//}

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

pub const ParsedPacket = struct {
    const Self = @This();

    //TODO keep track of the state that this packet was recieved in, login, play
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

        node.* = .{ .prev = null, .next = null, .data = .{ .id = 0, .len = 0, .buffer = msg, .msg_type = .local } };
        queue.put(node);
        q_cond.signal();
    }
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
    ) void {
        var parsed = ParsedPacket.init(alloc);
        //defer parsed.deinit();

        while (true) {
            parsed.len = readVarInt(reader);
            parsed.id = readVarInt(reader);
            var data_count: u32 = toVarInt(parsed.id).len;
            //std.debug.print("Packet with len: {x} id {s}\n", .{
            //    parsed.len,
            //    IDS.packet_ids[@intCast(u32, parsed.id)],
            //});
            {
                //std.debug.print("parsing data\n", .{});
                while (data_count < parsed.len) : (data_count += 1) {
                    const byte = reader.readByte() catch unreachable;
                    parsed.buffer.append(byte) catch unreachable;
                }
                const node = alloc.create(PacketQueueType.Node) catch unreachable;
                node.* = .{ .prev = null, .next = null, .data = parsed };
                queue.put(node);
                parsed = ParsedPacket.init(alloc);
                q_cond.signal();
            }
        }
    }
};

pub const Chunk = [16]ChunkSection;
pub const ChunkMapCoord = std.AutoHashMap(i32, Chunk);
pub const ChunkMap = struct {
    const Self = @This();

    pub const XTYPE = std.AutoHashMap(i32, ChunkMapCoord);
    pub const YTYPE = ChunkMapCoord;

    x: XTYPE,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .x = XTYPE.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.x.deinit();
    }
};

pub const BLOCK_ID_INT = u16;
pub const ChunkSection = struct {
    const Self = @This();
    mapping: std.ArrayList(BLOCK_ID_INT),
    data: std.ArrayList(u64),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .mapping = std.ArrayList(BLOCK_ID_INT).init(alloc), .data = std.ArrayList(u64).init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.mapping.deinit();
        self.data.deinit();
    }
};

pub const BlockIdJson = struct {
    name: []u8,
    ids: []u16,
};

pub const PacketAnalysisJson = struct {
    bound_to: []u8,
    data: []u8,
    timestamp: f32,
};
