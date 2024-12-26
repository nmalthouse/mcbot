const std = @import("std");
const strToEnum = std.meta.stringToEnum;
const FbsT = std.io.FixedBufferStream([]u8);
const JValue = std.json.Value;
const eql = std.mem.eql;
const Alloc = std.mem.Allocator;
const com = @import("common.zig");

fn getV(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) @TypeOf(@field(v, @tagName(tag))) {
    return getVal(v, tag) orelse unreachable;
}

fn getVE(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) !@TypeOf(@field(v, @tagName(tag))) {
    return getVal(v, tag) orelse {
        std.debug.print("Error with getVE\n", .{});
        return error.notSupported;
    };
}

fn getVal(v: std.json.Value, comptime tag: std.meta.Tag(std.json.Value)) ?@TypeOf(@field(v, @tagName(tag))) {
    if (v == tag) {
        return @field(v, @tagName(tag));
    }
    return null;
}

pub fn getDir(version_map: *const std.json.ArrayHashMap([]const u8), wanted_file: []const u8) !std.fs.Dir {
    const path = version_map.map.get(wanted_file) orelse {
        return error.cantFindDataMapping;
    };
    const mcdir = try std.fs.cwd().openDir("minecraft-data/data", .{});
    return try mcdir.openDir(path, .{});
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
        .{ "Vector", "@import(\"vector.zig\")" },
        .{ "PSend", "mc.Packet" },
        .{ "varint", "i32" },
        //.{ "vec3f64", "Vector.V3f" },
        .{ "UUID", "u128" },
        //.{ "Slot", "mc.Slot" },
        .{ "string", "[]const u8" },
        //.{ "position", "Vector.V3i" },
        .{ "restBuffer", "[]const u8" },
        .{ "nbt", "mc.nbt_zig.EntryWithName" },
        .{ "anonymousNbt", "mc.nbt_zig.Entry" },
        .{ "anonOptionalNbt", em },
        //.{ "particle", em },
        .{ "optionalNbt", em },
        //.{ "command_node", em },
        //.{ "packedChunkPos", em },
        //.{ "tags", em },
        //.{ "chunkBlockEntity", em },
        .{ "entityMetadata", em },
        //All that follow are for 1.21
        //.{ "ContainerID", "varint" },
        .{ "ByteArray", "[]const u8" }, //Wiki vg, parse this with varint as counter
        //.{ "Slot", "mc.Slot" },
        .{ "MovementFlags", "mc.MovementFlags" },
        //.{ "SpawnInfo", "Play_Clientbound.packets.Type_SpawnInfo" }, //Ugly
        //.{ "vec2f", "mc.Vec2f" },
        //.{ "Particle", em },
        //.{ "vec3f", "mc.V3f" },
        .{ "IDSet", em },
        //.{ "Type_PositionUpdateRelatives", "mc.PositionUpdateRelatives" },
        .{ "Type_IDSet", em },
        .{ "Type_tags", em },
        .{ "Type_string", "[]const u8" },
        .{ "Type_ByteArray", "[]const u8" },
        .{ "Type_entityMetadata", em },
        //.{ "Type_MovementFlags", em },
        .{ "Type_ingredient", em },
        .{ "Type_previousMessages", "Array_previousMessages" },
        //.{ "RecipeDisplay", em },
        //.{ "SlotDisplay", em },
        //.{ "ChatTypeParameterType", em },
        //.{ "ChatTypes", em },
    };

    const ddd = "error.protodefisdumb";
    const omit = "omit";
    const native_mapper = [_]struct { []const u8, []const u8 }{
        .{ "varint", "i32" },
        .{ "varlong", "i32" },
        .{ "restBuffer", "[]const u8" },
        .{ "UUID", "u128" },
        .{ "u8", "u8" },
        .{ "u16", "u16" },
        .{ "u32", "u32" },
        .{ "u64", "u64" },
        .{ "i8", "i8" },
        .{ "i16", "i16" },
        .{ "i32", "i32" },
        .{ "i64", "i64" },
        .{ "bool", "bool" },
        .{ "f32", "f32" },
        .{ "f64", "f64" },
        .{ "container", omit }, //You gotta love protodef
        .{ "switch", ddd },
        .{ "bitfield", ddd },
        .{ "void", ddd },
        .{ "array", ddd },
        .{ "bitflags", ddd },
        .{ "option", ddd },
        .{ "topBitSetTerminatedArray", ddd },
    };

    var native_map = std.StringHashMap([]const u8).init(alloc);
    defer native_map.deinit();
    for (native_mapper) |item| {
        try native_map.put(item[0], item[1]);
    }

    //
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    const output_file_path = args.next() orelse fatal("Needs output file argument", .{});

    const mc_version_string = args.next() orelse fatal("Needs mc version string", .{});

    const data_paths = try com.readJson(std.fs.cwd(), "minecraft-data/data/dataPaths.json", arena_alloc, struct {
        pc: std.json.ArrayHashMap(std.json.ArrayHashMap([]const u8)),
    });
    const version_map = data_paths.value.pc.map.get(mc_version_string) orelse fatal("can't find version in dataPaths.json, {s}", .{mc_version_string});

    const file = try (try getDir(&version_map, "protocol")).openFile("protocol.json", .{});
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
    try w.print("pub const minecraftVersion: []const u8 = \"{s}\";\n", .{mc_version_string});
    for (types_map) |t| {
        try w.print("const {s} = {s};\n", .{ t[0], t[1] });
    }

    //try w.print("{s}", .{@embedFile("datatype.zig")});
    { //TRY to emit all the stupid types

        //try w.print("pub const STUPID = struct{{\n", .{});
        const types = getV(root.get("types").?, .object);
        var p_it = types.iterator();
        var parent = ParseStructGen.init(arena_alloc);
        str_w.reset();
        while (p_it.next()) |ty| {
            switch (ty.value_ptr.*) {
                .string => |s| {
                    if (!std.mem.eql(u8, s, "native")) {
                        try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, s });
                    } else {
                        if (native_map.get(ty.key_ptr.*)) |has| {
                            if (std.mem.eql(u8, has, omit)) {
                                continue;
                            }
                            try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, has });
                        } else {
                            try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, em });
                        }
                    }
                },
                .array => {
                    newGenType(ty.value_ptr.*, &parent, ty.key_ptr.*, .{ .gen_fields = false, .optional = false }) catch |err| {
                        if (parent.decls.items.len > 0) {
                            const last = parent.getLastDecl();
                            last.unsupported = true;
                        }
                        std.debug.print("{any}\n", .{err});
                        //std.debug.print("Omitting {s}:{s} {s} {any}\n", .{ game_state, direction, p.key_ptr.*, err });
                        continue;
                    };
                },
                else => {
                    unreachable;
                },
            }
        }
        try parent.emit(
            w,
            .{ .none = {} },
            .recv,
        );
        //try w.print("}};\n", .{});
    }

    try emitPacketEnum(arena_alloc, &root, w, "play", "toClient", "Play_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "play", "toServer", "Play_Serverbound");
    try emitPacketEnum(arena_alloc, &root, w, "handshaking", "toServer", "Handshake_Serverbound");
    try emitPacketEnum(arena_alloc, &root, w, "handshaking", "toClient", "Handshake_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "login", "toClient", "Login_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "login", "toServer", "Login_Serverbound");
    try emitPacketEnum(arena_alloc, &root, w, "configuration", "toClient", "Config_Clientbound");
    try emitPacketEnum(arena_alloc, &root, w, "configuration", "toServer", "Config_Serverbound");

    { //Various enums
        var ents = try com.readJson(try getDir(&version_map, "entities"), "entities.json", alloc, []struct { id: u32, name: []const u8 });
        defer ents.deinit();

        try w.print("pub const EntityEnum = enum(i32){{\n", .{});
        for (ents.value) |v| {
            try w.print("{s} = {d},\n", .{ v.name, v.id });
        }
        try w.print("}};\n", .{});

        var effects = try com.readJson(try getDir(&version_map, "effects"), "effects.json", alloc, []struct { id: u32, name: []const u8 });
        defer effects.deinit();

        try w.print("pub const EffectEnum = enum(i32){{\n", .{});
        for (effects.value) |v| {
            try w.print("{s} = {d},\n", .{ v.name, v.id });
        }
        try w.print("}};\n", .{});
    }
}

