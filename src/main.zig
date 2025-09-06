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
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{ .server, Channel(ServerContext), true, curr_id, &server_context });
    defer stid.join();
}

pub fn Channel(Context_: type) type {
    return struct {
        pub fn send(ctx: *Context_, val: anytype) void {
            const writer = &ctx.stream_writer.interface;
            switch (val) {
                inline else => |msg, tag| {
                    writer.writeByte(@intFromEnum(tag)) catch unreachable;
                    const data = msg.data;
                    switch (@typeInfo(@TypeOf(data))) {
                        .void => {},
                        .int => {
                            writer.writeInt(@TypeOf(data), data, .little) catch unreachable;
                        },
                        .@"struct" => {
                            data.encode(writer) catch unreachable;
                        },
                        else => @compileError("Not impl!"),
                    }
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
                    const Data = @FieldType(std.meta.TagPayload(T, t), "data");
                    switch (@typeInfo(Data)) {
                        .void => {
                            return @unionInit(T, @tagName(t), .{ .data = {} });
                        },
                        .int => {
                            const data = reader.takeInt(Data, .little) catch unreachable;
                            return @unionInit(T, @tagName(t), .{ .data = data });
                        },
                        .@"struct" => {
                            const data = Data.decode(reader) catch unreachable;
                            return @unionInit(T, @tagName(t), .{ .data = data });
                        },
                        else => @compileError("Not impl!"),
                    }
                },
            }
        }
    };
}

//example PingPong

pub fn PingPong(Data_: type, State_: type) type {
    return ps.Session("PingPong", Data_, State_);
}

pub const ServerContext = struct {
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,

    server_counter: i32,
};

pub const ClientContext = struct {
    stream_writer: net.Stream.Writer,
    stream_reader: net.Stream.Reader,

    client_counter: i32,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

fn pong_process(ctx: *ServerContext) i32 {
    ctx.server_counter += 1;
    return ctx.server_counter;
}

fn pong_preprocess(ctx: *ClientContext, val: i32) void {
    ctx.client_counter = val;
}

const St = union(enum) {
    ping: PingPong(i32, ps.Cast("pong", PingPong, i32, @This(), .server, Context, pong_process, pong_preprocess)),
    exit: PingPong(void, ps.Exit),

    pub const agency: ps.Role = .client;

    pub fn process(ctx: *ClientContext) @This() {
        ctx.client_counter += 1;
        if (ctx.client_counter >= 20) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess(ctx: *ServerContext, msg: @This()) void {
        switch (msg) {
            .ping => |val| ctx.server_counter = val.data,
            .exit => {},
        }
    }
};

const EnterFsmState = PingPong(void, St);

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);
