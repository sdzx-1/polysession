const std = @import("std");
const Codec = @import("Codec.zig");
const net = std.net;

//stream channel

pub const StreamChannel = struct {
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    log: bool = false,
    master: []const u8 = &.{},
    other: []const u8 = &.{},

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        const res = try Codec.decode(self.reader, state_id, T);
        if (self.log) std.debug.print("{s} recv form {s}: {any}\n", .{ self.master, self.other, res });
        return res;
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        if (self.log) std.debug.print("{s} send to   {s}: {any}\n", .{ self.master, self.other, val });
        try Codec.encode(self.writer, state_id, val);
    }
};

//Mvar channel
pub const MvarChannel = struct {
    mvar_a: *Mvar,
    mvar_b: *Mvar,

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        return try self.mvar_a.recv(state_id, T);
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        try self.mvar_b.send(state_id, val);
    }
};

pub const Mvar = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    state: MvarState = .empty,
    buff: []u8,
    size: usize = 0,

    pub const MvarState = enum { full, empty };

    pub fn init(gpa: std.mem.Allocator, len: usize) !*Mvar {
        const ref = try gpa.create(Mvar);
        const buff = try gpa.alloc(u8, len);
        ref.* = .{ .buff = buff };
        return ref;
    }

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

pub fn MvarChannelMap(Role: type) type {
    return struct {
        hashmap: std.AutoArrayHashMapUnmanaged([2]u8, MvarChannel),
        log: bool = true,
        msg_delay: ?u64 = 10, //ms

        pub fn init() @This() {
            return .{ .hashmap = .empty };
        }

        //TODO: deinit

        pub fn generate_all_MvarChannel(
            self: *@This(),
            gpa: std.mem.Allocator,
            comptime buff_size: usize,
        ) !void {
            const enum_fields = @typeInfo(Role).@"enum".fields;
            var i: usize = 0;
            while (i < enum_fields.len) : (i += 1) {
                var j = i + 1;
                while (j < enum_fields.len) : (j += 1) {
                    const mvar_a = try Mvar.init(gpa, buff_size);
                    const mvar_b = try Mvar.init(gpa, buff_size);

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(i)), @as(u8, @intCast(j)) },
                        .{ .mvar_a = mvar_a, .mvar_b = mvar_b },
                    );

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(j)), @as(u8, @intCast(i)) },
                        .{ .mvar_a = mvar_b, .mvar_b = mvar_a },
                    );
                }
            }
        }

        pub fn recv(self: @This(), curr_role: Role, other: Role, state_id: anytype, T: type) !T {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            const res = try mvar_channel.recv(state_id, T);
            if (self.msg_delay) |delay| std.Thread.sleep(std.time.ns_per_ms * delay);
            return res;
        }

        pub fn send(self: @This(), curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            if (self.log) std.debug.print("statd_id: {d},  {t} send to {t}: {any}\n", .{ state_id, curr_role, other, val });
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            try mvar_channel.send(state_id, val);
        }
    };
}
