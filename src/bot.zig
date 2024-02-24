const std = @import("std");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const mc = @import("listener.zig");
const astar = @import("astar.zig");

//How to move?
//Kinds of movment
//Walking
//  What is the height of the block we are standing on, slabs, carpets,
//  Dealing with instant changes in y with slabs and stairs
//Jumping
//Falling
//Swimming
//Ladder climbing
//Rabbit mode

pub fn quadFGreater(a: f64, b: f64, C: f64) ?f64 {
    const disc = std.math.pow(f64, b, 2) - (4 * a * C);
    if (disc < 0) return null;
    return (-b + @sqrt(disc)) / (2 * a);
}

pub fn quadFLess(a: f64, b: f64, C: f64) ?f64 {
    const disc = std.math.pow(f64, b, 2) - (4 * a * C);
    if (disc < 0) return null;
    return (-b - @sqrt(disc)) / (2 * a);
}

pub fn quadFL(a: f64, b: f64, C: f64) ?f64 {
    const disc = std.math.pow(f64, b, 2) - (4 * a * C);
    if (disc < 0) return null;

    const resA = (-b - @sqrt(disc)) / (2 * a);
    const resB = (-b + @sqrt(disc)) / (2 * a);

    return @min(resA, resB);
}

pub fn quadFR(a: f64, b: f64, C: f64) ?f64 {
    const disc = std.math.pow(f64, b, 2) - (4 * a * C);
    if (disc < 0) return null;

    const resA = (-b - @sqrt(disc)) / (2 * a);
    const resB = (-b + @sqrt(disc)) / (2 * a);

    return @max(resA, resB);
}

