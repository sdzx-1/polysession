const std = @import("std");
const ps = @import("polysession");
const core = @import("core.zig");
const ServerContext = core.ServerContext;
const ClientContext = core.ClientContext;

pub fn SendFile(Data_: type, State_: type) type {
    return ps.Session("SendFile", Data_, State_);
}

pub const Start = union(enum) {
    send: SendFile([]const u8, @This()),
    final: SendFile([]const u8, ps.Exit),

    pub const agency: ps.Role = .server;

    pub fn process(ctx: *ServerContext) !@This() {
        const n = try ctx.reader.readSliceShort(&ctx.send_buff);
        if (n < ctx.send_buff.len) {
            return .{ .final = .{ .data = ctx.send_buff[0..n] } };
        } else {
            return .{ .send = .{ .data = &ctx.send_buff } };
        }
    }

    pub fn preprocess(ctx: *ClientContext, msg: @This()) !void {
        var size: usize = 0;
        switch (msg) {
            .send => |val| {
                size = val.data.len;
                ctx.recved += val.data.len;
                try ctx.writer.writeAll(val.data);
            },
            .final => |val| {
                size = val.data.len;
                ctx.recved += val.data.len;
                try ctx.writer.writeAll(val.data);
                try ctx.writer.flush();
            },
        }

        std.debug.print("recv: {Bi}, {d:.4}\n", .{
            size,
            @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
        });
    }
};
