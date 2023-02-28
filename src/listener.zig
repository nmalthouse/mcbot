const std = @import("std");

const IDS = @import("list.zig");

const Queue = std.atomic.Queue;

pub fn sendChat(packet: *Packet, server: std.net.Stream.Writer, msg: []const u8) !void {
    if (msg.len > 255) return error.msgToLong;
    try packet.clear();
    try packet.varInt(0x05);
    try packet.string(msg);
    try packet.long(0);
    try packet.long(0);
    try packet.boolean(false);
    try packet.int32(0);
    _ = try server.write(packet.getWritableBuffer());
}

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
    pub const ZTYPE = ChunkMapCoord;

    x: XTYPE,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .x = XTYPE.init(alloc) };
    }

    pub fn getBlockFloat(self: *Self, x: f64, y: f64, z: f64) BLOCK_ID_INT {
        return self.getBlock(
            @floatToInt(i32, x),
            @floatToInt(i32, y),
            @floatToInt(i32, z),
        );
    }
    pub fn getChunkCoord(x: i64, y: i64, z: i64) V3i {
        const cx = @intCast(i32, @divTrunc(x, 16));
        const cz = @intCast(i32, @divTrunc(z, 16));
        const cy = @intCast(i32, @divTrunc(y + 64, 16));
        return .{ .x = cx, .y = cy, .z = cz };
    }

    pub fn getChunkSectionPtr(self: *Self, x: i64, y: i64, z: i64) ?*ChunkSection {
        const cx = @intCast(i32, @divTrunc(x, 16));
        const cz = @intCast(i32, @divTrunc(z, 16));
        const cy = @intCast(i32, @divTrunc(y + 64, 16));

        const world_z = self.x.getPtr(cx) orelse return null;
        const column = world_z.getPtr(cz) orelse return null;
        return &column[@intCast(u32, cy)];
    }

    pub fn getBlock(self: *Self, x: i32, y: i32, z: i32) BLOCK_ID_INT {
        const cx = @divTrunc(x, 16);
        const cz = @divTrunc(z, 16);
        const cy = @divTrunc(y + 64, 16);

        const rx = std.math.absInt(@rem(x, 16)) catch unreachable;
        const rz = std.math.absInt(@rem(z, 16)) catch unreachable;
        const ry = std.math.absInt(@rem(y + 64, 16)) catch unreachable;

        //std.debug.print("Provide pos : {d}\t{d}\t{d}\n", .{ x, y, z });

        const world_z = self.x.getPtr(cx) orelse unreachable;
        const column = world_z.getPtr(cz) orelse unreachable;
        const section = column[@intCast(u32, cy)];
        switch (section.bits_per_entry) {
            0 => {
                return section.mapping.items[0];
            },
            1...3 => unreachable,
            else => {
                //TODO Ensure this function works for all possible bpe's
                //TODO Verify our indexing scheme is correct, is the data actually packed x, z, y
                //Need a mc client to build a chunk that we can query
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

    pub fn setBlock(self: *Self, x: i64, y: i64, z: i64, id: BLOCK_ID_INT) !void {
        const section = self.getChunkSectionPtr(x, y, z) orelse unreachable;

        const rx = @intCast(i32, @rem(x, 16));
        const rz = @intCast(i32, @rem(z, 16));
        const ry = @intCast(i32, @rem(y + 64, 16));

        try section.setBlock(rx, ry, rz, id);
    }

    pub fn deinit(self: *Self) void {
        self.x.deinit();
    }
};

pub const V3i = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const BLOCK_ID_INT = u16;
pub const ChunkSection = struct {
    const Self = @This();

    const BLOCKS_PER_SECTION = 16 * 16 * 16;

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
            it.shift_index += 1;
            const entries_per_long = @divTrunc(64, it.bits_per_entry);
            if (it.shift_index >= entries_per_long) {
                it.shift_index = 0;
                it.buffer_index += 1;
            }

            if (it.buffer_index >= it.buffer.len) return null;
            return (it.buffer[it.buffer_index] >> @intCast(u6, it.shift_index * it.bits_per_entry)) & getBitMask(it.bits_per_entry);
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

    pub fn getBlockIndex(self: *Self, rx: i32, ry: i32, rz: i32) BlockIndex {
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
    pub fn setData(self: *Self, rx: i32, ry: i32, rz: i32, id: BLOCK_ID_INT) void {
        const bi = self.getBlockIndex(rx, ry, rz);
        const long = &self.data.items[bi.index];
        const mask = getBitMask(self.bits_per_entry) << @intCast(u6, bi.offset * bi.bit_count);
        const shifted_id = @intCast(u64, self.getMapping(id) orelse unreachable) << @intCast(u6, bi.offset * bi.bit_count);
        long.* = (long.* & ~mask) | shifted_id;
    }

    pub fn setBlock(self: *Self, rx: i32, ry: i32, rz: i32, id: BLOCK_ID_INT) !void {
        if (self.hasMapping(id)) { //No need to update just set relevent data
            self.setData(rx, ry, rz, id);
        } else {
            const max_mapping = std.math.pow(BLOCK_ID_INT, 2, self.bits_per_entry);
            if (max_mapping < self.mapping.items.len + 1) {
                const new_bpe = numBitsRequired(self.mapping.items.len + 1);

                const new_bpl = @divTrunc(64, new_bpe);
                var new_data = std.ArrayList(u64).init(self.data.allocator);
                try new_data.resize(@divTrunc(BLOCKS_PER_SECTION, new_bpl) + 1);
                std.mem.set(u64, new_data.items, 0);

                var new_i: usize = 0;
                var new_shift_i: usize = 0;

                var old_it = DataIterator{ .buffer = self.data.items, .bits_per_entry = self.bits_per_entry };
                var old_dat = old_it.next();
                while (old_dat != null) : (old_dat = old_it.next()) {
                    const long = &new_data.items[new_i];
                    const mask = getBitMask(new_bpe) << @intCast(u6, new_shift_i * new_bpe);
                    const shifted_id = old_dat.? << @intCast(u6, new_shift_i * new_bpe);
                    long.* = (long.* & ~mask) | shifted_id;

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

    //pub fn dumpSection(self: *Self)void {
    //    for(data)
    //}

    //pub fn getBitMask(self: *const Self) u64 {
    //    if (self.bits_per_entry < 4 or self.bits_per_entry == 0 or self.bits_per_entry > 8) unreachable;
    //    //return @as(u64, 0x1) <<| (self.bits_per_entry - 1);
    //    return (~@as(u64, 0x0)) >> @intCast(u6, 64 - self.bits_per_entry);

    //    //From wiki.vg/chunk_format:
    //    //For block states with bits per entry <= 4, 4 bits are used to represent a block.
    //    //For block states and bits per entry between 5 and 8, the given value is used.
    //    //For biomes the given value is always used, and will be <= 3
    //}

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

pub const BlockIdJson = struct {
    name: []u8,
    ids: []u16,
};

pub fn findBlockNameFromId(table: []const BlockIdJson, q_id: u16) []const u8 {
    for (table) |entry| {
        for (entry.ids) |id| {
            if (id == q_id) {
                return entry.name;
            }
        }
    }
    return "Block not found";
}

pub const PacketAnalysisJson = struct {
    bound_to: []u8,
    data: []u8,
    timestamp: f32,
};
