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

    //Server
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    var server = try localhost.listen(.{});
    defer server.deinit();
    //

    const S = struct {
        fn clientFn(server_address: net.Address) !void {
            const socket = try net.tcpConnectToAddress(server_address);
            defer socket.close();

            var reader_buf: [16]u8 = undefined;
            var writer_buf: [16]u8 = undefined;

            var stream_reader = socket.reader(&reader_buf);
            var stream_writer = socket.writer(&writer_buf);

            var client_context: ClientContext = .{
                .client_counter = 0,
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

    const t = try std.Thread.spawn(.{}, S.clientFn, .{server.listen_address});
    defer t.join();

    //

    var client = try server.accept();
    defer client.stream.close();

    var reader_buf: [16]u8 = undefined;
    var writer_buf: [16]u8 = undefined;

    var stream_reader = client.stream.reader(&reader_buf);
    var stream_writer = client.stream.writer(&writer_buf);

    var server_context: ServerContext = .{
        .server_counter = 0,
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        .server,
        StreamChannel{
            .reader = stream_reader.interface(),
            .writer = &stream_writer.interface,
            .log = true,
        },
        curr_id,
        &server_context,
    });

    defer stid.join();
}
