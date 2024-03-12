const std = @import("std");
const vector = @import("vector.zig");
const com = @import("common.zig");
const J = std.json;

//Support Key F: full, P: partial
// [ ] biomes.json
// [ ] blockLoot.json
// [ ] effects.json
// [ ] language.json
// [ ] enchantments.json
// [ ] instruments.json
// [ ] particles.json
// [ ] tints.json

// [P] entities.json
// [ ] blockCollisionShapes.json
// [ ] entityLoot.json
// [ ] recipes.json
// [P] foods.json
// [F] items.json
// [F] materials.json
// [ ] protocol.json
// [F] version.json
// [P] blocks.json

pub const Recipe = struct {
    inShape: ?[][]?ItemId = null,
    ingredients: ?[]ItemId = null,
    result: struct {
        count: u8,
        id: ItemId,
    },
};

pub const RecipeJson = std.json.ArrayHashMap([]Recipe);

pub const Food = struct {
    id: ItemId,
    foodPoints: f32,
};

pub const FoodJson = []const Food;

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
    version: u32,
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

//TODO get materials to work, currently causes memory leak with default json.parse
pub const Block = struct {
    pub const BoundingBox = enum(u8) {
        empty,
        block,
    };
    pub const Material = enum(u8) {
        default,
        @"mineable/pickaxe",
        @"mineable/shovel",
        @"mineable/axe",
        @"plant;mineable/axe",
        plant,
        UNKNOWN_MATERIAL,
        @"leaves;mineable/hoe",
        @"mineable/hoe",
        cobweb,
        wool,
        @"gourd;mineable/axe",
        @"vine_or_glow_lichen;plant;mineable/axe",
    };

    pub const State = struct {
        pub const SubState = union(enum) {
            unimplemented: u8,
            age: u8,
            facing: Direction,
            half: enum { top, bottom },
            shape: enum { straight, inner_left, inner_right, outer_left, outer_right },
            waterlogged: bool,
        };
        pub const SubStateTag = @typeInfo(SubState).Union.tag_type.?;

        num_values: u8,
        sub: SubState,

        pub const JsonDummyState = struct {
            name: []const u8,
            type: []const u8,
            num_values: u8,
            values: ?[]const []const u8 = null,
        };

        pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const eql = std.mem.eql;
            const dummy = try std.json.innerParse(JsonDummyState, alloc, source, options);
            const info = @typeInfo(SubState);
            var ret: State = .{ .num_values = dummy.num_values, .sub = .{ .unimplemented = 0 } };
            inline for (info.Union.fields) |f| {
                if (eql(u8, f.name, dummy.name)) {
                    const finfo = @typeInfo(f.type);
                    ret.sub = @unionInit(SubState, f.name, switch (finfo) {
                        .Int => 0,
                        .Enum => @enumFromInt(0),
                        .Void => {},
                        .Bool => false,
                        else => @compileError("not supported"),
                    });
                    return ret;
                }
            }
            return ret;
        }

        pub fn initWithInt(num_values: u8, sub: SubStateTag, val: usize) @This() {
            const info = @typeInfo(SubState);
            inline for (info.Union.fields, 0..) |f, i| {
                if (i == @intFromEnum(sub)) {
                    const T = f.type;
                    const finfo = @typeInfo(T);
                    return .{
                        .num_values = num_values,
                        .sub = @unionInit(SubState, f.name, switch (finfo) {
                            .Int => @intCast(val),
                            .Enum => @enumFromInt(val),
                            .Void => {},
                            .Bool => val == 0, //bools are reversed in minecraft data
                            else => @compileError("not supported"),
                        }),
                    };
                }
            }
            unreachable;
        }
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
    //material: ?Material,
    diggable: bool,
    transparent: bool,

    states: []State,

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

    pub fn getState(self: @This(), stateid: StateId, sub: Block.State.SubStateTag) ?State {

        //Formula for n states [a,b,c,d,e]
        //
        // to find what state d is:
        // ( id /(a * b * c) ) % d

        var divisor: usize = 1;
        var i = self.states.len;
        while (i > 0) : (i -= 1) {
            const state = self.states[i - 1];
            defer divisor *= state.num_values;
            if (state.sub == sub) {
                const local_id = @divFloor(stateid - self.minStateId, divisor) % state.num_values;
                return Block.State.initWithInt(state.num_values, sub, local_id);
            }
        }

        return null;
    }

    pub fn getAllStates(self: *const @This(), stateid: StateId, buf: []State) ?[]State {
        var count: usize = 0;
        for (self.states) |state| {
            defer count += 1;
            if (count >= buf.len)
                return buf[0..count];
            buf[count] = self.getState(stateid, state.sub) orelse return null;
        }
        return buf[0..count];
    }
};
pub const BlocksJson = []Block;

