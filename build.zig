const std = @import("std");
const gobject_build = @import("gobject");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gobject = b.dependency("gobject", .{});
    const xml = b.dependency("xml", .{}).module("xml");

    const data_dir: std.Build.InstallDir = .{ .custom = "share" };
    const locale_dir: std.Build.InstallDir = .{ .custom = "share/locale" };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "locale_dir", b.getInstallPath(locale_dir, ""));

    const exe = b.addExecutable(.{
        .name = "nonograms",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("xml", xml);
    exe.root_module.addImport("glib", gobject.module("glib2"));
    exe.root_module.addImport("gobject", gobject.module("gobject2"));
    exe.root_module.addImport("gio", gobject.module("gio2"));
    exe.root_module.addImport("gdk", gobject.module("gdk4"));
    exe.root_module.addImport("gtk", gobject.module("gtk4"));
    exe.root_module.addImport("cairo", gobject.module("cairo1"));
    exe.root_module.addImport("pango", gobject.module("pango1"));
    exe.root_module.addImport("pangocairo", gobject.module("pangocairo1"));
    exe.root_module.addImport("adw", gobject.module("adw1"));
    exe.root_module.addImport("libintl", b.dependency("libintl", .{}).module("libintl"));
    exe.root_module.addAnonymousImport("puzzles", .{ .root_source_file = b.path("puzzles/puzzles.zig") });
    const gresources = gobject_build.addCompileResources(b, target, b.path("data/resources/gresources.xml"));
    exe.root_module.addImport("gresources", gresources);
    b.installArtifact(exe);

    b.installDirectory(.{
        .source_dir = b.path("data/icons"),
        .install_dir = data_dir,
        .install_subdir = "icons",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.setEnvironmentVariable("XDG_DATA_HOME", b.getInstallPath(data_dir, "."));

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
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
