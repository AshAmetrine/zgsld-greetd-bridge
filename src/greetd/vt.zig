const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    if (builtin.os.tag == .linux) {
        @cInclude("linux/vt.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("sys/consio.h");
    }
});

pub fn findNextVt() !u8 {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .freebsd) {
        return error.UnsupportedPlatform;
    }

    var console = try openConsoleFile();
    defer console.close();

    var vt_num: c_int = 0;
    const status = std.c.ioctl(console.handle, c.VT_OPENQRY, &vt_num);
    if (status != 0) return error.FailedToQueryVt;
    if (vt_num <= 0 or vt_num > std.math.maxInt(u8)) return error.InvalidValueType;
    return @intCast(vt_num);
}

fn openConsoleFile() !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty0", .{ .mode = .read_write }) catch
        std.fs.openFileAbsolute("/dev/console", .{ .mode = .read_write });
}
