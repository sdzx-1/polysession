const std = @import("std");
const polysession = @import("polysession");

pub fn main() !void {
    std.debug.print("nice\n", .{});
}

pub const Done = union(enum) {};

pub fn Session(state: type) type {
    return struct {
        pub const State = state;
    };
}

pub const ClientContext = i32;
pub const ServerContext = i32;

const Idle = union(enum) {
    ping: Session(Busy),
    done: Session(Done),

    pub fn client_yield(ctx: *ClientContext) @This() {
        _ = ctx;
    }

    pub fn server_await(ctx: *ServerContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};

const Busy = union(enum) {
    pong: Session(Idle),

    pub fn server_yield(ctx: *ServerContext) @This() {
        _ = ctx;
    }

    pub fn client_await(ctx: *ClientContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};
