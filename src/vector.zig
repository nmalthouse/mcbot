const std = @import("std");
const math = std.math;

const c = @import("c.zig").c;

pub fn Ivec(comptime itype: type) type {
    return struct {
        const Self = @This();
        x: itype,
        y: itype,
        z: itype,

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
        .x = (((d.x / 128) + (32 * x0.x)) / 32),
        .y = (((d.y / 128) + (32 * x0.y)) / 32),
        .z = (((d.z / 128) + (32 * x0.z)) / 32),
    };
}

//pub const V3i = struct {
//    const Self = @This();
//    x: i32,
//    y: i32,
//    z: i32,
//
//    pub fn new(x: i32, y: i32, z: i32) Self {
//        return Self{
//            .x = x,
//            .y = y,
//            .z = z,
//        };
//    }
//
//    pub fn add(a: Self, b: Self) Self {
//        return Self.new(a.x + b.x, a.y + b.y, a.z + b.z);
//    }
//};

pub const V2i = struct {
    x: i32,
    y: i32,
};

pub const V3f = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn toI(a: @This()) V3i {
        return .{
            .x = @as(i32, @intFromFloat(a.x)),
            .y = @as(i32, @intFromFloat(a.y)),
            .z = @as(i32, @intFromFloat(a.z)),
        };
    }

    pub fn new(x_: f64, y_: f64, z_: f64) @This() {
        return .{ .x = x_, .y = y_, .z = z_ };
    }

    pub fn newi(x_: i64, y_: i64, z_: i64) @This() {
        return .{
            .x = @as(f64, @floatFromInt(x_)),
            .y = @as(f64, @floatFromInt(y_)),
            .z = @as(f64, @floatFromInt(z_)),
        };
    }

    pub fn toRay(a: @This()) c.Vector3 {
        return .{
            .x = @as(f32, @floatCast(a.x)),
            .y = @as(f32, @floatCast(a.y)),
            .z = @as(f32, @floatCast(a.z)),
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
