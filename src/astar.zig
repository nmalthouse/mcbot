const std = @import("std");
const mc = @import("listener.zig");
const Reg = @import("data_reg.zig");
const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;

const Vector = @import("vector.zig");
const V3f = Vector.V3f;
const V3i = Vector.V3i;
const ITERATION_LIMIT = 100000;

//TODO move to vector class
pub const V2i = struct {
    x: i32,
    y: i32,
};

const FACE_ADJ = [6]V3i{ //six faces of a cube
    .{ .x = -1, .y = 0, .z = 0 },
    .{ .x = 1, .y = 0, .z = 0 },
    .{ .x = 0, .y = -1, .z = 0 },
    .{ .x = 0, .y = 1, .z = 0 },
    .{ .x = 0, .y = 0, .z = -1 },
    .{ .x = 0, .y = 0, .z = 1 },
};

// Even indicies are diagonal
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

pub const AStarContext = struct {
    const Self = @This();
    pub const Node = struct {
        pub const HashPos = struct {
            x: i32,
            y: i32,
            z: i32,

            pub fn eql(ctx: HashPos, a: @This(), b: @This()) bool {
                _ = ctx;
                return a.x == b.x and a.y == b.y and a.z == b.z;
            }

            pub fn hash(ctx: HashPos, a: @This()) u64 {
                _ = ctx;
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(hasher, a.x, .Shallow);
                std.hash.autoHashStrat(hasher, a.y, .Shallow);
                std.hash.autoHashStrat(hasher, a.z, .Shallow);
                return hasher.final();
            }
        };
        pub const Ntype = enum {
            freemove,
            blocked,
            ladder,
            walk,
            jump,
            fall,
            gap,
        };

        parent: ?*Node = null,
        block_id: Reg.StateId = 0,
        G: u32 = 0,
        H: u32 = 0,

        x: i32,
        y: i32,
        z: i32,

        ntype: Ntype = .walk,

        pub fn compare(ctx: void, a: *Node, b: *Node) std.math.Order {
            _ = ctx;
            const fac = 20;
            return std.math.order(a.G + a.H * fac, b.G + b.H * fac);
        }
    };

    pub const PlayerActionItem = union(enum) {
        pub const Inv = struct {
            pub const ItemMoveDirection = enum { deposit, withdraw };
            pub const ItemCategory = enum { food };
            pub const Match = union(enum) {
                by_id: Reg.ItemId,
                tag_list: []const u32, //Owned by TagRegistry, list of item ids
                category: usize,
                match_any: void,
            };

            direction: ItemMoveDirection,
            match: Match,
            count: u8 = 1,
        };
        chat: struct { str: std.ArrayList(u8), is_command: bool },

        eat: void,
        movement: MoveItem,
        block_break_pos: struct { pos: V3i, repeat_timeout: ?f64 = null },
        block_break: BreakBlock,
        wait_ms: u32,
        hold_item_name: Reg.ItemId,
        hold_item: struct { slot_index: u16, hotbar_index: u16 = 0 },
        place_block: struct {
            select_item_tag: ?[]const u8 = null, //TODO currently this is not an allocated string
            pos: V3i,
        },
        open_chest: struct { pos: V3i },
        close_chest: void,

        inventory: Inv,
        craft: struct {
            product_id: Reg.ItemId,
            count: u8,
        },
        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .chat => |*ch| {
                    ch.str.deinit();
                },
                else => {},
            }
        }
    };

    pub const BreakBlock = struct {
        pos: V3i,
        break_time: f64,
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
            //this could be renamed to x offset
            gap: i32 = 0,
        };

        ctx: *const Self,
        x: i32,
        z: i32,
        y: i32,

        pub fn walkable(s: *const S, y: i32) bool {
            const id = s.ctx.world.reg.getBlockFromState(s.ctx.world.chunkdata(s.ctx.dim_id).getBlock(V3i.new(s.x, y + s.y, s.z)) orelse return false);
            return s.ctx.world.reg.isBlockCollidable(id.id);
        }

        pub fn canEnter(s: *const S, y: i32) bool {
            const id = s.ctx.world.reg.getBlockFromState(s.ctx.world.chunkdata(s.ctx.dim_id).getBlock(V3i.new(s.x, s.y + y, s.z)) orelse return false).id;
            const tags_to_check = [_][]const u8{
                "minecraft:climbable",
                "minecraft:signs",
            };
            var can = false;
            for (tags_to_check) |t| {
                can = can or s.ctx.world.tag_table.hasTag(id, "minecraft:block", t);
            }
            return !s.ctx.world.reg.isBlockCollidable(id) or can;
        }
    };

    pub const BlockColumn = struct {
        col: u8,
    };
    const QType = std.PriorityQueue(*Node, void, Node.compare);
    //const ClosedType = std.HashMap(*Node, void, Node, std.hash_map.default_max_load_percentage);
    const ClosedType = std.AutoHashMap(Node.HashPos, *Node);

    alloc: std.mem.Allocator,
    world: *McWorld,

    openq: QType,
    //open: std.ArrayList(*Node),
    //closed: std.ArrayList(*Node),
    closed: ClosedType,
    dim_id: i32,

    pub fn init(alloc: std.mem.Allocator, world: *McWorld, dim_id: i32) Self {
        return Self{
            .openq = QType.init(alloc, {}),
            .dim_id = dim_id,
            .closed = ClosedType.init(alloc),
            //.open = std.ArrayList(*Node).init(alloc),
            //.closed = std.ArrayList(*Node).init(alloc),
            .world = world,
            .alloc = alloc,
        };
    }

    pub fn reset(self: *Self, dim_id: i32) !void {
        var cit = self.closed.valueIterator();
        while (cit.next()) |cl|
            self.closed.allocator.destroy(cl.*);
        var it = self.openq.iterator();
        while (it.next()) |cl|
            self.closed.allocator.destroy(cl);
        //try self.open.resize(0);
        self.closed.clearRetainingCapacity();
        self.openq.deinit();
        self.dim_id = dim_id;
        self.openq = QType.init(self.closed.allocator, {});
    }

    pub fn deinit(self: *Self) void {
        self.reset(0) catch unreachable;
        //self.open.deinit();
        self.closed.deinit();
        self.openq.deinit();
    }

    //Write a new flood fill with better predicat system
    //A want to do a walkable flood fill for any1`

    pub fn floodfillCommonBlock(self: *Self, start: V3f, blockid: Reg.BlockId, max_dist: f32, dim_id: i32) !?std.ArrayList(V3i) {
        var last_matching_pos = start;
        try self.reset(dim_id);
        try self.addOpen(.{ .x = @as(i32, @intFromFloat(start.x)), .y = @as(i32, @intFromFloat(start.y)), .z = @as(i32, @intFromFloat(start.z)) });
        var iterations: usize = 0;
        while (true) : (iterations += 1) {
            const current_n = self.popLowestFOpen() orelse break;
            const pv = V3i.new(current_n.x, current_n.y, current_n.z);
            //const direct_adj = [_]u32{ 1, 3, 5, 7 };
            for (FACE_ADJ) |avec| {
                const coord = V3i.new(pv.x + avec.x, pv.y + avec.y, pv.z + avec.z);
                if (self.world.chunkdata(self.dim_id).getBlock(coord)) |id| {
                    const state_id = self.world.reg.getBlockIdFromState(id);
                    if (state_id == blockid) {
                        last_matching_pos = coord.toF();
                        try self.addNode(.{
                            .block_id = id,
                            .ntype = .walk,
                            .x = coord.x,
                            .y = coord.y,
                            .z = coord.z,
                            .G = 0,
                            .H = 0,
                        }, current_n);
                    } else {
                        if (last_matching_pos.subtract(coord.toF()).magnitude() < max_dist) {
                            try self.addNode(.{
                                .block_id = id,
                                .ntype = .walk,
                                .x = coord.x,
                                .y = coord.y,
                                .z = coord.z,
                                .G = 0,
                                .H = 0,
                            }, current_n);
                        }
                    }
                }
            }
            if (self.openq.items.len == 0) {
                var tiles = std.ArrayList(V3i).init(self.alloc);
                var cit = self.closed.valueIterator();
                while (cit.next()) |p| {
                    if (self.world.reg.getBlockIdFromState(p.*.block_id) == blockid)
                        try tiles.append(V3i.new(p.*.x, p.*.y, p.*.z));
                }
                return tiles;
            }
        }
        return null;
    }

    //calling a lua predicate for every node is probably too slow
    //IF combined with a early filtering system in zig then a nice lua predicate is possible.
    //IF zig detects dirt with 2+wood on top call the predicate to determine if its a tree
    pub fn findTree(self: *Self, start: V3f, dim_id: i32) !?struct {
        list: std.ArrayList(PlayerActionItem),
        // String does not need to be freed
        tree_name: []const u8,
    } {
        try self.reset(dim_id);
        try self.addOpen(.{
            .x = @as(i32, @intFromFloat(@floor(start.x))),
            .y = @as(i32, @intFromFloat(@floor(start.y))),
            .z = @as(i32, @intFromFloat(@floor(start.z))),
        });

        var iter_count: usize = 0;
        while (iter_count < ITERATION_LIMIT) : (iter_count += 1) {
            const current_n = self.popLowestFOpen() orelse break;
            const pv = V3i.new(current_n.x, current_n.y, current_n.z);
            const direct_adj = [_]u32{ 1, 3, 5, 7 };
            const MAX_HEIGHT = 64;
            for (direct_adj) |di| {
                const avec = ADJ[di];
                var is_tree = false;
                var n_logs: i32 = 0;
                if (self.hasBlockTag("minecraft:dirt", pv.add(V3i.new(avec.x, -1, avec.y)))) {
                    while (self.hasBlockTag("minecraft:logs", pv.add(V3i.new(avec.x, n_logs, avec.y)))) : (n_logs += 1) {}
                    if (n_logs > 0 and self.hasBlockTag("minecraft:leaves", pv.add(V3i.new(avec.x, n_logs, avec.y))) and n_logs < MAX_HEIGHT) {
                        is_tree = true;
                    }
                }
                if (is_tree) { // If it is a tree, do a check for logs around it to discard any trees with branches
                    const stump = pv.add(V3i.new(avec.x, 0, avec.y));
                    outer: for (0..@intCast(n_logs)) |li| {
                        for (ADJ) |a| {
                            if (self.hasBlockTag("minecraft:logs", stump.add(V3i.new(a.x, @intCast(li), a.y)))) {
                                is_tree = false;
                                std.debug.print("Discarding tree with branch\n", .{});
                                break :outer;
                            }
                        }
                    }
                }
                //We seem to be missing a node at the beginning
                if (is_tree) {
                    //Get the name of the log
                    const tree_name = blk: {
                        const log_block = self.world.reg.getBlockFromState(self.world.chunkdata(self.dim_id).getBlock(pv.add(V3i.new(avec.x, 0, avec.y))) orelse return null);
                        if (std.mem.lastIndexOfScalar(u8, log_block.name, '_')) |ind| {
                            if (std.mem.startsWith(u8, log_block.name, "stripped")) {
                                break :blk log_block.name["stripped_".len..ind];
                            }
                            break :blk log_block.name[0..ind];
                        }
                        break :blk "unknown";
                    };

                    var parent: ?*AStarContext.Node = current_n;
                    var actions = std.ArrayList(PlayerActionItem).init(self.alloc);
                    //First add the tree backwards
                    n_logs -= 1;
                    const total_logs = n_logs;
                    if (total_logs > 7) {
                        //descend down
                        var i: i32 = 0;
                        //first dig then move down starting at the highest
                        while (i < total_logs - 7) : (i += 1) {
                            try actions.append(.{ .movement = .{
                                .kind = .freemove,
                                .pos = pv.add(V3i.new(avec.x, i, avec.y)).toF().subtract(V3f.new(-0.5, 0, -0.5)),
                            } });
                            try actions.append(.{ .block_break_pos = .{ .pos = pv.add(V3i.new(avec.x, i, avec.y)) } });
                        }
                    }
                    while (n_logs >= 0) : (n_logs -= 1) {
                        const jumper = n_logs > 7;
                        try actions.append(.{
                            .block_break_pos = .{ .pos = pv.add(V3i.new(avec.x, n_logs, avec.y)) },
                        });
                        if (jumper) { //First place the block,jump, then mine
                            try actions.append(.{
                                .place_block = .{
                                    .pos = pv.add(V3i.new(avec.x, n_logs - 8, avec.y)),
                                    .select_item_tag = "minecraft:logs",
                                },
                            });
                            try actions.append(.{ .wait_ms = 100 });
                            try actions.append(.{ .movement = .{
                                .kind = .freemove,
                                .pos = pv.add(V3i.new(avec.x, n_logs - 7, avec.y)).toF().subtract(V3f.new(-0.5, 0, -0.5)),
                            } });
                        }
                        if (n_logs == 2) { //Walk under the tree after breaking the first 2 blocks
                            try actions.append(.{ .movement = .{
                                .kind = .walk,
                                .pos = pv.add(V3i.new(avec.x, 0, avec.y)).toF().subtract(V3f.new(-0.5, 0, -0.5)),
                            } });
                        }
                    }

                    //if(did the jump)
                    //undo the jump n times

                    while (parent != null) : (parent = parent.?.parent) {
                        //while (parent.?.parent != null) : (parent = parent.?.parent) {
                        switch (parent.?.ntype) {
                            .gap, .jump, .fall => try actions.append(.{ .wait_ms = 300 }),
                            else => {},
                        }
                        try actions.append(.{ .movement = .{
                            .kind = parent.?.ntype,
                            .pos = V3f.newi(parent.?.x, parent.?.y, parent.?.z).subtract(V3f.new(-0.5, 0, -0.5)),
                        } });
                    }
                    //return pv.add(V3i.new(avec.x, 0, avec.y));
                    return .{ .list = actions, .tree_name = tree_name };
                }
            }

            try self.addAdjLadderNodes(current_n, V3i.new(0, 0, 0), 0);
            try self.addAdjNodes(current_n, V3f.new(0, 0, 0), 0);
        }

        return null;
    }

    //TODO Prevent attempting to path outside of currently loaded chunks
    //Starting with simplest, check if goal is outside of loaded chunks.
    //Full implementation will need to check range on each node xz
    pub fn pathfind(
        self: *Self,
        dimension_id: i32,
        start: V3f,
        goal: V3f,
        params: struct {
            min_distance: ?f32 = null, //if set, a node within this distance from goal is a match
        },
    ) !?std.ArrayList(PlayerActionItem) {
        if (self.world.chunkdata(self.dim_id).isLoaded(goal.toI()) == false) {
            return null;
        }

        try self.reset(dimension_id);
        try self.addOpen(.{
            .x = @as(i32, @intFromFloat(@floor(start.x))),
            .y = @as(i32, @intFromFloat(@floor(start.y))),
            .z = @as(i32, @intFromFloat(@floor(start.z))),
        });
        //Is there a reason this is round
        const gpx = @as(i32, @intFromFloat(@floor(goal.x)));
        const gpy = @as(i32, @intFromFloat(@floor(goal.y)));
        const gpz = @as(i32, @intFromFloat(@floor(goal.z)));

        var i: u32 = 0;
        //TODO make iteration limit change depending on the distance between position and goal
        while (i < ITERATION_LIMIT) : (i += 1) {
            const current_n = self.popLowestFOpen() orelse break;
            var actions = std.ArrayList(PlayerActionItem).init(self.alloc);
            const is_goal = current_n.x == gpx and current_n.z == gpz and current_n.y == gpy;
            const is_near = blk: {
                if (params.min_distance) |md| {
                    const dist = V3f.newi(gpx - current_n.x, gpy - current_n.y, gpz - current_n.z).magnitude();
                    break :blk dist <= md;
                } else {
                    break :blk false;
                }
            };

            if (is_goal or is_near) {
                var parent: ?*AStarContext.Node = current_n;
                while (parent != null) : (parent = parent.?.parent) {
                    switch (parent.?.ntype) {
                        .gap, .jump, .fall => try actions.append(.{ .wait_ms = 300 }),
                        else => {},
                    }
                    try actions.append(.{ .movement = .{
                        .kind = parent.?.ntype,
                        .pos = V3f.newi(parent.?.x, parent.?.y, parent.?.z).subtract(V3f.new(
                            -0.5,
                            0,
                            -0.5,
                        )),
                    } });
                }
                return actions;
            }

            try self.addAdjLadderNodes(current_n, goal.toI(), null);
            try self.addAdjNodes(current_n, goal, null);
        }
        std.debug.print("ITERATION LIMIT EXCEEDED\n", .{});
        return null;
    }

    pub fn addAdjLadderNodes(self: *Self, node: *Node, goal: V3i, override_h: ?u32) !void {
        var y_offset: i32 = 1;
        const h = override_h orelse 0;
        _ = goal;
        while (self.hasBlockTag("minecraft:climbable", V3i.new(node.x, node.y + y_offset, node.z))) : (y_offset += 1) {
            if (self.hasWalkableAdj(node.x, node.y + y_offset, node.z))
                try self.addNode(.{
                    .ntype = .ladder,
                    .x = node.x,
                    .z = node.z,
                    .y = node.y + y_offset + 1,
                    .G = node.G + 10,
                    .H = h,
                }, node);
        }

        y_offset = -1;
        while (self.hasBlockTag("minecraft:climbable", V3i.new(node.x, node.y + y_offset, node.z))) : (y_offset -= 1) {
            if (self.hasWalkableAdj(node.x, node.y + y_offset - 1, node.z))
                try self.addNode(.{
                    .ntype = .ladder,
                    .x = node.x,
                    .z = node.z,
                    .y = node.y + y_offset + 1,
                    .G = node.G + 10,
                    .H = h,
                }, node);
        }
    }

    pub fn addNode(self: *Self, node: Node, parent: *Node) !void {
        var new_node = node;
        const is_on_closed = false;
        if (self.closed.get(.{ .x = node.x, .y = node.y, .z = node.z }) != null) {
            return;
        }
        new_node.parent = parent;
        if (!is_on_closed) {
            var it = self.openq.iterator();
            while (it.next()) |op| {
                if (op.x == new_node.x and op.y == new_node.y and op.z == new_node.z) {
                    if (new_node.G < op.G) { //Destroy old node
                        self.closed.allocator.destroy(self.openq.removeIndex(it.count - 1));
                    } else { //Discard new node, already exists with lower G
                        return;
                    }
                    //std.debug.print("EXISTS BEFORE\n", .{});
                }
            }

            try self.addOpen(new_node);
        }
    }

    pub fn addOpen(self: *Self, node: Node) !void {
        const new_node = try self.openq.allocator.create(Node);
        new_node.* = node;
        try self.openq.add(new_node);
    }

    pub fn popLowestFOpen(self: *Self) ?*Node {
        const lowest = self.openq.removeOrNull();
        if (lowest) |l|
            self.closed.put(.{ .x = l.x, .y = l.y, .z = l.z }, l) catch unreachable;
        //self.closed.append(l) catch unreachable;
        return lowest;
    }

    pub fn addAdjNodes(self: *Self, node: *Node, goal: V3f, override_h: ?u32) !void {
        const block_above = self.world.chunkdata(self.dim_id).getBlock(V3i.new(node.x, node.y + 2, node.z)) orelse 0;
        const direct_adj = [_]u32{ 1, 3, 5, 7 };
        const diag_adj = [_]u32{ 0, 2, 4, 6 };
        var acat: [8]ColumnHelper.Category = .{.{ .cat = .blocked }} ** 8;
        for (direct_adj) |di| {
            const avec = ADJ[di];
            acat[di] = self.catagorizeAdjColumn(node.x + avec.x, node.y - 1, node.z + avec.y, false, 2, di);
        }

        for (diag_adj) |di| {
            const li = @as(u32, @intCast(@mod(@as(i32, @intCast(di)) - 1, 8)));
            const ui = @mod(di + 1, 8);
            //TODO expand this to be more inclusive
            if (acat[ui].cat == .walk and acat[li].cat == .walk) {
                const avec = ADJ[di];
                const cat = self.catagorizeAdjColumn(node.x + avec.x, node.y - 1, node.z + avec.y, false, 2, di);
                //acat[di] = if (cat.cat == acat[ui].cat) cat else .{ .cat = .blocked };
                acat[di] = if (cat.cat != .walk) .{ .cat = .blocked } else cat;
            }
        }

        for (acat, 0..) |cat, i| {
            const avec = ADJ[i];
            const h = if (override_h != null) override_h.? else @as(u32, @intCast(@abs(@as(i32, @intFromFloat(goal.x)) - (node.x + avec.x)) +
                @abs(@as(i32, @intFromFloat(goal.z)) - (node.z + avec.y)) + @abs(@as(i32, @intFromFloat(goal.y)) - node.y)));
            if (cat.cat == .blocked)
                continue;
            if (cat.cat == .jump and (block_above != 0 or i % 2 == 0))
                continue;

            if (i % 2 == 0 and cat.cat != .walk)
                continue;

            if (cat.cat == .gap) {
                try self.addNode(.{
                    .ntype = cat.cat,
                    .x = node.x + avec.x * cat.gap,
                    .z = node.z + avec.y * cat.gap,
                    .y = node.y + cat.y_offset,
                    .G = node.G + 20,
                    .H = h,
                }, node);
                continue;
            }

            try self.addNode(.{
                .ntype = cat.cat,
                .x = node.x + avec.x,
                .z = node.z + avec.y,
                .y = node.y + cat.y_offset,
                .G = node.G + switch (cat.cat) {
                    .ladder => 1,
                    .fall => 40,
                    .jump => 40,
                    .gap => 30,
                    else => ADJ_COST[i] + @as(u32, @intCast((@abs(cat.y_offset)) * 1)),
                },
                .H = h,
            }, node);
        }
    }

    // If we allow player to break certain blocks then the result of this function is ill defined.
    // For example, if the player can break stone and the player is in a cave every node is any category
    // If we can allow multiple nodes to be added this problem goes away. In the stone example this adds three nodes, dig straight, dig up one, dig down one
    // Or, to keep it simple breakable blocks cannot be considered walkable blocks, this makes the result of this function well defined
    ///z is the coordinate beneath players feet
    pub fn catagorizeAdjColumn(self: *Self, x: i32, y: i32, z: i32, head_blocked: bool, max_fall_dist: u32, adj_i: u32) ColumnHelper.Category {
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
                    if (@as(u32, @intCast(@abs(i))) <= max_fall_dist)
                        return .{ .cat = .fall, .y_offset = i };
                    break;
                }
            }
            //Can we jump across this?
            if (!head_blocked and col.canEnter(1) and col.canEnter(2) and col.canEnter(3)) {
                if (adj_i % 2 != 0) { //odd adj_i are cardinal directions
                    const max_gap_dist = 3;
                    var gi: i32 = 1;
                    while (gi <= max_gap_dist) : (gi += 1) {
                        const jcol = ColumnHelper{ .x = x + (ADJ[adj_i].x * gi), .z = z + (ADJ[adj_i].y * gi), .y = y, .ctx = self };
                        if (jcol.canEnter(1) and jcol.canEnter(2) and jcol.canEnter(3)) {
                            if (jcol.walkable(0))
                                return .{ .cat = .gap, .gap = gi + 1 };
                        }
                    }
                }
            }
        }
        return .{ .cat = .blocked };
    }

    pub fn hasAnyTagFrom(self: *const Self, namespace: []const u8, tags: []const []const u8, pos: V3i) bool {
        const block = self.world.reg.getBlockFromState(self.world.chunkdata(self.dim_id).getBlock(pos) orelse return false);
        for (tags) |tag| {
            if (self.world.tag_table.hasTag(block.id, namespace, tag))
                return true;
        }
        return false;
    }

    pub fn hasBlockTag(self: *const Self, tag: []const u8, pos: V3i) bool {
        return (self.world.tag_table.hasTag(self.world.reg.getBlockFromState(self.world.chunkdata(self.dim_id).getBlock(pos) orelse return false).id, "minecraft:block", tag));
    }

    //TODO check if it is transparent block
    pub fn isWalkable(self: *Self, x: i32, y: i32, z: i32) bool {
        return @as(bool, @bitCast(self.world.chunkdata(self.dim_id).getBlock(x, y, z) != 0));
    }

    pub fn hasWalkableAdj(self: *Self, x: i32, y: i32, z: i32) bool {
        var l_adj: [4][3]bool = undefined;
        const a_ind = [_]u32{ 1, 3, 5, 7 };
        for (a_ind, 0..) |ind, i| {
            const a_vec = ADJ[ind];
            const bx = x + a_vec.x;
            const bz = z + a_vec.y;
            const by = y;
            l_adj[i][0] = @as(bool, @bitCast((self.world.chunkdata(self.dim_id).getBlock(V3i.new(bx, by, bz)) orelse return false) != 0));
            l_adj[i][1] = @as(bool, @bitCast((self.world.chunkdata(self.dim_id).getBlock(V3i.new(bx, by + 1, bz)) orelse return false) != 0));
            l_adj[i][2] = @as(bool, @bitCast((self.world.chunkdata(self.dim_id).getBlock(V3i.new(bx, by + 2, bz)) orelse return false) != 0));

            if (l_adj[i][0] and !l_adj[i][1] and !l_adj[i][2]) {
                return true;
            }
        }
        return false;
    }
};

