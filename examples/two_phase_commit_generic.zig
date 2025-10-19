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
};
const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
    selector: type = SelectorContext,
};

// pub const EnterFsmState = CAB.Start(ABC.Start(BAC.Start(ps.Exit)));
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
        std.debug.print("times_2pc: {d}\n", .{ctx.times_2pc});
        if (ctx.times_2pc > 10) {
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

    var mvar_selector: Mvar = .{ .buff = try gpa.alloc(u8, 10) };
    var mvar_alice: Mvar = .{ .buff = try gpa.alloc(u8, 10) };
    var mvar_bob: Mvar = .{ .buff = try gpa.alloc(u8, 10) };
    var mvar_charlie: Mvar = .{ .buff = try gpa.alloc(u8, 10) };

    const AllMvars = struct { selector: *Mvar, alice: *Mvar, bob: *Mvar, charlie: *Mvar };

    const all_mvars: AllMvars = .{
        .selector = &mvar_selector,
        .alice = &mvar_alice,
        .bob = &mvar_bob,
        .charlie = &mvar_charlie,
    };

    const alice = struct {
        fn clientFn(all_mvars_: AllMvars) !void {
            var alice_context: AliceContext = undefined;
            alice_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .alice,
                .{
                    // zig fmt: off
                    .selector = MvarChannel{ .mvar_a = all_mvars_.alice, .mvar_b = all_mvars_.selector },
                    .alice    = MvarChannel{ .mvar_a = all_mvars_.alice, .mvar_b = all_mvars_.alice },
                    .bob      = MvarChannel{ .mvar_a = all_mvars_.alice, .mvar_b = all_mvars_.bob },
                    .charlie  = MvarChannel{ .mvar_a = all_mvars_.alice, .mvar_b = all_mvars_.charlie },
                    // zig fmt: on
                },
                curr_id,
                &alice_context,
            );
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{all_mvars});
    defer alice_thread.join();

    const bob = struct {
        fn clientFn(all_mvars_: AllMvars) !void {
            var bob_context: BobContext = undefined;
            bob_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .bob,
                .{

                    // zig fmt: off
                    .selector = MvarChannel{ .mvar_a = all_mvars_.bob, .mvar_b = all_mvars_.selector },
                    .alice    = MvarChannel{ .mvar_a = all_mvars_.bob, .mvar_b = all_mvars_.alice },
                    .bob      = MvarChannel{ .mvar_a = all_mvars_.bob, .mvar_b = all_mvars_.bob },
                    .charlie  = MvarChannel{ .mvar_a = all_mvars_.bob, .mvar_b = all_mvars_.charlie },
                    // zig fmt: on
                },
                curr_id,
                &bob_context,
            );
        }
    };

    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{all_mvars});
    defer bob_thread.join();

    const selector = struct {
        fn clientFn(all_mvars_: AllMvars) !void {
            var selector_context: SelectorContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&selector_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);
            selector_context.times_2pc = 0;

            try Runner.runProtocol(
                .selector,
                .{
                    .selector = MvarChannel{
                        .mvar_a = all_mvars_.selector,
                        .mvar_b = all_mvars_.selector,
                        .master = "selector",
                        .other = "selector",
                        .log = false,
                    },
                    .alice = MvarChannel{
                        .mvar_a = all_mvars_.selector,
                        .mvar_b = all_mvars_.alice,
                        .log = false,
                        .master = "selector",
                        .other = "alice",
                    },
                    .bob = MvarChannel{
                        .mvar_a = all_mvars_.selector,
                        .mvar_b = all_mvars_.bob,
                        .master = "selector",
                        .other = "bob",
                        .log = false,
                    },
                    .charlie = MvarChannel{
                        .mvar_a = all_mvars_.selector,
                        .mvar_b = all_mvars_.charlie,
                        .master = "selector",
                        .other = "charlie",
                        .log = false,
                    },
                },
                curr_id,
                &selector_context,
            );
        }
    };

    const selector_thread = try std.Thread.spawn(.{}, selector.clientFn, .{all_mvars});
    defer selector_thread.join();

    var charlie_context: CharlieContext = undefined;
    charlie_context.counter = 0;
    const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
    std.crypto.random.bytes(fill_ptr);

    try Runner.runProtocol(
        .charlie,
        .{
            .selector = MvarChannel{
                .mvar_a = all_mvars.charlie,
                .mvar_b = all_mvars.selector,
                .master = "charlie",
                .other = "selector",
                .log = true,
            },
            .alice = MvarChannel{
                .mvar_a = all_mvars.charlie,
                .mvar_b = all_mvars.alice,
                .log = true,
                .master = "charlie",
                .other = "alice",
            },
            .bob = MvarChannel{
                .mvar_a = all_mvars.charlie,
                .mvar_b = all_mvars.bob,
                .master = "charlie",
                .other = "bob",
                .log = true,
            },
            .charlie = MvarChannel{
                .mvar_a = all_mvars.charlie,
                .mvar_b = all_mvars.charlie,
                .master = "charlie",
                .other = "charlie",
                .log = true,
            },
        },
        curr_id,
        &charlie_context,
    );
}
