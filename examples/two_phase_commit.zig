const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;

pub fn main() !void {
    std.debug.print("curr_id {d}\n", .{curr_id});
}

pub const Runner = ps.Runner(Start);
pub const curr_id = Runner.idFromState(Start);

//
const Role = enum { coordinator, alice, bob };

const Context = struct {
    coordinator: type = u32,
    alice: type = struct { xoshiro256: std.Random.Xoshiro256 },
    bob: type = struct { xoshiro256: std.Random.Xoshiro256 },
};

fn two_pc(sender: Role, receiver: []const Role) ps.ProtocolInfo("2pc", Role, Context{}) {
    return .{ .sender = sender, .receiver = receiver };
}

const Start = union(enum) {
    begin: Data(void, AliceResp),

    pub const info = two_pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.coordinator)) !@This() {
        _ = ctx;
        return .{ .begin = .{ .data = {} } };
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

const AliceResp = union(enum) {
    resp: Data(bool, BobResp),

    pub const info = two_pc(.alice, &.{.coordinator});

    pub fn process(ctx: *info.RoleCtx(.alice)) !@This() {
        const random: std.Random = ctx.xoshiro256.random();
        const res: bool = random.intRangeAtMost(u32, 0, 100) < 30;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx += 1;
            },
        }
    }
};

const BobResp = union(enum) {
    resp: Data(bool, Check),

    pub const info = two_pc(.bob, &.{.coordinator});

    pub fn process(ctx: *info.RoleCtx(.bob)) !@This() {
        const random: std.Random = ctx.xoshiro256.random();
        const res: bool = random.intRangeAtMost(u32, 0, 100) < 30;
        return .{ .resp = .{ .data = res } };
    }

    pub fn preprocess_0(ctx: *info.RoleCtx(.coordinator), msg: @This()) !void {
        switch (msg) {
            .resp => |val| {
                if (val.data) ctx += 1;
            },
        }
    }
};

const Check = union(enum) {
    succcessed: Data(void, ps.Exit),
    failed_retry: Data(void, Start),

    pub const info = two_pc(.coordinator, &.{ .alice, .bob });

    pub fn process(ctx: *info.RoleCtx(.coordinator)) !@This() {
        if (ctx.* == 2) {
            return .{ .succcessed = .{ .data = {} } };
        }
        ctx.* = 0;
        return .{ .failed_retry = .{ .data = {} } };
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
