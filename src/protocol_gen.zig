const std = @import("std");
const strToEnum = std.meta.stringToEnum;
const FbsT = std.io.FixedBufferStream([]u8);
const JValue = std.json.Value;
const eql = std.mem.eql;
const Alloc = std.mem.Allocator;
const com = @import("common.zig");
const ERR_NAME = "PE";
// All the different types of "switch" in the wild: (As of 1.21.3)
// Type 1
// A direct mapping of enum values to union members without a default field
//      ex: RecipeDisplay.data, SlotDisplay.data, SlotComponent.data
//
// Type 2
// A variant of Id(string) or x(int) if parse.varint() == 0, parse the only field in switch (field "0") else return a int
//      Ex: SlotComponent.trim.materialType (anon), SlotComponent.trimPattern.trimPatternType (anon)
//          SlotComponent.instrument.instrumentType(anon)
//          SlotComponent.jukebox_playable.directmode.jukeboxsongtype
//          SlotComponent.jukebox_playable.directmode.jukeboxsongtype.soundEventType
//          SlotComponent.banner_patterns.layers.patternType
//
// Type 3
// Essentially an optional type, maps a boolean to two different structs
//      Ex: SlotComponent.jukebox_playable
//
// Type 4
//  Another variant of optional types with a numerical fields "0","1".. and default used with Slot.itemCount
//      Ex: if Slot.itemCount > 0 item data is present else nothing
//          packet_boss_bar.title has two numbers(0,3) and a default
//
//  This category is also overloaded to an extent. With a single number field it is essentially an optional.
//  More than one number field should not occur as the meanings of the numbers should be specifed using an enum/mapper
//
// Type 5
//  Has a single value without a default field, :( see packet_common_server_links
//  Will not support, it is a bug in the protocol spec imo as we have to infer a default of void
//
// Memory Representations
// Type #, zig type         , parsing method
//      1, union(enum)      , switch on compareTo enum
//      2, union(enum)      , switch with else on bare integer
//      3, union(enum)      , if statement on boolean
//      4, optional type    , non standard optional code, could probably use (2)
//
// Thus, generating code for these "switch" types is annoying.
// It's worth noting that the code for Type_Slot is around 2000 lines or 1/4 of all generated code and all but one switch are within Type_Slot. As items are sent within arrays and there is no way to determine the byte length of metadata without parsing, it is necessary to generate all this code. If only each component was prefixed with a length field.
//
// Json layout for each type of switch
// Type #, fields
//      1, "compareTo"(str)->parentFieldEnumIdentifier, "fields"(dict)-> maps enum strings to types, NO "default" field
//      2, "compareTo"(str)->parentFieldInteger,"fields(dict)->contains a single number key, NO "default" field
//      3, "compareTo"(str)->parentFieldBool, "fields"(dict)->contains two fields, true, false
//      4, "compareTo"(str)->parentFieldInteger, "fields"(dict)->"0", contains default field
//
// Parsing plan
// Categorize the "switch"
// case A: all numerical (default allowed), total fields > 1
// case B: boolean, total fields > 1 else unsupported
// case C: all strings mapping to enum (default forbidden)
// case D: single numerical no default, subset of case 'A'
//

// Other info(1.21.3)
// Data types that are recursive
// EffectDetail is recursive, it contains an optional Field hiddenEffect: EffectDetail
// How to resolve?
// Solution 1:
// This is a really. really. stupid packet, essentially a linked list sent over the network? Are you kidding? Why not an array
// Easiest thing is to special case it. Omit the recursive field and omit an return a parsing error if the bool is ever true as it is unlikely to ever occur in vanilla games.
// Given how problematic protocol.json can be, having .patch files for supported versions might be the way to go.
//
// Solution 2
// promote all optional fields to ?pointers, relatively easy
//
// Solution 3
// Detect dependency cycles and selectively convert to pointers, annoying
//
// Problem:
// SlotComponent can have a Slot field
// Not same problem as above as Slot contains an array of SlotComponent so it has a defined size.
// The problem is that zig can't infer the error set in recursive situations
//
// Solution 1, make everything anyerror
//
// Solution 2, parse functions cannot return an error
//
// Solution 3, specify the error set
//

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

