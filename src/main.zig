const std = @import("std");
const Proto = @import("protocol.zig");
const config = @import("config");

const graph = @import("graph");
const botJoin = @import("botJoin.zig").botJoin;

const mc = @import("listener.zig");
const eql = std.mem.eql;
const astar = @import("astar.zig");
const bot = @import("bot.zig");
const Bot = bot.Bot;
const Reg = @import("data_reg.zig");

const math = std.math;

const vector = @import("vector.zig");
const V3f = vector.V3f;
const V3i = vector.V3i;

const AutoParse = mc.AutoParse;

const mcTypes = @import("mcContext.zig");
const McWorld = mcTypes.McWorld;
const Entity = mcTypes.Entity;
const Lua = graph.Lua;
const parseSwitch = @import("parseSwitch.zig").parseSwitch;
const drawThread = @import("draw.zig").drawThread;

pub const std_options = .{
    .log_level = .debug,
    .logFn = myLogFn,
};
const LOG_ALL = config.verbose_logging;
const annotateManualParse = mc.annotateManualParse;

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .info and !LOG_ALL) {
        switch (scope) {
            .inventory,
            .parsing,
            .world,
            .lua,
            .SDL,
            => return,
            else => {},
        }
    }
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

pub const PacketParse = struct {
    state: enum { len, data } = .len,
    buf: std.ArrayList(u8),
    data_len: ?u32 = null,
    len_len: ?u32 = null,
    num_read: u32 = 0,

    pub fn reset(self: *@This()) !void {
        try self.buf.resize(0);
        self.state = .len;
        self.data_len = null;
        self.len_len = null;
        self.num_read = 0;
    }
};

pub const BuildLayer = struct {
    //bitmap: []const Reg.BlockId,
    bitmap: [][]const u8,
    offset: V3f,
    direction: ?Reg.Direction,
    w: u32 = 3,
    h: u32 = 3,
};

