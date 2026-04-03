const std = @import("std");
const zgsld = @import("zgsld");
const Zgsld = zgsld.Zgsld;
const Greeter = @import("greeter.zig").Greeter;
const clap = @import("clap");
const build_options = @import("build_options");
const greetd_config = @import("greetd/config.zig");

pub const std_options: std.Options = .{ .logFn = zgsld.logFn };

const log = std.log.scoped(.greetd_bridge);

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    if (!build_options.standalone and std.posix.getenv("ZGSLD_SOCK") == null) {
        const argv = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, argv);

        var config = try parseArgs(allocator, argv);
        defer config.deinit();

        if (!build_options.preview) {
            log.err("This greeter should be run by zgsld", .{});
            return;
        }
    }

    zgsld.initZgsldLog();

    const app = zgsld.Zgsld.init(allocator, &.{
        .run = run,
        .configure = configure,
    });

    if (build_options.preview) {
        try app.runPreview(.{
            .authenticate_steps = &zgsld.preview.password_auth_steps,
            .post_auth_steps = &zgsld.preview.change_auth_token_steps,
        });
    } else {
        try app.run();
    }
}

pub fn configure(ctx: Zgsld.ConfigureContext) !void {
    if (!build_options.standalone) unreachable;

    const argv = try std.process.argsAlloc(ctx.allocator);
    defer std.process.argsFree(ctx.allocator, argv);

    var config = try parseArgs(ctx.allocator, argv);
    defer config.deinit();

    if (config.vt) |vt| ctx.config.vt = vt;
    if (config.greeter_user) |u| ctx.config.greeter.user = try ctx.arena_allocator.dupe(u8, u);
    if (config.pam_greeter_service) |p| ctx.config.greeter.service_name = try ctx.arena_allocator.dupe(u8, p);
    if (config.pam_user_service) |p| ctx.config.session.service_name = try ctx.arena_allocator.dupe(u8, p);
    if (config.autologin) |autologin| {
        ctx.config.autologin.user = try ctx.arena_allocator.dupeZ(u8, autologin.user);
        ctx.config.autologin.command = try ctx.arena_allocator.dupeZ(u8, autologin.command);
    }
}

pub fn run(ctx: Zgsld.GreeterContext) !void {
    const argv = try std.process.argsAlloc(ctx.allocator);
    defer std.process.argsFree(ctx.allocator, argv);

    var config = try parseArgs(ctx.allocator, argv);
    defer config.deinit();

    var greeter = try Greeter.init(
        ctx.allocator,
        ctx.ipc,
        config.greeter_cmd,
        config.source_profile,
    );
    defer greeter.deinit();
    try greeter.run();
}

const ParsedArgs = if (build_options.standalone) struct {
    arena: std.heap.ArenaAllocator,
    vt: ?Zgsld.Config.Vt = null,
    greeter_user: ?[]const u8 = null,
    pam_user_service: ?[]const u8 = null,
    pam_greeter_service: ?[]const u8 = null,
    autologin: ?AutologinConfig = null,
    greeter_cmd: []const u8,
    source_profile: bool = true,

    pub fn deinit(self: *ParsedArgs) void {
        self.arena.deinit();
    }
} else struct {
    arena: std.heap.ArenaAllocator,
    greeter_cmd: []const u8,
    source_profile: bool = true,

    pub fn deinit(self: *ParsedArgs) void {
        self.arena.deinit();
    }
};

const AutologinConfig = struct {
    command: []const u8,
    user: []const u8,
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) !ParsedArgs {
    const param_str = if (build_options.standalone) blk: {
        break :blk 
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld-greetd-bridge.
        \\-c, --config <str>        Config file to use.
        \\--vt <str>                Sets the VT ("current"|"next"|"none"|number).
        ;
    } else blk: {
        break :blk 
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld-greetd-bridge.
        \\-c, --config <str>        Config file to use.
        ;
    };

    const params = comptime clap.parseParamsComptime(param_str);
    var diag = clap.Diagnostic{};
    var iter = clap.args.SliceIterator{ .args = argv[1..] };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
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

        try stderr.writeAll("zgsld-greetd-bridge version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    const config_path = res.args.config orelse "/etc/greetd/config.toml";
    const config = try greetd_config.Config.parseFromFile(allocator, config_path);

    const greeter_session = config.value.default_session;

    if (build_options.standalone) {
        const vt_selection = if (res.args.vt) |vt| blk: {
            break :blk try greetd_config.parseVtArg(vt);
        } else config.value.terminal.vt;

        const vt = try greetd_config.resolveVt(vt_selection);

        return .{
            .arena = config.arena,
            .vt = vt,
            .greeter_user = greeter_session.user,
            .pam_user_service = config.value.general.service,
            .pam_greeter_service = config.value.default_session.service,
            .autologin = if (config.value.initial_session) |autologin| .{
                .command = autologin.command,
                .user = autologin.user,
            } else null,
            .greeter_cmd = greeter_session.command,
            .source_profile = config.value.general.source_profile,
        };
    }

    return .{
        .arena = config.arena,
        .greeter_cmd = greeter_session.command,
        .source_profile = config.value.general.source_profile,
    };
}
