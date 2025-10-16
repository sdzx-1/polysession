const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;
const net = std.net;

pub fn main() !void {

    //coordinator
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    var server = try localhost.listen(.{});
    defer server.deinit();

    const alice = struct {
        fn clientFn(server_address: net.Address) !void {
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var alice_context: AliceContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .alice,
                .{
                    .coordinator = StreamChannel{
                        .reader = stream_reader.interface(),
                        .writer = &stream_writer.interface,
                        .log = false,
                    },
                },
                curr_id,
                &alice_context,
            );
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.clientFn, .{server.listen_address});
    defer alice_thread.join();

    const bob = struct {
        fn clientFn(server_address: net.Address) !void {
            std.Thread.sleep(std.time.ns_per_ms * 100); //Let alice connect first
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var bob_context: BobContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .bob,
                .{
                    .coordinator = StreamChannel{
                        .reader = stream_reader.interface(),
                        .writer = &stream_writer.interface,
                        .log = false,
                    },
                },
                curr_id,
                &bob_context,
            );
        }
    };

    const bob_thread = try std.Thread.spawn(.{}, bob.clientFn, .{server.listen_address});
    defer bob_thread.join();

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

    var coordinator_context: u32 = 0;

    try Runner.runProtocol(
        .coordinator,
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
        &coordinator_context,
    );
}

pub const Runner = ps.Runner(Start);
pub const curr_id = Runner.idFromState(Start);

//
const Role = enum { coordinator, alice, bob };

const AliceContext = struct { xoshiro256: std.Random.Xoshiro256 };

const BobContext = struct { xoshiro256: std.Random.Xoshiro256 };

const Context = struct {
    coordinator: type = u32,
    alice: type = AliceContext,
    bob: type = BobContext,
};

fn two_pc(sender: Role, receiver: []const Role) ps.ProtocolInfo("2pc", Role, Context{}) {
    return .{ .sender = sender, .receiver = receiver };
}

const Start = union(enum) {
    begin: Data(void, AliceResp),

    pub const info = two_pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.coordinator)) !@This() {
        _ = ctx;
        return .{ .begin = .{ .data = {} } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.alice), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }

    pub fn preprocess_1(ctx: *info.RoleCtx(.bob), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }
};

const AliceResp = union(enum) {
    resp: Data(bool, BobResp),

    pub const info = two_pc(.alice, &.{.coordinator});

    pub fn process(ctx: *info.RoleCtx(.alice)) !@This() {
        const random: std.Random = ctx.xoshiro256.random();
        const res: bool = random.intRangeAtMost(u32, 0, 100) < 50;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx.* += 1;
            },
        }
    }
};

const BobResp = union(enum) {
    resp: Data(bool, Check),

    pub const info = two_pc(.bob, &.{.coordinator});

    pub fn process(ctx: *info.RoleCtx(.bob)) !@This() {
        const random: std.Random = ctx.xoshiro256.random();
        const res: bool = random.intRangeAtMost(u32, 0, 100) < 50;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx.* += 1;
            },
        }
    }
};

const Check = union(enum) {
    succcessed: Data(void, ps.Exit),
    failed_retry: Data(void, Start),

    pub const info = two_pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.coordinator)) !@This() {
        if (ctx.* == 2) {
            return .{ .succcessed = .{ .data = {} } };
        }
        ctx.* = 0;
        return .{ .failed_retry = .{ .data = {} } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.alice), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }

    pub fn preprocess_1(ctx: *info.RoleCtx(.bob), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }
};
