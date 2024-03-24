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

//var primitive_types =
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();
    //Protocol.json names their types differently, rather than change our codebase to use their names just map them for now.
    const em = "error.notImplemented";
    const types_map = [_]struct { []const u8, []const u8 }{
        .{ "varint", "i32" },
        .{ "vec3f64", "Vector.V3f" },
        .{ "UUID", "u128" },
        .{ "slot", em },
        .{ "entityMetadata", em },
        .{ "string", "[]const u8" },
        .{ "Vector", "@import(\"vector.zig\")" },
        .{ "position", "Vector.V3i" },
        .{ "optionalNbt", em },
        .{ "restBuffer", "[]const u8" },
        .{ "nbt", em },
        .{ "command_node", em },
        .{ "packedChunkPos", em },
        .{ "tags", em },
        //.{ "i8", "byte" },
        //.{ "u8", "ubyte" },
        //.{ "u16", "ushort" },
        //.{ "i16", "short" },
        //.{ "i32", "int" },
        //.{ "i64", "long" },
        //.{ "bool", "boolean" },
        //.{ "slot", "slot" },
    };

    //
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
    try w.print("// THIS FILE IS AUTO GENERATED BY protocol_gen.zig\n", .{});
    try w.print("const mc = @import(\"listener.zig\");\n", .{});
    try w.print("const ParseItem = mc.AutoParse.ParseItem;\n", .{});
    try w.print("const Pt = mc.AutoParse.parseType;\n", .{});
    try w.print("pub const minecraftVersion = \"{s}\";\n", .{mc_version_string});
    for (types_map) |t| {
        try w.print("const {s} = {s};\n", .{ t[0], t[1] });
    }

    //try w.print("{s}", .{@embedFile("datatype.zig")});

    try emitPacketEnum(arena_alloc, &root, w, "play", "toClient", "Play_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "play", "toServer", "Play_Serverbound");
    try emitPacketEnum(arena_alloc, &root, w, "handshaking", "toServer", "Handshake_Serverbound");
    try emitPacketEnum(arena_alloc, &root, w, "handshaking", "toClient", "Handshake_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "login", "toClient", "Login_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "login", "toServer", "Login_Serverbound");
    //try emitPacketEnum(&root, w, "configuration", "toClient", "Config_Clientbound");
    //try emitPacketEnum(&root, w, "configuration", "toServer", "Config_Serverbound");
}

pub fn emitPacketEnum(alloc: std.mem.Allocator, root: *std.json.ObjectMap, writer: anytype, game_state: []const u8, direction: []const u8, enum_name: []const u8) !void {
    const play = (getV(root.get(game_state) orelse unreachable, .object));
    const type_it = getV((getV(play.get(direction) orelse unreachable, .object)).get("types") orelse unreachable, .object);
    const map = getV(getV(getV(getV(getV(getV(type_it.get("packet") orelse unreachable, .array).items[1], .array).items[0], .object).get("type") orelse unreachable, .array).items[1], .object).get("mappings") orelse unreachable, .object);
    var mit = map.iterator();

    try writer.print("pub const {s} = enum(i32) {{\n", .{enum_name});
    while (mit.next()) |m| {
        try writer.print("{s} = {s},\n", .{ getV(m.value_ptr.*, .string), m.key_ptr.* });
    }
    const write_types = true;

    if (write_types) {
        str_w.reset();
        var parent = ParseStructGen.init(alloc);
        var p_it = type_it.iterator();
        while (p_it.next()) |p| {
            //const child = try parent.newDecl(p.key_ptr.*);
            newGenType(p.value_ptr.*, &parent, p.key_ptr.*, false, false) catch |err| {
                const last = parent.getLastDecl();
                last.unsupported = true;
                //parent.unsupported = true;
                std.debug.print("Omitting {s}:{s} {s} {any}\n", .{ game_state, direction, p.key_ptr.*, err });
                //try writer.print("pub const {s} = error.packetCannotBeAutoGenerated;\n", .{p.key_ptr.*});
                continue;
            };
            //try writer.print("pub const {s} = ", .{p.key_ptr.*});

            //try writer.print("{s}", .{fbs.getWritten()});
        }
        try writer.print("pub const packets = struct {{\n", .{});
        try parent.emit(writer, false);
        try writer.print("}};\n", .{});
    }
    try writer.print("}};\n\n", .{});
}

