## Polysession Example: pingpong


Here is a simple pingpong example to illustrate the compositionality of polysession.


The meaning of this pingpong protocol is as follows:
Initially, both the client and server are in the Start state.

The client checks the value of the client_counter field in the ClientContext.

1. If the value of client_counter is greater than 10, it clears client_counter and sends a next message to the server. Upon receiving the message, the server clears the server_counter field in the ServerContext. After this, both the client and server enter the new state specified by the next message.

2. If the value of client_counter is less than 10, the client sends a ping message to the server containing the value. Upon receiving the value, the server stores it in server_counter, increments server_counter by one, and then sends the new server_counter value to the client. The client receives the message and stores it in client_counter. The client and server then enter the Start state again.

```zig

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
                ping: Data(i32, ps.Cast("pingpong", "pong", client.flip(), PongFn, i32, @This())),
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

```

```zig
const PingPong = pingpong.MkPingPong(.client, Context, .pingpong, .pingpong);
pub const EnterFsmState = PingPong.Start(ps.Exit);
```

Here we let next point to the Exit state, which means that the pingpong protocol will exit directly after running.

Run this protocol, the result is as follows:

```shell
client:                                                          server:
send: .{ .ping = .{ .data = 0 } }                                recv: .{ .ping = .{ .data = 0 } }
recv: .{ .cast = .{ .data = 1 } }                                send: .{ .cast = .{ .data = 1 } }
send: .{ .ping = .{ .data = 1 } }                                recv: .{ .ping = .{ .data = 1 } }
recv: .{ .cast = .{ .data = 2 } }                                send: .{ .cast = .{ .data = 2 } }
send: .{ .ping = .{ .data = 2 } }                                recv: .{ .ping = .{ .data = 2 } }
recv: .{ .cast = .{ .data = 3 } }                                send: .{ .cast = .{ .data = 3 } }
send: .{ .ping = .{ .data = 3 } }                                recv: .{ .ping = .{ .data = 3 } }
recv: .{ .cast = .{ .data = 4 } }                                send: .{ .cast = .{ .data = 4 } }
send: .{ .ping = .{ .data = 4 } }                                recv: .{ .ping = .{ .data = 4 } }
recv: .{ .cast = .{ .data = 5 } }                                send: .{ .cast = .{ .data = 5 } }
send: .{ .ping = .{ .data = 5 } }                                recv: .{ .ping = .{ .data = 5 } }
recv: .{ .cast = .{ .data = 6 } }                                send: .{ .cast = .{ .data = 6 } }
send: .{ .ping = .{ .data = 6 } }                                recv: .{ .ping = .{ .data = 6 } }
recv: .{ .cast = .{ .data = 7 } }                                send: .{ .cast = .{ .data = 7 } }
send: .{ .ping = .{ .data = 7 } }                                recv: .{ .ping = .{ .data = 7 } }
recv: .{ .cast = .{ .data = 8 } }                                send: .{ .cast = .{ .data = 8 } }
send: .{ .ping = .{ .data = 8 } }                                recv: .{ .ping = .{ .data = 8 } }
recv: .{ .cast = .{ .data = 9 } }                                send: .{ .cast = .{ .data = 9 } }
send: .{ .ping = .{ .data = 9 } }                                recv: .{ .ping = .{ .data = 9 } }
recv: .{ .cast = .{ .data = 10 } }                               send: .{ .cast = .{ .data = 10 } }
send: .{ .next = .{ .data = void } }                             recv: .{ .next = .{ .data = void } }
```
---------------------------------------------

```zig
pub const EnterFsmState = PingPong.Start(PingPong.Start(ps.Exit));
```

Let's modify the protocol so that next now points to the Start state of pingpong (inside Start's next points to Exit). This means we will run the pingpong protocol twice.

This is the embodiment of compositionality.

Run this protocol, the result is as follows:

