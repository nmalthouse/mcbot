pub fn doLoop() !void {
    while (queue.get()) |item| {
        var arena_allocs = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocs.deinit();
        const arena_alloc = arena_allocs.allocator();
        defer alloc.destroy(item);
        defer item.data.buffer.deinit();

        var fbs_ = fbsT{ .buffer = item.data.buffer.items, .pos = 0 };
        const parseT = mc.packetParseCtx(fbsT.Reader);
        var parse = parseT.init(fbs_.reader(), arena_alloc);

        const parseTr = Parse.packetParseCtx(fbsT.Reader);
        var parser = parseTr.init(fbs_.reader(), arena_alloc);

        const pid = parse.varInt();

        const P = Parse.P;
        const PT = Parse.parseType;

        switch (bot1.connection_state) {
            else => {},
            .play => switch (item.data.msg_type) {
                .server => {
                    switch (@as(id_list.packet_enum, @enumFromInt(pid))) {
                        .Keep_Alive => {
                            const data = parser.parse(PT(&.{P(.long, "keep_alive_id")}));

                            try pctx.keepAlive(data.keep_alive_id);
                        },
                        .Login => {
                            const data = parser.parse(PT(&.{
                                P(.int, "ent_id"),
                                P(.boolean, "is_hardcore"),
                                P(.ubyte, "gamemode"),
                                P(.byte, "prev_gamemode"),
                                P(.stringList, "dimension_names"),
                                P(.nbtTag, "reg"),
                                P(.identifier, "dimension_type"),
                                P(.identifier, "dimension_name"),
                                P(.long, "hashed_seed"),
                                P(.varInt, "max_players"),
                                P(.varInt, "view_dist"),
                                P(.varInt, "sim_dist"),
                                P(.boolean, "reduced_debug_info"),
                                P(.boolean, "enable_respawn_screen"),
                                P(.boolean, "is_debug"),
                                P(.boolean, "is_flat"),
                                P(.boolean, "has_death_location"),
                            }));
                            bot1.view_dist = @as(u8, @intCast(data.sim_dist));
                            std.debug.print("Login {any}\n", .{data});
                        },
                        .Combat_Death => {
                            const id = parse.varInt();
                            const killer_id = parse.int(i32);
                            const msg = try parse.string(null);
                            std.debug.print("You died lol {d} {d} {s}\n", .{ id, killer_id, msg });

                            try pctx.clientCommand(0);
                        },
                        .Disconnect => {
                            const reason = try parse.string(null);
                            run = false;

                            std.debug.print("Disconnect: {s}\n", .{reason});
                        },
                        .Plugin_Message => {
                            const channel_name = try parse.string(null);
                            std.debug.print("Plugin Message: {s}\n", .{channel_name});

                            try pctx.pluginMessage("tony:brand");
                            try pctx.clientInfo("en_US", bot1.view_dist, 1);
                        },
                        .Change_Difficulty => {
                            const diff = parse.int(u8);
                            const locked = parse.int(u8);
                            std.debug.print("Set difficulty: {d}, Locked: {d}\n", .{ diff, locked });
                        },
                        .Player_Abilities => {
                            std.debug.print("Player Abilities\n", .{});
                        },
                        .Feature_Flags => {
                            const num_feature = parse.varInt();
                            std.debug.print("Feature_Flags: \n", .{});

                            var i: u32 = 0;
                            while (i < num_feature) : (i += 1) {
                                const feat = try parse.string(null);
                                std.debug.print("\t{s}\n", .{feat});
                            }
                        },
                        .Set_Held_Item => {
                            bot1.selected_slot = parse.int(u8);
                            try pctx.setHeldItem(bot1.selected_slot);
                        },
                        .Set_Container_Slot => {
                            const win_id = parse.int(u8);
                            const state_id = parse.varInt();
                            const slot_i = @as(u16, @intCast(parse.int(i16)));
                            const data = parse.slot();
                            if (win_id == 0) {
                                bot1.container_state = state_id;
                                bot1.inventory[slot_i] = data;
                                std.debug.print("updating slot {any}\n", .{data});
                            }
                        },
                        .Set_Container_Content => {
                            const win_id = parse.int(u8);
                            std.debug.print("SETTING CONTAINER: {d}\n", .{win_id});
                            const state_id = parse.varInt();
                            const item_count = parse.varInt();
                            var i: u32 = 0;
                            if (win_id == 0) {
                                while (i < item_count) : (i += 1) {
                                    bot1.container_state = state_id;
                                    const s = parse.slot();
                                    bot1.inventory[i] = s;
                                }
                            }
                        },
                        .Spawn_Player => {
                            const data = parser.parse(PT(&.{
                                P(.varInt, "ent_id"),
                                P(.uuid, "ent_uuid"),
                                P(.V3f, "pos"),
                                P(.angle, "yaw"),
                                P(.angle, "pitch"),
                            }));
                            niklas_id = data.ent_id;
                            try entities.put(data.ent_id, .{
                                .uuid = data.ent_uuid,
                                .pos = data.pos,
                                .pitch = data.pitch,
                                .yaw = data.yaw,
                            });
                            std.debug.print("Spawn player: {d}\n", .{data.ent_uuid});
                        },
                        .Spawn_Entity => {
                            const data = parser.parse(PT(&.{
                                P(.varInt, "ent_id"),
                                P(.uuid, "ent_uuid"),
                                P(.varInt, "ent_type"),
                                P(.V3f, "pos"),
                                P(.angle, "pitch"),
                                P(.angle, "yaw"),
                                P(.angle, "head_yaw"),
                                P(.varInt, "data"),
                                P(.shortV3i, "vel"),
                            }));
                            try entities.put(data.ent_id, .{
                                .uuid = data.ent_uuid,
                                .pos = data.pos,
                                .pitch = data.pitch,
                                .yaw = data.yaw,
                            });
                            //std.debug.print("Spawn_Entity: {}\n", .{data});
                            //   std.debug.print("Spawn: {d} {d} {s}\n", .{
                            //       data.ent_uuid,
                            //       data.ent_type,
                            //       id_list.Entity_Types[@intCast(u32, data.ent_type)],
                            //   });
                        },
                        .Remove_Entities => {
                            const num_ent = parse.varInt();
                            var n: u32 = 0;
                            while (n < num_ent) : (n += 1) {
                                const e_id = parse.varInt();
                                _ = entities.remove(e_id);
                            }
                        },
                        .Synchronize_Player_Position => {
                            const FieldMask = enum(u8) {
                                X = 0x01,
                                Y = 0x02,
                                Z = 0x04,
                                Y_ROT = 0x08,
                                x_ROT = 0x10,
                            };
                            const data = parser.parse(PT(&.{
                                P(.V3f, "pos"),
                                P(.float, "yaw"),
                                P(.float, "pitch"),
                                P(.byte, "flags"),
                                P(.varInt, "tel_id"),
                                P(.boolean, "should_dismount"),
                            }));

                            std.debug.print(
                                "Sync pos: x: {d}, y: {d}, z: {d}, yaw {d}, pitch : {d} flags: {b}, tel_id: {}\n",
                                .{ data.pos.x, data.pos.y, data.pos.z, data.yaw, data.pitch, data.flags, data.tel_id },
                            );
                            //TODO use if relative flag
                            bot1.pos = data.pos;
                            _ = FieldMask;

                            try pctx.confirmTeleport(data.tel_id);

                            if (bot1.handshake_complete == false) {
                                bot1.handshake_complete = true;
                                try pctx.completeLogin();
                            }
                        },
                        .Update_Entity_Rotation => {
                            const data = parser.parse(PT(&.{
                                P(.varInt, "ent_id"),
                                P(.angle, "yaw"),
                                P(.angle, "pitch"),
                                P(.boolean, "grounded"),
                            }));
                            if (entities.getPtr(data.ent_id)) |e| {
                                e.pitch = data.pitch;
                                e.yaw = data.yaw;
                            }
                        },
                        .Update_Entity_Position_and_Rotation => {
                            const data = parser.parse(PT(&.{
                                P(.varInt, "ent_id"),
                                P(.shortV3i, "del"),
                                P(.angle, "yaw"),
                                P(.angle, "pitch"),
                                P(.boolean, "grounded"),
                            }));
                            if (entities.getPtr(data.ent_id)) |e| {
                                e.pos = vector.deltaPosToV3f(e.pos, data.del);
                                e.pitch = data.pitch;
                                e.yaw = data.yaw;
                            }
                        },
                        .Update_Entity_Position => {
                            const data = parser.parse(PT(&.{ P(.varInt, "ent_id"), P(.shortV3i, "del"), P(.boolean, "grounded") }));
                            if (entities.getPtr(data.ent_id)) |e| {
                                e.pos = vector.deltaPosToV3f(e.pos, data.del);
                            }
                        },
                        .Block_Entity_Data => {
                            const pos = parse.position();
                            const btype = parse.varInt();
                            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
                            _ = pos;
                            _ = btype;
                            _ = nbt_data;
                        },
                        .Acknowledge_Block_Change => {

                            //TODO use this to advance to next break_block item
                        },
                        .Block_Update => {
                            const pos = parse.position();
                            const new_id = parse.varInt();
                            try world.setBlock(pos, @as(mc.BLOCK_ID_INT, @intCast(new_id)));
                        },
                        .Set_Health => {
                            bot1.health = parse.float(f32);
                            bot1.food = @as(u8, @intCast(parse.varInt()));
                            bot1.food_saturation = parse.float(f32);
                        },
                        .Set_Head_Rotation => {},
                        .Teleport_Entity => {
                            const data = parser.parse(PT(&.{
                                P(.varInt, "ent_id"),
                                P(.V3f, "pos"),
                                P(.angle, "yaw"),
                                P(.angle, "pitch"),
                                P(.boolean, "grounded"),
                            }));
                            if (entities.getPtr(data.ent_id)) |e| {
                                e.pos = data.pos;
                                e.pitch = data.pitch;
                                e.yaw = data.yaw;
                            }
                        },
                        .Set_Entity_Metadata => {
                            const e_id = parse.varInt();
                            _ = e_id;
                            //for (entities.items) |it| {
                            //    if (it.id == e_id) {
                            //        std.debug.print("Set Metadata for: {s}\n", .{id_list.Entity_Types[it.type_id]});
                            //        break;
                            //    }
                            //}
                            //if (e_id == bot1.e_id)
                            //    std.debug.print("\tFOR PLAYER\n", .{});

                            //var index = parse.int(u8);
                            //while (index != 0xff) : (index = parse.int(u8)) {
                            //    //std.debug.print("\tIndex {d}\n", .{index});
                            //    const metatype = @intToEnum(mc.MetaDataType, parse.varInt());
                            //    //std.debug.print("\tMetadata: {}\n", .{metatype});
                            //    switch (metatype) {
                            //        else => {
                            //            //std.debug.print("\tENTITY METADATA TYPE NOT IMPLEMENTED\n", .{});
                            //            break;
                            //        },
                            //    }
                            //}
                        },
                        .Game_Event => {
                            const event = parse.int(u8);
                            const value = parse.float(f32);
                            std.debug.print("GAME EVENT: {d} {d}\n", .{ event, value });
                        },
                        .Update_Time => {},
                        .Update_Tags => {
                            //TODO Does this packet replace all the tags or does it append to an existing
                            const num_tags = parse.varInt();

                            var n: u32 = 0;
                            while (n < num_tags) : (n += 1) {
                                const identifier = try parse.string(null);
                                { //TAG
                                    const n_tags = parse.varInt();
                                    var nj: u32 = 0;

                                    while (nj < n_tags) : (nj += 1) {
                                        const ident = try parse.string(null);
                                        const num_ids = parse.varInt();

                                        var ids = std.ArrayList(u32).init(alloc);
                                        defer ids.deinit();
                                        try ids.resize(@as(usize, @intCast(num_ids)));
                                        var ni: u32 = 0;
                                        while (ni < num_ids) : (ni += 1)
                                            ids.items[ni] = @as(u32, @intCast(parse.varInt()));
                                        //std.debug.print("{s}: {s}: {any}\n", .{ identifier.items, ident.items, ids.items });
                                        try tag_table.addTag(identifier, ident, ids.items);
                                    }
                                }
                            }
                        },
                        .Unload_Chunk => {
                            const data = parser.parse(PT(&.{ P(.int, "cx"), P(.int, "cz") }));
                            world.removeChunkColumn(data.cx, data.cz);
                        },
                        .Set_Entity_Velocity => {},
                        .Update_Section_Blocks => {
                            const chunk_pos = parse.cposition();
                            const sup_light = parse.boolean();
                            _ = sup_light;
                            const n_blocks = parse.varInt();
                            var n: u32 = 0;
                            while (n < n_blocks) : (n += 1) {
                                const bd = parse.varLong();
                                const bid = @as(u16, @intCast(bd >> 12));
                                const lx = @as(i32, @intCast((bd >> 8) & 15));
                                const lz = @as(i32, @intCast((bd >> 4) & 15));
                                const ly = @as(i32, @intCast(bd & 15));
                                try world.setBlockChunk(chunk_pos, V3i.new(lx, ly, lz), bid);
                            }
                        },
                        .Chunk_Data_and_Update_Light => {
                            const cx = parse.int(i32);
                            const cy = parse.int(i32);

                            var nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader);
                            _ = nbt_data;
                            const data_size = parse.varInt();
                            var chunk_data = std.ArrayList(u8).init(alloc);
                            defer chunk_data.deinit();
                            try chunk_data.resize(@as(usize, @intCast(data_size)));
                            try parse.reader.readNoEof(chunk_data.items);

                            var chunk: mc.Chunk = undefined;
                            var chunk_i: u32 = 0;
                            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = chunk_data.items, .pos = 0 };
                            const cr = chunk_fbs.reader();
                            //TODO determine number of chunk sections some other way
                            while (chunk_i < 16) : (chunk_i += 1) {

                                //std.debug.print(" CHUKN SEC {d}\n", .{chunk_i});
                                const block_count = try cr.readInt(i16, .Big);
                                _ = block_count;
                                chunk[chunk_i] = mc.ChunkSection.init(alloc);
                                const chunk_section = &chunk[chunk_i];

                                { //BLOCK STATES palated container
                                    const bp_entry = try cr.readInt(u8, .Big);
                                    {
                                        if (bp_entry == 0) {
                                            try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mc.readVarInt(cr))));
                                        } else {
                                            const num_pal_entry = mc.readVarInt(cr);
                                            chunk_section.bits_per_entry = bp_entry;

                                            var i: u32 = 0;
                                            while (i < num_pal_entry) : (i += 1) {
                                                const mapping = mc.readVarInt(cr);
                                                try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mapping)));
                                            }
                                        }

                                        const num_longs = mc.readVarInt(cr);
                                        var j: u32 = 0;
                                        //std.debug.print("\t NUM LONGNS {d}\n", .{num_longs});

                                        while (j < num_longs) : (j += 1) {
                                            const d = try cr.readInt(u64, .Big);
                                            try chunk_section.data.append(d);
                                        }
                                    }
                                }
                                { //BIOME palated container
                                    const bp_entry = try cr.readInt(u8, .Big);
                                    {
                                        if (bp_entry == 0) {
                                            const id = mc.readVarInt(cr);
                                            _ = id;
                                        } else {
                                            const num_pal_entry = mc.readVarInt(cr);
                                            var i: u32 = 0;
                                            while (i < num_pal_entry) : (i += 1) {
                                                const mapping = mc.readVarInt(cr);
                                                _ = mapping;
                                                //try chunk_section.mapping.append(@intCast(mc.BLOCK_ID_INT, mapping));
                                            }
                                        }

                                        const num_longs = mc.readVarInt(cr);
                                        var j: u32 = 0;
                                        //std.debug.print("\t NUM LONGNS {d}\n", .{num_longs});

                                        while (j < num_longs) : (j += 1) {
                                            const d = try cr.readInt(u64, .Big);
                                            _ = d;
                                            //_ = try chunk_section.data.append(d);
                                        }
                                    }
                                }
                            }

                            const ymap = try world.x.getOrPut(cx);
                            if (!ymap.found_existing) {
                                ymap.value_ptr.* = mc.ChunkMap.ZTYPE.init(alloc);
                            }

                            const chunk_entry = try ymap.value_ptr.getOrPut(cy);
                            if (chunk_entry.found_existing) {
                                for (chunk_entry.value_ptr.*) |*cs| {
                                    cs.deinit();
                                }
                            }
                            chunk_entry.value_ptr.* = chunk;
                            //std.mem.copy(mc.ChunkSection, chunk_entry.value_ptr, &chunk);

                            const num_block_ent = parse.varInt();
                            var ent_i: u32 = 0;
                            while (ent_i < num_block_ent) : (ent_i += 1) {
                                const be = parse.blockEntity();
                                _ = be;
                            }
                        },
                        .System_Chat_Message => {
                            const msg = try parse.string(null);
                            const is_actionbar = parse.boolean();
                            std.debug.print("System msg: {s} {}\n", .{ msg, is_actionbar });
                        },
                        .Disguised_Chat_Message => {
                            const msg = try parse.string(null);
                            std.debug.print("System msg: {s}\n", .{msg});
                        },
                        .Player_Chat_Message => {
                            { //HEADER
                                const uuid = parse.int(u128);
                                const index = parse.varInt();
                                const sig_present_bool = parse.boolean();
                                _ = index;
                                //std.debug.print("Chat from UUID: {d} {d}\n", .{ uuid, index });
                                //std.debug.print("sig_present {any}\n", .{sig_present_bool});
                                if (sig_present_bool) {
                                    std.debug.print("NOT SUPPORTED \n", .{});
                                    unreachable;
                                }

                                var ent_it = entities.iterator();
                                var ent = ent_it.next();
                                const player_info: ?Entity = blk: {
                                    while (ent != null) : (ent = ent_it.next()) {
                                        if (ent.?.value_ptr.uuid == uuid) {
                                            break :blk ent.?.value_ptr.*;
                                        }
                                    }
                                    break :blk null;
                                };

                                const msg = try parse.string(null);
                                const eql = std.mem.eql;

                                var msg_buffer: [1024]u8 = undefined;
                                var m_fbs = std.io.FixedBufferStream([]u8){ .buffer = &msg_buffer, .pos = 0 };
                                const m_wr = m_fbs.writer();

                                var it = std.mem.tokenize(u8, msg, " ");

                                const key = it.next().?;
                                if (eql(u8, key, "path")) {
                                    maj_goal = blk: {
                                        if (parseCoordOpt(&it)) |coord| {
                                            break :blk coord.add(V3f.new(0, 1, 0));
                                        }
                                        break :blk player_info.?.pos;
                                    };

                                    const found = try pathctx.pathfind(bot1.pos.?, maj_goal.?);
                                    if (found) |*actions| {
                                        player_actions.deinit();
                                        player_actions = actions.*;
                                        for (player_actions.items) |pitem| {
                                            std.debug.print("action: {any}\n", .{pitem});
                                        }
                                        if (!draw) {
                                            current_action = player_actions.popOrNull();
                                            if (current_action) |acc| {
                                                switch (acc) {
                                                    .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                                    .block_break => block_break_timer = null,
                                                }
                                            }
                                        }
                                    }
                                } else if (eql(u8, key, "toggle")) {
                                    doit = !doit;
                                } else if (eql(u8, key, "inventory")) {
                                    m_fbs.reset();
                                    try m_wr.print("Items: ", .{});
                                    for (bot1.inventory) |optslot| {
                                        if (optslot) |slot| {
                                            const itemd = reg.getItem(slot.item_id);
                                            try m_wr.print("{s}: {d}, ", .{ itemd.name, slot.count });
                                        }
                                    }
                                    try pctx.sendChat(m_fbs.getWritten());
                                } else if (eql(u8, key, "axe")) {
                                    for (bot1.inventory, 0..) |optslot, si| {
                                        if (optslot) |slot| {
                                            //TODO in mc 19.4 tags have been added for axes etc, for now just do a string search
                                            const name = reg.getItem(slot.item_id).name;
                                            const inde = std.mem.indexOf(u8, name, "axe");
                                            if (inde) |in| {
                                                std.debug.print("found axe at {d} {any}\n", .{ si, bot1.inventory[si] });
                                                _ = in;
                                                //try pctx.pickItem(si - 10);
                                                try pctx.clickContainer(0, bot1.container_state, @as(i16, @intCast(si)), 0, 2, &.{});
                                                try pctx.setHeldItem(0);
                                                break;
                                            }
                                            //std.debug.print("item: {s}\n", .{item_table.getName(slot.item_id)});
                                        }
                                    }
                                } else if (eql(u8, key, "open_chest")) {
                                    try pctx.sendChat("Trying to open chest");
                                    const v = try parseCoord(&it);
                                    try pctx.useItemOn(.main, v.toI(), .bottom, 0, 0, 0, false, 0);
                                } else if (eql(u8, key, "tree")) {
                                    if (try pathctx.findTree(bot1.pos.?)) |*actions| {
                                        player_actions.deinit();
                                        player_actions = actions.*;
                                        for (player_actions.items) |pitem| {
                                            std.debug.print("action: {any}\n", .{pitem});
                                        }
                                        current_action = player_actions.popOrNull();
                                        if (current_action) |acc| {
                                            switch (acc) {
                                                .movement => |m| move_state = bot.MovementState{ .init_pos = bot1.pos.?, .final_pos = m.pos, .time = 0 },
                                                .block_break => block_break_timer = null,
                                            }
                                        }
                                    }
                                } else if (eql(u8, key, "has_tag")) {
                                    const v = try parseCoord(&it);
                                    const tag = it.next() orelse unreachable;
                                    if (pathctx.hasBlockTag(tag, v.toI())) {
                                        try pctx.sendChat("yes has tag");
                                    } else {
                                        try pctx.sendChat("no tag");
                                    }
                                } else if (eql(u8, key, "look")) {
                                    if (parseCoordOpt(&it)) |coord| {
                                        _ = coord;
                                        std.debug.print("Has coord\n", .{});
                                    }
                                    const pw = mc.lookAtBlock(bot1.pos.?, player_info.?.pos.add(V3f.new(-0.3, 1, -0.3)));
                                    try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                                } else if (eql(u8, key, "dig")) {
                                    try pctx.sendChat("digging");
                                    const v = try parseCoord(&it);
                                    try pctx.playerAction(.start_digging, v.toI());
                                } else if (eql(u8, key, "bpe")) {} else if (eql(u8, key, "moverel")) {} else if (eql(u8, key, "lookat")) {
                                    const v = try parseCoord(&it);
                                    const pw = mc.lookAtBlock(bot1.pos.?, v);
                                    try pctx.setPlayerPositionRot(bot1.pos.?, pw.yaw, pw.pitch, true);
                                } else if (eql(u8, key, "jump")) {} else if (eql(u8, key, "query")) {
                                    const qb = (try parseCoord(&it)).toI();
                                    const bid = world.getBlock(qb);
                                    m_fbs.reset();
                                    try m_wr.print("Block {s} id: {d}", .{
                                        reg.getBlockFromState(bid).name,
                                        bid,
                                    });
                                    try pctx.sendChat(m_fbs.getWritten());
                                    m_fbs.reset();
                                    std.debug.print("{}", .{reg.getBlockFromState(bid)});
                                    //try pctx.sendChat(m_fbs.getWritten());
                                }
                            }
                        },
                        else => {
                            //std.debug.print("Packet {s}\n", .{id_list.packet_ids[@intCast(u32, pid)]});
                        },
                    }
                },
                .local => {
                    var itt = std.mem.tokenize(u8, item.data.buffer.items[0 .. item.data.buffer.items.len - 1], " ");
                    const key = itt.next() orelse unreachable;
                    const eql = std.mem.eql;
                    if (eql(u8, "exit", key)) {
                        run = false;
                    } else if (eql(u8, "query", key)) {
                        if (itt.next()) |tag_type| {
                            const tags = tag_table.tags.getPtr(tag_type) orelse unreachable;
                            var kit = tags.keyIterator();
                            var ke = kit.next();
                            std.debug.print("Possible sub tag: \n", .{});
                            while (ke != null) : (ke = kit.next()) {
                                std.debug.print("\t{s}\n", .{ke.?.*});
                            }
                        } else {
                            var kit = tag_table.tags.keyIterator();
                            var ke = kit.next();
                            std.debug.print("Possible tags: \n", .{});
                            while (ke != null) : (ke = kit.next()) {
                                std.debug.print("\t{s}\n", .{ke.?.*});
                            }
                        }
                    }
                },
            },
        }
    }
}
