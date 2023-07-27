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

    pub fn init(alloc: std.mem.Allocator, comptime version: []const u8) !Self {
        var cwd = std.fs.cwd();
        var data_dir = try cwd.openDir("minecraft-data/data/pc/" ++ version, .{});
        defer data_dir.close();

        const version_file = try data_dir.openFile("version.json", .{});
        defer version_file.close();
        const version_info = try com.readJsonFd(&version_file, alloc, VersionJson);
        com.freeJson(VersionJson, alloc, version_info);

        const items_file = try data_dir.openFile("items.json", .{});
        defer items_file.close();

        const ent_file = try data_dir.openFile("entities.json", .{});
        defer ent_file.close();

        const block_file = try data_dir.openFile("blocks.json", .{});
        defer block_file.close();

        const ret = Self{
            .version_id = version_info.version,
            .alloc = alloc,
            .items = try com.readJsonFd(&items_file, alloc, ItemsJson),
            .entities = try com.readJsonFd(&ent_file, alloc, EntitiesJson),
            .blocks = try com.readJsonFd(&block_file, alloc, BlocksJson),
        };
        return ret;
    }

    pub fn deinit(self: *const Self) void {
        com.freeJson(ItemsJson, self.alloc, self.items);
        com.freeJson(EntitiesJson, self.alloc, self.entities);
        com.freeJson(BlocksJson, self.alloc, self.blocks);
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

    pub fn init(alloc: std.mem.Allocator, filename: []const u8) !Self {
        const reg = try com.readJsonFile(filename, alloc, Self);
        return reg;
    }

    pub fn deinit(self: *const Self, alloc: std.mem.Allocator) void {
        com.freeJson(Self, alloc, self.*);
    }

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
        return @intCast(BlockId, index);
    }

    pub fn getBlockFromState(self: *const Self, state_id: BlockId) Block {
        var block: Block = undefined;
        block.min_state = state_id;
        block.max_state = 0;

        const index = std.sort.binarySearch(Block, block, self.blocks, @as(u8, 0), Block.compareStateIds) orelse unreachable;
        return self.blocks[index];
    }
};
