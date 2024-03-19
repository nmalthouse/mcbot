const std = @import("std");
const strToEnum = std.meta.stringToEnum;
const FbsT = std.io.FixedBufferStream([]u8);
const JValue = std.json.Value;
const eql = std.mem.eql;
const Alloc = std.mem.Allocator;

fn getV(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) @TypeOf(@field(v, @tagName(tag))) {
    return getVal(v, tag) orelse unreachable;
}

fn getVal(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) ?@TypeOf(@field(v, @tagName(tag))) {
    if (v == tag) {
        return @field(v, @tagName(tag));
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    const output_file_path = args.next() orelse fatal("Needs output file argument", .{});

    const mc_version_string = args.next() orelse fatal("Needs mc version string", .{});
    var data_dir_name = std.ArrayList(u8).init(arena_alloc);
    try data_dir_name.appendSlice("minecraft-data/data/pc/");
    try data_dir_name.appendSlice(mc_version_string);

    const mc_data_dir = try std.fs.cwd().openDir(data_dir_name.items, .{});
    const file = try mc_data_dir.openFile("protocol.json", .{});
    defer file.close();
    const json_str = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(json_str);
    var vtree = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_str, .{});
    defer vtree.deinit();
    var root = getVal(vtree.value, .object) orelse return error.InvalidJson;

    var out = try std.fs.cwd().createFile(output_file_path, .{});
    defer out.close();
    const w = out.writer();
    try w.print("// THIS FILE IS AUTO GENERATED\n", .{});
    try w.print("pub const minecraftVersion = \"{s}\";", .{mc_version_string});

    //try w.print("{s}", .{@embedFile("datatype.zig")});

    try emitPacketEnum(&root, w, "play", "toClient", "Play_Clientbound");
    try emitPacketEnum(&root, w, "play", "toServer", "Play_Serverbound");
    try emitPacketEnum(&root, w, "handshaking", "toServer", "Handshake_Serverbound");
    try emitPacketEnum(&root, w, "handshaking", "toClient", "Handshake_Clientbound");
    try emitPacketEnum(&root, w, "login", "toClient", "Login_Clientbound");
    try emitPacketEnum(&root, w, "login", "toServer", "Login_Serverbound");
    //try emitPacketEnum(&root, w, "configuration", "toClient", "Config_Clientbound");
    //try emitPacketEnum(&root, w, "configuration", "toServer", "Config_Serverbound");
}

pub fn emitPacketEnum(root: *std.json.ObjectMap, writer: anytype, game_state: []const u8, direction: []const u8, enum_name: []const u8) !void {
    const play = (getV(root.get(game_state) orelse unreachable, .object));
    const playToClientTypes = getV((getV(play.get(direction) orelse unreachable, .object)).get("types") orelse unreachable, .object);
    const map = getV(getV(getV(getV(getV(getV(playToClientTypes.get("packet") orelse unreachable, .array).items[1], .array).items[0], .object).get("type") orelse unreachable, .array).items[1], .object).get("mappings") orelse unreachable, .object);
    var mit = map.iterator();

    //try writer.print("pub const {s}_{s} = struct {{\n", .{ game_state, direction });
    try writer.print("pub const {s} = enum(i32) {{\n", .{enum_name});
    while (mit.next()) |m| {
        try writer.print("{s} = {s},\n", .{ getV(m.value_ptr.*, .string), m.key_ptr.* });
    }
    try writer.print("}};\n\n", .{});
    const write_types = false;

    if (write_types) {
        var p_it = playToClientTypes.iterator();
        var buf: [4096]u8 = undefined;
        while (p_it.next()) |p| {
            var fbs = FbsT{ .buffer = &buf, .pos = 0 };
            newGenType(p.value_ptr.*, fbs.writer()) catch
                {
                std.debug.print("Omitting {s}:{s} {s}\n", .{ game_state, direction, p.key_ptr.* });
                continue;
            };
            try writer.print("pub const {s} = ", .{p.key_ptr.*});

            try writer.print("{s}", .{fbs.getWritten()});
        }
    }
    //try writer.print("}};\n\n", .{});
}

const SupportedTypes = enum {
    container,
};

pub fn newGenType(v: std.json.Value, w: anytype) !void {
    switch (v) {
        .array => |a| {
            const t = strToEnum(SupportedTypes, getV(a.items[0], .string)) orelse return error.notSupported;
            switch (t) {
                .container => {
                    try w.print("[_]ParseItem{{\n", .{});
                    for (getV(a.items[1], .array).items) |item| {
                        const ob = getV(item, .object);
                        try w.print(".{{.name = \"{s}\",.type_ = ", .{getV(ob.get("name").?, .string)});

                        try newGenType(ob.get("type").?, w);
                    }
                    try w.print("}};\n", .{});
                },
            }
        },
        .string => |str| {
            try w.print("{s} }},\n", .{str});
        },
        else => return error.notSupported,
    }
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
