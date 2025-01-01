const std = @import("std");
const mc = @import("listener.zig");
const Proto = @import("protocol.zig");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const Bot = @import("bot.zig").Bot;
const Reg = @import("data_reg.zig");
const nbt_zig = @import("nbt.zig");
const config = @import("config");

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
    const OwnersT = std.bit_set.IntegerBitSet(config.MAX_BOTS);
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
    dim: i32,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, dim: i32) @This() {
        return .{
            .dim = dim,
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
                if (world.chunkdata(self.dim).getBlock(self.crafting_tables.items[mi])) |bl| {
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
    pub const DimInfo = struct {
        section_count: u32,
        min_y: i32,
        id: i32,
        bed_works: bool,
    };
    pub const Dimension = struct {
        chunk_data: mc.ChunkMap,
        info: McWorld.DimInfo,
        sign_waypoints: std.StringHashMap(std.ArrayList(Waypoint)),
        sign_waypoints_mutex: std.Thread.Mutex = .{},
        /// Poi has its own mutex
        poi: Poi,

        pub fn init(dim_info: DimInfo, alloc: std.mem.Allocator) Dimension {
            return .{
                .chunk_data = mc.ChunkMap.init(alloc, dim_info.section_count, dim_info.min_y),
                .sign_waypoints = std.StringHashMap(std.ArrayList(Waypoint)).init(alloc),
                .poi = Poi.init(alloc, dim_info.id),
                .info = dim_info,
            };
        }

        pub fn deinit(self: *Dimension, alloc: std.mem.Allocator) void {
            self.poi.deinit();
            self.chunk_data.deinit();
            var kit = self.sign_waypoints.iterator();
            while (kit.next()) |key| {
                alloc.free(key.key_ptr.*);
                key.value_ptr.deinit();
            }
            self.sign_waypoints.deinit();
        }
    };
    //Only used for time, organize the mutex please
    modify_mutex: std.Thread.Mutex = .{},

    ///All api calls to chunk_data are locked internally
    //chunk_data: mc.ChunkMap, //TODO support dimensions

    dimension_map: std.StringHashMap(DimInfo),
    dimensions: std.AutoHashMap(i32, Dimension),

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
            .dimension_map = std.StringHashMap(DimInfo).init(alloc),
            .dimensions = std.AutoHashMap(i32, Dimension).init(alloc),
            .reg = reg,
            .packet_cache = .{},
            //.chunk_data = mc.ChunkMap.init(alloc),
            .entities = std.AutoHashMap(i32, Entity).init(alloc),
            .bots = std.AutoHashMap(i32, Bot).init(alloc),
            .tag_table = mc.TagRegistry.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        var dim_it = self.dimension_map.iterator();
        while (dim_it.next()) |d| {
            self.alloc.free(d.key_ptr.*);
        }
        var d_it = self.dimensions.iterator();
        while (d_it.next()) |dd| {
            dd.value_ptr.deinit(self.alloc);
        }
        self.dimensions.deinit();
        self.dimension_map.deinit();
        //self.chunk_data.deinit();
        self.entities.deinit();
        var b_it = self.bots.valueIterator();
        while (b_it.next()) |bot| {
            bot.deinit();
        }
        self.bots.deinit();
        self.tag_table.deinit();
    }

    pub fn addBot(self: *Self, bot: Bot, index_id: u32) !void {
        var bb = bot;
        bb.index_id = index_id;
        try self.bots.put(bb.fd, bb);
    }

    pub fn putSignWaypoint(self: *Self, dim: i32, sign_name: []const u8, waypoint: Waypoint) !void {
        const d = self.dimensions.getPtr(dim).?;
        d.sign_waypoints_mutex.lock();
        defer d.sign_waypoints_mutex.unlock();
        const name = try self.alloc.dupe(u8, sign_name);
        log.info("Putting waypoint \"{s}\"", .{name});
        errdefer self.alloc.free(name);
        const gpr = try d.sign_waypoints.getOrPut(name);
        if (gpr.found_existing) {
            self.alloc.free(gpr.key_ptr.*);
            gpr.key_ptr.* = name;
            try gpr.value_ptr.append(waypoint);
            log.warn("Adding second waypoint: {s}", .{name});
        } else {
            var new_list = std.ArrayList(Waypoint).init(self.alloc);
            try new_list.append(waypoint);
            gpr.value_ptr.* = new_list;
        }
    }

    pub fn getNearestSignWaypoint(self: *Self, dim: i32, sign_name: []const u8, pos: vector.V3i) ?Waypoint {
        const d = self.dimensions.getPtr(dim).?;
        d.sign_waypoints_mutex.lock();
        defer d.sign_waypoints_mutex.unlock();
        var min_index: ?usize = null;
        var min_dist = std.math.floatMax(f64);
        const p = pos.toF();
        if (d.sign_waypoints.get(sign_name)) |wps| {
            for (wps.items, 0..) |wp, i| {
                const dist = wp.pos.toF().subtract(p).magnitude();
                if (dist < min_dist) {
                    min_index = i;
                    min_dist = dist;
                }
            }
            if (min_index) |mi| {
                return wps.items[mi];
            }
        }
        return null;
    }

    pub fn chunkdata(self: *Self, dim_id: i32) *mc.ChunkMap {
        return &(self.dimensions.getPtr(dim_id) orelse unreachable).chunk_data;
    }

    pub fn dimPtr(self: *Self, dim_id: i32) *Dimension {
        return (self.dimensions.getPtr(dim_id) orelse unreachable);
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

    pub fn putBlockEntity(self: *Self, dim_id: i32, coord: vector.V3i, nbt: nbt_zig.Entry, aa: std.mem.Allocator) !void {
        const dim = self.dimensions.getPtr(dim_id) orelse return;
        const id = dim.chunk_data.getBlock(coord) orelse return;
        const b = self.reg.getBlockFromState(id);

        //const j = try nbt.toJsonValue(aa);
        //const wr = std.io.getStdOut().writer();
        //try std.json.stringify(j, .{ .whitespace = .indent_4 }, wr);
        //New sign nbt in 1.21.3
        //back_text{
        //  has_glowing_text, 0
        //  color, "black"
        //  messages [""]4
        //
        //}
        //front_text{} same as above
        //is_waxed: 0
        if (self.tag_table.hasTag(b.id, "minecraft:block", "minecraft:signs")) {
            var has_text = false;
            if (nbt == .compound) {
                const fields = [_][]const u8{ "front_text", "back_text" };
                for (fields) |f| {
                    if (nbt.compound.get(f)) |bt| {
                        if (bt == .compound) {
                            const e = bt.compound.get("messages").?.list.entries.items[0];
                            has_text = true;
                            if (e.string.len <= 2) return;
                            const jv = std.json.parseFromSlice(std.json.Value, aa, e.string, .{}) catch {
                                log.err("Json crashed while parsing sign text", .{});
                                return;
                            };
                            switch (jv.value) {
                                else => {
                                    log.warn("invalid sign text", .{});
                                    return;
                                },
                                .object => {
                                    log.warn("Omitting sign with json", .{});
                                    return;
                                },
                                .string => |s| {
                                    const t = s;
                                    if (self.reg.getBlockState(id, "facing")) |facing| {
                                        const fac = std.meta.stringToEnum(Reg.Direction, facing.enum_) orelse return;
                                        const dvec = fac.reverse().toVec();
                                        const behind = coord.add(dvec);
                                        if (dim.chunk_data.getBlock(behind)) |bid| {
                                            const bi = self.reg.getBlockFromState(bid);
                                            if (std.mem.eql(u8, "chest", bi.name)) {
                                                const name = try std.mem.concat(aa, u8, &.{ t, "_chest" });
                                                try self.putSignWaypoint(dim_id, name, .{ .pos = behind, .facing = fac });
                                            } else if (std.mem.eql(u8, "dropper", bi.name)) {
                                                const name = try std.mem.concat(aa, u8, &.{ t, "_dropper" });
                                                try self.putSignWaypoint(dim_id, name, .{ .pos = behind, .facing = fac });
                                            } else if (std.mem.eql(u8, "crafting_table", bi.name)) {
                                                const name = try std.mem.concat(aa, u8, &.{ t, "_craft" });
                                                try self.putSignWaypoint(dim_id, name, .{ .pos = behind, .facing = fac });
                                            }
                                        }
                                        try self.putSignWaypoint(dim_id, t, .{ .pos = coord, .facing = fac });
                                    } else {
                                        try self.putSignWaypoint(dim_id, t, .{ .pos = coord, .facing = .north });
                                    }
                                },
                            }
                        }
                    }
                }
            }
            if (!has_text)
                log.warn("sign without text {any}", .{coord});
        } else {
            if (std.mem.eql(u8, "chest", b.name)) {}
        }
    }
};
