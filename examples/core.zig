const ps = @import("polysession");
const std = @import("std");
const pingpong = @import("pingpong.zig");
const PingPong = pingpong.PingPong;
const Start = pingpong.Start;

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

pub const EnterFsmState = PingPong(void, Start(PingPong(void, ps.Exit)));
// const EnterFsmState = PingPong(void, Start(PingPong(void, Start(PingPong(void, ps.Exit)))));

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState.State);
