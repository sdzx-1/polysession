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

            try Runner.runProtocol(.client, Channel(ClientContext), true, curr_id, &client_context);
            // catch |err| {
            // std.debug.print("err: {any}\n", .{err});
            // const tt = @typeInfo(@TypeOf(err)).error_set;
            // @compileLog(tt);
            //
            //
            // @as(?[]const builtin.Type.Error, &.{
            // .{ .name = "WriteFailed"[0..11] },
            // .{ .name = "ReadFailed"[0..10] },
            // .{ .name = "EndOfStream"[0..11] },
            // .{ .name = "IncorrectStatusReceived"[0..23] },
            // .{ .name = "TestError"[0..9] } }[0..5])        }
            // };
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

    try Runner.runProtocol(.server, Channel(ServerContext), true, curr_id, &server_context);
    // catch |err| {
    // std.debug.print("err: {any}\n", .{err});

    // const tt = @typeInfo(@TypeOf(err)).error_set;
    // @compileLog(tt);
    //
    //
    // @as(?[]const builtin.Type.Error, &.{
    // .{ .name = "WriteFailed"[0..11] },
    // .{ .name = "ReadFailed"[0..10] },
    // .{ .name = "EndOfStream"[0..11] },
    // .{ .name = "IncorrectStatusReceived"[0..23] } }[0..4])
    // };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{ .server, Channel(ServerContext), true, curr_id, &server_context });
    defer stid.join();
}

pub fn Channel(Context_: type) type {
    return struct {
        pub fn send(ctx: *Context_, state_id: anytype, val: anytype) !void {
            const writer = &ctx.stream_writer.interface;
            const id: u8 = @intFromEnum(state_id);
            switch (val) {
                inline else => |msg, tag| {
                    try writer.writeByte(id);
                    try writer.writeByte(@intFromEnum(tag));
                    const data = msg.data;
                    switch (@typeInfo(@TypeOf(data))) {
                        .void => {},
                        .int => {
                            try writer.writeInt(@TypeOf(data), data, .little);
                        },
                        .@"struct" => {
                            try data.encode(writer);
                        },
                        else => @compileError("Not impl!"),
                    }
                },
            }

            try writer.flush();
        }

        pub fn recv(ctx: *Context_, state_id: anytype, T: type) !T {
            const reader = ctx.stream_reader.interface();
            const id: u8 = @intFromEnum(state_id);
            const sid = try reader.takeByte();
            std.debug.assert(id == sid);
            if (id != sid) return error.IncorrectStatusReceived;
            const recv_tag_num = try reader.takeByte();
            const tag: std.meta.Tag(T) = @enumFromInt(recv_tag_num);
            switch (tag) {
                inline else => |t| {
                    const Data = @FieldType(std.meta.TagPayload(T, t), "data");
                    switch (@typeInfo(Data)) {
                        .void => {
                            return @unionInit(T, @tagName(t), .{ .data = {} });
                        },
                        .int => {
                            const data = try reader.takeInt(Data, .little);
                            return @unionInit(T, @tagName(t), .{ .data = data });
                        },
                        .@"struct" => {
                            const data = try Data.decode(reader);
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

const PongFn = struct {
    pub fn process(ctx: *ServerContext) !i32 {
        ctx.server_counter += 1;
        return ctx.server_counter;
    }

    pub fn preprocess(ctx: *ClientContext, val: i32) !void {
        ctx.client_counter = val;
    }
};

const St = union(enum) {
    ping: PingPong(i32, ps.Cast("pong", .server, PongFn, PingPong(i32, @This()))),
    exit: PingPong(void, ps.Exit),

    pub const agency: ps.Role = .client;

    pub fn process(ctx: *ClientContext) !@This() {
        ctx.client_counter += 1;
        if (ctx.client_counter > 10) return error.TestError;
        if (ctx.client_counter >= 20) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess(ctx: *ServerContext, msg: @This()) !void {
        switch (msg) {
            .ping => |val| ctx.server_counter = val.data,
            .exit => {},
        }
    }
};

const EnterFsmState = PingPong(void, St);

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);

const ProtocolFamily = union(enum) {
    pingpong0: PingPong(void, St),
    pingpong1: PingPong(void, St),
    pingpong2: PingPong(void, St),
};
