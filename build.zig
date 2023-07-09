const std = @import("std");
const libxml2 = @import("lib/zig-libxml2/libxml2.zig");
const zig_gobject = @import("lib/zig-gobject/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    exe.addModule("glib", zig_gobject.addBindingModule(b, exe, "glib-2.0"));
    exe.addModule("gobject", zig_gobject.addBindingModule(b, exe, "gobject-2.0"));
    exe.addModule("gio", zig_gobject.addBindingModule(b, exe, "gio-2.0"));
    exe.addModule("gdk", zig_gobject.addBindingModule(b, exe, "gdk-4.0"));
    exe.addModule("gtk", zig_gobject.addBindingModule(b, exe, "gtk-4.0"));
    exe.addModule("cairo", zig_gobject.addBindingModule(b, exe, "cairo-1.0"));
    exe.addModule("pango", zig_gobject.addBindingModule(b, exe, "pango-1.0"));
    exe.addModule("pangocairo", zig_gobject.addBindingModule(b, exe, "pangocairo-1.0"));
    exe.addModule("adw", zig_gobject.addBindingModule(b, exe, "adw-1"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
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
