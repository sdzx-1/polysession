const std = @import("std");
const ps = @import("polysession");
const net = std.net;
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

    const graph: ps.Graph = try core.graph(gpa);
    var stdio_writer = std.fs.File.stdout().writer(&.{});
    try graph.generateDot(&stdio_writer.interface);

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
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    var server = try localhost.listen(.{});
    defer server.deinit();
    //

    const S = struct {
        fn clientFn(server_address: net.Address, dir: std.fs.Dir) !void {
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [1024 * 1024 * 2]u8 = undefined;
            var writer_buf: [1024 * 1024 * 2]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

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
                StreamChannel{
                    .reader = stream_reader.interface(),
                    .writer = &stream_writer.interface,
                    .log = false,
                },
                curr_id,
                &client_context,
            );
        }
    };

    const t = try std.Thread.spawn(.{}, S.clientFn, .{ server.listen_address, tmp_dir });
    defer t.join();

    //

    var client = try server.accept();
    defer client.stream.close();

    var reader_buf: [1024 * 1024 * 2]u8 = undefined;
    var writer_buf: [1024 * 1024 * 2]u8 = undefined;

    var stream_reader = client.stream.reader(&reader_buf);
    var stream_writer = client.stream.writer(&writer_buf);

    var file_reader_buf: [1024 * 1024 * 2]u8 = undefined;

    const read_file = try tmp_dir.openFile("test_read", .{});
    defer read_file.close();

    var file_reader = read_file.reader(&file_reader_buf);

    var server_context: ServerContext = .{
        .pingpong = .{ .server_counter = 0 },
        .send_context = .{
            .reader = &file_reader.interface,
            .file_size = (try read_file.stat()).size,
        },
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        .server,
        StreamChannel{
            .reader = stream_reader.interface(),
            .writer = &stream_writer.interface,
            .log = false,
        },
        curr_id,
        &server_context,
    });

    defer stid.join();
}
