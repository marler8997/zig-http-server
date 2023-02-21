const builtin = @import("builtin");
const std = @import("std");

const http = @import("http.zig");
const server = @import("server.zig");

const fdeventer = @import("fdeventer.zig");
const FdEventer = fdeventer.FdEventer(*Handler);

const Gpa = std.heap.GeneralPurposeAllocator(.{});

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const log_to_stdout = false;
var stdout_mutex = if (log_to_stdout) std.Thread.Mutex{} else void;

fn handlePrintErr(err: anytype) noreturn {
    std.debug.panic("log to stdout failed with {s}", .{@errorName(err)});
}
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const now = std.time.timestamp();
    const level_txt = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const unbuffered_writer = if (log_to_stdout) std.io.getStdOut().writer() else std.io.getStdErr().writer();
    var bw = std.io.BufferedWriter(300, @TypeOf(unbuffered_writer)){ .unbuffered_writer = unbuffered_writer };
    const mutex = if (log_to_stdout) &stdout_mutex else std.debug.getStderrMutex();
    mutex.lock();
    defer mutex.unlock();
    bw.writer().print("{}: ", .{now}) catch |e| handlePrintErr(e);
    bw.writer().print(level_txt ++ prefix2 ++ format ++ "\n", args) catch |e| handlePrintErr(e);
    bw.flush() catch |e| handlePrintErr(e);
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }
    if (builtin.os.tag == .linux) {
        std.os.close(0); // close stdin, we don't need it
        if (!log_to_stdout) {
            std.os.close(1); // we don't need stdout
            // we do want stderr cause zig logs things there
        }

        // disable SIGPIPE (TODO: zig will do this automatically after my PR is released)
        const act = std.os.Sigaction{
            .handler = .{ .handler = std.os.SIG.IGN },
            .mask = std.os.empty_sigset,
            .flags = std.os.SA.SIGINFO,
        };
        try std.os.sigaction(std.os.SIG.PIPE, &act, null);
    }


    //var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//    const all_args = try std.process.argsAlloc(arena.allocator());
//    if (all_args.len <= 1) {
//        try std.io.getStdErr().writer().writeAll("Usage: webserver ROOT_PATH\n");
//        std.os.exit(0xff);
//    }
//    const args = all_args[1..];
//    if (args.len != 1) {
//        std.log.err("expected 1 cmdline argument but got {}", .{args.len});
//        std.os.exit(0xff);
//    }

    var gpa = Gpa{};
    defer _ = gpa.deinit();

    // TODO: support custom listen address
    //const port = 80;
    const port = 8080;
    const listen_addr = try std.net.Address.parseIp("0.0.0.0", port);
    std.log.info("listen address is {}", .{listen_addr});
    const listen_sock = try server.createListenSock(listen_addr);
    // no need to close

    var eventer = try FdEventer.init();
    defer eventer.deinit();

    var listen_handler = ListenHandler{
        .sock = listen_sock,
        .eventer = &eventer,
        .gpa = &gpa,
    };
    try eventer.add(listen_sock, .read, &listen_handler.base);

    while (true) {
        const max_events = 100;
        var events: [max_events]FdEventer.Event = undefined;
        const count = try eventer.wait(max_events, &events);
        for (events[0 .. count]) |*event| {
            try event.data().*.onReady(event.data().*);
        }
    }
}

pub const Handler = struct {
    onReady: *const fn(handler: *Handler) anyerror!void,
};

const ListenHandler = struct {
    base: Handler = .{ .onReady = onReady },
    sock: std.os.socket_t,
    eventer: *FdEventer,
    gpa: *Gpa,
    fn onReady(base: *Handler) anyerror!void {
        const self = @fieldParentPtr(ListenHandler, "base", base);
        var from: std.net.Address = undefined;
        var fromlen: std.os.socklen_t = @sizeOf(@TypeOf(from));
        // TODO: maybe handle some of the errors we could get?
        const new_sock = try std.os.accept(self.sock, &from.any, &fromlen, 0);
        // TODO: do we ened to tell eventer that we closed the socket?
        errdefer server.shutCloseSock(new_sock);
        std.log.info("s={}: got new connection from {}", .{new_sock, from});
        const new_handler = try self.gpa.allocator().create(DataHandler);
        errdefer self.gpa.allocator().destroy(new_handler);
        new_handler.* = .{
            .sock = new_sock,
            .gpa = self.gpa,
        };
        try self.eventer.add(new_sock, .read, &new_handler.base);
    }
};

// helps detur Denial of Service
const max_request_header_len = 4096 * 100;

