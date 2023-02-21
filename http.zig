const std = @import("std");
const testing = std.testing;

const end_of_headers = "\r\n\r\n";

pub fn findEndOfHeaders(data: []const u8, last_recv_len: usize) ?usize {
    var i: usize = data.len - last_recv_len;

    // rewind in case we already had \r\n\r
    if (i >= (end_of_headers.len - 1)) {
        i -= (end_of_headers.len - 1);
    } else {
        i = 0;
    }

    while (i + 3 < data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i .. i + end_of_headers.len], end_of_headers)) {
            return i + end_of_headers.len;
        }
    }
    return null;
}

const http_version = "HTTP/1.1\r\n";

pub const ParseUriLineError = error {
    Unfinished,
    MethodTooLong,
    UnsupportedHttpVersion,
};
pub const UriLine = struct {
    method_len: u8,
    uri_limit: u16,

    pub fn method(self: UriLine, request: []const u8) []const u8 {
        return request[0 .. self.method_len];
    }
    pub fn uri(self: UriLine, request: []const u8) []const u8 {
        return request[self.method_len + 1 .. self.uri_limit];
    }
    pub fn end(self: UriLine) usize {
        return @intCast(usize, self.uri_limit) + 1 + http_version.len;
    }
};
pub fn parseUriLine(request: []const u8) ParseUriLineError!UriLine {
    const request_limit = std.math.min(request.len, std.math.maxInt(u16));

    var offset : u16 = 0;
    while (true) : (offset += 1) {
        if (offset >= request_limit) return error.Unfinished;
        if (request[offset] == ' ') break;
    }
    if (offset > std.math.maxInt(u8))
        return error.MethodTooLong;
    const method_len = @intCast(u8, offset);
    offset += 1;

    while (true) : (offset += 1) {
        if (offset >= request_limit) return error.Unfinished;
        if (request[offset] == ' ') break;
    }
    const uri_limit = offset;

    offset += 1;
    const headers_start = @intCast(usize, offset) + http_version.len;
    if (headers_start > request_limit)
        return error.Unfinished;
    if (!std.mem.eql(u8, request[offset..headers_start], http_version))
        return error.UnsupportedHttpVersion;

    return UriLine{
        .method_len = method_len,
        .uri_limit = uri_limit,
    };
}


pub const Header = struct {
    name: []const u8,
    value: []const u8,
};
pub const HeaderIterator = struct {
    headers: []const u8,
    pos: usize = 0,

    pub const Error = error {
        HttpHeaderMissingColon,
        HttpHeaderMissingNewline,
        HttpHeaderNoSpaceAfterColon,
    };
    pub fn next(self: *HeaderIterator) Error!?Header {
        if (self.pos == self.headers.len) return null;

        // find colon
        var i = self.pos;
        while (true) {
            if (self.headers[i] == ':') break;
            if (self.headers[i] == '\n') return error.HttpHeaderMissingColon;
            i += 1;
            if (i == self.headers.len) return error.HttpHeaderMissingColon;
        }
        const name_end = i;

        // skip whitespace
        while (true) {
            i += 1;
            if (i == self.headers.len) return error.HttpHeaderMissingNewline;
            if (self.headers[i] != ' ') break;
        }

        const value_start = i;

        // find newline
        while (true) {
            if (self.headers[i] == '\n') break;
            i += 1;
            if (i ==  self.headers.len) return error.HttpHeaderMissingNewline;
        }

        var value_end = i;
        if (value_end > value_start and self.headers[value_end - 1] == '\r')
            value_end -= 1;
        const name_start = self.pos;
        self.pos = i + 1;
        return .{
            .name = self.headers[name_start .. name_end],
            .value = self.headers[value_start .. value_end],
        };
    }
};

fn getUriPathOffset(uri: []const u8) ?usize {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == uri.len) return null;

        if (uri[i] == ':') {
            if (std.mem.startsWith(u8, uri[i+1..], "//")) {
                i += 3;
                break;
            }
        } else if (uri[i] == '/') {
            return i;
        }
    }

    while (true) : (i += 1) {
        if (i == uri.len) return null;
        if (uri[i] == '/') return i;
    }
}

pub const Uri = struct {
    path: []const u8,
    args: ?[]const u8,

    pub const ParseError = error {
        UriMissingPath,
    };
    pub fn parse(slice: []const u8) ParseError!Uri {
        const path_start = getUriPathOffset(slice) orelse return error.UriMissingPath;
        std.debug.assert(slice[path_start] == '/');
        var i = path_start + 1;
        while (true) : (i += 1) {
            if (i == slice.len) return .{
                .path = slice[path_start .. i],
                .args = null,
            };
            if (slice[i] == '?') return .{
                .path = slice[path_start .. i],
                .args = slice[i+1..],
            };
        }
    }
};
