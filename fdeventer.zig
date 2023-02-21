const builtin = @import("builtin");
const std = @import("std");
const os = std.os;

pub const EventKind = enum {
    read, write//, err,
};

pub fn FdEventer(comptime EventData: type) type {
    return switch (builtin.os.tag) {
        .linux => FdEventerEpoll(EventData),
        .windows => FdEventerSelectWindows(EventData),
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly =>
            FdEventerKqueue(EventData),
        else =>  @compileError("FdEventer not implemented for os " ++ @tagName(builtin.os.tag)),
    };
}

pub fn FdEventerEpoll(comptime EventData: type) type {
    if (@sizeOf(EventData) > @sizeOf(os.linux.epoll_data))
        @compileError("@sizeOf(EventData) this big is not implemented");

    return struct {
        const Self = @This();

        epoll_fd: os.fd_t,

        pub fn init() !Self {
            return Self{
                .epoll_fd = try os.epoll_create1(os.linux.EPOLL.CLOEXEC),
            };
        }

        pub fn deinit(self: *Self) void {
            os.close(self.epoll_fd);
            self.epoll_fd = -1;
        }

        fn eventKindToEpollEvents(kind: EventKind) u32 {
            return switch (kind) {
                .read => os.linux.EPOLL.IN,
                .write => os.linux.EPOLL.OUT,
                //.read => os.linux.EPOLL.in,
            };
        }

        pub fn add(self: Self, fd: os.fd_t, kind: EventKind, data: EventData) !void {
            var event = os.linux.epoll_event {
                .events = eventKindToEpollEvents(kind),
                .data = undefined,
                //os.linux.epoll_data { .ptr = @ptrToInt(handler) },
            };
            if (@sizeOf(EventData) > 0) {
                comptime { std.debug.assert(@sizeOf(os.linux.epoll_data) >= @sizeOf(EventData)); }
                std.mem.copy(
                    u8,
                    @ptrCast([*]u8, &event.data)[0 .. @sizeOf(@TypeOf(event.data))],
                    @ptrCast([*]const u8, &data)[0 .. @sizeOf(EventData)],
                );
            }
            try os.epoll_ctl(self.epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &event);
        }

        pub const Event = extern struct {
            _epoll_event: os.linux.epoll_event,
            pub fn data(self: *Event) *align(1) EventData {
                return @ptrCast(*align(1) EventData, &self._epoll_event.data);
            }
        };
        comptime {
            std.debug.assert(@sizeOf(Event) == @sizeOf(os.linux.epoll_event));
            std.debug.assert(@alignOf(Event) == @alignOf(os.linux.epoll_event));
        }
        pub fn wait(self: Self, comptime MaxCount: usize, events: *[MaxCount]Event) !usize {
            const count = os.epoll_wait(self.epoll_fd, @ptrCast(*[MaxCount]os.linux.epoll_event, events), -1);
            std.debug.assert(count != 0); // should be impossible since we have no timeout
            return count;
        }
    };
}

pub fn FdEventerKqueue(comptime EventData: type) type {
    return struct {
        const Self = @This();

        //epoll_fd: os.fd_t,

        pub fn init() !Self {
            @panic("todo");
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            @panic("todo");
        }

        pub fn add(self: Self, fd: os.fd_t, kind: EventKind, data: EventData) !void {
            _ = self; _ = fd; _ = kind; _ = data;
            @panic("todo");
        }

        pub const Event = extern struct {
            pub fn data(self: *Event) *align(1) EventData {
                _ = self;
                @panic("todo");
            }
        };
        pub fn wait(self: Self, comptime MaxCount: usize, events: *[MaxCount]Event) !usize {
            _ = self; _ = events;
            @panic("todo");
        }
    };
}

