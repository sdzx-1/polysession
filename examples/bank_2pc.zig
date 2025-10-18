const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;
const net = std.net;

pub const Runner = ps.Runner(CreatTransaction);
pub const curr_id = Runner.idFromState(CreatTransaction);

const Role = enum { client, coordinator, alice, bob };

const Transaction = struct {
    alice: i32,
    bob: i32,

    pub fn encode(self: *const @This(), writer: *std.Io.Writer) !void {
        try writer.writeInt(i32, self.alice, .little);
        try writer.writeInt(i32, self.bob, .little);
    }
    pub fn decode(reader: *std.Io.Reader) !@This() {
        const alice = try reader.takeInt(i32, .little);
        const bob = try reader.takeInt(i32, .little);
        return .{ .alice = alice, .bob = bob };
    }
};

const ClientContext = struct {
    reader: *std.Io.Reader,
    xoshiro256: std.Random.Xoshiro256,
};

const CoordinatorContext = struct {
    counter: u32,
    transaction: ?Transaction,
};

const AliceContext = struct {
    balance: i32,
    recved_value: i32,
};

const BobContext = struct {
    balance: i32,
    recvd_value: i32,
};

const Context = struct {
    client: type = ClientContext,
    coordinator: type = CoordinatorContext,
    alice: type = AliceContext,
    bob: type = BobContext,
};

fn bank_2pc(sender: Role, receiver: []const Role) ps.ProtocolInfo("bank_2pc", Role, Context{}) {
    return .{ .sender = sender, .receiver = receiver };
}

const CreatTransaction = union(enum) {
    transaction: Data(Transaction, Begin),

    pub const info = bank_2pc(.client, &.{.coordinator});

    pub fn process(ctx: *ClientContext) !@This() {
        std.debug.print(
            \\Press Enter to randomly generate a transaction
            \\
        ,
            .{},
        );
        var buff: [10]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&buff);
        _ = try stdin_reader.interface.takeDelimiter('\n');
        const random = ctx.xoshiro256.random();

        return .{ .transaction = .{ .data = .{
            .alice = random.intRangeAtMost(i32, -30, 30),
            .bob = random.intRangeAtMost(i32, -30, 30),
        } } };
    }

    pub fn preprocess_0(ctx: *CoordinatorContext, msg: @This()) !void {
        switch (msg) {
            .transaction => |val| ctx.transaction = val.data,
        }
    }
};

const Begin = union(enum) {
    begin: Data(Transaction, AliceResp),

    pub const info = bank_2pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *CoordinatorContext) !@This() {
        ctx.counter = 0;
        return .{ .begin = .{ .data = ctx.transaction.? } };
    }

    pub fn preprocess_0(ctx: *AliceContext, msg: @This()) !void {
        switch (msg) {
            .begin => |val| ctx.recved_value = val.data.alice,
        }
    }

    pub fn preprocess_1(ctx: *BobContext, msg: @This()) !void {
        switch (msg) {
            .begin => |val| ctx.recvd_value = val.data.bob,
        }
    }
};

const AliceResp = union(enum) {
    resp: Data(bool, BobResp),

    pub const info = bank_2pc(.alice, &.{.coordinator});

    pub fn process(ctx: *AliceContext) !@This() {
        const res = ctx.balance + ctx.recved_value >= 0;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx.counter += 1;
            },
        }
    }
};

const BobResp = union(enum) {
    resp: Data(bool, Check),

    pub const info = bank_2pc(.bob, &.{.coordinator});

    pub fn process(ctx: *BobContext) !@This() {
        const res = ctx.balance + ctx.recvd_value >= 0;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx.counter += 1;
            },
        }
    }
};

const Check = union(enum) {
    check_result: Data(bool, CreatTransaction),

    pub const info = bank_2pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.coordinator)) !@This() {
        if (ctx.counter == 2) {
            return .{ .check_result = .{ .data = true } };
        }
        return .{ .check_result = .{ .data = false } };
    }

    pub fn preprocess_0(ctx: *AliceContext, msg: @This()) !void {
        switch (msg) {
            .check_result => |val| {
                if (val.data) ctx.balance += ctx.recved_value;
            },
        }
        std.debug.print("alice blance: {d}\n", .{ctx.balance});
    }

    pub fn preprocess_1(ctx: *BobContext, msg: @This()) !void {
        switch (msg) {
            .check_result => |val| {
                if (val.data) ctx.balance += ctx.recvd_value;
            },
        }
        std.debug.print("bob   blance: {d}\n", .{ctx.balance});
    }
};

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

            var alice_context: AliceContext = .{ .balance = 0, .recved_value = 0 };

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

            var bob_context: BobContext = .{ .balance = 0, .recvd_value = 0 };

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

    const client = struct {
        fn clientFn(server_address: net.Address) !void {
            std.Thread.sleep(std.time.ns_per_ms * 200); //Let bob connect first
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [10]u8 = undefined;
            var writer_buf: [10]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var client_context: ClientContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&client_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(
                .client,
                .{
                    .coordinator = StreamChannel{
                        .reader = stream_reader.interface(),
                        .writer = &stream_writer.interface,
                        .log = false,
                    },
                },
                curr_id,
                &client_context,
            );
        }
    };

    const client_thread = try std.Thread.spawn(.{}, client.clientFn, .{server.listen_address});
    defer client_thread.join();

    var alice_client = try server.accept();
    defer alice_client.stream.close();

    var bob_client = try server.accept();
    defer bob_client.stream.close();

    var client_client = try server.accept();
    defer client_client.stream.close();

    var alice_reader_buf: [10]u8 = undefined;
    var alice_writer_buf: [10]u8 = undefined;
    var alice_stream_reader = alice_client.stream.reader(&alice_reader_buf);
    var alice_stream_writer = alice_client.stream.writer(&alice_writer_buf);

    var bob_reader_buf: [10]u8 = undefined;
    var bob_writer_buf: [10]u8 = undefined;
    var bob_stream_reader = bob_client.stream.reader(&bob_reader_buf);
    var bob_stream_writer = bob_client.stream.writer(&bob_writer_buf);

    var client_reader_buf: [10]u8 = undefined;
    var client_writer_buf: [10]u8 = undefined;
    var client_stream_reader = client_client.stream.reader(&client_reader_buf);
    var client_stream_writer = client_client.stream.writer(&client_writer_buf);

    var coordinator_context: CoordinatorContext = .{
        .counter = 0,
        .transaction = .{ .alice = 0, .bob = 0 },
    };

    try Runner.runProtocol(
        .coordinator,
        .{
            .alice = StreamChannel{
                .reader = alice_stream_reader.interface(),
                .writer = &alice_stream_writer.interface,
                .log = true,
                .master = "coordinator",
                .other = "alice ",
            },

            .bob = StreamChannel{
                .reader = bob_stream_reader.interface(),
                .writer = &bob_stream_writer.interface,
                .log = true,
                .master = "coordinator",
                .other = "bob   ",
            },

            .client = StreamChannel{
                .reader = client_stream_reader.interface(),
                .writer = &client_stream_writer.interface,
                .log = true,
                .master = "coordinator",
                .other = "client",
            },
        },
        curr_id,
        &coordinator_context,
    );
}
