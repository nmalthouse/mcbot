const std = @import("std");
const ProtoGen = @import("protocol_gen.zig");
const vector = @import("vector.zig");
const com = @import("common.zig");
const J = std.json;

pub const ItemCatJson = struct {
    pub const JFuzzyItem = union(enum) {
        startsWith: []const u8,
        endsWith: []const u8,
    };
    fuzzy: J.ArrayHashMap([]const JFuzzyItem),
    exact_name: J.ArrayHashMap([]const []const u8),
};

//Support Key F: full, P: partial
// [ ] biomes.json
// [ ] blockLoot.json
// [p] effects.json
// [ ] language.json
// [ ] enchantments.json
// [ ] instruments.json
// [ ] particles.json
// [ ] tints.json

// [P] entities.json
// [ ] blockCollisionShapes.json
// [ ] entityLoot.json
// [p] recipes.json
// [P] foods.json
// [F] items.json
// [F] materials.json
// [P] protocol.json
// [F] version.json
// [f] blocks.json

pub const Recipe = struct {
    inShape: ?[][]?ItemId = null, //if set, shaped
    ingredients: ?[]ItemId = null, //if set,  Shapeless
    result: struct {
        count: u8,
        id: ItemId,
    },
};

pub const RecipeJson = std.json.ArrayHashMap([]Recipe);

pub const RecipeMap = std.AutoHashMap(ItemId, []Recipe);

pub const Food = struct {
    id: ItemId,
    foodPoints: f32,
};

pub const FoodJson = []const Food;

pub const Effect = struct {
    id: u8,
    name: []const u8,
    type: enum { good, bad },
};
pub const EffectJson = []const Effect;

pub const Direction = enum {
    north,
    south,
    west,
    east,

    pub fn reverse(self: Direction) Direction {
        return switch (self) {
            .north => .south,
            .south => .north,
            .east => .west,
            .west => .east,
        };
    }

    pub fn toVec(self: Direction) vector.V3i {
        return switch (self) {
            .north => vector.V3i.new(0, 0, -1),
            .south => vector.V3i.new(0, 0, 1),
            .east => vector.V3i.new(1, 0, 0),
            .west => vector.V3i.new(-1, 0, 0),
        };
    }
};
pub const ItemId = u16;
pub const EntId = u8;
pub const BlockId = u16; //TODO block id can be made much smaller
pub const StateId = u16;

const VersionJson = struct {
    minecraftVersion: []const u8,
    version: i32,
    majorVersion: []const u8,
};

pub const MaterialsJson = J.ArrayHashMap(J.ArrayHashMap(f32));

