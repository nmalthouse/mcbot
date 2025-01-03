const std = @import("std");
const graph = @import("graph");
const Lua = graph.Lua;
const math = std.math;
//TODO delete all of this and use zalgebra's generic vector
//Same goes for ratgraph

pub fn Ivec(comptime itype: type) type {
    return struct {
        const Self = @This();
        x: itype,
        y: itype,
        z: itype,

        pub fn setLuaTable(L: Lua.Ls) void {
            V3f.setLuaTable(L);
        }

        pub fn new(x: itype, y: itype, z: itype) Self {
            return Self{
                .x = x,
                .y = y,
                .z = z,
            };
        }

        pub fn add(a: Self, b: Self) Self {
            return Self.new(a.x + b.x, a.y + b.y, a.z + b.z);
        }

        pub fn toF(a: Self) V3f {
            return .{
                .x = @as(f64, @floatFromInt(a.x)),
                .y = @as(f64, @floatFromInt(a.y)),
                .z = @as(f64, @floatFromInt(a.z)),
            };
        }
    };
}
pub const V3i = Ivec(i32);
pub const shortV3i = Ivec(i16);

pub fn deltaPosToV3f(x0: V3f, del: shortV3i) V3f {
    const d = del.toF();
    return .{
        .x = d.x / 4096 + x0.x,
        .y = d.y / 4096 + x0.y,
        .z = d.z / 4096 + x0.z,
    };
    //return .{ //Old 1.19.4
    //    .x = (((d.x / 128) + (32 * x0.x)) / 32),
    //    .y = (((d.y / 128) + (32 * x0.y)) / 32),
    //    .z = (((d.z / 128) + (32 * x0.z)) / 32),
    //};
}

pub const V2i = struct {
    x: i32,
    y: i32,
};

pub const V3f = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn setLuaTable(L: Lua.Ls) void {
        _ = Lua.c.lua_getglobal(L, Lua.zstring("Vec3"));
        Lua.c.lua_setfield(L, -2, "__index");
        _ = Lua.c.lua_getglobal(L, Lua.zstring("Vec3"));
        _ = Lua.c.lua_setmetatable(L, -2);
    }

    pub fn toI(a: @This()) V3i {
        return .{
            .x = @as(i32, @intFromFloat(a.x)),
            .y = @as(i32, @intFromFloat(a.y)),
            .z = @as(i32, @intFromFloat(a.z)),
        };
    }

    pub fn toIFloor(a: @This()) V3i {
        return .{
            .x = @as(i32, @intFromFloat(@floor(a.x))),
            .y = @as(i32, @intFromFloat(@floor(a.y))),
            .z = @as(i32, @intFromFloat(@floor(a.z))),
        };
    }

    pub fn new(x_: f64, y_: f64, z_: f64) @This() {
        return .{ .x = x_, .y = y_, .z = z_ };
    }

    pub fn fromZa(v: graph.za.Vec3) @This() {
        return new(v.x(), v.y(), v.z());
    }

    pub fn newi(x_: i64, y_: i64, z_: i64) @This() {
        return .{
            .x = @as(f64, @floatFromInt(x_)),
            .y = @as(f64, @floatFromInt(y_)),
            .z = @as(f64, @floatFromInt(z_)),
        };
    }

    pub fn toF32(self: @This()) struct { x: f32, y: f32, z: f32 } {
        return .{
            .x = @floatCast(self.x),
            .y = @floatCast(self.y),
            .z = @floatCast(self.z),
        };
    }

    pub fn magnitude(s: @This()) f64 {
        return math.sqrt(math.pow(f64, s.x, 2) +
            math.pow(f64, s.y, 2) +
            math.pow(f64, s.z, 2));
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    pub fn smul(s: @This(), scalar: f64) @This() {
        var r = s;
        r.x *= scalar;
        r.y *= scalar;
        r.z *= scalar;
        return r;
    }

    pub fn negate(s: @This()) @This() {
        return s.smul(-1);
    }

    pub fn subtract(a: @This(), b: @This()) @This() {
        return a.add(b.negate());
    }

    pub fn add(a: @This(), b: @This()) @This() {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn getUnitVec(v: @This()) @This() {
        return v.smul(1.0 / v.magnitude());
    }

    pub fn dot(v1: @This(), v2: @This()) f64 {
        return (v1.x * v2.x) + (v1.y * v2.y) + (v1.z * v2.z);
    }

    pub fn cross(a: @This(), b: @This()) @This() {
        return .{
            .x = (a.y * b.z - a.z * b.y),
            .y = -(a.x * b.z - a.z * b.x),
            .z = (a.x * b.y - a.y * b.x),
        };
    }
};
