//! Based on wiki.vg, MC Java only; all values are big-endian
//! Note that this library does not handle GZIPing; use std.compress for that

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
            var num_read = try self.child_reader.read(buffer);
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
        var writer = if (@hasField(@TypeOf(basic_writer.context), "n")) basic_writer else (IndentingStream(@TypeOf(basic_writer)){ .underlying_writer = basic_writer }).writer();

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
                writer.context.n += 1;
                for (list.entries.items) |ent|
                    try writer.print("\ntag_{s}(None): {}", .{ @tagName(ent), ent });
                writer.context.n -= 1;
                try writer.writeAll("\n}");
            },
            .compound => |com| {
                try writer.print("{d} entries {{", .{com.size});
                writer.context.n += 1;
                var it = com.iterator();
                while (it.next()) |ent|
                    try writer.print("\ntag_{s}('{s}'): {}", .{ @tagName(ent.value_ptr.*), ent.key_ptr.*, ent.value_ptr });
                writer.context.n -= 1;
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
};

// TODO: Handle readers without Error decls
pub fn ParseError(comptime ReaderType: type) type {
    return std.mem.Allocator.Error || ReaderType.Error || error{ InvalidNbt, EndOfStream };
}

pub const EntryWithName = struct { name: ?[]const u8, entry: Entry };

/// Caller owns returned memory. Using an Arena is recommended.
pub fn parse(allocator: std.mem.Allocator, reader: anytype) ParseError(@TypeOf(reader))!EntryWithName {
    return (try parseWithOptions(allocator, reader, true, null));
}

pub fn parseAsCompoundEntry(allocator: std.mem.Allocator, reader: anytype) ParseError(@TypeOf(reader))!Entry {
    var result = try parse(allocator, reader);
    var com = Entry.Compound{};
    try com.put(allocator, result.name.?, result.entry);
    return Entry{ .compound = com };
}

/// Caller owns returned memory. Using an Arena is recommended.
pub fn parseWithOptions(allocator: std.mem.Allocator, reader: anytype, in_compound: bool, tag_type: ?Tag) ParseError(@TypeOf(reader))!EntryWithName {
    const tag = tag_type orelse (std.meta.intToEnum(Tag, try reader.readByte()) catch return error.InvalidNbt);
    var name = if (in_compound and tag != .end) n: {
        var nn = try allocator.alloc(u8, try reader.readIntBig(u16));
        _ = try reader.readAll(nn);
        break :n nn;
    } else null;

    const entry: Entry = switch (tag) {
        .end => .end,
        .byte => .{ .byte = try reader.readIntBig(i8) },
        .short => .{ .short = try reader.readIntBig(i16) },
        .int => .{ .int = try reader.readIntBig(i32) },
        .long => .{ .long = try reader.readIntBig(i64) },
        .float => .{ .float = @as(f32, @bitCast(try reader.readIntBig(u32))) },
        .double => .{ .double = @as(f64, @bitCast(try reader.readIntBig(u64))) },
        .byte_array => ba: {
            const len = try reader.readIntBig(i32);
            std.debug.assert(len >= 0);
            var array = try allocator.alloc(i8, @as(usize, @intCast(len)));
            _ = try reader.readAll(@as([]u8, @ptrCast(array)));
            break :ba .{ .byte_array = array };
        },
        .string => str: {
            var string = try allocator.alloc(u8, try reader.readIntBig(u16));
            _ = try reader.readAll(string);
            break :str .{ .string = string };
        },
        .list => lis: {
            var entries = Entry.List.Entries{};
            const @"type" = std.meta.intToEnum(Tag, try reader.readByte()) catch return error.InvalidNbt;

            // TODO: Handle negatives, ends
            const len = try reader.readIntBig(i32);
            std.debug.assert(len >= 0);
            try entries.ensureTotalCapacity(allocator, @as(usize, @intCast(len)));
            entries.items.len = @as(usize, @intCast(len));

            for (entries.items) |*item|
                item.* = (try parseWithOptions(allocator, reader, false, @"type")).entry;

            break :lis .{ .list = .{ .type = @"type", .entries = entries } };
        },
        .compound => com: {
            var hashmap = Entry.Compound{};
            while (true) {
                const result = try parseWithOptions(allocator, reader, true, null);
                if (result.entry == .end) break;
                try hashmap.put(allocator, result.name.?, result.entry);
            }
            break :com .{ .compound = hashmap };
        },
        .int_array => ia: {
            const len = try reader.readIntBig(i32);
            std.debug.assert(len >= 0);
            var array = try allocator.alloc(i32, @as(usize, @intCast(len)));
            for (array) |*i| i.* = try reader.readIntBig(i32);
            break :ia .{ .int_array = array };
        },
        .long_array => la: {
            const len = try reader.readIntBig(i32);
            std.debug.assert(len >= 0);
            var array = try allocator.alloc(i64, @as(usize, @intCast(len)));
            for (array) |*i| i.* = try reader.readIntBig(i64);
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

    var data = try parseAsCompoundEntry(arena.allocator(), ungzip.reader());
    std.debug.print("\n\n{}\n\n", .{data});
}
