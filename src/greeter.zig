const std = @import("std");
const ipc = @import("zgipc");
const greetd = @import("greetd.zig");

const log = std.log.scoped(.compat);

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    zgsld_ipc: *ipc.Ipc,
    server_fd: std.posix.fd_t,
    sock_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    sock_path: []const u8 = "",

    zgsld_rbuf: [ipc.IPC_IO_BUF_SIZE]u8 = undefined,
    zgsld_event_buf: [ipc.GREETER_BUF_SIZE]u8 = undefined,
    zgsld_reader: std.fs.File.Reader = undefined,

    pub fn init(allocator: std.mem.Allocator, ipc_conn: *ipc.Ipc) !Greeter {
        std.debug.print("Greeter: init start\n",.{});
        const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;

        var greeter: Greeter = .{
            .allocator = allocator,
            .zgsld_ipc = ipc_conn,
            .server_fd = undefined,
        };

        greeter.sock_path = try std.fmt.bufPrint(
            &greeter.sock_path_buf,
            "{s}/zgsld-greetd-{d}.sock",
            .{ runtime_dir, std.c.getpid() },
        );

        std.fs.cwd().deleteFile(greeter.sock_path) catch {};
        errdefer std.fs.cwd().deleteFile(greeter.sock_path) catch {};

        const server_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(server_fd);

        const addr = try std.net.Address.initUnix(greeter.sock_path);
        try std.posix.bind(server_fd, &addr.any, addr.getOsSockLen());
        try std.posix.listen(server_fd, 1);

        greeter.server_fd = server_fd;
        greeter.zgsld_reader = greeter.zgsld_ipc.reader(&greeter.zgsld_rbuf);

        std.debug.print("Greeter: init end\n",.{});

        return greeter;
    }

    pub fn deinit(self: *Greeter) void {
        std.debug.print("Greeter: deinit start\n",.{});
        std.posix.close(self.server_fd);
        if (self.sock_path.len != 0) std.fs.cwd().deleteFile(self.sock_path) catch {};
    }

    pub fn serviceName() []const u8 {
        return "greetd";
    }

    pub fn handleInitialArgs(allocator: std.mem.Allocator) !void {
        _ = allocator;
    }

    pub fn run(self: *Greeter) !void {
        std.debug.print("Greeter: run start\n",.{});
        var args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        std.debug.print("Greeter: parsing args\n",.{});

        var greeter_args_list = std.ArrayList([]const u8){};
        defer greeter_args_list.deinit(self.allocator);

        if (args.len >= 2) {
            for (args[1..]) |arg| {
                try greeter_args_list.append(self.allocator, std.mem.sliceTo(arg, 0));
            }
        } else {
            return error.MissingGreeterCommand;
        }

        if (greeter_args_list.items.len == 0) return error.MissingGreeterCommand;
        const greeter_args = greeter_args_list.items;

        std.debug.print("Greeter: args parsed\n",.{});

        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();
        try env_map.put("GREETD_SOCK", self.sock_path);

        var child = std.process.Child.init(greeter_args, self.allocator);
        child.env_map = &env_map;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        defer _ = child.wait() catch {};

        const zgsld_io_reader = &self.zgsld_reader.interface;
        while (true) {
            std.debug.print("Connecting...\n", .{});
            const client_fd = try std.posix.accept(self.server_fd, null, null, 0);
            defer std.posix.close(client_fd);

            std.debug.print("Connected.\n",.{});

            var greeter_file = std.fs.File{ .handle = client_fd };
            var greeter_rbuf: [8192]u8 = undefined;
            var greeter_wbuf: [8192]u8 = undefined;
            var greeter_reader = greeter_file.reader(&greeter_rbuf);
            var greeter_writer = greeter_file.writer(&greeter_wbuf);
            const greeter_io_reader = &greeter_reader.interface;
            const greeter_io_writer = &greeter_writer.interface;

            var fds = [_]std.posix.pollfd{
                .{ .fd = client_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.zgsld_ipc.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };

            var greeter_state = GreeterState{};
            poll_loop: while (true) {
                fds[0].revents = 0;
                fds[1].revents = 0;
                _ = try std.posix.poll(&fds, -1);

                if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    while (true) {
                        std.debug.print("Waiting for Greeter event\n", .{});
                        const payload = greetd.readFrame(self.allocator, greeter_io_reader) catch |err| switch (err) {
                            error.EndOfStream => {
                                std.debug.print("Greeter: EndOfStream\n", .{});
                                break :poll_loop;
                            },
                            else => return err,
                        };
                        defer self.allocator.free(payload);

                        handleGreetdRequest(
                            self.allocator,
                            payload,
                            self.zgsld_ipc,
                            greeter_io_writer,
                            &greeter_state,
                        ) catch |err| switch (err) {
                            error.WriteFailed => {
                                log.err("greeter write failed", .{});
                            },
                            else => {
                                log.err("request handling failed: {s}", .{@errorName(err)});
                                greetd.writeResponse(greeter_io_writer, self.allocator, .{
                                    .err = .{
                                        .error_type = error.Error,
                                        .description = "invalid request",
                                    },
                                }) catch {};
                            },
                        };

                        if (greeter_reader.interface.end == greeter_reader.interface.seek) break;
                    }
                }

                if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    while (true) {
                        std.debug.print("Waiting for ZGSLD event\n", .{});
                        const ev = self.zgsld_ipc.readEvent(zgsld_io_reader, &self.zgsld_event_buf) catch |err| switch (err) {
                            error.EndOfStream => return,
                            else => return err,
                        };

                        switch (ev) {
                            .pam_request => greeter_state.awaiting_response = true,
                            .pam_auth_result => greeter_state.awaiting_response = false,
                            else => {},
                        }

                        std.debug.print("ZGSLD: {s}\n", .{@tagName(ev)});

                        const resp = greetd.zgsldRequestToGreetd(ev);
                        try greetd.writeResponse(greeter_io_writer, self.allocator, resp);

                        if (self.zgsld_reader.interface.end == self.zgsld_reader.interface.seek) break;
                    }
                }

                if ((fds[0].revents & std.posix.POLL.ERR) != 0) {
                    std.debug.print("Greeter poll error\n", .{});
                }
                if ((fds[1].revents & std.posix.POLL.ERR) != 0) {
                    std.debug.print("ZGSLD poll error\n", .{});
                }
            }
        }
    }
};

