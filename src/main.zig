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
                    const PayloadT = std.meta.TagPayload(T, t);
                    const payload = reader.takeStruct(PayloadT, .little) catch unreachable;
                    return @unionInit(T, @tagName(t), payload);
                },
            }
        }
    };
}

pub fn Cast(
    Protocol: fn (type, type) type,
    Val: type,
    NextState: type,
    agency_: ps.Role,
    Context_: ps.ClientAndServerContext,
    process_fun: fn (*@field(Context_, @tagName(agency_))) Val,
    preprocess_fun: fn (*@field(Context_, @tagName(agency_.flip())), Val) void,
) type {
    return union(enum) {
        cast: Protocol(Val, NextState),

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context_, @tagName(agency_))) @This() {
            return .{ .cast = .{ .data = process_fun(ctx) } };
        }

        pub fn preprocess(ctx: *@field(Context_, @tagName(agency_.flip())), msg: @This()) void {
            switch (msg) {
                .cast => |val| preprocess_fun(ctx, val.data),
            }
        }
    };
}

pub fn IF(
    Protocol: fn (type, type) type,
    agency_: ps.Role,
    Context_: ps.ClientAndServerContext,
    fun: fn (*@field(Context_, @tagName(agency_))) bool,
    Yes: type,
    No: type,
) type {
    return union(enum) {
        yes: Protocol(void, Yes),
        no: Protocol(void, No),

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context, @tagName(agency_))) @This() {
            if (fun(ctx)) {
                return .{ .yes = .{ .data = {} } };
            } else {
                return .{ .no = .{ .data = {} } };
            }
        }

        pub fn preprocess(ctx: *@field(Context, @tagName(agency_.flip())), msg: @This()) void {
            _ = ctx;
            _ = msg;
        }
    };
}

//
fn foo(ctx: *ClientContext) i32 {
    ctx.client_counter += 1;
    return ctx.client_counter;
}

fn bar(ctx: *ServerContext, val: i32) void {
    ctx.server_counter = val;
}

fn foo1(ctx: *ServerContext) i32 {
    ctx.server_counter += 1;
    return ctx.server_counter;
}

fn bar1(ctx: *ClientContext, val: i32) void {
    ctx.client_counter = val;
}

fn check(ctx: *ClientContext) bool {
    return ctx.client_counter < 10;
}

fn C2S(Next: type) type {
    return Cast(PingPong, i32, Next, .client, Context, foo, bar);
}

fn S2C(Next: type) type {
    return Cast(PingPong, i32, Next, .server, Context, foo1, bar1);
}

const P1 = PingPong(void, IF(PingPong, .client, Context, check, C2S(S2C(Loop1)), ps.Exit));

const Loop1 = union(enum) {
    back: P1,

    pub const agency: ps.Role = .server;

    pub fn process(ctx: *@field(Context, @tagName(agency))) @This() {
        _ = ctx;
        return .{ .back = .{ .data = {} } };
    }

    pub fn preprocess(ctx: *@field(Context, @tagName(agency.flip())), msg: @This()) void {
        _ = msg;
        _ = ctx;
    }
};
// PingPong new impl
//

const St1 = union(enum) {
    ping: PingPong(i32, S2C(@This())),
    exit: PingPong(void, ps.Exit),

    pub const agency: ps.Role = .client;

    pub fn process(ctx: *@field(Context, @tagName(agency))) @This() {
        if (!check(ctx)) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = foo(ctx) } };
    }

    pub fn preprocess(ctx: *@field(Context, @tagName(agency.flip())), msg: @This()) void {
        switch (msg) {
            .ping => |val| bar(ctx, val.data),
            .exit => {},
        }
    }
};

const P2 = PingPong(void, St1);

const EnterFsmState = P2;

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);

// const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, ps.Exit)));
// const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, Idle(.server, PingPong(void, ps.Exit)))));
// const EnterFsmState = PingPong(void, Idle(.client, PingPong(void, Idle(.server, PingPong(void, Loop)))));

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
};

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
    };
}
