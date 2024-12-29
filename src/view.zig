const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const pbn = @import("libpbn");
const util = @import("util.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const oom = util.oom;

const State = struct {
    set: *pbn.PuzzleSet,
    image: pbn.Image,
    selected_color: ?pbn.Color.Index,
    max_row_hints: usize,
    max_column_hints: usize,
    hover_tile: ?Cell,
    solved: bool,

    fn load(set: *pbn.PuzzleSet, puzzle: pbn.Puzzle.Index) Allocator.Error!State {
        var max_row_hints: usize = 0;
        for (0..set.rowCount(puzzle)) |i| {
            max_row_hints = @max(max_row_hints, set.rowClueCount(puzzle, @enumFromInt(i)));
        }
        var max_column_hints: usize = 0;
        for (0..set.columnCount(puzzle)) |j| {
            max_column_hints = @max(max_column_hints, set.columnClueCount(puzzle, @enumFromInt(j)));
        }

        const saved_solution = try set.getOrAddSavedSolution(puzzle);
        const saved_image = set.savedSolutionImage(puzzle, saved_solution);

        var state: State = .{
            .set = set,
            .image = saved_image,
            .selected_color = .default,
            .max_row_hints = max_row_hints,
            .max_column_hints = max_column_hints,
            .hover_tile = null,
            .solved = undefined,
        };
        state.solved = state.isSolved();
        return state;
    }

    fn isSolved(state: State) bool {
        return state.set.imageSolved(state.image);
    }

    fn moveHoverTile(state: *State, drow: isize, dcolumn: isize) void {
        var hover_tile = state.hover_tile orelse {
            state.hover_tile = .{ .row = state.max_column_hints, .column = state.max_row_hints };
            return;
        };
        if (drow < 0) {
            hover_tile.row -|= @intCast(-drow);
        } else {
            hover_tile.row +|= @intCast(drow);
        }
        if (dcolumn < 0) {
            hover_tile.column -|= @intCast(-dcolumn);
        } else {
            hover_tile.column +|= @intCast(dcolumn);
        }
        state.hover_tile = .{
            .row = std.math.clamp(hover_tile.row, state.max_column_hints, state.max_column_hints + state.image.rows - 1),
            .column = std.math.clamp(hover_tile.column, state.max_row_hints, state.max_row_hints + state.image.columns - 1),
        };
    }

    fn tilePosition(state: State, row: usize, column: usize) ?struct { usize, usize } {
        const row_in_bounds = row >= state.max_column_hints and row < state.max_column_hints + state.image.rows;
        const column_in_bounds = column >= state.max_row_hints and column < state.max_row_hints + state.image.columns;
        if (row_in_bounds and column_in_bounds) {
            return .{ row - state.max_column_hints, column - state.max_row_hints };
        } else {
            return null;
        }
    }
};

const Cell = struct {
    row: usize,
    column: usize,
};

const Point = struct {
    x: f64,
    y: f64,
};

const Dimensions = struct {
    board_pos: Point,
    tile_size: f64,

    const gap_frac = 0.1;

    fn positionTile(dim: Dimensions, x: f64, y: f64) ?Cell {
        const rel_x = x - dim.board_pos.x;
        const rel_y = y - dim.board_pos.y;
        if (rel_x < 0 or rel_y < 0) {
            return null;
        } else {
            return .{
                .row = @intFromFloat(rel_y / (dim.tile_size + gap_frac * dim.tile_size)),
                .column = @intFromFloat(rel_x / (dim.tile_size + gap_frac * dim.tile_size)),
            };
        }
    }

    fn tilePosition(dim: Dimensions, row: usize, column: usize) Point {
        return .{
            .x = dim.board_pos.x + @as(f64, @floatFromInt(column)) * (dim.tile_size + gap_frac * dim.tile_size),
            .y = dim.board_pos.y + @as(f64, @floatFromInt(row)) * (dim.tile_size + gap_frac * dim.tile_size),
        };
    }
};

const Rule = struct {
    inc: usize,
    weight: f64,
};

pub const View = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Widget;

    const Private = struct {
        box: *gtk.Box,
        drawing_area: *gtk.DrawingArea,
        color_picker: *ColorPicker,
        draw_start: Point,
        keyboard_drawing: bool,
        dimensions: ?Dimensions,
        state: ?State,
        cleared_cells: []pbn.Cell,
        arena: ArenaAllocator,

        var offset: c_int = 0;
    };

    const rules = [_]Rule{
        .{ .inc = 1, .weight = 0.1 },
        .{ .inc = 5, .weight = 0.5 },
        .{ .inc = 10, .weight = 1 },
    };

    pub const getGObjectType = gobject.ext.defineClass(View, .{
        .name = "NonogramsView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const solved = struct {
            pub const name = "solved";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, View, &.{}, void);
        };
    };

    pub fn new() *View {
        return View.newWith(.{});
    }

    pub fn as(view: *View, comptime T: type) *T {
        return gobject.ext.as(T, view);
    }

    fn init(view: *View, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(view.as(gtk.Widget));
        gtk.Widget.setLayoutManager(view.as(gtk.Widget), gtk.BinLayout.new().as(gtk.LayoutManager));

        const drawing_area = view.private().drawing_area;
        _ = gtk.DrawingArea.signals.resize.connect(drawing_area, *View, &handleResize, view, .{});
        gtk.DrawingArea.setDrawFunc(drawing_area, &draw, view, null);

        const drag = gtk.GestureDrag.new();
        gtk.GestureSingle.setButton(drag.as(gtk.GestureSingle), gdk.BUTTON_PRIMARY);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *View, &handleDragBegin, view, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *View, &handleDragUpdate, view, .{});
        gtk.Widget.addController(drawing_area.as(gtk.Widget), drag.as(gtk.EventController));

        const drag_secondary = gtk.GestureDrag.new();
        gtk.GestureSingle.setButton(drag_secondary.as(gtk.GestureSingle), gdk.BUTTON_SECONDARY);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag_secondary, *View, &handleDragBeginSecondary, view, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag_secondary, *View, &handleDragUpdateSecondary, view, .{});
        gtk.Widget.addController(drawing_area.as(gtk.Widget), drag_secondary.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *View, &handlePointerMotion, view, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *View, &handlePointerLeave, view, .{});
        gtk.Widget.addController(drawing_area.as(gtk.Widget), motion.as(gtk.EventController));

        const key = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(key, *View, &handleKeyPressed, view, .{});
        _ = gtk.EventControllerKey.signals.key_released.connect(key, *View, &handleKeyReleased, view, .{});
        gtk.Widget.addController(view.as(gtk.Widget), key.as(gtk.EventController));

        view.private().arena = ArenaAllocator.init(std.heap.raw_c_allocator);

        _ = ColorPicker.signals.color_selected.connect(view.private().color_picker, *View, &handleColorSelected, view, .{});
    }

    fn dispose(view: *View) callconv(.C) void {
        gtk.Widget.disposeTemplate(view.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, view.as(Parent));
    }

    fn finalize(view: *View) callconv(.C) void {
        view.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, view.as(Parent));
    }

    pub fn load(view: *View, set: *pbn.PuzzleSet, puzzle: pbn.Puzzle.Index) void {
        _ = view.private().arena.reset(.retain_capacity);
        const allocator = view.private().arena.allocator();

        const state = State.load(set, puzzle) catch oom();
        view.private().state = state;
        view.private().cleared_cells = allocator.alloc(pbn.Cell, state.image.rows * state.image.columns) catch oom();
        @memset(view.private().cleared_cells, set.colorMask(puzzle));
        view.private().dimensions = null;
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));

        view.private().color_picker.setColors(state.set, state.image.puzzle);
    }

    pub fn clear(view: *View) void {
        const state = &(view.private().state orelse return);
        @memcpy(view.private().cleared_cells, state.set.images.items[@intFromEnum(state.image.index)..][0 .. state.image.rows * state.image.columns]);
        state.set.imageClear(state.image);
        state.solved = false;
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    pub fn undoClear(view: *View) void {
        const state = &(view.private().state orelse return);
        @memcpy(state.set.images.items[@intFromEnum(state.image.index)..][0 .. state.image.rows * state.image.columns], view.private().cleared_cells);
        state.solved = state.isSolved();
        // No solved signal is emitted here to prevent repeated completion
        // popups.
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const view: *View = @ptrCast(@alignCast(user_data));
        const state = view.private().state orelse return;
        const dims = view.private().dimensions orelse blk: {
            const computed = computeDimensions(state, width, height);
            view.private().dimensions = computed;
            break :blk computed;
        };

        if (dims.tile_size <= 0) return;

        drawRules(cr, dims, state);

        for (0..state.image.rows) |i| {
            for (0..state.image.columns) |j| {
                const pos = dims.tilePosition(i + state.max_column_hints, j + state.max_row_hints);
                drawTile(cr, state.set.imageGet(state.image, i, j), pos, dims, state);
            }
        }

        drawHover(cr, dims, state);

        const layout = pangocairo.createLayout(cr);
        defer layout.unref();
        const pango_scale: f64 = @floatFromInt(pango.SCALE);
        const font = pango.FontDescription.new();
        defer font.free();
        font.setFamilyStatic("Sans");
        font.setSize(@intFromFloat(pango_scale * dims.tile_size / 2));
        layout.setFontDescription(font);
        for (0..state.image.rows) |i| {
            const row: pbn.ClueLine.Index = @enumFromInt(i);
            const row_len = state.set.rowClueCount(state.image.puzzle, row);
            for (0..row_len) |n| {
                const pos = dims.tilePosition(state.max_column_hints + i, state.max_row_hints - row_len + n);
                drawClue(cr, layout, state.set.rowClue(state.image.puzzle, row, @enumFromInt(n)), pos, dims, state);
            }
        }
        for (0..state.image.columns) |j| {
            const column: pbn.ClueLine.Index = @enumFromInt(j);
            const column_len = state.set.columnClueCount(state.image.puzzle, column);
            for (0..column_len) |n| {
                const pos = dims.tilePosition(state.max_column_hints - column_len + n, state.max_row_hints + j);
                drawClue(cr, layout, state.set.columnClue(state.image.puzzle, column, @enumFromInt(n)), pos, dims, state);
            }
        }
    }

    fn drawClue(cr: *cairo.Context, layout: *pango.Layout, clue: pbn.Clue, pos: Point, dims: Dimensions, state: State) void {
        var buf: [32]u8 = undefined;
        const color = state.set.color(state.image.puzzle, clue.color);
        setSourceColor(cr, color);
        const text = std.fmt.bufPrintZ(&buf, "{}", .{clue.count}) catch unreachable;
        layout.setText(text, -1);
        var w: c_int = undefined;
        var h: c_int = undefined;
        layout.getSize(&w, &h);

        const pango_scale: f64 = @floatFromInt(pango.SCALE);
        const x = pos.x + 0.5 * dims.tile_size - @as(f64, @floatFromInt(w)) / pango_scale / 2;
        const y = pos.y + 0.5 * dims.tile_size - @as(f64, @floatFromInt(h)) / pango_scale / 2;
        cr.moveTo(x, y);
        pangocairo.showLayout(cr, layout);
    }

    fn drawTile(cr: *cairo.Context, cell: pbn.Cell, pos: Point, dims: Dimensions, state: State) void {
        const bg_color: pbn.Color.Index, const fg_color: ?pbn.Color.Index = if (@popCount(@intFromEnum(cell)) != 1)
            .{ .background, null }
        else if (@ctz(@intFromEnum(cell)) == 0)
            .{ .background, .default }
        else
            .{ @enumFromInt(@ctz(@intFromEnum(cell))), null };
        setSourceColor(cr, state.set.color(state.image.puzzle, bg_color));
        cr.rectangle(pos.x, pos.y, dims.tile_size, dims.tile_size);
        cr.fill();

        if (fg_color) |index| {
            setSourceColor(cr, state.set.color(state.image.puzzle, index));
            cr.setLineWidth(Dimensions.gap_frac * dims.tile_size);
            cr.moveTo(pos.x + dims.tile_size * 0.25, pos.y + dims.tile_size * 0.25);
            cr.lineTo(pos.x + dims.tile_size * 0.75, pos.y + dims.tile_size * 0.75);
            cr.stroke();
            cr.moveTo(pos.x + dims.tile_size * 0.75, pos.y + dims.tile_size * 0.25);
            cr.lineTo(pos.x + dims.tile_size * 0.25, pos.y + dims.tile_size * 0.75);
            cr.stroke();
        }
    }

    fn drawRules(cr: *cairo.Context, dims: Dimensions, state: State) void {
        for (rules) |rule| {
            var i: usize = 0;
            while (i < state.image.rows) : (i += rule.inc) {
                drawRowRule(cr, i, rule.weight, dims, state);
            }
            var j: usize = 0;
            while (j < state.image.columns) : (j += rule.inc) {
                drawColumnRule(cr, j, rule.weight, dims, state);
            }
        }
    }

    fn drawRowRule(cr: *cairo.Context, row: usize, weight: f64, dims: Dimensions, state: State) void {
        var start = dims.tilePosition(state.max_column_hints + row, 0);
        start.y -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        var end = dims.tilePosition(state.max_column_hints + row, state.max_row_hints + state.image.columns);
        end.x -= Dimensions.gap_frac * dims.tile_size;
        end.y -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        drawRule(cr, start, end, weight, dims);
    }

    fn drawColumnRule(cr: *cairo.Context, column: usize, weight: f64, dims: Dimensions, state: State) void {
        var start = dims.tilePosition(0, state.max_row_hints + column);
        start.x -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        var end = dims.tilePosition(state.max_column_hints + state.image.rows, state.max_row_hints + column);
        end.x -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        end.y -= Dimensions.gap_frac * dims.tile_size;
        drawRule(cr, start, end, weight, dims);
    }

    fn drawRule(cr: *cairo.Context, start: Point, end: Point, weight: f64, dims: Dimensions) void {
        cr.setSourceRgb(1 - weight, 1 - weight, 1 - weight);
        cr.moveTo(start.x, start.y);
        cr.lineTo(end.x, end.y);
        cr.setLineWidth(Dimensions.gap_frac * dims.tile_size);
        cr.stroke();
    }

    fn drawHover(cr: *cairo.Context, dims: Dimensions, state: State) void {
        const hover_tile = state.hover_tile orelse return;
        cr.setSourceRgba(0, 0, 0, 0.1);

        if (hover_tile.row >= state.max_column_hints and hover_tile.row < state.max_column_hints + state.image.rows) {
            const row_start = dims.tilePosition(hover_tile.row, 0);
            const row_end = dims.tilePosition(hover_tile.row, state.max_row_hints + state.image.columns);
            cr.rectangle(row_start.x, row_start.y, row_end.x - row_start.x, dims.tile_size);
            cr.fill();
        }

        if (hover_tile.column >= state.max_row_hints and hover_tile.column < state.max_row_hints + state.image.columns) {
            const col_start = dims.tilePosition(0, hover_tile.column);
            const col_end = dims.tilePosition(state.max_column_hints + state.image.rows, hover_tile.column);
            cr.rectangle(col_start.x, col_start.y, dims.tile_size, col_end.y - col_start.y);
            cr.fill();
        }
    }

    fn handleDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, view: *View) callconv(.C) void {
        view.private().draw_start = .{ .x = x, .y = y };
        view.handleDrag(x, y, true);
        // If the user clicks the drawing area, it is assumed they want to focus
        // it for future interactions
        _ = gtk.Widget.grabFocus(view.private().drawing_area.as(gtk.Widget));
    }

    fn handleDragUpdate(_: *gtk.GestureDrag, x: f64, y: f64, view: *View) callconv(.C) void {
        const draw_start = view.private().draw_start;
        view.handleDrag(draw_start.x + x, draw_start.y + y, true);
    }

    fn handleDragBeginSecondary(_: *gtk.GestureDrag, x: f64, y: f64, view: *View) callconv(.C) void {
        view.private().draw_start = .{ .x = x, .y = y };
        view.handleDrag(x, y, false);
    }

    fn handleDragUpdateSecondary(_: *gtk.GestureDrag, x: f64, y: f64, view: *View) callconv(.C) void {
        const draw_start = view.private().draw_start;
        view.handleDrag(draw_start.x + x, draw_start.y + y, false);
    }

    fn handleDrag(view: *View, x: f64, y: f64, primary: bool) void {
        const state = view.private().state orelse return;
        const dims = view.private().dimensions orelse return;
        const tile = dims.positionTile(x, y) orelse return;
        view.setColor(tile.row, tile.column, if (primary) state.selected_color else null);
    }

    fn handleResize(_: *gtk.DrawingArea, width: c_int, height: c_int, view: *View) callconv(.C) void {
        const state = view.private().state orelse return;
        view.private().dimensions = computeDimensions(state, width, height);
    }

    fn handlePointerMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, view: *View) callconv(.C) void {
        const state = &(view.private().state orelse return);
        const dims = view.private().dimensions orelse return;
        state.hover_tile = dims.positionTile(x, y);
        view.handleDrawIfDrawing();
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    fn handlePointerLeave(_: *gtk.EventControllerMotion, view: *View) callconv(.C) void {
        const state = &(view.private().state orelse return);
        state.hover_tile = null;
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    fn handleKeyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, view: *View) callconv(.C) c_int {
        const state = &(view.private().state orelse return 0);
        switch (keyval) {
            gdk.KEY_Up => {
                state.moveHoverTile(-1, 0);
                view.handleDrawIfDrawing();
                gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
            },
            gdk.KEY_Down => {
                state.moveHoverTile(1, 0);
                view.handleDrawIfDrawing();
                gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
            },
            gdk.KEY_Left => {
                state.moveHoverTile(0, -1);
                view.handleDrawIfDrawing();
                gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
            },
            gdk.KEY_Right => {
                state.moveHoverTile(0, 1);
                view.handleDrawIfDrawing();
                gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
            },
            gdk.KEY_1 => view.handleColorKeyPressed(1),
            gdk.KEY_2 => view.handleColorKeyPressed(2),
            gdk.KEY_3 => view.handleColorKeyPressed(3),
            gdk.KEY_4 => view.handleColorKeyPressed(4),
            gdk.KEY_5 => view.handleColorKeyPressed(5),
            gdk.KEY_6 => view.handleColorKeyPressed(6),
            gdk.KEY_7 => view.handleColorKeyPressed(7),
            gdk.KEY_8 => view.handleColorKeyPressed(8),
            gdk.KEY_9 => view.handleColorKeyPressed(9),
            gdk.KEY_0 => view.handleColorKeyPressed(0),
            gdk.KEY_space => view.handleKeyboardDrawStart(),
            else => return 0,
        }
        return 1;
    }

    fn handleKeyReleased(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, view: *View) callconv(.C) void {
        switch (keyval) {
            gdk.KEY_space => view.handleKeyboardDrawEnd(),
            else => {},
        }
    }

    fn handleColorKeyPressed(view: *View, n: usize) void {
        view.private().color_picker.activateButton(n);
    }

    fn handleKeyboardDrawStart(view: *View) void {
        view.private().keyboard_drawing = true;
        view.handleDrawIfDrawing();
    }

    fn handleKeyboardDrawEnd(view: *View) void {
        view.private().keyboard_drawing = false;
    }

    fn handleDrawIfDrawing(view: *View) void {
        if (!view.private().keyboard_drawing) return;
        const state = &(view.private().state orelse return);
        const hover_tile = state.hover_tile orelse return;
        view.setColor(hover_tile.row, hover_tile.column, state.selected_color);
    }

    fn computeDimensions(state: State, width_int: c_int, height_int: c_int) Dimensions {
        const width: f64 = @floatFromInt(width_int);
        const height: f64 = @floatFromInt(height_int);
        const rows: f64 = @floatFromInt(state.image.rows + state.max_column_hints);
        const columns: f64 = @floatFromInt(state.image.columns + state.max_row_hints);

        const max_tile_height = height / (rows + Dimensions.gap_frac * rows + Dimensions.gap_frac);
        const max_tile_width = width / (columns + Dimensions.gap_frac * columns + Dimensions.gap_frac);
        const tile_size = @min(max_tile_height, max_tile_width);
        const board_height = rows * tile_size + (rows + 1) * Dimensions.gap_frac * tile_size;
        const board_width = columns * tile_size + (columns + 1) * Dimensions.gap_frac * tile_size;
        const board_pos = Point{
            .x = width / 2 - board_width / 2,
            .y = height / 2 - board_height / 2,
        };
        return .{ .tile_size = tile_size, .board_pos = board_pos };
    }

    fn handleColorSelected(_: *ColorPicker, color: c_int, view: *View) callconv(.C) void {
        const state = &(view.private().state orelse return);
        state.selected_color = if (color >= 0) @enumFromInt(color) else null;
    }

    fn setColor(view: *View, row: usize, column: usize, color: ?pbn.Color.Index) void {
        const state = &(view.private().state orelse return);
        if (state.solved) {
            return;
        }
        const real_row, const real_column = state.tilePosition(row, column) orelse return;
        const cell: pbn.Cell = if (color == null)
            .only(.background)
        else if (color == .background)
            state.set.colorMask(state.image.puzzle)
        else
            .only(color.?);
        state.set.imageSet(state.image, real_row, real_column, cell);
        if (state.isSolved()) {
            state.solved = true;
            signals.solved.impl.emit(view, null, .{}, null);
        }
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    fn private(view: *View) *Private {
        return gobject.ext.impl_helpers.getPrivate(view, Private, Private.offset);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = View;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gtk.Widget.Class.setTemplateFromResource(class.as(gtk.Widget.Class), "/dev/ianjohnson/Nonograms/ui/view.ui");
            class.bindTemplateChildPrivate("box", .{});
            class.bindTemplateChildPrivate("drawing_area", .{});
            class.bindTemplateChildPrivate("color_picker", .{});
            signals.solved.impl.register(.{});
        }

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.ext.BindTemplateChildOptions) void {
            gtk.ext.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }
    };
};

