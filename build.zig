const std = @import("std");
const zig_gobject = @import("lib/zig-gobject/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{}).module("xml");

    const compile_resources = b.addSystemCommand(&.{ "glib-compile-resources", "--generate-source", "--target" });
    const gresources_c = compile_resources.addOutputFileArg("gresources.c");
    compile_resources.addArg("gresources.xml");
    compile_resources.cwd = "data";

    const exe = b.addExecutable(.{
        .name = "nonograms",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.addModule("xml", xml);
    exe.addModule("glib", zig_gobject.addBindingModule(b, exe, "glib-2.0"));
    exe.addModule("gobject", zig_gobject.addBindingModule(b, exe, "gobject-2.0"));
    exe.addModule("gio", zig_gobject.addBindingModule(b, exe, "gio-2.0"));
    exe.addModule("gdk", zig_gobject.addBindingModule(b, exe, "gdk-4.0"));
    exe.addModule("gtk", zig_gobject.addBindingModule(b, exe, "gtk-4.0"));
    exe.addModule("cairo", zig_gobject.addBindingModule(b, exe, "cairo-1.0"));
    exe.addModule("pango", zig_gobject.addBindingModule(b, exe, "pango-1.0"));
    exe.addModule("pangocairo", zig_gobject.addBindingModule(b, exe, "pangocairo-1.0"));
    exe.addModule("adw", zig_gobject.addBindingModule(b, exe, "adw-1"));
    exe.addModule("libintl", zig_gobject.addBindingModule(b, exe, "libintl-0.0"));
    exe.addAnonymousModule("puzzles", .{ .source_file = .{ .path = "puzzles/puzzles.zig" } });
    exe.addCSourceFile(.{ .file = gresources_c, .flags = &.{} });
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

    const run_xgettext = b.addSystemCommand(&.{
        "xgettext",
        "-f",
        b.pathFromRoot(b.pathJoin(&.{ "po", "POTFILES.in" })),
        "-o",
        b.pathFromRoot(b.pathJoin(&.{ "po", "nonograms.pot" })),
        "--package-name=Nonograms",
        "--package-version=0.0.0", // TODO: use real version once we can import build.zig.zon
        "--copyright-holder=Nonograms contributors",
    });

    const xgettext_step = b.step("xgettext", "Generate nonograms.pot using xgettext");
    xgettext_step.dependOn(&run_xgettext.step);
}
