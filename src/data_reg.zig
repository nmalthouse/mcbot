const std = @import("std");
const com = @import("common.zig");

//Parsing protocol.json to generate required code
//At comptime json.parse protocol.json
//Generate enums for the different states and clientBound serverBound
//These enum values are used as packet ids
//
//Ideally generate parsing code for each packet
//Only allocate when required for strings etc. Use an arena allocator
//Allow early discard of packets
//
//At runtime in our packet parsing function
//Don't do all that just use python and jinja to generate code!

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
// [ ] foods.json
// [P] items.json
// [ ] materials.json
// [ ] protocol.json
// [F] version.json
// [P] blocks.json

pub const ItemId = u16;
pub const BlockId = u16; //TODO block id can be made much smaller
pub const StateId = u16;

const VersionJson = struct {
    minecraftVersion: []const u8,
    version: u32,
    majorVersion: []const u8,
};

pub const ItemsJson = []const struct {
    id: ItemId,
    name: []const u8,
    stackSize: u8,
    //displayName: []const u8,
};

pub const EntitiesJson = []const struct {
    id: u8,
    internalId: u8,
    name: []const u8,
    width: f32,
    height: f32,
    type: []const u8,
};

//TODO get materials to work, currently causes memory leak with default json.parse
pub const BlocksJson = []const struct {
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

    id: BlockId,
    name: []const u8,
    hardness: ?f32,
    resistance: f32,
    minStateId: StateId,
    maxStateId: StateId,
    stackSize: u8,
    defaultState: StateId,
    boundingBox: BoundingBox,
    //material: ?Material,
    diggable: bool,
    transparent: bool,

    //filterLight: u8, not relevent
};

pub const NewDataReg = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    version_id: u32,
    items: ItemsJson,
    blocks: BlocksJson,
    entities: EntitiesJson,

    item_j: std.json.Parsed(ItemsJson),
    block_j: std.json.Parsed(BlocksJson),
    ent_j: std.json.Parsed(EntitiesJson),

    pub fn init(alloc: std.mem.Allocator, comptime version: []const u8) !Self {
        var cwd = std.fs.cwd();
        var data_dir = try cwd.openDir("minecraft-data/data/pc/" ++ version, .{});
        defer data_dir.close();

        var version_info = try com.readJson(data_dir, "version.json", alloc, VersionJson);
        defer version_info.deinit();

        const items = try com.readJson(data_dir, "items.json", alloc, ItemsJson);
        const ent = try com.readJson(data_dir, "entities.json", alloc, EntitiesJson);
        const block = try com.readJson(data_dir, "blocks.json", alloc, BlocksJson);

        const ret = Self{
            .version_id = version_info.value.version,
            .alloc = alloc,
            .items = items.value,
            .entities = ent.value,
            .blocks = block.value,

            .item_j = items,
            .block_j = block,
            .ent_j = ent,
        };
        return ret;
    }

    //TODO ugly, we do this

    pub fn deinit(self: *const Self) void {
        self.item_j.deinit();
        self.block_j.deinit();
        self.ent_j.deinit();
    }
};

//TODO
//should we remove the old datareg in favor of NEW. why do two even exist
pub const DataRegContainer = struct {
    reg: DataReg,
    data_j: std.json.Parsed(DataReg),

    pub fn init(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !@This() {
        const j = try com.readJson(dir, filename, alloc, DataReg);
        return .{ .reg = j.value, .data_j = j };
    }

    pub fn deinit(self: *@This()) void {
        self.data_j.deinit();
    }
};

//This structure should contain all data related to minecraft required for our bot
pub const DataReg = struct {
    const Self = @This();

    pub const Material = struct {
        pub const Tool = struct {
            item_id: ItemId,
            multiplier: f32,
        };

        name: []const u8,
        tools: []const Tool,
    };

    pub const Item = struct {
        id: ItemId,
        name: []const u8,
        stack_size: u8,
    };

    pub const Block = struct {
        id: BlockId,
        name: []const u8,
        hardness: f32,
        resistance: f32,
        stack_size: u8,
        diggable: bool,
        material_i: u8,
        transparent: bool,
        default_state: BlockId,
        min_state: BlockId,
        max_state: BlockId,
        drops: []const ItemId,
        //TODO handle block states

        fn compareStateIds(ctx: u8, key: Block, actual: Block) std.math.Order {
            _ = ctx;
            if (key.min_state >= actual.min_state and key.min_state <= actual.max_state) return .eq;
            if (key.min_state > actual.max_state) return .gt;
            if (key.min_state < actual.min_state) return .lt;
            return .eq;
        }
    };

    //alloc: std.mem.Allocator,

    blocks: []const Block, //Block information indexed by block id
    materials: []const Material, //indexed by material id
    items: []const Item,

    pub fn getItem(self: *const Self, id: ItemId) Item {
        return self.items[id];
    }

    pub fn getBlock(self: *const Self, id: BlockId) Block {
        return self.blocks[id];
    }

    pub fn getBlockFromName(self: *const Self, name: []const u8) ?BlockId {
        for (self.blocks) |block| {
            if (std.mem.eql(u8, block.name, name)) {
                return block.id;
            }
        }
        return null;
    }

    pub fn getBlockIdFromState(self: *const Self, state_id: BlockId) BlockId {
        var block: Block = undefined;
        block.min_state = state_id;
        block.max_state = 0;

        const index = std.sort.binarySearch(Block, block, self.blocks, @as(u8, 0), Block.compareStateIds) orelse unreachable;
        return @as(BlockId, @intCast(index));
    }

    pub fn getBlockFromState(self: *const Self, state_id: BlockId) Block {
        var block: Block = undefined;
        block.min_state = state_id;
        block.max_state = 0;

        const index = std.sort.binarySearch(Block, block, self.blocks, @as(u8, 0), Block.compareStateIds) orelse unreachable;
        return self.blocks[index];
    }
};
