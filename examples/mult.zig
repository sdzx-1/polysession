const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;

// pub const MultChannel = struct {
//     alice: ?StreamChannel,
//     bob: ?StreamChannel,
//     charlie: ?StreamChannel,
// };

//Example
pub const Role = enum { alice, bob, charlie };

pub const Context = struct {
    alice: i32,
    bob: i32,
    charlie: i32,
};

pub fn example_info(sender: Role, receiver: []const Role) ps.ProtocolInfo("Example", Role, Context) {
    return .{ .sender = sender, .receiver = receiver };
}

pub const A = union(enum) {
    msg1: Data(i32, B),

    pub const info = example_info(.alice, &.{.bob});

    pub fn process(ctx: *info.RoleCtx(.alice)) !@This() {
        return .{ .msg1 = .{ .data = ctx.* } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.bob), msg: @This()) !void {
        ctx.* = msg.val;
    }
};

pub const B = union(enum) {
    msg2: Data(i32, C),

    pub const info = example_info(.bob, &.{ .alice, .charlie });

    pub fn process(ctx: *info.RoleCtx(.bob)) !@This() {
        ctx.* += 1;
        return .{ .msg2 = .{ .data = ctx.* } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.alice), msg: @This()) !void {
        ctx.* = msg.val;
    }

    pub fn preprocess_1(ctx: *info.RoleCtx(.charlie), msg: @This()) !void {
        ctx.* = msg.val;
    }
};

pub const C = union(enum) {
    msg3: Data(void, C),
    msg4: Data(void, A),
    msg5: Data(void, ps.Exit),

    pub const info = example_info(.charlie, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.charlie)) !@This() {
        ctx.* += 1;
        if (ctx.* > 5) return .{ .msg4 = .{ .data = {} } };
        if (ctx.* > 10) return .{ .msg5 = .{ .data = {} } };
        return .{ .msg3 = .{ .data = {} } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.alice), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }

    pub fn preprocess_1(ctx: *info.RoleCtx(.bob), msg: @This()) !void {
        _ = ctx;
        _ = msg;
    }
};
