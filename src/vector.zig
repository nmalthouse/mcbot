const std = @import("std");
const math = std.math;

const c = @import("c.zig").c;

pub const V3f = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn new(x_: f64, y_: f64, z_: f64) @This() {
        return .{ .x = x_, .y = y_, .z = z_ };
    }

    pub fn newi(x_: i64, y_: i64, z_: i64) @This() {
        return .{
            .x = @intToFloat(f64, x_),
            .y = @intToFloat(f64, y_),
            .z = @intToFloat(f64, z_),
        };
    }

    pub fn toRay(a: @This()) c.Vector3 {
        return .{
            .x = @floatCast(f32, a.x),
            .y = @floatCast(f32, a.y),
            .z = @floatCast(f32, a.z),
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
