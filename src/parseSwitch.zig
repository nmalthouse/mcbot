const std = @import("std");
const bot = @import("bot.zig");
const Bot = bot.Bot;
const eql = std.mem.eql;
const Proto = @import("protocol.zig");
const annotateManualParse = mc.annotateManualParse;
const mc = @import("listener.zig");
const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;
const AutoParse = mc.AutoParse;
const vector = @import("vector.zig");
const V3f = vector.V3f;
const shortV3i = vector.shortV3i;
const V3i = vector.V3i;
const V2i = vector.V2i;
const nbt_zig = @import("nbt.zig");
const config = @import("config");

pub fn parseSwitch(alloc: std.mem.Allocator, bot1: *Bot, packet_buf: []const u8, world: *McWorld) !void {
    const CB = Proto.Play_Clientbound.packets;
    const log = std.log.scoped(.parsing);
    const inv_log = std.log.scoped(.inventory);
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();
    bot1.modify_mutex.lock();
    defer bot1.modify_mutex.unlock();

    var fbs_ = blk: {
        var fbs = mc.fbsT{ .buffer = packet_buf, .pos = 0 };
        _ = mc.readVarInt(fbs.reader()); //Discard the packet length
        if (bot1.compression_threshold > -1) {
            const comp_len = mc.readVarInt(fbs.reader());
            if (comp_len == 0)
                break :blk fbs;

            var zlib_stream = std.compress.zlib.decompressor(fbs.reader());
            const ubuf = try zlib_stream.reader().readAllAlloc(arena_alloc, std.math.maxInt(usize));
            break :blk mc.fbsT{ .buffer = ubuf, .pos = 0 };
        } else {
            break :blk fbs;
        }
    };

    var parse = mc.parseT.init(fbs_.reader(), arena_alloc);

    const pid = parse.varInt();

    const P = AutoParse.P;
    const PT = AutoParse.parseType;

    const server_stream = std.net.Stream{ .handle = bot1.fd };

    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(arena_alloc, bot1.compression_threshold), .server = server_stream.writer(), .mutex = &bot1.fd_mutex };

    if (bot1.connection_state != .play)
        return error.invalidConnectionState;
    const Ap = mc.AutoParseFromEnum.parseFromEnum;
    const Penum = Proto.Play_Clientbound;
    const penum = @as(Proto.Play_Clientbound, @enumFromInt(pid));
    switch (penum) {
        //WORLD specific packets
        .custom_payload => {
            const d = try Ap(Penum, .custom_payload, &parse);
            log.info("{s}: {s}", .{ @tagName(penum), d.channel });

            try pctx.pluginMessage("tony:brand");
            try pctx.clientInfo("en_US", 6, 1);
        },
        .difficulty => {
            const d = try CB.Type_packet_difficulty.parse(&parse);
            log.info("Set difficulty: {d}, Locked: {any}", .{ d.difficulty, d.difficultyLocked });
        },
        .abilities => {
            const d = try CB.Type_packet_abilities.parse(&parse);
            log.info("Player Abilities packet fly_speed: {d}, walk_speed: {d}", .{ d.flyingSpeed, d.walkingSpeed });
        },
        //.named_entity_spawn => {
        //    const data = try CB.Type_packet_named_entity_spawn.parse(&parse);
        //    try world.putEntity(bot1, data, data.playerUUID, Proto.EntityEnum.player);
        //},
        .spawn_entity => {
            const data = try CB.Type_packet_spawn_entity.parse(&parse);
            const t: Proto.EntityEnum = @enumFromInt(data.type);
            log.info("Spawn entity {x} {s} at {d:.2}, {d:.2}, {d:.2}", .{ data.objectUUID, @tagName(t), data.x, data.y, data.z });
            try world.putEntity(bot1, data, data.objectUUID, t);
        },
        .entity_destroy => {
            const d = try CB.Type_packet_entity_destroy.parse(&parse);
            for (d.entityIds) |e| {
                world.removeEntity(bot1.index_id, e.i_entityIds);
            }
        },
        .entity_look => {
            const data = try CB.Type_packet_entity_look.parse(&parse);
            if (world.modifyEntityLocal(bot1.index_id, data.entityId)) |e| {
                e.pitch = data.pitch;
                e.yaw = data.yaw;
                world.entities_mutex.unlock();
            }
        },
        .entity_move_look => {
            const data = try CB.Type_packet_entity_move_look.parse(&parse);
            if (world.modifyEntityLocal(bot1.index_id, data.entityId)) |e| {
                e.pos = vector.deltaPosToV3f(e.pos, vector.shortV3i.new(data.dX, data.dY, data.dZ));
                e.pitch = data.pitch;
                e.yaw = data.yaw;
                world.entities_mutex.unlock();
            }
        },
        .remove_entity_effect => {
            const d = try Ap(Penum, .remove_entity_effect, &parse);
            const eff: Proto.EffectEnum = @enumFromInt(d.effectId);
            if (d.entityId == bot1.e_id) {
                bot1.removeEffect(eff);
            }
        },
        .entity_effect => {
            const d = try Ap(Penum, .entity_effect, &parse);
            const eff: Proto.EffectEnum = @enumFromInt(d.effectId);
            if (d.entityId == bot1.e_id) {
                try bot1.addEffect(eff, d.duration, d.amplifier);
            }
        },
        .update_time => {
            const d = try Ap(Penum, .update_time, &parse);
            world.modify_mutex.lock();
            defer world.modify_mutex.unlock();
            world.time = d.time;
        },
        .rel_entity_move => {
            const d = try Ap(Penum, .rel_entity_move, &parse);
            if (world.modifyEntityLocal(bot1.index_id, d.entityId)) |e| {
                e.pos = vector.deltaPosToV3f(e.pos, shortV3i.new(d.dX, d.dY, d.dZ));
                world.entities_mutex.unlock();
            }
        },
        .tile_entity_data => {
            annotateManualParse("1.21.3");
            const pos = parse.position();
            const btype = parse.varInt();
            _ = btype;
            const tr = nbt_zig.TrackingReader(@TypeOf(parse.reader));
            var tracker = tr.init(arena_alloc, parse.reader);
            defer tracker.deinit();

            const nbt_data = nbt_zig.parse(arena_alloc, tracker.reader(), .{ .is_networked_root = true }) catch null;
            if (nbt_data) |nbt| {
                try world.putBlockEntity(bot1.dimension_id, pos, nbt.entry, arena_alloc);
            }
        },
        .entity_teleport => {
            const data = try CB.Type_packet_entity_teleport.parse(&parse);
            if (world.modifyEntityLocal(bot1.index_id, data.entityId)) |e| {
                e.pos = V3f.new(data.x, data.y, data.z);
                e.pitch = data.pitch;
                e.yaw = data.yaw;
                world.entities_mutex.unlock();
            }
        },
        .entity_metadata => {
            const e_id = parse.varInt();
            _ = e_id;
        },
        .multi_block_change => {
            annotateManualParse("1.21.3");
            const chunk_pos = parse.chunk_position();
            const n_blocks = parse.varInt();
            var n: u32 = 0;
            while (n < n_blocks) : (n += 1) {
                const bd = parse.varLong();
                const bid = @as(u16, @intCast(bd >> 12));
                const lx = @as(i32, @intCast((bd >> 8) & 15));
                const lz = @as(i32, @intCast((bd >> 4) & 15));
                const ly = @as(i32, @intCast(bd & 15));
                try world.chunkdata(bot1.dimension_id).setBlockChunk(chunk_pos, V3i.new(lx, ly, lz), bid);
            }
        },
        .block_change => {
            const d = try Ap(Penum, .block_change, &parse);
            const pos = V3i.new(@intCast(d.location.x), @intCast(d.location.y), @intCast(d.location.z));
            try world.chunkdata(bot1.dimension_id).setBlock(pos, @as(mc.BLOCK_ID_INT, @intCast(d.type)));
        },
        .chunk_batch_start => {
            //MARK TIME WE RECIEVE
            bot1.chunk_batch_info.start_time = std.time.milliTimestamp();
        },
        .chunk_batch_finished => {
            const d = try Ap(Penum, .chunk_batch_finished, &parse);
            bot1.chunk_batch_info.end_time = std.time.milliTimestamp();
            const ms_per_chunk: f32 = @as(f32, @floatFromInt(bot1.chunk_batch_info.end_time - bot1.chunk_batch_info.start_time)) / @as(f32, @floatFromInt(d.batchSize));
            const cpt = 25 / ms_per_chunk;
            try pctx.sendAuto(Proto.Play_Serverbound, .chunk_batch_received, .{ .chunksPerTick = cpt });
        },
        .map_chunk => {
            annotateManualParse("1.21.3");
            const cx = parse.int(i32);
            const cy = parse.int(i32);
            if (!try world.chunkdata(bot1.dimension_id).tryOwn(cx, cy, bot1.uuid)) {
                //TODO keep track of owners better
                return;
            }
            const dim = world.dimensions.getPtr(bot1.dimension_id).?; //CHECK ERR

            const nbt_data = try nbt_zig.parseAsCompoundEntry(arena_alloc, parse.reader, true);
            _ = nbt_data;
            const data_size = parse.varInt();
            var raw_chunk = std.ArrayList(u8).init(alloc);
            defer raw_chunk.deinit();
            try raw_chunk.resize(@as(usize, @intCast(data_size)));
            try parse.reader.readNoEof(raw_chunk.items);

            var chunk = try mc.Chunk.init(alloc, dim.info.section_count);
            try chunk.owners.put(bot1.uuid, {});
            var chunk_i: u32 = 0;
            var chunk_fbs = std.io.FixedBufferStream([]const u8){ .buffer = raw_chunk.items, .pos = 0 };
            const cr = chunk_fbs.reader();
            while (chunk_i < dim.info.section_count) : (chunk_i += 1) {
                const block_count = try cr.readInt(i16, .big);
                const chunk_section = &chunk.sections.items[chunk_i];

                { //BLOCK STATES palated container
                    const bp_entry = try cr.readInt(u8, .big);
                    if (bp_entry > 15) {
                        std.debug.print("IMPOSSIBLE BPE {d} [{d},{d}, {d}]\n", .{ bp_entry, cx, @as(i64, @intCast(chunk_i * 16)) - 64, cy });
                        std.debug.print("Info block_count {d}\n", .{block_count});
                        chunk.deinit();
                        return;
                    }
                    {
                        chunk_section.bits_per_entry = bp_entry;
                        chunk_section.palatte_t = if (bp_entry > 8) .direct else .map;
                        switch (bp_entry) {
                            0 => try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mc.readVarInt(cr)))),
                            4...8 => {
                                const num_pal_entry = mc.readVarInt(cr);

                                var i: u32 = 0;
                                while (i < num_pal_entry) : (i += 1) {
                                    const mapping = mc.readVarInt(cr);
                                    if (mapping > std.math.maxInt(mc.BLOCK_ID_INT)) {
                                        std.debug.print("CORRUPT BLOCK\n", .{});
                                        chunk.deinit();
                                        return;
                                    } else {
                                        try chunk_section.mapping.append(@as(mc.BLOCK_ID_INT, @intCast(mapping)));
                                    }
                                }
                            },
                            else => {}, // Direct indexing
                        }

                        const num_longs = mc.readVarInt(cr);
                        var j: u32 = 0;

                        while (j < num_longs) : (j += 1) {
                            const d = try cr.readInt(u64, .big);
                            try chunk_section.data.append(d);
                        }
                    }
                }
                { //BIOME palated container
                    const bp_entry = try cr.readInt(u8, .big);
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

                        const num_longs = @as(u32, @intCast(mc.readVarInt(cr)));
                        try cr.skipBytes(num_longs * @sizeOf(u64), .{});
                    }
                }

                //Find all the crafting benches
                {
                    const bed_ids = world.tag_table.getIdList("minecraft:block", "minecraft:beds");
                    //other things to find
                    //Beds
                    //furnace
                    //
                    //Also check if they are accesable
                    const crafting_bench = world.reg.getBlockFromNameI("crafting_table").?;
                    const nether_portal = world.reg.getBlockFromNameI("nether_portal").?;
                    //const obsidian = world.reg.getBlockFromNameI("obsidian").?;
                    var skip = false;
                    if (chunk_section.palatte_t == .map) {
                        var none = true;
                        outer: for (chunk_section.mapping.items) |map| {
                            if (bed_ids) |bid| {
                                for (bid) |bi| {
                                    const bb = world.reg.getBlock(@intCast(bi));
                                    if (map >= bb.minStateId and map <= bb.maxStateId) {
                                        none = false;
                                        break :outer;
                                    }
                                }
                            }
                            if (map >= crafting_bench.minStateId and map <= crafting_bench.maxStateId) {
                                none = false;
                                break;
                            }
                            if (map >= nether_portal.minStateId and map <= nether_portal.maxStateId) {
                                none = false;
                                break;
                            }
                        }
                        if (none)
                            skip = true;
                    }
                    if (!skip) {
                        var i: u32 = 0;
                        while (i < 16 * 16 * 16) : (i += 1) {
                            const block = chunk_section.getBlockFromIndex(i);
                            const bid = world.reg.getBlockIdFromState(block.block);
                            if (bid == crafting_bench.id) {
                                const coord = V3i.new(cx * 16 + block.pos.x, @as(i32, @intCast(chunk_i)) * 16 + block.pos.y + dim.info.min_y, cy * 16 + block.pos.z);
                                try world.dimPtr(dim.info.id).poi.putNew(coord);
                            } else if (bed_ids) |bids| {
                                for (bids) |id| {
                                    if (id == bid) {
                                        //TODO add the bed
                                    }
                                }
                            } else if (bid == nether_portal.id) {
                                //check if the block under is obsidion
                            }
                        }
                    }
                }
            }

            try world.chunkdata(bot1.dimension_id).insertChunkColumn(cx, cy, chunk);

            const num_block_ent = parse.varInt();
            var ent_i: u32 = 0;
            while (ent_i < num_block_ent) : (ent_i += 1) {
                const be = parse.blockEntity();
                const coord = V3i.new(cx * 16 + be.rel_x, be.abs_y, cy * 16 + be.rel_z);

                try world.putBlockEntity(bot1.dimension_id, coord, be.nbt, arena_alloc);
            }
        },
        //Keep track of what bots have what chunks loaded and only unload chunks if none have it loaded
        .unload_chunk => {
            const d = try Ap(Penum, .unload_chunk, &parse);
            try world.chunkdata(bot1.dimension_id).removeChunkColumn(d.chunkX, d.chunkZ, bot1.uuid);
        },
        //BOT specific packets
        .keep_alive => {
            const data = try Proto.Play_Clientbound.packets.Type_packet_keep_alive.parse(&parse);
            try pctx.sendAuto(Proto.Play_Serverbound, .keep_alive, .{ .keepAliveId = data.keepAliveId });
        },
        .respawn => {
            //TODO how to notify bot thread we have changed dimension?
            const d = (try Ap(Penum, .respawn, &parse)).worldState;
            log.warn("Respawn sent, changing dimension: {d}, {s}", .{ d.dimension, d.name });
            bot1.dimension_id = d.dimension;
        },
        .login => {
            const d = try CB.Type_packet_login.parse(&parse);
            const ws = d.worldState;
            bot1.view_dist = @as(u8, @intCast(d.simulationDistance));
            bot1.init_status.has_login = true;
            std.debug.print("{s} id:{d}, view_dist: {d}\n", .{ ws.name, ws.dimension, d.viewDistance });
            world.modify_mutex.lock();
            defer world.modify_mutex.unlock();
            bot1.dimension_id = ws.dimension;
            try pctx.clientInfo("en_US", @intCast(d.viewDistance), 1);
        },
        .death_combat_event => {
            const d = try CB.Type_packet_death_combat_event.parse(&parse);
            log.warn("Combat death, id: {d}, msg: {s}", .{ d.playerId, d.message });
            try pctx.clientCommand(0);
        },
        .kick_disconnect => {
            const d = try CB.Type_packet_kick_disconnect.parse(&parse);
            log.warn("Disconnected. Reason:  {s}", .{d.reason});
        },
        .held_item_slot => {
            const d = try CB.Type_packet_held_item_slot.parse(&parse);
            bot1.selected_slot = @intCast(d.slot);
            try pctx.setHeldItem(bot1.selected_slot);
        },
        .set_slot => {
            const d = try Ap(Penum, .set_slot, &parse);
            inv_log.info("set_slot: win_id: data: {any}", .{d});
            if (d.windowId == -1 and d.slot == -1) {
                bot1.held_item = mc.Slot.fromProto(d.item);
            } else if (d.windowId == 0) {
                bot1.container_state = d.stateId;
                try bot1.inventory.setSlot(@intCast(d.slot), mc.Slot.fromProto(d.item));
            } else if (bot1.interacted_inventory.win_id != null and d.windowId == bot1.interacted_inventory.win_id.?) {
                bot1.container_state = d.stateId;
                try bot1.interacted_inventory.setSlot(@intCast(d.slot), mc.Slot.fromProto(d.item));

                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 36);
                if (d.slot >= player_inv_start)
                    try bot1.inventory.setSlot(@intCast(d.slot - player_inv_start + 9), mc.Slot.fromProto(d.item));
            }
        },
        .open_window => {
            const d = try Ap(Penum, .open_window, &parse);
            bot1.interacted_inventory.win_type = @as(u32, @intCast(d.inventoryType));
            inv_log.info("open_win: win_id: {d}, win_type: {d}, title: {s}", .{ d.windowId, d.inventoryType, d.windowTitle });
        },
        .window_items => {
            inv_log.info("set content packet", .{});
            bot1.init_status.has_inv = true;
            const d = try Ap(Penum, .window_items, &parse);
            if (d.windowId == 0) {
                for (d.items, 0..) |it, i| {
                    bot1.container_state = d.stateId;
                    try bot1.inventory.setSlot(@intCast(i), mc.Slot.fromProto(it.i_items));
                }
            } else {
                try bot1.interacted_inventory.setSize(@intCast(d.items.len));
                bot1.interacted_inventory.win_id = @intCast(d.windowId);
                bot1.container_state = d.stateId;
                const player_inv_start: i16 = @intCast(bot1.interacted_inventory.slots.items.len - 36);
                for (d.items, 0..) |it, i| {
                    try bot1.interacted_inventory.setSlot(@intCast(i), mc.Slot.fromProto(it.i_items));
                    const ii: i16 = @intCast(i);
                    if (i >= player_inv_start)
                        try bot1.inventory.setSlot(@intCast(ii - player_inv_start + 9), mc.Slot.fromProto(it.i_items));
                }
            }
        },
        .position => {
            const FieldMask = enum(u8) {
                X = 0x01,
                Y = 0x02,
                Z = 0x04,
                Y_ROT = 0x08,
                x_ROT = 0x10,
            };
            const data = try Proto.Play_Clientbound.packets.Type_packet_position.parse(&parse);
            const Coord_fmt = "[{d:.2}, {d:.2}, {d:.2}]";

            log.warn("Sync Pos: new: " ++ Coord_fmt ++ " tel_id: {d}", .{ data.x, data.y, data.z, data.teleportId });
            if (bot1.pos) |p|
                log.warn("\told: " ++ Coord_fmt ++ " diff: " ++ Coord_fmt, .{
                    p.x,          p.y,          p.z,
                    p.x - data.x, p.y - data.y, p.z - data.z,
                });
            bot1.pos = V3f.new(data.x, data.y, data.z);
            _ = FieldMask;

            try pctx.confirmTeleport(data.teleportId);

            if (bot1.handshake_complete == false) {
                bot1.handshake_complete = true;
                try pctx.completeLogin();
            }
        },
        .acknowledge_player_digging => {

            //TODO use this to advance to next break_block item
        },
        .update_health => {
            const d = try Ap(Penum, .update_health, &parse);
            bot1.health = d.health;
            bot1.food = @as(u8, @intCast(d.food));
            bot1.food_saturation = d.foodSaturation;
        },
        .tags => {
            annotateManualParse("1.21.3");
            if (!world.has_tag_table) {
                world.has_tag_table = true;

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
                            try world.tag_table.addTag(identifier, ident, ids.items);
                        }
                    }
                }
                log.info("Tags added {d} namespaces", .{num_tags});
            }
        },
        .player_chat => {
            annotateManualParse("1.21.3");
            const header = parse.auto(PT(&.{
                P(.uuid, "sender_uuid"),
                P(.varInt, "index"),
                P(.boolean, "is_sig_present"),
            }));
            if (header.is_sig_present) {
                log.err("A player chat has encryption, not supported, exiting", .{});
                return error.notImplemented;
            }
            const body = parse.auto(PT(&.{
                P(.string, "message"),
                P(.long, "timestamp"),
                P(.long, "salt"),
            }));

            if (std.mem.indexOfScalar(i64, &world.packet_cache.chat_time_stamps.buf, body.timestamp) != null)
                return;
            world.packet_cache.chat_time_stamps.insert(body.timestamp);
            var message_it = std.mem.tokenizeScalar(u8, body.message, ' ');
            if (std.ascii.eqlIgnoreCase(message_it.next() orelse return, bot1.name)) {
                //try pctx.sendChatFmt("Hello: {d}", .{header.sender_uuid});
                const a = message_it.next() orelse return;
                if (eql(u8, a, "say")) {
                    try pctx.sendChat("CRASS");
                }
            }
        },
        else => {
            if (config.log_skipped_packets)
                log.info("unhandled packet {s}", .{@tagName(penum)});
        },
    }
}