const windows = struct {
    pub const FdSet = extern struct {
        count: usize,
        array: [0]os.socket_t,
        pub fn fd_ptr(self: *FdSet) [*]os.socket_t {
            return @ptrCast([*]os.socket_t, &self.array);
        }
        pub fn fd_slice(self: *FdSet) []os.socket_t {
            return self.fd_ptr()[0 .. self.count];
        }

        // has to be mutable to make type system happy
        pub var none = FdSet{ .count = 0, .array = undefined };
    };
    pub const fd_set_array_offset = @offsetOf(FdSet, "array");
    pub const FdListUnmanaged = extern struct {
        socket_capacity: usize = 0,
        set: *FdSet = &FdSet.none,

        pub fn deinit(self: *FdListUnmanaged, allocator: std.mem.Allocator) void {
            if (self.socket_capacity > 0) {
                allocator.free(self.allocatedSlice());
            }
        }

        fn allocatedSlice(self: FdListUnmanaged) []u8 {
            std.debug.assert(self.socket_capacity > 0);
            const byte_len = fd_set_array_offset + @sizeOf(os.socket_t) * self.socket_capacity;
            return @ptrCast([*]u8, self.set)[0 .. byte_len];
        }

        pub fn add(
            self: *FdListUnmanaged,
            allocator: std.mem.Allocator,
            fd: os.socket_t,
        ) std.mem.Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, self.set.count + 1);
            self.set.fd_ptr()[self.set.count] = fd;
            self.set.count += 1;
        }

        // does not copy
        pub fn ensureTotalCapacity(
            self: *FdListUnmanaged,
            allocator: std.mem.Allocator,
            new_socket_capacity: usize,
        ) std.mem.Allocator.Error!void {
            if (self.socket_capacity >= new_socket_capacity) return;
            var better_socket_capacity = self.socket_capacity;
            while (true) {
                better_socket_capacity +|= better_socket_capacity / 2 + 8;
                if (better_socket_capacity >= new_socket_capacity) break;
            }
            return self.ensureTotalCapacityPrecise(allocator, better_socket_capacity);
        }

        pub fn ensureTotalCapacityPrecise(
            self: *FdListUnmanaged,
            allocator: std.mem.Allocator,
            new_socket_capacity: usize,
        ) std.mem.Allocator.Error!void {
            if (self.socket_capacity >= new_socket_capacity) return;
            const new_byte_capacity = fd_set_array_offset + @sizeOf(os.socket_t) * new_socket_capacity;
            if (self.socket_capacity > 0 and allocator.resize(self.allocatedSlice(), new_byte_capacity)) {
                // success
            } else {
                const new_memory = try allocator.alignedAlloc(u8, @alignOf(FdSet), new_byte_capacity);
                const new_set = @ptrCast(*FdSet, new_memory.ptr);
                if (self.socket_capacity > 0) {
                    new_set.count = self.set.count;
                    std.mem.copy(os.socket_t, new_set.fd_slice(), self.set.fd_slice());
                    allocator.free(self.allocatedSlice());
                } else {
                    new_set.count = 0;
                }
                self.set = new_set;
            }
            self.socket_capacity = new_socket_capacity;
        }
    };

    pub const timeval = extern struct {
        tv_sec: c_long,
        tv_usec: c_long,
    };
    pub extern "ws2_32" fn select(
        nfds: c_int, // ignored
        readfds: ?*FdSet,
        writefds: ?*FdSet,
        exceptfds: ?*FdSet,
        timeout: ?*const timeval,
    ) callconv(os.windows.WINAPI) c_int;
};

pub fn FdEventerSelectWindows(comptime EventData: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        fds: std.ArrayListUnmanaged(struct {
            fd: os.socket_t,
            events: EventKind,
        }) = .{},
        fd_map: std.AutoHashMapUnmanaged(os.socket_t, EventData) = .{},
        read_fd_set: windows.FdListUnmanaged = .{},

        pub fn init() !Self {
            return Self{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.read_fd_set.deinit(self.arena.allocator());
            self.fd_map.deinit(self.arena.allocator());
            self.fds.deinit(self.arena.allocator());
            self.arena.deinit();
        }

        pub fn add(self: *Self, fd: os.socket_t, kind: EventKind, data: EventData) !void {
            try self.fds.append(
                self.arena.allocator(),
                .{ .fd = fd, .events = kind },
            );
            errdefer self.fds.items.len -= 1;
            try self.fd_map.put(self.arena.allocator(), fd, data);
        }

        pub const Event = extern struct {
            _event_data: EventData,
            pub fn data(self: *Event) *align(1) EventData {
                return &self._event_data;
            }
        };
        pub fn wait(self: *Self, comptime MaxCount: usize, events: *[MaxCount]Event) !usize {
            for (self.fds.items) |fd| {
                switch (fd.events) {
                    .read => try self.read_fd_set.add(self.arena.allocator(), fd.fd),
                    .write => @panic("todo"),
                }
            }
            const result = windows.select(
                0,
                self.read_fd_set.set,
                null,//&writefds,
                null,//&exceptfds,
                null,
            );
            if (result == -1) {
                std.debug.panic("select failed with {s}, todo?", .{@tagName(os.windows.ws2_32.WSAGetLastError())});
            }
            // result should never be 0 because of infinite timeout
            std.debug.assert(result != 0);

            // should always be true because we currently
            // only listen on the read_fds set
            std.debug.assert(self.read_fd_set.set.count == result);
            var event_count: usize = 0;
            for (self.read_fd_set.set.fd_slice()) |fd| {
                const data = self.fd_map.get(fd) orelse
                    std.debug.panic("fd {} is not in the map", .{fd});
                events[event_count] = .{ ._event_data = data };
                event_count += 1;
                if (event_count == MaxCount) break;
            }
            return event_count;
        }
    };
}
