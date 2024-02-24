const std = @import("std");
const vector = @import("vector.zig");
const V3i = vector.V3i;
const V3f = vector.V3f;
const nbt_zig = @import("nbt.zig");

pub const ParseTypes = union(enum) {
    const boolean = bool;
    const byte = i8;
    const ubyte = u8;
    const short = i16;
    const ushort = u16;
    const varInt = i32;
    const long = i64;
};

//Defines names of types we can parse, the .Type indicates what this field will be in the returned struct
const TypeItem = struct { name: []const u8, Type: type };
pub const TypeList = [_]TypeItem{
    .{ .name = "boolean", .Type = bool },

    .{ .name = "long", .Type = i64 },
    .{ .name = "byte", .Type = i8 },
    .{ .name = "ubyte", .Type = u8 },
    .{ .name = "short", .Type = i16 },
    .{ .name = "ushort", .Type = u16 },
    .{ .name = "int", .Type = i32 },
    .{ .name = "uuid", .Type = u128 },

    .{ .name = "string", .Type = []const u8 },
    .{ .name = "chat", .Type = []const u8 },
    .{ .name = "identifier", .Type = []const u8 },

    .{ .name = "float", .Type = f32 },
    .{ .name = "double", .Type = f64 },

    .{ .name = "varInt", .Type = i32 },
    .{ .name = "varLong", .Type = i64 },

    .{ .name = "entityMetadata", .Type = u0 },
    .{ .name = "slot", .Type = u0 },
    .{ .name = "nbtTag", .Type = u0 },

    .{ .name = "position", .Type = V3i },
    .{ .name = "angle", .Type = f32 },

    .{ .name = "V3f", .Type = V3f },
    .{ .name = "shortV3i", .Type = vector.shortV3i },

    .{ .name = "stringList", .Type = [][]const u8 },
};

//Generate an enum where the enum values map to the original list so types can be retrieved,
//needed instead of a union so that instatiation is not needed when specifing a struct by listing fields, see fn parseType
fn genTypeListEnum(comptime list: []const TypeItem) type {
    var enum_fields: [list.len]std.builtin.Type.EnumField = undefined;
    for (list, 0..) |it, i| {
        enum_fields[i] = .{ .name = it.name, .value = i };
    }
    return @Type(std.builtin.Type{
        .Enum = .{
            .tag_type = usize,
            .fields = &enum_fields,
            .is_exhaustive = true,
            .decls = &.{},
        },
    });
}

pub const Types = genTypeListEnum(&TypeList);

pub const ParseItem = struct {
    type_: Types,
    name: []const u8,
};

pub fn P(comptime type_: Types, comptime name: []const u8) ParseItem {
    return .{ .type_ = type_, .name = name };
}

