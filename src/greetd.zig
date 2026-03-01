const std = @import("std");
const Ipc = @import("zgsld").Ipc;
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();
const log = std.log.scoped(.greetd_bridge);

pub const GreetdRequestType = enum {
    create_session,
    post_auth_message_response,
    start_session,
    cancel_session,
};

pub const GreetdRequest = union(GreetdRequestType) {
    create_session: struct { username: []const u8 },
    post_auth_message_response: struct { response: ?[]const u8 },
    start_session: struct { cmd: []const []const u8, env: []const []const u8 },
    cancel_session: void,
};

pub const GreetdResponseType = enum {
    success,
    err,
    auth_message,
};

pub const ErrorType = error{
    AuthError,
    Error,
};

pub const AuthMessageType = enum { visible, secret, info, err };

pub const GreetdResponse = union(GreetdResponseType) {
    success: void,
    err: struct { error_type: ErrorType, description: []const u8 },
    auth_message: struct { auth_message_type: AuthMessageType, auth_message: []const u8 },
};

pub fn parseGreetdRequest(arena: std.mem.Allocator, payload: []const u8) !GreetdRequest {
    const RequestEnvelope = struct {
        type: GreetdRequestType,
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

    switch (req.type) {
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
pub fn zgsldRequestToGreetd(ipc_event: Ipc.Event) GreetdResponse {
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

pub const ZgsldWriteOpts = struct {
    source_profile: bool,
};

// GreetdRequest -> Zgsld
pub fn writeGreetdRequestToZgsld(ipc_conn: *Ipc.Connection, greetd_req: GreetdRequest, opts: ZgsldWriteOpts) !void {
    var buf: [Ipc.event_buf_size]u8 = undefined;
    var writer = ipc_conn.writer(&buf);
    var ipc_w = &writer.interface;

    log.debug("greeter sending {s}", .{@tagName(greetd_req)});

    switch (greetd_req) {
        .create_session => |r| {
            var user_buf: [64]u8 = undefined;
            const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{r.username});
            const ev = Ipc.Event{
                .pam_start_auth = .{ .user = user_z },
            };
            log.debug("compat pam_start_auth len={d}", .{user_z.len});
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .post_auth_message_response => |r| {
            const ev = Ipc.Event{
                .pam_response = r.response orelse "",
            };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .cancel_session => {
            const ev = Ipc.Event{ .login_cancel = {} };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
        .start_session => |r| {
            for (r.env) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                if (eq == 0) continue;

                const ev = Ipc.Event{
                    .set_session_env = .{
                        .key = kv[0..eq],
                        .value = kv[eq + 1 ..],
                    },
                };
                try ipc_conn.writeEvent(ipc_w, &ev);
            }

            var cmd_buf: [Ipc.event_buf_size]u8 = undefined;
            var cmd_writer: std.Io.Writer = .fixed(&cmd_buf);
            for (r.cmd, 0..) |arg, i| {
                if (i != 0) try cmd_writer.writeByte(' ');
                try cmd_writer.writeAll(arg);
            }

            const cmd_str = cmd_writer.buffered();
            if (cmd_str.len == 0) return error.InvalidPayload;

            const ev = Ipc.Event{
                .start_session = .{
                    .session_type = .command,
                    .command = .{ .session_cmd = cmd_str, .source_profile = opts.source_profile },
                },
            };
            try ipc_conn.writeEvent(ipc_w, &ev);
        },
    }

    ipc_w.flush() catch |err| {
        log.err("compat flush failed: {s}", .{@errorName(err)});
        return err;
    };
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
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    var jw = std.json.Stringify{ .writer = &buf.writer, .options = .{} };
    try jw.write(value);
    const payload = buf.written();
    try writer.writeInt(u32, @intCast(payload.len), native_endian);
    try writer.writeAll(payload);
    try writer.flush();
}
