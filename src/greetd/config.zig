const std = @import("std");
const toml = @import("toml");
const vt = @import("vt.zig");
const ZgsldVt = @import("zgsld").Config.Vt;

const GreetdVtOpts = enum {
    num,
    current,
    next,
    none,
};

pub const GreetdVt = union(GreetdVtOpts) {
    num: u8,
    current: void,
    next: void,
    none: void,
};

pub const Config = struct {
    default_session: struct {
        command: []const u8,
        user: []const u8 = "greeter",
        service: []const u8 = "greetd-greeter",
    },
    initial_session: ?struct {
        command: []const u8,
        user: []const u8,
    },
    terminal: TerminalConfig,
    general: struct {
        source_profile: bool = true,
        //runfile: []const u8,
        service: []const u8 = "greetd",
    } = .{},

    pub fn parseFromFile(allocator: std.mem.Allocator, config_path: []const u8) !toml.Parsed(@This()) {
        var parser = toml.Parser(@This()).init(allocator);
        defer parser.deinit();

        return try parser.parseFile(config_path);
    }
};

const TerminalConfig = struct {
    vt: GreetdVt,
    @"switch": bool = true,

    pub fn tomlIntoStruct(ctx: anytype, table: *toml.Table) !@This() {
        var result: @This() = .{
            .vt = undefined,
            .@"switch" = true,
        };

        try ctx.field_path.append(ctx.alloc, "vt");
        const vt_entry = table.fetchRemove("vt") orelse {
            _ = ctx.field_path.pop();
            return error.MissingRequiredField;
        };
        defer _ = ctx.field_path.pop();
        result.vt = try parseGreetdVt(&vt_entry.value);

        if (table.fetchRemove("switch")) |entry| {
            try ctx.field_path.append(ctx.alloc, "switch");
            defer _ = ctx.field_path.pop();
            result.@"switch" = switch (entry.value) {
                .boolean => |b| b,
                else => return error.InvalidValueType,
            };
        }

        return result;
    }
};

fn parseGreetdVt(value: *const toml.Value) !GreetdVt {
    switch (value.*) {
        .integer => |x| {
            if (x <= 0 or x > std.math.maxInt(u8)) return error.InvalidValueType;
            return .{ .num = @intCast(x) };
        },
        .string => |s| {
            return parseVtKeyword(s) orelse error.InvalidValueType;
        },
        else => return error.InvalidValueType,
    }
}

pub fn parseVtArg(value: []const u8) !GreetdVt {
    if (parseVtKeyword(value)) |vt_value| return vt_value;

    const vt_num = try std.fmt.parseInt(u8, value, 10);
    if (vt_num == 0) return error.InvalidValueType;
    return .{ .num = vt_num };
}

pub fn resolveVt(value: GreetdVt) !ZgsldVt {
    return switch (value) {
        .num => |vt_num| .{ .number = vt_num },
        .current => .current,
        .next => .{ .number = try vt.findNextVt() },
        .none => .unmanaged,
    };
}

fn parseVtKeyword(value: []const u8) ?GreetdVt {
    if (std.mem.eql(u8, value, "current")) return .current;
    if (std.mem.eql(u8, value, "next")) return .next;
    if (std.mem.eql(u8, value, "none")) return .none;
    return null;
}
