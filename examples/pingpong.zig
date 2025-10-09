const std = @import("std");
const ps = @import("polysession");
const core = @import("core.zig");
const Data = ps.Data;

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub fn MkPingPong(
    comptime client: ps.Role,
    comptime Context: ps.ClientAndServerContext,
    comptime client_ctx_field: std.meta.FieldEnum(@field(Context, @tagName(client))),
    comptime server_ctx_field: std.meta.FieldEnum(@field(Context, @tagName(client.flip()))),
) type {
    return struct {
        pub fn Start(NextFsmState: type) type {
            return union(enum) {
                ping: Data(i32, ps.Cast("pingpong", "pong", client.flip(), i32, PongFn, @This())),
                next: Data(void, NextFsmState),

                pub const agency: ps.Role = client;
                pub const protocol = "pingpong";

                pub fn process(parent_ctx: *@field(Context, @tagName(client))) !@This() {
                    const ctx = client_ctxFromParent(parent_ctx);
                    if (ctx.client_counter >= 10) {
                        ctx.client_counter = 0;
                        return .{ .next = .{ .data = {} } };
                    }
                    return .{ .ping = .{ .data = ctx.client_counter } };
                }

                pub fn preprocess(parent_ctx: *@field(Context, @tagName(client.flip())), msg: @This()) !void {
                    const ctx = server_ctxFromParent(parent_ctx);
                    switch (msg) {
                        .ping => |val| ctx.server_counter = val.data,
                        .next => {
                            ctx.server_counter = 0;
                        },
                    }
                }
            };
        }

        const PongFn = struct {
            pub fn process(parent_ctx: *@field(Context, @tagName(client.flip()))) !i32 {
                const ctx = server_ctxFromParent(parent_ctx);
                ctx.server_counter += 1;
                return ctx.server_counter;
            }

            pub fn preprocess(parent_ctx: *@field(Context, @tagName(client)), val: i32) !void {
                const ctx = client_ctxFromParent(parent_ctx);
                ctx.client_counter = val;
            }
        };
        fn client_ctxFromParent(parent_ctx: *@field(Context, @tagName(client))) *ClientContext {
            return &@field(parent_ctx, @tagName(client_ctx_field));
        }

        fn server_ctxFromParent(parent_ctx: *@field(Context, @tagName(client.flip()))) *ServerContext {
            return &@field(parent_ctx, @tagName(server_ctx_field));
        }
    };
}
