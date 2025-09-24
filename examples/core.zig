const ps = @import("polysession");
const std = @import("std");
const pingpong = @import("pingpong.zig");
const PingPong = pingpong.PingPong;
const Start = pingpong.Start;
const sendfile = @import("sendfile.zig");
const SendFile = sendfile.SendFile;

pub const ServerContext = struct {
    server_counter: i32,
    send_context: sendfile.SendContext,
};

pub const ClientContext = struct {
    client_counter: i32,
    recv_context: sendfile.RecvContext,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

const InitSendFile = struct {
    pub fn process(ctx: *ServerContext) !u64 {
        return ctx.send_context.file_size;
    }

    pub fn preprocess(ctx: *ClientContext, val: u64) !void {
        ctx.recv_context.total = val;
    }
};

pub const EnterFsmState = PingPong(Start(SendFile(ps.Cast(
    "init send file",
    .server,
    InitSendFile,
    u64,
    SendFile(sendfile.MkSendFile(
        .server,
        Context,
        20 * 1024 * 1024,
        .send_context,
        .recv_context,
    ).Start(PingPong(Start(PingPong(ps.Exit))), SendFile(ps.Exit))),
))));

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState.State);
