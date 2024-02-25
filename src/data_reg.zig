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

pub const Item = struct {
    id: ItemId,
    name: []const u8,
    stackSize: u8,
    //displayName: []const u8,
};
pub const ItemsJson = []const Item;

pub const EntitiesJson = []const struct {
    id: u8,
    internalId: u8,
    name: []const u8,
    width: f32,
    height: f32,
    type: []const u8,
};

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
};
pub const BlocksJson = []Block;

pub const NewDataReg = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    version_id: u32,
    items: ItemsJson,
    blocks: BlocksJson,
    entities: EntitiesJson,

    empty_block_ids: std.ArrayList(BlockId),

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

        var empty = std.ArrayList(BlockId).init(alloc);
        for (block.value) |b| {
            if (b.boundingBox == .empty)
                try empty.append(b.id);
        }
        std.sort.heap(BlockId, empty.items, {}, std.sort.asc(BlockId));
        std.sort.heap(Block, block.value, {}, Block.asc);

        const ret = Self{
            .version_id = version_info.value.version,
            .alloc = alloc,
            .items = items.value,
            .entities = ent.value,
            .blocks = block.value,
            .empty_block_ids = empty,

            .item_j = items,
            .block_j = block,
            .ent_j = ent,
        };
        return ret;
    }

    pub fn deinit(self: *const Self) void {
        self.empty_block_ids.deinit();
        self.item_j.deinit();
        self.block_j.deinit();
        self.ent_j.deinit();
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

    pub fn getBlockIdFromState(self: *const Self, state_id: StateId) BlockId {
        return self.getBlockFromState(state_id).id;
    }
};
