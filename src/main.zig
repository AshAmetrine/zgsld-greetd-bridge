const std = @import("std");
const zgsld = @import("zgsld");
const Greeter = @import("greeter.zig").Greeter;
const clap = @import("clap");
const build_options = @import("build_options");
const greetd = @import("greetd.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const app = zgsld.Zgsld.init(allocator, .{
        .run = run,
        .configure = configure,
    });

    try app.run();
}

pub fn configure(ctx: zgsld.ConfigureContext) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of basic-greeter.
        \\-c, --config <str>        Config file to use.
        \\--vt <str>                Sets the VT ("current"|"next"|"none"|number).
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = ctx.allocator }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }

    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("Zgsld Greetd Bridge version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    if (res.args.vt) |vt_arg| {
        const vt_selection = try greetd.parseVtArg(vt_arg);
        if (try greetd.resolveVt(vt_selection)) |vt_num| {
            ctx.cfg.setVt(vt_num);
        }
    }

    const config_path = res.args.config orelse "/etc/greetd/config.toml";

    const config = try greetd.parseConfig(ctx.allocator, config_path);
    defer config.deinit();

    try ctx.cfg.setGreeterUser(config.value.default_session.user);
    try ctx.cfg.setServiceName("greetd");
    if (res.args.vt == null) {
        if (try greetd.resolveVt(config.value.terminal.vt)) |vt| {
            ctx.cfg.setVt(vt);
        }
    }
}

pub fn run(ctx: zgsld.GreeterContext) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of basic-greeter.
        \\-c, --config <str>        Config file to use.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = ctx.allocator }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }

    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("Zgsld Greetd Bridge version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    const config_path = res.args.config orelse "/etc/greetd/config.toml";

    const config = try greetd.parseConfig(ctx.allocator, config_path);
    defer config.deinit();

    const greeter_cmd = config.value.default_session.command;

    var greeter = try Greeter.init(
        ctx.allocator,
        ctx.ipc,
        greeter_cmd,
        config.value.general.source_profile,
    );
    defer greeter.deinit();
    try greeter.run();
}
