const std = @import("std");
const graph = @import("graph");

//For each block in blocks.json:
//  read_file(pack/assets/minecraft/models/block/block_name.json
//  extract texture name
//  load_png(pack/assets/minecraft/textures/block/texture_name

const BlockEntry = struct {
    const State = struct {
        name: []const u8,
        type: []const u8,
        num_values: u32,
    };

    id: u32,
    displayName: []const u8,
    name: []const u8,
    //hardness: f32,
    //resistance: f32,
    //minStateId: u32,
    //maxStateId: u32,
    //states: []State,
    //drops: []const u32,
    //diggable: bool,
    //transparent: bool,
    //filterLight: u8,
    //emitLight: u8,
    //boundingBox: []const u8,
    //stackSize: u32,
    //material: []const u8,
    //defaultState: u32,
};

pub fn readFileCwd(alloc: std.mem.Allocator, file_name: []const u8) ![]const u8 {
    const cwd = std.fs.cwd();
    var file = try cwd.openFile(file_name, .{});
    defer file.close();
    const r = file.reader();
    const slice = try r.readAllAlloc(alloc, std.math.maxInt(usize));
    return slice;
}

pub fn parseJsonFile(alloc: std.mem.Allocator, comptime T: type, file_name: []const u8) !T {
    const block_file_slice = try readFileCwd(alloc, file_name);
    defer alloc.free(block_file_slice);

    var ts = std.json.TokenStream.init(block_file_slice);

    const parse_opts: std.json.ParseOptions = .{ .allocator = alloc, .ignore_unknown_fields = true };
    @setEvalBranchQuota(10000);
    const json = try std.json.parse(T, &ts, parse_opts);
    return json;
}

pub fn parseJsonFileFree(alloc: std.mem.Allocator, comptime T: type, value: T) void {
    const parse_opts: std.json.ParseOptions = .{ .allocator = alloc, .ignore_unknown_fields = true };
    defer std.json.parseFree(T, value, parse_opts);
}

pub const McAtlas = struct {
    texture: graph.Texture,
    protocol_id_to_atlas_map: []const u16,
    entry_w: usize,
    entry_span: usize,

    pub fn getTextureRec(self: *const @This(), protocol_id: u32) graph.Rect {
        const atlas_id = self.protocol_id_to_atlas_map[protocol_id];
        return graph.Rec(
            @as(f32, @floatFromInt((atlas_id % self.entry_span) * self.entry_w)),
            @as(f32, @floatFromInt((atlas_id / self.entry_span) * self.entry_w)),
            @as(f32, @floatFromInt(self.entry_w)),
            @as(f32, @floatFromInt(self.entry_w)),
        );
    }

    pub fn deinit(self: *const McAtlas, alloc: std.mem.Allocator) void {
        alloc.free(self.protocol_id_to_atlas_map);
    }
};

pub fn buildAtlas(alloc: std.mem.Allocator) !McAtlas {
    //const block_file_slice = try readFileCwd(alloc, "minecraft/blocks.json");
    //defer alloc.free(block_file_slice);

    //var ts = std.json.TokenStream.init(block_file_slice);

    //const parse_opts: std.json.ParseOptions = .{ .allocator = alloc, .ignore_unknown_fields = true };
    //@setEvalBranchQuota(10000);
    //const json = try std.json.parse([]BlockEntry, &ts, parse_opts);
    //defer std.json.parseFree([]BlockEntry, json, parse_opts);

    const json = try parseJsonFile(alloc, []BlockEntry, "minecraft/blocks.json");
    defer parseJsonFileFree(alloc, []BlockEntry, json);
    {
        const it_dir_path = "minecraft/pack/assets/minecraft/textures/block";
        var itdir = try std.fs.cwd().openIterableDir(it_dir_path, .{});
        defer itdir.close();

        var pngs = std.ArrayList([]const u8).init(alloc);
        defer {
            for (pngs.items) |png| {
                alloc.free(png);
            }
            pngs.deinit();
        }

        var it = itdir.iterate();
        var item = try it.next();
        while (item != null) : (item = try it.next()) {
            if (item.?.kind == .File) {
                const slice = try alloc.alloc(u8, item.?.name.len);
                std.mem.copy(u8, slice, item.?.name);
                try pngs.append(slice);
            }
        }

        const entry_w = 16;
        const width = @as(u32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(pngs.items.len))))));
        var atlas_bitmap = try graph.Bitmap.initBlank(alloc, width * entry_w, width * entry_w);
        defer atlas_bitmap.data.deinit();

        var proto_map = std.ArrayList(u16).init(alloc);
        try proto_map.appendNTimes(0, json.len);

        const Match = struct {
            pub fn ln(comptime ctx: type, a: @This(), b: @This()) bool {
                _ = ctx;
                return a.len < b.len;
            }
            index: usize,
            len: usize,
        };
        var matches = std.ArrayList(Match).init(alloc);
        defer matches.deinit();

        var left_out_count: usize = 0;
        var atlas_index: usize = 0;
        for (json) |block| {
            try matches.resize(0);
            for (pngs.items, 0..) |png_file, pi| {
                const idiff = std.mem.indexOfDiff(u8, png_file, block.name);
                if (idiff == block.name.len)
                    try matches.append(.{ .index = pi, .len = png_file.len });
            }

            std.sort.sort(Match, matches.items, void, Match.ln);
            if (matches.items.len > 0) {
                var strcat = std.ArrayList(u8).init(alloc);
                defer strcat.deinit();
                try strcat.appendSlice(it_dir_path);
                try strcat.append('/');
                try strcat.appendSlice(pngs.items[matches.items[0].index]);

                var bmp = try graph.loadPngBitmap(strcat.items, &alloc);
                defer bmp.data.deinit();
                bmp.copySub(
                    0,
                    0,
                    entry_w,
                    entry_w,
                    &atlas_bitmap,
                    @as(u32, @intCast((atlas_index % width) * entry_w)),
                    @as(u32, @intCast((atlas_index / width) * entry_w)),
                );
                proto_map.items[block.id] = @as(u16, @intCast(atlas_index));

                atlas_index += 1;
            } else {
                left_out_count += 1;
            }
        }
        try atlas_bitmap.writeToBmpFile(alloc, "debug/mcatlas.bmp");
        std.debug.print("left out: {d}\n", .{left_out_count});
        return McAtlas{
            .texture = graph.Texture.fromArray(atlas_bitmap.data.items, atlas_bitmap.w, atlas_bitmap.h, .{ .mag_filter = graph.c.GL_NEAREST }),
            .protocol_id_to_atlas_map = proto_map.toOwnedSlice(),
            .entry_w = entry_w,
            .entry_span = width,
        };
    }
    return error.fucked;
}
