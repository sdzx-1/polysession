const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const StreamChannel = @import("channel.zig").StreamChannel;

pub const Role = enum { alice, bob, charlie };

pub fn main() !void {
    std.debug.print("nice\n", .{});
}
