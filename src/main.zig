const std = @import("std");
const ps = @import("root.zig");

pub fn main() !void {
    //
    client_mutex.lock();
    server_mutex.lock();

    //Server
    const ServerRunner = ps.Runner(EnterFsmState, .server, ServerChannel);
    const curr_id = ServerRunner.idFromState(EnterFsmState.State);
    var server_context: ServerContext = .{
        .server_counter = 0,
        .client_counter = 0,
    };

    const stid = try std.Thread.spawn(.{}, ServerRunner.runProtocol, .{ curr_id, &server_context });

    //Client
    const ClientRunner = ps.Runner(EnterFsmState, .client, ClientChannel);
    const curr_id1 = ClientRunner.idFromState(EnterFsmState.State);
    var client_context: ClientContext = .{
        .client_counter = 0,
        .server_counter = 0,
    };

    const ctid = try std.Thread.spawn(.{}, ClientRunner.runProtocol, .{ curr_id1, &client_context });

    ctid.join();
    stid.join();

    std.debug.print("client_context: {any}\n", .{client_context});
    std.debug.print("server_context: {any}\n", .{server_context});
}

//example

pub fn PingPong(State_: type, Data_: type) type {
    return ps.Session("PingPong", State_, Data_);
}

pub const ServerContext = struct {
    server_counter: i32,
    client_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
    server_counter: i32,
};

pub const Context: ps.ClientAndServerContext = .{
    .client = ClientContext,
    .server = ServerContext,
};

const EnterFsmState = PingPong(Idle(.client, PingPong(Idle(.server, PingPong(ps.Exit, void)), void)), void);

pub fn Idle(agency_: ps.Role, NextFsmState: type) type {
    return union(enum) {
        ping: PingPong(Busy(agency_.flip(), NextFsmState), i32),
        next: NextFsmState,

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context, @tagName(agency_))) @This() {
            ctx.client_counter += 1;
            if (ctx.client_counter > 10) return .{ .next = .{ .data = {} } };
            return .{ .ping = .{ .data = ctx.client_counter } };
        }

        pub fn preprocess(ctx: *@field(Context, @tagName(agency_.flip())), msg: @This()) void {
            switch (msg) {
                .next => {},
                .ping => |val| {
                    ctx.server_counter = val.data;
                },
            }
        }
    };
}
pub fn Busy(agency_: ps.Role, NextFsmState: type) type {
    return union(enum) {
        pong: PingPong(Idle(agency_.flip(), NextFsmState), i32),

        pub const agency: ps.Role = agency_;

        pub fn process(ctx: *@field(Context, @tagName(agency_))) @This() {
            ctx.server_counter += 2;
            return .{ .pong = .{ .data = ctx.server_counter } };
        }

        pub fn preprocess(ctx: *@field(Context, @tagName(agency_.flip())), msg: @This()) void {
            switch (msg) {
                .pong => |val| {
                    ctx.client_counter = val.data;
                },
            }
        }
    };
}

//simple send, recv
var client_mailbox: *const anyopaque = undefined;
pub var client_mutex: std.Thread.Mutex = .{};

var server_mailbox: *const anyopaque = undefined;
pub var server_mutex: std.Thread.Mutex = .{};

var gpa_install = std.heap.DebugAllocator(.{}).init;
const gpa = gpa_install.allocator();

pub const ClientChannel = struct {
    pub fn send(_: anytype, val: anytype) void {
        const T = @TypeOf(val);
        const val1 = gpa.create(T) catch unreachable;
        val1.* = val;
        server_mailbox = val1;
        server_mutex.unlock();
    }

    pub fn recv(_: anytype, T: type) T {
        client_mutex.lock();
        const val: *const T = @ptrCast(@alignCast((client_mailbox)));
        const val1 = val.*;
        return val1;
    }
};

pub const ServerChannel = struct {
    pub fn send(_: anytype, val: anytype) void {
        const T = @TypeOf(val);
        std.Thread.sleep(1 * std.time.ns_per_s);
        const val1 = gpa.create(T) catch unreachable;
        val1.* = val;
        client_mailbox = val1;
        client_mutex.unlock();
    }

    pub fn recv(_: anytype, T: type) T {
        server_mutex.lock();
        const val: *const T = @ptrCast(@alignCast((server_mailbox)));
        const val1 = val.*;
        return val1;
    }
};
