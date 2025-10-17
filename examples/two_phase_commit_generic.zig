const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;
const net = std.net;

pub fn main() !void {
    var xorshiro256: std.Random.Xoshiro256 = undefined;
    const ptr: *[4 * 64]u8 = @ptrCast(&xorshiro256.s);
    std.crypto.random.bytes(ptr);
    const random = xorshiro256.random();

    const localhost0 = try net.Address.parseIp(
        "127.0.0.1",
        random.intRangeAtMost(u16, 10000, 1 << 15),
    );

    const localhost1 = try net.Address.parseIp(
        "127.0.0.1",
        random.intRangeAtMost(u16, 10000, 1 << 15),
    );

    const alice = struct {
        fn clientFn(addr0: net.Address, addr1: net.Address) !void {
            const socket = try net.tcpConnectToAddress(addr0);
            defer socket.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var alice_context: AliceContext = undefined;
            alice_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            //
            var alice_server = try addr1.listen(.{});
            defer alice_server.deinit();

            var bob_client = try alice_server.accept();
            defer bob_client.stream.close();

            var bob_reader_buf: [10]u8 = undefined;
            var bob_writer_buf: [10]u8 = undefined;

            var bob_stream_reader = bob_client.stream.reader(&bob_reader_buf);
            var bob_stream_writer = bob_client.stream.writer(&bob_writer_buf);

            try Runner.runProtocol(
                .alice,
                .{
                    .charlie = StreamChannel{
                        .reader = stream_reader.interface(),
                        .writer = &stream_writer.interface,
                        .log = false,
                    },

                    .bob = StreamChannel{
                        .reader = bob_stream_reader.interface(),
                        .writer = &bob_stream_writer.interface,
                        .log = false,
                        .perfix = "bob  ",
                    },
                },
                curr_id,
                &alice_context,
            );
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{ localhost0, localhost1 });
    defer alice_thread.join();

    const bob = struct {
        fn clientFn(addr0: net.Address, addr1: net.Address) !void {
            std.Thread.sleep(std.time.ns_per_ms * 100); //Let alice connect first
            const socket = try net.tcpConnectToAddress(addr0);
            defer socket.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var bob_context: BobContext = undefined;
            bob_context.counter = 0;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            //

            const alice_client = try net.tcpConnectToAddress(addr1);
            defer alice_client.close();

            var alice_reader_buf: [10]u8 = undefined;
            var alice_writer_buf: [10]u8 = undefined;
            var alice_stream_reader = alice_client.reader(&alice_reader_buf);
            var alice_stream_writer = alice_client.writer(&alice_writer_buf);

            try Runner.runProtocol(
                .bob,
                .{
                    .charlie = StreamChannel{
                        .reader = stream_reader.interface(),
                        .writer = &stream_writer.interface,
                        .log = false,
                    },

                    .alice = StreamChannel{
                        .reader = alice_stream_reader.interface(),
                        .writer = &alice_stream_writer.interface,
                        .log = false,
                        .perfix = "alice",
                    },
                },
                curr_id,
                &bob_context,
            );
        }
    };

    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{ localhost0, localhost1 });
    defer bob_thread.join();

    //
    var server = try localhost0.listen(.{});
    defer server.deinit();

    var alice_client = try server.accept();
    defer alice_client.stream.close();

    var bob_client = try server.accept();
    defer bob_client.stream.close();

    var alice_reader_buf: [10]u8 = undefined;
    var alice_writer_buf: [10]u8 = undefined;
    var alice_stream_reader = alice_client.stream.reader(&alice_reader_buf);
    var alice_stream_writer = alice_client.stream.writer(&alice_writer_buf);

    var bob_reader_buf: [10]u8 = undefined;
    var bob_writer_buf: [10]u8 = undefined;
    var bob_stream_reader = bob_client.stream.reader(&bob_reader_buf);
    var bob_stream_writer = bob_client.stream.writer(&bob_writer_buf);

    var charlie_context: CharlieContext = undefined;
    charlie_context.counter = 0;
    charlie_context.times_2pc = 0;
    const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
    std.crypto.random.bytes(fill_ptr);

    try Runner.runProtocol(
        .charlie,
        .{
            .alice = StreamChannel{
                .reader = alice_stream_reader.interface(),
                .writer = &alice_stream_writer.interface,
                .log = true,
                .perfix = "alice",
            },

            .bob = StreamChannel{
                .reader = bob_stream_reader.interface(),
                .writer = &bob_stream_writer.interface,
                .log = true,
                .perfix = "bob  ",
            },
        },
        curr_id,
        &charlie_context,
    );
}

