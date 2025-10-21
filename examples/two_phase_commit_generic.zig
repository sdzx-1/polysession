const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;
const net = std.net;
const pingpong = @import("pingpong.zig");

const AllRole = enum { alice, bob, charlie };

const AliceContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
    pingpong: pingpong.ClientContext,
};

const BobContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
    pingpong: pingpong.ServerContext,
};

const CharlieContext = struct {
    counter: u32,
    xoshiro256: std.Random.Xoshiro256,
    times_2pc: u32,
    pingpong: pingpong.ClientContext,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
};

pub const EnterFsmState = Random2pc;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

fn PingPong(client: AllRole, server: AllRole, Next: type) type {
    return pingpong.MkPingPong(AllRole, client, server, Context{}, .pingpong, .pingpong, Next);
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
    charlie_as_coordinator: Data(void, PingPong(.alice, .bob, PingPong(.charlie, .bob, CAB(@This()).Start).Start).Start),
    alice_as_coordinator: Data(void, PingPong(.alice, .bob, ABC(@This()).Start).Start),
    bob_as_coordinator: Data(void, PingPong(.charlie, .bob, BAC(@This()).Start).Start),
    exit: Data(void, ps.Exit),

    pub const info: ps.ProtocolInfo("random_2pc", AllRole, Context{}, &.{ .charlie, .alice, .bob }, &.{}) = .{
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
};

//
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

pub fn main() !void {
    var xorshiro256: std.Random.Xoshiro256 = undefined;
    const ptr: *[4 * 64]u8 = @ptrCast(&xorshiro256.s);
    std.crypto.random.bytes(ptr);
    const random = xorshiro256.random();

    const start_address = random.intRangeAtMost(u16, 10000, (1 << 15) - 2);

    const alice_bob_address = try net.Address.parseIp(
        "127.0.0.1",
        start_address,
    );

    const bob_charlie_address = try net.Address.parseIp(
        "127.0.0.1",
        start_address + 1,
    );

    const charlie_alice_address = try net.Address.parseIp(
        "127.0.0.1",
        start_address + 2,
    );

    // waiting for connection: (bob, charlie)
    // connection:             alice -> bob
    // waiting for connection: (alice, charlie)
    // connection:             bob -> charlie
    // waiting for connection: (alice)
    // connection:             charlie -> alice

    const alice = struct {
        fn clientFn(
            alice_bob_addr: net.Address,
            charlie_alice_addr: net.Address,
        ) !void {
            const alice_bob_stream = try net.tcpConnectToAddress(alice_bob_addr);
            defer alice_bob_stream.close();

            var charlie_alice_server = try charlie_alice_addr.listen(.{});
            defer charlie_alice_server.deinit();

            const charlie_alice_stream = (try charlie_alice_server.accept()).stream;
            defer charlie_alice_stream.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;
            var stream_reader = charlie_alice_stream.reader(&reader_buf);
            var stream_writer = charlie_alice_stream.writer(&writer_buf);

            var bob_reader_buf: [10]u8 = undefined;
            var bob_writer_buf: [10]u8 = undefined;
            var bob_stream_reader = alice_bob_stream.reader(&bob_reader_buf);
            var bob_stream_writer = alice_bob_stream.writer(&bob_writer_buf);

            var alice_context: AliceContext = undefined;
            alice_context.counter = 0;
            alice_context.pingpong.client_counter = 0;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

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
                    },
                },
                curr_id,
                &alice_context,
            );
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{ alice_bob_address, charlie_alice_address });
    defer alice_thread.join();

    const bob = struct {
        fn clientFn(
            alice_bob_addr: net.Address,
            bob_charlie_addr: net.Address,
        ) !void {
            var alice_bob_server = try alice_bob_addr.listen(.{});
            defer alice_bob_server.deinit();

            const alice_bob_stream = (try alice_bob_server.accept()).stream;
            defer alice_bob_stream.close();

            const bob_charlie_stream = try net.tcpConnectToAddress(bob_charlie_addr);
            defer bob_charlie_stream.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;
            var stream_reader = bob_charlie_stream.reader(&reader_buf);
            var stream_writer = bob_charlie_stream.writer(&writer_buf);

            var alice_reader_buf: [10]u8 = undefined;
            var alice_writer_buf: [10]u8 = undefined;
            var alice_stream_reader = alice_bob_stream.reader(&alice_reader_buf);
            var alice_stream_writer = alice_bob_stream.writer(&alice_writer_buf);

            var bob_context: BobContext = undefined;
            bob_context.counter = 0;
            bob_context.pingpong.server_counter = 0;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

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
                    },
                },
                curr_id,
                &bob_context,
            );
        }
    };

    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{ alice_bob_address, bob_charlie_address });
    defer bob_thread.join();

    var bob_charlie_server = try bob_charlie_address.listen(.{});
    defer bob_charlie_server.deinit();

    const bob_charlie_stream = (try bob_charlie_server.accept()).stream;
    defer bob_charlie_stream.close();

    const charlie_alice_stream = try net.tcpConnectToAddress(charlie_alice_address);
    defer charlie_alice_stream.close();

    var alice_reader_buf: [10]u8 = undefined;
    var alice_writer_buf: [10]u8 = undefined;
    var alice_stream_reader = charlie_alice_stream.reader(&alice_reader_buf);
    var alice_stream_writer = charlie_alice_stream.writer(&alice_writer_buf);

    var bob_reader_buf: [10]u8 = undefined;
    var bob_writer_buf: [10]u8 = undefined;
    var bob_stream_reader = bob_charlie_stream.reader(&bob_reader_buf);
    var bob_stream_writer = bob_charlie_stream.writer(&bob_writer_buf);

    var charlie_context: CharlieContext = undefined;
    charlie_context.counter = 0;
    charlie_context.times_2pc = 0;
    charlie_context.pingpong.client_counter = 0;
    const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
    std.crypto.random.bytes(fill_ptr);

    try Runner.runProtocol(
        .charlie,
        .{
            .alice = StreamChannel{
                .reader = alice_stream_reader.interface(),
                .writer = &alice_stream_writer.interface,
                .log = true,
                .master = "charlie",
                .other = "alice",
            },

            .bob = StreamChannel{
                .reader = bob_stream_reader.interface(),
                .writer = &bob_stream_writer.interface,
                .log = true,
                .master = "charlie",
                .other = "bob  ",
            },
        },
        curr_id,
        &charlie_context,
    );
}