threadlocal var lss: ?*LuaApi = null;
pub const LuaApi = struct {
    const Doc = struct {
        const Arg = struct {
            type: []const u8,
            name: []const u8,
            desc: []const u8,
        };
        desc: []const u8,
        errors: []const ErrorMsg,
        args: []const Arg,
        returns: Arg = .{ .type = "void", .name = "", .desc = "" },
    };
    const ErrorMsg = bot.BotScriptThreadData.ErrorMsg;

    const sToE = std.meta.stringToEnum;
    const log = std.log.scoped(.lua);
    const Self = @This();
    const ActionListT = std.ArrayList(astar.AStarContext.PlayerActionItem);
    const PlayerActionItem = astar.AStarContext.PlayerActionItem;
    thread_data: *bot.BotScriptThreadData,
    vm: *Lua,
    pathctx: astar.AStarContext,
    world: *McWorld,
    bo: *Bot,
    in_yield: bool = false,
    has_yield_fn: bool = false,

    allow_yield: bool = true, //User can disable yielding from script

    alloc: std.mem.Allocator,

    pub fn registerAllStruct(self: *Lua, comptime api_struct: type) void {
        const info = @typeInfo(api_struct);
        inline for (info.Struct.decls) |decl| {
            const t = @TypeOf(@field(api_struct, decl.name));
            const tinfo = @typeInfo(t);
            const lua_name = decl.name;
            switch (tinfo) {
                .Fn => self.reg(lua_name, @field(api_struct, decl.name)),
                //else => |crass| @compileError("Cannot export to lua: " ++ @tagName(crass)),
                //@typeName(@TypeOf(@field(api_struct, decl.name)))),
                .Pointer => |p| {
                    _ = p;
                    //if (p.size == .Slice and p.child == u8) {
                    //    self.setGlobal(lua_name, @field(api_struct, decl.name));
                    //}
                },
                else => {}, //don't export
            }
        }
    }

    fn stripErrorUnion(comptime T: type) type {
        const info = @typeInfo(T);
        if (info != .ErrorUnion) @compileError("stripErrorUnion expects an error union!");
        return info.ErrorUnion.payload;
    }

    fn errc(to_check: anytype) ?stripErrorUnion(@TypeOf(to_check)) {
        return to_check catch |err| {
            lss.?.vm.putError(@errorName(err));
            return null;
        };
    }

    pub fn checkExit(self: *Self) void {
        if (self.thread_data.exit_mutex.tryLock()) {
            self.thread_data.setStatus(.terminated);
            self.thread_data.exit_mutex.unlock();
            _ = Lua.c.luaL_error(self.vm.state, "TERMINATING LUA SCRIPT");
        }
        if (self.thread_data.reload_mutex.tryLock()) {
            self.thread_data.reload_mutex.unlock();
            self.thread_data.setStatus(.terminated_waiting_for_restart);
            _ = Lua.c.luaL_error(self.vm.state, "RELOADING LUA SCRIPT");
        }
    }

    pub fn init(alloc: std.mem.Allocator, world: *McWorld, bo: *Bot, vm: *Lua) Self {
        registerAllStruct(vm, Api);
        return .{
            .vm = vm,
            .thread_data = &bo.th_d,
            .pathctx = astar.AStarContext.init(alloc, world, 0),
            .alloc = alloc,
            .bo = bo,
            .world = world,
        };
    }
    pub fn deinit(self: *Self) void {
        self.pathctx.deinit();
    }

    pub fn beginHalt(self: *Self) *ActionListT {
        if (!self.in_yield and self.has_yield_fn and self.allow_yield) {
            self.in_yield = true;
            self.vm.callLuaFunction("onYield") catch {};
            self.in_yield = false;
        }

        self.checkExit(); //No return

        self.thread_data.clearActions() catch unreachable;
        return &self.thread_data.actions;
    }
    pub fn endHalt(self: *Self) ?ErrorMsg {
        self.thread_data.action_index = self.thread_data.actions.items.len;
        if (self.thread_data.actions.items.len == 0)
            self.thread_data.action_index = null;

        self.bo.modify_mutex.lock();
        self.thread_data.nextAction(0, self.bo.getPos());
        self.bo.modify_mutex.unlock();

        //const error_status = self.thread_data.error_;
        var arena_allocs = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_allocs.deinit();
        const arena_alloc = arena_allocs.allocator();

        updateLoop(&self.bo.th_d.exit_mutex, self.bo, arena_alloc, self.world) catch unreachable;

        //return error_status;
        return null;
    }

    pub fn endHaltReturnErr(self: *Self, L: Lua.Ls, err: ErrorMsg) noreturn {
        _ = self.endHalt();
        returnError(L, err);
        unreachable;
    }

    pub fn endHaltReturnErrL(self: *Self, comptime err: []const u8, fmt: anytype) noreturn {
        _ = self.endHalt();
        self.vm.putErrorFmt(err, fmt);
        unreachable;
    }

    pub fn returnError(L: Lua.Ls, err: ErrorMsg) noreturn {
        Lua.pushV(L, err);
        _ = Lua.c.lua_error(L); //Never returns but returns an int, hmm
        unreachable;
    }

    //Assumes appropriate mutexs are owned by calling thread
    //todo make self have a method lock unlock for all owned mutex
    pub fn addBreakBlockAction(self: *Self, actions: *ActionListT, coord: V3i) void {
        const sid = self.world.chunkdata(self.bo.dimension_id).getBlock(coord) orelse return;
        const block = self.world.reg.getBlockFromState(sid);
        if (self.bo.inventory.findToolForMaterial(self.world.reg, block.material)) |match| {
            const hardness = block.hardness orelse return;
            const btime = Reg.calculateBreakTime(match.mul, hardness, .{
                .haste_level = self.bo.getEffect(.Haste),
            });
            errc(actions.append(.{ .block_break = .{ .pos = coord, .break_time = @as(f64, @floatFromInt(btime)) / 20 } })) orelse return;
            errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(match.slot_index)) } })) orelse return;
        }
    }

    pub fn interactChest(self: *Self, coord: V3i, to_move: [][]const u8) c_int {
        //TODO we don't know if requested actions are possible until much later. How do we notify user if the chest is full or has none of the requested items?
        const actions = self.beginHalt();
        defer _ = self.endHalt();
        self.bo.modify_mutex.lock();
        defer self.bo.modify_mutex.unlock();
        errc(actions.append(.{ .close_chest = {} })) orelse return 0;
        errc(actions.append(.{ .wait_ms = 10 })) orelse return 0;
        var m_i = to_move.len;
        while (m_i > 0) {
            m_i -= 1;
            const mv_str = to_move[m_i];
            errc(actions.append(.{ .wait_ms = 20 })) orelse return 0;
            var it = std.mem.tokenizeScalar(u8, mv_str, ' ');
            // "DIRECTION COUNT MATCH_TYPE MATCH_PARAMS
            const dir_str = it.next() orelse {
                self.vm.putErrorFmt("expected string", .{});
                return 0;
            };
            const dir = sToE(PlayerActionItem.Inv.ItemMoveDirection, dir_str) orelse {
                self.vm.putErrorFmt("invalid direction: {s}", .{dir_str});
                return 0;
            };
            const count_str = it.next() orelse {
                self.vm.putError("expected count");
                return 0;
            };
            const count = if (eql(u8, count_str, "all")) 0xff else (std.fmt.parseInt(u8, count_str, 10)) catch {
                self.vm.putErrorFmt("invalid count: {s}", .{count_str});
                return 0;
            };
            const match_str = it.next() orelse {
                self.vm.putError("expected match predicate");
                return 0;
            };
            const match = sToE(enum { item, any, category, tag }, match_str) orelse {
                self.vm.putErrorFmt("invalid match predicate: {s}", .{match_str});
                return 0;
            };
            errc(actions.append(.{
                .inventory = .{
                    .direction = dir,
                    .count = count,
                    .match = blk: {
                        switch (match) {
                            .item => {
                                const item_name = it.next() orelse {
                                    self.vm.putError("expected item name");
                                    return 0;
                                };
                                const item_id = self.world.reg.getItemFromName(item_name) orelse {
                                    self.vm.putErrorFmt("invalid item name: {s}", .{item_name});
                                    return 0;
                                };
                                break :blk .{ .by_id = item_id.id };
                            },
                            .tag => {
                                const tag_name = it.next() orelse {
                                    self.vm.putError("expected tag name");
                                    return 0;
                                };
                                const item_list = self.world.tag_table.getIdList("minecraft:item", tag_name) orelse {
                                    self.vm.putErrorFmt("invalid tag {s} for minecraft:item", .{tag_name});
                                    return 0;
                                };
                                break :blk .{ .tag_list = item_list };
                            },
                            .any => break :blk .{ .match_any = {} },
                            .category => {
                                const cat_str = it.next() orelse {
                                    self.vm.putError("expected category name");
                                    return 0;
                                };
                                const sindex = self.world.reg.item_categories.string_tracker.get(cat_str) orelse {
                                    self.vm.putErrorFmt("unknown category: {s}", .{cat_str});
                                    return 0;
                                };
                                break :blk .{ .category = sindex };
                            },
                        }
                    },
                },
            })) orelse break;
        }
        errc(actions.append(.{ .open_chest = .{ .pos = coord } })) orelse return 0;
        return 0;
    }
    //TODO API
    //interactInv should have per item control rather than stack

    /// Everything inside this Api struct is exported to lua using the given name
    ///
    /// Be very careful about using defer with Lua putError as it longjmps and defer are not evaluated
    /// Also be very carefull with clearAlloc / beginHalt, beginHalt may call yield which may call a function with clearalloc clobering any allocs.
    /// Call beginHalt before any local allocations / clearAlloc
    pub const Api = struct {
        pub const LUA_PATH: []const u8 = "?;?.lua;scripts/?.lua;scripts/?";
        //pub export const LUA_PATH = "?;?.lua;scripts/?.lua;scripts/?";

        pub const DOC_inv_interact_action: []const u8 =
            \\A action is a string of words: "DIRECTION COUNT MATCH_TYPE MATCH_PARAMS"
            \\DIRECTION can be, "deposit", "withdraw"
            \\COUNT can be a number or "all"
            \\MATCH_TYPE can be:                            "item", "any", "category", "tag"
            \\MATCH_PARAM is an argument to MATCH_TYPE :     NAME           CAT_NAME   TAG_NAME
            \\Tag name is a tag within the minecraft:item tag list, example: minecraft:axes
            \\
            \\CAT_NAME comes from item_sort.json
            \\Example actions:
            \\"withdraw 1 item iron_pickaxe"
            \\"deposit all any" --deposit all items
            \\"deposit all category dye" --deposit any items defined as dye in item_sort.json
        ;

        pub export fn allowYield(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            self.allow_yield = self.vm.getArg(L, bool, 1);

            return 0;
        }

        pub export fn reverseDirection(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, Reg.Direction, 1);

            Lua.pushV(L, p.reverse());
            return 1;
        }
        //TODO every exported lua function should be wrapped in a BEGIN_LUA, END_LUA function pair.
        //all stack operations are tracked
        //at compile time we can detect when an error has been made regarding stack discipline

        const invalidErr = ErrorMsg{ .code = "invalidThing", .msg = "Expects a different kind of thingy" };
        pub const fn_giveError = Doc{
            .desc = "nothing",
            .errors = &.{invalidErr},
            .args = &.{},
        };
        pub export fn giveError(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            _ = self;
            returnError(L, invalidErr);
        }

        pub const fn_command = Doc{
            .errors = &.{},
            .desc = "Execute a Minecraft command",
            .args = &.{.{ .type = "string", .name = "command", .desc = "minecraft command to execute" }},
        };
        pub export fn command(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, []const u8, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var ar = std.ArrayList(u8).init(self.world.alloc);
            ar.appendSlice(p) catch unreachable;
            errc(actions.append(.{ .chat = .{ .str = ar, .is_command = true } })) orelse return 0;

            return 0;
        }

        pub const fn_say = Doc{
            .errors = &.{},
            .desc = "send a chat",
            .args = &.{.{ .type = "string", .name = "message", .desc = "" }},
        };
        pub export fn say(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, []const u8, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var ar = std.ArrayList(u8).init(self.world.alloc);
            ar.appendSlice(p) catch unreachable;
            errc(actions.append(.{ .chat = .{ .str = ar, .is_command = false } })) orelse return 0;

            return 0;
        }

        //TODO function that takes a table mapping chests to the items they provide or request

        pub const fn_applySlice = Doc{
            .errors = &.{},
            .desc = "Build a 2d slice in the world",
            .args = &.{.{ .type = "BuildLayer", .name = "slice", .desc = "see main.BuildLayer" }},
        };
        pub export fn applySlice(L: Lua.Ls) c_int {
            //TODO handling blocks with orientation
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, BuildLayer, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            defer self.bo.modify_mutex.unlock();
            //for each item in bitmap
            //calculate world position
            //add relavant item to action items
            //
            //
            //rotation in x swaps y = -z, z = y
            //in y x = -z, z = x
            //in z x = -y, y = x
            const bf = pos.toIFloor();
            const offset = p.offset.toIFloor();
            const w = p.w;
            var ii = p.bitmap.len;
            while (ii > 0) : (ii -= 1) {
                const i = ii - 1;
                const bl = p.bitmap[i];
                //for (p.bitmap, 0..) |bl, i| {
                //TODO if block already exists, skip it
                const x: i32 = @intCast(i % w);
                const y: i32 = @intCast(i / w);
                var loc = V3i.new(x, 0, y).add(offset);
                if (p.direction) |dir| {
                    switch (dir) {
                        .south => {
                            const t = loc.y;
                            loc.y = -loc.z;
                            loc.z = t;
                            loc.x = -loc.x;
                        },
                        .north => {
                            const t = loc.y;
                            loc.y = -loc.z;
                            loc.z = -t;
                            loc.x = loc.x;
                        },
                        .east => {
                            const t = loc.x;
                            loc.x = loc.y;
                            loc.y = -loc.z;
                            loc.z = t;
                        },
                        .west => {
                            const t = loc.x;
                            loc.x = -loc.y;
                            loc.y = -loc.z;
                            loc.z = -t;
                        },
                    }
                }
                const bpos = bf.add(loc);
                if (self.world.chunkdata(self.bo.dimension_id).getBlock(bpos)) |id| {
                    if (std.mem.eql(u8, bl, "noop"))
                        continue;
                    const item = self.world.reg.getItemFromName(bl) orelse {
                        std.debug.print("unkown item {s}\n", .{bl});
                        continue;
                    };
                    const block = self.world.reg.getBlockFromState(id);
                    //first check if the block has sand or gravel above it, if yes, ?

                    if (std.mem.eql(u8, item.name, block.name)) {
                        continue;
                    }

                    if (!std.mem.eql(u8, "air", bl)) {
                        errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                        errc(actions.append(.{ .hold_item_name = item.id })) orelse return 0;
                    }
                    if (id != 0) {
                        var timeout: ?f64 = null;
                        if (self.world.chunkdata(self.bo.dimension_id).getBlock(bpos.add(V3i.new(0, 1, 0)))) |above| {
                            const b = self.world.reg.getBlockFromState(above);
                            if (std.mem.eql(u8, b.name, "gravel") or std.mem.eql(u8, b.name, "sand")) {
                                timeout = 10;
                            }
                        }
                        const below = self.world.chunkdata(self.bo.dimension_id).getBlock(bpos.add(V3i.new(0, -1, 0)));
                        const place_below = (timeout != null and (below == null or below.? == 0));
                        if (place_below) {
                            errc(actions.append(.{ .block_break_pos = .{ .pos = bpos.add(V3i.new(0, -1, 0)) } })) orelse return 0;
                        }
                        //if(std.mem.eql(u8, self.world.reg.getBlockFromNameI("gravel")))
                        errc(actions.append(.{ .block_break_pos = .{ .pos = bpos, .repeat_timeout = timeout } })) orelse return 0;
                        if (place_below) {
                            //place a block below and delete after
                            errc(actions.append(.{ .place_block = .{ .pos = bpos.add(V3i.new(0, -1, 0)) } })) orelse return 0;
                            errc(actions.append(.{ .hold_item_name = 1 })) orelse return 0;
                        }
                    }
                    if (std.mem.eql(u8, block.name, "water")) {
                        errc(actions.append(.{ .block_break_pos = .{ .pos = bpos } })) orelse return 0;
                        errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                        errc(actions.append(.{ .hold_item_name = self.world.reg.getItemFromName("stone").?.id })) orelse return 0;
                    }
                }
                //errc(actions.append(.{ .wait_ms = 300 })) orelse return 0;
            }

            //Lua.pushV(L, p.toVec());
            return 0;
        }

        pub const fn_getMcTime = Doc{
            .errors = &.{},
            .desc = "returns an integer representing minecraft world time",
            .returns = .{ .type = "int", .name = "time", .desc = "" },
            .args = &.{},
        };
        pub export fn getMcTime(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.world.modify_mutex.lock();
            defer self.world.modify_mutex.unlock();

            Lua.pushV(L, self.world.time);
            return 1;
        }

        pub const DOC_directionToVec: []const u8 = "Test";
        pub export fn directionToVec(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, Reg.Direction, 1);

            Lua.pushV(L, p.toVec());
            return 1;
        }

        pub export fn freemovetest(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const p = self.vm.getArg(L, V3f, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            self.bo.modify_mutex.unlock();

            errc(actions.append(.{ .movement = .{ .kind = .freemove, .pos = pos.add(p) } })) orelse return 0;

            return 0;
        }

        pub const fn_blockInfo = Doc{
            .errors = &.{},
            .desc = "get block state and name information",
            .returns = .{ .type = "table{name:str, state: table}", .name = "blockinfo", .desc = "" },
            .args = &.{.{ .type = "Vec3", .name = "block_coord", .desc = "" }},
        };
        pub export fn blockInfo(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            const vm = self.vm;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const p = vm.getArg(L, V3f, 1).toIFloor();

            if (self.world.chunkdata(self.bo.dimension_id).getBlock(p)) |id| {
                const block = self.world.reg.getBlockFromState(id);
                var buf: [6]Reg.Block.State.KV = undefined;
                const states = self.world.reg.getBlockStates(id, &buf);
                Lua.c.lua_newtable(L);

                Lua.pushV(L, @as([]const u8, "name"));
                Lua.pushV(L, block.name);
                Lua.c.lua_settable(L, -3);

                Lua.pushV(L, @as([]const u8, "state"));
                Lua.c.lua_newtable(L);
                for (states) |st| {
                    Lua.pushV(L, st.key);
                    switch (st.val) {
                        .int => |in| Lua.pushV(L, in),
                        .boolean => |b| Lua.pushV(L, b),
                        .enum_ => |e| Lua.pushV(L, e),
                    }
                    Lua.c.lua_settable(L, -3);
                }
                Lua.c.lua_settable(L, -3);
                return 1;
            }
            returnError(L, .{ .code = "unknownBlock", .msg = "" });
        }

        pub const DOC_sleepms: []const u8 = "Args: [int: time in ms], sleep lua script, scripts onYield is still called during sleep";
        pub export fn sleepms(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const n_ms = self.vm.getArg(L, u64, 1);
            const max_time_ms = 500;
            if (n_ms > max_time_ms) {
                var remaining = n_ms;
                while (remaining > max_time_ms) : (remaining -= max_time_ms) {
                    _ = self.beginHalt();
                    defer _ = self.endHalt();
                    std.time.sleep(max_time_ms * std.time.ns_per_ms);
                }
            }
            const stime = n_ms % max_time_ms;
            _ = self.beginHalt();
            defer _ = self.endHalt();
            std.time.sleep(stime);
            return 0;
        }

        pub const DOC_gotoLandmark: []const u8 = "Args: [string: landmark name] returns (vec3) landmark coord. Make the bot pathfind to the landmark";
        pub const errWpNotFound = ErrorMsg{ .code = "notFound", .msg = "" };
        pub export fn gotoLandmark(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const str = self.vm.getArg(L, []const u8, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            _ = B: {
                self.bo.modify_mutex.lock();
                const pos = self.bo.getPos();
                self.pathctx.reset(self.bo.dimension_id) catch |E| break :B E;
                const did = self.bo.dimension_id;
                self.bo.modify_mutex.unlock();
                const wp = self.world.getNearestSignWaypoint(did, str, pos.toI()) orelse {
                    log.warn("Can't find waypoint: {s}", .{str});
                    self.endHaltReturnErr(L, errWpNotFound);
                };
                const found = self.pathctx.pathfind(did, pos, wp.pos.toF(), actions, .{}) catch |E| break :B E;

                if (!found) {
                    log.warn("Can't path to waypoint: {any}", .{wp.pos});
                    self.endHaltReturnErr(L, .{ .code = "noPath", .msg = "" });
                }
                Lua.pushV(L, wp);
            } catch {
                self.endHaltReturnErr(L, .{ .code = "zigError", .msg = "" });
            };

            return 1;
        }

        pub export fn pathfindColumnMatch(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const match_list = self.vm.getArg(L, astar.ColumnMatchArg, 1);
            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            const did = self.bo.dimension_id;
            self.bo.modify_mutex.unlock();
            const found = self.pathctx.findNearestMatchingColumn(pos, did, actions, match_list, .{ .max_iterations = 10000 }) catch unreachable;
            if (found == null) {
                std.debug.print("COULDNT FIND\n", .{});
                return 0;
            }
            Lua.pushV(L, found.?);
            return 1;
        }

        pub export fn getBreakableSlice(L: Lua.Ls) c_int {
            //return a list of blocks from coord -4 +4 in xz excluding corners
            const self = lss orelse return 0;
            _ = self.beginHalt();
            defer _ = self.endHalt();
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const head_block = self.vm.getArg(L, V3i, 1);

            var list = std.ArrayList(V3i).init(self.vm.fba.allocator());
            for (0..9) |y| {
                for (0..9) |x| {
                    const fx: i32 = @intCast(x);
                    const fy: i32 = @intCast(y);

                    if ((x == 0 or x == 8) and (y == 0 or y == 8)) //Omit corners, player can't reach
                        continue;
                    list.append(head_block.add(.{ .x = fx - 4, .y = 0, .z = fy - 4 })) catch unreachable;
                }
            }

            Lua.pushV(L, list.items);
            return 1;
        }

        pub export fn doesEntityExist(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const ent_id = self.vm.getArg(L, i32, 1);

            Lua.pushV(L, self.world.getEntity(ent_id) != null);
            return 1;
        }

        pub export fn getEntityPos(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const ent_id = self.vm.getArg(L, i32, 1);

            Lua.pushV(L, self.world.getEntity(ent_id).?.pos);
            return 1;
        }

        pub export fn findNearbyItemsId(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            _ = self.beginHalt();
            defer _ = self.endHalt();
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const max_dist = self.vm.getArg(L, f64, 1);

            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            defer self.bo.modify_mutex.unlock();

            var list = std.ArrayList(i32).init(self.vm.fba.allocator());

            self.world.entities_mutex.lock();
            defer self.world.entities_mutex.unlock();
            var e_it = self.world.entities.iterator();
            while (e_it.next()) |e| {
                if (e.value_ptr.kind == .item) {
                    if (e.value_ptr.pos.subtract(pos).magnitude() < max_dist) {
                        list.append(e.key_ptr.*) catch return 0;
                    }
                }
            }

            Lua.pushV(L, list.items);
            return 1;
        }

        pub export fn findNearbyItems(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const max_dist = self.vm.getArg(L, f64, 1);
            _ = self.beginHalt();
            defer _ = self.endHalt();

            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            defer self.bo.modify_mutex.unlock();

            var list = std.ArrayList(V3i).init(self.vm.fba.allocator());

            self.world.entities_mutex.lock();
            defer self.world.entities_mutex.unlock();
            var e_it = self.world.entities.iterator();
            while (e_it.next()) |e| {
                if (e.value_ptr.kind == .item) {
                    if (e.value_ptr.pos.subtract(pos).magnitude() < max_dist) {
                        const bpos = V3i.new(
                            @intFromFloat(@floor(e.value_ptr.pos.x)),
                            @intFromFloat(@floor(e.value_ptr.pos.y)),
                            @intFromFloat(@floor(e.value_ptr.pos.z)),
                        );
                        list.append(bpos) catch return 0;
                    }
                }
            }

            Lua.pushV(L, list.items);
            return 1;
        }

        pub export fn getLandmark(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            _ = self.beginHalt();
            defer _ = self.endHalt();
            Lua.c.lua_settop(L, 1);
            const str = self.vm.getArg(L, []const u8, 1);
            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            const did = self.bo.dimension_id;
            self.bo.modify_mutex.unlock();

            const wp = self.world.getNearestSignWaypoint(did, str, pos.toI()) orelse {
                log.warn("Can't find waypoint: {s}", .{str});
                returnError(L, errWpNotFound);
            };

            Lua.pushV(L, wp);

            return 1;
        }

        //Arg x y z, item_name, ?face
        pub export fn placeBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 3);
            const bposf = self.vm.getArg(L, V3f, 1);
            const bpos = V3i.new(
                @intFromFloat(@floor(bposf.x)),
                @intFromFloat(@floor(bposf.y)),
                @intFromFloat(@floor(bposf.z)),
            );
            const item_name = self.vm.getArg(L, []const u8, 2);

            const face = self.vm.getArg(L, ?Reg.Direction, 3);
            _ = face;
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            if (self.bo.inventory.findItem(self.world.reg, item_name)) |found| {
                errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(found.index)) } })) orelse return 0;
            } else {
                std.debug.print("ITEM NOT FOUND {s}\n", .{item_name});
                if (eql(u8, "use", item_name)) {
                    errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                }
            }
            return 0;
        }

        pub export fn placeBlockTag(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 3);
            const bposf = self.vm.getArg(L, V3f, 1);
            const bpos = V3i.new(
                @intFromFloat(@floor(bposf.x)),
                @intFromFloat(@floor(bposf.y)),
                @intFromFloat(@floor(bposf.z)),
            );
            const item_name = self.vm.getArg(L, []const u8, 2);

            const face = self.vm.getArg(L, ?Reg.Direction, 3);
            _ = face;
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            if (self.bo.inventory.findItemWithTag(&self.world.tag_table, item_name)) |found| {
                errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(found.index)) } })) orelse return 0;
            } else {
                std.debug.print("ITEM NOT FOUND {s}\n", .{item_name});
                if (eql(u8, "use", item_name)) {
                    errc(actions.append(.{ .place_block = .{ .pos = bpos } })) orelse return 0;
                }
            }
            return 0;
        }

        pub export fn gotoNearestCrafting(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            defer self.bo.modify_mutex.unlock();

            if (self.world.dimPtr(self.bo.dimension_id).poi.findNearest(self.world, pos.toIFloor())) |nearest| {
                const found = errc(self.pathctx.pathfind(self.bo.dimension_id, pos, nearest.toF(), actions, .{ .min_distance = 4 })) orelse return 0;
                if (found) {
                    Lua.pushV(L, nearest);
                    return 1;
                }
            }
            returnError(L, .{ .code = "noNearbyCraftingTable", .msg = "" });
        }

        pub export fn breakBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const bpos = self.vm.getArg(L, V3f, 1).toIFloor();
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            errc(actions.append(.{ .block_break_pos = .{ .pos = bpos } })) orelse return 0;
            return 0;
        }

        pub export fn gotoCoord(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            const p = self.vm.getArg(L, V3f, 1);
            const opt_dist = self.vm.getArg(L, ?f32, 2);
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            const did = self.bo.dimension_id;
            const pos = self.bo.getPos();
            self.bo.modify_mutex.unlock();
            const found = errc(self.pathctx.pathfind(did, pos, p, actions, .{ .min_distance = opt_dist })) orelse return 0;
            if (found) {
                Lua.pushV(L, true);
                return 1;
            }

            returnError(L, .{ .code = "noPath", .msg = "" });
        }

        pub export fn getBlockId(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            _ = self.beginHalt();
            defer _ = self.endHalt();
            const name = self.vm.getArg(L, []const u8, 1);
            const id = self.world.reg.getBlockFromName(name);
            Lua.pushV(L, id);
            return 1;
        }

        pub export fn getBlock(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            _ = self.beginHalt();
            defer _ = self.endHalt();

            const name = self.vm.getArg(L, []const u8, 1);
            const id = self.world.reg.getBlockFromNameI(name);
            Lua.pushV(L, id);
            return 1;
        }

        pub export fn blockHasTag(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            const coord = self.vm.getArg(L, V3i, 1);
            const tag = self.vm.getArg(L, []const u8, 2);

            self.bo.modify_mutex.lock();
            const did = self.bo.dimension_id;
            self.bo.modify_mutex.unlock();
            const has = blk: {
                break :blk (self.world.tag_table.hasTag(self.world.reg.getBlockFromState(self.world.chunkdata(did).getBlock(coord) orelse break :blk false).id, "minecraft:block", tag));
            };
            Lua.pushV(L, has);
            return 1;
        }

        // block name, tag name
        pub export fn hasBlockTag(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 2);
            const bname = self.vm.getArg(L, []const u8, 1);
            const tag = self.vm.getArg(L, []const u8, 2);
            const bid = self.world.reg.getBlockFromName(bname).?;
            Lua.pushV(L, self.world.tag_table.hasTag(bid, "minecraft:block", tag));
            return 1;
        }

        ///Args: landmarkName, blockname to search
        ///Returns, array of v3i
        //TODO add a maximum distance argument or max node count
        pub export fn getFieldFlood(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 3);
            _ = self.beginHalt();
            defer _ = self.endHalt();
            const landmark = self.vm.getArg(L, []const u8, 1);
            const block_name = self.vm.getArg(L, []const u8, 2);
            const max_dist = self.vm.getArg(L, f32, 3);
            const id = self.world.reg.getBlockFromName(block_name) orelse return 0;
            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            const did = self.bo.dimension_id;
            self.bo.modify_mutex.unlock();
            const wp = self.world.getNearestSignWaypoint(did, landmark, pos.toI()) orelse {
                std.debug.print("cant find waypoint: {s}\n", .{landmark});
                return 0;
            };
            //errc(self.pathctx.reset()) orelse return 0;
            const flood_pos = errc(self.pathctx.floodfillCommonBlock(wp.pos.toF(), id, max_dist, did)) orelse return 0;
            if (flood_pos) |fp| {
                Lua.pushV(L, fp.items);
                fp.deinit();
                return 1;
            }
            return 0;
        }

        pub const DOC_craftDumb: []const u8 = "Arg: [table_coord, item_name, count], searches recipes and will craft if it has all necessary ingredients in inventory ";
        pub export fn craftDumb(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 3);
            const wp = self.vm.getArg(L, V3f, 1).toIFloor();
            const item_name = self.vm.getArg(L, []const u8, 2);
            const item_count = self.vm.getArg(L, i32, 3);
            const actions = self.beginHalt();
            defer _ = self.endHalt();
            if (self.world.reg.getItemFromName(item_name)) |item| {
                if (self.world.reg.rec_map.get(item.id)) |recipe_list| {
                    for (recipe_list) |rec| {
                        var needed_ingred: [9]struct { count: u32 = 0, id: u32 = 0 } = undefined;
                        var needed_i: usize = 0;
                        if (rec.ingredients) |ing| {
                            for (ing) |in| {
                                var set = false;
                                for (0..needed_i) |i| {
                                    if (needed_ingred[i].id == in) {
                                        needed_ingred[i].count += 1;
                                        set = true;
                                    }
                                }
                                if (!set) {
                                    needed_ingred[needed_i] = .{ .id = in, .count = 1 };
                                    needed_i += 1;
                                }
                            }
                        }
                        if (rec.inShape) |shaped| {
                            for (shaped) |sh1| {
                                for (sh1) |sh| {
                                    const s = sh orelse continue;
                                    var set = false;
                                    for (0..needed_i) |i| {
                                        if (needed_ingred[i].id == s) {
                                            needed_ingred[i].count += 1;
                                            set = true;
                                        }
                                    }
                                    if (!set) {
                                        needed_ingred[needed_i] = .{ .id = s, .count = 1 };
                                        needed_i += 1;
                                    }
                                }
                            }
                        }
                        //How many rec to get needed amount

                        const mult: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(item_count)) / @as(f32, @floatFromInt(rec.result.count))));
                        var missing = false;
                        for (needed_ingred[0..needed_i]) |n| {
                            if (n.count * mult > self.bo.inventory.getCount(@intCast(n.id))) {
                                missing = true;
                            } else {
                                continue;
                            }
                            missing = true;
                        }
                        if (!missing) {
                            errc(actions.append(.{ .close_chest = {} })) orelse return 0;
                            errc(actions.append(.{ .wait_ms = 100 })) orelse return 0;
                            errc(actions.append(.{ .craft = .{ .product_id = item.id, .count = @intCast(mult) } })) orelse return 0;
                            errc(actions.append(.{ .wait_ms = 100 })) orelse return 0;
                            errc(actions.append(.{ .open_chest = .{ .pos = wp } })) orelse return 0;
                            return 0;
                        } else {}
                    }
                }
            }

            std.debug.print("CANT CRAFT\n", .{});
            Lua.pushV(L, "can't craft with materials");
            return 1;
        }

        pub export fn getInv(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 1);
            const interacted = self.vm.getArg(L, ?bool, 1);

            const inventory = if (interacted != null) &self.bo.interacted_inventory else &self.bo.inventory;
            const upper_index = if (interacted != null) inventory.slots.items.len - 36 else inventory.slots.items.len;
            var count: usize = 0;
            for (inventory.slots.items[0..upper_index]) |item| {
                if (item.count > 0)
                    count += 1;
            }
            const LuaItem = struct {
                name: []const u8,
                count: i32,
            };
            const ret_slice: []LuaItem = self.vm.getAlloc().alloc(LuaItem, count) catch return 0;
            var i: usize = 0;
            for (inventory.slots.items[0..upper_index]) |item| {
                if (item.count > 0) {
                    ret_slice[i] = .{
                        .count = item.count,
                        .name = self.world.reg.getItem(item.item_id).name,
                    };
                    i += 1;
                }
            }

            Lua.pushV(L, ret_slice);
            return 1;
            //for(inventory.slots.items[0..upper_index])
        }

        pub const DOC_interactChest: []const u8 = "Arg:[landmark_name, []inv_interact_action]";
        pub export fn interactChest(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 2);
            const name = self.vm.getArg(L, []const u8, 1);
            const to_move = self.vm.getArg(L, [][]const u8, 2);
            self.bo.modify_mutex.lock();
            const pos = self.bo.getPos();
            const did = self.bo.dimension_id;
            self.bo.modify_mutex.unlock();
            const wp = self.world.getNearestSignWaypoint(did, name, pos.toI()) orelse {
                std.debug.print("interactChest can't find waypoint {s}\n", .{name});
                return 0;
            };
            return self.interactChest(wp.pos, to_move);
        }

        pub export fn interactInv(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            const bpos = self.vm.getArg(L, V3f, 1).toIFloor();
            const to_move = self.vm.getArg(L, [][]const u8, 2);
            return self.interactChest(bpos, to_move);
        }

        pub const DOC_getSortCategories: []const u8 = "Args: [], returns []string, Names of all sorting categories defined in item_sort.json";
        pub export fn getSortCategories(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.pushV(L, self.world.reg.item_categories.categories.items);
            return 1;
        }

        pub const DOC_getPosition: []const u8 = "Args: [], return (Vec3) of bots current world position";
        pub export fn getPosition(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            _ = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();

            Lua.pushV(L, self.bo.getPos());
            return 1;
        }

        pub const DOC_getHunger: []const u8 = "Args: [], returns (int 0-20) bots hunger";
        pub export fn getHunger(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            _ = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();

            Lua.pushV(L, self.bo.food);
            return 1;
        }

        pub const DOC_timestamp: []const u8 = "Args: [], returns (int) a real world timestamp in seconds";
        pub export fn timestamp(L: Lua.Ls) c_int {
            Lua.pushV(L, std.time.timestamp());
            return 1;
        }

        pub export fn timestamp_ms(L: Lua.Ls) c_int {
            Lua.pushV(L, std.time.milliTimestamp());
            return 1;
        }

        //TODO itemCount function that works with nonplayer inventories.
        pub const DOC_itemCount: []const u8 = "Args: item_predicate, returns (int),\n\titem_predicate is a string [[item, any, category] argument] where argument depends on the predicate. Examples: \"category food\" or \"item stone_bricks\"";
        pub export fn itemCount(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            self.vm.clearAlloc();
            Lua.c.lua_settop(L, 2);
            const query = self.vm.getArg(L, []const u8, 1);
            const interactedO = self.vm.getArg(L, ?bool, 2);
            const interacted = interactedO != null and interactedO.?;
            _ = self.beginHalt();
            defer _ = self.endHalt();
            var it = std.mem.tokenizeScalar(u8, query, ' ');
            //MATCH_TYPE MATCH_PARAM
            const match_str = it.next() orelse {
                self.endHaltReturnErrL("expected_string", .{});
            };
            const match = sToE(enum { item, any, category, tag }, match_str) orelse {
                self.endHaltReturnErrL("invalid match predicate: {s}", .{match_str});
            };
            var item_id: Reg.Item = undefined;
            var tag_list: ?[]const u32 = null;
            var cat: PlayerActionItem.Inv.ItemCategory = undefined;
            switch (match) {
                .tag => {
                    const tag_name = it.next() orelse {
                        self.endHaltReturnErrL("expected tag name", .{});
                    };
                    tag_list = self.world.tag_table.getIdList("minecraft:item", tag_name) orelse {
                        self.endHaltReturnErrL("invalid tag {s} for minecraft:item", .{tag_name});
                    };
                },
                .item => {
                    const item_name = it.next() orelse {
                        self.endHaltReturnErrL("expected item name", .{});
                    };
                    item_id = self.world.reg.getItemFromName(item_name) orelse {
                        self.endHaltReturnErrL("invalid item name: {s}", .{item_name});
                    };
                },
                .category => {
                    const cat_str = it.next() orelse {
                        self.endHaltReturnErrL("expected category name", .{});
                    };
                    cat = sToE(PlayerActionItem.Inv.ItemCategory, cat_str) orelse {
                        self.endHaltReturnErrL("unknown category: {s}", .{cat_str});
                    };
                },
                else => {},
            }
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var item_count: usize = 0;
            const inventory = if (interacted) &self.bo.interacted_inventory else &self.bo.inventory;
            const upper_index = if (interacted) inventory.slots.items.len - 36 else inventory.slots.items.len;
            for (inventory.slots.items[0..upper_index]) |sl| {
                const slot = if (sl.count > 0) sl else continue;

                switch (match) {
                    .tag => {
                        if (tag_list) |tl| {
                            for (tl) |t| {
                                if (t == slot.item_id)
                                    item_count += slot.count;
                            }
                        }
                    },
                    .item => {
                        if (slot.item_id == item_id.id)
                            item_count += slot.count;
                    },
                    .any => {
                        item_count += slot.count;
                    },
                    .category => {
                        switch (cat) {
                            .food => {
                                for (self.world.reg.foods) |food| {
                                    if (food.id == slot.item_id) {
                                        item_count += slot.count;
                                        break;
                                    }
                                }
                            },
                        }
                    },
                }
            }

            Lua.pushV(L, item_count);
            return 1;
        }

        pub const DOC_countFreeSlots: []const u8 = "Args:[], returns (int) number of usable free slots in bots inventory";
        pub export fn countFreeSlots(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            _ = self.beginHalt();
            defer _ = self.endHalt();
            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            var count: usize = 0;
            //Start at index 8 of inventory, skipping the armor slots and crafting bench
            for (self.bo.inventory.slots.items[8..]) |sl| {
                if (sl.count == 0)
                    count += 1;
            }
            Lua.pushV(L, count);
            return 1;
        }

        pub const DOC_eatFood: []const u8 = "Args:[], searches for first food item in inventory and eats returns true if bot ate.";
        pub export fn eatFood(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 0);
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            self.bo.modify_mutex.lock();
            defer self.bo.modify_mutex.unlock();
            if (self.bo.inventory.findItemFromList(self.world.reg.foods, "id")) |food_slot| {
                errc(actions.append(.{ .eat = {} })) orelse return 0;
                errc(actions.append(.{ .hold_item = .{ .slot_index = @as(u16, @intCast(food_slot.index)) } })) orelse return 0;
                Lua.pushV(L, true);
                return 1;
            }
            Lua.pushV(L, false);
            return 1;
        }

        pub export fn holdSlot(L: Lua.Ls) c_int {
            const self = lss orelse return 0;
            Lua.c.lua_settop(L, 1);
            const ind = self.vm.getArg(L, i32, 1);
            const actions = self.beginHalt();
            defer _ = self.endHalt();

            errc(actions.append(.{ .hold_item = .{ .slot_index = 0, .hotbar_index = @intCast(ind) } })) orelse return 0;
            return 0;
        }
    };
};
pub fn luaBotScript(bo: *Bot, alloc: std.mem.Allocator, world: *McWorld, filename: []const u8) !void {
    if (lss != null)
        return error.lua_script_state_AlreadyInit;
    var luavm = Lua.init();
    var script_state = LuaApi.init(alloc, world, bo, &luavm);
    defer script_state.deinit();
    lss = &script_state;
    luavm.loadAndRunFile("scripts/common.lua");
    luavm.loadAndRunFile(filename);
    _ = Lua.c.lua_getglobal(luavm.state, "onYield");
    const t = Lua.c.lua_type(luavm.state, 1);
    Lua.c.lua_pop(luavm.state, 1);
    if (t == Lua.c.LUA_TFUNCTION) {
        script_state.has_yield_fn = true;
    }

    while (true) {
        if (bo.th_d.exit_mutex.tryLock()) {
            bo.th_d.setStatus(.terminated);
            bo.th_d.exit_mutex.unlock();
            return;
        }
        if (bo.th_d.reload_mutex.tryLock()) {
            bo.th_d.reload_mutex.unlock();
            bo.th_d.setStatus(.terminated_waiting_for_restart);
        }
        luavm.callLuaFunction("loop") catch |err| {
            switch (err) {
                error.luaError => break,
            }
        };
    }
    if (bo.th_d.getStatus() == .running)
        bo.th_d.setStatus(.crashed);
}

