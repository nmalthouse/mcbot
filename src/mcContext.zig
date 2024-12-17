const std = @import("std");
const mc = @import("listener.zig");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const Bot = @import("bot.zig").Bot;
const Reg = @import("data_reg.zig");
const IdList = @import("list.zig");
pub const MAX_BOTS = 32;

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
    const OwnersT = std.bit_set.IntegerBitSet(MAX_BOTS);
    owners: OwnersT,
    kind: IdList.entity_type_enum,
    uuid: u128,
    pos: V3f,
    yaw: i8,
    pitch: i8,
};

const log = std.log.scoped(.world);

pub const McWorld = struct {
    const Self = @This();
    pub const Waypoint = struct {
        pos: vector.V3i,
        facing: Reg.Direction,
    };
    modify_mutex: std.Thread.Mutex = .{},

    chunk_data: mc.ChunkMap,

    sign_waypoints_mutex: std.Thread.Mutex = .{},
    sign_waypoints: std.StringHashMap(Waypoint),
    alloc: std.mem.Allocator,

    entities: std.AutoHashMap(i32, Entity),
    entities_mutex: std.Thread.Mutex = .{},

    //Todo remove this
    mine_index: u8 = 1,
    mine_mutex: std.Thread.Mutex = .{},

    time: i64 = 0,

    bot_reload_mutex: std.Thread.Mutex = .{},
    reload_bot_id: ?i32 = null,

    bots: std.AutoHashMap(i32, Bot),
    tag_table: mc.TagRegistry,
    reg: *const Reg.DataReg,

    //TODO what does this do again?
    packet_cache: struct {
        chat_time_stamps: RingBuf(32, i64) = RingBuf(32, i64).init(0),
    },

    has_tag_table: bool = false,

    pub fn init(alloc: std.mem.Allocator, reg: *const Reg.DataReg) Self {
        return Self{
            .alloc = alloc,
            .sign_waypoints = std.StringHashMap(Waypoint).init(alloc),
            .reg = reg,
            .packet_cache = .{},
            .chunk_data = mc.ChunkMap.init(alloc),
            .entities = std.AutoHashMap(i32, Entity).init(alloc),
            .bots = std.AutoHashMap(i32, Bot).init(alloc),
            .tag_table = mc.TagRegistry.init(alloc),
        };
    }

    pub fn addBot(self: *Self, bot: Bot) !void {
        var bb = bot;
        bb.index_id = self.bots.count() + 1;
        try self.bots.put(bb.fd, bb);
    }

    pub fn putSignWaypoint(self: *Self, sign_name: []const u8, waypoint: Waypoint) !void {
        self.sign_waypoints_mutex.lock();
        defer self.sign_waypoints_mutex.unlock();
        const name = try self.alloc.dupe(u8, sign_name);
        log.info("Putting waypoint \"{s}\"", .{name});
        errdefer self.alloc.free(name);
        const gpr = try self.sign_waypoints.getOrPut(name);
        if (gpr.found_existing) {
            self.alloc.free(gpr.key_ptr.*);
            gpr.key_ptr.* = name;
            log.warn("Clobbering waypoint: {s}", .{name});
        }
        gpr.value_ptr.* = waypoint;
    }

    pub fn getSignWaypoint(self: *Self, sign_name: []const u8) ?Waypoint {
        self.sign_waypoints_mutex.lock();
        defer self.sign_waypoints_mutex.unlock();
        return self.sign_waypoints.get(sign_name);
    }

    pub fn putEntity(self: *Self, bot: *Bot, data: anytype, uuid: u128) !void {
        self.entities_mutex.lock();
        defer self.entities_mutex.unlock();

        const g = try self.entities.getOrPut(data.entityId);
        if (g.found_existing) {
            g.value_ptr.owners.set(bot.index_id);
        } else {
            g.key_ptr.* = data.entityId;
            var set = Entity.OwnersT.initEmpty();
            set.set(bot.index_id);
            g.value_ptr.* = .{
                .owners = set,
                .kind = .@"minecraft:cod", //TODO fixme
                .uuid = uuid,
                .pos = V3f.new(data.x, data.y, data.z),
                .pitch = data.pitch,
                .yaw = data.yaw,
            };
        }
    }

    /// Returns a ptr to entity if the bot is considered the owner.
    /// used for updating state of entity
    /// The returned pointer should not be stored
    /// The caller of the function must unlock entites_mutex if nonnull is returned;
    ///
    /// The first bot in the set that has this entity alive is considered the owner, this is needed as some packets do a relative update of entity state so packets from multiple bots would cause issues.
    pub fn modifyEntityLocal(self: *Self, bot_index: u32, ent_id: i32) ?*Entity {
        self.entities_mutex.lock();
        if (self.entities.getPtr(ent_id)) |e| {
            if (e.owners.findFirstSet()) |first| {
                if (first == bot_index)
                    return e;
            }
        }
        self.entities_mutex.unlock();
        return null;
    }

    pub fn removeEntity(self: *Self, bot_index: u32, ent_id: i32) void {
        self.entities_mutex.lock();
        defer self.entities_mutex.unlock();
        if (self.entities.getPtr(ent_id)) |ent| {
            ent.owners.unset(bot_index);
            if (ent.owners.mask == 0) { //No bots are owning
                _ = self.entities.remove(ent_id);
            }
        }
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
