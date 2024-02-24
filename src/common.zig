const std = @import("std");
const J = std.json;

//pub fn readJsonFd(file: *const std.fs.File, alloc: std.mem.Allocator, comptime T: type) !T {
//    var buf: []const u8 = try file.readToEndAlloc(alloc, 1024 * 1024 * 1024);
//    defer alloc.free(buf);
//    var ts = std.json.TokenStream.init(buf);
//    var ret = try std.json.parse(T, &ts, .{ .allocator = alloc, .ignore_unknown_fields = true });
//    //defer std.json.parseFree(T, ret, .{ .allocator = alloc });
//    return ret;
//}
//
//pub fn readJsonFile(filename: []const u8, alloc: std.mem.Allocator, comptime T: type) !T {
//    const cwd = std.fs.cwd();
//    const f = cwd.openFile(filename, .{}) catch null;
//    if (f) |cont| {
//        var buf: []const u8 = try cont.readToEndAlloc(alloc, 1024 * 1024 * 1024);
//        defer alloc.free(buf);
//
//        var ts = std.json.TokenStream.init(buf);
//        var ret = try std.json.parse(T, &ts, .{ .allocator = alloc, .ignore_unknown_fields = true });
//        //defer std.json.parseFree(T, ret, .{ .allocator = alloc });
//        return ret;
//    }
//    return error.fileNotFound;
//}

///User must call deinit on returned object
pub fn readJson(dir: std.fs.Dir, filename: []const u8, alloc: std.mem.Allocator, comptime T: type) !J.Parsed(T) {
    var file = try dir.openFile(filename, .{});
    defer file.close();
    const slice = try file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);
    var parsed = try J.parseFromSlice(T, alloc, slice, .{ .ignore_unknown_fields = true });
    return parsed;
}

pub fn freeJson(comptime T: type, alloc: std.mem.Allocator, item: T) void {
    std.json.parseFree(T, item, .{ .allocator = alloc, .ignore_unknown_fields = true });
}
