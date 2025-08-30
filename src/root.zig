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

pub fn Other(
    comptime OtherState_: type,
    comptime Data_: type,
) type {
    return struct {
        data: Data_,

        pub const OtherState = OtherState_;
        pub const Data = Data_;
    };
}

// pub const RC = union(enum) {
//     a: i32,
//     b: i32,
//     c: i32,
// };

pub fn PingPong(State_: type, Data_: type) type {
    return Session("PingPong", State_, Data_);
}

//RC: RoleAndContext
pub fn Idle(RC: type, From_: meta.Tag(RC), To_: meta.Tag(RC), Next: type) type {
    return union(enum) {
        ping: PingPong(Busy(RC, To_, From_, Next), i32),
        next: Other(Next, void),

        pub const From = From_;
        pub const To = To_;

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

        pub const From = From_;
        pub const To = To_;

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