const parseTypeReturnType = struct { t: type, list: []const ParseItem };
pub fn parseType(comptime parse_items: []const ParseItem) parseTypeReturnType {
    var struct_fields: [parse_items.len]std.builtin.Type.StructField = undefined;
    for (parse_items, 0..) |item, i| {
        struct_fields[i] = .{
            .name = item.name,
            .type = TypeList[@intFromEnum(item.type_)].Type,
            .is_comptime = false,
            .default_value = null,
            .alignment = 0,
        };
    }
    return .{ .t = @Type(std.builtin.Type{
        .Struct = .{
            .layout = .Auto,
            .backing_integer = null,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    }), .list = parse_items };
}

pub fn readVarInt(reader: anytype) i32 {
    const CONT: u32 = 0x80;
    const SEG: u32 = 0x7f;

    var value: u32 = 0;
    var pos: u8 = 0;
    var current_byte: u8 = 0;

    while (true) {
        current_byte = reader.readByte() catch unreachable;
        value |= @as(u32, @intCast(current_byte & SEG)) << @as(u5, @intCast(pos));
        if ((current_byte & CONT) == 0) break;
        pos += 7;
        if (pos >= 32) unreachable;
    }

    return @as(i32, @bitCast(value));
}

pub fn packetParseCtx(comptime readerT: type) type {
    return struct {
        const Self = @This();

        //This structure makes no attempt to keep track of memory it allocates, as much of what is parsed is
        //garbage
        //use an arena allocator and copy over values that you need
        //TODO internally use an arena
        pub fn init(reader: readerT, alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .reader = reader,
            };
        }

        fn float(self: *Self, comptime fT: type) fT {
            if (fT == f32) {
                return @as(f32, @bitCast(self.int(u32)));
            }
            if (fT == f64) {
                return @as(f64, @bitCast(self.int(u64)));
            }
            unreachable;
        }

        fn position(self: *Self) vector.V3i {
            const pos = self.int(i64);
            return .{
                .x = @as(i32, @intCast(pos >> 38)),
                .y = @as(i32, @intCast(pos << 52 >> 52)),
                .z = @as(i32, @intCast(pos << 26 >> 38)),
            };
        }

        fn v3f(self: *Self) V3f {
            return .{
                .x = self.float(f64),
                .y = self.float(f64),
                .z = self.float(f64),
            };
        }

        fn int(self: *Self, comptime intT: type) intT {
            return self.reader.readInt(intT, .Big) catch unreachable;
        }

        fn string(self: *Self) ![]const u8 {
            const len = @as(u32, @intCast(readVarInt(self.reader)));
            const slice = try self.alloc.alloc(u8, len);
            try self.reader.readNoEof(slice);
            return slice;
        }

        pub fn parse(self: *Self, comptime p_type: parseTypeReturnType) p_type.t {
            const r = self.reader;
            var ret: p_type.t = undefined;
            const info = @typeInfo(p_type.t).Struct.fields;
            inline for (p_type.list, 0..) |item, i| {
                @field(ret, info[i].name) = blk: {
                    switch (item.type_) {
                        .long, .byte, .ubyte, .short, .ushort, .int, .uuid => {
                            break :blk self.reader.readInt(info[i].type, .Big) catch unreachable;
                        },
                        .boolean => break :blk (r.readInt(u8, .Big) catch unreachable == 0x1),
                        .string, .chat, .identifier => break :blk self.string() catch unreachable,
                        .float, .double => break :blk self.float(info[i].type),
                        .varInt => break :blk readVarInt(r),
                        .position => break :blk self.position,
                        .V3f => break :blk self.v3f(),
                        .angle => break :blk @as(f32, @floatFromInt(self.int(u8))) / (256.0 / 360.0),
                        .shortV3i => {
                            break :blk .{
                                .x = self.int(i16),
                                .y = self.int(i16),
                                .z = self.int(i16),
                            };
                        },

                        .stringList => {
                            const len = readVarInt(r);
                            var strs = self.alloc.alloc([]const u8, @as(u32, @intCast(len))) catch unreachable;
                            var n: u32 = 0;
                            while (n < len) : (n += 1) {
                                strs[n] = self.string() catch unreachable;
                            }
                            break :blk strs;
                        },
                        .nbtTag => {
                            const nbt = nbt_zig.parse(self.alloc, r) catch unreachable;
                            _ = nbt;
                            break :blk 0;
                        },
                        else => {
                            std.debug.print("{}\n", .{item.type_});
                            @compileError("Type not supported");
                        },
                    }
                };
            }
            return ret;
        }

        reader: readerT,
        alloc: std.mem.Allocator,
    };
}

const fbsT = std.io.FixedBufferStream([]const u8);
const rT = fbsT.Reader;

test "basic usage" {
    const buffer = &.{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    var fbs = fbsT{ .buffer = buffer, .pos = 0 };
    const PT = packetParseCtx(rT);
    std.debug.print("ff\n", .{});
    var parsectx = PT.init(fbs.reader(), std.testing.allocator);
    //const t = parseType(&.{.{ .type_ = i64, .name = "keep_alive_id" }});
    //const t = parseType(&.{P(i64, "keep_alive_id")});

    const data = parsectx.parse(
        parseType(&.{P(i64, "keep_alive_id")}),
    );
    std.debug.print("{}\n", .{data});

    //const res = parsectx.parse(Keep_Alive);
}
