const std = @import("std");
const bot = @import("bot.zig");
const Bot = bot.Bot;
const eql = std.mem.eql;
const Proto = @import("protocol.zig");
const annotateManualParse = mc.annotateManualParse;
const mc = @import("listener.zig");
const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;

pub fn botJoin(alloc: std.mem.Allocator, bot_name: []const u8, script_name: ?[]const u8, ip: []const u8, port: u16, version_id: i32, world: *McWorld) !Bot {
    const log = std.log.scoped(.parsing);
    var bot1 = try Bot.init(alloc, bot_name, script_name);
    errdefer bot1.deinit();
    const s = try std.net.tcpConnectToHost(alloc, ip, port);
    bot1.fd = s.handle;
    var pctx = mc.PacketCtx{ .packet = try mc.Packet.init(alloc, -1), .server = s.writer(), .mutex = &bot1.fd_mutex };
    defer pctx.packet.deinit();
    try pctx.setProtocol(ip, port, version_id);
    try pctx.loginStart(bot1.name);
    bot1.connection_state = .login;
    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();
    const arena_alloc = arena_allocs.allocator();
    var comp_thresh: i32 = -1;

    while (bot1.connection_state == .login or bot1.connection_state == .config) {
        const pd = try mc.recvPacket(alloc, s.reader(), comp_thresh);
        defer alloc.free(pd);
        var fbs_ = mc.fbsT{ .buffer = pd, .pos = 0 };
        //const parseT = mc.packetParseCtx(fbsT.Reader);
        var parse = mc.parseT.init(fbs_.reader(), arena_alloc);
        const pid = parse.varInt();
        switch (bot1.connection_state) {
            else => {},
            .config => switch (@as(Proto.Config_Clientbound, @enumFromInt(pid))) {
                .select_known_packs => {
                    const d = try Proto.Type_packet_common_select_known_packs.parse(&parse);
                    for (d.packs) |p| {
                        log.info("server has pack: {s}:{s}\n", .{ p.i_packs.namespace, p.i_packs.id });
                    }
                    //We tell the server we don't know anything so we get dimension params etc
                    //If the server doesn't send dimension information the program will crash
                    try pctx.sendManual(Proto.Config_Serverbound.select_known_packs, Proto.Type_packet_common_select_known_packs{ .packs = &.{} });
                },
                .custom_payload => {}, //Just ignore, shouldn't need response
                .feature_flags => {
                    const d = try Proto.Config_Clientbound.packets.Type_packet_feature_flags.parse(&parse);
                    log.info("feature flags:", .{});
                    for (d.features) |f| {
                        log.info("flag: {s}", .{f.i_features});
                    }
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
                                    try world.tag_table.addTag(identifier, ident, ids.items);
                                }
                            }
                        }
                        log.info("Tags added {d} namespaces", .{num_tags});
                    }
                },
                .ping => {
                    const d = try Proto.Config_Clientbound.packets.Type_packet_ping.parse(&parse);
                    try pctx.sendAuto(Proto.Config_Serverbound, .pong, .{ .id = d.id });
                },
                .registry_data => {
                    const d = try Proto.Config_Clientbound.packets.Type_packet_registry_data.parse(&parse);
                    log.info("Reg data: {s}", .{d.id});
                    if (eql(u8, d.id, "minecraft:dimension_type")) {
                        world.modify_mutex.lock();
                        defer world.modify_mutex.unlock();
                        for (d.entries, 0..) |entry, i| {
                            if (entry.i_entries.value) |val| {
                                const elem = val.compound;
                                const new_dim = McWorld.DimInfo{
                                    .section_count = @intCast(@divExact(elem.get("height").?.int, 16)),
                                    .min_y = elem.get("min_y").?.int,
                                    .bed_works = elem.get("bed_works").?.byte > 0,
                                    .id = @intCast(i),
                                };
                                const name = entry.i_entries.key;
                                if (world.dimension_map.get(name) == null)
                                    try world.dimension_map.put(try world.alloc.dupe(u8, name), new_dim);
                                if (world.dimensions.get(new_dim.id) == null)
                                    try world.dimensions.put(new_dim.id, McWorld.Dimension.init(new_dim, alloc));
                                log.info("Adding dimension {s} id:{d}", .{ name, new_dim.id });
                            }
                        }
                    } else {}
                },
                .finish_configuration => {
                    log.info("Config finished", .{});
                    bot1.connection_state = .play;
                    try pctx.sendAuto(Proto.Config_Serverbound, .finish_configuration, .{});
                },
                .disconnect => {
                    const d = try Proto.Config_Clientbound.packets.Type_packet_disconnect.parse(&parse);
                    log.warn("Disconnected: {s}\n", .{d.reason});
                    return error.disconnectedDuringConfig;
                },
                else => {
                    std.debug.print("CONFIG PACKET {s}\n", .{@tagName(@as(Proto.Config_Clientbound, @enumFromInt(pid)))});
                },
            },
            .login => switch (@as(Proto.Login_Clientbound, @enumFromInt(pid))) {
                .cookie_request => {
                    annotateManualParse("1.21.3");
                },
                .disconnect => {
                    const d = try Proto.Login_Clientbound.packets.Type_packet_disconnect.parse(&parse);
                    log.warn("Disconnected: {s}\n", .{d.reason});
                    return error.disconnectedDuringLogin;
                },
                .compress => {
                    const d = try Proto.Login_Clientbound.packets.Type_packet_compress.parse(&parse);
                    comp_thresh = d.threshold;
                    log.info("Setting Compression threshhold: {d}\n", .{d.threshold});
                    if (d.threshold < 0) {
                        log.err("Invalid compression threshold from server: {d}", .{d.threshold});
                        return error.invalidCompressionThreshold;
                    } else {
                        bot1.compression_threshold = d.threshold;
                        pctx.packet.comp_thresh = d.threshold;
                    }
                },
                .encryption_begin => {
                    std.debug.print("\n!!!!!!!!!!!\n", .{});
                    std.debug.print("ONLINE MODE NOT SUPPORTED\nDISABLE with online-mode=false in server.properties\n", .{});
                    std.process.exit(1);
                },
                .success => {
                    const d = try Proto.Login_Clientbound.packets.Type_packet_success.parse(&parse);
                    log.info("Login Success: {d}: {s}", .{ d.uuid, d.username });

                    try pctx.sendAuto(Proto.Login_Serverbound, .login_acknowledged, .{});
                    bot1.uuid = d.uuid;
                    bot1.connection_state = .config;
                    try pctx.sendAuto(Proto.Config_Serverbound, .settings, .{
                        .chatColors = true,
                        .locale = "en_US",
                        .viewDistance = 12,
                        .chatFlags = 0,
                        .skinParts = 0,
                        .mainHand = 0,
                        .enableTextFiltering = false,
                        .enableServerListing = true,
                        .particles = 0,
                    });
                },
                .login_plugin_request => {
                    const data = try Proto.Login_Clientbound.packets.Type_packet_login_plugin_request.parse(&parse);
                    log.info("Login plugin request {d} {s}", .{ data.messageId, data.channel });
                    log.info("Payload {s}", .{data.data});

                    try pctx.loginPluginResponse(
                        data.messageId,
                        null, // We tell the server we don't understand any plugin requests, might be a problem
                    );
                },
            },
        }
    }
    return bot1;
}
