const std = @import("std");
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const standalone = b.option(bool, "standalone", "Build standalone greeter + session manager") orelse false;
    const preview = b.option(bool, "preview", "Preview build") orelse false;

    const zgsld = b.dependency("zgsld", .{ .target = target, .optimize = optimize, .standalone = standalone, .x11 = false });
    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize });

    const sem_ver = try std.SemanticVersion.parse(build_zon.version);
    const version_str = try getVersionStr(b, "zgsld", sem_ver);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_str);
    build_options.addOption(bool, "standalone", standalone);
    build_options.addOption(bool, "preview", preview);

    const exe_name = if (standalone) "greetd" else "zgsld-greetd-bridge";
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zgsld", .module = zgsld.module("zgsld") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "toml", .module = toml.module("toml") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the compat greeter");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zgsld", .module = zgsld.module("zgsld") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "toml", .module = toml.module("toml") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const fmt_step = b.step("fmt", "Format source files");
    const fmt_cmd = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" } });
    fmt_step.dependOn(&fmt_cmd.step);
}

fn getVersionStr(b: *std.Build, name: []const u8, version: std.SemanticVersion) ![]const u8 {
    const version_str = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    var status: u8 = undefined;
    const git_describe_raw = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--match",
        "*.*.*",
        "--tags",
    }, &status, .Ignore) catch {
        return version_str;
    };
    var git_describe = std.mem.trim(u8, git_describe_raw, " \n\r");
    git_describe = std.mem.trimLeft(u8, git_describe, "v");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            if (!std.mem.eql(u8, version_str, git_describe)) {
                std.debug.print("{s} version '{s}' does not match git tag: '{s}'\n", .{ name, version_str, git_describe });
                std.process.exit(1);
            }
            return version_str;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = std.mem.trimLeft(u8, it.first(), "v");
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            if (version.order(ancestor_ver) != .gt) {
                std.debug.print("{s} version '{f}' must be greater than tagged ancestor '{f}'\n", .{ name, version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version_str;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_str, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_str;
        },
    }
}
