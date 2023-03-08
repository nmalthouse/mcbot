const std = @import("std");
const vector = @import("vector.zig");
const V3f = vector.V3f;

//Stores info about a specific bot/player
//Not a client as chunk data etc can be shaerd between Bots
pub const Bot = struct {
    const Self = @This();

    name: []const u8,
    health: f32 = 20,
    food: u8 = 20,
    food_saturation: f32 = 5,
    pos: V3f,
    e_id: u32,

    pub fn init(alloc: std.mem.Allocator, name_: []const u8) Bot {
        _ = alloc;
        return Bot{
            .name = name_,
            .pos = V3f.new(0, 0, 0),
            .e_id = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