const DataHandler = struct {
    base: Handler = .{ .onReady = onReady },
    sock: std.os.socket_t,
    gpa: *Gpa,
    al: std.ArrayListUnmanaged(u8) = .{},
    pub fn deinit(self: *DataHandler) void {
        // TODO: does the eventer need to know we've been closed?
        std.log.info("s={}: shutdown/close", .{self.sock});
        server.shutCloseSock(self.sock);
        self.al.deinit(self.gpa.allocator());
        self.gpa.allocator().destroy(self);
    }
    fn onReady(base: *Handler) anyerror!void {
        const self = @fieldParentPtr(DataHandler, "base", base);

        // TODO: just close the client if we run out of memory
        try self.al.ensureUnusedCapacity(self.gpa.allocator(), 4096);

        //var buf: [std.mem.page_size]u8 = undefined;
        // TODO: maybe handle some of these errors
        const received = server.readSock(self.sock, self.al.unusedCapacitySlice(), 0) catch |err| switch (err) {
            error.ConnectionResetByPeer => {
                std.log.info("s={}: connection reset", .{self.sock});
                self.deinit();
                return;
            },
            else => |e| return e,
        };
        if (received == 0) {
            std.log.info("s={}: closed", .{self.sock});
            self.deinit();
            return;
        }

        self.al.items.len += received;
        std.log.info("s={}: got {} bytes", .{self.sock, received});

        const end_of_headers = http.findEndOfHeaders(self.al.items, received) orelse {
            if (self.al.items.len > max_request_header_len) {
                std.log.info("s={}: headers exceeded max len {}, closing", .{self.sock, max_request_header_len});
                self.deinit();
            }
            return;
        };
        try self.onAllHeadersReceived(end_of_headers);
    }

    fn onAllHeadersReceived(self: *DataHandler, end_of_headers: usize) !void {
        const request = self.al.items[0 .. end_of_headers];

        const uri_line = http.parseUriLine(request) catch |err| {
            try server.sendHttpResponse(self.sock, .{ .keep_alive = false }, "400 Bad Request", .text, @errorName(err));
            self.deinit();
            return;
        };

        const headers = request[uri_line.end()..end_of_headers-2];
        var request_options = server.RequestOptions {
            .keep_alive = false,
        };
        var content_len: usize = 0;

        //std.log.info("s={}: ------------- GET '{s}' -----------------", .{self.sock, uri_line.uri(request)});
        var header_it = http.HeaderIterator{ .headers = headers };
        while (header_it.next() catch |err| {
            try server.sendHttpResponse(self.sock, .{ .keep_alive = false }, "400 Bad Request", .text, @errorName(err));
            self.deinit();
            return;
        }) |header| {
            //std.log.info("s={}: {s}: {s}", .{self.sock, header.name, header.value});
            if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                if (std.mem.eql(u8, header.value, "keep-alive")) {
                    request_options.keep_alive = true;
                } else if (std.mem.eql(u8, header.value, "close")) {
                    request_options.keep_alive = false;
                } else {
                    try server.sendHttpResponseFmt(self.sock, .{ .keep_alive = false }, "400 Bad Request",
                        .text, "unknown Connection header value '{s}'", .{header.value});
                    self.deinit();
                    return;
                }
            } else if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
                @panic("todo");
            }
        }
        //std.log.info("s={}: ---------------------------------------", .{self.sock});

        if (content_len > 0) {
            @panic("todo: non-zero content-length");
        }
        switch (try handleRequest(self.sock, request, uri_line, request_options)) {
            .close => {
                self.deinit();
                return;
            },
            .can_keep_alive => {
                if (self.al.items.len > request.len) {
                    @panic("todo");
                }
                self.al.items.len = 0;
            },
        }
    }
};

const HandleRequestResult = enum {
    close,
    can_keep_alive,
};
fn handleRequest(
    sock: std.os.socket_t,
    request: []const u8,
    uri_line: http.UriLine,
    opt: server.RequestOptions,
) !HandleRequestResult {
    const http_method = uri_line.method(request);
    const uri_str = uri_line.uri(request);
    std.log.info("{s} {s}", .{http_method, uri_str});

    if (!std.mem.startsWith(u8, http_method, "GET")) {
        try server.sendHttpResponseFmt(sock, opt, "501 Not Implemented", .text, "HTTP method '{s}' not implemented", .{http_method});
        return .can_keep_alive;
    }

    const uri = http.Uri.parse(uri_str) catch |err| {
        try server.sendHttpResponseFmt(sock, opt, "400 Bad Request", .text, "failed to parse '{s}' as URI with {s}", .{uri_str, @errorName(err)});
        return .can_keep_alive;
    };

    const path = if (std.mem.eql(u8, uri.path, "/")) "/index.html" else uri.path;

    std.debug.assert(path.len >= 2);
    std.debug.assert(path[0] == '/');
    const path_relative = path[1..];

    const file = std.fs.cwd().openFile(path_relative, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try server.sendHttpResponseNoContent(sock, opt, "404 Not Found");
            return .can_keep_alive;
        },
        else => |e| return e,
    };
    defer file.close();
    
    try server.sendHttpResponseFile(file, sock, opt, path);
    return .can_keep_alive;
}

fn matchArg(arg: []const u8, comptime against: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, against ++ "="))
        arg[against.len + 1..] else null;
}
