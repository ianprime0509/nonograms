const std = @import("std");
const gobject_build = @import("gobject");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const devel = b.release_mode == .off;
    const app_id = "dev.ianjohnson.Nonograms";

    const gobject = b.dependency("gobject", .{});
    const libpbn = b.dependency("libpbn", .{}).module("libpbn");

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
    exe.root_module.addImport("libpbn", libpbn);
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

    const linguas = readLinguas(b);

    const metainfo = generateMetainfo(b, linguas);
    const metainfo_install = b.addInstallFileWithDir(metainfo, metainfo_dir, b.fmt("{s}.metainfo.xml", .{app_id}));
    b.getInstallStep().dependOn(&metainfo_install.step);

    const desktop = generateDesktop(b, linguas);
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

    const test_step = b.step("test", "Run unit tests");

    const exe_test = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&exe_test.step);

    const metainfo_validate = b.addSystemCommand(&.{ "appstreamcli", "validate", "--no-net", "--strict" });
    metainfo_validate.addFileArg(metainfo);
    metainfo_validate.expectExitCode(0);
    test_step.dependOn(&metainfo_validate.step);

    const desktop_validate = b.addSystemCommand(&.{"desktop-file-validate"});
    desktop_validate.addFileArg(desktop);
    desktop_validate.expectExitCode(0);
    test_step.dependOn(&desktop_validate.step);

    const exe_run = b.addRunArtifact(exe);
    exe_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
    exe_run.setEnvironmentVariable("XDG_DATA_HOME", b.getInstallPath(data_dir, "."));

    const exe_run_step = b.step("run", "Run the app");
    exe_run_step.dependOn(&exe_run.step);

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

fn readLinguas(b: *std.Build) []const []const u8 {
    const max_bytes = 16 * 1024; // 16KB
    const raw = std.fs.cwd().readFileAlloc(b.allocator, b.pathFromRoot("po/LINGUAS"), max_bytes) catch |err|
        std.debug.panic("failed to read LINGUAS: {}", .{err});

    var linguas = std.ArrayList([]const u8).init(b.allocator);
    defer linguas.deinit();
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed_line, "#")) continue;
        var items = std.mem.tokenizeAny(u8, trimmed_line, &std.ascii.whitespace);
        while (items.next()) |item| {
            linguas.append(item) catch @panic("OOM");
        }
    }
    return linguas.toOwnedSlice() catch @panic("OOM");
}

fn generateMetainfo(b: *std.Build, linguas: []const []const u8) std.Build.LazyPath {
    const base = b.path("data/dev.ianjohnson.Nonograms.metainfo.xml");

    const translate = b.addSystemCommand(&.{ "msgfmt", "--xml" });
    addPoDependencies(b, translate, linguas);
    translate.addPrefixedDirectoryArg("-d", b.path("po"));
    translate.addPrefixedFileArg("--template=", base);
    return translate.addPrefixedOutputFileArg("-o", "dev.ianjohnson.Nonograms.metainfo.xml");
}

fn generateDesktop(b: *std.Build, linguas: []const []const u8) std.Build.LazyPath {
    const base = b.path("data/dev.ianjohnson.Nonograms.desktop");

    const translate = b.addSystemCommand(&.{ "msgfmt", "--desktop" });
    addPoDependencies(b, translate, linguas);
    translate.addPrefixedDirectoryArg("-d", b.path("po"));
    translate.addPrefixedFileArg("--template=", base);
    return translate.addPrefixedOutputFileArg("-o", "dev.ianjohnson.Nonograms.desktop");
}

fn addPoDependencies(b: *std.Build, run: *std.Build.Step.Run, linguas: []const []const u8) void {
    for (linguas) |lingua| {
        run.addFileInput(b.path(b.fmt("po/{s}.po", .{lingua})));
    }
}
