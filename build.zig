const std = @import("std");
const gobject_build = @import("gobject");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gobject = b.dependency("gobject", .{});
    const xml = b.dependency("xml", .{}).module("xml");

    const exe = b.addExecutable(.{
        .name = "nonograms",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("xml", xml);
    exe.root_module.addImport("glib", gobject.module("glib-2.0"));
    exe.root_module.addImport("gobject", gobject.module("gobject-2.0"));
    exe.root_module.addImport("gio", gobject.module("gio-2.0"));
    exe.root_module.addImport("gdk", gobject.module("gdk-4.0"));
    exe.root_module.addImport("gtk", gobject.module("gtk-4.0"));
    exe.root_module.addImport("cairo", gobject.module("cairo-1.0"));
    exe.root_module.addImport("pango", gobject.module("pango-1.0"));
    exe.root_module.addImport("pangocairo", gobject.module("pangocairo-1.0"));
    exe.root_module.addImport("adw", gobject.module("adw-1"));
    exe.root_module.addImport("libintl", b.dependency("libintl", .{}).module("libintl"));
    exe.root_module.addAnonymousImport("puzzles", .{ .root_source_file = .{ .path = "puzzles/puzzles.zig" } });
    const gresources = gobject_build.addCompileResources(b, target, .{ .path = "data/gresources.xml" });
    exe.root_module.addImport("gresources", gresources);
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
