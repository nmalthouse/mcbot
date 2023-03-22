const std = @import("std");
const com = @import("common.zig");

//This structure should contain all data related to minecraft required for our bot
pub const DataReg = struct {
    const Self = @This();
    pub const ItemId = u16;
    pub const BlockId = u16;

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

    pub fn getBlockFromState(self: *const Self, state_id: BlockId) Block {
        var block: Block = undefined;
        block.min_state = state_id;
        block.max_state = 0;

        const index = std.sort.binarySearch(Block, block, self.blocks, @as(u8, 0), Block.compareStateIds) orelse unreachable;
        return self.blocks[index];
    }
};