pub const ColorPicker = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Widget;

    const Private = struct {
        box: *gtk.Box,
        buttons: []*ColorButton,
        arena: ArenaAllocator,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(ColorPicker, .{
        .name = "NonogramsColorPicker",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const color_selected = struct {
            pub const name = "color-selected";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, ColorPicker, &.{c_int}, void);
        };
    };

    pub fn new() *ColorPicker {
        return ColorPicker.newWith(.{});
    }

    pub fn as(picker: *ColorPicker, comptime T: type) *T {
        return gobject.ext.as(T, picker);
    }

    fn init(picker: *ColorPicker, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(picker.as(gtk.Widget));
        gtk.Widget.setLayoutManager(picker.as(gtk.Widget), gtk.BinLayout.new().as(gtk.LayoutManager));

        picker.private().buttons = &.{};
        picker.private().arena = ArenaAllocator.init(std.heap.raw_c_allocator);
    }

    fn dispose(picker: *ColorPicker) callconv(.C) void {
        gtk.Widget.disposeTemplate(picker.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, picker.as(Parent));
    }

    fn finalize(picker: *ColorPicker) callconv(.C) void {
        picker.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, picker.as(Parent));
    }

    pub fn setColors(picker: *ColorPicker, set: *pbn.PuzzleSet, puzzle: pbn.Puzzle.Index) void {
        while (gtk.Widget.getFirstChild(picker.private().box.as(gtk.Widget))) |child| child.unparent();
        _ = picker.private().arena.reset(.retain_capacity);
        const allocator = picker.private().arena.allocator();

        var buttons = std.ArrayList(*ColorButton).init(allocator);
        const none_button = ColorButton.new(
            set.color(puzzle, .background),
            set.color(puzzle, .default),
            0,
        );
        gtk.Box.append(picker.private().box, none_button.as(gtk.Widget));
        _ = gtk.ToggleButton.signals.toggled.connect(
            none_button,
            *ButtonToggleData,
            &handleButtonToggled,
            ButtonToggleData.new(picker, null),
            .{ .destroyData = ButtonToggleData.destroy },
        );
        buttons.append(none_button) catch oom();

        var last_button: *gtk.ToggleButton = none_button.as(gtk.ToggleButton);
        for (0..set.colorCount(puzzle), 1..) |index, number| {
            const color = set.color(puzzle, @enumFromInt(index));
            const button = ColorButton.new(color, null, number);
            gtk.ToggleButton.setGroup(button.as(gtk.ToggleButton), last_button);
            picker.private().box.append(button.as(gtk.Widget));
            last_button = button.as(gtk.ToggleButton);
            if (index == @intFromEnum(pbn.Color.Index.default)) {
                gtk.ToggleButton.setActive(button.as(gtk.ToggleButton), 1);
            }
            _ = gtk.ToggleButton.signals.toggled.connect(
                button,
                *ButtonToggleData,
                &handleButtonToggled,
                ButtonToggleData.new(picker, @enumFromInt(index)),
                .{ .destroyData = ButtonToggleData.destroy },
            );
            buttons.append(button) catch oom();
        }

        picker.private().buttons = buttons.toOwnedSlice() catch oom();
    }

    pub fn activateButton(picker: *ColorPicker, n: usize) void {
        const buttons = picker.private().buttons;
        if (n < buttons.len) {
            gtk.ToggleButton.setActive(buttons[n].as(gtk.ToggleButton), 1);
        }
    }

    const ButtonToggleData = struct {
        picker: *ColorPicker,
        color: ?pbn.Color.Index,

        fn new(picker: *ColorPicker, color: ?pbn.Color.Index) *ButtonToggleData {
            return glib.ext.new(ButtonToggleData, .{
                .picker = picker,
                .color = color,
            });
        }

        fn destroy(data: *ButtonToggleData) callconv(.C) void {
            glib.ext.destroy(data);
        }
    };

    fn handleButtonToggled(button: *ColorButton, data: *ButtonToggleData) callconv(.C) void {
        if (gtk.ToggleButton.getActive(button.as(gtk.ToggleButton)) == 0) {
            return;
        }

        signals.color_selected.impl.emit(
            data.picker,
            null,
            .{if (data.color) |color| @intCast(@intFromEnum(color)) else -1},
            null,
        );
    }

    fn private(picker: *ColorPicker) *Private {
        return gobject.ext.impl_helpers.getPrivate(picker, Private, Private.offset);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = ColorPicker;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gtk.Widget.Class.setTemplateFromResource(class.as(gtk.Widget.Class), "/dev/ianjohnson/Nonograms/ui/color-picker.ui");
            class.bindTemplateChildPrivate("box", .{});
            signals.color_selected.impl.register(.{});
        }

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.ext.BindTemplateChildOptions) void {
            gtk.ext.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }
    };
};

