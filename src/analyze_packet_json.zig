const std = @import("std");
const com = @import("common.zig");
const eql = std.mem.eql;
const mc = @import("listener.zig");
const ids = @import("list.zig");

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

pub fn analyzeWalk(parent_alloc: std.mem.Allocator, dump_file_name: []const u8) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(parent_alloc);
    const alloc = arena_alloc.allocator();
    defer arena_alloc.deinit();
    const cwd = std.fs.cwd();
    const f = cwd.openFile(dump_file_name, .{}) catch null;
    const out_csv = try cwd.createFile("walkx.csv", .{});
    defer out_csv.close();
    const ow = out_csv.writer();
    if (f) |cont| {
        var buf: []const u8 = try cont.readToEndAlloc(alloc, 1024 * 1024 * 1024);
        //std.json.Parser is used rather than std.json.parse because the wireshark packet json is too complicated to parse into a zig struct
        var parser = std.json.Parser.init(alloc, false);
        const vtree = try parser.parse(buf);
        const packet_list = switch (vtree.root) {
            .Array => |arr| arr,
            else => return error.invalidJson,
        };
        for (packet_list.items) |item| {
            const obj = switch (item) {
                .Object => |obj| obj,
                else => return error.invalidJson,
            };
            const source = obj.get("_source") orelse continue;
            const layers = (try getJObj(source)).get("layers") orelse continue;
            const tcp = try getJObj((try getJObj(layers)).get("tcp") orelse continue);
            if (eql(u8, getVal(tcp.get("tcp.flags") orelse continue, .String) orelse continue, "0x0018")) { //0x0018 are PSH ACK flags

                const timestamps = getVal(tcp.get("Timestamps") orelse continue, .Object) orelse continue;
                const rel_time = try std.fmt.parseFloat(f32, getVal(timestamps.get("tcp.time_relative") orelse continue, .String) orelse continue);

                const payload = getVal(tcp.get("tcp.payload") orelse continue, .String) orelse continue;
                const MAX_SIZE = 4096;
                const replace_size = std.mem.replacementSize(u8, payload, ":", "");
                if (replace_size > MAX_SIZE) {
                    std.debug.print("PACKET TOO LONG\n", .{});
                    return error.packetTooLong;
                }
                var replace_buffer: [MAX_SIZE]u8 = undefined;
                const num_replaced = std.mem.replace(u8, payload, ":", "", &replace_buffer);
                _ = num_replaced;

                var byte_buf: [MAX_SIZE]u8 = undefined;
                const bytes = try std.fmt.hexToBytes(&byte_buf, replace_buffer[0..replace_size]);

                const fbsT = std.io.FixedBufferStream([]const u8);
                var fbs = fbsT{ .buffer = bytes, .pos = 0 };
                const parseT = mc.packetParseCtx(fbsT.Reader);
                var parse = parseT.init(fbs.reader(), alloc);
                const plen = parse.varInt();
                _ = plen;
                const pid = @as(u32, @intCast(parse.varInt()));

                const dstport = getVal(tcp.get("tcp.dstport") orelse continue, .String) orelse continue;
                const srcport = getVal(tcp.get("tcp.srcport") orelse continue, .String) orelse continue;

                if (eql(u8, srcport, "25565")) { //Clientbound
                    switch (@as(ids.packet_enum, @enumFromInt(pid))) {
                        .Set_Entity_Velocity,
                        .Set_Entity_Metadata,
                        .Update_Time,
                        .Update_Entity_Position,
                        .Update_Entity_Position_and_Rotation,
                        .Update_Entity_Rotation,
                        .Set_Head_Rotation,
                        => {},

                        else => {
                            std.debug.print("server sent packet: {s}\n", .{ids.packet_ids[pid]});
                        },
                    }
                }

                if (eql(u8, dstport, "25565")) { //Serverbound
                    switch (@as(ids.server_bound_enum, @enumFromInt(pid))) {
                        .Set_Player_Rotation => {},
                        .Set_Player_Position, .Set_Player_Position_and_Rotation => {
                            const x = parse.float(f64);
                            const y = parse.float(f64);
                            const z = parse.float(f64);
                            try ow.print("{d}, {d}, {d}, {d}\n", .{ rel_time, x, y, z });
                        },
                        .Click_Container => {
                            const wid = parse.int(u8);
                            _ = wid;
                            const state = parse.varInt();
                            _ = state;
                            const slot = parse.int(i16);
                            const button = parse.int(u8);
                            const mode = parse.varInt();

                            std.debug.print("index :{d} button: {d}, {d}\n", .{ slot, button, mode });
                            const num_items = parse.varInt();
                            var i: u32 = 0;
                            while (i < num_items) : (i += 1) {
                                const slot_index = parse.int(i16);
                                const sl = parse.slot();
                                std.debug.print("slot: {d} {any}\n", .{ slot_index, sl });
                            }
                            const carried = parse.slot();
                            std.debug.print("carried: {any}\n", .{carried});
                        },
                        else => {
                            std.debug.print("client sent packet: {s}\n", .{ids.ServerBoundPlayIds[pid]});
                        },
                    }
                }
            }
        }
    }
    //for (json_dump) |item| {
    //std.debug.print("{any}\n", .{item._source.layers.tcp.@"tcp.flags"});
    //}
}