pub fn emitPacketEnum(alloc: std.mem.Allocator, root: *std.json.ObjectMap, writer: anytype, game_state: []const u8, direction: []const u8, enum_name: []const u8) !void {
    const play = (getV(root.get(game_state) orelse return, .object));
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
            if (std.mem.eql(u8, "packet", p.key_ptr.*)) continue;
            newGenType(p.value_ptr.*, &parent, p.key_ptr.*, .{ .gen_fields = false, .optional = false }) catch |err| {
                if (parent.decls.items.len > 0) {
                    const last = parent.getLastDecl();
                    last.unsupported = true;
                }
                std.debug.print("Omitting {s}:{s} {s} {any}\n", .{ game_state, direction, p.key_ptr.*, err });
                continue;
            };
        }
        try writer.print("pub const packets = struct {{\n", .{});
        try parent.emit(
            writer,
            .{ .none = {} },
            if (std.mem.eql(u8, "toClient", direction)) .recv else .send,
        );
        try writer.print("}};\n", .{});
    }
    try writer.print("}};\n\n", .{});
}

const SupportedTypes = enum {
    container,
    array,
    option,
    buffer,
    bitfield,
    mapper,
    @"switch",
    registryEntryHolder,
    registryEntryHolderSet,
    bitflags,
};

