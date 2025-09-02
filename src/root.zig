const std = @import("std");
const meta = std.meta;

pub const Exit = union(enum) {};

pub fn Session(
    comptime name_: []const u8,
    comptime State_: type,
    comptime Data_: type,
) type {
    return struct {
        data: Data_,

        pub const name = name_;

        pub const State = State_;
        pub const Data = Data_;
    };
}

pub const Role = enum { client, server };

//example

pub fn PingPong(State_: type, Data_: type) type {
    return Session("PingPong", State_, Data_);
}

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub const Idle = union(enum) {
    ping: PingPong(Busy, i32),
    exit: PingPong(Exit, void),

    pub const Agency: Role = .client;

    pub fn process(ctx: *ClientContext) @This() {
        if (ctx.client_counter > 100) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess(ctx: *ServerContext, msg: @This()) void {
        switch (msg) {
            .exit => {},
            .ping => |val| {
                ctx.server_counter = val.data;
            },
        }
    }
};

pub const Busy = union(enum) {
    pong: PingPong(Idle, i32),

    pub const Agency: Role = .server;

    pub fn process(ctx: *ServerContext) @This() {
        ctx.server_counter += 1;
        return .{ .pong = .{ .data = ctx.server_counter } };
    }

    pub fn preprocess(ctx: *ClientContext, msg: @This()) void {
        switch (msg) {
            .pong => |val| {
                ctx.client_counter = val.data;
            },
        }
    }
};
