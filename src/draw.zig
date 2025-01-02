const std = @import("std");
const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;
const Entity = mcTypes.Entity;
const Lua = graph.Lua;
const graph = @import("graph");
const common = @import("common.zig");
const mcBlockAtlas = @import("mc_block_atlas.zig");
const bot = @import("bot.zig");
const Bot = bot.Bot;
const vector = @import("vector.zig");
const V3f = vector.V3f;
const shortV3i = vector.shortV3i;
const V3i = vector.V3i;
const V2i = vector.V2i;
const astar = @import("astar.zig");
const Reg = @import("data_reg.zig");
const DrawStuff = struct {
    const VertMapxT = std.AutoHashMap(i32, ChunkVerts);
    const VertMapT = std.AutoHashMap(i32, VertMapxT);

    const RebuildItem = struct {
        vertex_array: ?std.ArrayList(graph.CubeVert) = null,
        index_array: ?std.ArrayList(u32) = null,

        cx: i32,
        cy: i32,
        delete: bool,
    };

    const RebuildContext = struct {
        ready: std.ArrayList(RebuildItem),
        ready_mutex: std.Thread.Mutex = .{},

        should_exit_mutex: std.Thread.Mutex = .{}, //once the rebuild thread can lock this it will return
    };

    const Verts = struct {
        map: VertMapT,

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .map = VertMapT.init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.map.iterator();
            while (it.next()) |kv| {
                var zit = kv.value_ptr.iterator();
                while (zit.next()) |zkv| { //Cubes
                    zkv.value_ptr.cubes.deinit();
                }
                kv.value_ptr.deinit();
            }
            self.map.deinit();
        }
    };

    const ChunkVerts = struct {
        cubes: graph.Cubes,
    };
};
pub fn chunkRebuildThread(alloc: std.mem.Allocator, world: *McWorld, bot1: *Bot, ctx: *DrawStuff.RebuildContext, mc_atlas: anytype) !void {
    while (true) {
        //TODO render chunk sections instead of chunk columns,
        //test for visibility
        //TODO for now this just spins
        if (ctx.should_exit_mutex.tryLock()) {
            ctx.should_exit_mutex.unlock();
            return;
        }
        //const max_chunk_build_time = std.time.ns_per_s / 8;
        const max_chunk_build_time = std.time.ns_per_s / 20 * 5;
        std.time.sleep(std.time.ns_per_s / 100);
        var chunk_build_timer = try std.time.Timer.start();
        var num_removed: usize = 0;
        bot1.modify_mutex.lock();
        const dim = bot1.dimension_id;
        //const pos = bot1.pos;
        bot1.modify_mutex.unlock();
        const cdata = world.chunkdata(dim);
        {
            cdata.rw_lock.lockShared();
            const num_items = cdata.rebuild_notify.items.len;
            for (cdata.rebuild_notify.items, 0..) |item, rebuild_i| {
                if (chunk_build_timer.read() > max_chunk_build_time) {
                    num_removed = rebuild_i;
                    break;
                }
                defer num_removed += 1;

                var new_verts = std.ArrayList(graph.CubeVert).init(alloc);
                var new_index = std.ArrayList(u32).init(alloc);
                var should_delete: bool = false;

                if (cdata.x.get(item.x)) |xx| {
                    if (xx.get(item.y)) |chunk| {
                        for (chunk.sections.items, 0..) |sec, sec_i| {
                            //if (@divTrunc(@as(i32, @intFromFloat(pos.?.y)) - cdata.y_offset, 16) - @as(i32, @intCast(sec_i)) > 3)
                            //continue; //Only render chunks close to player, for quick render when debug
                            //if (!display_caves and sec_i < 7) continue;
                            if (sec.bits_per_entry == 0) continue;
                            //var s_it = mc.ChunkSection.DataIterator{ .buffer = sec.data.items, .bits_per_entry = sec.bits_per_entry };
                            //var block = s_it.next();

                            {
                                var i: u32 = 0;
                                while (i < 16 * 16 * 16) : (i += 1) {
                                    const block = sec.getBlockFromIndex(i);
                                    const binfo = world.reg.getBlockFromState(block.block);
                                    const bid = binfo.id;
                                    if (bid == 0)
                                        continue;
                                    //const colors = if (bid == grass_block_id) [_]u32{0x77c05aff} ** 6 else null;
                                    //const cc = [_]u32{0xffffffff} ** 6;
                                    const cc = [6]u32{
                                        0xffffffff,
                                        0x222222ff,
                                        0x888888ff,
                                        0x777777ff,
                                        0x999999ff,
                                        0x888888ff,
                                    };
                                    const co = block.pos;
                                    const x = co.x + item.x * 16;
                                    const y = (co.y + @as(i32, @intCast(sec_i)) * 16) + cdata.y_offset;
                                    const z = co.z + item.y * 16;
                                    const fx: f32 = @floatFromInt(x);
                                    const fy: f32 = @floatFromInt(y);
                                    const fz: f32 = @floatFromInt(z);
                                    const cb = graph.cubeVert;
                                    const sx = 1;
                                    const sy = 1;
                                    const sz = 1;
                                    const ti = 0;

                                    const un = graph.GL.normalizeTexRect(mc_atlas.getTextureRec(bid), @as(i32, @intCast(mc_atlas.texture.w)), @as(i32, @intCast(mc_atlas.texture.h)));
                                    const uxx = un.x + un.w;
                                    const uyy = un.y + un.h;
                                    if (cdata.getBlock(V3i.new(x, y + 1, z)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx, fy + sy, fz, un.x, uyy, 0, 1, 0, cc[3], 1, 0, 0, ti),
                                            cb(fx, fy + sy, fz + sz, un.x, un.y, 0, 1, 0, cc[3], 1, 0, 0, ti),
                                            cb(fx + sx, fy + sy, fz + sz, uxx, un.y, 0, 1, 0, cc[3], 1, 0, 0, ti),
                                            cb(fx + sx, fy + sy, fz, uxx, uyy, 0, 1, 0, cc[3], 1, 0, 0, ti),
                                        });
                                    }

                                    if (cdata.getBlock(V3i.new(x, y - 1, z)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx + sx, fy, fz, uxx, uyy, 0, -1, 0, cc[2], 1, 0, 0, ti),
                                            cb(fx + sx, fy, fz + sz, uxx, un.y, 0, -1, 0, cc[2], 1, 0, 0, ti),
                                            cb(fx, fy, fz + sz, un.x, un.y, 0, -1, 0, cc[2], 1, 0, 0, ti),
                                            cb(fx, fy, fz, un.x, uyy, 0, -1, 0, cc[2], 1, 0, 0, ti),
                                        });
                                    }

                                    if (cdata.getBlock(V3i.new(x + 1, y, z)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx + sx, fy + sy, fz + sz, un.x, uyy, 1, 0, 0, cc[5], 0, -1, 0, ti),
                                            cb(fx + sx, fy, fz + sz, un.x, un.y, 1, 0, 0, cc[5], 0, -1, 0, ti),
                                            cb(fx + sx, fy, fz, uxx, un.y, 1, 0, 0, cc[5], 0, -1, 0, ti),
                                            cb(fx + sx, fy + sy, fz, uxx, uyy, 1, 0, 0, cc[5], 0, -1, 0, ti),
                                        });
                                    }
                                    if (cdata.getBlock(V3i.new(x - 1, y, z)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx, fy + sy, fz, uxx, uyy, -1, 0, 0, cc[4], 0, 1, 0, ti),
                                            cb(fx, fy, fz, uxx, un.y, -1, 0, 0, cc[4], 0, 1, 0, ti),
                                            cb(fx, fy, fz + sz, un.x, un.y, -1, 0, 0, cc[4], 0, 1, 0, ti),
                                            cb(fx, fy + sy, fz + sz, un.x, uyy, -1, 0, 0, cc[4], 0, 1, 0, ti),
                                        });
                                    }
                                    if (cdata.getBlock(V3i.new(x, y, z + 1)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx, fy + sy, fz + sz, un.x, uyy, 0, 0, 1, cc[1], 1, 0, 0, ti), //3
                                            cb(fx, fy, fz + sz, un.x, un.y, 0, 0, 1, cc[1], 1, 0, 0, ti), //2
                                            cb(fx + sx, fy, fz + sz, uxx, un.y, 0, 0, 1, cc[1], 1, 0, 0, ti), //1
                                            cb(fx + sx, fy + sy, fz + sz, uxx, uyy, 0, 0, 1, cc[1], 1, 0, 0, ti), //0
                                        });
                                    }
                                    if (cdata.getBlock(V3i.new(x, y, z - 1)) orelse 0 == 0) {
                                        const ind: u32 = @intCast(new_verts.items.len);
                                        try new_index.appendSlice(&[6]u32{ ind + 0, ind + 1, ind + 3, ind + 1, ind + 2, ind + 3 });
                                        try new_verts.appendSlice(&.{
                                            cb(fx + sx, fy + sy, fz, uxx, uyy, 0, 0, -1, cc[0], 1, 0, 0, ti), //0
                                            cb(fx + sx, fy, fz, uxx, un.y, 0, 0, -1, cc[0], 1, 0, 0, ti), //1
                                            cb(fx, fy, fz, un.x, un.y, 0, 0, -1, cc[0], 1, 0, 0, ti), //2
                                            cb(fx, fy + sy, fz, un.x, uyy, 0, 0, -1, cc[0], 1, 0, 0, ti), //3
                                        });
                                    }
                                }
                            }
                        }
                        //vz.value_ptr.cubes.setData();
                    } else {
                        should_delete = true;
                        //TODO NOTIFY REMOVE UNLOADED CHUNK

                        //vert_map.main_mutex.lock(); //Modifying main map
                        //_ = vx.value_ptr.remove(item.y);
                        //vert_map.main_mutex.unlock();
                    }
                }
                ctx.ready_mutex.lock();
                if (should_delete) {
                    try ctx.ready.append(.{ .delete = true, .cx = item.x, .cy = item.y });
                } else {
                    try ctx.ready.append(.{
                        .delete = false,
                        .vertex_array = new_verts,
                        .index_array = new_index,
                        .cx = item.x,
                        .cy = item.y,
                    });
                }
                ctx.ready_mutex.unlock();
            }
            cdata.rw_lock.unlockShared();
            if (num_items > 0) {
                cdata.rw_lock.lock();
                defer cdata.rw_lock.unlock();
                for (0..num_removed) |_| {
                    _ = cdata.rebuild_notify.orderedRemove(0);
                }
            }
        }
    }
}
pub fn drawThread(alloc: std.mem.Allocator, world: *McWorld) !void {
    const InvMap = struct {
        default: []const [2]f32,
        generic_9x3: []const [2]f32,
    };
    const inv_map = try common.readJson(std.fs.cwd(), "inv_map.json", alloc, InvMap);
    defer inv_map.deinit();

    var win = try graph.SDL.Window.createWindow("Debug mcbot Window", .{});
    defer win.destroyWindow();

    const mc_atlas = try mcBlockAtlas.buildAtlasGeneric(
        alloc,
        std.fs.cwd(),
        "res_pack",
        world.reg.blocks,
        "assets/minecraft/textures/block",
        "debug/mc_atlas.png",
    );
    defer mc_atlas.deinit(alloc);

    const item_atlas = try mcBlockAtlas.buildAtlasGeneric(
        alloc,
        std.fs.cwd(),
        "res_pack",
        world.reg.items,
        "assets/minecraft/textures/item",
        "debug/mc_itematlas.bmp",
    );
    defer item_atlas.deinit(alloc);

    var strbuf: [32]u8 = undefined;
    var fbs = std.io.FixedBufferStream([]u8){ .buffer = &strbuf, .pos = 0 };

    var invtex = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "res_pack/assets/minecraft/textures/gui/container/inventory.png", .{ .mag_filter = graph.c.GL_NEAREST });
    defer invtex.deinit();

    var invtex2 = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "res_pack/assets/minecraft/textures/gui/container/shulker_box.png", .{});
    defer invtex2.deinit();

    var camera = graph.Camera3D{};
    camera.pos.data = [_]f32{ -2.20040695e+02, 6.80385284e+01, 1.00785331e+02 };
    win.grabMouse(true);

    //A chunk is just a vertex array
    var vert_map = DrawStuff.Verts.init(alloc);
    defer vert_map.deinit();

    var position_synced = false;

    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/fonts/roboto.ttf", 16, 163, .{});
    defer font.deinit();

    const M = graph.SDL.keycodes.Keymod;
    const None = comptime M.mask(&.{.NONE});
    const KeyMap = graph.Bind(&.{
        .{ .name = "print_coord", .bind = .{ .C, None } },
        .{ .name = "toggle_draw_nodes", .bind = .{ .T, None } },
        .{ .name = "toggle_inventory", .bind = .{ .E, None } },
        .{ .name = "toggle_caves", .bind = .{ .F, None } },
    });
    var testmap = KeyMap.init();

    var draw_nodes: bool = false;

    const bot1 = &(world.bot_threads[0].?.bot);
    //const grass_block_id = world.reg.getBlockFromName("grass_block");

    var gctx = graph.ImmediateDrawingContext.init(alloc, 123);
    defer gctx.deinit();
    var cubes = graph.Cubes.init(alloc, mc_atlas.texture, gctx.textured_tri_3d_shader);
    defer cubes.deinit();

    var astar_ctx_mutex: std.Thread.Mutex = .{};
    var astar_ctx = astar.AStarContext.init(alloc, world, bot1.dimension_id);
    defer astar_ctx.deinit();
    {
        try gctx.begin(0x263556ff, win.screen_dimensions.toF());
        win.pumpEvents();
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        gctx.text(.{ .x = 40, .y = 30 }, "LOADING CHUNKS", &font, 72, 0xffffffff);
        try gctx.end(null);
        win.swap();
    }
    var draw_inventory = true;
    var display_caves = false;

    var rebuild_ctx = DrawStuff.RebuildContext{
        .ready = std.ArrayList(DrawStuff.RebuildItem).init(alloc),
    };
    rebuild_ctx.should_exit_mutex.lock();

    const rebuild_thread = try std.Thread.spawn(.{}, chunkRebuildThread, .{
        alloc,
        world,
        bot1,
        &rebuild_ctx,
        &mc_atlas,
    });
    defer rebuild_thread.join();
    defer { //This must happend before rebuild_thread tries to join
        rebuild_ctx.should_exit_mutex.unlock();
        rebuild_ctx.ready_mutex.lock();
        rebuild_ctx.ready.deinit();
    }
    const ts = 30;

    //graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
    while (!win.should_exit) {
        bot1.modify_mutex.lock();
        const dim_id = bot1.dimension_id;
        bot1.modify_mutex.unlock();
        try gctx.begin(0x467b8cff, win.screen_dimensions.toF());
        try cubes.indicies.resize(0);
        try cubes.vertices.resize(0);
        win.pumpEvents();
        camera.updateDebugMove(.{
            .down = win.keyHigh(.LSHIFT),
            .up = win.keyHigh(.SPACE),
            .left = win.keyHigh(.A),
            .right = win.keyHigh(.D),
            .fwd = win.keyHigh(.W),
            .bwd = win.keyHigh(.S),
            .mouse_delta = win.mouse.delta,
            .scroll_delta = win.mouse.wheel_delta.y,
        });
        const cmatrix = camera.getMatrix(3840.0 / 2160.0, 0.1, 100000);

        for (win.keys.slice()) |key| {
            switch (testmap.getWithMod(key.scancode, 0) orelse continue) {
                .print_coord => std.debug.print("Camera pos: {any}\n", .{camera.pos}),
                .toggle_draw_nodes => draw_nodes = !draw_nodes,
                .toggle_inventory => draw_inventory = !draw_inventory,
                .toggle_caves => display_caves = !display_caves,
            }
        }
        {
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
            var e_it = world.entities.valueIterator();
            while (e_it.next()) |e| {
                try drawTextCube(&win, &gctx, cmatrix, &cubes, e.pos, mc_atlas.getTextureRec(88), @tagName(e.kind), &font);
            }
        }
        //{
        //    world.sign_waypoints_mutex.lock();
        //    defer world.sign_waypoints_mutex.unlock();
        //    var w_it = world.sign_waypoints.iterator();
        //    while (w_it.next()) |w| {
        //        try drawTextCube(&win, &gctx, cmatrix, &cubes, w.value_ptr.pos.toF(), mc_atlas.getTextureRec(88), w.key_ptr.*, &font);
        //    }
        //}

        if (draw_nodes and astar_ctx_mutex.tryLock()) {
            var it = astar_ctx.openq.iterator();
            while (it.next()) |item| {
                try cubes.cubeExtra(
                    @as(f32, @floatFromInt(item.x)),
                    @as(f32, @floatFromInt(item.y)),
                    @as(f32, @floatFromInt(item.z)),
                    0.7,
                    0.2,
                    0.6,
                    mc_atlas.getTextureRec(1),
                    0,
                    [_]u32{0xcb41dbff} ** 6,
                );
            }
            var cit = astar_ctx.closed.valueIterator();
            while (cit.next()) |itemp| {
                const item = itemp.*;
                const vv = V3f.newi(item.x, item.y, item.z);
                try cubes.cubeExtra(
                    @as(f32, @floatFromInt(item.x)),
                    @as(f32, @floatFromInt(item.y)),
                    @as(f32, @floatFromInt(item.z)),
                    0.7,
                    0.2,
                    0.6,
                    mc_atlas.getTextureRec(1),
                    0,
                    [_]u32{0xff0000ff} ** 6,
                );
                fbs.reset();
                const H = item.H * 20;
                try fbs.writer().print("{d} {d}: {d}", .{ H, item.G, item.G + H });
                try drawTextCube(&win, &gctx, cmatrix, &cubes, vv, graph.Rec(0, 0, 0, 0), fbs.getWritten(), &font);
            }
            astar_ctx_mutex.unlock();
        }

        if (world.chunkdata(dim_id).rw_lock.tryLockShared()) {
            defer world.chunkdata(dim_id).rw_lock.unlockShared();
            {
                //Camera raycast to block
                const point_start = camera.pos;
                const count = 10;
                var t: f32 = 1;
                var i: u32 = 0;
                while (t < count) {
                    i += 1;
                    const mx = camera.front.data[0];
                    const my = camera.front.data[1];
                    const mz = camera.front.data[2];
                    t += 0.001;

                    const next_xt = if (@abs(mx) < 0.001) 100000 else ((if (mx > 0) @ceil(mx * t + point_start.data[0]) else @floor(mx * t + point_start.data[0])) - point_start.data[0]) / mx;
                    const next_yt = if (@abs(my) < 0.001) 100000 else ((if (my > 0) @ceil(my * t + point_start.data[1]) else @floor(my * t + point_start.data[1])) - point_start.data[1]) / my;
                    const next_zt = if (@abs(mz) < 0.001) 100000 else ((if (mz > 0) @ceil(mz * t + point_start.data[2]) else @floor(mz * t + point_start.data[2])) - point_start.data[2]) / mz;
                    if (i > 10) break;

                    t = @min(next_xt, next_yt, next_zt);
                    if (t > count)
                        break;

                    const point = point_start.add(camera.front.scale(t + 0.01)).data;
                    //const point = point_start.lerp(point_end, t / count).data;
                    const pi = V3i{
                        .x = @as(i32, @intFromFloat(@floor(point[0]))),
                        .y = @as(i32, @intFromFloat(@floor(point[1]))),
                        .z = @as(i32, @intFromFloat(@floor(point[2]))),
                    };
                    if (world.chunkdata(dim_id).getBlock(pi)) |block| {
                        const cam_pos = world.chunkdata(dim_id).getBlock(V3f.fromZa(camera.pos).toIFloor()) orelse 0;
                        if (block != 0 and cam_pos == 0) {
                            try cubes.cubeExtra(
                                @as(f32, @floatFromInt(pi.x)),
                                @as(f32, @floatFromInt(pi.y)),
                                @as(f32, @floatFromInt(pi.z)),
                                1.1,
                                1.2,
                                1.1,
                                mc_atlas.getTextureRec(1),
                                0,
                                [_]u32{0xcb41db66} ** 6,
                            );
                            if (win.keyHigh(.LSHIFT)) {
                                const center = win.screen_dimensions.toF().smul(0.5);
                                gctx.textFmt(center, "{d}", .{block}, &font, ts, 0xffffffff);
                            }

                            if (win.mouse.left == .rising) {
                                bot1.modify_mutex.lock();
                                bot1.action_index = null;

                                bot1.modify_mutex.unlock();
                            }
                            if (win.mouse.right == .rising) {
                                std.debug.print("DOING THE FLOOD\n", .{});
                            }

                            break;
                        }
                    }
                }
            }
        }

        if (rebuild_ctx.ready_mutex.tryLock()) {
            defer rebuild_ctx.ready_mutex.unlock();
            for (rebuild_ctx.ready.items) |rd| {
                const vx = try vert_map.map.getOrPut(rd.cx);
                if (!vx.found_existing) {
                    vx.value_ptr.* = DrawStuff.VertMapxT.init(alloc);
                }
                const vz = try vx.value_ptr.getOrPut(rd.cy);
                if (!vz.found_existing) {
                    vz.value_ptr.cubes = graph.Cubes.init(alloc, mc_atlas.texture, gctx.textured_tri_3d_shader);
                }
                if (rd.delete) {
                    vz.value_ptr.cubes.deinit();
                    _ = vx.value_ptr.remove(rd.cy);
                } else {
                    vz.value_ptr.cubes.vertices.deinit();
                    vz.value_ptr.cubes.indicies.deinit();
                    vz.value_ptr.cubes.vertices = rd.vertex_array.?;
                    vz.value_ptr.cubes.indicies = rd.index_array.?;
                    vz.value_ptr.cubes.setData();
                }
            }
            try rebuild_ctx.ready.resize(0);
        }

        { //Draw the chunks
            var it = vert_map.map.iterator();
            while (it.next()) |kv| {
                var zit = kv.value_ptr.iterator();
                while (zit.next()) |kv2| {
                    kv2.value_ptr.cubes.draw(cmatrix, graph.za.Mat4.identity());

                    //kv2.value_ptr.cubes.draw(win.screen_dimensions, cmatrix);
                }
            }
        }

        {
            bot1.modify_mutex.lock();
            defer bot1.modify_mutex.unlock();
            if (bot1.pos) |bpos| {
                if (!position_synced) {
                    position_synced = true;
                    camera.pos = graph.za.Vec3.new(@floatCast(bpos.x), @floatCast(bpos.y + 3), @floatCast(bpos.z));
                }
                const p = bpos.toF32();
                try cubes.cubeExtra(
                    p.x - 0.3,
                    p.y,
                    p.z - 0.3,
                    0.6,
                    1.8,
                    0.6,
                    mc_atlas.getTextureRec(1),
                    0,
                    [_]u32{0xcb41dbff} ** 6,
                );
            }
            if (bot1.action_list.items.len > 0) {
                const list = bot1.action_list.items;
                var last_pos = bot1.pos.?;
                var i: usize = list.len;
                while (i > 0) : (i -= 1) {
                    switch (list[i - 1]) {
                        .movement => |move| {
                            const color: u32 = switch (move.kind) {
                                .walk => 0xff0000ff,
                                .fall => 0x0fff00ff,
                                .jump => 0x000fffff,
                                .ladder => 0x2222ffff,
                                .gap => 0x00ff00ff,
                                else => 0x000000ff,
                            };
                            const p = move.pos.toF32();
                            const lp = last_pos.toF32();
                            gctx.line3D(graph.za.Vec3.new(lp.x, lp.y + 1, lp.z), graph.za.Vec3.new(p.x, p.y + 1, p.z), 0xffffffff);
                            last_pos = move.pos;
                            try cubes.cubeExtra(
                                p.x,
                                p.y,
                                p.z,
                                0.2,
                                0.2,
                                0.2,
                                mc_atlas.getTextureRec(1),
                                0,
                                [_]u32{color} ** 6,
                            );
                        },
                        else => {},
                    }
                }
            }
        }

        cubes.setData();
        cubes.draw(graph.za.Mat4.identity(), cmatrix);
        //cubes.draw(win.screen_dimensions, cmatrix);

        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        if (draw_inventory) {
            bot1.modify_mutex.lock();
            defer bot1.modify_mutex.unlock();
            world.entities_mutex.lock();
            defer world.entities_mutex.unlock();
            const area = graph.Rec(0, 0, @divTrunc(win.screen_dimensions.x, 3), @divTrunc(win.screen_dimensions.x, 3));
            const invtexrec = graph.Rec(0, 0, 176, 166);
            const sx = area.w / invtexrec.w;
            const sy = area.h / invtexrec.h;
            gctx.rectTex(area, invtexrec, invtex);
            for (bot1.inventory.slots.items, 0..) |slot, i| {
                const rr = inv_map.value.default[i];
                const rect = graph.Rec(area.x + rr[0] * sx, area.y + rr[1] * sy, 16 * sx, 16 * sy);
                if (slot.count > 0) {
                    if (item_atlas.getTextureRecO(slot.item_id)) |tr| {
                        gctx.rectTex(rect, tr, item_atlas.texture);
                    } else {
                        const item = world.reg.getItem(slot.item_id);
                        if (world.reg.getBlockFromNameI(item.name)) |block| {
                            if (mc_atlas.getTextureRecO(block.id)) |tr| {
                                gctx.rectTex(rect, tr, mc_atlas.texture);
                            }
                        } else {
                            gctx.text(rect.pos(), item.name, &font, 12, 0xff);
                        }
                    }
                    gctx.textFmt(rect.pos().add(.{ .x = 0, .y = rect.h / 2 }), "{d}", .{slot.count}, &font, ts, 0xff);
                }
            }

            if (bot1.interacted_inventory.win_id != null) {
                drawInventory(&gctx, &mc_atlas, &item_atlas, world.reg, &font, area.addV(area.w + 20, 0), &bot1.interacted_inventory);
            }
            const statsr = graph.Rec(0, area.y + area.h, 400, 300);
            gctx.rect(statsr, 0xffffffff);
            gctx.textFmt(
                statsr.pos().add(.{ .x = 0, .y = 10 }),
                "health :{d}/20\nhunger: {d}/20\nName: {s}\nSaturation: {d}\nEnt id: {d}\nent count: {d}",
                .{
                    bot1.health,
                    bot1.food,
                    bot1.name,
                    bot1.food_saturation,
                    bot1.e_id,
                    world.entities.count(),
                },
                &font,
                ts,
                0xff,
            );
        }
        gctx.rect(graph.Rec(@divTrunc(win.screen_dimensions.x, 2), @divTrunc(win.screen_dimensions.y, 2), 10, 10), 0xffffffff);

        { //binding info draw
            const num_lines = KeyMap.bindlist.len;
            const fs = ts;
            const px_per_line = font.ptToPixel(12);
            const h = num_lines * px_per_line;
            const area = graph.Rec(0, @as(f32, @floatFromInt(win.screen_dimensions.y)) - h, 500, h);
            var y = area.y;
            for (KeyMap.bindlist) |b| {
                gctx.textFmt(.{ .x = area.x, .y = y }, "{s}: {s}", .{ b.name, @tagName(b.bind[0]) }, &font, fs, 0xffffffff);
                y += px_per_line;
            }
        }
        try gctx.end(null);
        //try ctx.beginDraw(graph.itc(0x2f2f2fff));
        //ctx.drawText(40, 40, "hello", &font, 16, graph.itc(0xffffffff));
        //ctx.endDraw(win.screen_width, win.screen_height);
        win.swap();
    }
}
fn drawInventory(
    gctx: *graph.ImmediateDrawingContext,
    block_atlas: *const mcBlockAtlas.McAtlas,
    item_atlas: *const mcBlockAtlas.McAtlas,
    reg: *const Reg.DataReg,
    font: *graph.Font,
    area: graph.Rect,
    inventory: *const bot.Inventory,
) void {
    const w = area.w;
    const icx = 9;
    const padding = 4;
    const iw: f32 = w / icx;
    //const h = w;
    for (inventory.slots.items, 0..) |slot, i| {
        const rr = graph.Rec(
            area.x + @as(f32, @floatFromInt(i % icx)) * iw,
            area.y + @as(f32, @floatFromInt(i / icx)) * iw,
            iw - padding,
            iw - padding,
        );
        gctx.rect(rr, 0xffffffff);
        if (slot.count > 0) {
            if (item_atlas.getTextureRecO(slot.item_id)) |tr| {
                gctx.rectTex(rr, tr, item_atlas.texture);
            } else {
                const item = reg.getItem(slot.item_id);
                if (reg.getBlockFromNameI(item.name)) |block| {
                    if (block_atlas.getTextureRecO(block.id)) |tr| {
                        gctx.rectTex(rr, tr, block_atlas.texture);
                    }
                } else {
                    gctx.text(rr.pos(), item.name, font, 12, 0xff);
                }
            }
            gctx.textFmt(rr.pos().add(.{ .x = 0, .y = rr.h / 2 }), "{d}", .{slot.count}, font, 20, 0xff);
        }
    }
}
fn drawTextCube(win: *graph.SDL.Window, gctx: *graph.ImmediateDrawingContext, cmatrix: graph.za.Mat4, cubes: *graph.Cubes, pos: V3f, tr: graph.Rect, text: []const u8, font: *graph.Font) !void {
    _ = cubes;
    _ = tr;
    //try cubes.cubeVec(pos, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, tr);
    const tpos = cmatrix.mulByVec4(graph.za.Vec4.new(
        @floatCast(pos.x),
        @floatCast(pos.y),
        @floatCast(pos.z),
        1,
    ));
    const w = tpos.w();
    const z = tpos.z();
    const pp = graph.Vec2f.new(tpos.x() / w, tpos.y() / -w);
    const dist_in_blocks = 10;
    if (z < dist_in_blocks and z > 0 and @abs(pp.x) < 1 and @abs(pp.y) < 1) {
        const sw = win.screen_dimensions.toF().smul(0.5);
        const spos = pp.mul(sw).add(sw);
        gctx.text(spos, text, font, 12, 0xffffffff);
    }
}
