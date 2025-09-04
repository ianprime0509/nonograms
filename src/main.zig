const std = @import("std");
const build_options = @import("build_options");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const intl = @import("libintl");
const pbn = @import("libpbn");
const view = @import("view.zig");
const ColorButton = view.ColorButton;
const ColorPicker = view.ColorPicker;
const Library = @import("Library.zig");
const View = view.View;
const c_allocator = std.heap.c_allocator;
const mem = std.mem;
const oom = @import("util.zig").oom;

const package = "nonograms";

pub fn main() !void {
    intl.bindTextDomain(package, build_options.locale_dir ++ "");
    intl.bindTextDomainCodeset(package, "UTF-8");
    intl.setTextDomain(package);

    const app = Application.new();
    const status = gio.Application.run(app.as(gio.Application), @intCast(std.os.argv.len), std.os.argv.ptr);
    std.process.exit(@intCast(status));
}

const Application = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.Application;

    pub const getGObjectType = gobject.ext.defineClass(Application, .{
        .name = "NonogramsApplication",
        .classInit = &Class.init,
    });

    pub fn new() *Application {
        return gobject.ext.newInstance(Application, .{
            .application_id = build_options.app_id,
            .flags = gio.ApplicationFlags{},
        });
    }

    pub fn as(app: *Application, comptime T: type) *T {
        return gobject.ext.as(T, app);
    }

    fn activateImpl(app: *Application) callconv(.c) void {
        const win = ApplicationWindow.new(app);
        gtk.Window.present(win.as(gtk.Window));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Application;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.c) void {
            gio.Application.virtual_methods.activate.implement(class, &Application.activateImpl);
        }
    };
};

const ApplicationWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.ApplicationWindow;

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
        puzzle_state: ?PuzzleState,
        clear_action: *gio.SimpleAction,

        var offset: c_int = 0;
    };

    const PuzzleState = struct {
        set: pbn.PuzzleSet,
        file: *gio.File,
        puzzle: pbn.Puzzle.Index,

        fn deinit(puzzle: *PuzzleState) void {
            puzzle.set.deinit();
            puzzle.file.unref();
            puzzle.* = undefined;
        }
    };

    pub const getGObjectType = gobject.ext.defineClass(ApplicationWindow, .{
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

    fn init(win: *ApplicationWindow, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(win.as(gtk.Widget));

        const open = gio.SimpleAction.new("open", null);
        _ = gio.SimpleAction.signals.activate.connect(open, *ApplicationWindow, &handleOpenAction, win, .{});
        gio.ActionMap.addAction(win.as(gio.ActionMap), open.as(gio.Action));
        const clear = gio.SimpleAction.new("clear", null);
        gio.SimpleAction.setEnabled(clear, 0);
        gio.ActionMap.addAction(win.as(gio.ActionMap), clear.as(gio.Action));
        _ = gio.SimpleAction.signals.activate.connect(clear, *ApplicationWindow, &handleClearAction, win, .{});
        win.private().clear_action = clear;
        const about = gio.SimpleAction.new("about", null);
        _ = gio.SimpleAction.signals.activate.connect(about, *ApplicationWindow, &handleAboutAction, win, .{});
        gio.ActionMap.addAction(win.as(gio.ActionMap), about.as(gio.Action));

        _ = gtk.Window.signals.close_request.connect(win, ?*anyopaque, &handleCloseRequest, null, .{});
        _ = gtk.Button.signals.clicked.connect(win.private().library_menu_button, *ApplicationWindow, &handleLibraryMenuButtonClicked, win, .{});
        _ = gtk.ListBox.signals.row_activated.connect(win.private().library_list, *ApplicationWindow, &handleLibraryRowActivated, win, .{});
        _ = gtk.ListBox.signals.row_activated.connect(win.private().puzzle_list, *ApplicationWindow, &handlePuzzleRowActivated, win, .{});
        _ = View.signals.solved.connect(win.private().view, *ApplicationWindow, &handlePuzzleSolved, win, .{});

        gtk.Window.setFocus(win.as(gtk.Window), win.private().view.as(gtk.Widget));

        if (build_options.devel) {
            gtk.Widget.addCssClass(win.as(gtk.Widget), "devel");
        }

        win.loadLibrary();
    }

    fn dispose(win: *ApplicationWindow) callconv(.c) void {
        gtk.Widget.disposeTemplate(win.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, win.as(Parent));
    }

    fn finalize(win: *ApplicationWindow) callconv(.c) void {
        if (win.private().library) |*library| library.deinit();
        if (win.private().puzzle_state) |*puzzle| puzzle.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, win.as(Parent));
    }

    fn loadLibrary(win: *ApplicationWindow) void {
        if (win.private().library) |*library| {
            library.deinit();
        }
        var library = Library.load(c_allocator) catch {
            adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to read library")));
            return;
        };
        if (library.entries.len == 0) {
            if (Library.copyDefaultPuzzles(c_allocator)) {
                library = Library.load(c_allocator) catch {
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

        adw.WindowTitle.setSubtitle(win.private().window_title, "");
        gtk.Stack.setVisibleChildName(win.private().stack, "library");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 0);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 0);
        gio.SimpleAction.setEnabled(win.private().clear_action, 0);
    }

    fn openFile(win: *ApplicationWindow, file: *gio.File) void {
        const contents = file.loadBytes(null, null, null) orelse return;
        defer contents.unref();
        var diag: pbn.Diagnostics = .init(c_allocator);
        defer diag.deinit();
        const puzzle_set = pbn.PuzzleSet.parse(c_allocator, glib.ext.Bytes.getDataSlice(contents), &diag) catch {
            for (diag.errors.items) |err| {
                std.log.err("puzzle parse error: {}", .{err});
            }
            adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(intl.gettext("Failed to load puzzle")));
            return;
        };

        if (win.private().puzzle_state) |*old_state| old_state.deinit();
        file.ref();
        win.private().puzzle_state = .{
            .set = puzzle_set,
            .file = file,
            .puzzle = .root,
        };

        const puzzle_list = win.private().puzzle_list;
        while (gtk.Widget.getFirstChild(puzzle_list.as(gtk.Widget))) |child| {
            gtk.ListBox.remove(puzzle_list, child);
        }
        adw.WindowTitle.setSubtitle(win.private().window_title, puzzle_set.title(.root) orelse "");
        gtk.Label.setLabel(win.private().puzzle_set_title, puzzle_set.title(.root) orelse intl.gettext("Puzzles"));
        gtk.Label.setLabel(win.private().info_title, puzzle_set.title(.root) orelse intl.gettext("Untitled puzzle set"));
        if (puzzle_set.author(.root)) |author| {
            gtk.Label.setLabel(win.private().info_author, author);
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 0);
        }
        if (puzzle_set.copyright(.root)) |copyright| {
            gtk.Label.setLabel(win.private().info_copyright, copyright);
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 0);
        }
        if (puzzle_set.source(.root)) |source| {
            gtk.Label.setLabel(win.private().info_source, source);
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 0);
        }
        for (1..puzzle_set.puzzles.items.len) |puzzle_index| {
            const puzzle: pbn.Puzzle.Index = @enumFromInt(puzzle_index);
            const action_row = adw.ActionRow.new();
            adw.PreferencesRow.setTitle(action_row.as(adw.PreferencesRow), puzzle_set.title(puzzle) orelse intl.gettext("Untitled"));
            gtk.ListBoxRow.setActivatable(action_row.as(gtk.ListBoxRow), 1);
            gtk.ListBox.append(puzzle_list, action_row.as(gtk.Widget));
        }

        gtk.Stack.setVisibleChildName(win.private().stack, "puzzle_selector");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 1);
        gio.SimpleAction.setEnabled(win.private().clear_action, 0);
    }

    fn loadPuzzle(win: *ApplicationWindow) void {
        const state = &(win.private().puzzle_state orelse return);
        adw.WindowTitle.setSubtitle(win.private().window_title, state.set.title(state.puzzle) orelse "");
        gtk.Label.setLabel(win.private().info_title, state.set.title(state.puzzle) orelse intl.gettext("Untitled puzzle"));
        if (state.set.author(state.puzzle)) |author| {
            gtk.Label.setLabel(win.private().info_author, author);
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_author.as(gtk.Widget), 0);
        }
        if (state.set.copyright(state.puzzle)) |copyright| {
            gtk.Label.setLabel(win.private().info_copyright, copyright);
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_copyright.as(gtk.Widget), 0);
        }
        if (state.set.source(state.puzzle)) |source| {
            gtk.Label.setLabel(win.private().info_source, source);
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(win.private().info_source.as(gtk.Widget), 0);
        }
        win.private().view.load(&state.set, state.puzzle);

        gtk.Stack.setVisibleChildName(win.private().stack, "view");
        gtk.Widget.setVisible(win.private().library_menu_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(win.private().info_menu_button.as(gtk.Widget), 1);
        gio.SimpleAction.setEnabled(win.private().clear_action, 1);
    }

    fn handleOpenAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.unref();
        gtk.FileDialog.setTitle(dialog, intl.gettext("Open Puzzle"));
        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        defer filters.unref();
        const filter = gtk.FileFilter.new();
        gtk.FileFilter.setName(filter, "PBN XML");
        gtk.FileFilter.addPattern(filter, "*.pbn");
        gtk.FileFilter.addPattern(filter, "*.xml");
        filters.append(filter.as(gobject.Object));
        gtk.FileDialog.setFilters(dialog, filters.as(gio.ListModel));
        gtk.FileDialog.open(dialog, win.as(gtk.Window), null, @ptrCast(&handleOpenReady), win);
    }

    fn handleOpenReady(dialog: *gtk.FileDialog, res: *gio.AsyncResult, win: *ApplicationWindow) callconv(.c) void {
        const file = gtk.FileDialog.openFinish(dialog, res, null) orelse return;
        defer file.unref();
        win.openFile(file);
    }

    fn handleClearAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.c) void {
        win.private().view.clear();
        const toast = adw.Toast.new("Puzzle cleared");
        adw.Toast.setButtonLabel(toast, "Undo");
        _ = adw.Toast.signals.button_clicked.connect(toast, *ApplicationWindow, &handleUndoClear, win, .{});
        adw.ToastOverlay.addToast(win.private().toast_overlay, toast);
    }

    fn handleUndoClear(toast: *adw.Toast, win: *ApplicationWindow) callconv(.c) void {
        adw.Toast.dismiss(toast);
        win.private().view.undoClear();
    }

    fn handleAboutAction(_: *gio.SimpleAction, _: ?*glib.Variant, win: *ApplicationWindow) callconv(.c) void {
        const about = adw.AboutWindow.newFromAppdata("/dev/ianjohnson/Nonograms/metainfo.xml", null);
        gtk.Window.setTransientFor(about.as(gtk.Window), win.as(gtk.Window));
        gtk.Window.present(about.as(gtk.Window));
    }

    fn handleCloseRequest(win: *ApplicationWindow, _: ?*anyopaque) callconv(.c) c_int {
        win.saveCurrentImage();
        return 0;
    }

    fn handleLibraryMenuButtonClicked(_: *gtk.Button, win: *ApplicationWindow) callconv(.c) void {
        win.saveCurrentImage();
        win.loadLibrary();
    }

    fn handleLibraryRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, win: *ApplicationWindow) callconv(.c) void {
        const library = win.private().library orelse return;
        const index: usize = @intCast(row.getIndex());
        if (index >= library.entries.len) {
            return;
        }
        const file = gio.File.newForPath(library.entries[index].path);
        defer file.unref();
        win.openFile(file);
    }

    fn handlePuzzleRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, win: *ApplicationWindow) callconv(.c) void {
        const state = &(win.private().puzzle_state orelse return);
        state.puzzle = @enumFromInt(row.getIndex() + 1);
        win.loadPuzzle();
    }

    fn handlePuzzleSolved(_: *View, win: *ApplicationWindow) callconv(.c) void {
        const state = win.private().puzzle_state orelse return;
        adw.ToastOverlay.addToast(win.private().toast_overlay, adw.Toast.new(state.set.description(state.puzzle) orelse "Congratulations!"));
    }

    fn saveCurrentImage(win: *ApplicationWindow) void {
        const state = win.private().puzzle_state orelse return;
        const path = std.mem.span(state.file.getPath() orelse return);
        var rendered: std.Io.Writer.Allocating = .init(c_allocator);
        defer rendered.deinit();
        state.set.render(c_allocator, &rendered.writer) catch oom();
        std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = rendered.written(),
        }) catch return; // TODO: error handling
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

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
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
