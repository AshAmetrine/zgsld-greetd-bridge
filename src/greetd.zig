const std = @import("std");
const ipc = @import("zgipc");
const builtin = @import("builtin");
const toml = @import("toml");

const native_endian = builtin.cpu.arch.endian();

pub const Config = struct {
    default_session: struct {
        command: []const u8,
        user: []const u8,
    },
    terminal: struct {
        vt: u8,
    },
};

pub const GreetdRequestType = enum {
    create_session,
    post_auth_message_response,
    start_session,
    cancel_session,
};

pub const GreetdRequest = union(GreetdRequestType) {
    create_session: struct { username: []const u8 },
    post_auth_message_response: struct { response: ?[]const u8 },
    start_session: struct{ cmd: []const []const u8, env: []const []const u8 },
    cancel_session: void,
};

pub const GreetdResponseType = enum {
    success,
    err,
    auth_message,
};

pub const ErrorType = error {
    AuthError,
    Error,
};

pub const AuthMessageType = enum {
    visible,
    secret,
    info,
    err
};

pub const GreetdResponse = union(GreetdResponseType) {
    success: void,
    err: struct { error_type: ErrorType, description: []const u8 },
    auth_message: struct { auth_message_type: AuthMessageType, auth_message: []const u8 },
};

pub fn parseConfig(allocator: std.mem.Allocator, config_path: []const u8) !toml.Parsed(Config) {
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return try parser.parseFile(config_path);
}

pub fn parseGreetdRequest(arena: std.mem.Allocator, payload: []const u8) !GreetdRequest {
    const RequestEnvelope = struct {
        @"type": GreetdRequestType,
        username: ?[]const u8 = null,
        response: ?[]const u8 = null,
        cmd: ?[]const []const u8 = null,
        env: ?[]const []const u8 = null,
    };

    const req = std.json.parseFromSliceLeaky(RequestEnvelope, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPayload,
    };

    switch (req.@"type") {
        .create_session => {
            const username = req.username orelse return error.InvalidPayload;
            return .{ .create_session = .{ .username = username } };
        },
        .post_auth_message_response => {
            return .{ .post_auth_message_response = .{ .response = req.response } };
        },
        .start_session => {
            const cmd_items = req.cmd orelse return error.InvalidPayload;
            if (cmd_items.len == 0) return error.InvalidPayload;
            const env_items = req.env orelse &[_][]const u8{};
            return .{ .start_session = .{ .cmd = cmd_items, .env = env_items } };
        },
        .cancel_session => return .{ .cancel_session = {} },
    }
}

// PAM REQUEST -> GreetdResponse
pub fn zgsldRequestToGreetd(ipc_event: ipc.IpcEvent) GreetdResponse {
    switch (ipc_event) {
        .pam_request => |r| {
            const msg_type: AuthMessageType = if (r.echo) .visible else .secret;
            return .{ 
                .auth_message = .{ 
                    .auth_message = r.message, 
                    .auth_message_type = msg_type, 
                }, 
            };
        },
        .pam_message => |m| { 
            const msg_type: AuthMessageType = if (m.is_error) .err else .info;
            return .{ 
                .auth_message = .{
                    .auth_message = m.message,
                    .auth_message_type = msg_type,
                },
            };
        },
        .pam_auth_result => |r| {
            if (r.ok) return .success;

            return .{ 
                .err = .{ 
                    .description = "authentication failed",
                    .error_type = error.AuthError,
                }, 
            };
        },
        else => unreachable,
    }
}

// GreetdRequest -> Zgsld
pub fn writeGreetdRequestToZgsld(ipc_conn: *ipc.Ipc, greetd_req: GreetdRequest) !void {
    var buf: [ipc.IPC_IO_BUF_SIZE]u8 = undefined;
    var writer = ipc_conn.writer(&buf);
    var ipc_w = &writer.interface;

    std.debug.print("Greeter: Sending {s}",.{ @tagName(greetd_req) });

    switch (greetd_req) {
        .create_session => |r| {
            var user_buf: [ipc.PAM_START_BUF_SIZE]u8 = undefined;
            const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{r.username});
            const ev = ipc.IpcEvent{
                .pam_start_auth = .{ .user = user_z },
            };
            std.debug.print("compat: pam_start_auth len={d}\n", .{user_z.len});
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .post_auth_message_response => |r| {
            const ev = ipc.IpcEvent{
                .pam_response = r.response orelse "",
            };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .cancel_session => {
            const ev = ipc.IpcEvent{ .pam_cancel = {} };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .start_session => |r| { 
            for (r.env) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                if (eq == 0) continue;

                const ev = ipc.IpcEvent{
                    .set_session_env = .{
                        .key = kv[0..eq],
                        .value = kv[eq + 1 ..],
                    },
                };
                try ipc_conn.writeEvent(ipc_w, &ev);
            }

            var argv_buf: [ipc.IPC_IO_BUF_SIZE]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&argv_buf);
            const argv_writer = fbs.writer();
            for (r.cmd) |arg| {
                try argv_writer.writeAll(arg);
                try argv_writer.writeByte(0);
            }

            const argv = fbs.getWritten();
            if (argv.len == 0) return error.InvalidPayload;

            const ev = ipc.IpcEvent{
                .start_session = .{
                    .Command = .{
                        .argv = argv,
                    },
                },
            };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
    }

    std.debug.print("compat: flushing {s} to zgsld fd={d}\n", .{
        @tagName(greetd_req),
        ipc_conn.file.handle,
    });
    ipc_w.flush() catch |err| {
        std.debug.print("compat: flush failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("compat: flushed {s}\n", .{@tagName(greetd_req)});
}

pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const len = try reader.takeInt(u32, native_endian);
    if (len == 0) return error.InvalidPayload;

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try reader.readSliceAll(buf);
    return buf;
}

pub fn writeResponse(writer: *std.Io.Writer, allocator: std.mem.Allocator, resp: GreetdResponse) !void {
    switch (resp) {
        .success => {
            const payload = struct { type: []const u8 = "success" }{};
            try sendJson(writer, allocator, payload);
        },
        .err => |e| {
            const payload = struct {
                type: []const u8 = "error",
                error_type: []const u8,
                description: []const u8,
            }{
                .error_type = errorTypeToString(e.error_type),
                .description = e.description,
            };
            try sendJson(writer, allocator, payload);
        },
        .auth_message => |m| {
            const payload = struct {
                type: []const u8 = "auth_message",
                auth_message_type: []const u8,
                auth_message: []const u8,
            }{
                .auth_message_type = authMessageTypeToString(m.auth_message_type),
                .auth_message = m.auth_message,
            };
            try sendJson(writer, allocator, payload);
        },
    }
}

fn errorTypeToString(error_type: ErrorType) []const u8 {
    return switch (error_type) {
        error.AuthError => "auth_error",
        error.Error => "error",
    };
}

fn authMessageTypeToString(msg_type: AuthMessageType) []const u8 {
    return switch (msg_type) {
        .visible => "visible",
        .secret => "secret",
        .info => "info",
        .err => "error",
    };
}

fn sendJson(writer: *std.Io.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    var buf_writer = buf.writer(allocator);
    var adapter_buf: [256]u8 = undefined;
    var adapter = buf_writer.adaptToNewApi(&adapter_buf);
    var jw = std.json.Stringify{ .writer = &adapter.new_interface, .options = .{} };
    try jw.write(value);
    try adapter.new_interface.flush();

    const payload = buf.items;
    try writer.writeInt(u32, @intCast(payload.len), native_endian);
    try writer.writeAll(payload);
    try writer.flush();
}
