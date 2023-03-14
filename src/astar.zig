const std = @import("std");
const mc = @import("listener.zig");

const Vector = @import("vector.zig");
const V3f = Vector.V3f;

pub const V2i = struct {
    x: i32,
    y: i32,
};

const ADJ = [8]V2i{
    .{ .x = -1, .y = 1 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 1 },
    .{ .x = 1, .y = 0 },

    .{ .x = 1, .y = -1 },
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = -1 },
    .{ .x = -1, .y = 0 },
};

const ADJ_COST = [8]u32{
    14,
    10,
    14,
    10,
    14,
    10,
    14,
    10,
};

//
//     4
//   0 3
//   i 2  X
//XXXXX1
//     0
//
//Scan each adjacent block column
//
//Test masks in order
//
//level-walk-mask
//jump-up-mask
//jump-down-mask
//
//in order for the corners to be accesible nodes the two adjacent cardinals need to be open, complicated once you add jumping etc

pub const AStarContext = struct {
    const Self = @This();
    pub const Node = struct {
        pub const Ntype = enum {
            blocked,
            ladder,
            walk,
            jump,
            fall,
        };

        parent: ?*Node = null,
        G: u32 = 0,
        H: u32 = 0,

        x: i32,
        y: i32,
        z: i32,

        ntype: Ntype = .walk,
    };

    pub const MoveItem = struct {
        kind: AStarContext.Node.Ntype = .walk,
        pos: V3f,
    };

    pub const ColumnHelper = struct {
        const S = @This();

        pub const Category = struct {
            cat: Node.Ntype,
            y_offset: i32 = 0,
        };

        ctx: *const Self,
        x: i32,
        z: i32,
        y: i32,

        pub fn walkable(s: *const S, y: i32) bool {
            return @bitCast(bool, s.ctx.world.getBlock(s.x, y + s.y, s.z) != 0);
        }

        pub fn canEnter(s: *const S, y: i32) bool {
            const id = s.ctx.block_table.getBlockIndex(s.ctx.world.getBlock(s.x, s.y + y, s.z));
            const tag_list = [_][]const u8{ "flowers", "rails", "signs", "wool_carpets", "crops", "climbable", "buttons", "banners" };
            const fully_tag = blk: {
                var list: [tag_list.len][]const u8 = undefined;
                inline for (tag_list) |li, i| {
                    list[i] = "minecraft:" ++ li;
                }
                break :blk list;
            };
            if (id == 0)
                return true;
            for (fully_tag) |tag| {
                if (s.ctx.hasBlockTag(tag, s.x, y + s.y, s.z)) {
                    return true;
                }
            }
            return false;
        }
    };

    pub const BlockColumn = struct {
        col: u8,
    };

    world: *mc.ChunkMap,
    tag_table: *mc.TagRegistry,
    block_table: *mc.BlockRegistry,

    open: std.ArrayList(*Node),
    closed: std.ArrayList(*Node),

    pub fn init(alloc: std.mem.Allocator, world: *mc.ChunkMap, tag_table: *mc.TagRegistry, block_table: *mc.BlockRegistry) Self {
        return Self{
            .open = std.ArrayList(*Node).init(alloc),
            .closed = std.ArrayList(*Node).init(alloc),
            .world = world,
            .tag_table = tag_table,
            .block_table = block_table,
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

    pub fn pathfind(self: *Self, start: V3f, goal: V3f, move_vecs: *std.ArrayList(MoveItem)) !void {
        try self.reset();
        try self.addOpen(.{ .x = @floatToInt(i32, start.x), .y = @floatToInt(i32, start.y), .z = @floatToInt(i32, start.z) });
        const gpx = @floatToInt(i32, goal.x);
        const gpy = @floatToInt(i32, goal.y);
        const gpz = @floatToInt(i32, goal.z);

        while (true) {
            const current_n = self.popLowestFOpen() orelse break;

            if (current_n.x == gpx and current_n.z == gpz and current_n.y == gpy) {
                var parent: ?*AStarContext.Node = current_n;
                try move_vecs.resize(0);
                while (parent.?.parent != null) : (parent = parent.?.parent) {
                    try move_vecs.append(.{
                        .kind = parent.?.ntype,
                        .pos = V3f.newi(parent.?.x, parent.?.y, parent.?.z).subtract(V3f.new(
                            -0.5,
                            0,
                            -0.5,
                        )),
                    });
                }
                break;
            }

            { //LADDERS
                var y_offset: i32 = 1;
                while (self.hasBlockTag("minecraft:climbable", current_n.x, current_n.y + y_offset, current_n.z)) : (y_offset += 1) {
                    if (self.hasWalkableAdj(current_n.x, current_n.y + y_offset, current_n.z))
                        try self.addNode(.{
                            .ntype = .ladder,
                            .x = current_n.x,
                            .z = current_n.z,
                            .y = current_n.y + y_offset + 1,
                            .G = current_n.G + @intCast(u32, try std.math.absInt(y_offset)),
                            .H = @intCast(u32, try std.math.absInt(gpx - (current_n.x)) +
                                try std.math.absInt(gpz - (current_n.z))),
                        }, current_n);
                }

                y_offset = -1;
                while (self.hasBlockTag("minecraft:climbable", current_n.x, current_n.y + y_offset, current_n.z)) : (y_offset -= 1) {
                    if (self.hasWalkableAdj(current_n.x, current_n.y + y_offset - 1, current_n.z))
                        try self.addNode(.{
                            .ntype = .ladder,
                            .x = current_n.x,
                            .z = current_n.z,
                            .y = current_n.y + y_offset + 1,
                            .G = current_n.G + @intCast(u32, try std.math.absInt(y_offset)),
                            .H = @intCast(u32, try std.math.absInt(gpx - (current_n.x)) +
                                try std.math.absInt(gpz - (current_n.z))),
                        }, current_n);
                }
            }

            try self.addAdjNodes(current_n, goal);
        }
    }

    pub fn addNode(self: *Self, node: Node, parent: *Node) !void {
        var new_node = node;
        var is_on_closed = false;
        for (self.closed.items) |cl| {
            if (cl.x == new_node.x and cl.y == new_node.y and cl.z == new_node.z) {
                is_on_closed = true;
                //std.debug.print("CLOSED\n", .{});
                break;
            }
        }
        new_node.parent = parent;
        if (!is_on_closed) {
            var old_open: ?*AStarContext.Node = null;
            for (self.open.items) |op| {
                if (op.x == new_node.x and op.y == new_node.y and op.z == new_node.z) {
                    old_open = op;
                    //std.debug.print("EXISTS BEFORE\n", .{});
                    break;
                }
            }

            if (old_open) |op| {
                if (new_node.G < op.G) {
                    op.parent = parent;
                    op.G = new_node.G;
                }
            } else {
                try self.addOpen(new_node);
            }
        }
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
                lowest = node.G + (node.H * 10);
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

    pub fn addAdjNodes(self: *Self, node: *Node, goal: V3f) !void {
        const direct_adj = [_]u32{ 1, 3, 5, 7 };
        const diag_adj = [_]u32{ 0, 2, 4, 6 };
        var acat: [8]ColumnHelper.Category = .{.{ .cat = .blocked }} ** 8;
        for (direct_adj) |di| {
            const avec = ADJ[di];
            acat[di] = self.catagorizeAdjColumn(node.x + avec.x, node.y - 1, node.z + avec.y, false, 4);
        }

        for (diag_adj) |di| {
            const li = @intCast(u32, @mod(@intCast(i32, di) - 1, 8));
            const ui = @mod(di + 1, 8);
            if (acat[li].cat == acat[ui].cat and acat[li].cat != .blocked) {
                const avec = ADJ[di];
                const cat = self.catagorizeAdjColumn(node.x + avec.x, node.y - 1, node.z + avec.y, false, 4);
                acat[di] = if (cat.cat == acat[ui].cat) cat else .{ .cat = .blocked };
            }
        }

        for (acat) |cat, i| {
            const avec = ADJ[i];
            if (cat.cat == .blocked)
                continue;
            try self.addNode(.{
                .ntype = cat.cat,
                .x = node.x + avec.x,
                .z = node.z + avec.y,
                .y = node.y + cat.y_offset,
                .G = ADJ_COST[i] + node.G + @intCast(u32, (try std.math.absInt(cat.y_offset)) * 1),
                //TODO fix the hurestic
                .H = @intCast(u32, try std.math.absInt(@floatToInt(i32, goal.x) - (node.x + avec.x)) +
                    try std.math.absInt(@floatToInt(i32, goal.z) - (node.z + avec.y))),
            }, node);
        }
    }

    //TYPES of movevment
    //walk
    //fall
    //jump
    //ladder

    //z is the coordinate beneath players feet
    pub fn catagorizeAdjColumn(self: *Self, x: i32, y: i32, z: i32, head_blocked: bool, max_fall_dist: u32) ColumnHelper.Category {
        const col = ColumnHelper{ .x = x, .z = z, .y = y, .ctx = self };
        if (col.walkable(0) and col.canEnter(1) and col.canEnter(2)) {
            return .{ .cat = .walk };
        } else if (!head_blocked and col.walkable(1) and col.canEnter(2) and col.canEnter(3)) {
            return .{ .cat = .jump, .y_offset = 1 };
        } else {
            if (!col.canEnter(1) or !col.canEnter(2))
                return .{ .cat = .blocked };
            var i: i32 = 0;
            while (y + i >= -64) : (i -= 1) {
                if (col.walkable(i)) {
                    if (@intCast(u32, (std.math.absInt(i) catch unreachable)) <= max_fall_dist)
                        return .{ .cat = .fall, .y_offset = i };
                    break;
                }
            }
        }
        return .{ .cat = .blocked };
    }

    pub fn hasBlockTag(self: *const Self, tag: []const u8, x: i32, y: i32, z: i32) bool {
        return (self.tag_table.hasTag(self.block_table.getBlockIndex(self.world.getBlock(x, y, z)), "minecraft:block", tag));
    }

    //TODO check if it is transparent block
    pub fn isWalkable(self: *Self, x: i32, y: i32, z: i32) bool {
        return @bitCast(bool, self.world.getBlock(x, y, z) != 0);
    }

    pub fn hasWalkableAdj(self: *Self, x: i32, y: i32, z: i32) bool {
        var l_adj: [4][3]bool = undefined;
        const a_ind = [_]u32{ 1, 3, 5, 7 };
        for (a_ind) |ind, i| {
            const a_vec = ADJ[ind];
            const bx = x + a_vec.x;
            const bz = z + a_vec.y;
            const by = y;
            l_adj[i][0] = @bitCast(bool, self.world.getBlock(bx, by, bz) != 0);
            l_adj[i][1] = @bitCast(bool, self.world.getBlock(bx, by + 1, bz) != 0);
            l_adj[i][2] = @bitCast(bool, self.world.getBlock(bx, by + 2, bz) != 0);

            if (l_adj[i][0] and !l_adj[i][1] and !l_adj[i][2]) {
                return true;
            }
        }
        return false;
    }

    //pub fn addWalkableAdj(self: *Self )!void{

    //}

};
