const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const net = std.net;
const pingpong = @import("pingpong.zig");

const MvarChannelMap = @import("channel.zig").MvarChannelMap(AllRole);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next();
    if (arg_iter.next()) |arg_str| {
        std.debug.print("arg_str {s}\n", .{arg_str});
        if (std.mem.eql(u8, "dot", arg_str)) {
            const graph: ps.Graph = try ps.Graph.initWithFsm(gpa, Random2pc);
            const graph_fs = try std.fs.cwd().createFile("t.dot", .{});
            var graph_fs_writer = graph_fs.writer(try gpa.alloc(u8, 1 << 20));
            try graph.generateDot(&graph_fs_writer.interface);
            try graph_fs_writer.interface.flush();
        }
    }

    var mvar_channel_map: MvarChannelMap = .init();
    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);
    mvar_channel_map.enable_log(.charlie); //enable charlie channel log

    const alice = struct {
        fn clientFn(mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn clientFn(mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.bob, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn clientFn(mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.charlie, false, mcm, curr_id, &charlie_context);
        }
    };

    const selector = struct {
        fn clientFn(mcm: *MvarChannelMap) !void {
            var charlie_context: SelectorContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.selector, false, mcm, curr_id, &charlie_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{&mvar_channel_map});
    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{&mvar_channel_map});
    const charlie_thread = try std.Thread.spawn(.{}, charlie.clientFn, .{&mvar_channel_map});
    const selector_thread = try std.Thread.spawn(.{}, selector.clientFn, .{&mvar_channel_map});

    alice_thread.join();
    bob_thread.join();
    charlie_thread.join();
    selector_thread.join();
}

//
const AllRole = enum { selector, alice, bob, charlie };

const AliceContext = struct {
    counter: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const BobContext = struct {
    counter: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const CharlieContext = struct {
    counter: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const SelectorContext = struct {
    times_2pc: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
    selector: type = SelectorContext,
};

pub const EnterFsmState = Random2pc;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

fn PingPong(client: AllRole, server: AllRole, Next: type) type {
    return pingpong.MkPingPong(
        AllRole,
        client,
        server,
        Context{},
        .pingpong_client,
        .pingpong_server,
        Next,
    );
}

fn CAB(Next: type) type {
    return mk2pc(AllRole, .charlie, .alice, .bob, Context{}, Next);
}
fn ABC(Next: type) type {
    return mk2pc(AllRole, .alice, .bob, .charlie, Context{}, Next);
}
fn BAC(Next: type) type {
    return mk2pc(AllRole, .bob, .alice, .charlie, Context{}, Next);
}

//Randomly select a 2pc protocol
pub const Random2pc = union(enum) {
    charlie_as_coordinator: Data(void, PingPong(.charlie, .bob, PingPong(.bob, .alice, CAB(@This()).Start).Start).Start),
    alice_as_coordinator: Data(void, PingPong(.alice, .bob, ABC(@This()).Start).Start),
    bob_as_coordinator: Data(void, PingPong(.bob, .charlie, BAC(@This()).Start).Start),
    exit: Data(void, ps.Exit),

    pub const info: ps.ProtocolInfo(
        "random_2pc",
        AllRole,
        Context{},
        &.{ .selector, .charlie, .alice, .bob },
        &.{},
    ) = .{
        .sender = .selector,
        .receiver = &.{ .charlie, .alice, .bob },
    };

    pub fn process(ctx: *SelectorContext) !@This() {
        ctx.times_2pc += 1;
        std.debug.print("times_2pc: {d}\n", .{ctx.times_2pc});
        if (ctx.times_2pc > 3) {
            return .{ .exit = .{ .data = {} } };
        }

        const random: std.Random = ctx.xoshiro256.random();
        const res = random.intRangeAtMost(u8, 0, 2);
        switch (res) {
            0 => return .{ .charlie_as_coordinator = .{ .data = {} } },
            1 => return .{ .alice_as_coordinator = .{ .data = {} } },
            2 => return .{ .bob_as_coordinator = .{ .data = {} } },
            else => unreachable,
        }
    }
};

pub fn mk2pc(
    Role: type,
    coordinator: Role,
    alice: Role,
    bob: Role,
    context: anytype,
    NextFsmState: type,
) type {
    return struct {
        fn two_pc(sender: Role, receiver: []const Role) ps.ProtocolInfo(
            "2pc_generic",
            Role,
            context,
            &.{ coordinator, alice, bob },
            &.{NextFsmState},
        ) {
            return .{ .sender = sender, .receiver = receiver };
        }

        pub const Start = union(enum) {
            begin: Data(void, AliceResp),

            pub const info = two_pc(coordinator, &.{ alice, bob });

            pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                _ = ctx;
                return .{ .begin = .{ .data = {} } };
            }
        };

        pub const AliceResp = union(enum) {
            resp: Data(bool, BobResp),

            pub const info = two_pc(alice, &.{coordinator});

            pub fn process(ctx: *info.RoleCtx(alice)) !@This() {
                const random: std.Random = ctx.xoshiro256.random();
                const res: bool = random.intRangeAtMost(u32, 0, 100) < 80;
                return .{ .resp = .{ .data = res } };
            }

            pub fn preprocess_0(ctx: *info.RoleCtx(coordinator), msg: @This()) !void {
                switch (msg) {
                    .resp => |val| {
                        if (val.data) ctx.counter += 1;
                    },
                }
            }
        };

        pub const BobResp =
            union(enum) {
                resp: Data(bool, Check),

                pub const info = two_pc(bob, &.{coordinator});

                pub fn process(ctx: *info.RoleCtx(bob)) !@This() {
                    const random: std.Random = ctx.xoshiro256.random();
                    const res: bool = random.intRangeAtMost(u32, 0, 100) < 80;
                    return .{ .resp = .{ .data = res } };
                }

                pub fn preprocess_0(ctx: *info.RoleCtx(coordinator), msg: @This()) !void {
                    switch (msg) {
                        .resp => |val| {
                            if (val.data) ctx.counter += 1;
                        },
                    }
                }
            };

        pub const Check = union(enum) {
            succcessed: Data(void, NextFsmState),
            failed_retry: Data(void, Start),

            pub const info = two_pc(coordinator, &.{ alice, bob });

            pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                if (ctx.counter == 2) {
                    ctx.counter = 0;
                    return .{ .succcessed = .{ .data = {} } };
                }
                ctx.counter = 0;
                return .{ .failed_retry = .{ .data = {} } };
            }
        };
    };
}
