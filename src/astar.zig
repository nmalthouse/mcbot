const std = @import("std");

pub const AStarContext = struct {
    const Self = @This();
    pub const Node = struct {
        parent: ?*Node = null,
        G: u32 = 0,
        H: u32 = 0,

        x: i32,
        y: i32,
        z: i32,
    };

    open: std.ArrayList(*Node),
    closed: std.ArrayList(*Node),

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .open = std.ArrayList(*Node).init(alloc),
            .closed = std.ArrayList(*Node).init(alloc),
        };
    }

    pub fn reset(self: *Self) !void {
        for (self.closed.items) |cl|
            self.closed.allocator.destroy(cl);
        for (self.open.items) |cl|
            self.closed.allocator.destroy(cl);
        try self.open.resize(0);
        try self.closed.resize(0);
    }

    pub fn deinit(self: *Self) void {
        self.reset() catch unreachable;
        self.open.deinit();
        self.closed.deinit();
    }

    pub fn addOpen(self: *Self, node: Node) !void {
        const new_node = try self.open.allocator.create(Node);
        new_node.* = node;
        try self.open.append(new_node);
    }

    pub fn popLowestFOpen(self: *Self) ?*Node {
        var lowest: u32 = std.math.maxInt(u32);
        var lowest_index: ?usize = null;
        for (self.open.items) |node, i| {
            if (node.G + (node.H * 10) < lowest) {
                lowest = node.G + node.H;
                lowest_index = i;
            }
        }

        if (lowest_index) |ind| {
            const n = self.open.swapRemove(ind);
            self.closed.append(n) catch unreachable;
            return n;
        } else {
            return null;
        }
    }
};