pub const Materials = struct {
    pub const SetItem = struct {
        id: ItemId,
        mul: f32,
    };
    pub const Set = []const SetItem;

    map: std.StringHashMap(Set),
    alloc: std.mem.Allocator,

    pub fn initFromJson(alloc: std.mem.Allocator, j: MaterialsJson) !@This() {
        var nmap = std.StringHashMap(Set).init(alloc);
        var m_it = j.map.iterator();
        while (m_it.next()) |kv| {
            var s_it = kv.value_ptr.map.iterator();
            const new_set = try alloc.alloc(SetItem, kv.value_ptr.map.count());
            var i: usize = 0;
            while (s_it.next()) |si| {
                defer i += 1;
                //convert string to number
                new_set[i] = .{
                    .id = try std.fmt.parseInt(ItemId, si.key_ptr.*, 10),
                    .mul = si.value_ptr.*,
                };
            }
            try nmap.put(try alloc.dupe(u8, kv.key_ptr.*), new_set);
        }

        return @This(){
            .map = nmap,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *@This()) void {
        var m_it = self.map.iterator();
        while (m_it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.map.deinit();
    }
};

pub const Item = struct {
    id: ItemId,
    name: []const u8,
    stackSize: u8,

    fn asc(ctx: void, lhs: @This(), rhs: @This()) bool {
        _ = ctx;
        return lhs.id < rhs.id;
    }
    //displayName: []const u8,
};
pub const ItemsJson = []const Item;

pub const Entity = struct {
    id: u8,
    internalId: u8,
    name: []const u8,
    width: f32,
    height: f32,
    type: []const u8,

    fn compareIds(ctx: u8, key: Entity, actual: Entity) std.math.Order {
        _ = ctx;
        if (key.id == actual.id) return .eq;
        if (key.id > actual.id) return .gt;
        if (key.id < actual.id) return .lt;
        return .eq;
    }

    fn asc(ctx: void, lhs: @This(), rhs: @This()) bool {
        _ = ctx;
        return lhs.id < rhs.id;
    }
};
pub const EntitiesJson = []const Entity;

//Used for parsing blocks.json, transferd into block later
pub const JsonBlock = struct {
    id: BlockId,
    name: []const u8,
    hardness: ?f32,
    resistance: f32,
    minStateId: StateId,
    maxStateId: StateId,
    stackSize: u8,
    defaultState: StateId,
    boundingBox: Block.BoundingBox,
    material: []const u8,
    diggable: bool,
    transparent: bool,

    states: []Block.State.JsonDummyState,
};

pub const Block = struct {
    pub const BoundingBox = enum(u8) {
        empty,
        block,
    };

    pub const State = struct {
        pub const JsonDummyState = struct {
            name: []const u8,
            type: []const u8,
            num_values: u8,
            values: ?[]const []const u8 = null,
        };
        pub const Context = struct {
            pub fn eql(_: @This(), a: State, b: State) bool {
                const ne = std.mem.eql(u8, a.name, b.name);
                if (!ne)
                    return false;
                switch (a.type) {
                    .int => {
                        if (b.type == .int) {
                            return (b.type.int.min == a.type.int.min and b.type.int.max == a.type.int.max);
                        }
                        return false;
                    },
                    .boolean => {
                        return (b.type == .boolean);
                    },
                    .enum_ => {
                        if (b.type != .enum_)
                            return false;
                        if (a.type.enum_.len != b.type.enum_.len)
                            return false;
                        for (a.type.enum_, 0..) |av, i| {
                            if (!std.mem.eql(u8, av, b.type.enum_[i]))
                                return false;
                        }

                        return true;
                    },
                }
            }
            pub fn hash(_: @This(), key: State) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
                return hasher.final();
            }
        };

        pub const Value = union(enum) {
            boolean: bool,
            int: u8,
            enum_: []const u8,
        };

        pub const KV = struct {
            key: []const u8,
            val: Value,
        };

        pub fn numValues(self: @This()) usize {
            return switch (self.type) {
                .boolean => 2,
                .int => |i| i.max - i.min + 1,
                .enum_ => |e| e.len,
            };
        }

        name: []const u8,
        type: union(enum) {
            boolean: void,
            int: struct {
                min: u8,
                max: u8,
            },
            enum_: []const []const u8,
        },
    };

    id: BlockId,
    name: []const u8,
    hardness: ?f32,
    resistance: f32,
    minStateId: StateId,
    maxStateId: StateId,
    stackSize: u8,
    defaultState: StateId,
    boundingBox: BoundingBox,
    material: []const u8,
    diggable: bool,
    transparent: bool,

    states: []usize, //Indices into reg,state_list

    //filterLight: u8, not relevent
    fn compareStateIds(ctx: u8, key: Block, actual: Block) std.math.Order {
        _ = ctx;
        if (key.minStateId >= actual.minStateId and key.minStateId <= actual.maxStateId) return .eq;
        if (key.minStateId > actual.maxStateId) return .gt;
        if (key.minStateId < actual.minStateId) return .lt;
        return .eq;
    }

    fn asc(ctx: void, lhs: @This(), rhs: @This()) bool {
        _ = ctx;
        return lhs.id < rhs.id;
    }

    pub fn getState(self: @This(), state_list: []const State, stateid: StateId, state_tag: []const u8) ?State.Value {
        //Formula for n states [a,b,c,d,e]
        //
        // to find what state d is:
        // ( id /(a * b * c) ) % d
        var divisor: usize = 1;
        var i = self.states.len;
        while (i > 0) : (i -= 1) {
            const state = state_list[self.states[i - 1]];
            const nv = state.numValues();
            defer divisor *= nv;
            if (std.mem.eql(u8, state.name, state_tag)) {
                const local_id = @divFloor(stateid - self.minStateId, divisor) % nv;
                return switch (state.type) {
                    .boolean => .{ .boolean = local_id == 0 },
                    .int => .{ .int = @intCast(local_id) },
                    .enum_ => .{ .enum_ = state.type.enum_[local_id] },
                };
            }
        }
        return null;
    }
};
pub const BlocksJson = []Block;

pub const DataReg = struct {
    const Self = @This();
    pub const ItemCategories = struct {
        alloc: std.mem.Allocator,
        map: std.AutoHashMap(ItemId, u16),
        categories: std.ArrayList([]const u8),
        string_tracker: std.StringHashMap(usize),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .map = std.AutoHashMap(ItemId, u16).init(alloc),
                .alloc = alloc,
                .string_tracker = std.StringHashMap(usize).init(alloc),
                .categories = std.ArrayList([]const u8).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.map.deinit();
            self.string_tracker.deinit();
            for (self.categories.items) |item| {
                self.alloc.free(item);
            }
            self.categories.deinit();
        }
    };

    string_storage: std.StringHashMap(u32),
    strings: std.ArrayList([]const u8),
    statelist: std.ArrayList(Block.State),

    alloc: std.mem.Allocator,
    item_categories: ItemCategories,
    version_id: i32,
    block_name_map: std.StringHashMap(BlockId),
    item_name_map: std.StringHashMap(u16), //Maps item names to indices into items[].
    items: []Item,
    foods: []Food,
    blocks: []Block,
    entities: EntitiesJson,
    materials: Materials,
    recipes: RecipeJson,
    rec_map: RecipeMap,

    empty_block_ids: std.ArrayList(BlockId),

    ent_j: std.json.Parsed(EntitiesJson),
    rec_j: std.json.Parsed(RecipeJson),

    pub fn init(alloc: std.mem.Allocator, comptime version: []const u8) !Self {
        const data_paths = try com.readJson(std.fs.cwd(), "minecraft-data/data/dataPaths.json", alloc, struct {
            pc: std.json.ArrayHashMap(std.json.ArrayHashMap([]const u8)),
        });
        defer data_paths.deinit();
        const version_map = data_paths.value.pc.map.get(version) orelse return error.invalidVersion;

        var version_info = try com.readJson(try ProtoGen.getDir(&version_map, "version"), "version.json", alloc, VersionJson);
        defer version_info.deinit();
        var string_storage = std.StringHashMap(u32).init(alloc);
        var strings = std.ArrayList([]const u8).init(alloc);

        const jitems = try com.readJson(try ProtoGen.getDir(&version_map, "items"), "items.json", alloc, ItemsJson);
        defer jitems.deinit();
        var item_map = std.StringHashMap(u16).init(alloc);
        var items = try alloc.alloc(Item, jitems.value.len);
        for (jitems.value, 0..) |item, i| {
            items[i] = item;
            items[i].name = try dupeString(alloc, &string_storage, &strings, item.name);
        }
        std.sort.heap(Item, items, {}, Item.asc);
        for (items, 0..) |item, i| {
            try item_map.put(item.name, @intCast(i));
        }

        const block = try com.readJson(try ProtoGen.getDir(&version_map, "blocks"), "blocks.json", alloc, []JsonBlock);

        const ent = try com.readJson(try ProtoGen.getDir(&version_map, "entities"), "entities.json", alloc, EntitiesJson);
        const mat = try com.readJson(try ProtoGen.getDir(&version_map, "materials"), "materials.json", alloc, MaterialsJson);
        defer mat.deinit();

        const rec = try com.readJson(try ProtoGen.getDir(&version_map, "recipes"), "recipes.json", alloc, RecipeJson);
        var rec_map = RecipeMap.init(alloc);
        {
            var it = rec.value.map.iterator();
            while (it.next()) |item| {
                //Don't realloc just keep contents owned by json rec
                try rec_map.put(try std.fmt.parseInt(ItemId, item.key_ptr.*, 10), item.value_ptr.*);
            }
        }

        const blocks = try alloc.alloc(Block, block.value.len);

        var empty = std.ArrayList(BlockId).init(alloc);
        const h = std.hash.Wyhash.hash;
        var statetable = std.HashMap(Block.State, usize, Block.State.Context, std.hash_map.default_max_load_percentage).init(alloc);
        var statelist = std.ArrayList(Block.State).init(alloc);
        defer statetable.deinit();
        for (block.value, 0..) |b, i| {
            if (b.boundingBox == .empty)
                try empty.append(b.id);

            const state_list = try alloc.alloc(usize, b.states.len);
            for (b.states, 0..) |st, si| {
                const trystate = Block.State{
                    .name = st.name,
                    .type = switch (h(0, st.type)) {
                        h(0, "int") => .{ .int = .{ .min = try std.fmt.parseInt(u8, st.values.?[0], 10), .max = try std.fmt.parseInt(u8, st.values.?[st.num_values - 1], 10) } },
                        h(0, "bool") => .{ .boolean = {} },
                        h(0, "enum") => .{ .enum_ = st.values.? },
                        else => unreachable,
                    },
                };
                if (statetable.get(trystate)) |ost| {
                    state_list[si] = ost;
                } else {
                    const duped_state = Block.State{
                        .name = try dupeString(alloc, &string_storage, &strings, trystate.name),
                        .type = switch (trystate.type) {
                            .int => trystate.type,
                            .boolean => trystate.type,
                            .enum_ => |e| blk: {
                                var list = try alloc.alloc([]const u8, e.len);
                                for (e, 0..) |it, ssi|
                                    list[ssi] = try dupeString(alloc, &string_storage, &strings, it);
                                break :blk .{ .enum_ = list };
                            },
                        },
                    };
                    const index = statelist.items.len;
                    try statelist.append(duped_state);
                    try statetable.put(duped_state, index);
                    state_list[si] = index;
                }
            }

            blocks[i] = .{
                .name = try dupeString(alloc, &string_storage, &strings, b.name),
                .material = try dupeString(alloc, &string_storage, &strings, b.material),
                .id = b.id,
                .hardness = b.hardness,
                .resistance = b.resistance,
                .minStateId = b.minStateId,
                .maxStateId = b.maxStateId,
                .stackSize = b.stackSize,
                .defaultState = b.defaultState,
                .boundingBox = b.boundingBox,
                .diggable = b.diggable,
                .transparent = b.transparent,
                .states = state_list,
            };
        }
        std.sort.heap(BlockId, empty.items, {}, std.sort.asc(BlockId));
        std.sort.heap(Block, blocks, {}, Block.asc);
        block.deinit();

        var block_map = std.StringHashMap(BlockId).init(alloc);
        for (blocks, 0..) |bl, i| {
            try block_map.put(bl.name, @intCast(i));
        }

        const foodj = try com.readJson(try ProtoGen.getDir(&version_map, "foods"), "foods.json", alloc, FoodJson);
        defer foodj.deinit();
        const foods = try alloc.alloc(Food, foodj.value.len);
        for (foodj.value, 0..) |f, i| {
            foods[i] = f;
        }

        const ret = Self{
            .rec_map = rec_map,
            .recipes = rec.value,
            .version_id = version_info.value.version,
            .item_categories = ItemCategories.init(alloc),
            .alloc = alloc,
            .entities = ent.value,
            .foods = foods,
            .item_name_map = item_map,
            .block_name_map = block_map,
            .items = items,
            .blocks = blocks,
            .materials = try Materials.initFromJson(alloc, mat.value),
            .empty_block_ids = empty,
            .string_storage = string_storage,
            .strings = strings,
            .statelist = statelist,

            .ent_j = ent,
            .rec_j = rec,
        };
        return ret;
    }

    pub fn dupeString(alloc: std.mem.Allocator, map: *std.StringHashMap(u32), strings: *std.ArrayList([]const u8), string: []const u8) ![]const u8 {
        if (map.getEntry(string)) |e| {
            e.value_ptr.* += 1;
            return e.key_ptr.*;
        }

        const str = try alloc.dupe(u8, string);
        try strings.append(str);
        try map.put(str, 0);
        return str;
    }

    pub fn addUserItemCategories(self: *Self, dir: std.fs.Dir, path: []const u8) !void {
        var json = try com.readJson(dir, path, self.alloc, ItemCatJson);
        defer json.deinit();
        const cat = &self.item_categories;
        {
            var it = json.value.exact_name.map.iterator();
            while (it.next()) |n| {
                const r = try cat.string_tracker.getOrPut(n.key_ptr.*);
                if (r.found_existing) continue;
                r.key_ptr.* = n.key_ptr.*;
            }
        }
        {
            var it = json.value.fuzzy.map.iterator();
            while (it.next()) |n| {
                const r = try cat.string_tracker.getOrPut(n.key_ptr.*);
                if (r.found_existing) continue;
                r.key_ptr.* = n.key_ptr.*;
            }
        }
        {
            var it = cat.string_tracker.iterator();
            while (it.next()) |n| {
                n.value_ptr.* = cat.categories.items.len;
                try cat.categories.append(try self.alloc.dupe(u8, n.key_ptr.*));
                n.key_ptr.* = cat.categories.items[n.value_ptr.*];
            }
        }
        {
            var it = json.value.exact_name.map.iterator();
            while (it.next()) |n| {
                const index = cat.string_tracker.get(n.key_ptr.*) orelse continue;
                for (n.value_ptr.*) |item_name| {
                    const item = self.getItemFromName(item_name) orelse continue;
                    try cat.map.put(item.id, @intCast(index));
                }
            }
        }
        {
            var it = json.value.fuzzy.map.iterator();
            while (it.next()) |n| {
                const index = cat.string_tracker.get(n.key_ptr.*) orelse continue;
                for (n.value_ptr.*) |match_type| {
                    for (self.items) |item| {
                        const is_match = switch (match_type) {
                            .startsWith => |s| std.mem.startsWith(u8, item.name, s),
                            .endsWith => |s| std.mem.endsWith(u8, item.name, s),
                        };
                        if (is_match) {
                            try cat.map.put(item.id, @intCast(index));
                            continue;
                        }
                    }
                }
            }
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.statelist.items) |state| {
            if (state.type == .enum_)
                self.alloc.free(state.type.enum_);
        }
        self.statelist.deinit();
        for (self.strings.items) |item| {
            self.alloc.free(item);
        }
        self.string_storage.deinit();
        self.strings.deinit();
        self.rec_map.deinit();
        self.item_categories.deinit();
        for (self.blocks) |b| {
            self.alloc.free(b.states);
        }
        self.alloc.free(self.blocks);
        self.alloc.free(self.items);
        self.item_name_map.deinit();
        self.block_name_map.deinit();
        self.materials.deinit();
        self.empty_block_ids.deinit();
        self.ent_j.deinit();
        self.alloc.free(self.foods);
        self.rec_j.deinit();
    }

    pub fn getBlockState(self: *const Self, stateid: StateId, tag: []const u8) ?Block.State.Value {
        const b = self.getBlockFromState(stateid);
        return b.getState(self.statelist.items, stateid, tag);
    }

    pub fn getBlockStates(self: *const Self, stateid: StateId, buf: []Block.State.KV) []Block.State.KV {
        const b = self.getBlockFromState(stateid);

        var count: usize = 0;
        for (b.states) |si| {
            defer count += 1;
            if (count >= buf.len)
                return buf[0..count];
            const st = self.statelist.items[si];
            buf[count] = .{ .key = st.name, .val = b.getState(self.statelist.items, stateid, st.name) orelse .{ .enum_ = "" } };
        }
        return buf[0..count];
    }

    pub fn getBlockSlice(self: *const Self) []const Block {
        return self.blocks;
    }

    pub fn getMaterial(self: *const Self, material: []const u8) ?Materials.Set {
        return self.materials.map.get(material);
    }

    fn blockIdOrder(ctx: void, lhs: BlockId, rhs: BlockId) std.math.Order {
        _ = ctx;
        return std.math.order(lhs, rhs);
    }

    pub fn isBlockCollidable(self: *const Self, bid: BlockId) bool {
        return std.sort.binarySearch(BlockId, bid, self.empty_block_ids.items, {}, blockIdOrder) == null;
    }

    pub fn getBlockFromState(self: *const Self, state_id: StateId) Block {
        var block: Block = undefined;
        block.minStateId = state_id;
        block.maxStateId = 0;

        const index = std.sort.binarySearch(Block, block, self.blocks, @as(u8, 0), Block.compareStateIds) orelse unreachable;
        return self.blocks[index];
    }

    pub fn getEntity(self: *const Self, ent_id: EntId) ?Entity {
        for (self.entities) |ent| {
            if (ent.id == ent_id)
                return ent;
        }
        //const index = std.sort.binarySearch(Entity, ent, self.entities, @as(u8, 0), Entity.compareIds) orelse unreachable;
        return null;
    }

    pub fn getItem(self: *const Self, id: ItemId) Item {
        return self.items[id];
    }

    pub fn getItemFromName(self: *const Self, name: []const u8) ?Item {
        if (self.item_name_map.get(name)) |item_index| {
            return self.items[item_index];
        }
        return null;
    }

    pub fn getBlock(self: *const Self, id: BlockId) Block {
        return self.blocks[id];
    }

    pub fn getBlockFromNameI(self: *const Self, name: []const u8) ?Block {
        if (self.block_name_map.get(name)) |index| {
            return self.blocks[index];
        }
        return null;
    }

    pub fn getBlockFromName(self: *const Self, name: []const u8) ?BlockId {
        if (self.block_name_map.get(name)) |index| {
            return self.blocks[index].id;
        }
        return null;
    }

    pub fn getBlockIdFromState(self: *const Self, state_id: StateId) BlockId {
        return self.getBlockFromState(state_id).id;
    }
};

