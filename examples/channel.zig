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
