const std = @import("std");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const mc = @import("listener.zig");
const astar = @import("astar.zig");
const RegD = @import("data_reg.zig");
const Proto = @import("protocol.zig");
const Reg = RegD.DataReg;
const log = std.log.scoped(.bot);

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

    pub const MoveError = error{
        quadf,
        missingReturn,
        ladderHasLateralMovement,
        moveTypeBlocked,
    };

    init_pos: V3f,
    final_pos: V3f,
    time: f64,

    move_type: astar.AStarContext.Node.Ntype,

    pub fn update(self: *Self, dt: f64) MoveError!MoveResult {
        const speed = 4.37;
        const iv = self.final_pos.subtract(self.init_pos);
        const mvec = V3f.new(iv.x, 0, iv.z);
        switch (self.move_type) {
            .blocked => return error.moveTypeBlocked,
            .freemove => {
                const max_t = iv.magnitude() / speed;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos, .grounded = false };
                }
                self.time += dt;
                return MoveResult{
                    .remaining_dt = 0,
                    .grounded = false,
                    .move_complete = false,
                    .new_pos = self.init_pos.add(iv.getUnitVec().smul(speed * self.time)),
                };
            },
            .walk => {
                const max_t = mvec.magnitude() / speed;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos };
                }

                self.time += dt;

                return MoveResult{
                    .remaining_dt = 0,
                    .move_complete = false,
                    .new_pos = self.init_pos.add(mvec.getUnitVec().smul(speed * self.time)),
                };
            },
            .jump => {
                //Once we have reached dy = +1 we don't worry about colliding with the block we are jumping on.
                const at_y1_time = quadFL(gravity / 2, jumpV, -1) orelse return error.quadf;
                const jump_end_time = quadFR(gravity / 2, jumpV, -1) orelse return error.quadf;
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
                const fall_time = quadFR(gravity / 2, 0, @abs(iv.y)) orelse return error.quadf;
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
                //Once we have reached dy = +1 we don't worry about colliding with the block we are jumping on.
                const land_time = quadFR(gravity / 2, jumpV, 0) orelse return error.quadf;
                const max_t = land_time;
                const xz_speed = mvec.magnitude() / land_time;

                if (max_t < self.time + dt) {
                    const r = (self.time + dt) - max_t;
                    self.time = max_t;
                    return MoveResult{ .remaining_dt = r, .move_complete = true, .new_pos = self.final_pos };
                }
                self.time += dt;

                const dy = (gravity / 2) * std.math.pow(f64, self.time, 2) + (jumpV * self.time);
                const dx = mvec.getUnitVec().smul(xz_speed * self.time);
                return MoveResult{
                    .remaining_dt = 0,
                    .grounded = false,
                    .move_complete = false,
                    .new_pos = self.init_pos.add(dx).add(V3f.new(0, dy, 0)),
                };
            },
            .ladder => {
                const climb_speed = 3;
                if (mvec.magnitude() != 0) return error.ladderHasLateralMovement; //we can only climb up or down
                const max_t = @abs(iv.y) / climb_speed;
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
                    .new_pos = self.init_pos.add(V3f.new(0, iv.y, 0).getUnitVec().smul(climb_speed * self.time)),
                };
            },
        }
        return error.missingReturn;
    }

    pub fn init(initp: V3f, final: V3f, dt: f64, move_type: astar.AStarContext.Node.Ntype) Self {
        return .{ .init_pos = initp, .final_pos = final, .time = dt, .move_type = move_type };
    }
};

