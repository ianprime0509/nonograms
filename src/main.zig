const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const pbn = @import("pbn.zig");
const view = @import("view.zig");
const ColorButton = view.ColorButton;
const ColorPicker = view.ColorPicker;
const View = view.View;
const c_allocator = std.heap.c_allocator;
const mem = std.mem;

pub fn main() !void {
    _ = Application.getType();
    _ = ApplicationWindow.getType();
    _ = ColorButton.getType();
    _ = ColorPicker.getType();
    _ = View.getType();
    const status = Application.new().run(@intCast(c_int, std.os.argv.len), std.os.argv.ptr);
    std.os.exit(@intCast(u8, status));
}

const Application = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.Application;
    const Self = @This();

    pub const getType = gobject.registerType(Self, .{
        .name = "NonogramsApplication",
    });

    pub fn new() *Self {
        return Self.newWith(.{
            .application_id = "dev.ianjohnson.Nonograms",
            .flags = gio.ApplicationFlags{},
        });
    }

    fn activateImpl(self: *Self) callconv(.C) void {
        const win = ApplicationWindow.new(self);
        win.present();
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.implementActivate(&Self.activateImpl);
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Self);
    };
};

const ApplicationWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.ApplicationWindow;
    const Self = @This();

    pub const Private = struct {
        view: *View,

        pub var offset: c_int = 0;
    };

    const template = @embedFile("ui/window.ui");

    pub const getType = gobject.registerType(ApplicationWindow, .{
        .name = "NonogramsApplicationWindow",
    });

    pub fn new(app: *Application) *Self {
        return Self.newWith(.{ .application = app });
    }

    pub fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();
        var puzzle_set = pbn.PuzzleSet.parseFile(c_allocator, "9381.pbn") catch @panic("oh no");
        defer puzzle_set.deinit();
        self.private().view.load(puzzle_set.puzzles[0]);

        const about = gio.SimpleAction.new("about", null);
        _ = about.connectActivate(*Self, &handleAboutAction, self, .{});
        self.addAction(about.as(gio.Action));
        const open = gio.SimpleAction.new("open", null);
        _ = open.connectActivate(*Self, &handleOpenAction, self, .{});
        self.addAction(open.as(gio.Action));
    }

    fn handleAboutAction(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.C) void {
        const about = adw.AboutWindow.new();
        about.setApplicationName("Nonograms");
        about.setDeveloperName("Ian Johnson");
        about.setCopyright("© 2023 Ian Johnson");
        about.setWebsite("https://github.com/ianprime0509/nonograms");
        about.setIssueUrl("https://github.com/ianprime0509/nonograms/issues");
        about.setLicenseType(gtk.License.mit_x11);
        about.setTransientFor(self.as(gtk.Window));
        about.present();
    }

    fn handleOpenAction(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.C) void {
        const chooser = gtk.FileChooserNative.new("Open Puzzle", self.as(gtk.Window), .open, "_Open", "_Cancel");
        const filter = gtk.FileFilter.new();
        filter.setName("PBN XML");
        filter.addPattern("*.pbn");
        filter.addPattern("*.xml");
        chooser.addFilter(filter);
        _ = chooser.connectResponse(*Self, &handleOpenResponse, self, .{});
        chooser.show();
    }

    fn handleOpenResponse(chooser: *gtk.FileChooserNative, _: gtk.ResponseType, self: *Self) callconv(.C) void {
        defer chooser.unref();
        const file = chooser.getFile() orelse return;
        defer file.unref();
        const contents = file.loadBytes(null, null, null) orelse return;
        defer contents.unref();
        const url = file.getUri();
        defer glib.free(url);
        var size: usize = undefined;
        const bytes = contents.getData(&size);
        var puzzle_set = pbn.PuzzleSet.parseBytes(c_allocator, bytes[0..size], mem.sliceTo(url, 0)) catch @panic("TODO show error");
        defer puzzle_set.deinit();
        self.private().view.load(puzzle_set.puzzles[0]);
    }

    pub usingnamespace Parent.Methods(Self);
    pub usingnamespace gio.ActionMap.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.setTemplate(glib.Bytes.newFromSlice(template));
            class.bindTemplateChild("view", .{ .private = true });
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Self);
    };
};
