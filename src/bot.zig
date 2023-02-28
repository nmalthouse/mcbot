const std = @import("std");

//Stores info about a specific bot/player
//Not a client as chunk data etc can be shaerd between Bots
pub const Bot = struct {
    const Self = @This();

    name: []const u8,
    health: f32 = 20,
    food: u8 = 20,
    food_saturation: f32 = 5,

    pub fn init(alloc: std.mem.Allocator, name_: []const u8) Bot {
        _ = alloc;
        return Bot{ .name = name_ };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
