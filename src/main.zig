const std = @import("std");
const zgipc = @import("zgipc");
const Greeter = @import("greeter.zig").Greeter;
const clap = @import("clap");
const build_options = @import("build_options");
const greetd = @import("greetd.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var sock_fd: ?std.posix.fd_t = null;
    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }
    
    const fd = sock_fd orelse return error.MissingSockFd;
    var ipc_conn = zgipc.Ipc.initFromFd(fd);
    defer ipc_conn.deinit();

    var greeter = try Greeter.init(allocator, &ipc_conn);
    defer greeter.deinit();
    try greeter.run();

    std.debug.print("Greeter Exiting...\n",.{});
}

fn handleArgs(allocator: std.mem.Allocator) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stdout().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const paramStr =
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld (greetd).
        \\-s, --socket-path <str>   Socket path to use
        \\-c, --config <str>        Config file to use
        \\--vt <u8>                 Use the specified vt
        \\<str>...
    ;

    const params = comptime clap.parseParamsComptime(paramStr);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }
    if (res.args.version != 0) {
        try stderr.writeAll("zgsld (greetd) version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    // socket_path, config_path, vt,
    const config_path = res.args.config orelse "/etc/greetd/config.toml";
    const parsed = try greetd.parseConfig(allocator, config_path);
    defer parsed.deinit();
    const config = parsed.value;

    std.debug.print("Parsed Config\nSession Command: {s}\nGreeter User: {s}\nTTY: {d}\n",.{config.default_session.command,config.default_session.user, config.terminal.vt});
}
