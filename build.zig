const std = @import("std");
const libxml2 = @import("lib/zig-libxml2/libxml2.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bindings = b.dependency("zig-gobject", .{});

    const libxml2_lib = try libxml2.create(b, target, optimize, .{
        .iconv = false,
        .lzma = false,
        .zlib = false,
    });

    const exe = b.addExecutable(.{
        .name = "nonograms",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    libxml2_lib.link(exe);
    exe.addModule("glib", bindings.module("glib-2.0"));
    exe.addModule("gobject", bindings.module("gobject-2.0"));
    exe.addModule("gio", bindings.module("gio-2.0"));
    exe.addModule("gdk", bindings.module("gdk-4.0"));
    exe.addModule("gtk", bindings.module("gtk-4.0"));
    exe.addModule("cairo", bindings.module("cairo-1.0"));
    exe.addModule("pango", bindings.module("pango-1.0"));
    exe.addModule("pangocairo", bindings.module("pangocairo-1.0"));
    exe.addModule("adw", bindings.module("adw-1"));
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
