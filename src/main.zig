const std = @import("std");
const root = @import("root.zig");

const EnterFsmState = root.PingPong(root.Idle, void);

pub fn main() !void {
    //
    root.client_mutex.lock();
    root.server_mutex.lock();

    //Server
    const ServerRunner = root.Runner(EnterFsmState, .server);
    const curr_id = ServerRunner.idFromState(EnterFsmState.State);
    var server_context: root.ServerContext = .{ .server_counter = 0 };

    const stid = try std.Thread.spawn(.{}, ServerRunner.runProtocol, .{ curr_id, &server_context });

    //Client
    const ClientRunner = root.Runner(EnterFsmState, .client);
    const curr_id1 = ClientRunner.idFromState(EnterFsmState.State);
    var client_context: root.ClientContext = .{ .client_counter = 0 };

    const ctid = try std.Thread.spawn(.{}, ClientRunner.runProtocol, .{ curr_id1, &client_context });

    ctid.join();
    stid.join();
}