pub const ColorButton = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.ToggleButton;

    const Private = struct {
        toggle_button: *gtk.ToggleButton,
        drawing_area: *gtk.DrawingArea,
        color: pbn.Color,
        x_color: ?pbn.Color,
        key_number: usize,

        var offset: c_int = 0;
    };

    const text_padding = 0.2;

    pub const getGObjectType = gobject.ext.defineClass(ColorButton, .{
        .name = "NonogramsColorButton",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(color: pbn.Color, x_color: ?pbn.Color, key_number: usize) *ColorButton {
        const button = gobject.ext.newInstance(ColorButton, .{});
        button.private().color = color;
        button.private().x_color = x_color;
        button.private().key_number = key_number;
        return button;
    }

    pub fn as(button: *ColorButton, comptime T: type) *T {
        return gobject.ext.as(T, button);
    }

    fn init(button: *ColorButton, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(button.as(gtk.Widget));
        gtk.DrawingArea.setDrawFunc(button.private().drawing_area, &draw, button, null);
    }

    fn dispose(button: *ColorButton) callconv(.C) void {
        gtk.Widget.disposeTemplate(button.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, button.as(Parent));
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const button: *ColorButton = @ptrCast(@alignCast(user_data));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);

        const color = button.private().color;
        setSourceColor(cr, color);
        cr.rectangle(0, 0, w, h);
        cr.fill();

        if (button.private().x_color) |x_color| {
            setSourceColor(cr, x_color);
            cr.setLineWidth(Dimensions.gap_frac * w);
            cr.moveTo(w * 0.25, h * 0.25);
            cr.lineTo(w * 0.75, h * 0.75);
            cr.stroke();
            cr.moveTo(w * 0.75, h * 0.25);
            cr.lineTo(w * 0.25, h * 0.75);
            cr.stroke();
        }

        const layout = pangocairo.createLayout(cr);
        defer layout.unref();
        const pango_scale: f64 = @floatFromInt(pango.SCALE);
        const font = pango.FontDescription.new();
        defer font.free();
        font.setFamilyStatic("Sans");
        font.setSize(@intFromFloat(pango_scale * h / 4));
        layout.setFontDescription(font);

        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{}", .{button.private().key_number}) catch unreachable;
        layout.setText(text, -1);
        var tw: c_int = undefined;
        var th: c_int = undefined;
        layout.getSize(&tw, &th);
        const twf = @as(f64, @floatFromInt(tw)) / pango_scale;
        const thf = @as(f64, @floatFromInt(th)) / pango_scale;
        const tx = w - (1 + text_padding) * twf;
        const ty = w - (1 + text_padding) * thf;
        // Text background (to ensure contrast)
        cr.setSourceRgba(1, 1, 1, 0.5);
        cr.rectangle(
            tx - text_padding * twf,
            ty - text_padding * thf,
            (1 + 2 * text_padding) * twf,
            (1 + 2 * text_padding) * thf,
        );
        cr.fill();
        // Text
        cr.setSourceRgb(0, 0, 0);
        cr.moveTo(tx, ty);
        pangocairo.showLayout(cr, layout);
    }

    fn private(button: *ColorButton) *Private {
        return gobject.ext.impl_helpers.getPrivate(button, Private, Private.offset);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = ColorButton;

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gtk.Widget.Class.setTemplateFromResource(class.as(gtk.Widget.Class), "/dev/ianjohnson/Nonograms/ui/color-button.ui");
            class.bindTemplateChildPrivate("drawing_area", .{});
        }

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.ext.BindTemplateChildOptions) void {
            gtk.ext.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }
    };
};

fn setSourceColor(cr: *cairo.Context, color: pbn.Color) void {
    const r, const g, const b = color.rgbFloat();
    cr.setSourceRgb(r, g, b);
}
