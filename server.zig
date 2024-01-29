const builtin = @import("builtin");
const std = @import("std");

const http = @import("http.zig");

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

pub fn createListenSock(addr: std.net.Address) !std.os.socket_t {
    const sock = try std.os.socket(addr.any.family, std.os.SOCK.STREAM, std.os.IPPROTO.TCP);
    errdefer std.os.close(sock);

    if (builtin.os.tag != .windows) {
        try std.os.setsockopt(sock, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.os.bind(sock, &addr.any, addr.getOsSockLen());
    try std.os.listen(sock, 128);
    return sock;
}

pub fn shutCloseSock(sock: std.os.socket_t) void {
    std.os.shutdown(sock, .both) catch {};
    std.os.close(sock);
}

const ContentType = enum {
    json,
    text,
    pub fn str(self: ContentType) []const u8 {
        return switch (self) {
            .json => "application/json",
            .text => "text/plain",
        };
    }
};
pub const RequestOptions = struct {
    keep_alive: bool,
};
pub fn sendHttpResponseFmt(
    sock: std.os.socket_t,
    request_options: RequestOptions,
    code: []const u8,
    content_type: ContentType,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buf: [4096]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, fmt, args) catch "[content-too-long]";
    try sendHttpResponse(sock, request_options, code, content_type, content);
}
pub fn sendHttpResponse(
    sock: std.os.socket_t,
    request_options: RequestOptions,
    code: []const u8,
    content_type: ContentType,
    content: []const u8,
) !void {
    const connection = if (request_options.keep_alive) "keep-alive" else "close";
    const sock_writer = SocketWriter{ .context = sock };
    var bw = std.io.BufferedWriter(300, @TypeOf(sock_writer)){ .unbuffered_writer = sock_writer };
    std.log.info("Sending HTTP Reponse '{s}', Content-Length={}", .{code, content.len});
    try bw.writer().print(
        "HTTP/1.1 {s}\r\nConnection: {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\n\r\n{s}",
        .{code, connection, content_type.str(), content.len, content});
    try bw.flush();
}
pub fn sendHttpResponseNoContent(
    sock: std.os.socket_t,
    request_options: RequestOptions,
    code: []const u8,
) !void {
    const connection = if (request_options.keep_alive) "keep-alive" else "close";
    const sock_writer = SocketWriter{ .context = sock };
    var bw = std.io.BufferedWriter(300, @TypeOf(sock_writer)){ .unbuffered_writer = sock_writer };
    std.log.info("Sending HTTP Reponse '{s}'", .{code});
    try bw.writer().print("HTTP/1.1 {s}\r\nConnection: {s}\r\nContent-Length: 0\r\n\r\n", .{code, connection});
    try bw.flush();
}

pub fn sendHttpResponseFile(
    file: std.fs.File,
    sock: std.os.socket_t,
    opt: RequestOptions,
    path: []const u8,
) !void {
    // TODO: dont' return error if this fails?
    const file_size = try file.getEndPos();
    const sock_writer = SocketWriter{ .context = sock };

    {
        const connection = if (opt.keep_alive) "keep-alive" else "close";
        var buf: [400]u8 = undefined;
        const headers = std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 200 OK\r\nConnection: {s}\r\nContent-Length: {}\r\n\r\n",
            .{ connection, file_size },
        ) catch unreachable;
        std.log.info("Sending file '{s}', header is {} bytes", .{path, headers.len});
        try sock_writer.writeAll(headers);
    }

    // TODO: use sendfile when possible
    var buf: [std.mem.page_size]u8 = undefined;
    var remaining = file_size;
    while (remaining > 0) {
        const next_len = @min(remaining, buf.len);

        // TODO: handle errors better
        const len = try file.read(&buf);
        if (len == 0) {
            std.log.err("file read returned 0 with {} bytes left", .{remaining});
            return error.GotEofBeforeExpectedEndOfFile;
        }
        //std.log.info("sending {} bytes", .{len});
        try sock_writer.writeAll(buf[0 .. len]);
        remaining -= next_len;
    }
}

const WriteSockResult = @typeInfo(@TypeOf(writeSock)).Fn.return_type.?;
pub const SocketWriter = std.io.Writer(
    std.os.socket_t,
    @typeInfo(WriteSockResult).ErrorUnion.error_set,
    writeSock,
);
pub fn writeSock(sock: std.os.socket_t, buf: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        const result = std.os.windows.sendto(sock, buf.ptr, buf.len, 0, null, 0);
        if (result != std.os.windows.ws2_32.SOCKET_ERROR)
            return @intCast(result);
        switch (std.os.windows.ws2_32.WSAGetLastError()) {
            else => |err| return std.os.windows.unexpectedWSAError(err),
        }
    }
    return std.os.send(sock, buf, 0);
}
pub fn readSock(sock: std.os.socket_t, buf: []u8, flags: u32) !usize {
    if (builtin.os.tag == .windows) {
        const result = std.os.windows.recvfrom(sock, buf.ptr, buf.len, flags, null, null);
        if (result != std.os.windows.ws2_32.SOCKET_ERROR)
            return @intCast(result);
        switch (std.os.windows.ws2_32.WSAGetLastError()) {
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return std.os.windows.unexpectedWSAError(err),
        }
    }
    return std.os.recv(sock, buf, flags);
}