pub fn updateLoop(exit_mutex: *std.Thread.Mutex, bo: *Bot, arena_alloc: std.mem.Allocator, world: *McWorld) !void {
    const log = std.log.scoped(.update);
    var skip_ticks: i32 = 0;
    const dt: f64 = 1.0 / 20.0;
    while (true) {
        var tick_timer = try std.time.Timer.start();
        if (exit_mutex.tryLock()) {
            exit_mutex.unlock(); //Allow beginHalt to finish exiting
            return;
        }
        if (bo.th_d.reload_mutex.tryLock()) {
            bo.th_d.reload_mutex.unlock();
            return;
        }

        bo.modify_mutex.lock();
        bo.update(dt, 1);
        bo.modify_mutex.unlock();
        var bp = mc.PacketCtx{ .packet = try mc.Packet.init(arena_alloc, bo.compression_threshold), .server = (std.net.Stream{ .handle = bo.fd }).writer(), .mutex = &bo.fd_mutex };
        { // bot Mutex held within this block
            bo.modify_mutex.lock();
            defer bo.modify_mutex.unlock();
            if (!bo.handshake_complete)
                continue;

            if (skip_ticks > 0) {
                skip_ticks -= 1;
            } else {
                var bpos = bo.getPos();
                const th_d = &bo.th_d;
                if (th_d.action_index) |action| {
                    switch (th_d.actions.items[action]) {
                        .chat => |ch| {
                            if (ch.is_command) {
                                try bp.sendCommand(ch.str.items);
                            } else {
                                try bp.sendChat(ch.str.items);
                            }
                            th_d.nextAction(0, bpos);
                        },
                        .movement => |move_| {
                            const move = move_;
                            const adt = dt;
                            var grounded = true;
                            var moved = false;
                            const pw = mc.lookAtBlock(bpos, V3f.new(0, 0, 0), 0);
                            while (true) {
                                const move_vec = th_d.move_state.update(adt) catch |err| {
                                    log.err("move_state.update failed, canceling move {!}", .{err});
                                    try th_d.clearActions();
                                    th_d.setError(.{ .code = "invalidMove", .msg = "Error occured during move_state.update" });
                                    return;
                                    //th_d.unlock(.bot_thread);
                                    //TODO on teleport, also cancel move
                                    //break;
                                };
                                grounded = move_vec.grounded;

                                bo.pos = move_vec.new_pos;
                                bpos = bo.getPos();
                                moved = true;

                                if (move_vec.move_complete) {
                                    th_d.nextAction(move_vec.remaining_dt, bpos);
                                    if (th_d.action_index) |new_acc| {
                                        if (th_d.actions.items[new_acc] != .movement) {
                                            break;
                                        } else if (th_d.actions.items[new_acc].movement.kind == .jump and move.kind == .jump) {
                                            th_d.move_state.time = 0;
                                            //skip_ticks = 100;
                                            break;
                                        }
                                    } else {
                                        break;
                                        //th_d.unlock(.bot_thread); //We have no more left so notify
                                        //break;
                                        //return;
                                    }
                                } else {
                                    //TODO signal error
                                    //should report to the bot
                                    break;
                                }
                                //move_vec = //above switch statement
                            }
                            if (moved) {
                                try bp.setPlayerPositionRot(bpos, pw.yaw, pw.pitch, grounded);
                            }
                        },
                        .eat => {
                            const EATING_TIME_S = 1.61;
                            if (th_d.timer == null) {
                                try bp.useItem(.main, 0, .{ .x = 0, .y = 0 });
                                th_d.timer = dt;
                            } else {
                                th_d.timer.? += dt;
                                if (th_d.timer.? >= EATING_TIME_S) {
                                    try bp.playerAction(.shoot_arrowEat, .{ .x = 0, .y = 0, .z = 0 });
                                    th_d.nextAction(0, bpos);
                                }
                            }
                        },
                        .wait_ms => |wms| {
                            skip_ticks = @intFromFloat(@as(f64, @floatFromInt(wms)) / 1000 / dt);
                            th_d.nextAction(0, bpos);
                        },
                        .hold_item_name => |in| {
                            try bp.setHeldItem(0);
                            if (bo.inventory.findItemFromId(in)) |found| {
                                try bp.clickContainer(0, bo.container_state, found.index, 0, 2, &.{}, .{});
                            }
                            th_d.nextAction(0, bpos);
                        },
                        .hold_item => |si| {
                            try bp.setHeldItem(@intCast(si.hotbar_index));
                            try bp.clickContainer(0, bo.container_state, si.slot_index, @intCast(si.hotbar_index), 2, &.{}, .{});
                            th_d.nextAction(0, bpos);
                        },
                        .craft => |cr| {
                            if (bo.interacted_inventory.win_id) |wid| {
                                if (th_d.craft_item_counter == null) {
                                    th_d.craft_item_counter = cr.count;
                                }
                                const count = &th_d.craft_item_counter.?;
                                if (count.* == 64) {
                                    //FIXME the recipe ids are no longer valid, they are send in recipe_book_add
                                    try bp.doRecipeBook(wid, cr.product_id, true);
                                    count.* = 0;
                                } else {
                                    try bp.doRecipeBook(wid, cr.product_id, false);
                                    if (count.* >= 1)
                                        count.* -= 1;
                                }
                                if (count.* == 0) {
                                    try bp.clickContainer(wid, bo.container_state, 0, 1, 1, &.{}, .{});
                                    th_d.nextAction(0, bpos);
                                } else {
                                    skip_ticks = 1; //Throttle the packets we are sending
                                }
                            } else {
                                th_d.nextAction(0, bpos);
                            }
                        },
                        .inventory => |inv| {
                            if (bo.interacted_inventory.win_id) |wid| {
                                //std.debug.print("Inventory interact:  {any}\n", .{inv});
                                var num_transfered: u8 = 0;
                                const magic_num = 36; //should this be 36?
                                const inv_len = bo.interacted_inventory.slots.items.len;
                                const player_inv_start = inv_len - magic_num;
                                const search_i = if (inv.direction == .deposit) player_inv_start else 0;
                                const search_i_end = if (inv.direction == .deposit) inv_len else player_inv_start;
                                for (bo.interacted_inventory.slots.items[search_i..search_i_end], search_i..) |slot, i| {
                                    const s = if (slot.count > 0) slot else continue;
                                    var should_move = false;
                                    switch (inv.match) {
                                        .by_id => |match_id| {
                                            if (s.item_id == match_id) {
                                                should_move = true;
                                            }
                                        },
                                        .tag_list => |tags| {
                                            for (tags) |i_id| {
                                                if (i_id == s.item_id) {
                                                    should_move = true;
                                                    break;
                                                }
                                            }
                                        },
                                        .match_any => should_move = true,
                                        .category => |cat| {
                                            if (world.reg.item_categories.map.get(s.item_id) orelse 0 == cat) {
                                                should_move = true;
                                            }
                                        },
                                    }
                                    if (should_move) {
                                        try bp.clickContainer(wid, bo.container_state, @intCast(i), 0, 1, &.{}, .{});
                                        num_transfered += 1;
                                        if (num_transfered == inv.count)
                                            break;
                                    }
                                }
                            }
                            th_d.nextAction(0, bpos);
                        },
                        .place_block => |pb| {
                            //TODO support placing block with orientation, slabs, stairs etc.
                            const pw = mc.lookAtBlock(bpos, pb.pos.toF(), 0);
                            if (pb.select_item_tag) |tag| {
                                if (world.tag_table.getIdList("minecraft:item", tag)) |taglist| {
                                    for (taglist) |t| {
                                        if (bo.inventory.findItemFromId(@intCast(t))) |found| {
                                            try bp.setHeldItem(0);
                                            try bp.clickContainer(0, bo.container_state, found.index, 0, 2, &.{}, .{});
                                            break;
                                        }
                                    }
                                }
                            }
                            try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                            try bp.useItemOn(.main, pb.pos, .north, 0, 0, 0, false, 0);
                            th_d.nextAction(0, bpos);
                        },
                        .open_chest => |ii| {
                            const pw = mc.lookAtBlock(bpos, ii.pos.toF(), 0.5); //look at Top face of block
                            try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                            try bp.useItemOn(.main, ii.pos, .top, 0, 0, 0, false, 0);
                            th_d.nextAction(0, bpos);
                        },
                        .close_chest => {
                            if (bo.interacted_inventory.win_id) |win| {
                                try bp.closeContainer(win);
                            } else {
                                log.warn("Close chest: no open inventory", .{});
                            }
                            //bo.interacted_inventory.win_id = null;
                            th_d.nextAction(0, bpos);
                        },
                        .block_break_pos => |p| {
                            //TODO catch error
                            if (th_d.timer == null) {
                                const pw = mc.lookAtBlock(bpos, p.pos.toF(), 0);
                                th_d.timer = dt;
                                const sid = world.chunkdata(bo.dimension_id).getBlock(p.pos).?;
                                const block = world.reg.getBlockFromState(sid);
                                if (eql(u8, "lava", block.name) or eql(u8, "water", block.name)) {
                                    th_d.timer = null;
                                    th_d.nextAction(0, bpos);
                                }
                                if (bo.inventory.findToolForMaterial(world.reg, block.material)) |match| {
                                    const hardness = block.hardness.?;
                                    const btime = Reg.calculateBreakTime(match.mul, hardness, .{
                                        .haste_level = bo.getEffect(.Haste),
                                    });
                                    th_d.break_timer_max = @as(f64, @floatFromInt(btime)) / 20.0;

                                    try bp.setHeldItem(0);
                                    try bp.clickContainer(0, bo.container_state, match.slot_index, 0, 2, &.{}, .{});
                                } else {
                                    annotateManualParse("1.21.3"); //Not really but it break in future
                                    if (eql(u8, block.name, "snow") or eql(u8, block.name, "snow_block")) {
                                        log.err("adequate_tool_level assumption is wrong for snow!", .{});
                                    }
                                    th_d.break_timer_max = @as(f64, @floatFromInt(Reg.calculateBreakTime(1, block.hardness.?, .{
                                        .best_tool = false,
                                        .haste_level = bo.getEffect(.Haste),
                                        //This check is only wrong for snow blocks, every other block can be broken by hand. So if you mine those blocks without a tool the server might complain. As of 1.21.3
                                        .adequate_tool_level = !std.mem.eql(u8, block.material, "mineable/pickaxe"),
                                    }))) / 20.0;
                                }
                                try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                try bp.playerAction(.start_digging, p.pos);
                            } else {
                                th_d.timer.? += dt;
                                if (th_d.timer.? >= th_d.break_timer_max) {
                                    try bp.playerAction(.finish_digging, p.pos);
                                    var reset = true;
                                    if (p.repeat_timeout) |t| {
                                        reset = false;
                                        const si = world.chunkdata(bo.dimension_id).getBlock(p.pos).?;
                                        if (si != 0) {
                                            skip_ticks = @intFromFloat(t);
                                            th_d.timer = null;
                                        } else {
                                            reset = true;
                                        }
                                        //is there a block? repeat else end

                                    }
                                    if (reset) {
                                        th_d.timer = null;
                                        th_d.nextAction(0, bpos);
                                    }
                                }
                            }
                        },
                        .block_break => |bb| {
                            if (th_d.timer == null) {
                                const pw = mc.lookAtBlock(bpos, bb.pos.toF(), 0);
                                try bp.setPlayerRot(pw.yaw, pw.pitch, true);
                                try bp.playerAction(.start_digging, bb.pos);
                                th_d.timer = dt;
                            } else {
                                if (th_d.timer.? >= bb.break_time) {
                                    th_d.timer = null;
                                    try bp.playerAction(.finish_digging, bb.pos);
                                    th_d.nextAction(0, bpos);
                                }
                                if (th_d.timer != null)
                                    th_d.timer.? += dt;
                            }
                        },
                    }
                } else {
                    //TODO move this somewhere else, it will never get executed here
                    //Quick and dirty floati protection
                    if (false) {
                        var dist_to_fall: f64 = -1;
                        //Check the bot is standing on something
                        if (world.chunkdata(bo.dimension_id).getBlock(bpos.add(V3f.new(0, dist_to_fall, 0)).toIFloor())) |under_o| {
                            var under: ?Reg.BlockId = under_o;

                            if (under_o == 0 or @trunc(bpos.y) != 0) { //Bot is standing on air, make it fall
                                while (under != null and under.? == 0) {
                                    dist_to_fall -= 1;
                                    under = world.chunkdata(bo.dimension_id).getBlock(bpos.add(V3f.new(0, dist_to_fall, 0)).toIFloor());
                                }
                                var actions = LuaApi.ActionListT.init(world.alloc);
                                var pos = bpos;
                                pos.y = @trunc(pos.y) + dist_to_fall + 1;
                                try actions.append(.{ .movement = .{ .kind = .freemove, .pos = pos } });
                                th_d.setActions(actions, bpos);
                            }
                        }
                    }
                    //th_d.unlock(.bot_thread); //No more actions, unlock
                    return;
                }
            }
        }

        const tick_took = tick_timer.read();
        //Support carpetmod variable ticktime?
        const dtns: u64 = @intFromFloat(dt * std.time.ns_per_s);
        if (tick_took > dtns) {
            log.warn("tick took {d:.2} ms", .{tick_took * std.time.ms_per_s / std.time.ns_per_s});
        } else {
            std.time.sleep(dtns - tick_took);
        }
        //std.time.sleep(@as(u64, @intFromFloat(std.time.ns_per_s * dt)));
    }
}