pub const DataReg = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    version_id: u32,
    item_name_map: std.StringHashMap(u16), //Maps item names to indices into items[]. name strings are stored in items[]
    items: []Item,
    foods: []Food,
    blocks: []Block,
    entities: EntitiesJson,
    materials: Materials,
    recipes: RecipeJson,

    empty_block_ids: std.ArrayList(BlockId),

    ent_j: std.json.Parsed(EntitiesJson),
    rec_j: std.json.Parsed(RecipeJson),

    pub fn init(alloc: std.mem.Allocator, comptime version: []const u8) !Self {
        var cwd = std.fs.cwd();
        var data_dir = try cwd.openDir("minecraft-data/data/pc/" ++ version, .{});
        defer data_dir.close();

        var version_info = try com.readJson(data_dir, "version.json", alloc, VersionJson);
        defer version_info.deinit();

        const jitems = try com.readJson(data_dir, "items.json", alloc, ItemsJson);
        defer jitems.deinit();
        var item_map = std.StringHashMap(u16).init(alloc);
        var items = try alloc.alloc(Item, jitems.value.len);
        for (jitems.value, 0..) |item, i| {
            items[i] = item;
            items[i].name = try alloc.dupe(u8, item.name);
        }
        std.sort.heap(Item, items, {}, Item.asc);
        for (items, 0..) |item, i| {
            try item_map.put(item.name, @intCast(i));
        }

        const ent = try com.readJson(data_dir, "entities.json", alloc, EntitiesJson);
        const block = try com.readJson(data_dir, "blocks.json", alloc, BlocksJson);
        const mat = try com.readJson(data_dir, "materials.json", alloc, MaterialsJson);
        defer mat.deinit();

        const rec = try com.readJson(data_dir, "recipes.json", alloc, RecipeJson);

        const blocks = try alloc.alloc(Block, block.value.len);

        var empty = std.ArrayList(BlockId).init(alloc);
        for (block.value, 0..) |b, i| {
            if (b.boundingBox == .empty)
                try empty.append(b.id);
            blocks[i] = b;
            blocks[i].name = try alloc.dupe(u8, b.name);
            blocks[i].material = try alloc.dupe(u8, b.material);
            blocks[i].states = try alloc.dupe(Block.State, b.states);
        }
        std.sort.heap(BlockId, empty.items, {}, std.sort.asc(BlockId));
        std.sort.heap(Block, blocks, {}, Block.asc);
        block.deinit();

        const foodj = try com.readJson(data_dir, "foods.json", alloc, FoodJson);
        defer foodj.deinit();
        const foods = try alloc.alloc(Food, foodj.value.len);
        for (foodj.value, 0..) |f, i| {
            foods[i] = f;
        }
        //std.sort.heap(Entity, ent.value, {}, Entity.asc);

        const ret = Self{
            .recipes = rec.value,
            .version_id = version_info.value.version,
            .alloc = alloc,
            .entities = ent.value,
            .foods = foods,
            .item_name_map = item_map,
            .items = items,
            .blocks = blocks,
            .materials = try Materials.initFromJson(alloc, mat.value),
            .empty_block_ids = empty,

            .ent_j = ent,
            .rec_j = rec,
        };
        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.blocks) |b| {
            self.alloc.free(b.name);
            self.alloc.free(b.states);
            self.alloc.free(b.material);
        }
        self.alloc.free(self.blocks);
        for (self.items) |item| {
            self.alloc.free(item.name);
        }
        self.alloc.free(self.items);
        self.item_name_map.deinit();
        self.materials.deinit();
        self.empty_block_ids.deinit();
        self.ent_j.deinit();
        self.alloc.free(self.foods);
        self.rec_j.deinit();
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
        for (self.blocks) |block| {
            if (std.mem.eql(u8, block.name, name)) {
                return block;
            }
        }
        return null;
    }

    pub fn getBlockFromName(self: *const Self, name: []const u8) ?BlockId {
        for (self.blocks) |block| {
            if (std.mem.eql(u8, block.name, name)) {
                return block.id;
            }
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
    haste_level: f32 = 0,
    mining_fatigue: f32 = 0,
    in_water: bool = false,
    has_aqua_affinity: bool = false,
    on_ground: bool = true,
}) u32 {
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
        s *= 0.2 * params.haste_level + 1;

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
