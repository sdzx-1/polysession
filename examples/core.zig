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

pub const Role = enum { client, server };

pub const Context = struct {
    client: type = ClientContext,
    server: type = ServerContext,
};

fn PingPong(NextFsmState: type) type {
    return pingpong.MkPingPong(Role, .client, .server, Context{}, .pingpong, .pingpong, NextFsmState);
}
fn SendFile(Successed: type, Failed: type) type {
    return sendfile.MkSendFile(
        Role,
        .server,
        .client,
        Context{},
        20 * 1024 * 1024,
        .send_context,
        .recv_context,
        Successed,
        Failed,
    );
}

pub const EnterFsmState = PingPong(SendFile(PingPong(ps.Exit).Start, ps.Exit).Start).Start;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

pub fn graph(gpa: std.mem.Allocator) !ps.Graph {
    return ps.Graph.initWithFsm(gpa, EnterFsmState);
}