pub fn basicPathfindThread(
    alloc: std.mem.Allocator,
    world: *McWorld,
    start: V3f,
    goal: V3f,
    bot_handle: i32,
    return_ctx_mutex: *std.Thread.Mutex,
    return_ctx: *astar.AStarContext,
) !void {
    std.debug.print("PATHFIND CALLED \n", .{});
    var pathctx = astar.AStarContext.init(alloc, world);
    errdefer pathctx.deinit();

    //const found = try pathctx.findTree(start, 0, 0);
    const found = try pathctx.pathfind(start, goal, .{});
    if (found) |*actions| {
        const player_actions = actions;
        for (player_actions.items) |pitem| {
            _ = pitem;
            //std.debug.print("action: {any}\n", .{pitem});
        }

        const botp = world.bots.getPtr(bot_handle) orelse return error.invalidBotHandle;
        botp.modify_mutex.lock();
        botp.action_list.deinit();
        botp.action_list = player_actions.*;
        botp.action_index = player_actions.items.len;
        //botp.nextAction(0);
        botp.modify_mutex.unlock();
    }
    std.debug.print("FINISHED DUMPING\n", .{});

    return_ctx_mutex.lock();
    return_ctx.*.deinit();
    return_ctx.* = pathctx;
    return_ctx_mutex.unlock();
    std.debug.print("PATHFIND FINISHED\n", .{});
}

