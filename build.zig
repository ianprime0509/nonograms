const std = @import("std");
const gobject_build = @import("gobject");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const devel = b.release_mode == .off;
    const app_id = "dev.ianjohnson.Nonograms";

    const gobject = b.dependency("gobject", .{});
    const xml = b.dependency("xml", .{}).module("xml");

    const data_dir: std.Build.InstallDir = .{ .custom = "share" };
    const locale_dir: std.Build.InstallDir = .{ .custom = "share/locale" };
    const metainfo_dir: std.Build.InstallDir = .{ .custom = "share/metainfo" };
    const desktop_dir: std.Build.InstallDir = .{ .custom = "share/applications" };
    const icon_dir: std.Build.InstallDir = .{ .custom = "share/icons" };
    const build_options = b.addOptions();
    build_options.addOption(bool, "devel", devel);
    build_options.addOption([:0]const u8, "app_id", app_id);
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
    b.installArtifact(exe);

    const metainfo = b.path("data/dev.ianjohnson.Nonograms.metainfo.xml");
    const metainfo_install = b.addInstallFileWithDir(metainfo, metainfo_dir, b.fmt("{s}.metainfo.xml", .{app_id}));
    b.getInstallStep().dependOn(&metainfo_install.step);

    const desktop = b.path("data/dev.ianjohnson.Nonograms.desktop");
    const desktop_install = b.addInstallFileWithDir(desktop, desktop_dir, b.fmt("{s}.desktop", .{app_id}));
    b.getInstallStep().dependOn(&desktop_install.step);

    const scalable_icon = if (devel)
        b.path("data/icons/hicolor/scalable/apps/dev.ianjohnson.Nonograms.Devel.svg")
    else
        b.path("data/icons/hicolor/scalable/apps/dev.ianjohnson.Nonograms.svg");
    const scalable_icon_install = b.addInstallFileWithDir(scalable_icon, icon_dir, b.fmt("hicolor/scalable/apps/{s}.svg", .{app_id}));
    b.getInstallStep().dependOn(&scalable_icon_install.step);

    const symbolic_icon = b.path("data/icons/hicolor/symbolic/apps/dev.ianjohnson.Nonograms-symbolic.svg");
    const symbolic_icon_install = b.addInstallFileWithDir(symbolic_icon, icon_dir, b.fmt("hicolor/symbolic/apps/{s}-symbolic.svg", .{app_id}));
    b.getInstallStep().dependOn(&symbolic_icon_install.step);

    var gresources = gobject_build.buildCompileResources(gobject);
    const resources = gresources.addGroup("/dev/ianjohnson/Nonograms/");
    resources.addFile("metainfo.xml", metainfo, .{});
    resources.addFile("icons/scalable/actions/about-symbolic.svg", b.path("data/resources/icons/scalable/actions/about-symbolic.svg"), .{});
    resources.addFile("icons/scalable/actions/library-symbolic.svg", b.path("data/resources/icons/scalable/actions/library-symbolic.svg"), .{});
    resources.addFile("icons/scalable/actions/menu-symbolic.svg", b.path("data/resources/icons/scalable/actions/menu-symbolic.svg"), .{});
    resources.addFile("ui/color-button.ui", b.path("data/resources/ui/color-button.ui"), .{});
    resources.addFile("ui/color-picker.ui", b.path("data/resources/ui/color-picker.ui"), .{});
    resources.addFile("ui/view.ui", b.path("data/resources/ui/view.ui"), .{});
    resources.addFile("ui/window.ui", b.path("data/resources/ui/window.ui"), .{});
    exe.root_module.addImport("gresources", gresources.build(target));

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
