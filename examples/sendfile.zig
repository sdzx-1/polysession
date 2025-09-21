const std = @import("std");
const ps = @import("polysession");
const core = @import("core.zig");
const Data = ps.Data;
const ServerContext = core.ServerContext;
const ClientContext = core.ClientContext;

pub fn SendFile(State_: type) type {
    return ps.Session("SendFile", State_);
}

const InitCheckHash = struct {
    pub fn process(ctx: *ServerContext) !u64 {
        return ctx.hasher.final();
    }

    pub fn preprocess(ctx: *ClientContext, msg: u64) !void {
        ctx.recved_hash = msg;
    }
};

pub const Start = union(enum) {
    check: Data(u64, SendFile(CheckHash(@This()))),
    send: Data([]const u8, SendFile(@This())),
    final: Data(
        []const u8,
        SendFile(ps.Cast("init check hash", .server, InitCheckHash, u64, SendFile(CheckHash(ps.Exit)))),
    ),

    pub const agency: ps.Role = .server;

    pub fn process(ctx: *ServerContext) !@This() {
        if (ctx.send_size >= 20 * 1024 * 1024) {
            ctx.send_size = 0;
            const curr_hash = ctx.hasher.final();
            ctx.hasher = std.hash.XxHash3.init(0);
            return .{ .check = .{ .data = curr_hash } };
        }

        const n = try ctx.reader.readSliceShort(&ctx.send_buff);
        if (n < ctx.send_buff.len) {
            ctx.hasher.update(ctx.send_buff[0..n]);
            ctx.send_size += ctx.send_buff.len;
            return .{ .final = .{ .data = ctx.send_buff[0..n] } };
        } else {
            ctx.hasher.update(&ctx.send_buff);
            ctx.send_size += ctx.send_buff.len;
            return .{ .send = .{ .data = &ctx.send_buff } };
        }
    }

    pub fn preprocess(ctx: *ClientContext, msg: @This()) !void {
        var size: usize = 0;
        switch (msg) {
            .send => |val| {
                size = val.data.len;
                ctx.recved += val.data.len;
                ctx.hasher.update(val.data);
                try ctx.writer.writeAll(val.data);
            },
            .final => |val| {
                size = val.data.len;
                ctx.recved += val.data.len;
                ctx.hasher.update(val.data);
                try ctx.writer.writeAll(val.data);
                try ctx.writer.flush();
            },
            .check => |val| {
                ctx.recved_hash = val.data;
            },
        }

        std.debug.print("recv: {Bi}, {d:.4}\n", .{
            size,
            @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
        });
    }
};

pub fn CheckHash(NextState: type) type {
    return union(enum) {
        Successed: Data(void, SendFile(NextState)),
        Failed: Data(void, SendFile(ps.Exit)),

        pub const agency: ps.Role = .client;

        pub fn process(ctx: *ClientContext) !@This() {
            const curr_hash = ctx.hasher.final();
            ctx.hasher = std.hash.XxHash3.init(0);
            if (curr_hash == ctx.recved_hash) {
                std.debug.print("check successed \n", .{});
                return .{ .Successed = .{ .data = {} } };
            } else {
                std.debug.print("check failed \n", .{});
                return .{ .Failed = .{ .data = {} } };
            }
        }
        pub fn preprocess(ctx: *ServerContext, msg: @This()) !void {
            _ = ctx;
            switch (msg) {
                .Failed => {},
                .Successed => {},
            }
        }
    };
}
