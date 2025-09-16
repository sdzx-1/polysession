const std = @import("std");
const ps = @import("root.zig");
const net = std.net;

pub fn main() !void {
    var buffA: [50]u8 = @splat(0);
    var buffB: [50]u8 = @splat(0);

    var mvarA: Mvar = .{ .buff = &buffA, .size = 0 };
    var mvarB: Mvar = .{ .buff = &buffB, .size = 0 };

    var client_channel: MvarChannel = .{ .mvar_a = &mvarA, .mvar_b = &mvarB };
    var server_channel: MvarChannel = .{ .mvar_a = &mvarB, .mvar_b = &mvarA };

    const S = struct {
        fn clientFn(mv_channel: *MvarChannel) !void {
            var client_context: ClientContext = .{
                .client_counter = 0,
            };

            try Runner.runProtocol(.client, &mv_channel, true, curr_id, &client_context);
        }
    };

    const t = try std.Thread.spawn(.{}, S.clientFn, .{&client_channel});
    defer t.join();

    //
    var server_context: ServerContext = .{
        .server_counter = 0,
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{ .server, &server_channel, true, curr_id, &server_context });
    defer stid.join();
}

pub const Codec = struct {
    pub fn encode(writer: *std.Io.Writer, state_id: anytype, val: anytype) !void {
        const id: u8 = @intFromEnum(state_id);
        switch (val) {
            inline else => |msg, tag| {
                try writer.writeByte(id);
                try writer.writeByte(@intFromEnum(tag));
                const data = msg.data;
                switch (@typeInfo(@TypeOf(data))) {
                    .void => {},
                    .int => {
                        try writer.writeInt(@TypeOf(data), data, .little);
                    },
                    .@"struct" => {
                        try data.encode(writer);
                    },
                    else => @compileError("Not impl!"),
                }
            },
        }

        try writer.flush();
    }

    pub fn decode(reader: *std.Io.Reader, state_id: anytype, T: type) !T {
        const id: u8 = @intFromEnum(state_id);
        const sid = try reader.takeByte();
        if (id != sid) return error.IncorrectStatusReceived;
        const recv_tag_num = try reader.takeByte();
        const tag: std.meta.Tag(T) = @enumFromInt(recv_tag_num);
        switch (tag) {
            inline else => |t| {
                const Data = @FieldType(std.meta.TagPayload(T, t), "data");
                switch (@typeInfo(Data)) {
                    .void => {
                        return @unionInit(T, @tagName(t), .{ .data = {} });
                    },
                    .int => {
                        const data = try reader.takeInt(Data, .little);
                        return @unionInit(T, @tagName(t), .{ .data = data });
                    },
                    .@"struct" => {
                        const data = try Data.decode(reader);
                        return @unionInit(T, @tagName(t), .{ .data = data });
                    },
                    else => @compileError("Not impl!"),
                }
            },
        }
    }
};

pub const MvarChannel = struct {
    mvar_a: *Mvar,
    mvar_b: *Mvar,

    pub fn recv(self: *@This(), state_id: anytype, T: type) !T {
        return try self.mvar_a.recv(state_id, T);
    }

    pub fn send(self: *@This(), state_id: anytype, val: anytype) !void {
        try self.mvar_b.send(state_id, val);
    }
};

pub const Mvar = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    state: MvarState = .empty,
    buff: []u8,
    size: usize,

    pub const MvarState = enum { full, empty };

    pub fn recv(self: *@This(), state_id: anytype, T: type) !T {
        self.mutex.lock();

        while (self.state == .empty) {
            self.cond.wait(&self.mutex);
        }

        var reader = std.Io.Reader.fixed(self.buff);
        const val = try Codec.decode(&reader, state_id, T);

        self.state = .empty;
        self.mutex.unlock();
        self.cond.signal();
        return val;
    }

    pub fn send(self: *@This(), state_id: anytype, val: anytype) !void {
        self.mutex.lock();

        while (self.state == .full) {
            self.cond.wait(&self.mutex);
        }

        var writer = std.Io.Writer.fixed(self.buff);
        try Codec.encode(&writer, state_id, val);
        self.size = writer.buffered().len;

        self.state = .full;
        self.mutex.unlock();
        self.cond.signal();
    }
};

//example PingPong

pub fn PingPong(Data_: type, State_: type) type {
    return ps.Session("PingPong", Data_, State_);
}

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

const PongFn = struct {
    pub fn process(ctx: *ServerContext) !i32 {
        ctx.server_counter += 1;
        return ctx.server_counter;
    }

    pub fn preprocess(ctx: *ClientContext, val: i32) !void {
        ctx.client_counter = val;
    }
};

const St = union(enum) {
    ping: PingPong(i32, ps.Cast("pong", .server, PongFn, PingPong(i32, @This()))),
    exit: PingPong(void, ps.Exit),

    pub const agency: ps.Role = .client;

    pub fn process(ctx: *ClientContext) !@This() {
        ctx.client_counter += 1;
        // if (ctx.client_counter > 10) return error.TestError;
        if (ctx.client_counter >= 20) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess(ctx: *ServerContext, msg: @This()) !void {
        switch (msg) {
            .ping => |val| ctx.server_counter = val.data,
            .exit => {},
        }
    }
};

const EnterFsmState = PingPong(void, St);

const Runner = ps.Runner(EnterFsmState);
const curr_id = Runner.idFromState(EnterFsmState.State);

// const ProtocolFamily = union(enum) {
//     pingpong0: PingPong(void, St),
//     pingpong1: PingPong(void, St),
//     pingpong2: PingPong(void, St),
// };

// pub const Mux = struct {
//     reader: *std.Io.Reader,
//     reader_mutex: std.Thread.Mutex,
//     reader_single: std.Thread.Condition,

//     writer: *std.Io.Writer,
//     writer_mutex: std.Thread.Mutex,
// };
