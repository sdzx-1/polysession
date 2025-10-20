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

    log: bool = false,
    master: []const u8 = &.{},
    other: []const u8 = &.{},

    pub fn flip(self: @This()) MvarChannel {
        return .{
            .mvar_a = self.mvar_b,
            .mvar_b = self.mvar_a,
            .log = self.log,
            .master = self.other,
            .other = self.master,
        };
    }

    pub fn enable_log(self: @This()) @This() {
        var tmp = self;
        tmp.log = true;
        return tmp;
    }

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        return try self.mvar_a.recv(state_id, T, self.log, self.master, self.other);
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        try self.mvar_b.send(state_id, val, self.log, self.master, self.other);
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
        ref.* = .{
            .mutex = .{},
            .cond = .{},
            .state = .empty,
            .buff = buff,
            .size = 0,
        };

        return ref;
    }

    pub fn recv(
        self: *@This(),
        state_id: anytype,
        T: type,
        log: bool,
        master: []const u8,
        other: []const u8,
    ) !T {
        self.mutex.lock();

        while (self.state == .empty) {
            self.cond.wait(&self.mutex);
        }

        var reader = std.Io.Reader.fixed(self.buff);
        const val = try Codec.decode(&reader, state_id, T);
        if (log) std.debug.print(
            "{s} recv form {s}: {any}\n",
            .{ master, other, val },
        );

        self.state = .empty;
        self.mutex.unlock();
        self.cond.signal();
        return val;
    }

    pub fn send(
        self: *@This(),
        state_id: anytype,
        val: anytype,
        log: bool,
        master: []const u8,
        other: []const u8,
    ) !void {
        self.mutex.lock();

        while (self.state == .full) {
            self.cond.wait(&self.mutex);
        }

        if (log) std.debug.print(
            "{s} send to   {s}: {any}\n",
            .{ master, other, val },
        );
        var writer = std.Io.Writer.fixed(self.buff);
        try Codec.encode(&writer, state_id, val);
        self.size = writer.buffered().len;

        self.state = .full;
        self.mutex.unlock();
        self.cond.signal();
    }
};

pub fn ConnectChannelMap(Role: type) type {
    return struct {
        hashmap: std.AutoArrayHashMapUnmanaged([2]u8, MvarChannel),

        pub fn init() @This() {
            return .{ .hashmap = .empty };
        }

        pub fn enable_log(self: @This(), role: Role) void {
            self.set_log(role, true);
        }

        pub fn set_log(self: @This(), role: Role, val: bool) void {
            var iter = self.hashmap.iterator();
            while (iter.next()) |entry| {
                if (entry.key_ptr.*[0] == @as(u8, @intFromEnum(role))) {
                    entry.value_ptr.log = val;
                }
            }
        }

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
                        .{
                            .mvar_a = mvar_a,
                            .mvar_b = mvar_b,
                            .log = false,
                            .master = @tagName(@as(Role, @enumFromInt(i))),
                            .other = @tagName(@as(Role, @enumFromInt(j))),
                        },
                    );

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(j)), @as(u8, @intCast(i)) },
                        .{
                            .mvar_a = mvar_b,
                            .mvar_b = mvar_a,
                            .log = false,
                            .master = @tagName(@as(Role, @enumFromInt(j))),
                            .other = @tagName(@as(Role, @enumFromInt(i))),
                        },
                    );
                }
            }
        }

        pub fn recv(self: @This(), curr_role: Role, other: Role, state_id: anytype, T: type) !T {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            return try mvar_channel.recv(state_id, T);
        }

        pub fn send(self: @This(), curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            try mvar_channel.send(state_id, val);
        }
    };
}
