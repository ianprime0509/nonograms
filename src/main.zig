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
        pub usingnamespace Parent.VirtualMethods(Class, Self);
    };
};

const ApplicationWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.ApplicationWindow;
    pub const Implements = Parent.Implements;
    const Self = @This();

    pub const Private = struct {
        window_title: *adw.WindowTitle,
        toast_overlay: *adw.ToastOverlay,
        stack: *gtk.Stack,
        puzzle_set_title: *gtk.Label,
        puzzle_list: *gtk.ListBox,
        view: *View,
        puzzle_set: ?pbn.PuzzleSet,

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

        const about = gio.SimpleAction.new("about", null);
        _ = about.connectActivate(*Self, &handleAboutAction, self, .{});
        self.addAction(about.as(gio.Action));
        const open = gio.SimpleAction.new("open", null);
        _ = open.connectActivate(*Self, &handleOpenAction, self, .{});
        self.addAction(open.as(gio.Action));

        _ = self.private().puzzle_list.connectRowActivated(*Self, &handlePuzzleRowActivated, self, .{});

        // The function setFocus by itself is ambiguous because it could be
        // either gtk_window_set_focus or gtk_root_set_focus
        gtk.Window.OwnMethods(Self).setFocus(self, self.private().view.private().drawing_area.as(gtk.Widget));

        // Load an initial puzzle
        const file = gio.File.newForPath("9381.pbn");
        defer file.unref();
        self.openFile(file);
    }

    fn finalize(self: *Self) callconv(.C) void {
        self.deinitPuzzleSet();
        Class.parent.?.callFinalize(self.as(gobject.Object));
    }

    fn openFile(self: *Self, file: *gio.File) void {
        const contents = file.loadBytes(null, null, null) orelse return;
        defer contents.unref();
        const url = file.getUri();
        defer glib.free(url);
        var size: usize = undefined;
        const bytes = contents.getData(&size);
        var puzzle_set = pbn.PuzzleSet.parseBytes(c_allocator, bytes[0..size], mem.sliceTo(url, 0)) catch {
            self.private().toast_overlay.addToast(adw.Toast.new("Failed to load puzzle"));
            return;
        };
        self.loadPuzzleSet(puzzle_set);
    }

    fn loadPuzzleSet(self: *Self, puzzle_set: pbn.PuzzleSet) void {
        self.deinitPuzzleSet();
        self.private().puzzle_set = puzzle_set;
        const puzzle_list = self.private().puzzle_list;
        while (puzzle_list.getFirstChild()) |child| {
            puzzle_list.remove(child);
        }
        self.private().window_title.setTitle(puzzle_set.title orelse "Nonograms");
        self.private().puzzle_set_title.setLabel(puzzle_set.title orelse "Puzzles");
        if (puzzle_set.description) |description| {
            self.private().window_title.setSubtitle(description);
        }
        for (puzzle_set.puzzles) |puzzle| {
            const action_row = adw.ActionRow.new();
            action_row.setTitle(puzzle.title orelse "Untitled");
            if (puzzle.description) |description| {
                action_row.setSubtitle(description);
            }
            action_row.setActivatable(true);
            puzzle_list.append(action_row.as(gtk.Widget));
        }
        self.private().stack.setVisibleChildName("puzzle_selector");
    }

    fn loadPuzzle(self: *Self, puzzle: pbn.Puzzle) void {
        self.private().window_title.setTitle(puzzle.title orelse "Nonograms");
        if (puzzle.description) |description| {
            self.private().window_title.setSubtitle(description);
        }
        self.private().view.load(puzzle);
        self.private().stack.setVisibleChildName("view");
    }

    fn deinitPuzzleSet(self: *Self) void {
        const puzzle_set = &(self.private().puzzle_set orelse return);
        puzzle_set.deinit();
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

    fn handleOpenResponse(chooser: *gtk.FileChooserNative, _: c_int, self: *Self) callconv(.C) void {
        defer chooser.unref();
        const file = chooser.getFile() orelse return;
        defer file.unref();
        self.openFile(file);
    }

    fn handlePuzzleRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.C) void {
        const puzzle_set = self.private().puzzle_set orelse return;
        const index = @intCast(usize, row.getIndex());
        if (index >= puzzle_set.puzzles.len) {
            return;
        }
        self.loadPuzzle(puzzle_set.puzzles[index]);
    }

    pub usingnamespace Parent.Methods(Self);
    pub usingnamespace gio.ActionMap.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub var parent: ?*Parent.Class = null;

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.implementFinalize(&finalize);
            class.setTemplateFromSlice(template);
            class.bindTemplateChild("window_title", .{ .private = true });
            class.bindTemplateChild("toast_overlay", .{ .private = true });
            class.bindTemplateChild("stack", .{ .private = true });
            class.bindTemplateChild("puzzle_set_title", .{ .private = true });
            class.bindTemplateChild("puzzle_list", .{ .private = true });
            class.bindTemplateChild("view", .{ .private = true });
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.VirtualMethods(Class, Self);
    };
};
