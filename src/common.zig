const std = @import("std");
const J = std.json;

///User must call deinit on returned object
pub fn readJson(dir: std.fs.Dir, filename: []const u8, alloc: std.mem.Allocator, comptime T: type) !J.Parsed(T) {
    var file = try dir.openFile(filename, .{});
    defer file.close();
    const slice = try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);
    const parsed = try J.parseFromSlice(T, alloc, slice, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return parsed;
}

pub fn freeJson(comptime T: type, alloc: std.mem.Allocator, item: T) void {
    std.json.parseFree(T, item, .{ .allocator = alloc, .ignore_unknown_fields = true });
}