const NameManglerT = std.StringHashMap(struct { collision_counter: usize = 0 });
var name_mangler_3000: NameManglerT = undefined;
var mangle_map: std.StringHashMap(usize) = undefined;

//About name mangling.
//packet_tags contains a lovely naming scheme,
//It defines an array type named "tags" which contains a struct containing a field named "tags" of type "tags"
//the field "tags" is ambiguously defined. It is supposed to refer to the top level type "tags"
//Name mangling will not help us we either have to check that types can't be self referential or just special case this dumb packet

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
        .{ ERR_NAME, "mc.ParseError" },
        .{ "Vector", "@import(\"vector.zig\")" },
        .{ "PSend", "mc.Packet" },
        .{ "varint", "i32" },
        //.{ "vec3f64", "Vector.V3f" },
        .{ "UUID", "u128" },
        //.{ "Slot", "mc.Slot" },
        .{ "string", "[]const u8" },
        //.{ "position", "Vector.V3i" },
        .{ "restBuffer", "[]const u8" },
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
        //.{ "SpawnInfo", "Play_Clientbound.packets.Type_SpawnInfo" }, //Ugly
        //.{ "vec2f", "mc.Vec2f" },
        //.{ "Particle", em },
        //.{ "vec3f", "mc.V3f" },
        //.{ "Type_PositionUpdateRelatives", "mc.PositionUpdateRelatives" },
        .{ "Type_tags", em },
        //.{ "Type_IDSet", "void" },
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
    name_mangler_3000 = NameManglerT.init(alloc);
    defer name_mangler_3000.deinit();
    mangle_map = std.StringHashMap(usize).init(alloc);
    defer mangle_map.deinit();

    const ddd = "error.protodefisdumb";
    const omit = "omit";
    const native_mapper = [_]struct { []const u8, []const u8 }{
        //pub const Type_optionalNbt = error.notImplemented;
        .{ "optionalNbt", "?mc.nbt_zig.EntryWithName" },
        .{ "varint", "i32" },
        .{ "optvarint", "?i32" },
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
        .{ "nbt", "mc.nbt_zig.EntryWithName" },
        .{ "string", "[]const u8" },
        .{ "ContainerID", "i32" },
        .{ "anonymousNbt", "mc.nbt_zig.Entry" },
        .{ "anonOptionalNbt", "?mc.nbt_zig.Entry" },
        .{ "container", omit }, //You gotta love protodef
        .{ "switch", ddd },
        .{ "bitfield", ddd },
        .{ "void", "void" },
        .{ "array", ddd },
        .{ "bitflags", ddd },
        .{ "option", ddd },
        .{ "topBitSetTerminatedArray", ddd },
    };
    //Need to have a map that indicates if something can be parsed by pctx or not

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
                    if (!eql(u8, s, "native")) {
                        try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, s });
                    } else {
                        if (native_map.get(ty.key_ptr.*)) |has| {
                            if (eql(u8, has, omit)) {
                                continue;
                            }
                            try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, has });
                        } else {
                            try w.print("pub const Type_{s} = {s};\n", .{ ty.key_ptr.*, em });
                        }
                    }
                },
                .array => {
                    newGenType(ty.value_ptr.*, &parent, ty.key_ptr.*, .{ .gen_fields = false, .optional = .no }) catch |err| {
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
        try mangleTypeNames(&parent, &mangle_map, false);
        try parent.emit(
            w,
            .{ .none = {} },
            .recv,
            &native_map,
            null,
        );
        //try w.print("}};\n", .{});
    }

    try emitPacketEnum(&native_map, arena_alloc, &root, w, "play", "toClient", "Play_Clientbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "play", "toServer", "Play_Serverbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "handshaking", "toServer", "Handshake_Serverbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "handshaking", "toClient", "Handshake_Clientbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "login", "toClient", "Login_Clientbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "login", "toServer", "Login_Serverbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "configuration", "toClient", "Config_Clientbound");
    try emitPacketEnum(&native_map, arena_alloc, &root, w, "configuration", "toServer", "Config_Serverbound");

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

pub fn emitPacketEnum(native_map: *const std.StringHashMap([]const u8), alloc: std.mem.Allocator, root: *std.json.ObjectMap, writer: anytype, game_state: []const u8, direction: []const u8, enum_name: []const u8) !void {
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
            if (eql(u8, "packet", p.key_ptr.*)) continue;
            newGenType(p.value_ptr.*, &parent, p.key_ptr.*, .{ .gen_fields = false, .optional = .no }) catch |err| {
                if (parent.decls.items.len > 0) {
                    const last = parent.getLastDecl();
                    last.unsupported = true;
                }
                std.debug.print("Omitting {s}:{s} {s} {any}\n", .{ game_state, direction, p.key_ptr.*, err });
                continue;
            };
        }
        try mangleTypeNames(&parent, &mangle_map, true);
        try writer.print("pub const packets = struct {{\n", .{});
        try parent.emit(
            writer,
            .{ .none = {} },
            if (eql(u8, "toClient", direction)) .recv else .send,
            native_map,
            null,
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

const MangleItem = struct {
    ident: []const u8,
    count: usize = 0,
};
//Recursivly walk through psg defining types while going along
//returns how many items it append to list
var nest_level: i64 = 0;
pub fn mangleTypeNames(parent: *ParseStructGen, mangle_list: *std.StringHashMap(usize), remove_tl: bool) !void {
    nest_level += 1;
    defer nest_level -= 1;
    //add all decls to hash_map, any existing will be given a mangle counter
    for (parent.decls.items) |decl| {
        const res = try mangle_list.getOrPut(try parent.alloc.dupe(u8, decl.name));
        if (res.found_existing) { //remember to update the name
            res.value_ptr.* += 1;
        } else {
            res.value_ptr.* = 0;
        }
        //If the decl already exists, indicate that it needs to be mangled
    }
    for (parent.fields.items) |*f| {
        switch (f.type) {
            .primitive => {},
            .compound => |co| {
                if (mangle_list.get(co.name)) |found| {
                    if (found > 0)
                        co.name = try printString("{s}_{d}", .{ co.name, found });
                }
            },
        }
    }
    for (parent.decls.items) |decl| {
        if (mangle_list.getPtr(decl.name)) |item| {
            if (item.* > 0) {
                decl.name = try printString("{s}_{d}", .{ decl.name, item.* });
                //
                item.* -= 1;
            }
        }
    }
    for (parent.decls.items) |decl| {
        switch (decl.d) {
            else => {},
            ._union => |*d| {
                try mangleTypeNames(&d.psg, mangle_list, true);
            },
            ._struct => |*d| {
                try mangleTypeNames(d, mangle_list, true);
            },
            ._array => |*d| {
                try mangleTypeNames(&d.s, mangle_list, true);
            },
        }
    }
    if (remove_tl) {
        for (parent.decls.items) |decl| {
            if (mangle_list.getPtr(decl.name)) |item| {
                if (item.* == 0) {
                    _ = mangle_list.remove(decl.name);
                }
            }
        }
    }
}

pub const ParseStructGen = struct {
    const Self = @This();
    pub const PType = union(enum) {
        primitive: []const u8, // all primitive types have a mc.parse_primitiveName() function
        compound: *Decl,

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
        const OptionalT = enum {
            no,
            yes,
            yes_ptr,
        };
        name: []const u8,
        type: PType,
        optional: OptionalT = .no,
        switch_value: ?i64,
        dont_emit_default: bool = false,
        counter_arg_name: ?[]const u8 = null, //If set, parse funtions will have this as an additional arg, should be f_myCounterArg
        switch_arg_name: ?[]const u8 = null, //Same as counter but for switching
        switch_arg_is_bool: bool = false,
        //type_identifier: []const u8,

        pub fn printParseFn(f: *const Field, w: anytype, native_mapper: *const std.StringHashMap([]const u8), ret_str: []const u8) !void {
            const switch_args = if (f.switch_arg_name) |sn| try printString(",{s}ret.{s}{s}", .{
                if (f.switch_arg_is_bool) "@intFromBool(" else "",
                sn,
                if (f.switch_arg_is_bool) ")" else "",
            }) else "";
            const extra_args = if (f.counter_arg_name) |cn| try printString(",@intCast(ret.{s})", .{cn}) else "";
            if (f.optional == .yes)
                try w.print("if(try pctx.parse_bool()){{\n", .{});
            if (f.optional == .yes_ptr) {
                //UGLY HACK for this ugly packet
                try w.print("const stupid = try pctx.alloc.create({s});\n", .{try f.type.getIdentifier()});
                try w.print("stupid.* = try Type_EffectDetail.parse(pctx);\n", .{});
                try w.print("ret.hiddenEffect = stupid;", .{});
            } else {
                switch (f.type) {
                    .primitive => |p| {
                        if (native_mapper.get(p) != null) {
                            try w.print("{s}{s} = try pctx.parse_{s}();\n", .{ ret_str, f.name, p });
                        } else {
                            try w.print("{s}{s} = try Type_{s}.parse(pctx);\n", .{ ret_str, f.name, p });
                        }
                    },
                    //.primitive => |p| try w.print("ret.{s} = try pctx.parse_{s}();\n", .{ f.name, p }),
                    .compound => |co| try w.print("{s}{s} = try {s}.parse(pctx {s} {s});\n", .{ ret_str, f.name, co.name, extra_args, switch_args }),
                }
            }
            if (f.optional == .yes)
                try w.print("}}", .{});
        }
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
        info: EmitUnionInfo = .{},
    };
    pub const UnionCategory = enum {
        strict_bool,
        numeric,
        enumeration,
    };

    pub const EmitUnionInfo = struct {
        category: UnionCategory = .enumeration,
        tag_type: []const u8 = "",
        has_default: bool = false,
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
            registryEntry: struct {
                is_array: bool = false, //for registryEntryHolderSet
                child_t: []const u8, //FIXME this only supports type references
                child_t_name: []const u8,
            },
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
    parse_as_union: bool = false, //this is here as we store unions as a ParseStructgen type and need a way to indicate.
    parse_as_union_type: []const u8 = "",
    parse_as_union_is_num: bool = false,

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

    pub fn emit(self: *const Self, w: anytype, emit_kind: EmitKind, dir: EmitDir, native_mapper: *const std.StringHashMap([]const u8), union_info: ?EmitUnionInfo) !void {
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
                .registryEntry => |r| {
                    try w.print("pub const {s} = union(enum) {{\n", .{d.name});
                    try w.print("//REGENTRY\n", .{});
                    if (r.is_array) {
                        try w.print("name: string,\n", .{});
                        try w.print("ids: []Type_varint,", .{});
                        switch (dir) {
                            .recv => {
                                try w.print("pub fn parse(pctx:anytype){s}!@This(){{\n", .{ERR_NAME});
                                const body =
                                    \\const v = try pctx.parse_varint();
                                    \\return switch(v){{
                                    \\ 0 => .{{ .name = try pctx.parse_string()   }},
                                    \\else =>  {{ 
                                    \\const array = try pctx.alloc.alloc(Type_varint, @intCast(v - 1));
                                    \\for(0..array.len)|i|{{
                                    \\  array[i] = try pctx.parse_varint();
                                    \\}}
                                    \\return .{{ .ids = array }};
                                    \\}},
                                    \\}};
                                ;
                                try w.print(body, .{});
                                try w.print("}}\n", .{}); //fn body
                            },
                            .send => {
                                //not implemented
                                unreachable;
                            },
                        }
                    } else {
                        try w.print("id: Type_varint,\n", .{});
                        try w.print("{s}: Type_{s},", .{ r.child_t_name, r.child_t });
                        switch (dir) {
                            .recv => {
                                try w.print("pub fn parse(pctx:anytype){s}!@This(){{\n", .{ERR_NAME});
                                const body =
                                    \\//{[is_array]any}
                                    \\const v = try pctx.parse_varint();
                                    \\return switch(v){{
                                    \\  0 => .{{ .{[child_t_name]s} = try Type_{[child_t]s}.parse(pctx)
                                    \\}},
                                    \\else => .{{ .id = v + 1 }},
                                    \\}};
                                ;
                                try w.print(body, r);
                                try w.print("}}\n", .{}); //fn body
                            },
                            .send => {
                                //not implemented
                                unreachable;
                            },
                        }
                    }
                    try w.print("}};\n", .{});
                },
                .bitflag => |b| {
                    try w.print("pub const {s} = struct {{\n", .{d.name});
                    try w.print("//Bitflag\n", .{});
                    for (b.flags.items, 0..) |fl, i| {
                        try w.print("pub const flag_{s} = 0b{b};\n", .{ fl, @as(usize, 0x1) << @as(u6, @intCast(i)) });
                    }
                    try w.print("flag: {s},", .{b.primitive_type});
                    switch (dir) {
                        .recv => {
                            try w.print("pub fn parse(pctx:anytype){s}!@This(){{\n", .{ERR_NAME});
                            try w.print("const val = try pctx.parse_{s}();\n", .{b.primitive_type});
                            try w.print("return @This(){{\n", .{});
                            try w.print(".flag = val\n", .{});
                            try w.print("}};\n", .{});
                            try w.print("}}\n", .{});
                        },
                        .send => {
                            try w.print("pub fn send(self:*const @This(), pk: *PSend)!void{{\n", .{});
                            try w.print("try pk.send_{s}(self.flag);\n", .{b.primitive_type});
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
                            try w.print("pub fn parse(pctx:anytype){s}!@This(){{\n", .{ERR_NAME});
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
                            try w.print("pub fn parse(pctx:anytype){s}!@This(){{\n", .{ERR_NAME});
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
                    try a.s.emit(w, a.emit_kind, dir, native_mapper, null);
                    try w.print("}};\n\n", .{});
                },
                ._union => |u| {
                    try w.print("pub const {s} = union({s}){{\n", .{
                        d.name,
                        if (u.info.category == .enumeration) u.info.tag_type else "enum",
                    });
                    try w.print("//{s}\n", .{u.info.tag_type});
                    try u.psg.emit(w, .{ .none = {} }, dir, native_mapper, u.info);
                    try w.print("}};\n\n", .{});
                },
                ._struct => |s| {
                    try w.print("pub const {s} = struct{{\n", .{d.name});
                    try s.emit(w, .{ .none = {} }, dir, native_mapper, null);
                    try w.print("}};\n\n", .{});
                },
            }
        }
        for (self.fields.items) |f| {
            if (f.optional == .yes and !f.dont_emit_default) {
                try w.print("{s}: ?{s} = null,\n", .{ f.name, try f.type.getIdentifier() });
            } else if (f.optional == .yes_ptr and !f.dont_emit_default) {
                try w.print("{s}: ?*{s} = null,\n", .{ f.name, try f.type.getIdentifier() });
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
                        try w.print("pub fn parse(pctx:anytype {s}){s}![]@This(){{\n", .{
                            if (emit_kind == .array_ref) ",item_count:usize " else "",
                            ERR_NAME,
                        });
                        switch (emit_kind) {
                            .array_count => try w.print("const item_count:usize = {d};\n", .{emit_kind.array_count}),
                            .array_varint => try w.print("const item_count:usize = @intCast(try pctx.parse_varint());\n", .{}),
                            .array_ref => try w.print("//ARRAY_REF {s}\n", .{emit_kind.array_ref.ref_name}),
                            else => unreachable,
                        }
                        try w.print("const array = try pctx.alloc.alloc(@This(), item_count);\n", .{});
                        try w.print("for(0..item_count)|i|{{\n", .{});
                        try item_field.printParseFn(w, native_mapper, "array[i].");
                        //switch (item_field.type) {
                        //    .primitive => |p| try w.print("array[i].{s} = try pctx.parse_{s}();\n", .{ item_field.name, p }),
                        //    .compound => |co| try w.print("array[i].{s} = try {s}.parse(pctx);\n", .{ item_field.name, co.name }),
                        //}
                        try w.print("}}\n", .{});

                        try w.print("return array;\n", .{});
                        try w.print("}}\n", .{});
                    },
                    .none => {
                        const pctx_var: []const u8 = if (self.fields.items.len > 0) "pctx" else "_";
                        const cvar: []const u8 = if (self.fields.items.len > 0) "var" else "const";
                        if (union_info) |uf| {
                            switch (uf.category) {
                                //Enumeration parse fn's take a enum value as argument
                                .enumeration => {
                                    try w.print("pub fn parse({s}:anytype, switch_arg: {s}){s}!@This(){{\n", .{
                                        pctx_var,
                                        uf.tag_type,
                                        ERR_NAME,
                                    });
                                    try w.print("{s} ret: @This() = undefined;\n", .{cvar});
                                    try w.print("switch(switch_arg){{\n", .{});
                                    for (self.fields.items) |f| {
                                        try w.print(".{s} => {{\n", .{f.name});
                                        if (f.optional == .yes) {
                                            //    try w.print("}}", .{});
                                            try w.print("ret.{s} = null;\n", .{f.name});
                                        }
                                        try f.printParseFn(w, native_mapper, "ret.");
                                        try w.print("}},", .{}); //switch case
                                    }
                                    try w.print("}}\n", .{}); //Switch body
                                    try w.print("return ret;\n", .{});
                                    try w.print("}}\n", .{}); //fn decl
                                },
                                //Boolean parse functions take a integer as argument
                                //Numeric parse functions take an integer as argument
                                .strict_bool, .numeric => {
                                    try w.print("pub fn parse({s}:anytype, switch_arg: {s}){s}!@This(){{\n", .{
                                        pctx_var,
                                        if (uf.category == .numeric) uf.tag_type else "u1", //no need to cast this unless bool
                                        ERR_NAME,
                                    });
                                    try w.print("{s} ret: @This() = undefined;\n", .{cvar});
                                    try w.print("switch(switch_arg){{\n", .{});
                                    var else_branch_present = false;
                                    for (self.fields.items) |f| {
                                        if (f.switch_value) |sv| {
                                            try w.print("{d} => {{\n", .{sv});
                                        } else {
                                            else_branch_present = true;
                                            try w.print("else => {{\n", .{});
                                        }
                                        if (f.optional == .yes) {
                                            //    try w.print("}}", .{});
                                            try w.print("ret.{s} = null;\n", .{f.name});
                                        }
                                        try f.printParseFn(w, native_mapper, "ret.");
                                        try w.print("}},", .{}); //switch case
                                    }
                                    if (!else_branch_present and uf.category != .strict_bool) { //Prevent zig compile error, not all cases handled
                                        try w.print("else => return error.invalidSwitchValue,", .{});
                                    }
                                    try w.print("}}\n", .{}); //Switch body
                                    try w.print("return ret;\n", .{});
                                    try w.print("}}\n", .{}); //fn decl
                                },
                            }
                            //try w.print("switch(@as({s}, @enumFromInt(switch_arg))){{\n", .{self.parse_as_union_type});
                            //const int_str = "switch(@as(@typeInfo({s}).Union.tag_type.?, @enumFromInt(switch_arg))){{\n";
                        } else {
                            try w.print("\npub fn parse({s}:anytype){s}!@This() {{\n", .{ pctx_var, ERR_NAME });
                            try w.print("{s} ret: @This() = undefined;\n", .{cvar});
                            for (self.fields.items) |f| {
                                try f.printParseFn(w, native_mapper, "ret.");
                            }
                            try w.print("return ret;\n", .{});
                            try w.print("}}\n\n", .{});
                        }
                    },
                }
            },
            .send => {
                try w.print("pub fn send(self:*const @This(), pk: *PSend)!void{{\n", .{});
                var discard_psend = true;
                for (self.fields.items) |f| {
                    discard_psend = false;
                    if (f.optional == .yes) {
                        try w.print("try pk.send_bool(self.{s} != null);\n", .{f.name});
                        try w.print("if(self.{s} != null){{\n", .{f.name});
                    }
                    const unwrapped_optional: []const u8 = if (f.optional == .yes) try printString("{s}.?", .{f.name}) else f.name;
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
                    if (f.optional == .yes)
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
    optional: ParseStructGen.Field.OptionalT = .no,
    switch_value: ?i64 = null,
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
                //.registryEntryHolderSet => {
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
                //},
                .registryEntryHolderSet, .registryEntryHolder => {

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
                    //
                    //The behavior of this is slightly different than switch as the id is modified
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const child = try parent.newDecl(Tname);
                    const ob = getV(a.items[1], .object);
                    child.d = .{ .registryEntry = .{
                        .child_t_name = ob.get("otherwise").?.object.get("name").?.string,
                        .child_t = ob.get("otherwise").?.object.get("type").?.string,
                        .is_array = t == .registryEntryHolderSet,
                    } };

                    if (flags.gen_fields) {
                        try parent.fields.append(.{
                            .switch_value = flags.switch_value,
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                        });
                    }
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
                        try parent.fields.append(.{
                            .switch_value = flags.switch_value,
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                        });
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
                            .switch_value = flags.switch_value,
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
                        const ident_mangle = ident;
                        //const ident_mangle = try printString("f_{s}", .{ident});
                        const field_type = ob.get("type").?;
                        try newGenType(field_type, &child.d._struct, ident_mangle, .{ .gen_fields = true, .optional = .no });
                    }
                    if (flags.gen_fields)
                        try parent.fields.append(.{
                            .switch_value = flags.switch_value,
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                        });
                },
                .@"switch" => {
                    const sw_def = getV(a.items[1], .object);
                    const Tname = try printString("{s}{s}", .{ ns_prefix, fname });
                    const tag_type_name = sw_def.get("compareTo").?.string;
                    var found = false;
                    //TODO these (1.21.3) packets have the switch's tag variable somewhere other than the direct parent and use a path notation: ../mystupid/path
                    //Probably wontfix
                    //packet_player_info
                    //packet_declare_commands
                    //packet_advancements
                    var index: usize = 0;
                    for (parent.fields.items, 0..) |f, i| { //Search through parent's fields for matching tag
                        if (eql(u8, f.name, tag_type_name)) {
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

                    const child = try parent.newDecl(Tname);
                    const tag_type = try parent.fields.items[index].type.getIdentifier();
                    child.d = .{ ._union = .{
                        .psg = ParseStructGen.init(parent.alloc),
                    } };
                    child.d._union.psg.parse_as_union = true;
                    child.d._union.psg.parse_as_union_type = Tname;
                    child.d._union.info.tag_type = tag_type;
                    //If its a number
                    //we parse an varint
                    //we pass a varint to the thing and need to convert it into a tag
                    //we need to cast on both sides or pass the correct one
                    //DO THE IS NUM THINGE
                    const fields = sw_def.get("fields").?.object;
                    var f_it = fields.iterator();
                    var all_numeric = true;
                    while (f_it.next()) |f| {
                        const int_val = std.fmt.parseInt(i64, f.key_ptr.*, 10) catch {
                            //Not an int so we can continue
                            try newGenType(f.value_ptr.*, &child.d._union.psg, f.key_ptr.*, .{ .gen_fields = true, .optional = .no });
                            all_numeric = false;
                            continue;
                        };
                        try newGenType(f.value_ptr.*, &child.d._union.psg, try printString("{s}_v_{d}", .{ fname, int_val }), .{ .gen_fields = true, .optional = .no, .switch_value = int_val });
                    }
                    child.d._union.psg.parse_as_union_is_num = all_numeric;
                    const is_bool = blk: {
                        if (eql(u8, "Type_bool", tag_type)) {
                            if (child.d._union.psg.fields.items.len < 2) {
                                std.debug.print("Will not parse switch on bool with less than two values {s}\n", .{fname});
                                return error.notSupported;
                            }
                            break :blk true;
                        }
                        break :blk false;
                    };

                    //make the default branch the else branch
                    if (sw_def.get("default")) |default| {
                        child.d._union.info.has_default = true;
                        if (!is_bool and !all_numeric) {
                            std.debug.print("Switch with default is not supported on enumeration switches {s}\n", .{fname});
                            return error.notSupported;
                        }
                        try newGenType(default, &child.d._union.psg, "default", .{ .gen_fields = true, .optional = .no });
                    }

                    //If the compareTo is a boolean we need to indicate as such to convert the bool to an integer
                    //This is needed so zig won't complain about default vals in union Decl
                    for (child.d._union.psg.fields.items) |*f| {
                        f.dont_emit_default = true;
                        if (is_bool) {
                            if (eql(u8, f.name, "true")) {
                                f.switch_value = 1;
                            } else if (eql(u8, f.name, "false")) {
                                f.switch_value = 0;
                            } else if (eql(u8, f.name, "default")) {
                                //Do nothing for default, the null switch value indicates else branch of switch
                            } else {
                                std.debug.print("Bool with invalid field: {s}\n", .{f.name});
                                return error.notSupported;
                            }
                        }
                    }
                    if (child.d._union.psg.fields.items.len == 0) {
                        std.debug.print("Switch with zero fields not supported {s}\n", .{fname});
                        return error.notSupported;
                    }

                    if (all_numeric and child.d._union.psg.fields.items.len == 1) { //Special case for those stupid id or x
                        try child.d._union.psg.fields.append(.{
                            .switch_value = null, // make this the default branch
                            .name = "none",
                            .optional = .no,
                            .type = .{ .primitive = "void" },
                        });
                    }

                    //TODO ensure bool passed into parse fn is cast to an integer
                    child.d._union.info.category = blk: {
                        if (all_numeric)
                            break :blk .numeric;
                        if (is_bool)
                            break :blk .strict_bool;
                        break :blk .enumeration;
                    };

                    if (flags.gen_fields)
                        try parent.fields.append(.{
                            .switch_value = flags.switch_value,
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                            .switch_arg_name = tag_type_name,
                            .switch_arg_is_bool = is_bool,
                        });
                },
                .buffer, .array => {
                    const array_def = getV(a.items[1], .object);

                    const ekind: ParseStructGen.EmitKind = blk: {
                        const count_type_str = getV(array_def.get("countType") orelse {
                            switch (t) {
                                .array => { //An array without a countType must have a string count that points to parent var
                                    //const count_name = try printString("f_{s}", .{try getVE(array_def.get("count").?, .string)});
                                    const count_name = try getVE(array_def.get("count").?, .string);
                                    var found = false;
                                    var index: usize = 0;
                                    for (parent.fields.items, 0..) |f, i| { //Search through parent's fields for matching tag
                                        if (eql(u8, f.name, count_name)) {
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
                    try newGenType(child_type, &child.d._array.s, try printString("i_{s}", .{fname}), .{ .gen_fields = true, .optional = .no });
                    if (flags.gen_fields)
                        try parent.fields.append(.{
                            .switch_value = flags.switch_value,
                            .name = fname,
                            .optional = flags.optional,
                            .type = .{ .compound = child },
                            .counter_arg_name = if (ekind == .array_ref) ekind.array_ref.ref_name else null,
                        });
                },
                .option => {
                    //This ugly special case is used to deal with EffectDetail's recursive definition.
                    //If more packets do this uglyness we will need to traverse to determine if a field cyclic
                    if (a.items[1] == .string and eql(u8, a.items[1].string, "EffectDetail")) {
                        try newGenType(a.items[1], parent, fname, .{ .gen_fields = true, .optional = .yes_ptr });
                    } else {
                        try newGenType(a.items[1], parent, fname, .{ .gen_fields = true, .optional = .yes });
                    }
                },
            }
        },
        .string => |str| { //A string is a literal type
            if (flags.gen_fields) {
                try parent.fields.append(.{
                    .switch_value = flags.switch_value,
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
