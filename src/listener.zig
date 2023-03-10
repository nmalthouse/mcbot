const std = @import("std");

const IDS = @import("list.zig");

const vector = @import("vector.zig");
const V3f = vector.V3f;

const Queue = std.atomic.Queue;

const Serv = std.net.Stream.Writer;
pub fn sendChat(packet: *Packet, server: Serv, msg: []const u8) !void {
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

pub fn handshake(packet: *Packet, server: Serv, hostname: []const u8, port: u16) !void {
    try packet.clear();
    try packet.varInt(0); //Packet id
    try packet.varInt(761); //Protocol version
    try packet.string(hostname);
    try packet.short(port);
    try packet.varInt(2); //Next state
    _ = try server.write(packet.getWritableBuffer());
}

pub fn loginStart(packet: *Packet, server: Serv, username: []const u8) !void {
    try packet.clear();
    try packet.varInt(0); //Packet id
    try packet.string(username);
    try packet.boolean(false); //No uuid
    _ = try server.write(packet.getWritableBuffer());
}

pub fn keepAlive(packet: *Packet, server: Serv, id: i64) !void {
    try packet.clear();
    try packet.varInt(0x11);
    try packet.long(id);
    _ = try server.write(packet.getWritableBuffer());
}

pub fn setPlayerPositionRot(packet: *Packet, server: Serv, pos: V3f, yaw: f32, pitch: f32, grounded: bool) !void {
    try packet.clear();
    try packet.varInt(0x14);
    try packet.double(pos.x);
    try packet.double(pos.y);
    try packet.double(pos.z);
    try packet.float(yaw);
    try packet.float(pitch);
    try packet.boolean(grounded);
    std.debug.print("MOVE PACKET {d} {d} {d} {any}\n", .{ pos.x, pos.y, pos.z, grounded });
    _ = try server.write(packet.getWritableBuffer());
}

pub fn confirmTeleport(p: *Packet, server: Serv, id: i32) !void {
    try p.clear();
    try p.varInt(0);
    try p.varInt(id);
    _ = try server.write(p.getWritableBuffer());
}

pub fn pluginMessage(p: *Packet, server: Serv, brand: []const u8) !void {
    try p.clear();
    try p.varInt(0x0C);
    try p.string(brand);
    _ = try server.write(p.getWritableBuffer());
}

pub fn clientInfo(p: *Packet, server: Serv, locale: []const u8, render_dist: u8, main_hand: u8) !void {
    try p.clear();
    try p.varInt(0x07); //client info packet
    try p.string(locale);
    try p.ubyte(render_dist);
    try p.varInt(0); //Chat mode, enabled
    try p.boolean(true); //Chat colors enabled
    try p.ubyte(0); // what parts are shown of skin
    try p.varInt(main_hand);
    try p.boolean(false); //No text filtering
    try p.boolean(true); //Allow this bot to be listed
    _ = try server.write(p.getWritableBuffer());
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

pub const PacketReader = struct {};

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

        const value = blk: {
            while (true) {
                parsed.len = readVarIntWithError(reader) catch |err| break :blk err;
                parsed.id = readVarIntWithError(reader) catch |err| break :blk err;
                var data_count: u32 = toVarInt(parsed.id).len;
                {
                    //std.debug.print("parsing data\n", .{});
                    while (data_count < parsed.len) : (data_count += 1) {
                        const byte = reader.readByte() catch |err| break :blk err;
                        parsed.buffer.append(byte) catch unreachable;
                    }
                    const node = alloc.create(PacketQueueType.Node) catch unreachable;
                    node.* = .{ .prev = null, .next = null, .data = parsed };
                    queue.put(node);
                    parsed = ParsedPacket.init(alloc);
                    q_cond.signal();
                }
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

    pub fn getBlockFloat(self: *Self, x: f64, y: f64, z: f64) BLOCK_ID_INT {
        return self.getBlock(
            @floatToInt(i32, x),
            @floatToInt(i32, y),
            @floatToInt(i32, z),
        );
    }
    pub fn getChunkCoord(x: i64, y: i64, z: i64) V3i {
        const cx = @intCast(i32, @divFloor(x, 16));
        const cz = @intCast(i32, @divFloor(z, 16));
        const cy = @intCast(i32, @divFloor(y + 64, 16));
        return .{ .x = cx, .y = cy, .z = cz };
    }

    pub fn getChunkSectionPtr(self: *Self, x: i64, y: i64, z: i64) ?*ChunkSection {
        const cx = @intCast(i32, @divFloor(x, 16));
        const cz = @intCast(i32, @divFloor(z, 16));
        const cy = @intCast(i32, @divFloor(y + 64, 16));

        const world_z = self.x.getPtr(cx) orelse return null;
        const column = world_z.getPtr(cz) orelse return null;
        return &column[@intCast(u32, cy)];
    }

    pub fn getBlock(self: *Self, x: i32, y: i32, z: i32) BLOCK_ID_INT {
        const cx = @divFloor(x, 16);
        const cz = @divFloor(z, 16);
        const cy = @divFloor(y + 64, 16);

        const rx = @mod(x, 16);
        const rz = @mod(z, 16);
        const ry = @mod(y + 64, 16);

        const world_z = self.x.getPtr(cx) orelse unreachable;
        const column = world_z.getPtr(cz) orelse unreachable;
        const section = column[@intCast(u32, cy)];
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

    pub fn setBlock(self: *Self, x: i64, y: i64, z: i64, id: BLOCK_ID_INT) !void {
        const section = self.getChunkSectionPtr(x, y, z) orelse unreachable;

        const rx = @intCast(u32, @mod(x, 16));
        const rz = @intCast(u32, @mod(z, 16));
        const ry = @intCast(u32, @mod(y + 64, 16));

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
