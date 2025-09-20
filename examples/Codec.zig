const std = @import("std");

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
                .pointer => |p| {
                    if (p.is_const == true and p.child == u8) {
                        const len: usize = data.len;
                        try writer.writeInt(usize, len, .little);
                        try writer.writeAll(data);
                    } else {
                        @compileError("Not impl!");
                    }
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
    std.debug.assert(id == sid);
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

                .pointer => |p| {
                    if (p.is_const == true and p.child == u8) {
                        const len = try reader.takeInt(usize, .little);
                        const str = try reader.take(len);
                        return @unionInit(T, @tagName(t), .{ .data = str });
                    } else {
                        @compileError("Not impl!");
                    }
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
