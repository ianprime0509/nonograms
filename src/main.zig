const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const pbn = @import("pbn.zig");
const util = @import("util.zig");
const view = @import("view.zig");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ColorButton = view.ColorButton;
const ColorPicker = view.ColorPicker;
const View = view.View;
const c_allocator = std.heap.c_allocator;
const mem = std.mem;
const oom = util.oom;

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
        puzzle_set_uri: ?[:0]u8,
        puzzle_index: ?usize,

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

        _ = self.connectCloseRequest(?*anyopaque, &handleCloseRequest, null, .{});
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
        if (self.private().puzzle_set_uri) |uri| {
            glib.free(uri.ptr);
        }
        const uri = mem.sliceTo(file.getUri(), 0);
        self.private().puzzle_set_uri = uri;
        var size: usize = undefined;
        const bytes = contents.getData(&size);
        var puzzle_set = pbn.PuzzleSet.parseBytes(c_allocator, bytes[0..size], uri) catch {
            self.private().toast_overlay.addToast(adw.Toast.new("Failed to load puzzle"));
            return;
        };
        self.loadPuzzleSet(puzzle_set);
    }

    fn loadPuzzleSet(self: *Self, puzzle_set: pbn.PuzzleSet) void {
        self.deinitPuzzleSet();
        self.private().puzzle_set = puzzle_set;
        self.private().puzzle_index = null;
        const puzzle_list = self.private().puzzle_list;
        while (puzzle_list.getFirstChild()) |child| {
            puzzle_list.remove(child);
        }
        self.private().window_title.setSubtitle(puzzle_set.title orelse "");
        self.private().puzzle_set_title.setLabel(puzzle_set.title orelse "Puzzles");
        for (puzzle_set.puzzles) |puzzle| {
            const action_row = adw.ActionRow.new();
            action_row.setTitle(puzzle.title orelse "Untitled");
            action_row.setActivatable(true);
            puzzle_list.append(action_row.as(gtk.Widget));
        }
        self.private().stack.setVisibleChildName("puzzle_selector");
    }

    fn loadPuzzle(self: *Self, puzzle: pbn.Puzzle) void {
        self.private().window_title.setSubtitle(puzzle.title orelse "");
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

    fn handleCloseRequest(self: *Self, _: ?*anyopaque) callconv(.C) bool {
        const puzzle_set_path = path: {
            const uri = self.private().puzzle_set_uri orelse return false;
            const file = gio.File.newForUri(uri);
            defer file.unref();
            break :path mem.sliceTo(file.getPath() orelse return false, 0);
        };
        defer glib.free(puzzle_set_path.ptr);
        const puzzle_index = self.private().puzzle_index orelse return false;

        var puzzle_set = self.private().puzzle_set orelse return false;
        var puzzle = puzzle_set.puzzles[puzzle_index];
        const image = (self.private().view.getImage(c_allocator, puzzle.colors.values()) catch return false) orelse return false;
        defer image.deinit(c_allocator);
        var solutions = ArrayListUnmanaged(pbn.Solution).initCapacity(c_allocator, puzzle.solutions.len) catch oom();
        defer solutions.deinit(c_allocator);
        solutions.appendSliceAssumeCapacity(puzzle.solutions);
        var saved_index: usize = 0;
        while (saved_index < solutions.items.len) : (saved_index += 1) {
            if (solutions.items[saved_index].type == .saved) {
                break;
            }
        } else {
            solutions.append(c_allocator, .{ .type = .saved, .image = undefined }) catch oom();
        }
        solutions.items[saved_index].image = image;
        puzzle.solutions = solutions.items;
        var puzzles = c_allocator.dupe(pbn.Puzzle, puzzle_set.puzzles) catch oom();
        defer c_allocator.free(puzzles);
        puzzles[puzzle_index] = puzzle;
        puzzle_set.puzzles = puzzles;

        puzzle_set.writeFile(puzzle_set_path) catch return false;

        return false;
    }

    fn handlePuzzleRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.C) void {
        const puzzle_set = self.private().puzzle_set orelse return;
        const index = @intCast(usize, row.getIndex());
        if (index >= puzzle_set.puzzles.len) {
            return;
        }
        self.private().puzzle_index = index;
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
