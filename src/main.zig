const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const intl = @import("libintl");
const pbn = @import("pbn.zig");
const view = @import("view.zig");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ColorButton = view.ColorButton;
const ColorPicker = view.ColorPicker;
const Library = @import("Library.zig");
const View = view.View;
const c_allocator = std.heap.c_allocator;
const fs = std.fs;
const mem = std.mem;
const oom = @import("util.zig").oom;

pub const application_id = "dev.ianjohnson.Nonograms";
const package = "nonograms";

pub fn main() !void {
    // Initialize libintl
    // TODO: figure out what path to use here (or rewrite gettext in Zig and avoid all this complexity???)
    const cwd = try fs.cwd().realpathAlloc(c_allocator, ".");
    defer c_allocator.free(cwd);
    const locale_path = try fs.path.joinZ(c_allocator, &.{ cwd, "locale" });
    defer c_allocator.free(locale_path);
    intl.bindTextDomain(package, locale_path);
    intl.bindTextDomainCodeset(package, "UTF-8");
    intl.setTextDomain(package);

    // Ensure types are defined
    _ = Application.getGObjectType();
    _ = ApplicationWindow.getGObjectType();
    _ = ColorButton.getGObjectType();
    _ = ColorPicker.getGObjectType();
    _ = View.getGObjectType();

    const app = Application.new();
    const status = gio.Application.run(app.as(gio.Application), @intCast(std.os.argv.len), std.os.argv.ptr);
    std.os.exit(@intCast(status));
}

const Application = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.Application;

    pub const getGObjectType = gobject.ext.defineType(Application, .{
        .name = "NonogramsApplication",
        .classInit = &Class.init,
    });

    pub fn new() *Application {
        return gobject.ext.newInstance(Application, .{
            .application_id = application_id,
            .flags = gio.ApplicationFlags{},
        });
    }

    pub fn as(app: *Application, comptime T: type) *T {
        return gobject.ext.as(T, app);
    }

    fn activateImpl(app: *Application) callconv(.C) void {
        const win = ApplicationWindow.new(app);
        gtk.Window.present(win.as(gtk.Window));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Application;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.C) void {
            gio.Application.Class.implementActivate(class, &Application.activateImpl);
        }
    };
};

const ApplicationWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.ApplicationWindow;
    pub const Implements = Parent.Implements;

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

    pub const getGObjectType = gobject.ext.defineType(ApplicationWindow, .{
        .name = "NonogramsApplicationWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(app: *Application) *ApplicationWindow {
        return gobject.ext.newInstance(ApplicationWindow, .{ .application = app });
    }

    pub fn as(win: *ApplicationWindow, comptime T: type) *T {
        return gobject.ext.as(T, win);
    }

    fn init(win: *ApplicationWindow, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(win.as(gtk.Widget));

        const open = gio.SimpleAction.new("open", null);
        _ = gio.SimpleAction.connectActivate(open, *ApplicationWindow, &handleOpenAction, win, .{});
        gio.ActionMap.addAction(win.as(gio.ActionMap), open.as(gio.Action));
        const clear = gio.SimpleAction.new("clear", null);
        gio.SimpleAction.setEnabled(clear, 0);
        gio.ActionMap.addAction(win.as(gio.ActionMap), clear.as(gio.Action));
        _ = gio.SimpleAction.connectActivate(clear, *ApplicationWindow, &handleClearAction, win, .{});
        win.private().clear_action = clear;
        const about = gio.SimpleAction.new("about", null);
        _ = gio.SimpleAction.connectActivate(about, *ApplicationWindow, &handleAboutAction, win, .{});
        gio.ActionMap.addAction(win.as(gio.ActionMap), about.as(gio.Action));

        _ = gtk.Window.connectCloseRequest(win, ?*anyopaque, &handleCloseRequest, null, .{});
        _ = gtk.Button.connectClicked(win.private().library_menu_button, *ApplicationWindow, &handleLibraryMenuButtonClicked, win, .{});
        _ = gtk.ListBox.connectRowActivated(win.private().library_list, *ApplicationWindow, &handleLibraryRowActivated, win, .{});
        _ = gtk.ListBox.connectRowActivated(win.private().puzzle_list, *ApplicationWindow, &handlePuzzleRowActivated, win, .{});
        _ = View.connectSolved(win.private().view, *ApplicationWindow, &handlePuzzleSolved, win, .{});

        gtk.Window.setFocus(win.as(gtk.Window), win.private().view.as(gtk.Widget));

        win.loadLibrary();
    }

    fn finalize(win: *ApplicationWindow) callconv(.C) void {
        if (win.private().library) |*library| {
            library.deinit();
        }
        if (win.private().puzzle_set) |*puzzle_set| {
            puzzle_set.deinit();
        }
        Class.parent.as(gobject.Object.Class).finalize.?(win.as(gobject.Object));
    }

    fn loadLibrary(win: *ApplicationWindow) void {
        if (win.private().library) |*library| {
            library.deinit();
        }
        var library = Library.load() catch {
            adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to read library")));
            return;
        };
        if (library.entries.len == 0) {
            if (Library.copyDefaultPuzzles()) {
                library = Library.load() catch {
                    adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to read library")));
                    return;
                };
            } else |_| {
                adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to add default puzzles to library")));
            }
        }
        win.private().library = library;
        const library_list = win.private().library_list;
        while (gtk.Widget.getFirstChild(library_list.as(gtk.Widget))) |child| {
            gtk.ListBox.remove(library_list, child);
        }
        for (library.entries) |entry| {
            const action_row = adw.ActionRow.new();
            adw.PreferencesRow.setTitle(action_row.as(adw.PreferencesRow), entry.title orelse intl.gettext("Untitled"));
            gtk.ListBoxRow.setActivatable(action_row.as(gtk.ListBoxRow), 1);
            gtk.ListBox.append(library_list, action_row.as(gtk.Widget));
        }

        gtk.Stack.setVisibleChildName(win.private().stack, "library");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 0);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 0);
        gio.SimpleAction.setEnabled(win.private().clear_action, 0);
    }

    fn openFile(win: *ApplicationWindow, file: *gio.File) void {
        const contents = file.loadBytes(null, null, null) orelse return;
        defer contents.unref();
        if (win.private().puzzle_set_uri) |uri| {
            glib.free(uri.ptr);
        }
        const uri = mem.sliceTo(file.getUri(), 0);
        win.private().puzzle_set_uri = uri;
        const bytes = glib.ext.Bytes.getDataSlice(contents);
        const puzzle_set = pbn.PuzzleSet.parseBytes(c_allocator, bytes) catch {
            adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to load puzzle")));
            return;
        };
        win.loadPuzzleSet(puzzle_set);
    }

    fn loadPuzzleSet(win: *ApplicationWindow, puzzle_set: pbn.PuzzleSet) void {
        if (win.private().puzzle_set) |*ps| {
            ps.deinit();
        }
        win.private().puzzle_set = puzzle_set;
        win.private().puzzle_index = null;
        const puzzle_list = win.private().puzzle_list;
        while (gtk.Widget.getFirstChild(puzzle_list.as(gtk.Widget))) |child| {
            gtk.ListBox.remove(puzzle_list, child);
        }
        adw.WindowTitle.setSubtitle(win.private().window_title, puzzle_set.title orelse "");
        gtk.Label.setLabel(win.private().puzzle_set_title, puzzle_set.title orelse intl.gettext("Puzzles"));
        gtk.Label.setLabel(win.private().info_title, puzzle_set.title orelse intl.gettext("Untitled puzzle set"));
        if (puzzle_set.author) |author| {
            gtk.Label.setLabel(win.private().info_author, author);
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 0);
        }
        if (puzzle_set.copyright) |copyright| {
            gtk.Label.setLabel(win.private().info_copyright, copyright);
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 0);
        }
        if (puzzle_set.source) |source| {
            gtk.Label.setLabel(win.private().info_source, source);
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 0);
        }
        for (puzzle_set.puzzles) |puzzle| {
            const action_row = adw.ActionRow.new();
            adw.PreferencesRow.setTitle(action_row.as(adw.PreferencesRow), puzzle.title orelse intl.gettext("Untitled"));
            gtk.ListBoxRow.setActivatable(action_row.as(gtk.ListBoxRow), 1);
            gtk.ListBox.append(puzzle_list, action_row.as(gtk.Widget));
        }

        gtk.Stack.setVisibleChildName(win.private().stack, "puzzle_selector");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 1);
        gio.SimpleAction.setEnabled(win.private().clear_action, 0);
    }

    fn loadPuzzle(win: *ApplicationWindow, puzzle: pbn.Puzzle) void {
        const puzzle_set = win.private().puzzle_set orelse return;
        adw.WindowTitle.setSubtitle(win.private().window_title, puzzle.title orelse "");
        gtk.Label.setLabel(win.private().info_title, puzzle.title orelse intl.gettext("Untitled puzzle"));
        if (puzzle.author orelse puzzle_set.author) |author| {
            gtk.Label.setLabel(win.private().info_author, author);
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 0);
        }
        if (puzzle.copyright orelse puzzle_set.copyright) |copyright| {
            gtk.Label.setLabel(win.private().info_copyright, copyright);
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 0);
        }
        if (puzzle.source orelse puzzle_set.source) |source| {
            gtk.Label.setLabel(win.private().info_source, source);
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 0);
        }
        win.private().view.load(puzzle);

        gtk.Stack.setVisibleChildName(win.private().stack, "view");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 1);
        gio.SimpleAction.setEnabled(win.private().clear_action, 1);
    }

    fn handleOpenAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.C) void {
        const chooser = gtk.FileChooserNative.new(
            intl.gettext("Open Puzzle"),
            win.as(gtk.Window),
            .open,
            intl.gettext("_Open"),
            intl.gettext("_Cancel"),
        );
        const filter = gtk.FileFilter.new();
        gtk.FileFilter.setName(filter, "PBN XML");
        gtk.FileFilter.addPattern(filter, "*.pbn");
        gtk.FileFilter.addPattern(filter, "*.xml");
        gtk.FileChooser.addFilter(chooser.as(gtk.FileChooser), filter);
        _ = gtk.NativeDialog.connectResponse(chooser, *ApplicationWindow, &handleOpenResponse, win, .{});
        gtk.NativeDialog.show(chooser.as(gtk.NativeDialog));
    }

    fn handleClearAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.C) void {
        win.private().view.clear();
        const toast = adw.Toast.new("Puzzle cleared");
        adw.Toast.setButtonLabel(toast, "Undo");
        _ = adw.Toast.connectButtonClicked(toast, *ApplicationWindow, &handleUndoClear, win, .{});
        adw.ToastOverlay.addToast(win.private().toast_overlay, toast);
    }

    fn handleUndoClear(toast: *adw.Toast, win: *ApplicationWindow) callconv(.C) void {
        adw.Toast.dismiss(toast);
        win.private().view.undoClear();
    }

    fn handleAboutAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.C) void {
        const about = adw.AboutWindow.newFromAppdata("/dev/ianjohnson/Nonograms/metainfo.xml", null);
        gtk.Window.setTransientFor(about.as(gtk.Window), win.as(gtk.Window));
        gtk.Window.present(about.as(gtk.Window));
    }

    fn handleOpenResponse(chooser: *gtk.FileChooserNative, _: c_int, win: *ApplicationWindow) callconv(.C) void {
        defer chooser.unref();
        win.saveCurrentImage();
        const file = gtk.FileChooser.getFile(chooser.as(gtk.FileChooser)) orelse return;
        defer file.unref();
        win.openFile(file);
    }

    fn handleCloseRequest(win: *ApplicationWindow, _: ?*anyopaque) callconv(.C) c_int {
        win.saveCurrentImage();
        return 0;
    }

    fn handleLibraryMenuButtonClicked(_: *gtk.Button, win: *ApplicationWindow) callconv(.C) void {
        win.saveCurrentImage();
        win.loadLibrary();
    }

    fn handleLibraryRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, win: *ApplicationWindow) callconv(.C) void {
        const library = win.private().library orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= library.entries.len) {
            return;
        }
        const file = gio.File.newForPath(library.entries[index].path);
        defer file.unref();
        win.openFile(file);
    }

    fn handlePuzzleRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, win: *ApplicationWindow) callconv(.C) void {
        const puzzle_set = win.private().puzzle_set orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= puzzle_set.puzzles.len) {
            return;
        }
        win.private().puzzle_index = index;
        win.loadPuzzle(puzzle_set.puzzles[index]);
    }

    fn handlePuzzleSolved(_: *View, win: *ApplicationWindow) callconv(.C) void {
        const puzzle_set = win.private().puzzle_set orelse return;
        const puzzle = puzzle_set.puzzles[win.private().puzzle_index orelse return];
        adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(puzzle.description orelse "Congratulations!"));
    }

    fn saveCurrentImage(win: *ApplicationWindow) void {
        const puzzle_set_path = path: {
            const uri = win.private().puzzle_set_uri orelse return;
            const file = gio.File.newForUri(uri);
            defer file.unref();
            break :path mem.sliceTo(file.getPath() orelse return, 0);
        };
        defer glib.free(puzzle_set_path.ptr);
        const puzzle_index = win.private().puzzle_index orelse return;

        var puzzle_set = win.private().puzzle_set orelse return;
        var puzzle = puzzle_set.puzzles[puzzle_index];
        const image = (win.private().view.getImage(c_allocator, puzzle.colors.values()) catch return) orelse return;
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

    fn private(win: *ApplicationWindow) *Private {
        return gobject.ext.impl_helpers.getPrivate(win, Private, Private.offset);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = ApplicationWindow;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.Class.implementFinalize(class, &finalize);
            gtk.Widget.Class.setTemplateFromResource(class.as(gtk.Widget.Class), "/dev/ianjohnson/Nonograms/ui/window.ui");
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

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.ext.BindTemplateChildOptions) void {
            gtk.ext.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }
    };
};
