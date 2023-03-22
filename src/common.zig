const std = @import("std");

pub fn readJsonFile(filename: []const u8, alloc: std.mem.Allocator, comptime T: type) !T {
    const cwd = std.fs.cwd();
    const f = cwd.openFile(filename, .{}) catch null;
    if (f) |cont| {
        var buf: []const u8 = try cont.readToEndAlloc(alloc, 1024 * 1024 * 1024);
        defer alloc.free(buf);

        var ts = std.json.TokenStream.init(buf);
        var ret = try std.json.parse(T, &ts, .{ .allocator = alloc });
        //defer std.json.parseFree(T, ret, .{ .allocator = alloc });
        return ret;
    }
    return error.fileNotFound;
}

pub fn freeJson(comptime T: type, alloc: std.mem.Allocator, item: T) void {
    std.json.parseFree(T, item, .{ .allocator = alloc });
}