const SupportedTypes = enum {
    container,
    array,
    option,
};

// Handling array type
// for struct just []const child
// for fn first len = parse(countType)
// while(parse(arraychild

var strbuf: [10000]u8 = undefined;
var str_w = std.io.FixedBufferStream([]u8){ .buffer = &strbuf, .pos = 0 };

pub fn printString(comptime fmt: []const u8, args: anytype) ![]const u8 {
    const start = str_w.pos;
    try str_w.writer().print(fmt, args);
    return str_w.buffer[start..str_w.pos];
}

pub const ParseStructGen = struct {
    const Self = @This();
    pub const PType = union(enum) {
        primitive: []const u8, // all primitive types have a mc.parse_primitiveName() function
        compound: *const Decl,

        pub fn getIdentifier(self: @This()) []const u8 {
            return switch (self) {
                .primitive => |p| p,
                .compound => |co| co.name,
            };
        }
    };

    pub const Field = struct {
        name: []const u8,
        type: PType,
        optional: bool = false,
        //type_identifier: []const u8,
    };

    pub const Decl = struct {
        unsupported: bool = false,
        name: []const u8,
        d: union(enum) {
            _struct: ParseStructGen,
            _array: ParseStructGen,
            alias: []const u8,
            none: void,
        } = .none,
    };

    //unsupported: bool = false,
    fields: std.ArrayList(Field),
    decls: std.ArrayList(*Decl), //Pointer so we can store references to it
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .fields = std.ArrayList(Field).init(alloc),
            .decls = std.ArrayList(*Decl).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn getLastDecl(self: *Self) *Decl {
        return self.decls.items[self.decls.items.len - 1];
    }

    pub fn newDecl(self: *Self, name: []const u8) !*Decl {
        const new_decl = try self.alloc.create(Decl);
        new_decl.* = .{ .name = name };
        try self.decls.append(new_decl);
        return new_decl;
    }

    pub fn emit(self: *const Self, w: anytype, emit_fn_as_array: bool) !void {
        for (self.decls.items) |d| {
            if (d.unsupported) {
                //try w.print("pub const {s} = error.cannotBeAutoGenerated;\n", .{d.name});
                continue;
            }
            switch (d.d) {
                else => {},
                .alias => |a| {
                    try w.print("pub const {s} = {s};\n\n", .{ d.name, a });
                },
                ._array => |a| {
                    try w.print("pub const {s} = []struct{{\n", .{d.name});
                    try a.emit(w, true);
                    try w.print("}};\n\n", .{});
                },
                ._struct => |s| {
                    try w.print("pub const {s} = struct{{\n", .{d.name});
                    try s.emit(w, false);
                    try w.print("}};\n\n", .{});
                },
            }
        }
        for (self.decls.items) |d| {
            if (d.unsupported) {
                try w.print("pub const {s} = error.cannotBeAutoGenerated;\n", .{d.name});
            }
        }
        for (self.fields.items) |f| {
            if (f.optional) {
                try w.print("{s}: ?{s} = null,\n", .{ f.name, f.type.getIdentifier() });
            } else {
                try w.print("{s}: {s},\n", .{ f.name, f.type.getIdentifier() });
            }
        }
        try w.print("\npub fn parse(pctx:anytype)!@This() {{\n", .{});
        if (emit_fn_as_array) {
            try w.print("const item_count:usize = @intCast(try pctx.parse_varint());\n", .{});
            if (self.fields.items.len != 1) return error.invalidArrayStructure;
            const item_field = self.fields.items[0];
            const child_name = item_field.type.getIdentifier();
            try w.print("const array = try pctx.alloc.alloc({s}, item_count);\n", .{child_name});
            try w.print("for(0..item_count)|i|{{\narray[i] = try {s}.parse(pctx);\n}}\n", .{child_name});

            try w.print("return array;\n", .{});
        } else {
            try w.print("var ret: @This() = undefined;\n", .{});
            var discard_pctx = true;
            for (self.fields.items) |f| {
                if (f.optional) {
                    try w.print("if(try pctx.parse_bool()){{\n", .{});
                }
                if (f.type == .primitive)
                    discard_pctx = false;
                switch (f.type) {
                    .primitive => |p| try w.print("ret.{s} = try pctx.parse_{s}();\n", .{ f.name, p }),
                    .compound => try w.print("ret.{s} = error.unsupported;\n", .{f.name}),
                }
                if (f.optional) {
                    try w.print("}}", .{});
                }
            }
            if (discard_pctx)
                try w.print("_ = pctx;\n", .{});
            try w.print("return ret;\n", .{});
        }
        try w.print("}}\n\n", .{});
    }
};

