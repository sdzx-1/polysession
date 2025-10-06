const ps = @import("polysession");
const std = @import("std");
const pingpong = @import("pingpong.zig");
const sendfile = @import("sendfile.zig");

pub const ServerContext = struct {
    pingpong: pingpong.ServerContext,
    send_context: sendfile.SendContext,
};

pub const ClientContext = struct {
    pingpong: pingpong.ClientContext,
    recv_context: sendfile.RecvContext,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

const PingPong = pingpong.MkPingPong(.client, Context, .pingpong, .pingpong);
const SendFile = sendfile.MkSendFile(.server, Context, 20 * 1024 * 1024, .send_context, .recv_context);

pub const EnterFsmState = PingPong.Start(SendFile.Start(
    PingPong.Start(ps.Exit),
    ps.Exit,
));

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);