```shell
client:                                                          server:                                                     
send: .{ .ping = .{ .data = 0 } }                                recv: .{ .ping = .{ .data = 0 } }    
recv: .{ .cast = .{ .data = 1 } }                                send: .{ .cast = .{ .data = 1 } }    
send: .{ .ping = .{ .data = 1 } }                                recv: .{ .ping = .{ .data = 1 } }    
recv: .{ .cast = .{ .data = 2 } }                                send: .{ .cast = .{ .data = 2 } }    
send: .{ .ping = .{ .data = 2 } }                                recv: .{ .ping = .{ .data = 2 } }    
recv: .{ .cast = .{ .data = 3 } }                                send: .{ .cast = .{ .data = 3 } }    
send: .{ .ping = .{ .data = 3 } }                                recv: .{ .ping = .{ .data = 3 } }    
recv: .{ .cast = .{ .data = 4 } }                                send: .{ .cast = .{ .data = 4 } }    
send: .{ .ping = .{ .data = 4 } }                                recv: .{ .ping = .{ .data = 4 } }    
recv: .{ .cast = .{ .data = 5 } }                                send: .{ .cast = .{ .data = 5 } }    
send: .{ .ping = .{ .data = 5 } }                                recv: .{ .ping = .{ .data = 5 } }    
recv: .{ .cast = .{ .data = 6 } }                                send: .{ .cast = .{ .data = 6 } }    
send: .{ .ping = .{ .data = 6 } }                                recv: .{ .ping = .{ .data = 6 } }    
recv: .{ .cast = .{ .data = 7 } }                                send: .{ .cast = .{ .data = 7 } }    
send: .{ .ping = .{ .data = 7 } }                                recv: .{ .ping = .{ .data = 7 } }    
recv: .{ .cast = .{ .data = 8 } }                                send: .{ .cast = .{ .data = 8 } }    
send: .{ .ping = .{ .data = 8 } }                                recv: .{ .ping = .{ .data = 8 } }    
recv: .{ .cast = .{ .data = 9 } }                                send: .{ .cast = .{ .data = 9 } }    
send: .{ .ping = .{ .data = 9 } }                                recv: .{ .ping = .{ .data = 9 } }    
recv: .{ .cast = .{ .data = 10 } }                               send: .{ .cast = .{ .data = 10 } }    
send: .{ .next = .{ .data = void } }                             recv: .{ .next = .{ .data = void } }    
send: .{ .ping = .{ .data = 0 } }                                recv: .{ .ping = .{ .data = 0 } }    
recv: .{ .cast = .{ .data = 1 } }                                send: .{ .cast = .{ .data = 1 } }    
send: .{ .ping = .{ .data = 1 } }                                recv: .{ .ping = .{ .data = 1 } }    
recv: .{ .cast = .{ .data = 2 } }                                send: .{ .cast = .{ .data = 2 } }    
send: .{ .ping = .{ .data = 2 } }                                recv: .{ .ping = .{ .data = 2 } }    
recv: .{ .cast = .{ .data = 3 } }                                send: .{ .cast = .{ .data = 3 } }    
send: .{ .ping = .{ .data = 3 } }                                recv: .{ .ping = .{ .data = 3 } }    
recv: .{ .cast = .{ .data = 4 } }                                send: .{ .cast = .{ .data = 4 } }    
send: .{ .ping = .{ .data = 4 } }                                recv: .{ .ping = .{ .data = 4 } }    
recv: .{ .cast = .{ .data = 5 } }                                send: .{ .cast = .{ .data = 5 } }    
send: .{ .ping = .{ .data = 5 } }                                recv: .{ .ping = .{ .data = 5 } }    
recv: .{ .cast = .{ .data = 6 } }                                send: .{ .cast = .{ .data = 6 } }    
send: .{ .ping = .{ .data = 6 } }                                recv: .{ .ping = .{ .data = 6 } }    
recv: .{ .cast = .{ .data = 7 } }                                send: .{ .cast = .{ .data = 7 } }    
send: .{ .ping = .{ .data = 7 } }                                recv: .{ .ping = .{ .data = 7 } }    
recv: .{ .cast = .{ .data = 8 } }                                send: .{ .cast = .{ .data = 8 } }    
send: .{ .ping = .{ .data = 8 } }                                recv: .{ .ping = .{ .data = 8 } }    
recv: .{ .cast = .{ .data = 9 } }                                send: .{ .cast = .{ .data = 9 } }    
send: .{ .ping = .{ .data = 9 } }                                recv: .{ .ping = .{ .data = 9 } }    
recv: .{ .cast = .{ .data = 10 } }                               send: .{ .cast = .{ .data = 10 } }    
send: .{ .next = .{ .data = void } }                             recv: .{ .next = .{ .data = void } }    

```

I think all this is enough to illustrate the power of polysession. You can combine various protocols like building blocks, and it is completely safe and correct.