const AllRole = enum { alice, bob, charlie };

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
    times_2pc: u32,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
};

// pub const EnterFsmState = CAB.Start(ABC.Start(BAC.Start(ps.Exit)));
pub const EnterFsmState = Random2pc;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const CAB = mk2pc(AllRole, .charlie, .alice, .bob, Context{});
const ABC = mk2pc(AllRole, .alice, .bob, .charlie, Context{});
const BAC = mk2pc(AllRole, .bob, .alice, .charlie, Context{});

//Randomly select a 2pc protocol
pub const Random2pc = union(enum) {
    charlie_as_coordinator: Data(void, CAB.Start(@This())),
    alice_as_coordinator: Data(void, ABC.Start(@This())),
    bob_as_coordinator: Data(void, BAC.Start(@This())),
    exit: Data(void, ps.Exit),

    pub const info: ps.ProtocolInfo("random_2pc", AllRole, Context{}) = .{
        .sender = .charlie,
        .receiver = &.{ .alice, .bob },
    };

    pub fn process(ctx: *CharlieContext) !@This() {
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

    pub fn preprocess_0(ctx: *AliceContext, msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }

    pub fn preprocess_1(ctx: *BobContext, msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }
};

//
pub fn mk2pc(
    Role: type,
    coordinator: Role,
    alice: Role,
    bob: Role,
    context: anytype,
) type {
    return struct {
        fn two_pc(sender: Role, receiver: []const Role) ps.ProtocolInfo("2pc_generic", Role, context) {
            return .{ .sender = sender, .receiver = receiver };
        }

        pub fn Start(NextFsmState: type) type {
            return union(enum) {
                begin: Data(void, AliceResp(NextFsmState)),

                pub const info = two_pc(coordinator, &.{ alice, bob });

                pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                    _ = ctx;
                    return .{ .begin = .{ .data = {} } };
                }

                pub fn preprocess_0(ctx: *info.RoleCtx(alice), msg: @This()) !void {
                    _ = ctx;
                    _ = msg;
                }

                pub fn preprocess_1(ctx: *info.RoleCtx(bob), msg: @This()) !void {
                    _ = ctx;
                    _ = msg;
                }
            };
        }

        pub fn AliceResp(NextFsmState: type) type {
            return union(enum) {
                resp: Data(bool, BobResp(NextFsmState)),

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
        }
        pub fn BobResp(NextFsmState: type) type {
            return union(enum) {
                resp: Data(bool, Check(NextFsmState)),

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
        }

        pub fn Check(NextFsmState: type) type {
            return union(enum) {
                succcessed: Data(void, NextFsmState),
                failed_retry: Data(void, Start(NextFsmState)),

                pub const info = two_pc(coordinator, &.{ alice, bob });

                pub fn process(ctx: *info.RoleCtx(coordinator)) !@This() {
                    if (ctx.counter == 2) {
                        ctx.counter = 0;
                        return .{ .succcessed = .{ .data = {} } };
                    }
                    ctx.counter = 0;
                    return .{ .failed_retry = .{ .data = {} } };
                }

                pub fn preprocess_0(ctx: *info.RoleCtx(alice), msg: @This()) !void {
                    _ = ctx;
                    _ = msg;
                }

                pub fn preprocess_1(ctx: *info.RoleCtx(bob), msg: @This()) !void {
                    _ = ctx;
                    _ = msg;
                }
            };
        }
    };
}