// Handling array type
// for struct just []const child
// for fn first len = parse(countType)
// while(parse(arraychild

var strbuf: [40000]u8 = undefined;
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

        pub fn getIdentifier(self: @This()) ![]const u8 {
            return switch (self) {
                .primitive => |p| try printString("Type_{s}", .{p}),
                //.primitive => |p| p,
                .compound => |co| {
                    if (co.d == ._array) {
                        switch (co.d._array.emit_kind) {
                            .array_count => |count| return try printString("[{d}]{s}", .{ count, co.name }),
                            else => {},
                        }
                        return try printString("[]const {s}", .{co.name});
                    }
                    return co.name;
                },
            };
        }
    };

    pub const Field = struct {
        name: []const u8,
        type: PType,
        optional: bool = false,
        requires_count: bool = false,
        //type_identifier: []const u8,
    };
    pub const EnumT = struct { //These are from "mappers"
        const FType = struct {
            name: []const u8,
            value: i64,
        };
        fields: std.ArrayList(FType),
        tag_type: []const u8, //This is always a primitive value (int), hence string
    };

    pub const UnionT = struct { //These are "switches"
        psg: ParseStructGen,
        tag_type: []const u8,
    };

    pub const BitfieldT = struct {
        const FieldT = struct {
            name: []const u8,
            int_t: []const u8,
            int_w: i64,
        };
        fields: std.ArrayList(FieldT),
        parent_t: i64, //Parent must be a integer type,
    };

    pub const BitFlagT = struct {
        flags: std.ArrayList([]const u8), //Index of the array represents bitindex
        primitive_type: []const u8,
    };

    pub const Decl = struct {
        unsupported: bool = false,
        name: []const u8,
        d: union(enum) {
            bitflag: BitFlagT,
            bitfield: BitfieldT,
            _enum: EnumT,
            _union: UnionT,
            _struct: ParseStructGen,
            _array: struct {
                s: ParseStructGen,
                emit_kind: EmitKind = .{ .none = {} },
            },
            alias: []const u8,
            none: void,
        } = .none,
    };

    pub const EmitKind = union(enum) {
        none: void,
        array_varint: void,
        array_ref: struct { ref_name: []const u8 },
        array_count: usize,
    };

    pub const EmitDir = enum {
        send,
        recv,
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

    pub fn emit(self: *const Self, w: anytype, emit_kind: EmitKind, dir: EmitDir) !void {
        for (self.decls.items) |d| {
            if (d.unsupported) {
                try w.print("pub const {s} = error.cannotBeAutoGenerated;\n", .{d.name});
            }
        }
        for (self.decls.items) |d| {
            if (d.unsupported) {
                //Skip emiting them here as we emit all unsupported first
                continue;
            }
            switch (d.d) {
                .bitflag => |b| {
                    try w.print("pub const {s} = struct {{\n", .{d.name});
                    try w.print("//Bitflag\n", .{});
                    for (b.flags.items, 0..) |fl, i| {
                        try w.print("pub const flag_{s} = 0b{b};\n", .{ fl, @as(usize, 0x1) << @as(u6, @intCast(i)) });
                    }
                    try w.print("flag: {s},", .{b.primitive_type});
                    switch (dir) {
                        .recv => {
                            try w.print("pub fn parse(pctx:anytype)!@This(){{\n", .{});
                            try w.print("const val = try pctx.parse_{s}();\n", .{b.primitive_type});
                            try w.print("return @This(){{\n", .{});
                            try w.print(".flag = val\n", .{});
                            try w.print("}};\n", .{});
                            //try w.print("return @enumFromInt(try pctx.parse_{s}());", .{e.tag_type});
                            try w.print("}}\n", .{});
                        },
                        .send => {
                            try w.print("pub fn send(self:*const @This(), pk: *PSend)!void{{\n", .{});
                            try w.print("pk.send_{s}(self.flag);\n", .{b.primitive_type});
                            try w.print("}}\n", .{});
                        },
                    }
                    try w.print("}};\n", .{});
                },
                .bitfield => |b| {
                    try w.print("pub const {s} = struct {{\n", .{d.name});
                    try w.print("//Bitfield\n", .{});
                    for (b.fields.items) |f| {
                        try w.print("{s}: {s},\n", .{ f.name, f.int_t });
                    }

                    switch (dir) {
                        .recv => {
                            try w.print("pub fn parse(pctx:anytype)!@This(){{\n", .{});
                            try w.print("const val = try pctx.parse_u{d}();\n", .{b.parent_t});
                            try w.print("return @This(){{\n", .{});
                            var sig_w: i64 = 0;
                            var insig_w: i64 = b.parent_t;
                            for (b.fields.items) |f| {
                                insig_w -= f.int_w;
                                try w.print(".{s} = @as({s}, @intCast(val << {d} >> {d})),\n", .{ f.name, f.int_t, sig_w, insig_w + sig_w });
                                sig_w += f.int_w;
                            }
                            try w.print("}};\n", .{});
                            //try w.print("return @enumFromInt(try pctx.parse_{s}());", .{e.tag_type});
                            try w.print("}}\n", .{});
                        },
                        .send => {
                            return error.notSupported;
                        },
                    }
                    try w.print("}};\n", .{});
                },
                ._enum => |e| {
                    try w.print("pub const {s} = enum({s}) {{\n", .{ d.name, e.tag_type });
                    //Enums can't have nested types so we can just emit parse or send here without recursion
                    switch (dir) {
                        .recv => {
                            try w.print("pub fn parse(pctx:anytype)!@This(){{\n", .{});
                            try w.print("return @enumFromInt(try pctx.parse_{s}());", .{e.tag_type});
                            try w.print("}}\n", .{});
                        },
                        .send => {
                            try w.print("pub fn send(self:*const @This(), pk: *PSend)!void{{\n", .{});
                            try w.print("return pk.send_{s}(@as({s},@intFromEnum(self.*)));", .{ e.tag_type, e.tag_type });
                            try w.print("}}\n", .{});
                        },
                    }

                    for (e.fields.items) |item| {
                        try w.print("{s} = {d},\n", .{ item.name, item.value });
                    }
                    try w.print("}};\n", .{});
                },

                .none => {},
                .alias => |a| {
                    try w.print("pub const {s} = {s};\n\n", .{ d.name, a });
                },
                ._array => |a| {
                    try w.print("pub const {s} = struct{{\n", .{d.name});
                    try a.s.emit(w, a.emit_kind, dir);
                    try w.print("}};\n\n", .{});
                },
                ._union => |u| {
                    try w.print("pub const {s} = union(enum){{\n", .{d.name});
                    try w.print("//{s}\n", .{u.tag_type});
                    try u.psg.emit(w, .{ .none = {} }, dir);
                    try w.print("}};\n\n", .{});
                },
                ._struct => |s| {
                    try w.print("pub const {s} = struct{{\n", .{d.name});
                    try s.emit(w, .{ .none = {} }, dir);
                    try w.print("}};\n\n", .{});
                },
            }
        }
        for (self.fields.items) |f| {
            if (f.optional) {
                try w.print("{s}: ?{s} = null,\n", .{ f.name, try f.type.getIdentifier() });
            } else {
                try w.print("{s}: {s},\n", .{ f.name, try f.type.getIdentifier() });
            }
        }
        switch (dir) {
            .recv => {
                switch (emit_kind) {
                    .array_count, .array_varint, .array_ref => {
                        if (self.fields.items.len != 1) return error.invalidArrayStructure;
                        const item_field = self.fields.items[0];
                        if (emit_kind == .array_ref) {}
                        try w.print("pub fn parse(pctx:anytype {s})![]@This(){{\n", .{
                            if (emit_kind == .array_ref) ",item_count:usize " else "",
                        });
                        switch (emit_kind) {
                            .array_count => try w.print("const item_count:usize = {d};\n", .{emit_kind.array_count}),
                            .array_varint => try w.print("const item_count:usize = @intCast(try pctx.parse_varint());\n", .{}),
                            .array_ref => try w.print("//ARRAY_REF {s}\n", .{emit_kind.array_ref.ref_name}),
                            else => unreachable,
                        }
                        try w.print("const array = try pctx.alloc.alloc(@This(), item_count);\n", .{});
                        try w.print("for(0..item_count)|i|{{\n", .{});
                        switch (item_field.type) {
                            .primitive => |p| try w.print("array[i].{s} = try pctx.parse_{s}();\n", .{ item_field.name, p }),
                            .compound => |co| try w.print("array[i].{s} = try {s}.parse(pctx);\n", .{ item_field.name, co.name }),
                        }
                        try w.print("}}\n", .{});

                        try w.print("return array;\n", .{});
                        try w.print("}}\n", .{});
                    },
                    .none => {
                        try w.print("\npub fn parse({s}:anytype)!@This() {{\n", .{if (self.fields.items.len > 0) "pctx" else "_"});
                        const cvar: []const u8 = if (self.fields.items.len > 0) "var" else "const";
                        try w.print("{s} ret: @This() = undefined;\n", .{cvar});
                        for (self.fields.items) |f| {
                            const extra_args = if (f.requires_count) ",69" else "";
                            if (f.optional)
                                try w.print("if(try pctx.parse_bool()){{\n", .{});
                            switch (f.type) {
                                .primitive => |p| try w.print("ret.{s} = try pctx.parse_{s}();\n", .{ f.name, p }),
                                .compound => |co| try w.print("ret.{s} = try {s}.parse(pctx {s});\n", .{ f.name, co.name, extra_args }),
                            }
                            if (f.optional)
                                try w.print("}}", .{});
                        }
                        try w.print("return ret;\n", .{});
                        try w.print("}}\n\n", .{});
                    },
                }
            },
            .send => {
                try w.print("pub fn send(self:*const @This(), pk: *PSend)!void{{\n", .{});
                var discard_psend = true;
                for (self.fields.items) |f| {
                    discard_psend = false;
                    if (f.optional) {
                        try w.print("try pk.send_bool(self.{s} != null);\n", .{f.name});
                        try w.print("if(self.{s} != null){{\n", .{f.name});
                    }
                    const unwrapped_optional: []const u8 = if (f.optional) try printString("{s}.?", .{f.name}) else f.name;
                    switch (f.type) {
                        //TODO determine if the array we are sending is a primitive and then just use write()
                        .primitive => |p| try w.print("try pk.send_{s}(self.{s});\n", .{ p, unwrapped_optional }),
                        .compound => |co| {
                            if (co.d == ._array) {
                                if (co.d._array.emit_kind == .array_varint)
                                    try w.print("try pk.send_varint(@intCast(self.{s}.len));\n", .{unwrapped_optional});
                                try w.print("for(self.{s})|i_{s}|{{", .{ unwrapped_optional, f.name });
                                try w.print("try i_{s}.send(pk);\n", .{f.name});
                                try w.print("}}\n", .{});
                            } else {
                                try w.print("try self.{s}.send(pk);\n", .{unwrapped_optional});
                            }
                        },
                    }
                    if (f.optional)
                        try w.print("}}\n", .{});
                }
                if (discard_psend)
                    try w.print("_ = pk;\n_ = self;\n", .{});
                try w.print("}}\n", .{});
            },
        }
    }
};
//TODO
//generate parsing code for switch
//pass counter var into referenced array count parse

