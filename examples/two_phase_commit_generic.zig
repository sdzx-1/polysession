const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;
const net = std.net;
const Mvar = channel.Mvar;
const MvarChannel = channel.MvarChannel;

const AllRole = enum { selector, alice, bob, charlie };

const AliceContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
};

const BobContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
};

const CharlieContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
};

const SelectorContext = struct {
    xoshiro256: std.Random.Xoshiro256,
    times_2pc: u32,
    counter_arr: [3]u32,
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

//Randomly select a 2pc protocol
pub const Random2pc = union(enum) {
    // zig fmt: off
    charlie_as_coordinator: Data(void, mk2pc(AllRole, .charlie, .alice, .bob, Context{}, &.{.selector}, @This()).Start),
    alice_as_coordinator  : Data(void, mk2pc(AllRole, .alice, .bob, .charlie, Context{}, &.{.selector}, @This()).Start),
    bob_as_coordinator    : Data(void, mk2pc(AllRole, .bob, .alice, .charlie, Context{}, &.{.selector}, @This()).Start),
    exit: Data(void, ps.Exit),
    // zig fmt: on

    pub const info: ps.ProtocolInfo("random_2pc", AllRole, Context{}) = .{
        .sender = .selector,
        .receiver = &.{ .charlie, .alice, .bob },
    };

    pub fn process(ctx: *SelectorContext) !@This() {
        ctx.times_2pc += 1;
        std.debug.print(
            "times_2pc: {d}, charlie {d}, alice {d}, bob {d}\n",
            .{
                ctx.times_2pc,
                ctx.counter_arr[0],
                ctx.counter_arr[1],
                ctx.counter_arr[2],
            },
        );

        if (ctx.times_2pc >= 10) {
            return .{ .exit = .{ .data = {} } };
        }

        const random: std.Random = ctx.xoshiro256.random();
        const res = random.intRangeAtMost(u8, 0, 2);
        ctx.counter_arr[@as(usize, @intCast(res))] += 1;
        switch (res) {
            0 => return .{ .charlie_as_coordinator = .{ .data = {} } },
            1 => return .{ .alice_as_coordinator = .{ .data = {} } },
            2 => return .{ .bob_as_coordinator = .{ .data = {} } },
            else => unreachable,
        }
    }
};

//
pub fn mk2pc(
    Role: type,
    coordinator: Role,
    alice: Role,
    bob: Role,
    context: anytype,
    others: []const Role,
    NextFsmState: type,
) type {
    return struct {
        fn two_pc(sender: Role, receiver: []const Role) ps.ProtocolInfo("2pc_generic", Role, context) {
            return .{
                .sender = sender,
                .receiver = receiver,
                .other_roles = others,
                .terminal_FsmState = NotifyOther,
            };
        }
        pub const NotifyOther = union(enum) {
            notify: Data(void, NextFsmState),

            pub const info = two_pc(coordinator, others);

            pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                _ = ctx;
                return .{ .notify = .{ .data = {} } };
            }
        };

        pub const Start = union(enum) {
            begin: Data(void, AliceResp),

            pub const info = two_pc(coordinator, &.{ alice, bob });

            pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                ctx.counter = 0;
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

        pub const BobResp = union(enum) {
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

        pub const Check =
            union(enum) {
                succcessed: Data(void, NotifyOther),
                failed_retry: Data(void, Start),

                pub const info = two_pc(coordinator, &.{ alice, bob });

                pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                    if (ctx.counter == 2) {
                        return .{ .succcessed = .{ .data = {} } };
                    }
                    return .{ .failed_retry = .{ .data = {} } };
                }
            };
    };
}

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    const selector_alice: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "selector",
        .other = "alice",
    };
    const selector_bob: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "selector",
        .other = "bob",
    };
    const selector_charlie: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "selector",
        .other = "charlie",
    };
    const charlie_alice: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "charlie",
        .other = "alice",
    };
    const charlie_bob: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "charlie",
        .other = "bob",
    };
    const bob_alice: MvarChannel = .{
        .mvar_a = try Mvar.init(gpa, 10),
        .mvar_b = try Mvar.init(gpa, 10),
        .master = "bob",
        .other = "alice",
    };

    const AllChannel = struct {
        selector_alice: MvarChannel,
        selector_bob: MvarChannel,
        selector_charlie: MvarChannel,
        charlie_alice: MvarChannel,
        charlie_bob: MvarChannel,
        bob_alice: MvarChannel,
    };

    const all_channel: AllChannel = .{
        .selector_alice = selector_alice,
        .selector_bob = selector_bob,
        .selector_charlie = selector_charlie,
        .charlie_alice = charlie_alice,
        .charlie_bob = charlie_bob,
        .bob_alice = bob_alice,
    };

    const alice = struct {
        fn clientFn(all_channel_: AllChannel) !void {
            var alice_context: AliceContext = undefined;
            alice_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .alice,
                .{
                    .selector = all_channel_.selector_alice.flip(),
                    .bob = all_channel_.bob_alice.flip(),
                    .charlie = all_channel_.charlie_alice.flip(),
                },
                curr_id,
                &alice_context,
            );
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{all_channel});
    defer alice_thread.join();

    const bob = struct {
        fn clientFn(all_channel_: AllChannel) !void {
            var bob_context: BobContext = undefined;
            bob_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .bob,
                .{
                    .selector = all_channel_.selector_bob.flip(),
                    .alice = all_channel_.bob_alice,
                    .charlie = all_channel_.charlie_bob.flip(),
                },
                curr_id,
                &bob_context,
            );
        }
    };

    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{all_channel});
    defer bob_thread.join();

    const selector = struct {
        fn clientFn(all_channel_: AllChannel) !void {
            var selector_context: SelectorContext = undefined;
            selector_context.counter_arr = @splat(0);
            const fill_ptr: []u8 = @ptrCast(&selector_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);
            selector_context.times_2pc = 0;

            try Runner.runProtocol(
                .selector,
                .{
                    .alice = all_channel_.selector_alice,
                    .bob = all_channel_.selector_bob,
                    .charlie = all_channel_.selector_charlie,
                },
                curr_id,
                &selector_context,
            );
        }
    };

    const selector_thread = try std.Thread.spawn(.{}, selector.clientFn, .{all_channel});
    defer selector_thread.join();

    var charlie_context: CharlieContext = undefined;
    charlie_context.counter = 0;
    const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
    std.crypto.random.bytes(fill_ptr);

    try Runner.runProtocol(
        .charlie,
        .{
            .selector = all_channel.selector_charlie.flip().enable_log(),
            .alice = all_channel.charlie_alice.enable_log(),
            .bob = all_channel.charlie_bob.enable_log(),
        },
        curr_id,
        &charlie_context,
    );
}
