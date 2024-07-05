const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const pbn = @import("pbn.zig");
const util = @import("util.zig");
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const math = std.math;
const oom = util.oom;
const raw_c_allocator = std.heap.raw_c_allocator;

const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    pub const getGObjectType = gobject.ext.defineBoxed(Color, .{});

    const white = Color{ .r = 1, .g = 1, .b = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const red = Color{ .r = 1, .g = 0, .b = 0 };

    fn eql(color: Color, other: Color) bool {
        return color.r == other.r and color.g == other.g and color.b == other.b;
    }

    fn fromPbn(color: pbn.Color) !Color {
        const rgb = try color.toFloatRgb();
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    fn toHex(color: Color) [6]u8 {
        var buf: [6]u8 = undefined;
        _ = fmt.bufPrint(&buf, "{X:0>2}{X:0>2}{X:0>2}", .{
            @as(u8, @intFromFloat(@round(color.r * 255))),
            @as(u8, @intFromFloat(@round(color.g * 255))),
            @as(u8, @intFromFloat(@round(color.b * 255))),
        }) catch unreachable;
        return buf;
    }
};

const Hint = struct {
    n: usize,
    color: Color,
};

const State = struct {
    tile_colors: []?Color,
    background_color: Color,
    default_color: Color,
    available_colors: []const Color,
    selected_color: ?Color,
    row_hints: [][]Hint,
    max_row_hints: usize,
    column_hints: [][]Hint,
    max_column_hints: usize,
    hover_tile: ?Cell,
    solved: bool,

    fn isSolved(state: State) bool {
        for (0..state.row_hints.len) |i| {
            if (!state.isLineSolved(.row, i)) {
                return false;
            }
        }
        for (0..state.column_hints.len) |j| {
            if (!state.isLineSolved(.column, j)) {
                return false;
            }
        }
        return true;
    }

    fn isLineSolved(state: State, comptime dir: enum { row, column }, n: usize) bool {
        const hints = if (dir == .row) state.row_hints[n] else state.column_hints[n];
        const cross_len = if (dir == .row) state.column_hints.len else state.row_hints.len;
        const cols = state.column_hints.len;
        var run_color: Color = state.background_color;
        var run_len: usize = 0;
        var hint_idx: usize = 0;
        for (0..cross_len) |m| {
            const tile_pos = if (dir == .row) n * cols + m else m * cols + n;
            const color = state.tile_colors[tile_pos] orelse state.background_color;
            if (color.eql(run_color)) {
                run_len += 1;
                continue;
            }
            if (!run_color.eql(state.background_color)) {
                if (hint_idx >= hints.len or !hints[hint_idx].color.eql(run_color) or hints[hint_idx].n != run_len) {
                    return false;
                }
                hint_idx += 1;
            }
            run_color = color;
            run_len = 1;
        }
        if (run_len > 0 and !run_color.eql(state.background_color)) {
            if (hint_idx >= hints.len or !hints[hint_idx].color.eql(run_color) or hints[hint_idx].n != run_len) {
                return false;
            }
            hint_idx += 1;
        }
        return hint_idx == hints.len;
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
            .row = math.clamp(hover_tile.row, state.max_column_hints, state.max_column_hints + state.row_hints.len - 1),
            .column = math.clamp(hover_tile.column, state.max_row_hints, state.max_row_hints + state.column_hints.len - 1),
        };
    }

    fn tileIndex(state: State, row: usize, column: usize) ?usize {
        const row_in_bounds = row >= state.max_column_hints and row < state.max_column_hints + state.row_hints.len;
        const column_in_bounds = column >= state.max_row_hints and column < state.max_row_hints + state.column_hints.len;
        if (row_in_bounds and column_in_bounds) {
            return (column - state.max_row_hints) + (row - state.max_column_hints) * state.column_hints.len;
        } else {
            return null;
        }
    }

    fn toImage(state: State, allocator: Allocator, colors: []const pbn.Color) !pbn.Image {
        var color_chars = StringHashMapUnmanaged(u8){};
        defer {
            var key_iterator = color_chars.keyIterator();
            while (key_iterator.next()) |key| {
                allocator.free(key.*);
            }
            color_chars.deinit(allocator);
        }
        try color_chars.ensureTotalCapacity(allocator, @intCast(colors.len));
        for (colors) |color| {
            if (color.char) |char| {
                const value = try ascii.allocUpperString(allocator, color.value);
                errdefer allocator.free(value);
                try color_chars.put(allocator, value, char);
            }
        }

        var chars = try ArrayListUnmanaged([]const u8).initCapacity(allocator, state.tile_colors.len);
        var row_iter = mem.window(?Color, state.tile_colors, state.column_hints.len, state.column_hints.len);
        while (row_iter.next()) |row| {
            for (row) |maybe_color| {
                if (maybe_color) |color| {
                    const color_char = color_chars.get(&color.toHex()) orelse return error.UndefinedColor;
                    chars.appendAssumeCapacity(try allocator.dupe(u8, &.{color_char}));
                } else {
                    chars.appendAssumeCapacity(try allocator.dupe(u8, ""));
                }
            }
        }
        return .{
            .rows = state.row_hints.len,
            .columns = state.column_hints.len,
            .chars = try chars.toOwnedSlice(allocator),
        };
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
        cleared_tile_colors: []?Color,
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

        view.private().arena = ArenaAllocator.init(raw_c_allocator);

        _ = ColorPicker.signals.color_selected.connect(view.private().color_picker, *View, &handleColorSelected, view, .{});
    }

    fn dispose(view: *View) callconv(.C) void {
        gtk.Widget.disposeTemplate(view.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent.as(gobject.Object.Class), view.as(gobject.Object));
    }

    fn finalize(view: *View) callconv(.C) void {
        view.private().arena.deinit();
        Class.parent.as(gobject.Object.Class).finalize.?(view.as(gobject.Object));
    }

    pub fn load(view: *View, puzzle: pbn.Puzzle) void {
        _ = view.private().arena.reset(.retain_capacity);
        const allocator = view.private().arena.allocator();

        const rows = puzzle.row_clues.lines.len;
        const row_hints = allocator.alloc([]Hint, rows) catch oom();
        var max_row_hints: usize = 0;
        for (row_hints, puzzle.row_clues.lines) |*row, line| {
            row.* = allocator.alloc(Hint, line.counts.len) catch oom();
            max_row_hints = @max(max_row_hints, line.counts.len);
            for (row.*, line.counts) |*hint, count| {
                const color_name = count.color orelse puzzle.default_color;
                const color = puzzle.colors.get(color_name) orelse pbn.Color.black;
                hint.* = Hint{ .n = count.n, .color = Color.fromPbn(color) catch Color.black };
            }
        }
        const columns = puzzle.column_clues.lines.len;
        const column_hints = allocator.alloc([]Hint, columns) catch oom();
        var max_column_hints: usize = 0;
        for (column_hints, puzzle.column_clues.lines) |*column, line| {
            column.* = allocator.alloc(Hint, line.counts.len) catch oom();
            max_column_hints = @max(max_column_hints, line.counts.len);
            for (column.*, line.counts) |*hint, count| {
                const color_name = count.color orelse puzzle.default_color;
                const color = puzzle.colors.get(color_name) orelse pbn.Color.black;
                hint.* = Hint{ .n = count.n, .color = Color.fromPbn(color) catch Color.black };
            }
        }
        const background_color = Color.fromPbn(puzzle.colors.get(puzzle.background_color) orelse pbn.Color.white) catch Color.white;
        const default_color = Color.fromPbn(puzzle.colors.get(puzzle.default_color) orelse pbn.Color.black) catch Color.black;
        const available_colors = allocator.alloc(Color, puzzle.colors.count()) catch oom();
        for (available_colors, puzzle.colors.values()) |*available_color, color| {
            available_color.* = Color.fromPbn(color) catch Color.black;
        }
        const tile_colors = allocator.alloc(?Color, rows * columns) catch oom();
        for (tile_colors) |*color| {
            color.* = background_color;
        }

        var state = State{
            .tile_colors = tile_colors,
            .background_color = background_color,
            .default_color = default_color,
            .selected_color = default_color,
            .available_colors = available_colors,
            .row_hints = row_hints,
            .max_row_hints = max_row_hints,
            .column_hints = column_hints,
            .max_column_hints = max_column_hints,
            .hover_tile = null,
            .solved = false,
        };

        const saved_image = for (puzzle.solutions) |solution| {
            if (solution.type == .saved) {
                break solution.image;
            }
        } else null;
        if (saved_image) |image| {
            // We can't trust that the saved image is actually valid: in
            // particular, it could have completely incorrect dimensions
            if (image.rows == rows and image.columns == columns) {
                var colors_by_char = AutoHashMapUnmanaged(u8, Color){};
                defer colors_by_char.deinit(allocator);
                for (puzzle.colors.values()) |color| {
                    if (color.char) |char| {
                        const converted = Color.fromPbn(color) catch continue;
                        colors_by_char.put(allocator, char, converted) catch oom();
                    }
                }

                for (image.chars, tile_colors) |options, *color| {
                    switch (options.len) {
                        0 => color.* = null,
                        1 => color.* = colors_by_char.get(options[0]) orelse background_color,
                        else => {},
                    }
                }
            }
        }
        state.solved = state.isSolved();

        view.private().state = state;
        view.private().cleared_tile_colors = allocator.alloc(?Color, tile_colors.len) catch oom();
        @memset(view.private().cleared_tile_colors, null);
        view.private().dimensions = null;
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));

        view.private().color_picker.load(puzzle);
    }

    pub fn clear(view: *View) void {
        const state = &(view.private().state orelse return);
        @memcpy(view.private().cleared_tile_colors, state.tile_colors);
        @memset(state.tile_colors, state.background_color);
        state.solved = false;
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    pub fn undoClear(view: *View) void {
        const state = &(view.private().state orelse return);
        @memcpy(state.tile_colors, view.private().cleared_tile_colors);
        state.solved = state.isSolved();
        // No solved signal is emitted here to prevent repeated completion
        // popups.
        gtk.Widget.queueDraw(view.private().drawing_area.as(gtk.Widget));
    }

    pub fn getImage(view: *View, allocator: Allocator, colors: []const pbn.Color) !?pbn.Image {
        const state = view.private().state orelse return null;
        return try state.toImage(allocator, colors);
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

        for (state.tile_colors, 0..) |color, n| {
            const i = state.max_column_hints + n / state.column_hints.len;
            const j = state.max_row_hints + n % state.column_hints.len;
            const pos = dims.tilePosition(i, j);
            drawTile(cr, color, pos, dims, state);
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
        for (state.row_hints, 0..) |row, i| {
            for (row, 0..) |hint, n| {
                const pos = dims.tilePosition(state.max_column_hints + i, state.max_row_hints - row.len + n);
                drawHint(cr, layout, hint, pos, dims);
            }
        }
        for (state.column_hints, 0..) |column, j| {
            for (column, 0..) |hint, n| {
                const pos = dims.tilePosition(state.max_column_hints - column.len + n, state.max_row_hints + j);
                drawHint(cr, layout, hint, pos, dims);
            }
        }
    }

    fn drawHint(cr: *cairo.Context, layout: *pango.Layout, hint: Hint, pos: Point, dims: Dimensions) void {
        var buf: [32]u8 = undefined;
        cr.setSourceRgb(hint.color.r, hint.color.g, hint.color.b);
        const text = std.fmt.bufPrintZ(&buf, "{}", .{hint.n}) catch unreachable;
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

    fn drawTile(cr: *cairo.Context, color: ?Color, pos: Point, dims: Dimensions, state: State) void {
        const c = color orelse state.background_color;
        cr.setSourceRgb(c.r, c.g, c.b);
        cr.rectangle(pos.x, pos.y, dims.tile_size, dims.tile_size);
        cr.fill();
        if (color == null) {
            cr.setSourceRgb(state.default_color.r, state.default_color.g, state.default_color.b);
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
            while (i < state.row_hints.len) : (i += rule.inc) {
                drawRowRule(cr, i, rule.weight, dims, state);
            }
            var j: usize = 0;
            while (j < state.column_hints.len) : (j += rule.inc) {
                drawColumnRule(cr, j, rule.weight, dims, state);
            }
        }
    }

    fn drawRowRule(cr: *cairo.Context, row: usize, weight: f64, dims: Dimensions, state: State) void {
        var start = dims.tilePosition(state.max_column_hints + row, 0);
        start.y -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        var end = dims.tilePosition(state.max_column_hints + row, state.max_row_hints + state.column_hints.len);
        end.x -= Dimensions.gap_frac * dims.tile_size;
        end.y -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        drawRule(cr, start, end, weight, dims);
    }

    fn drawColumnRule(cr: *cairo.Context, column: usize, weight: f64, dims: Dimensions, state: State) void {
        var start = dims.tilePosition(0, state.max_row_hints + column);
        start.x -= 0.5 * Dimensions.gap_frac * dims.tile_size;
        var end = dims.tilePosition(state.max_column_hints + state.row_hints.len, state.max_row_hints + column);
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

        if (hover_tile.row >= state.max_column_hints and hover_tile.row < state.max_column_hints + state.row_hints.len) {
            const row_start = dims.tilePosition(hover_tile.row, 0);
            const row_end = dims.tilePosition(hover_tile.row, state.max_row_hints + state.column_hints.len);
            cr.rectangle(row_start.x, row_start.y, row_end.x - row_start.x, dims.tile_size);
            cr.fill();
        }

        if (hover_tile.column >= state.max_row_hints and hover_tile.column < state.max_row_hints + state.column_hints.len) {
            const col_start = dims.tilePosition(0, hover_tile.column);
            const col_end = dims.tilePosition(state.max_column_hints + state.row_hints.len, hover_tile.column);
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
        const rows: f64 = @floatFromInt(state.row_hints.len + state.max_column_hints);
        const columns: f64 = @floatFromInt(state.column_hints.len + state.max_row_hints);

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

    fn handleColorSelected(_: *ColorPicker, maybe_color: ?*const Color, view: *View) callconv(.C) void {
        const state = &(view.private().state orelse return);
        state.selected_color = if (maybe_color) |color| color.* else null;
    }

    fn setColor(view: *View, row: usize, column: usize, color: ?Color) void {
        const state = &(view.private().state orelse return);
        if (state.solved) {
            return;
        }
        const index = state.tileIndex(row, column) orelse return;
        state.tile_colors[index] = color;
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
        color: Color,
        buttons: []const *ColorButton,
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
            const impl = gobject.ext.defineSignal(name, ColorPicker, &.{?*const Color}, void);
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
        picker.private().arena = ArenaAllocator.init(raw_c_allocator);
    }

    fn dispose(picker: *ColorPicker) callconv(.C) void {
        gtk.Widget.disposeTemplate(picker.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent.as(gobject.Object.Class), picker.as(gobject.Object));
    }

    fn finalize(picker: *ColorPicker) callconv(.C) void {
        picker.private().arena.deinit();
        Class.parent.as(gobject.Object.Class).finalize.?(picker.as(gobject.Object));
    }

    pub fn load(picker: *ColorPicker, puzzle: pbn.Puzzle) void {
        while (gtk.Widget.getFirstChild(picker.private().box.as(gtk.Widget))) |child| child.unparent();
        _ = picker.private().arena.reset(.retain_capacity);
        const allocator = picker.private().arena.allocator();

        var buttons = ArrayListUnmanaged(*ColorButton){};
        const none_button = ColorButton.new(
            Color.fromPbn(puzzle.colors.get(puzzle.background_color) orelse pbn.Color.white) catch Color.white,
            Color.fromPbn(puzzle.colors.get(puzzle.default_color) orelse pbn.Color.black) catch Color.black,
            0,
        );
        gtk.Box.append(picker.private().box, none_button.as(gtk.Widget));
        _ = gtk.ToggleButton.signals.toggled.connect(none_button, *ColorPicker, &handleButtonToggled, picker, .{});
        buttons.append(allocator, none_button) catch oom();

        var last_button: *gtk.ToggleButton = none_button.as(gtk.ToggleButton);
        for (puzzle.colors.values(), 1..) |color, number| {
            const button = ColorButton.new(Color.fromPbn(color) catch Color.black, null, number);
            gtk.ToggleButton.setGroup(button.as(gtk.ToggleButton), last_button);
            picker.private().box.append(button.as(gtk.Widget));
            last_button = button.as(gtk.ToggleButton);
            if (mem.eql(u8, color.name, puzzle.default_color)) {
                gtk.ToggleButton.setActive(button.as(gtk.ToggleButton), 1);
            }
            _ = gtk.ToggleButton.signals.toggled.connect(button, *ColorPicker, &handleButtonToggled, picker, .{});
            buttons.append(allocator, button) catch oom();
        }

        picker.private().buttons = buttons.items;
    }

    pub fn activateButton(picker: *ColorPicker, n: usize) void {
        const buttons = picker.private().buttons;
        if (n < buttons.len) {
            gtk.ToggleButton.setActive(buttons[n].as(gtk.ToggleButton), 1);
        }
    }

    fn handleButtonToggled(button: *ColorButton, picker: *ColorPicker) callconv(.C) void {
        if (gtk.ToggleButton.getActive(button.as(gtk.ToggleButton)) == 0) {
            return;
        }

        signals.color_selected.impl.emit(picker, null, .{
            if (button.getSelectionColor()) |color| &color else null,
        }, null);
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
        color: Color,
        x_color: ?Color,
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

    pub fn new(color: Color, x_color: ?Color, key_number: usize) *ColorButton {
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
        gobject.Object.virtual_methods.dispose.call(Class.parent.as(gobject.Object.Class), button.as(gobject.Object));
    }

    pub fn getSelectionColor(button: *ColorButton) ?Color {
        return if (button.private().x_color == null) button.private().color else null;
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const button: *ColorButton = @ptrCast(@alignCast(user_data));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);

        const color = button.private().color;
        cr.setSourceRgb(color.r, color.g, color.b);
        cr.rectangle(0, 0, w, h);
        cr.fill();

        if (button.private().x_color) |x_color| {
            cr.setSourceRgb(x_color.r, x_color.g, x_color.b);
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
