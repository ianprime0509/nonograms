const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const pbn = @import("pbn.zig");
const view = @import("view.zig");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ColorButton = view.ColorButton;
const ColorPicker = view.ColorPicker;
const Library = @import("Library.zig");
const View = view.View;
const c_allocator = std.heap.c_allocator;
const mem = std.mem;
const oom = @import("util.zig").oom;

pub const application_id = "dev.ianjohnson.Nonograms";

pub fn main() !void {
    _ = Application.getType();
    _ = ApplicationWindow.getType();
    _ = ColorButton.getType();
    _ = ColorPicker.getType();
    _ = View.getType();
    const status = Application.new().run(@intCast(std.os.argv.len), std.os.argv.ptr);
    std.os.exit(@intCast(status));
}

const Application = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.Application;
    const Self = @This();

    pub const getType = gobject.defineType(Self, .{
        .name = "NonogramsApplication",
        .classInit = &Class.init,
    });

    pub fn new() *Self {
        return Self.newWith(.{
            .application_id = application_id,
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

        fn init(class: *Class) callconv(.C) void {
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

    const Private = struct {
        window_title: *adw.WindowTitle,
        toast_overlay: *adw.ToastOverlay,
        stack: *gtk.Stack,
        library_list: *gtk.ListBox,
        puzzle_set_title: *gtk.Label,
        puzzle_list: *gtk.ListBox,
        library: ?Library,
        view: *View,
        library_menu_button: *gtk.Button,
        info_menu_button: *gtk.MenuButton,
        info_title: *gtk.Label,
        info_author: *gtk.Label,
        info_copyright: *gtk.Label,
        info_source: *gtk.Label,
        puzzle_set: ?pbn.PuzzleSet,
        puzzle_set_uri: ?[:0]u8,
        puzzle_index: ?usize,
        clear_action: *gio.SimpleAction,

        var offset: c_int = 0;
    };

    pub const getType = gobject.defineType(ApplicationWindow, .{
        .name = "NonogramsApplicationWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(app: *Application) *Self {
        return Self.newWith(.{ .application = app });
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();

        const open = gio.SimpleAction.new("open", null);
        _ = open.connectActivate(*Self, &handleOpenAction, self, .{});
        self.addAction(open.as(gio.Action));
        const clear = gio.SimpleAction.new("clear", null);
        clear.setEnabled(0);
        self.addAction(clear.as(gio.Action));
        _ = clear.connectActivate(*Self, &handleClearAction, self, .{});
        self.private().clear_action = clear;
        const about = gio.SimpleAction.new("about", null);
        _ = about.connectActivate(*Self, &handleAboutAction, self, .{});
        self.addAction(about.as(gio.Action));

        _ = self.connectCloseRequest(?*anyopaque, &handleCloseRequest, null, .{});
        _ = self.private().library_menu_button.connectClicked(*Self, &handleLibraryMenuButtonClicked, self, .{});
        _ = self.private().library_list.connectRowActivated(*Self, &handleLibraryRowActivated, self, .{});
        _ = self.private().puzzle_list.connectRowActivated(*Self, &handlePuzzleRowActivated, self, .{});
        _ = self.private().view.connectSolved(*Self, &handlePuzzleSolved, self, .{});

        // The function setFocus by itself is ambiguous because it could be
        // either gtk_window_set_focus or gtk_root_set_focus
        gtk.Window.OwnMethods(Self).setFocus(self, self.private().view.as(gtk.Widget));

        self.loadLibrary();
    }

    fn finalize(self: *Self) callconv(.C) void {
        if (self.private().library) |*library| {
            library.deinit();
        }
        if (self.private().puzzle_set) |*puzzle_set| {
            puzzle_set.deinit();
        }
        Class.parent.callFinalize(self.as(gobject.Object));
    }

    fn loadLibrary(self: *Self) void {
        if (self.private().library) |*library| {
            library.deinit();
        }
        var library = Library.load() catch {
            self.private().toast_overlay.addToast(adw.Toast.new("Failed to read library"));
            return;
        };
        if (library.entries.len == 0) {
            if (Library.copyDefaultPuzzles()) {
                library = Library.load() catch {
                    self.private().toast_overlay.addToast(adw.Toast.new("Failed to read library"));
                    return;
                };
            } else |_| {
                self.private().toast_overlay.addToast(adw.Toast.new("Failed to add default puzzles to library"));
            }
        }
        self.private().library = library;
        const library_list = self.private().library_list;
        while (library_list.getFirstChild()) |child| {
            library_list.remove(child);
        }
        for (library.entries) |entry| {
            const action_row = adw.ActionRow.new();
            action_row.setTitle(entry.title orelse "Untitled");
            action_row.setActivatable(1);
            library_list.append(action_row.as(gtk.Widget));
        }

        self.private().stack.setVisibleChildName("library");
        self.private().library_menu_button.setVisible(0);
        self.private().info_menu_button.setVisible(0);
        self.private().clear_action.setEnabled(0);
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
        var puzzle_set = pbn.PuzzleSet.parseBytes(c_allocator, bytes[0..size]) catch {
            self.private().toast_overlay.addToast(adw.Toast.new("Failed to load puzzle"));
            return;
        };
        self.loadPuzzleSet(puzzle_set);
    }

    fn loadPuzzleSet(self: *Self, puzzle_set: pbn.PuzzleSet) void {
        if (self.private().puzzle_set) |*ps| {
            ps.deinit();
        }
        self.private().puzzle_set = puzzle_set;
        self.private().puzzle_index = null;
        const puzzle_list = self.private().puzzle_list;
        while (puzzle_list.getFirstChild()) |child| {
            puzzle_list.remove(child);
        }
        self.private().window_title.setSubtitle(puzzle_set.title orelse "");
        self.private().puzzle_set_title.setLabel(puzzle_set.title orelse "Puzzles");
        self.private().info_title.setLabel(puzzle_set.title orelse "Untitled puzzle set");
        if (puzzle_set.author) |author| {
            self.private().info_author.setLabel(author);
            self.private().info_author.setVisible(1);
        } else {
            self.private().info_author.setVisible(0);
        }
        if (puzzle_set.copyright) |copyright| {
            self.private().info_copyright.setLabel(copyright);
            self.private().info_copyright.setVisible(1);
        } else {
            self.private().info_copyright.setVisible(0);
        }
        if (puzzle_set.source) |source| {
            const source_text = std.fmt.allocPrintZ(c_allocator, "From {s}", .{source}) catch oom();
            defer c_allocator.free(source_text);
            self.private().info_source.setLabel(source_text);
            self.private().info_source.setVisible(1);
        } else {
            self.private().info_source.setVisible(0);
        }
        for (puzzle_set.puzzles) |puzzle| {
            const action_row = adw.ActionRow.new();
            action_row.setTitle(puzzle.title orelse "Untitled");
            action_row.setActivatable(1);
            puzzle_list.append(action_row.as(gtk.Widget));
        }

        self.private().stack.setVisibleChildName("puzzle_selector");
        self.private().library_menu_button.setVisible(1);
        self.private().info_menu_button.setVisible(1);
        self.private().clear_action.setEnabled(0);
    }

    fn loadPuzzle(self: *Self, puzzle: pbn.Puzzle) void {
        const puzzle_set = self.private().puzzle_set orelse return;
        self.private().window_title.setSubtitle(puzzle.title orelse "");
        self.private().info_title.setLabel(puzzle.title orelse "Untitled puzzle");
        if (puzzle.author orelse puzzle_set.author) |author| {
            self.private().info_author.setLabel(author);
            self.private().info_author.setVisible(1);
        } else {
            self.private().info_author.setVisible(0);
        }
        if (puzzle.copyright orelse puzzle_set.copyright) |copyright| {
            self.private().info_copyright.setLabel(copyright);
            self.private().info_copyright.setVisible(1);
        } else {
            self.private().info_copyright.setVisible(0);
        }
        if (puzzle.source orelse puzzle_set.source) |source| {
            const source_text = std.fmt.allocPrintZ(c_allocator, "From {s}", .{source}) catch oom();
            defer c_allocator.free(source_text);
            self.private().info_source.setLabel(source_text);
            self.private().info_source.setVisible(1);
        } else {
            self.private().info_source.setVisible(0);
        }
        self.private().view.load(puzzle);

        self.private().stack.setVisibleChildName("view");
        self.private().library_menu_button.setVisible(1);
        self.private().info_menu_button.setVisible(1);
        self.private().clear_action.setEnabled(1);
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

    fn handleClearAction(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.C) void {
        self.private().view.clear();
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

    fn handleOpenResponse(chooser: *gtk.FileChooserNative, _: c_int, self: *Self) callconv(.C) void {
        defer chooser.unref();
        self.saveCurrentImage();
        const file = chooser.getFile() orelse return;
        defer file.unref();
        self.openFile(file);
    }

    fn handleCloseRequest(self: *Self, _: ?*anyopaque) callconv(.C) c_int {
        self.saveCurrentImage();
        return 0;
    }

    fn handleLibraryMenuButtonClicked(_: *gtk.Button, self: *Self) callconv(.C) void {
        self.saveCurrentImage();
        self.loadLibrary();
    }

    fn handleLibraryRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.C) void {
        const library = self.private().library orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= library.entries.len) {
            return;
        }
        const file = gio.File.newForPath(library.entries[index].path);
        defer file.unref();
        self.openFile(file);
    }

    fn handlePuzzleRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.C) void {
        const puzzle_set = self.private().puzzle_set orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= puzzle_set.puzzles.len) {
            return;
        }
        self.private().puzzle_index = index;
        self.loadPuzzle(puzzle_set.puzzles[index]);
    }

    fn handlePuzzleSolved(_: *View, _: u32, self: *Self) callconv(.C) void {
        const puzzle_set = self.private().puzzle_set orelse return;
        const puzzle = puzzle_set.puzzles[self.private().puzzle_index orelse return];
        self.private().toast_overlay.addToast(adw.Toast.new(puzzle.description orelse "Congratulations!"));
    }

    fn saveCurrentImage(self: *Self) void {
        const puzzle_set_path = path: {
            const uri = self.private().puzzle_set_uri orelse return;
            const file = gio.File.newForUri(uri);
            defer file.unref();
            break :path mem.sliceTo(file.getPath() orelse return, 0);
        };
        defer glib.free(puzzle_set_path.ptr);
        const puzzle_index = self.private().puzzle_index orelse return;

        var puzzle_set = self.private().puzzle_set orelse return;
        var puzzle = puzzle_set.puzzles[puzzle_index];
        const image = (self.private().view.getImage(c_allocator, puzzle.colors.values()) catch return) orelse return;
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
            solutions.append(c_allocator, .{ .type = .saved, .image = undefined, .notes = &.{} }) catch oom();
        }
        solutions.items[saved_index].image = image;
        puzzle.solutions = solutions.items;
        var puzzles = c_allocator.dupe(pbn.Puzzle, puzzle_set.puzzles) catch oom();
        defer c_allocator.free(puzzles);
        puzzles[puzzle_index] = puzzle;
        puzzle_set.puzzles = puzzles;

        puzzle_set.writeFile(puzzle_set_path) catch return;
    }

    fn private(self: *Self) *Private {
        return gobject.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub usingnamespace Parent.Methods(Self);
    pub usingnamespace gio.ActionMap.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            class.implementFinalize(&finalize);
            class.setTemplateFromResource("/dev/ianjohnson/Nonograms/ui/window.ui");
            class.bindTemplateChildPrivate("window_title", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("stack", .{});
            class.bindTemplateChildPrivate("library_list", .{});
            class.bindTemplateChildPrivate("puzzle_set_title", .{});
            class.bindTemplateChildPrivate("puzzle_list", .{});
            class.bindTemplateChildPrivate("library_menu_button", .{});
            class.bindTemplateChildPrivate("info_menu_button", .{});
            class.bindTemplateChildPrivate("info_title", .{});
            class.bindTemplateChildPrivate("info_author", .{});
            class.bindTemplateChildPrivate("info_copyright", .{});
            class.bindTemplateChildPrivate("info_source", .{});
            class.bindTemplateChildPrivate("view", .{});
        }

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.BindTemplateChildOptions) void {
            gtk.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.VirtualMethods(Class, Self);
    };
};
