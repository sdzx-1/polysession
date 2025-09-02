const std = @import("std");
const root = @import("root.zig");

const EnterFsmState = root.PingPong(root.Idle, void);

pub fn main() !void {
    const StateMap: root.StateMap = .init(EnterFsmState);
    std.debug.print("{any}\n", .{StateMap.StateId});
    inline for (@typeInfo(StateMap.StateId).@"enum".fields) |field| {
        std.debug.print("{s}\n", .{field.name});
    }
    const ClientRunner = root.Runner(EnterFsmState, .client);
    const curr_id = ClientRunner.idFromState(root.Idle);
    var client_context: root.ClientContext = .{ .client_counter = 0 };

    ClientRunner.runProtocol(curr_id, &client_context);
}
