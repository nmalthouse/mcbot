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

const log = std.log.scoped(.world);

pub const McWorld = struct {
    const Self = @This();

    chunk_data: mc.ChunkMap,

    sign_waypoints_mutex: std.Thread.Mutex = .{},
    sign_waypoints: std.StringHashMap(vector.V3i),
    alloc: std.mem.Allocator,

    //TODO make entities and bots thread safe
    entities: std.AutoHashMap(i32, Entity),
    entities_mutex: std.Thread.Mutex = .{},

    bots: std.AutoHashMap(i32, Bot),
    tag_table: mc.TagRegistry,
    reg: *const Reg.DataReg,

    packet_cache: struct {
        chat_time_stamps: RingBuf(32, u64) = RingBuf(32, u64).init(0),
    },

    has_tag_table: bool = false,

    master_id: ?i32,

    pub fn init(alloc: std.mem.Allocator, reg: *const Reg.DataReg) Self {
        return Self{
            .alloc = alloc,
            .sign_waypoints = std.StringHashMap(vector.V3i).init(alloc),
            .reg = reg,
            .packet_cache = .{},
            .chunk_data = mc.ChunkMap.init(alloc),
            .entities = std.AutoHashMap(i32, Entity).init(alloc),
            .bots = std.AutoHashMap(i32, Bot).init(alloc),
            .master_id = null,
            .tag_table = mc.TagRegistry.init(alloc),
        };
    }

    pub fn putSignWaypoint(self: *Self, sign_name: []const u8, pos: vector.V3i) !void {
        self.sign_waypoints_mutex.lock();
        defer self.sign_waypoints_mutex.unlock();
        const name = try self.alloc.dupe(u8, sign_name);
        log.info("Putting waypoint \"{s}\"", .{name});
        errdefer self.alloc.free(name);
        try self.sign_waypoints.put(name, pos);
    }

    pub fn getSignWaypoint(self: *Self, sign_name: []const u8) ?vector.V3i {
        self.sign_waypoints_mutex.lock();
        defer self.sign_waypoints_mutex.unlock();
        return self.sign_waypoints.get(sign_name);
    }

    pub fn putEntity(self: *Self, ent_id: i32, ent: Entity) !void {
        self.entities_mutex.lock();
        defer self.entities_mutex.unlock();
        try self.entities.put(ent_id, ent);
    }

    pub fn removeEntity(self: *Self, ent_id: i32) void {
        self.entities_mutex.lock();
        defer self.entities_mutex.unlock();
        _ = self.entities.remove(ent_id);
    }

    pub fn deinit(self: *Self) void {
        var kit = self.sign_waypoints.keyIterator();
        while (kit.next()) |key| {
            self.alloc.free(key.*);
        }
        self.sign_waypoints.deinit();
        self.chunk_data.deinit();
        self.entities.deinit();
        var b_it = self.bots.valueIterator();
        while (b_it.next()) |bot| {
            bot.deinit();
        }
        self.bots.deinit();
        self.tag_table.deinit();
    }
};
