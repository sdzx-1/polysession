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

    pub fn recv_notify(self: @This()) !u8 {
        if (self.log) std.debug.print("{s} recv_notify form {s}\n", .{ self.master, self.other });
        return try self.reader.takeByte();
    }

    pub fn send_notify(self: @This(), val: u8) !void {
        try self.writer.writeByte(val);
        try self.writer.flush();
        if (self.log) std.debug.print("{s} send_notify to   {s}\n", .{ self.master, self.other });
    }

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
