const std = @import("std");
const mc = @import("listener.zig");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const Bot = @import("bot.zig").Bot;
const Reg = @import("data_reg.zig");

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

pub const Entity = struct {
    uuid: u128,
    pos: V3f,
    yaw: f32,
    pitch: f32,
};

pub const McWorld = struct {
    const Self = @This();

    chunk_data: mc.ChunkMap,

    //TODO make entities and bots thread safe
    entities: std.AutoHashMap(i32, Entity),
    bots: std.AutoHashMap(i32, Bot),
    tag_table: mc.TagRegistry,
    reg: *const Reg.NewDataReg,

    packet_cache: struct {
        chat_time_stamps: RingBuf(32, u64) = RingBuf(32, u64).init(0),
    },

    has_tag_table: bool = false,

    master_id: ?i32,

    pub fn init(alloc: std.mem.Allocator, reg: *const Reg.NewDataReg) Self {
        return Self{
            .reg = reg,
            .packet_cache = .{},
            .chunk_data = mc.ChunkMap.init(alloc),
            .entities = std.AutoHashMap(i32, Entity).init(alloc),
            .bots = std.AutoHashMap(i32, Bot).init(alloc),
            .master_id = null,
            .tag_table = mc.TagRegistry.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunk_data.deinit();
        self.entities.deinit();
        self.bots.deinit();
        self.tag_table.deinit();
    }
};
