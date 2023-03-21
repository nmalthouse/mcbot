const std = @import("std");
const vector = @import("vector.zig");
const V3f = vector.V3f;
const mc = @import("listener.zig");

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

pub const MovementState = struct {
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

    //pub fn new(new_pos: )Self{

    //}

    pub fn walk(self: *Self, speed: f64, dt: f64) MoveResult {
        const iv = self.final_pos.subtract(self.init_pos);
        const mvec = V3f.new(iv.x, 0, iv.z);
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

    pub fn fall(self: *Self, speed: f64, dt: f64) MoveResult {
        const iv = self.final_pos.subtract(self.init_pos);
        const mvec = V3f.new(iv.x, 0, iv.z);
        const max_t = mvec.magnitude() / speed;
        const fall_dist = self.init_pos.y - self.final_pos.y;

        if (self.time + dt > max_t) {
            const max_ft = quadFLess(-16, 0, fall_dist) orelse unreachable;

            const fall_time = (self.time + dt) - max_t;
            if (fall_time > max_ft) {
                return MoveResult{
                    .remaining_dt = fall_time - max_ft,
                    .move_complete = true,
                    .new_pos = self.final_pos,
                };
            }
            self.time += dt;

            return MoveResult{
                .remaining_dt = 0,
                .move_complete = false,
                //.new_pos = V3f.new(self.final_pos.x, self.final_pos.y - ((-16 * fall_time) + 1), self.final_pos.z),
                .new_pos = self.final_pos.add(V3f.new(0, (-16 * std.math.pow(f64, fall_time, 2) + fall_dist), 0)),
                .grounded = true,
            };
        }

        self.time += dt;
        return MoveResult{
            .remaining_dt = 0,
            .move_complete = false,
            .new_pos = self.init_pos.add(mvec.getUnitVec().smul(speed * self.time)),
            .grounded = false,
        };
    }

    pub fn jump(self: *Self, speed: f64, dt: f64) MoveResult {
        const end_of_jump_t = comptime quadFGreater(-16, 9, -1) orelse unreachable; //Our player has gravity -16 m/s^2 and jumps with velocity 9m/s
        const mvec = self.final_pos.subtract(self.init_pos);
        const walk_vec = V3f.new(mvec.x, 0, mvec.z);

        if (self.time + dt > end_of_jump_t) {
            var d = self.init_pos.add(walk_vec.getUnitVec().smul(end_of_jump_t));
            d.y = self.final_pos.y;

            var ws = Self{ .init_pos = d, .final_pos = self.final_pos, .time = self.time - end_of_jump_t };
            const r = ws.walk(speed, dt);
            self.time += dt;
            return r;
        }

        self.time += dt;
        const y = (-16.0 * std.math.pow(f64, self.time, 2)) + (9 * self.time);
        var d = self.init_pos.add(walk_vec.getUnitVec().smul(1 * self.time));
        d.y = self.init_pos.y + y;

        return MoveResult{
            .remaining_dt = 0,
            .move_complete = false,
            .grounded = false,
            .new_pos = d,
        };
    }
};

//Stores info about a specific bot/player
//Not a client as chunk data etc can be shaerd between Bots
pub const Bot = struct {
    const Self = @This();

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

    inventory: [46]?mc.Slot = [_]?mc.Slot{null} ** 46,

    pub fn init(alloc: std.mem.Allocator, name_: []const u8) Bot {
        _ = alloc;
        return Bot{
            .name = name_,
            .e_id = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
