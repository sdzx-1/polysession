const ps = @import("polysession");
const std = @import("std");
const pingpong = @import("pingpong.zig");
const PingPong = pingpong.PingPong;
const Start = pingpong.Start;
const sendfile = @import("sendfile.zig");
const SendFile = sendfile.SendFile;

pub const ServerContext = struct {
    server_counter: i32,

    send_buff: [1024 * 1024]u8 = @splat(0),
    reader: *std.Io.Reader,
    file_size: u64,

    send_size: usize = 0,
    hasher: std.hash.XxHash32 = std.hash.XxHash32.init(0),
};

pub const ClientContext = struct {
    client_counter: i32,

    writer: *std.Io.Writer,
    total: u64 = 0,
    recved: u64 = 0,

    recved_hash: ?u32 = null,
    hasher: std.hash.XxHash32 = std.hash.XxHash32.init(0),
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

const InitSendFile = struct {
    pub fn process(ctx: *ServerContext) !u64 {
        return ctx.file_size;
    }

    pub fn preprocess(ctx: *ClientContext, val: u64) !void {
        ctx.total = val;
    }
};

pub const EnterFsmState = PingPong(void, Start(PingPong(void, ps.Cast("init send file", .server, InitSendFile, SendFile(u64, sendfile.Start)))));

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState.State);