var state_anon_level: usize = 0;
pub fn newGenType(v: std.json.Value, parent: *ParseStructGen, fname: []const u8, flags: struct {
    gen_fields: bool = false,
    optional: bool = false,
}) !void {
    const ns_prefix = "Type_";
    //const ns_prefix = "";
    switch (v) {
        //Needed for Slot
        //UNKOWN TYPE_DEF pstring
        //UNKOWN TYPE_DEF registryEntryHolder
        //UNKOWN TYPE_DEF registryEntryHolderSet
        //
        .array => |a| { //An array is some compound type definition
            const t = strToEnum(SupportedTypes, getV(a.items[0], .string)) orelse {
                std.debug.print("UNKOWN TYPE_DEF {s}\n", .{getV(a.items[0], .string)});
                return error.notSupported;
                //
            };
            switch (t) {
                .bitflags => {
                    //Has the fields: type, flags;array of flag vars
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const child = try parent.newDecl(Tname);
                    const ob = getV(a.items[1], .object);
                    child.d = .{ .bitflag = .{
                        .flags = std.ArrayList([]const u8).init(parent.alloc),
                        .primitive_type = getV(ob.get("type").?, .string),
                    } };
                    const flag_names = getV(ob.get("flags").?, .array).items;
                    for (flag_names) |f| {
                        try child.d.bitflag.flags.append(getV(f, .string));
                    }
                },
                .registryEntryHolderSet => {
                    //Has the fields:
                    //base: {name, type}
                    //otherwise: {name, type}
                    //
                    //if type==0
                    //  base
                    //else
                    //  otherwise
                    //
                    //In the wild we have 2 all same types, differnt namse for otherwise ,ids/blockids
                    //parsing is as follows for IDSET
                    //type = parse.varint()
                    //if type == 0
                    //  const reg_tag = parse.string()
                    //else
                    //  parse array of size (type -1) of type: varint
                    //  so its a union
                },
                .registryEntryHolder => {
                    //has the fields
                    //baseName
                    //otherwise
                    //
                    //parse is as follows
                    //id = parse.varint()
                    //if id == 0
                    //  return parse.childTYpe
                    //else
                    //  return id + 1
                },
                //.registryEntryHolder, .registryEntryHolderSet => {},
                .bitfield => {
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const child = try parent.newDecl(Tname);

                    //child.d = .{ ._struct = ParseStructGen.init(parent.alloc) };
                    const fields = getV(a.items[1], .array).items;
                    var total_size: i64 = 0;
                    for (fields) |f| {
                        const ob = getV(f, .object);
                        //const ident = getV(ob.get("name").?, .string);
                        const field_size = getV(ob.get("size").?, .integer);
                        total_size += field_size;
                        //const is_signed = getV(ob.get("signed").?, .bool);
                    }
                    child.d = .{ .bitfield = .{
                        .fields = std.ArrayList(ParseStructGen.BitfieldT.FieldT).init(parent.alloc),
                        .parent_t = @intCast(total_size),
                    } };
                    for (fields) |f| {
                        const ob = getV(f, .object);
                        const field_size = getV(ob.get("size").?, .integer);
                        const signed = getV(ob.get("signed").?, .bool);
                        try child.d.bitfield.fields.append(.{
                            .name = getV(ob.get("name").?, .string),
                            .int_t = try printString("{c}{d}", .{ @as(u8, if (signed) 'i' else 'u'), field_size }),
                            .int_w = @intCast(field_size),
                        });
                    }
                    //try newGenType(
                    //    .{ .string = try printString("u{d}", .{@as(usize, switch (total_size) {
                    //        32 => 32,
                    //        64 => 64,
                    //        8 => 8,
                    //        16 => 16,
                    //        else => return error.notSupported,
                    //    })}) },
                    //    &child.d._struct,
                    //    "bitfield",
                    //    .{ .gen_fields = true, .optional = false },
                    //);
                    //std.debug.print("TOTAL BITFIELD SIZE {d}\n", .{total_size});
                    if (flags.gen_fields)
                        try parent.fields.append(.{ .name = fname, .optional = flags.optional, .type = .{ .compound = child } });
                },
                .mapper => {
                    const fields = getV(a.items[1], .object);
                    const type_name = getV(fields.get("type").?, .string);
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._enum = .{ .fields = std.ArrayList(ParseStructGen.EnumT.FType).init(parent.alloc), .tag_type = type_name } };
                    const mappings = getV(fields.get("mappings").?, .object);
                    var map_it = mappings.iterator();
                    while (map_it.next()) |m_item| {
                        const name_dupe = try parent.alloc.dupe(u8, getV(m_item.value_ptr.*, .string));
                        std.mem.replaceScalar(u8, name_dupe, '.', '_');
                        try child.d._enum.fields.append(.{
                            .name = name_dupe,
                            .value = try std.fmt.parseInt(i64, m_item.key_ptr.*, 10),
                        });
                    }
                    if (flags.gen_fields)
                        try parent.fields.append(.{
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                        });
                },
                .container => {
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });

                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._struct = ParseStructGen.init(parent.alloc) };
                    const fields = getV(a.items[1], .array).items;
                    for (fields) |f| {
                        const ob = getV(f, .object);
                        const ident = blk: {
                            //There are 12 instances of anon in 1.21.3 protocol, (2 in 1.19.4), 11 are switches, one is a bitfield.
                            //Anon switches can't be sensibly attached to parent structs as a switch's memory representation is a union.
                            //The additional complexity of somehow attaching anon fields to the parent for the one bitfield, including parse/send functions is not worth it. (a packed xz for block ents). So we just give the anon field a name: anon
                            //Anon is dumb
                            if (ob.get("anon")) |anon| {
                                if (getV(anon, .bool)) {
                                    const n = try printString("anon_{d}", .{state_anon_level});
                                    state_anon_level += 1;
                                    break :blk n;
                                }
                            }
                            //Jukebox_playable has 3 deep nest of anon switch
                            //Slot as well
                            break :blk getV(ob.get("name").?, .string);
                        };
                        //We have to add something to every field identifier because of a global type named "tags" and multiple fields named "tags"
                        const ident_mangle = try printString("f_{s}", .{ident});
                        const field_type = ob.get("type").?;
                        try newGenType(field_type, &child.d._struct, ident_mangle, .{ .gen_fields = true, .optional = false });
                    }
                    if (flags.gen_fields)
                        try parent.fields.append(.{ .name = fname, .optional = flags.optional, .type = .{ .compound = child } });
                },
                .@"switch" => {
                    //A switch is a union
                    //Has fields:
                    //compareTo
                    //type
                    const sw_def = getV(a.items[1], .object);
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const tag_type_name = try printString("f_{s}", .{sw_def.get("compareTo").?.string});
                    var found = false;
                    //TODO these (1.21.3) packets have the switch's tag variable somewhere other than the direct parent and use a path notation: ../mystupid/path
                    //packet_player_info
                    //packet_declare_commands
                    //packet_advancements
                    var index: usize = 0;
                    for (parent.fields.items, 0..) |f, i| { //Search through parent's fields for matching tag
                        if (std.mem.eql(u8, f.name, tag_type_name)) {
                            index = i;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        //
                        std.debug.print("CANT FIND TAG {s}\n", .{tag_type_name});
                        return error.notSupported;
                    }

                    //Switch on either enum or bare number
                    //switches using numbers will need names for union fields

                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._union = .{
                        .psg = ParseStructGen.init(parent.alloc),
                        .tag_type = try parent.fields.items[index].type.getIdentifier(),
                    } };
                    const fields = sw_def.get("fields").?.object;
                    var f_it = fields.iterator();
                    while (f_it.next()) |f| {
                        const int_val = std.fmt.parseInt(i64, f.key_ptr.*, 10) catch {
                            //Not an int so we can continue
                            try newGenType(f.value_ptr.*, &child.d._union.psg, f.key_ptr.*, .{ .gen_fields = true, .optional = false });
                            continue;
                        };
                        try newGenType(f.value_ptr.*, &child.d._union.psg, try printString("{s}_v_{d}", .{ fname, int_val }), .{ .gen_fields = true, .optional = false });
                    }

                    if (sw_def.get("default")) |default| {
                        try newGenType(default, &child.d._union.psg, "default", .{ .gen_fields = true, .optional = false });
                    }
                    //const fields = getV(a.items[1], .array).items;
                    //First memory represent, then worry about logic to retrieve switch(value)
                    if (flags.gen_fields)
                        try parent.fields.append(.{ .name = fname, .optional = flags.optional, .type = .{ .compound = child } });
                },
                .buffer, .array => {
                    const array_def = getV(a.items[1], .object);

                    const ekind: ParseStructGen.EmitKind = blk: {
                        const count_type_str = getV(array_def.get("countType") orelse {
                            switch (t) {
                                .array => { //An array without a countType must have a string count that points to parent var
                                    const count_name = try printString("f_{s}", .{try getVE(array_def.get("count").?, .string)});
                                    var found = false;
                                    var index: usize = 0;
                                    for (parent.fields.items, 0..) |f, i| { //Search through parent's fields for matching tag
                                        if (std.mem.eql(u8, f.name, count_name)) {
                                            index = i;
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        std.debug.print("CANNOT FIND ARRAY TAG\n", .{});
                                        return error.notSupported;
                                    }
                                    break :blk .{ .array_ref = .{ .ref_name = count_name } };
                                },
                                .buffer => { //buffers have count as a fixed integer

                                    const count = try getVE(array_def.get("count").?, .integer);
                                    break :blk .{ .array_count = @intCast(count) };
                                },
                                else => unreachable,
                            }
                        }, .string);
                        const count_type = strToEnum(enum { varint }, count_type_str) orelse {
                            std.debug.print("INVALID ARRAY COUNT ON {s}\n", .{count_type_str});
                            return error.invalidArrayCount;
                        };
                        _ = count_type;
                        break :blk .{ .array_varint = {} };
                    };

                    const child_type = if (t == .buffer) std.json.Value{ .string = "u8" } else array_def.get("type").?;
                    const Tname = try printString("Array_{s}", .{fname});
                    const child = try parent.newDecl(Tname);
                    child.d = .{ ._array = .{ .s = ParseStructGen.init(parent.alloc), .emit_kind = ekind } };
                    try newGenType(child_type, &child.d._array.s, try printString("i_{s}", .{fname}), .{ .gen_fields = true, .optional = false });
                    try parent.fields.append(.{ .name = fname, .optional = flags.optional, .type = .{ .compound = child }, .requires_count = ekind == .array_ref });
                },
                .option => {
                    try newGenType(a.items[1], parent, fname, .{ .gen_fields = true, .optional = true });
                },
            }
        },
        .string => |str| { //A string is a literal type
            if (flags.gen_fields) {
                try parent.fields.append(.{
                    .name = fname,
                    .optional = flags.optional,
                    .type = .{ .primitive = str },
                });
            } else {
                const child = try parent.newDecl(try printString("{s}{s}", .{ ns_prefix, fname }));
                child.d = .{ .alias = str };
            }
        },
        else => {
            std.debug.print("Type not supported: {any}\n", .{v});
            return error.notSupported;
        },
    }
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
