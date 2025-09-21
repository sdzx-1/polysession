const std = @import("std");
const ps = @import("polysession");
const core = @import("core.zig");
const Data = ps.Data;
const ServerContext = core.ServerContext;
const ClientContext = core.ClientContext;

pub fn PingPong(State_: type) type {
    return ps.Session("PingPong", State_);
}

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
        ping: Data(i32, PingPong(ps.Cast(
            "pong",
            .server,
            PongFn,
            i32,
            PingPong(@This()),
        ))),
        next: Data(void, NextFsmState),

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