fn handleGreetdRequest(
    allocator: std.mem.Allocator,
    payload: []const u8,
    zgsld_ipc: *ipc.Ipc,
    greeter_io_writer: *std.Io.Writer,
    greeter_state: *GreeterState,
) !void {
    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();
    const req = try greetd.parseGreetdRequest(req_arena.allocator(), payload);
    std.debug.print("greetd -> compat: {s}\n", .{@tagName(req)});
    std.debug.print("greetd greeter: {s}\n", .{payload});

    switch (req) {
        .post_auth_message_response => {
            if (!greeter_state.awaiting_response) {
                log.err("dropping post_auth_message_response: no pending pam_request", .{});
                greetd.writeResponse(greeter_io_writer, allocator, .{
                    .err = .{
                        .error_type = error.Error,
                        .description = "unexpected auth response",
                    },
                }) catch {};
                return;
            }
            greeter_state.awaiting_response = false;
        },
        .create_session, .cancel_session, .start_session => {
            greeter_state.awaiting_response = false;
        },
    }

    std.debug.print("compat: writing {s}\n", .{@tagName(req)});
    try greetd.writeGreetdRequestToZgsld(zgsld_ipc, req);
    std.debug.print("compat: wrote {s}\n", .{@tagName(req)});
}

const GreeterState = struct {
    awaiting_response: bool = false,
};
