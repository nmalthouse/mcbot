const std = @import("std");
const graph = @import("graph");
const dreg = @import("data_reg.zig");

pub const McAtlas = struct {
    const left_out_sentinal = std.math.maxInt(u16);
    texture: graph.Texture,
    protocol_id_to_atlas_map: []const u16,
    entry_w: usize,
    entry_span: usize,

    pub fn getTextureRec(self: *const @This(), protocol_id: u32) graph.Rect {
        const atlas_id_o = self.protocol_id_to_atlas_map[protocol_id];
        const atlas_id = if (atlas_id_o == left_out_sentinal) 0 else atlas_id_o;

        return graph.Rec(
            @as(f32, @floatFromInt((atlas_id % self.entry_span) * self.entry_w)),
            @as(f32, @floatFromInt((atlas_id / self.entry_span) * self.entry_w)),
            @as(f32, @floatFromInt(self.entry_w)),
            @as(f32, @floatFromInt(self.entry_w)),
        );
    }

    pub fn getTextureRecO(self: *const @This(), protocol_id: u32) ?graph.Rect {
        const atlas_id_o = self.protocol_id_to_atlas_map[protocol_id];
        if (atlas_id_o == left_out_sentinal) return null;
        return self.getTextureRec(protocol_id);
    }

    pub fn deinit(self: *const McAtlas, alloc: std.mem.Allocator) void {
        alloc.free(self.protocol_id_to_atlas_map);
    }
};

/// Builds a texture atlas given a directory of pngs and any array of structs with the fields {name:[]const u8, id:usize}.
/// Matches "name" with "name".png
/// The atlas returned can be indexed with the id field
pub fn buildAtlasGeneric(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    texture_pack_filename: []const u8,
    name_id_slice: anytype,
    res_path: []const u8, //Path to folder containing all the pngs we will atlas. Relative to the pack folder we pass in
    debug_img_path: []const u8, //Relative to cwd
) !McAtlas {
    const blocks = name_id_slice;
    var pack_dir = try dir.openDir(texture_pack_filename, .{});
    defer pack_dir.close();
    var itdir = try pack_dir.openDir(res_path, .{ .iterate = true });
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
        if (item.?.kind == .file) {
            const slice = try alloc.dupe(u8, item.?.name);
            try pngs.append(slice);
        }
    }

    const entry_w = 16;
    const width = @as(u32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(pngs.items.len))))));
    var atlas_bitmap = try graph.Bitmap.initBlank(alloc, width * entry_w, width * entry_w, .rgba_8);
    defer atlas_bitmap.data.deinit();

    var proto_map = std.ArrayList(u16).init(alloc);
    try proto_map.appendNTimes(McAtlas.left_out_sentinal, blocks.len);

    const Match = struct {
        pub fn ln(ctx: u8, a: @This(), b: @This()) bool {
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
    for (blocks) |block| {
        try matches.resize(0);
        for (pngs.items, 0..) |png_file, pi| {
            const idiff = std.mem.indexOfDiff(u8, png_file, block.name);
            if (idiff == block.name.len)
                try matches.append(.{ .index = pi, .len = png_file.len });
        }

        std.sort.insertion(Match, matches.items, @as(u8, 0), Match.ln);
        if (matches.items.len > 0) {
            var strcat = std.ArrayList(u8).init(alloc);
            defer strcat.deinit();
            try strcat.appendSlice(res_path);
            try strcat.append('/');
            try strcat.appendSlice(pngs.items[matches.items[0].index]);

            var bmp = try graph.Bitmap.initFromPngFile(alloc, itdir, pngs.items[matches.items[0].index]);
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
    try atlas_bitmap.writeToPngFile(std.fs.cwd(), debug_img_path);
    return McAtlas{
        .texture = graph.Texture.initFromBitmap(atlas_bitmap, .{ .mag_filter = graph.c.GL_NEAREST }),
        .protocol_id_to_atlas_map = try proto_map.toOwnedSlice(),
        .entry_w = entry_w,
        .entry_span = width,
    };
}
