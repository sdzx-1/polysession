const std = @import("std");
const ps = @import("root.zig");
const net = std.net;

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

            var client_context: ClientContext = .{
                .stream_reader = socket.reader(&reader_buf),
                .stream_writer = socket.writer(&writer_buf),
                .server_counter = 0,
                .client_counter = 0,
            };

            Runner.runProtocol(.client, Channel(ClientContext), true, curr_id, &client_context);
        }
    };

    const t = try std.Thread.spawn(.{}, S.clientFn, .{server.listen_address});
    defer t.join();

    //

    var client = try server.accept();
    defer client.stream.close();

    var reader_buf: [16]u8 = undefined;
    var writer_buf: [16]u8 = undefined;

    var server_context: ServerContext = .{
        .stream_reader = client.stream.reader(&reader_buf),
        .stream_writer = client.stream.writer(&writer_buf),
        .server_counter = 0,
        .client_counter = 0,
        .counter = 0,
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{ .server, Channel(ServerContext), true, curr_id, &server_context });
    defer stid.join();
}

//example

pub fn PingPong(Data_: type, State_: type) type {
    return ps.Session("PingPong", Data_, State_);
}

pub const ServerContext = struct {
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,

    server_counter: i32,
    client_counter: i32,

    counter: i32,
};

pub const ClientContext = struct {
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,

    client_counter: i32,
    server_counter: i32,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

// const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, ps.Exit)));
// const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, Idle(.server, PingPong(void, ps.Exit)))));
const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, Idle(.server, PingPong(void, Loop)))));

const Loop = union(enum) {
    back: EnterFsmState,
    exit: PingPong(void, ps.Exit),

    pub const agency: ps.Role = .server;

    pub fn process(ctx: *@field(Context, @tagName(agency))) @This() {
        ctx.counter += 1;
        std.debug.print("counter: {d}\n", .{ctx.counter});
        if (ctx.counter >= 3) return .{ .exit = .{ .data = {} } };
        ctx.client_counter = 0;
        ctx.server_counter = 0;
        return .{ .back = .{ .data = {} } };
    }

    pub fn preprocess(ctx: *@field(Context, @tagName(agency.flip())), msg: @This()) void {
        switch (msg) {
            .exit => {},
            .back => {
                ctx.client_counter = 0;
                ctx.server_counter = 0;
            },
        }
    }

    pub fn decode(comptime tag: std.meta.Tag(@This()), reader: *std.Io.Reader) @This() {
        switch (tag) {
            .back => {
                const PayloadT = std.meta.TagPayload(@This(), tag);
                const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                return .{ .back = payload };
            },

            .exit => {
                const PayloadT = std.meta.TagPayload(@This(), tag);
                const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                return .{ .exit = payload };
            },
        }
    }
};

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);

pub fn Idle(agency_: ps.Role, NextFsmState: type) type {
    return union(enum) {
        ping: PingPong(i32, Busy(agency_.flip(), NextFsmState)),
        next: NextFsmState,

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context, @tagName(agency_))) @This() {
            ctx.client_counter += 1;
            if (ctx.client_counter > 10) {
                return .{ .next = .{ .data = {} } };
            }
            return .{ .ping = .{ .data = ctx.client_counter } };
        }

        pub fn preprocess(ctx: *@field(Context, @tagName(agency_.flip())), msg: @This()) void {
            switch (msg) {
                .next => {},
                .ping => |val| {
                    ctx.server_counter = val.data;
                },
            }
        }

        pub fn decode(comptime tag: std.meta.Tag(@This()), reader: *std.Io.Reader) @This() {
            switch (tag) {
                .ping => {
                    const PayloadT = std.meta.TagPayload(@This(), tag);
                    const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                    return .{ .ping = payload };
                },

                .next => {
                    const PayloadT = std.meta.TagPayload(@This(), tag);
                    const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                    return .{ .next = payload };
                },
            }
        }
    };
}
pub fn Busy(agency_: ps.Role, NextFsmState: type) type {
    return union(enum) {
        pong: PingPong(i32, Idle(agency_.flip(), NextFsmState)),

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context, @tagName(agency_))) @This() {
            ctx.server_counter += 1;
            return .{ .pong = .{ .data = ctx.server_counter } };
        }

        pub fn preprocess(ctx: *@field(Context, @tagName(agency_.flip())), msg: @This()) void {
            switch (msg) {
                .pong => |val| {
                    ctx.client_counter = val.data;
                },
            }
        }

        pub fn decode(comptime tag: std.meta.Tag(@This()), reader: *std.Io.Reader) @This() {
            switch (tag) {
                .pong => {
                    const PayloadT = std.meta.TagPayload(@This(), tag);
                    const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                    return .{ .pong = payload };
                },
            }
        }
    };
}

pub fn Channel(Context_: type) type {
    return struct {
        pub fn send(ctx: *Context_, val: anytype) void {
            const writer = &ctx.stream_writer.interface;
            switch (val) {
                inline else => |msg, tag| {
                    writer.writeByte(@intFromEnum(tag)) catch unreachable;
                    writer.writeStruct(msg, .little) catch unreachable;
                },
            }

            writer.flush() catch unreachable;
        }

        pub fn recv(ctx: *Context_, T: type) T {
            const reader = ctx.stream_reader.interface();
            const recv_tag_num = reader.takeByte() catch unreachable;
            const tag: std.meta.Tag(T) = @enumFromInt(recv_tag_num);
            switch (tag) {
                inline else => |t| {
                    //
                    // const PayloadT = std.meta.TagPayload(T, t);
                    // const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                    // return .{ .(@tagName(t)) = payload };
                    // // There seems to be no such function for tagged union, which allows tags to be specified dynamically at compile time.
                    // // So I had to use the following solution.
                    //
                    return T.decode(t, reader);
                },
            }
        }
    };
}