pub fn isWalkable(dim_id: i32, world: *McWorld, x: i32, y: i32, z: i32) bool {
    return @as(bool, @bitCast(world.chunkdata(dim_id).getBlock(x, y, z) != 0));
}

pub fn hasWalkableAdj(dim_id: i32, world: *McWorld, x: i32, y: i32, z: i32) bool {
    var l_adj: [4][3]bool = undefined;
    const a_ind = [_]u32{ 1, 3, 5, 7 };
    for (a_ind, 0..) |ind, i| {
        const a_vec = ADJ[ind];
        const bx = x + a_vec.x;
        const bz = z + a_vec.y;
        const by = y;
        l_adj[i][0] = @as(bool, @bitCast((world.chunkdata(dim_id).getBlock(V3i.new(bx, by, bz)) orelse return false) != 0));
        l_adj[i][1] = @as(bool, @bitCast((world.chunkdata(dim_id).getBlock(V3i.new(bx, by + 1, bz)) orelse return false) != 0));
        l_adj[i][2] = @as(bool, @bitCast((world.chunkdata(dim_id).getBlock(V3i.new(bx, by + 2, bz)) orelse return false) != 0));

        if (l_adj[i][0] and !l_adj[i][1] and !l_adj[i][2]) {
            return true;
        }
    }
    return false;
}