pub const ConsoleCommands = enum {
    query,
    remove,
    add,
    exit,
    reload,
    draw,
};

//TODO epoll layer. So bot can run on Windows
//Maybe just use libevent?
//Or multibot is only supported on linux and windows defalts to a single tcpconnect.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    defer _ = gpa.detectLeaks();
    errdefer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const cwd = std.fs.cwd();
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const log = std.log.scoped(.main);

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("draw", .flag, "Draw debug graphics"),
        Arg("doc", .flag, "print generated documentation and exit"),
        Arg("ip", .string, "Override ip"),
        Arg("port", .number, "Override port"),
    }, &arg_it);

    if (args.doc != null) {
        const info = @typeInfo(LuaApi.Api);
        //const seperator = "";
        inline for (info.Struct.decls) |d| {
            const fi = @field(LuaApi.Api, d.name);
            switch (@typeInfo(@TypeOf(fi))) {
                .Struct => {
                    if (@TypeOf(fi) == LuaApi.Doc) {
                        const dd = @field(LuaApi.Api, d.name);
                        std.debug.print("{s}:\n", .{d.name});
                        std.debug.print("Description: {s}:\n", .{dd.desc});
                        std.debug.print("Arguments:\n", .{});
                        for (dd.args) |er| {
                            std.debug.print("\t{s}:{s}\n", .{ er.name, er.type });
                        }
                        std.debug.print("returns: {s}:{s}\n", .{ dd.returns.name, dd.returns.type });
                        std.debug.print("Errors: \n", .{});
                        for (dd.errors) |er| {
                            std.debug.print("\t{s}, {s}\n", .{ er.code, er.msg });
                        }
                    }
                },
                else => {},
            }
        }
        return;
    }

    var arena_allocs = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocs.deinit();

    var dr = try Reg.DataReg.init(alloc, Proto.minecraftVersion);
    defer dr.deinit();
    try dr.addUserItemCategories(cwd, "item_sort.json");

    var config_vm = Lua.init();
    config_vm.loadAndRunFile("bot_config.lua");
    const bot_names = config_vm.getGlobal(config_vm.state, "bots", []struct {
        name: []const u8,
        script_name: []const u8,
    });

    const port: u16 = @intFromFloat(args.port orelse config_vm.getGlobal(config_vm.state, "port", f32));
    const ip = args.ip orelse config_vm.getGlobal(config_vm.state, "ip", []const u8);
    log.info("From bot_config.lua: ip {s}, port: {d}", .{ ip, port });

    const epoll_fd = try std.posix.epoll_create1(0);
    defer std.posix.close(epoll_fd);

    var world = McWorld.init(alloc, &dr);
    defer world.deinit();

    var event_structs: [config.MAX_BOTS]std.os.linux.epoll_event = undefined;
    var stdin_event: std.os.linux.epoll_event = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = std.io.getStdIn().handle } };
    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, std.io.getStdIn().handle, &stdin_event);

    var bot_fd: i32 = 0;
    for (bot_names, 0..) |bn, i| {
        const mb = try botJoin(alloc, bn.name, bn.script_name, ip, port, dr.version_id, &world);
        event_structs[i] = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = mb.fd } };
        try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, mb.fd, &event_structs[i]);
        try world.addBot(mb, @intCast(i));
        //For draw thread
        if (bot_fd == 0)
            bot_fd = mb.fd;
    }

    var events: [256]std.os.linux.epoll_event = undefined;

    var run = true;
    var tb = PacketParse{ .buf = std.ArrayList(u8).init(alloc) };
    defer tb.buf.deinit();

    if (args.draw != null) {
        const draw_thread = try std.Thread.spawn(.{}, drawThread, .{ alloc, &world });
        draw_thread.detach();
    }

    var bps_timer = try std.time.Timer.start();
    var bytes_read: usize = 0;
    while (run) {
        _ = arena_allocs.reset(.retain_capacity);
        {
            //Loop through threads and check status
            for (0..world.bot_threads.len) |i| {
                const bt = &(world.bot_threads[i] orelse continue);

                const st = bt.bot.th_d.getStatus();
                switch (st) {
                    .terminated => {
                        const stream = std.net.Stream{ .handle = world.bot_threads[i].?.bot.fd };
                        //Remove fd from epoll and kill the connection
                        try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_DEL, stream.handle, &event_structs[i]);
                        try world.removeBot(bt.bot.fd);
                        stream.close();
                        world.bot_threads[i] = null;
                    },
                    .terminated_waiting_for_restart, .waiting_for_ready => {
                        if (bt.bot.isReady()) {
                            std.debug.print("Starting bot\n", .{});
                            if (st == .terminated_waiting_for_restart)
                                bt.bot.th_d.reload_mutex.lock();
                            bt.bot.th_d.setStatus(.running);
                            if (bt.bot.script_filename) |sn| {
                                bt.handle = try std.Thread.spawn(.{}, luaBotScript, .{
                                    &bt.bot,
                                    alloc,
                                    &world,
                                    sn,
                                });
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        if (bps_timer.read() > std.time.ns_per_s) {
            bps_timer.reset();
            //std.debug.print("KBps: {d}\n", .{@divTrunc(bytes_read, 1000)});
            bytes_read = 0;
        }
        const e_count = std.posix.epoll_wait(epoll_fd, &events, 10);
        for (events[0..e_count]) |eve| {
            if (eve.data.fd == std.io.getStdIn().handle) {
                var msg: [256]u8 = undefined;
                const n = try std.posix.read(eve.data.fd, &msg);
                if (n == 0) { //Prevent integer overflow if user sends eof
                    run = false;
                    continue;
                }

                var itt = std.mem.tokenize(u8, msg[0 .. n - 1], " ");
                const key = itt.next() orelse continue;
                if (std.meta.stringToEnum(ConsoleCommands, key)) |k| {
                    switch (k) {
                        .exit => {
                            run = false;
                        },
                        .add => {
                            const bname = itt.next() orelse {
                                std.debug.print("Expected bot name\n", .{});
                                continue;
                            };
                            const script_name = itt.next() orelse {
                                std.debug.print("Expected script name\n", .{});
                                continue;
                            };
                            var empty_slot = false;
                            for (world.bot_threads, 0..) |b, i| {
                                if (b == null) {
                                    const mb = try botJoin(alloc, bname, script_name, ip, port, dr.version_id, &world);
                                    event_structs[i] = .{ .events = std.os.linux.EPOLL.IN, .data = .{ .fd = mb.fd } };
                                    try std.posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, mb.fd, &event_structs[i]);
                                    try world.addBot(mb, @intCast(i));

                                    empty_slot = true;
                                    break;
                                }
                            }
                            if (!empty_slot)
                                std.debug.print("No bot slots available\n", .{});
                        },
                        .remove => {
                            const bname = itt.next() orelse continue;
                            if (world.findBotFromName(bname)) |b| {
                                std.debug.print("Removing bot: {s}\n", .{b.name});
                                switch (b.th_d.getStatus()) {
                                    .waiting_for_ready, .terminated_waiting_for_restart, .crashed => {
                                        b.th_d.setStatus(.terminated);
                                    },
                                    .running => {
                                        b.th_d.exit_mutex.unlock();
                                    },
                                    .terminated => {},
                                }
                            } else {
                                std.debug.print("Can't find bot {s}\n", .{bname});
                            }
                        },
                        .reload => {
                            const bname = itt.next() orelse continue;
                            if (world.findBotFromName(bname)) |b| {
                                std.debug.print("Reloading bot: {s}\n", .{b.name});
                                switch (b.th_d.getStatus()) {
                                    .crashed => {
                                        b.th_d.setStatus(.waiting_for_ready);
                                    },
                                    .running => {
                                        b.th_d.reload_mutex.unlock();
                                    },
                                    .terminated, .terminated_waiting_for_restart, .waiting_for_ready => {},
                                }
                                break;
                            }
                        },
                        .draw => {
                            const draw_thread = try std.Thread.spawn(.{}, drawThread, .{ alloc, &world });
                            draw_thread.detach();
                        },
                        .query => { //query the tag table, "query ?namespace ?tag"
                            if (itt.next()) |tag_type| {
                                if (world.tag_table.tags.getPtr(tag_type)) |tags| {
                                    if (itt.next()) |wanted_tag| {
                                        if (tags.get(wanted_tag)) |t| {
                                            std.debug.print("Ids for: {s} {s}\n", .{ tag_type, wanted_tag });
                                            for (t.items) |item| {
                                                std.debug.print("\t{d}\n", .{item});
                                            }
                                        }
                                    } else {
                                        var kit = tags.keyIterator();
                                        var ke = kit.next();
                                        std.debug.print("Possible sub tag: \n", .{});
                                        while (ke != null) : (ke = kit.next()) {
                                            std.debug.print("\t{s}\n", .{ke.?.*});
                                        }
                                    }
                                }
                            } else {
                                var kit = world.tag_table.tags.keyIterator();
                                var ke = kit.next();
                                std.debug.print("Possible tags: \n", .{});
                                while (ke != null) : (ke = kit.next()) {
                                    std.debug.print("\t{s}\n", .{ke.?.*});
                                }
                            }
                        },
                    }
                } else {
                    std.debug.print("Unknown command: \"{s}\"\n", .{key});
                    std.debug.print("Possible commands: \n", .{});
                    inline for (@typeInfo(ConsoleCommands).Enum.fields) |f| {
                        std.debug.print("\t{s}\n", .{f.name});
                    }
                }
                continue;
            }

            const pp = &tb;

            var pbuf: [4096]u8 = undefined;
            var ppos: u32 = 0;

            local: while (true) {
                switch (pp.state) {
                    .len => { //Read bytes one at a time until we have a full varInt
                        var buf: [1]u8 = .{0xff};
                        const n = try std.posix.read(eve.data.fd, &buf);
                        if (n == 0) {
                            log.err("Read zero bytes, exting", .{});
                            run = false;
                            return;
                        }

                        pbuf[ppos] = buf[0];
                        ppos += 1;
                        if (buf[0] & 0x80 == 0) {
                            var fbs = std.io.FixedBufferStream([]u8){ .buffer = pbuf[0..ppos], .pos = 0 };
                            pp.data_len = @as(u32, @intCast(mc.readVarInt(fbs.reader())));
                            pp.len_len = @as(u32, @intCast(ppos));

                            if (pp.data_len.? == 0)
                                unreachable;

                            pp.state = .data;
                            if (pp.data_len.? > pbuf.len - pp.len_len.?) {
                                try pp.buf.resize(pp.data_len.? + pp.len_len.?);

                                @memcpy(pp.buf.items[0..ppos], pbuf[0..ppos]);
                                bytes_read += pp.data_len.?;
                            }
                        }
                    },
                    .data => {
                        const num_left_to_read = pp.data_len.? - pp.num_read;
                        const start = pp.len_len.? + pp.num_read;

                        if (pp.data_len.? > pbuf.len - pp.len_len.?) {
                            //TODO set this read to nonblocking?
                            const nr = try std.posix.read(eve.data.fd, pp.buf.items[start .. start + num_left_to_read]);

                            pp.num_read += @as(u32, @intCast(nr));
                            if (nr == 0) {
                                log.err("Read zero bytes, exting", .{});
                                run = false;
                                return;
                            }

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.getBotFromFd(eve.data.fd), pp.buf.items, &world);
                                try pp.buf.resize(0);
                                try pp.reset();
                                break :local;
                            }
                        } else {
                            const nr = try std.posix.read(eve.data.fd, pbuf[start .. start + num_left_to_read]);
                            pp.num_read += @as(u32, @intCast(nr));

                            if (nr == 0) {
                                log.err("Read zero bytes, exting", .{});
                                run = false;
                                return;
                            } //TODO properly support partial reads

                            if (nr == num_left_to_read) {
                                try parseSwitch(alloc, world.getBotFromFd(eve.data.fd), pbuf[0 .. pp.data_len.? + pp.len_len.?], &world);
                                bytes_read += pp.data_len.?;
                                try pp.reset();

                                break :local;
                            }
                        }
                    },
                }
            }
        }
    }
}
