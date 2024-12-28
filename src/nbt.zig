//! Source file copied from https://github.com/SuperAuguste/zig-nbt
//! Based on wiki.vg, MC Java only; all values are big-endian
//! Note that this library does not handle GZIPing; use std.compress for that

//Licence:
//MIT License
//
//Copyright (c) 2022 zig-nbt contributors
//
//Permission is hereby granted, free of charge, to any person obtaining a copy
//of this software and associated documentation files (the "Software"), to deal
//in the Software without restriction, including without limitation the rights
//to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//copies of the Software, and to permit persons to whom the Software is
//furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all
//copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//SOFTWARE.

const std = @import("std");

pub fn TrackingReader(comptime readerT: type) type {
    return struct {
        const Self = @This();
        pub const Reader = std.io.Reader(*Self, readerT.Error, read);

        buffer: std.ArrayList(u8),
        child_reader: readerT,

        pub fn init(alloc: std.mem.Allocator, child_reader: readerT) Self {
            return Self{ .buffer = std.ArrayList(u8).init(alloc), .child_reader = child_reader };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn read(self: *Self, buffer: []u8) readerT.Error!usize {
            const num_read = try self.child_reader.read(buffer);
            self.buffer.appendSlice(buffer[0..num_read]) catch unreachable;
            return num_read;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}
//fn(*nbt.TrackingReader(io.reader.Reader(*io.fixed_buffer_stream.FixedBufferStream([]const u8),error{},(function 'read'))), []u8) error{}!usize'

//fn(nbt.TrackingReader(io.reader.Reader(*io.fixed_buffer_stream.FixedBufferStream([]const u8),error{},(function 'read'))), []u8) error{}!usize'

pub const Tag = enum(u8) {
    end,
    byte,
    short,
    int,
    long,
    float,
    double,
    byte_array,
    string,
    list,
    compound,
    int_array,
    long_array,
};

fn IndentingStream(comptime UnderlyingWriter: type) type {
    return struct {
        const Self = @This();
        pub const Error = UnderlyingWriter.Error;
        pub const Writer = std.io.Writer(Self, Error, write);

        underlying_writer: UnderlyingWriter,
        n: usize = 0,

        pub fn writer(self: Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: Self, bytes: []const u8) Error!usize {
            // var sections = std.mem.split(u8, bytes, "\n");
            // while (sections.next()) |sec| {
            //     try self.underlying_writer.writeByteNTimes('\t', self.n);
            //     try self.underlying_writer.writeAll(sec);
            // }
            var start: usize = 0;
            while (std.mem.indexOfScalar(u8, bytes[start..], '\n')) |ind| {
                try self.underlying_writer.writeAll(bytes[start..ind]);
                try self.underlying_writer.writeByte('\n');
                try self.underlying_writer.writeByteNTimes(' ', self.n * 4);
                start = ind + 1;
            }
            try self.underlying_writer.writeAll(bytes[start..]);
            return bytes.len;
        }
    };
}

pub const Entry = union(Tag) {
    pub const List = struct {
        pub const Entries = std.ArrayListUnmanaged(Entry);
        // TODO: Handle lists with anytypes (I believe they exist in the wild?)
        type: Tag,
        entries: Entries,
    };

    pub const Compound = std.StringHashMapUnmanaged(Entry);

    end,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const i8,
    /// Uses https://docs.oracle.com/javase/8/docs/api/java/io/DataInput.html#modified-utf-8
    string: []const u8,
    list: List,
    compound: Compound,
    int_array: []const i32,
    long_array: []const i64,

    pub fn format(value: Entry, comptime fmt: []const u8, options: std.fmt.FormatOptions, basic_writer: anytype) !void {
        _ = fmt;
        _ = options;

        // @compileLog(@hasField(@TypeOf(basic_writer), "n"));
        const writer = basic_writer;
        //var writer = if (@hasField(@TypeOf(basic_writer.context), "n")) basic_writer else (IndentingStream(@TypeOf(basic_writer)){ .underlying_writer = basic_writer }).writer();

        switch (value) {
            .end => try writer.writeAll("Tag_END"),
            .byte => |val| try writer.print("{d}", .{val}),
            .short => |val| try writer.print("{d}", .{val}),
            .int => |val| try writer.print("{d}", .{val}),
            .long => |val| try writer.print("{d}", .{val}),
            .float => |val| try writer.print("{d}", .{val}),
            .double => |val| try writer.print("{d}", .{val}),
            .byte_array => |ba| {
                try writer.writeAll("[B;");
                for (ba) |val| try writer.print("{d}, ", .{val});
                try writer.writeAll("]");
            },
            .string => |str| {
                try writer.writeAll("\"");
                if (str.len > 50) try writer.print("{s}[... {d} chars remaining]", .{ str[0..50], str.len - 50 }) else try writer.writeAll(str);
                try writer.writeAll("\"");
            },
            .list => |list| {
                try writer.print("{s}, {d} entries {{", .{ @tagName(list.type), list.entries.items.len });
                for (list.entries.items) |ent|
                    try writer.print("\ntag_{s}(None): {}", .{ @tagName(ent), ent });
                try writer.writeAll("\n}");
            },
            .compound => |com| {
                try writer.print("{d} entries {{", .{com.size});
                var it = com.iterator();
                while (it.next()) |ent|
                    try writer.print("\ntag_{s}('{s}'): {}", .{ @tagName(ent.value_ptr.*), ent.key_ptr.*, ent.value_ptr });
                try writer.writeAll("\n}");
            },
            .int_array => |ba| {
                try writer.writeAll("[I;");
                for (ba) |val| try writer.print("{d}, ", .{val});
                try writer.writeAll("]");
            },
            .long_array => |ba| {
                try writer.writeAll("[L;");
                for (ba) |val| try writer.print("{d}, ", .{val});
                try writer.writeAll("]");
            },
        }
    }

    //Does not track allocations, use an arena
    pub fn toJsonValue(self: Entry, alloc: std.mem.Allocator) !std.json.Value {
        return switch (self) {
            .end => .{ .null = {} },
            .byte => |b| .{ .integer = b },
            .short => |b| .{ .integer = b },
            .int => |b| .{ .integer = b },
            .long => |b| .{ .integer = b },
            .float => |b| .{ .float = b },
            .double => |b| .{ .float = b },
            .byte_array => |b| blk: {
                var list = std.ArrayList(std.json.Value).init(alloc);
                for (b) |it|
                    try list.append(.{ .integer = it });
                break :blk .{ .array = list };
            },
            .int_array => |b| blk: {
                var list = std.ArrayList(std.json.Value).init(alloc);
                for (b) |it|
                    try list.append(.{ .integer = it });
                break :blk .{ .array = list };
            },
            .long_array => |b| blk: {
                var list = std.ArrayList(std.json.Value).init(alloc);
                for (b) |it|
                    try list.append(.{ .integer = it });
                break :blk .{ .array = list };
            },
            .list => |b| blk: {
                var list = std.ArrayList(std.json.Value).init(alloc);
                for (b.entries.items) |it|
                    try list.append(try it.toJsonValue(alloc));
                break :blk .{ .array = list };
            },
            .compound => |cc| blk: {
                var it = cc.iterator();
                var map = std.json.ObjectMap.init(alloc);
                while (it.next()) |item| {
                    try map.put(item.key_ptr.*, try item.value_ptr.toJsonValue(alloc));
                }
                break :blk .{ .object = map };
            },
            .string => |b| .{ .string = b },
        };
    }
};

// TODO: Handle readers without Error decls
pub fn ParseError(comptime ReaderType: type) type {
    return std.mem.Allocator.Error || ReaderType.Error || error{ InvalidNbt, EndOfStream };
}

pub const EntryWithName = struct { name: ?[]const u8, entry: Entry };

/// Caller owns returned memory. Using an Arena is recommended.
//pub fn parse(allocator: std.mem.Allocator, reader: anytype) ParseError(@TypeOf(reader))!EntryWithName {
//    return (try parseWithOptions(allocator, reader, true, null));
//}

pub fn parseAnonCompound(alloc: std.mem.Allocator, reader: anytype, is_network: bool) ParseError(@TypeOf(reader))!Entry {
    const res = try parse(alloc, reader, .{ .in_compound = true, .tag_type = null, .is_networked_root = is_network });
    //if (res.entry != .compound) return error.InvalidNbt;
    return res.entry;
}

pub fn parseAsCompoundEntry(allocator: std.mem.Allocator, reader: anytype, is_network: bool) ParseError(@TypeOf(reader))!Entry {
    const result = try parse(allocator, reader, .{
        .in_compound = true,
        .tag_type = null,
        .is_networked_root = is_network,
    });
    var com = Entry.Compound{};
    try com.put(allocator, result.name orelse "", result.entry);
    return Entry{ .compound = com };
}

/// Caller owns returned memory. Using an Arena is recommended.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: anytype,
    options: struct {
        in_compound: bool = true,
        tag_type: ?Tag = null,
        is_networked_root: bool = false,
    },
) ParseError(@TypeOf(reader))!EntryWithName {
    const tag = options.tag_type orelse (std.meta.intToEnum(Tag, try reader.readByte()) catch return error.InvalidNbt);

    const name = if (!options.is_networked_root and options.in_compound and tag != .end) n: {
        const nn = try allocator.alloc(u8, try reader.readInt(u16, .big));
        _ = try reader.readAll(nn);
        break :n nn;
    } else null;

    const entry: Entry = switch (tag) {
        .end => .end,
        .byte => .{ .byte = try reader.readInt(i8, .big) },
        .short => .{ .short = try reader.readInt(i16, .big) },
        .int => .{ .int = try reader.readInt(i32, .big) },
        .long => .{ .long = try reader.readInt(i64, .big) },
        .float => .{ .float = @as(f32, @bitCast(try reader.readInt(u32, .big))) },
        .double => .{ .double = @as(f64, @bitCast(try reader.readInt(u64, .big))) },
        .byte_array => ba: {
            const len = try reader.readInt(i32, .big);
            std.debug.assert(len >= 0);
            const array = try allocator.alloc(i8, @as(usize, @intCast(len)));
            _ = try reader.readAll(@as([]u8, @ptrCast(array)));
            break :ba .{ .byte_array = array };
        },
        .string => str: {
            const string = try allocator.alloc(u8, try reader.readInt(u16, .big));
            _ = try reader.readAll(string);
            break :str .{ .string = string };
        },
        .list => lis: {
            var entries = Entry.List.Entries{};
            const @"type" = std.meta.intToEnum(Tag, try reader.readByte()) catch return error.InvalidNbt;

            // TODO: Handle negatives, ends
            const len = try reader.readInt(i32, .big);
            std.debug.assert(len >= 0);
            try entries.ensureTotalCapacity(allocator, @as(usize, @intCast(len)));
            entries.items.len = @as(usize, @intCast(len));

            for (entries.items) |*item|
                item.* = (try parse(allocator, reader, .{ .in_compound = false, .tag_type = @"type" })).entry;

            break :lis .{ .list = .{ .type = @"type", .entries = entries } };
        },
        .compound => com: {
            var hashmap = Entry.Compound{};
            while (true) {
                const result = try parse(allocator, reader, .{ .in_compound = true });
                if (result.entry == .end) break;
                try hashmap.put(allocator, result.name.?, result.entry);
            }
            break :com .{ .compound = hashmap };
        },
        .int_array => ia: {
            const len = try reader.readInt(i32, .big);
            std.debug.assert(len >= 0);
            const array = try allocator.alloc(i32, @as(usize, @intCast(len)));
            for (array) |*i| i.* = try reader.readInt(i32, .big);
            break :ia .{ .int_array = array };
        },
        .long_array => la: {
            const len = try reader.readInt(i32, .big);
            std.debug.assert(len >= 0);
            const array = try allocator.alloc(i64, @as(usize, @intCast(len)));
            for (array) |*i| i.* = try reader.readInt(i64, .big);
            break :la .{ .long_array = array };
        },
    };

    return EntryWithName{
        .name = name,
        .entry = entry,
    };
}

test "serial" {
    var servers = try std.fs.cwd().openFile("test/bigtest.nbt", .{});
    defer servers.close();

    var ungzip = try std.compress.gzip.gzipStream(std.testing.allocator, servers.reader());
    defer ungzip.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var data = try parseAsCompoundEntry(arena.allocator(), ungzip.reader());

    var out = std.ArrayList(u8).init(arena.allocator());
    defer out.deinit();

    try data.serialize(out.writer());
}

test "servers.dat" {
    if (true)
        return;
    var servers = try std.fs.cwd().openFile("test/bigtest.nbt", .{});
    defer servers.close();

    var ungzip = try std.compress.gzip.gzipStream(std.testing.allocator, servers.reader());
    defer ungzip.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data = try parseAsCompoundEntry(arena.allocator(), ungzip.reader());
    std.debug.print("\n\n{}\n\n", .{data});
}