pub const MovementState = struct {
    const PlayerBounds: f64 = 0.6;
    const gravity: f64 = -32;
    const jumpV: f64 = 9;
    const Self = @This();
    pub const MoveResult = struct {
        remaining_dt: f64,
        move_complete: bool = false,
        new_pos: V3f,
        grounded: bool = true,
    };

    init_pos: V3f,
    final_pos: V3f,
    time: f64,

    move_type: astar.AStarContext.Node.Ntype,

    pub fn update(self: *Self, dt: f64) MoveResult {
        const speed = 4.37;
        const iv = self.final_pos.subtract(self.init_pos);
        const mvec = V3f.new(iv.x, 0, iv.z);
        switch (self.move_type) {
            .blocked => unreachable,
            .walk => {
                const max_t = mvec.magnitude() / speed;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{
                        .remaining_dt = r,
                        .move_complete = true,
                        .new_pos = self.final_pos,
                    };
                }

                self.time += dt;

                return MoveResult{
                    .remaining_dt = 0,
                    .move_complete = false,
                    .new_pos = self.init_pos.add(mvec.getUnitVec().smul(speed * self.time)),
                };
            },
            .jump => {
                if (mvec.magnitude() != 1) unreachable; //Only allow jumps in cardinal directions for now
                //Once we have reached dy = +1 we don't worry about colliding with the block we are jumping on.
                const at_y1_time = quadFL(gravity / 2, jumpV, -1) orelse unreachable;
                const jump_end_time = quadFR(gravity / 2, jumpV, -1) orelse unreachable;
                const lt_y1_v = (0.5 - (PlayerBounds / 2)) / at_y1_time;
                const gt_y1_v = (0.5 + (PlayerBounds / 2)) / (jump_end_time - at_y1_time);
                const at_y1_pos = self.init_pos.add(mvec.getUnitVec().smul(lt_y1_v * at_y1_time));
                const max_t = jump_end_time;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos };
                }

                self.time += dt;
                const dy = (gravity / 2) * std.math.pow(f64, self.time, 2) + (jumpV * self.time);
                if (self.time < at_y1_time) {
                    return MoveResult{
                        .remaining_dt = 0,
                        .grounded = false,
                        .move_complete = false,
                        .new_pos = self.init_pos.add(mvec.getUnitVec().smul(lt_y1_v * self.time).add(V3f.new(0, dy, 0))),
                    };
                } else if (self.time <= jump_end_time) {
                    return MoveResult{
                        .remaining_dt = 0,
                        .grounded = false,
                        .move_complete = false,
                        .new_pos = at_y1_pos.add(mvec.getUnitVec().smul(gt_y1_v * (self.time - at_y1_time)).add(V3f.new(0, dy, 0))),
                    };
                }
            },
            .fall => {
                if (mvec.magnitude() != 1) unreachable; //Only allow falls in cardinal directions for now
                const fall_time = quadFR(gravity / 2, 0, @fabs(iv.y)) orelse unreachable;
                const fall_start = (0.5 + (PlayerBounds / 2)) / speed;
                const max_t = fall_time + fall_start;
                const fall_walk_v = (0.5 - (PlayerBounds / 2)) / fall_time;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos };
                }

                if (self.time + dt < fall_start) { //Walking to the edge
                    self.time += dt;
                    return MoveResult{
                        .remaining_dt = 0,
                        .move_complete = false,
                        .new_pos = self.init_pos.add(mvec.getUnitVec().smul(speed * self.time)),
                    };
                } else if (self.time + dt >= fall_start) { //Falling and moving in xz
                    self.time += dt;
                    const adj_t = self.time - fall_start;
                    const dy = (gravity / 2) * std.math.pow(f64, adj_t, 2);
                    const init_fall_pos = self.init_pos.add(mvec.getUnitVec().smul(speed * fall_start));
                    return MoveResult{
                        .remaining_dt = 0,
                        .grounded = false,
                        .move_complete = false,
                        .new_pos = init_fall_pos.add(mvec.getUnitVec().smul(fall_walk_v * (self.time - fall_start)).add(V3f.new(0, dy, 0))),
                    };
                }
            },
            .gap => {
                //if (mvec.magnitude() != 1) unreachable; //Only allow jumps in cardinal directions for now
                //Once we have reached dy = +1 we don't worry about colliding with the block we are jumping on.
                const at_y1_time = quadFL(gravity / 2, jumpV, -iv.y) orelse unreachable;
                const jump_end_time = quadFR(gravity / 2, jumpV, -iv.y) orelse unreachable;
                const lt_y1_v = if (at_y1_time == 0) 0 else (0.5 - (PlayerBounds / 2)) / at_y1_time;
                const gt_y1_v = (0.5 + (PlayerBounds / 2)) / (jump_end_time - at_y1_time);
                const at_y1_pos = self.init_pos.add(mvec.getUnitVec().smul(lt_y1_v * at_y1_time));
                const max_t = jump_end_time;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos };
                }

                self.time += dt;
                const dy = (gravity / 2) * std.math.pow(f64, self.time, 2) + (jumpV * self.time);
                if (self.time < at_y1_time and at_y1_time != 0) {
                    return MoveResult{
                        .remaining_dt = 0,
                        .grounded = false,
                        .move_complete = false,
                        .new_pos = self.init_pos.add(mvec.getUnitVec().smul(lt_y1_v * self.time).add(V3f.new(0, dy, 0))),
                    };
                } else if (self.time <= jump_end_time) {
                    return MoveResult{
                        .remaining_dt = 0,
                        .grounded = false,
                        .move_complete = false,
                        .new_pos = at_y1_pos.add(mvec.getUnitVec().smul(gt_y1_v * (self.time - at_y1_time)).add(V3f.new(0, dy, 0))),
                    };
                }
            },
            .ladder => {},
        }
        unreachable;
    }

    pub fn init(initp: V3f, final: V3f, dt: f64, move_type: astar.AStarContext.Node.Ntype) Self {
        return .{ .init_pos = initp, .final_pos = final, .time = dt, .move_type = move_type };
    }

    pub fn ladder(self: *Self, climb_speed: f64, dt: f64) MoveResult {
        const iv = self.final_pos.subtract(self.init_pos);
        if (iv.x != 0 or iv.z != 0) unreachable;

        const max_t = @fabs(iv.y / climb_speed);
        if (self.time + dt > max_t) {
            const r = (self.time + dt) - max_t;
            self.time = max_t;
            return MoveResult{
                .remaining_dt = r,
                .move_complete = true,
                .new_pos = self.final_pos,
            };
        }

        self.time += dt;
        return MoveResult{
            .remaining_dt = 0,
            .move_complete = false,
            .new_pos = self.init_pos.add(V3f.new(0, self.time * climb_speed * if (iv.y < 0) @as(f64, -1.0) else @as(f64, 1.0), 0)),
        };
    }

    pub fn gap(self: *Self, dt: f64) MoveResult {
        const G = 16;
        const V = 9;
        const end_of_jump_t = comptime quadFLess(-G, V, 0) orelse unreachable;

        const mvec = self.final_pos.subtract(self.init_pos);
        const walk_vec = V3f.new(mvec.x, 0, mvec.z);

        if (self.time + dt > end_of_jump_t) {
            var d = self.final_pos;

            return MoveResult{ .remaining_dt = 0, .move_complete = true, .grounded = true, .new_pos = d };
        }

        self.time += dt;
        const y = (-G * std.math.pow(f64, self.time, 2)) + (V * self.time);
        var d = self.init_pos.add(walk_vec.smul(self.time / end_of_jump_t));
        d.y = self.init_pos.y + y;

        return MoveResult{
            .remaining_dt = 0,
            .move_complete = false,
            .grounded = false,
            .new_pos = d,
        };
    }
};

