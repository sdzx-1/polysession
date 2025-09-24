const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;

pub fn SendFile(State_: type) type {
    return ps.Session("SendFile", State_);
}

pub const SendContext = struct {
    send_buff: [1024 * 1024]u8 = @splat(0),
    reader: *std.Io.Reader,
    file_size: u64,

    send_size: usize = 0,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub const RecvContext = struct {
    writer: *std.Io.Writer,
    total: u64 = 0,
    recved: u64 = 0,

    recved_hash: ?u64 = null,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub fn MkSendFile(
    comptime sender: ps.Role,
    comptime Context: ps.ClientAndServerContext,
    comptime batch_size: usize,
    comptime sender_ctx_field: std.meta.FieldEnum(@field(Context, @tagName(sender))),
    comptime recver_ctx_field: std.meta.FieldEnum(@field(Context, @tagName(sender.flip()))),
) type {
    return struct {
        pub fn Start(
            Successed_NextFsmState: type,
            Failed_NextFsmState: type,
        ) type {
            return union(enum) {
                check: Data(u64, SendFile(CheckHash(SendFile(@This()), Failed_NextFsmState))),
                send: Data([]const u8, SendFile(@This())),
                final: Data([]const u8, SendFile(ps.Cast(
                    "init check hash",
                    .server,
                    InitCheckHash,
                    u64,
                    SendFile(CheckHash(Successed_NextFsmState, Failed_NextFsmState)),
                ))),

                pub const agency: ps.Role = sender;

                pub fn process(all_ctx: *@field(Context, @tagName(sender))) !@This() {
                    const ctx = sender_ctxFromParent(all_ctx);
                    if (ctx.send_size >= batch_size) {
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

                pub fn preprocess(all_ctx: *@field(Context, @tagName(sender.flip())), msg: @This()) !void {
                    const ctx = recver_ctxFromParent(all_ctx);
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
                    pub fn process(all_ctx: *@field(Context, @tagName(sender))) !u64 {
                        const ctx = sender_ctxFromParent(all_ctx);
                        return ctx.hasher.final();
                    }

                    pub fn preprocess(all_ctx: *@field(Context, @tagName(sender.flip())), msg: u64) !void {
                        const ctx = recver_ctxFromParent(all_ctx);
                        ctx.recved_hash = msg;
                    }
                };
            };
        }

        pub fn CheckHash(
            Successed_NextFsmState: type,
            Failed_NextFsmState: type,
        ) type {
            return union(enum) {
                Successed: Data(void, Successed_NextFsmState),
                Failed: Data(void, Failed_NextFsmState),

                pub const agency: ps.Role = .client;

                pub fn process(all_ctx: *@field(Context, @tagName(sender.flip()))) !@This() {
                    const ctx = recver_ctxFromParent(all_ctx);
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
                pub fn preprocess(all_ctx: *@field(Context, @tagName(sender)), msg: @This()) !void {
                    const ctx = sender_ctxFromParent(all_ctx);
                    _ = ctx;
                    switch (msg) {
                        .Failed => {},
                        .Successed => {},
                    }
                }
            };
        }

        fn sender_ctxFromParent(parent_ctx: *@field(Context, @tagName(sender))) *SendContext {
            return &@field(parent_ctx, @tagName(sender_ctx_field));
        }

        fn recver_ctxFromParent(parent_ctx: *@field(Context, @tagName(sender.flip()))) *RecvContext {
            return &@field(parent_ctx, @tagName(recver_ctx_field));
        }
    };
}