pub const Inventory = struct {
    const Self = @This();
    pub const FoundSlot = struct { slot: mc.Slot, index: u16 };
    slots: std.ArrayList(mc.Slot),
    win_id: ?u8 = null,
    win_type: u32 = 0,

    alloc: std.mem.Allocator,

    pub fn setSize(self: *Self, size: u32) !void {
        try self.slots.resize(size);
        for (self.slots.items) |*item| {
            item.count = 0; //Mark as empty slot
        }
    }

    pub fn getCount(self: *Self, item: RegD.ItemId) usize {
        var total: usize = 0;
        for (self.slots.items) |it| {
            if (it.count > 0 and it.item_id == item)
                total += it.count;
        }
        return total;
    }

    pub fn setSlot(self: *Self, index: u32, slot: mc.Slot) !void {
        self.slots.items[index] = slot;
    }

    pub fn findItem(self: *Self, reg: *const Reg, item_name: []const u8) ?FoundSlot {
        const q = reg.getItemFromName(item_name) orelse return null;
        return self.findItemFromId(q.id);
    }

    pub fn findItemFromId(self: *Self, item_id: RegD.ItemId) ?FoundSlot {
        for (self.slots.items, 0..) |slot, i| {
            if (slot.count > 0) {
                if (slot.item_id == item_id)
                    return .{ .slot = slot, .index = @intCast(i) };
            }
        }
        return null;
    }

    pub fn findItemFromList(self: *Self, list: anytype, comptime list_field_name: ?[]const u8) ?FoundSlot {
        for (self.slots.items, 0..) |slot, si| {
            for (list) |li| {
                if (slot.count > 0) {
                    const id: RegD.ItemId = if (list_field_name) |lf| @field(li, lf) else li;
                    if (slot.item_id == id)
                        return .{ .slot = slot, .index = @intCast(si) };
                }
            }
        }
        return null;
    }

    pub fn findItemWithTag(self: *Self, tag_table: *const mc.TagRegistry, item_tag: []const u8) ?FoundSlot {
        for (self.slots.items, 0..) |slot, si| {
            if (slot.count > 0) {
                if (tag_table.hasTag(slot.item_id, "minecraft:item", item_tag))
                    return .{ .slot = slot, .index = @intCast(si) };
            }
        }
        return null;
    }

    pub fn findToolForMaterial(self: *Self, reg: *const Reg, material: []const u8) ?struct { slot_index: u16, mul: f32 } {
        const matching_item_ids = reg.getMaterial(material) orelse {
            log.err("invalid material {s}", .{material});
            return null;
        };
        for (self.slots.items, 0..) |slot, i| {
            for (matching_item_ids) |id| {
                if (slot.count > 0 and id.id == slot.item_id) {
                    return .{ .slot_index = @intCast(i), .mul = id.mul };
                }
            }
        }
        return null;
    }
    //pub fn findItemMatching(self: *Self)void{ }

    pub fn init(alloc: std.mem.Allocator) Inventory {
        return .{ .slots = std.ArrayList(mc.Slot).init(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *@This()) void {
        self.slots.deinit();
    }
};

pub const BotScriptThreadData = struct {
    const Self = @This();
    pub const ErrorMsg = struct {
        code: []const u8,
        msg: []const u8,
    };
    pub const ThreadStatus = enum {
        waiting_for_ready,
        terminated_waiting_for_restart,
        terminated,
        crashed,
        running,
    };
    //TODO put a mutex for status
    error_: ?ErrorMsg = null, //not allocated
    status: ThreadStatus = .waiting_for_ready,
    status_mutex: std.Thread.Mutex,

    ///These actions are evaluated in reverse
    actions: std.ArrayList(astar.AStarContext.PlayerActionItem),
    action_index: ?usize = null,
    move_state: MovementState = undefined,
    timer: ?f64 = null,
    break_timer_max: f64 = 0,
    craft_item_counter: ?usize = null, //used to throttle inventory interaction
    //
    exit_mutex: std.Thread.Mutex, // If the script thread can lock this it should exit.
    reload_mutex: std.Thread.Mutex, // If the script thread should lock this it should exit and set status to terminated_w

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .exit_mutex = .{},
            .status_mutex = .{},
            .reload_mutex = .{},
            .actions = std.ArrayList(astar.AStarContext.PlayerActionItem).init(alloc),
        };
    }

    pub fn getStatus(self: *Self) ThreadStatus {
        self.status_mutex.lock();
        defer self.status_mutex.unlock();
        return self.status;
    }
    pub fn setStatus(self: *Self, new_status: ThreadStatus) void {
        self.status_mutex.lock();
        self.status = new_status;
        self.status_mutex.unlock();
    }

    //Assumes mutex is owned, strings in err are never freed so allocate as such
    pub fn setError(self: *Self, err: ErrorMsg) void {
        self.error_ = err;
    }

    pub fn deinit(self: *Self) void {
        for (self.actions.items) |*acc|
            acc.deinit();
        self.actions.deinit();
    }

    pub fn nextAction(self: *Self, init_dt: f64, pos: V3f) void {
        self.timer = null;
        self.craft_item_counter = null;
        if (self.action_index == null)
            return;
        self.action_index = if (self.action_index.? == 0) null else self.action_index.? - 1;
        if (self.action_index) |act| {
            switch (self.actions.items[act]) {
                .movement => |mov| {
                    // Should we check if the move is possible?
                    // We need a world ptr
                    // Should we append actions to remedy the blockage?
                    self.move_state = MovementState.init(pos, mov.pos, init_dt, mov.kind);
                },
                else => {},
            }
        }
    }

    pub fn clearActions(self: *Self) !void {
        self.action_index = null;
        for (self.actions.items) |*item|
            item.deinit();
        try self.actions.resize(0);
    }

    pub fn setActions(self: *Self, new_list: std.ArrayList(astar.AStarContext.PlayerActionItem), pos: V3f) void {
        for (self.actions.items) |*acc|
            acc.deinit();
        self.actions.deinit();
        self.actions = new_list;
        self.action_index = new_list.items.len;
        if (new_list.items.len == 0)
            self.action_index = null;
        self.nextAction(0, pos);
    }

    pub fn setActionSlice(self: *Self, alloc: std.mem.Allocator, new: []const astar.AStarContext.PlayerActionItem, pos: V3f) !void {
        var new_s = std.ArrayList(astar.AStarContext.PlayerActionItem).init(alloc);
        try new_s.appendSlice(new);
        self.setActions(new_s, pos);
    }
};

