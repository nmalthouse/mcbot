const std = @import("std");
const com = @import("common.zig");
const eql = std.mem.eql;
const mc = @import("listener.zig");
const Proto = @import("protocol.zig");

fn getVal(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) ?@TypeOf(@field(v, @tagName(tag))) {
    if (v == tag) {
        return @field(v, @tagName(tag));
    }
    return null;
}

fn getJObj(v: std.json.Value) !std.json.ObjectMap {
    const obj = switch (v) {
        .Object => |obj| obj,
        else => return error.invalidJson,
    };
    return obj;
}

//pub fn colonDelimHexToBytes(out: []u8, in: []const u8)![]u8{
//
//}