//Break time in ticks
pub fn calculateBreakTime(tool_multiplier: f32, block_hardness: f32, params: struct {
    best_tool: bool = true,
    adequate_tool_level: bool = true,
    efficiency_level: f32 = 0,
    haste_level: i64 = 0,
    mining_fatigue: f32 = 0,
    in_water: bool = false,
    has_aqua_affinity: bool = false,
    on_ground: bool = true,
}) u32 {
    const haste: f32 = @floatFromInt(params.haste_level);
    var s: f32 = 1;
    if (params.best_tool) {
        s = tool_multiplier;
        if (!params.adequate_tool_level) {
            s = 1;
        } else if (params.efficiency_level > 0) {
            s += std.math.pow(f32, params.efficiency_level, 2) + 1;
        }
    }

    if (params.haste_level > 0)
        s *= 0.2 * haste + 1;

    if (params.mining_fatigue > 0)
        s *= std.math.pow(f32, 0.3, @min(params.mining_fatigue, 4));

    if (params.in_water and !params.has_aqua_affinity)
        s /= 5;
    if (!params.on_ground)
        s /= 5;

    var damage: f32 = s / block_hardness;
    damage /= if (params.adequate_tool_level) 30 else 100;

    if (damage > 1) //instant mine
        return 0;

    return @intFromFloat(@round(1 / damage));
}

test "block break time" {
    const eql = std.testing.expectEqual;

    const ticks = calculateBreakTime(2, 22.5, .{});
    try eql(ticks, 338);
}