//Stores info about a specific bot/player
//Not a client as chunk data etc can be shaerd between Bots
pub const Bot = struct {
    const Self = @This();
    const Effect = struct {
        ticks: i64,
        amplifier: i64,
    };
    init_status: struct { //Used to determine when updateBots can begin processing
        has_inv: bool = false,
        has_login: bool = false,
    } = .{},

    move_state: MovementState = undefined,
    view_dist: u8 = 2,
    handshake_complete: bool = false,
    compression_threshold: i32 = -1,
    connection_state: enum { play, login, config, none } = .none,
    script_filename: ?[]const u8 = null,
    uuid: u128 = 0,
    name: []const u8,
    health: f32 = 20,
    food: u8 = 20,
    food_saturation: f32 = 5,
    pos: ?V3f = null,
    e_id: u32,
    dimension_id: i32 = 0,

    chunk_batch_info: struct {
        start_time: i64 = 0,
        end_time: i64 = 0,
    } = .{},

    /// This field is used as an index into bot bitsets. See Entity.owners
    index_id: u32 = 0,

    fd: i32 = 0,

    modify_mutex: std.Thread.Mutex = .{},
    fd_mutex: std.Thread.Mutex = .{},
    //This is only used for draw thread
    action_list: std.ArrayList(astar.AStarContext.PlayerActionItem),
    action_index: ?usize = null,

    held_item: ?mc.Slot = null,
    inventory: Inventory,
    selected_slot: u8 = 0,

    interacted_inventory: Inventory,
    container_state: i32 = 0,

    effects: std.AutoHashMap(Proto.EffectEnum, Effect),

    alloc: std.mem.Allocator,

    th_d: BotScriptThreadData,

    pub fn init(alloc: std.mem.Allocator, name_: []const u8, script_name: ?[]const u8) !Bot {
        var inv = Inventory.init(alloc);
        try inv.setSize(46);
        return Bot{
            .alloc = alloc,
            .inventory = inv,
            .effects = std.AutoHashMap(Proto.EffectEnum, Effect).init(alloc),
            .script_filename = if (script_name) |sn| try alloc.dupe(u8, sn) else null,
            .name = try alloc.dupe(u8, name_),
            .e_id = 0,
            .th_d = BotScriptThreadData.init(alloc),
            .action_list = std.ArrayList(astar.AStarContext.PlayerActionItem).init(alloc),
            .interacted_inventory = Inventory.init(alloc),
        };
    }

    //Assumes lock is held
    pub fn getPos(self: *const Self) V3f {
        if (self.pos == null) {
            log.err("Pos accessed before being set.", .{});
            return .{ .x = 0, .y = 0, .z = 0 };
        }
        return self.pos.?;
    }

    //TODO Remove this duplicate

    pub fn isReady(self: *Self) bool {
        const i = self.init_status;
        return i.has_inv and i.has_login;
    }

    pub fn getEffect(self: *Self, id: Proto.EffectEnum) i64 {
        if (self.effects.get(id)) |ef| {
            if (ef.ticks > 0)
                return ef.amplifier + 1;
        }
        return 0;
    }

    pub fn removeEffect(self: *Self, id: Proto.EffectEnum) void {
        if (self.effects.getPtr(id)) |ef| {
            ef.ticks = 0;
        }
    }

    pub fn addEffect(self: *Self, id: Proto.EffectEnum, time: i64, amplifier: i64) !void {
        try self.effects.put(id, .{ .ticks = time, .amplifier = amplifier });
    }

    pub fn update(self: *Self, dt: f64, tick_count: i64) void {
        _ = dt;
        var e_it = self.effects.iterator();
        while (e_it.next()) |e| {
            e.value_ptr.ticks = @min(0, e.value_ptr.ticks - tick_count);
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.script_filename) |sn| {
            self.alloc.free(sn);
        }
        self.alloc.free(self.name);
        for (self.action_list.items) |*item| {
            item.deinit();
        }
        self.action_list.deinit();
        self.th_d.deinit();
        self.effects.deinit();
        self.interacted_inventory.deinit();
        self.inventory.deinit();
    }
};