pub const Inventory = struct {
    const Self = @This();
    slots: std.ArrayList(?mc.Slot),
    win_id: ?u8 = null,
    state_id: i32 = 0,
    win_type: u32 = 0,

    alloc: std.mem.Allocator,

    pub fn setSize(self: *Self, size: u32) !void {
        for (self.slots.items) |optslot| {
            if (optslot) |slot| {
                if (slot.nbt_buffer) |buf| {
                    self.alloc.free(buf);
                }
            }
        }
        try self.slots.resize(size);
    }

    pub fn setSlot(self: *Self, index: u32, slot: ?mc.Slot) !void {
        //if (self.slots.items[index] != null) return error.slotNotCleared;
        self.slots.items[index] = slot;
        if (slot) |*s| {
            if (s.nbt_buffer) |buf| {
                self.slots.items[index].?.nbt_buffer = try self.alloc.alloc(u8, buf.len);
                std.mem.copy(u8, self.slots.items[index].?.nbt_buffer.?, buf);
            }
        }
    }

    pub fn init(alloc: std.mem.Allocator) Inventory {
        return .{ .slots = std.ArrayList(?mc.Slot).init(alloc), .alloc = alloc };
    }
    pub fn deinit(self: *@This()) void {
        for (self.slots.items) |*slot| {
            if (slot.nbt_buffer) |buf| {
                self.alloc.free(buf);
            }
        }
        self.slots.deinit();
    }
};

//Stores info about a specific bot/player
//Not a client as chunk data etc can be shaerd between Bots
pub const Bot = struct {
    const Self = @This();

    move_state: MovementState = undefined,
    view_dist: u8 = 2,
    handshake_complete: bool = false,
    compression_threshold: i32 = -1,
    connection_state: enum { play, login, none } = .none,
    name: []const u8,
    health: f32 = 20,
    food: u8 = 20,
    food_saturation: f32 = 5,
    pos: ?V3f = null,
    e_id: u32,

    fd: i32 = 0,

    modify_mutex: std.Thread.Mutex = .{},
    fd_mutex: std.Thread.Mutex = .{},
    action_list: std.ArrayList(astar.AStarContext.PlayerActionItem),
    action_index: ?usize = null,

    held_item: ?mc.Slot = null,
    inventory: [46]?mc.Slot = [_]?mc.Slot{null} ** 46,
    selected_slot: u8 = 0,
    container_state: i32 = 0,

    interacted_inventory: Inventory,

    pub fn init(alloc: std.mem.Allocator, name_: []const u8) Bot {
        return Bot{
            .name = name_,
            .e_id = 0,
            .action_list = std.ArrayList(astar.AStarContext.PlayerActionItem).init(alloc),
            .interacted_inventory = Inventory.init(alloc),
        };
    }

    pub fn nextAction(self: *Self, init_dt: f64) void {
        if (self.action_index == null)
            return;
        self.action_index = if (self.action_index.? == 0) null else self.action_index.? - 1;
        if (self.action_index) |act| {
            switch (self.action_list.items[act]) {
                .movement => |mov| {
                    self.move_state = MovementState.init(self.pos.?, mov.pos, init_dt, mov.kind);
                },
                else => {},
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.action_list.deinit();
        self.interacted_inventory.deinit();
    }
};
