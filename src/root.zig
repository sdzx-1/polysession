const std = @import("std");
const meta = std.meta;

pub const Exit = union(enum) {};

pub fn Session(
    comptime name_: []const u8,
    comptime ClientContext_: type,
    comptime ServerContext_: type,
    comptime State_: type,
    comptime Data_: type,
) type {
    return struct {
        data: Data_,

        pub const name = name_;
        pub const ClientContext = ClientContext_;
        pub const ServerContext = ServerContext_;
        pub const State = State_;
        pub const Data = Data_;
    };
}

// Protocol
// Idle(PP, .a, .b, next) {
// }
//
// dir: a -> b
//
//
// send_fun
// recv_fun
//

pub const Role = enum { client, server };

//PingPong Example
pub const ClientContext = i32;
pub const ServerContext = i32;

pub fn PingPong(State_: type, Data_: type) type {
    return Session("PingPong", ClientContext, ServerContext, State_, Data_);
}

// pub const RC = union(enum) {
//     a: i32,
//     b: i32,
//     c: i32,
// };

// const Idle = union(enum) {
//     ping: PingPong(Busy, i32),
//     exit: PingPong(Exit, void),

//     pub const From: meta.Tag(RC) = .a;
//     pub const To: meta.Tag(RC) = .b;

//     pub fn send(ctx: *meta.TagPayload(RC, From)) @This() {
//         std.debug.print("{any}\n", .{ctx.*});
//         ctx.* += 1;
//         std.debug.print("{any}\n", .{ctx.*});
//         return .{ .ping = .{ .data = 10 } };
//     }

//     pub fn recv(ctx: *meta.TagPayload(RC, To), msg: @This()) void {
//         _ = ctx;
//         _ = msg;
//     }
// };

// test "Idle" {
//     var va: i32 = 100;
//     std.debug.print("{any}\n", .{Idle.send(&va)});
// }

//RC: RoleAndContext
pub fn Idle(RC: type, From_: meta.Tag(RC), To_: meta.Tag(RC), Next: type) type {
    return union(enum) {
        ping: PingPong(Busy(RC, To_, From_, Next), i32),
        next: PingPong(Next, void),

        pub const From: meta.Tag(RC) = From_;
        pub const To: meta.Tag(RC) = To_;

        pub fn send(ctx: *meta.TagPayload(RC, From)) @This() {
            ctx.* += 1;
            return .{ .ping = .{ .data = 10 } };
        }

        pub fn recv(ctx: *meta.TagPayload(RC, To), msg: @This()) void {
            _ = ctx;
            _ = msg;
        }
    };
}

pub fn Busy(RC: type, From_: meta.Tag(RC), To_: meta.Tag(RC), Next: type) type {
    return union(enum) {
        pong: PingPong(Idle(RC, To_, From_, Next), i32),

        pub const From: meta.Tag(RC) = From_;
        pub const To: meta.Tag(RC) = To_;

        pub fn send(ctx: *meta.TagPayload(RC, From)) @This() {
            _ = ctx;
            return .{ .pong = .{ .data = 10 } };
        }

        pub fn recv(ctx: *meta.TagPayload(RC, To), msg: @This()) void {
            _ = ctx;
            _ = msg;
        }
    };
}

// 角色a,b 之间 的pingpong 通信, 然后结束
//
// Protocol1 = Idle(RC, .a, .b, Exit);
//
//
//
// 先a, b之间pingpong 通信, 然后再次a,b之间pingpong 通信,然后结束
//
// Protocol2 = Idle(RC, .a, .b, Idle(RC, .a, .b, Exit));
//
//
//
// 先a, b之间pingpong 通信, 然后再次b, a之间pingpong 通信,然后结束
//
// Protocol3 = Idle(RC, .a, .b, Idle(RC, .b, .a, Exit));
//
//
//
// Protocol4 = Idle(RC, .a, .b, Idle(RC, .a, .c, Idle(RC, .b, .c, Exit)));
