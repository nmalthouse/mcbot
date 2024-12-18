const std = @import("std");
const mc = @import("listener.zig");
const Proto = @import("protocol.zig");
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
    kind: Proto.EntityEnum,
    uuid: u128,
    pos: V3f,
    yaw: i8,
    pitch: i8,
};

const log = std.log.scoped(.world);

pub const Poi = struct {
    const Self = @This();

    //If this is slow to search use an octree or something
    crafting_tables: std.ArrayList(vector.V3i),
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .crafting_tables = std.ArrayList(vector.V3i).init(alloc),
        };
    }

    pub fn putNew(self: *Self, pos: vector.V3i) !void {
        self.mutex.lock();
        try self.crafting_tables.append(pos);
        self.mutex.unlock();
    }

    pub fn findNearest(self: *Self, world: *McWorld, pos: vector.V3i) ?vector.V3i {
        const cid = world.reg.getBlockFromNameI("crafting_table").?.id;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            var min_index: ?usize = null;
            var min: f64 = std.math.floatMax(f64);
            const a = pos.toF();
            for (self.crafting_tables.items, 0..) |table, i| {
                const l = table.toF().subtract(a).magnitude();
                if (l < min) {
                    min_index = i;
                    min = l;
                }
            }

            if (min_index) |mi| {
                var is_craft = false;
                if (world.chunk_data.getBlock(self.crafting_tables.items[mi])) |bl| {
                    //check it is still a crafting bench

                    const bll = world.reg.getBlockFromState(bl);
                    if (bll.id == cid)
                        is_craft = true;
                }

                if (is_craft)
                    return self.crafting_tables.items[mi];

                //Delete this one and search again
                _ = self.crafting_tables.swapRemove(mi);
            } else {
                return null;
            }
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        self.crafting_tables.deinit();
    }
};

pub const McWorld = struct {
    const Self = @This();
    pub const Waypoint = struct {
        pos: vector.V3i,
        facing: Reg.Direction,
    };
    //Only used for time, organize the mutex please
    modify_mutex: std.Thread.Mutex = .{},

    ///All api calls to chunk_data are locked internally
    chunk_data: mc.ChunkMap,

    sign_waypoints: std.StringHashMap(Waypoint),
    sign_waypoints_mutex: std.Thread.Mutex = .{},

    /// Poi has its own mutex
    poi: Poi,

    alloc: std.mem.Allocator,

    entities: std.AutoHashMap(i32, Entity),
    entities_mutex: std.Thread.Mutex = .{},

    ///Minecraft day time
    time: i64 = 0,

    /// Used to notify a bot should reload its script
    bot_reload_mutex: std.Thread.Mutex = .{},
    reload_bot_id: ?i32 = null,

    /// Bot's have their own mutex, modifying the bots hash_map after init may cause issues
    bots: std.AutoHashMap(i32, Bot),
    reg: *const Reg.DataReg,

    //TODO what does this do again?
    packet_cache: struct {
        chat_time_stamps: RingBuf(32, i64) = RingBuf(32, i64).init(0),
    },

    has_tag_table: bool = false,
    tag_table: mc.TagRegistry,

    pub fn init(alloc: std.mem.Allocator, reg: *const Reg.DataReg) Self {
        return Self{
            .alloc = alloc,
            .sign_waypoints = std.StringHashMap(Waypoint).init(alloc),
            .reg = reg,
            .poi = Poi.init(alloc),
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

    pub fn putEntity(self: *Self, bot: *Bot, data: anytype, uuid: u128, etype: Proto.EntityEnum) !void {
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
                .kind = etype, //TODO fixme
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
        self.poi.deinit();
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
