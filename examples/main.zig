const std = @import("std");
const ps = @import("polysession");
const net = std.net;
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;

pub fn main() !void {

    //Server
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    var server = try localhost.listen(.{});
    defer server.deinit();
    //

    const S = struct {
        fn clientFn(server_address: net.Address) !void {
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [16]u8 = undefined;
            var writer_buf: [16]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var client_context: ClientContext = .{
                .client_counter = 0,
            };

            try Runner.runProtocol(
                .client,
                StreamChannel{
                    .reader = stream_reader.interface(),
                    .writer = &stream_writer.interface,
                    .log = false,
                },
                curr_id,
                &client_context,
            );
        }
    };

    const t = try std.Thread.spawn(.{}, S.clientFn, .{server.listen_address});
    defer t.join();

    //

    var client = try server.accept();
    defer client.stream.close();

    var reader_buf: [16]u8 = undefined;
    var writer_buf: [16]u8 = undefined;

    var stream_reader = client.stream.reader(&reader_buf);
    var stream_writer = client.stream.writer(&writer_buf);

    var server_context: ServerContext = .{
        .server_counter = 0,
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        .server,
        StreamChannel{
            .reader = stream_reader.interface(),
            .writer = &stream_writer.interface,
            .log = true,
        },
        curr_id,
        &server_context,
    });

    defer stid.join();
}

//example PingPong

pub fn PingPong(Data_: type, State_: type) type {
    return ps.Session("PingPong", Data_, State_);
}

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

const PongFn = struct {
    pub fn process(ctx: *ServerContext) !i32 {
        ctx.server_counter += 1;
        return ctx.server_counter;
    }

    pub fn preprocess(ctx: *ClientContext, val: i32) !void {
        ctx.client_counter = val;
    }
};

pub fn Start(NextFsmState: type) type {
    return union(enum) {
        ping: PingPong(i32, ps.Cast("pong", .server, PongFn, PingPong(i32, @This()))),
        next: NextFsmState,

        pub const agency: ps.Role = .client;

        pub fn process(ctx: *ClientContext) !@This() {
            if (ctx.client_counter >= 10) {
                ctx.client_counter = 0;
                return .{ .next = .{ .data = {} } };
            }
            return .{ .ping = .{ .data = ctx.client_counter } };
        }

        pub fn preprocess(ctx: *ServerContext, msg: @This()) !void {
            switch (msg) {
                .ping => |val| ctx.server_counter = val.data,
                .next => {
                    ctx.server_counter = 0;
                },
            }
        }
    };
}

const EnterFsmState = PingPong(void, Start(PingPong(void, ps.Exit)));
// const EnterFsmState = PingPong(void, Start(PingPong(void, Start(PingPong(void, ps.Exit)))));

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);
