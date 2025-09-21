const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;

pub fn SendFile(State_: type) type {
    return ps.Session("SendFile", State_);
}

pub const ServerContext = struct {
    send_buff: [1024 * 1024]u8 = @splat(0),
    reader: *std.Io.Reader,
    file_size: u64,

    send_size: usize = 0,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub const ClientContext = struct {
    writer: *std.Io.Writer,
    total: u64 = 0,
    recved: u64 = 0,

    recved_hash: ?u64 = null,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub fn MkSendFile(Context: ps.ClientAndServerContext) type {
    return struct {
        pub const Start = union(enum) {
            check: Data(u64, SendFile(CheckHash(@This()))),
            send: Data([]const u8, SendFile(@This())),
            final: Data(
                []const u8,
                SendFile(ps.Cast(
                    "init check hash",
                    .server,
                    InitCheckHash,
                    u64,
                    SendFile(CheckHash(ps.Exit)),
                )),
            ),

            pub const agency: ps.Role = .server;

            pub fn process(all_ctx: *Context.server) !@This() {
                const ctx: *ServerContext = &all_ctx.send_file_server;
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

            pub fn preprocess(all_ctx: *Context.client, msg: @This()) !void {
                const ctx: *ClientContext = &all_ctx.send_file_client;
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

            const InitCheckHash = struct {
                pub fn process(all_ctx: *Context.server) !u64 {
                    const ctx: *ServerContext = &all_ctx.send_file_server;
                    return ctx.hasher.final();
                }

                pub fn preprocess(all_ctx: *Context.client, msg: u64) !void {
                    const ctx: *ClientContext = &all_ctx.send_file_client;
                    ctx.recved_hash = msg;
                }
            };
        };

        pub fn CheckHash(NextState: type) type {
            return union(enum) {
                Successed: Data(void, SendFile(NextState)),
                Failed: Data(void, SendFile(ps.Exit)),

                pub const agency: ps.Role = .client;

                pub fn process(all_ctx: *Context.client) !@This() {
                    const ctx: *ClientContext = &all_ctx.send_file_client;
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
                pub fn preprocess(all_ctx: *Context.server, msg: @This()) !void {
                    _ = all_ctx;
                    switch (msg) {
                        .Failed => {},
                        .Successed => {},
                    }
                }
            };
        }
    };
}
