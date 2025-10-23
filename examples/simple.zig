const std = @import("std");
const ps = @import("polysession");
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;
const core = @import("core.zig");
const ServerContext = core.ServerContext;
const ClientContext = core.ClientContext;
const Runner = core.Runner;
const curr_id = core.curr_id;

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var arg_iter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next();
    if (arg_iter.next()) |arg_str| {
        std.debug.print("arg_str {s}\n", .{arg_str});
        if (std.mem.eql(u8, "dot", arg_str)) {
            const graph: ps.Graph = try core.graph(gpa);
            const graph_fs = try std.fs.cwd().createFile("t.dot", .{});
            var graph_fs_writer = graph_fs.writer(try gpa.alloc(u8, 1 << 20));
            try graph.generateDot(&graph_fs_writer.interface);
            try graph_fs_writer.interface.flush();
        }
    }

    //create tmp dir
    var tmp_dir_instance = std.testing.tmpDir(.{});
    defer tmp_dir_instance.cleanup();
    const tmp_dir = tmp_dir_instance.dir;

    {
        const read_file = try tmp_dir.createFile("test_read", .{});
        defer read_file.close();
        const str: [1024 * 1024]u8 = @splat(65);
        for (0..100) |_| {
            try read_file.writeAll(&str);
        }
    }

    //Server

    var threaded = std.Io.Threaded.init(gpa);
    const io = threaded.io();

    const net = std.Io.net;
    const localhost = try net.IpAddress.parse("127.0.0.1", 8881);

    var server = try localhost.listen(io, .{});
    defer server.deinit(io);
    //

    const S = struct {
        fn clientFn(io_: std.Io, server_address: net.IpAddress, dir: std.fs.Dir) !void {
            const socket = try server_address.connect(io_, .{ .mode = .stream });
            defer socket.close(io_);

            var reader_buf: [1024 * 1024 * 2]u8 = undefined;
            var writer_buf: [1024 * 1024 * 2]u8 = undefined;

            var stream_reader = socket.reader(io_, &reader_buf);
            var stream_writer = socket.writer(io_, &writer_buf);

            const write_file = try dir.createFile("test_write", .{});
            defer write_file.close();

            var file_writer_buf: [1024 * 1024 * 2]u8 = undefined;

            var file_writer = write_file.writer(&file_writer_buf);

            var client_context: ClientContext = .{
                .pingpong = .{ .client_counter = 0 },
                .recv_context = .{
                    .writer = &file_writer.interface,
                },
            };

            try Runner.runProtocol(
                .client,
                true,
                .{
                    .server = StreamChannel{
                        .reader = &stream_reader.interface,
                        .writer = &stream_writer.interface,
                        .log = false,
                    },
                },
                curr_id,
                &client_context,
            );
        }
    };

    var t = try io.concurrent(S.clientFn, .{ io, localhost, tmp_dir });
    defer t.await(io) catch unreachable;

    //

    var client = try server.accept(io);
    defer client.close(io);

    var reader_buf: [1024 * 1024 * 2]u8 = undefined;
    var writer_buf: [1024 * 1024 * 2]u8 = undefined;

    var stream_reader = client.reader(io, &reader_buf);
    var stream_writer = client.writer(io, &writer_buf);

    var file_reader_buf: [1024 * 1024 * 2]u8 = undefined;

    const read_file = try tmp_dir.openFile("test_read", .{});
    defer read_file.close();

    var file_reader = read_file.reader(io, &file_reader_buf);

    var server_context: ServerContext = .{
        .pingpong = .{ .server_counter = 0 },
        .send_context = .{
            .reader = &file_reader.interface,
            .file_size = (try read_file.stat()).size,
        },
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        .server,
        true,
        .{
            .client = StreamChannel{
                .reader = &stream_reader.interface,
                .writer = &stream_writer.interface,
                .log = false,
            },
        },
        curr_id,
        &server_context,
    });

    defer stid.join();
}