pub fn newGenType(v: std.json.Value, parent: *ParseStructGen, fname: []const u8, gen_fields: bool, optional: bool) !void {
    switch (v) {
        .array => |a| { //An array is some compound type definition
            const t = strToEnum(SupportedTypes, getV(a.items[0], .string)) orelse return error.notSupported;
            switch (t) {
                //For each field in container
                //create field with (name: "Type_" ++ name)
                .container => {
                    const Tname = try printString("Type_{s}", .{fname});

                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._struct = ParseStructGen.init(parent.alloc) };
                    const fields = getV(a.items[1], .array).items;
                    for (fields) |f| {
                        const ob = getV(f, .object);
                        const ident = getV(ob.get("name").?, .string);
                        const field_type = ob.get("type").?;
                        try newGenType(field_type, &child.d._struct, ident, true, false);
                        //    catch |err| {
                        //    std.debug.print("Omitting {s}:{s} {any}\n", .{ fname, ident, err });
                        //    child.d._struct.unsupported = true;
                        //    return;
                        //};
                    }
                    if (gen_fields)
                        try parent.fields.append(.{ .name = fname, .type = .{ .compound = child } });
                },
                .array => {
                    const array_def = getV(a.items[1], .object);
                    //crass
                    const count_type_str = getV(array_def.get("countType").?, .string);
                    const count_type = strToEnum(enum { varint }, count_type_str) orelse return error.invalidArrayCount;
                    _ = count_type;

                    const child_type = array_def.get("type").?;
                    const Tname = try printString("Array_{s}", .{fname});
                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._array = ParseStructGen.init(parent.alloc) };
                    try newGenType(child_type, &child.d._array, try printString("i_{s}", .{fname}), true, false);
                    try parent.fields.append(.{ .name = fname, .type = .{ .compound = child } });
                },
                .option => {
                    try newGenType(a.items[1], parent, fname, true, true);
                    // const Oname = try printString("Opt_{s}", .{fname});
                    // const child = try parent.newDecl(Oname);
                    // child.d = .{ ._struct = ParseStructGen.init(parent.alloc) };
                    // try newGenType(a.items[1], &child.d._struct, fname, true);
                    //try parent.fields.append(.{ .name = fname, .type = .{ .compound = child } });
                },
            }
        },
        .string => |str| { //A string is a literal type
            //return str;
            if (gen_fields) {
                try parent.fields.append(.{
                    .name = fname,
                    .optional = optional,
                    .type = .{ .primitive = str },
                });
            } else {
                const child = try parent.newDecl(try printString("Type_{s}", .{fname}));
                child.d = .{ .alias = str };
            }

            //return str;
            //try w.print("{s},\n", .{str});
            //try fw.print("try pctx.parse_{s}();\n", .{str});
        },
        else => return error.notSupported,
    }
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