test "basic" {
    const Nt = AStarContext.Node.Ntype;
    const Column = [4]bool;

    const columns = [8]Column{
        Column{ true, false, false, false },
        Column{ true, false, false, false },
        Column{ false, false, false, false },
        Column{ false, false, false, false },

        Column{ false, false, false, false },
        Column{ false, false, false, false },
        Column{ false, false, false, false },
        Column{ false, true, false, false },
    };

    const exp = [8]Nt{
        .blocked,
        .walk,
        .blocked,
        .blocked,

        .blocked,
        .blocked,
        .blocked,
        .jump,
    };
    //const MAX_FALL_DISTANCE = 3;
    var actual = [_]Nt{.blocked} ** 8;
    const block_above_head = false;

    for (ADJ, 0..) |a, ai| {
        const col = columns[ai];
        _ = a;
        const can_walk = col[0] and (!(col[1] or col[2]));
        if (ai % 2 == 0) { //Diagonal
            const lcol = columns[(ai + 7) % 8];
            const rcol = columns[(ai + 1) % 8];
            const can_walk_d = can_walk and !(lcol[1] or lcol[2]) and !(rcol[1] or rcol[2]);
            actual[ai] = if (can_walk_d) .walk else .blocked;

            //Diagonals can only walk
        } else { //Straight
            if (can_walk) {
                actual[ai] = .walk;
            } else {
                actual[ai] = blk: {
                    if (!block_above_head and col[1] and !(col[2] or col[3])) { //Can jump
                        break :blk .jump;
                    } else if (!(col[0] or col[1] or col[2])) { //Can fall, check if we hit maxfalldist

                    }
                };
                //jump
                //fall
                //gap
            }
        }
    }

    for (exp, 0..) |v, i| {
        try std.testing.expectEqual(v, actual[i]);
    }
}
