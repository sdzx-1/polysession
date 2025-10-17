const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;

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
    comptime Role: type,
    comptime sender: Role,
    comptime receiver: Role,
    comptime context: anytype,
    comptime batch_size: usize,
    comptime sender_ctx_field: std.meta.FieldEnum(@field(context, @tagName(sender))),
    comptime recver_ctx_field: std.meta.FieldEnum(@field(context, @tagName(receiver))),
) type {
    return struct {
        fn sendfile_info(
            sender_: Role,
            receiver_: []const Role,
        ) ps.ProtocolInfo("sendfile", Role, context) {
            return .{ .sender = sender_, .receiver = receiver_ };
        }

        pub fn Start(Successed: type, Failed: type) type {
            const Tmp = struct {
                pub fn process(parent_ctx: *@field(context, @tagName(sender))) !u64 {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    return ctx.file_size;
                }

                pub fn preprocess(parent_ctx: *@field(context, @tagName(receiver)), msg: u64) !void {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    ctx.total = msg;
                }
            };
            return ps.Cast("sendfile", context, sender, receiver, u64, Tmp, Send(Successed, Failed));
        }

        pub fn Send(Successed: type, Failed: type) type {
            return union(enum) {
                // zig fmt: off
                check     : Data(u64       , CheckHash(@This(), Failed)),
                send      : Data([]const u8, @This()),
                final     : Data([]const u8, ps.Cast("sendfile", context, sender, receiver, u64, Tmp, CheckHash(Successed, Failed))),
                final_zero: Data(void      , Successed),
               // zig fmt: on

                pub const info = sendfile_info(sender, &.{receiver});

                pub fn process(parent_ctx: *@field(context, @tagName(sender))) !@This() {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    if (ctx.send_size >= batch_size) {
                        ctx.send_size = 0;
                        const curr_hash = ctx.hasher.final();
                        ctx.hasher = std.hash.XxHash3.init(0);
                        return .{ .check = .{ .data = curr_hash } };
                    }

                    const n = try ctx.reader.readSliceShort(&ctx.send_buff);

                    if (n == 0) return .{ .final_zero = .{ .data = {} } };

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

                pub fn preprocess_0(parent_ctx: *@field(context, @tagName(receiver)), msg: @This()) !void {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    var size: usize = 0;
                    switch (msg) {
                        .send => |val| {
                            size = val.data.len;
                            ctx.recved += val.data.len;
                            ctx.hasher.update(val.data);
                            try ctx.writer.writeAll(val.data);

                            std.debug.print("recv: send {Bi}, {d:.4}\n", .{
                                size,
                                @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
                            });
                        },
                        .final => |val| {
                            size = val.data.len;
                            ctx.recved += val.data.len;
                            ctx.hasher.update(val.data);
                            try ctx.writer.writeAll(val.data);
                            try ctx.writer.flush();

                            std.debug.print("recv: final {Bi}, {d:.4}\n", .{
                                size,
                                @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
                            });
                        },
                        .final_zero => {
                            std.debug.print("recv: final_zero\n", .{});
                        },
                        .check => |val| {
                            ctx.recved_hash = val.data;
                            std.debug.print("recv: check, hash: {d}\n", .{val.data});
                        },
                    }
                }

                const Tmp = struct {
                    pub fn process(parent_ctx: *@field(context, @tagName(sender))) !u64 {
                        const ctx = sender_ctxFromParent(parent_ctx);
                        return ctx.hasher.final();
                    }

                    pub fn preprocess(parent_ctx: *@field(context, @tagName(receiver)), msg: u64) !void {
                        const ctx = recver_ctxFromParent(parent_ctx);
                        ctx.recved_hash = msg;
                    }
                };
            };
        }

        pub fn CheckHash(Successed: type, Failed: type) type {
            return union(enum) {
                Successed: Data(void, Successed),
                Failed: Data(void, Failed),

                pub const info = sendfile_info(receiver, &.{sender});

                pub fn process(parent_ctx: *@field(context, @tagName(receiver))) !@This() {
                    const ctx = recver_ctxFromParent(parent_ctx);
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
                pub fn preprocess_0(parent_ctx: *@field(context, @tagName(sender)), msg: @This()) !void {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    _ = ctx;
                    switch (msg) {
                        .Failed => {},
                        .Successed => {},
                    }
                }
            };
        }

        fn sender_ctxFromParent(parent_ctx: *@field(context, @tagName(sender))) *SendContext {
            return &@field(parent_ctx, @tagName(sender_ctx_field));
        }

        fn recver_ctxFromParent(parent_ctx: *@field(context, @tagName(receiver))) *RecvContext {
            return &@field(parent_ctx, @tagName(recver_ctx_field));
        }
    };
}
