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
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
const math = std.math;
const oom = util.oom;
const raw_c_allocator = std.heap.raw_c_allocator;

const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    const white = Color{ .r = 1, .g = 1, .b = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const red = Color{ .r = 1, .g = 0, .b = 0 };

    fn fromPbn(color: pbn.Color) !Color {
        const rgb = try color.toFloatRgb();
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
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
    holding_color_key: ?usize,

    fn tileIndex(self: State, row: usize, column: usize) ?usize {
        const row_in_bounds = row >= self.max_column_hints and row < self.max_column_hints + self.row_hints.len;
        const column_in_bounds = column >= self.max_row_hints and column < self.max_row_hints + self.column_hints.len;
        if (row_in_bounds and column_in_bounds) {
            return (column - self.max_row_hints) + (row - self.max_column_hints) * self.column_hints.len;
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

    fn positionTile(self: Dimensions, x: f64, y: f64) ?Cell {
        const rel_x = x - self.board_pos.x;
        const rel_y = y - self.board_pos.y;
        if (rel_x < 0 or rel_y < 0) {
            return null;
        } else {
            return .{
                .row = @floatToInt(usize, rel_y / (self.tile_size + gap_frac * self.tile_size)),
                .column = @floatToInt(usize, rel_x / (self.tile_size + gap_frac * self.tile_size)),
            };
        }
    }

    fn tilePosition(self: Dimensions, row: usize, column: usize) Point {
        return .{
            .x = self.board_pos.x + @intToFloat(f64, column) * (self.tile_size + gap_frac * self.tile_size),
            .y = self.board_pos.y + @intToFloat(f64, row) * (self.tile_size + gap_frac * self.tile_size),
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
    const Self = @This();

    pub const Private = struct {
        drawing_area: *gtk.DrawingArea,
        color_picker: *ColorPicker,
        draw_start: Point,
        dimensions: ?Dimensions,
        state: ?State,
        state_arena: ArenaAllocator,

        pub var offset: c_int = 0;
    };

    const template = @embedFile("ui/view.ui");
    const rules = [_]Rule{
        .{ .inc = 1, .weight = 0.1 },
        .{ .inc = 5, .weight = 0.5 },
        .{ .inc = 10, .weight = 1 },
    };

    pub const getType = gobject.registerType(Self, .{
        .name = "NonogramsView",
    });

    pub fn new() *Self {
        return Self.newWith(.{});
    }

    pub fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();
        self.setLayoutManager(gtk.BinLayout.new().as(gtk.LayoutManager));

        const drawing_area = self.private().drawing_area;
        _ = drawing_area.connectResize(*Self, &handleResize, self, .{});
        drawing_area.setDrawFunc(&draw, self, null);

        const drag = gtk.GestureDrag.new();
        drag.setButton(gdk.BUTTON_PRIMARY);
        _ = drag.connectDragBegin(*Self, &handleDragBegin, self, .{});
        _ = drag.connectDragUpdate(*Self, &handleDragUpdate, self, .{});
        drawing_area.addController(drag.as(gtk.EventController));

        // Does not currently work: https://gitlab.gnome.org/GNOME/gtk/-/issues/5561
        const drag_secondary = gtk.GestureDrag.new();
        drag_secondary.setButton(gdk.BUTTON_SECONDARY);
        _ = drag_secondary.connectDragBegin(*Self, &handleDragBeginSecondary, self, .{});
        _ = drag_secondary.connectDragUpdate(*Self, &handleDragUpdateSecondary, self, .{});
        drawing_area.addController(drag_secondary.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = motion.connectMotion(*Self, &handlePointerMotion, self, .{});
        _ = motion.connectLeave(*Self, &handlePointerLeave, self, .{});
        drawing_area.addController(motion.as(gtk.EventController));

        const key = gtk.EventControllerKey.new();
        _ = key.connectKeyPressed(*Self, &handleKeyPressed, self, .{});
        _ = key.connectKeyReleased(*Self, &handleKeyReleased, self, .{});
        self.addController(key.as(gtk.EventController));

        self.private().state_arena = ArenaAllocator.init(raw_c_allocator);

        _ = gobject.signalConnectData(self.private().color_picker, "color-selected", @ptrCast(gobject.Callback, &handleColorSelected), self, null, .{});
    }

    fn dispose(self: *Self) callconv(.C) void {
        while (self.getFirstChild()) |child| child.unparent();
        self.private().state_arena.deinit();
        Class.parent.?.callDispose(self.as(gobject.Object));
    }

    pub fn load(self: *Self, puzzle: pbn.Puzzle) void {
        _ = self.private().state_arena.reset(.retain_capacity);
        const allocator = self.private().state_arena.allocator();

        const row_clues = puzzle.clues.get(.rows) orelse return;
        const column_clues = puzzle.clues.get(.columns) orelse return;
        const rows = row_clues.lines.len;
        const row_hints = allocator.alloc([]Hint, rows) catch oom();
        var max_row_hints: usize = 0;
        for (row_hints, row_clues.lines) |*row, line| {
            row.* = allocator.alloc(Hint, line.counts.len) catch oom();
            max_row_hints = @max(max_row_hints, line.counts.len);
            for (row.*, line.counts) |*hint, count| {
                const color_name = count.color orelse puzzle.default_color;
                const color = puzzle.colors.get(color_name) orelse pbn.Color.black;
                hint.* = Hint{ .n = count.n, .color = Color.fromPbn(color) catch Color.black };
            }
        }
        const columns = column_clues.lines.len;
        const column_hints = allocator.alloc([]Hint, columns) catch oom();
        var max_column_hints: usize = 0;
        for (column_hints, column_clues.lines) |*column, line| {
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

        self.private().state = .{
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
            .holding_color_key = null,
        };
        self.private().dimensions = null;
        self.private().drawing_area.queueDraw();

        self.private().color_picker.load(puzzle);
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), user_data));
        const state = self.private().state orelse return;
        const dims = self.private().dimensions orelse blk: {
            const computed = computeDimensions(state, width, height);
            self.private().dimensions = computed;
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
        const pango_scale = @intToFloat(f64, pango.SCALE);
        const font = pango.FontDescription.new();
        defer font.free();
        font.setFamilyStatic("Sans");
        font.setSize(@floatToInt(c_int, pango_scale * dims.tile_size / 2));
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

        const pango_scale = @intToFloat(f64, pango.SCALE);
        const x = pos.x + 0.5 * dims.tile_size - @intToFloat(f64, w) / pango_scale / 2;
        const y = pos.y + 0.5 * dims.tile_size - @intToFloat(f64, h) / pango_scale / 2;
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
            var row_start = dims.tilePosition(hover_tile.row, 0);
            var row_end = dims.tilePosition(hover_tile.row, state.max_row_hints + state.column_hints.len);
            cr.rectangle(row_start.x, row_start.y, row_end.x - row_start.x, dims.tile_size);
            cr.fill();
        }

        if (hover_tile.column >= state.max_row_hints and hover_tile.column < state.max_row_hints + state.column_hints.len) {
            var col_start = dims.tilePosition(0, hover_tile.column);
            var col_end = dims.tilePosition(state.max_column_hints + state.row_hints.len, hover_tile.column);
            cr.rectangle(col_start.x, col_start.y, dims.tile_size, col_end.y - col_start.y);
            cr.fill();
        }
    }

    fn handleDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        self.private().draw_start = .{ .x = x, .y = y };
        self.handleDrag(x, y, true);
    }

    fn handleDragUpdate(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        const draw_start = self.private().draw_start;
        self.handleDrag(draw_start.x + x, draw_start.y + y, true);
    }

    fn handleDragBeginSecondary(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        self.private().draw_start = .{ .x = x, .y = y };
        self.handleDrag(x, y, false);
    }

    fn handleDragUpdateSecondary(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        const draw_start = self.private().draw_start;
        self.handleDrag(draw_start.x + x, draw_start.y + y, false);
    }

    fn handleDrag(self: *Self, x: f64, y: f64, primary: bool) void {
        const state = self.private().state orelse return;
        const dims = self.private().dimensions orelse return;
        const tile = dims.positionTile(x, y) orelse return;
        if (state.tileIndex(tile.row, tile.column)) |n| {
            state.tile_colors[n] = if (primary) state.selected_color else null;
            self.private().drawing_area.queueDraw();
        }
    }

    fn handleResize(_: *gtk.DrawingArea, width: c_int, height: c_int, self: *Self) callconv(.C) void {
        const state = self.private().state orelse return;
        self.private().dimensions = computeDimensions(state, width, height);
    }

    fn handlePointerMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *Self) callconv(.C) void {
        const state = &(self.private().state orelse return);
        const dims = self.private().dimensions orelse return;
        state.hover_tile = dims.positionTile(x, y);
        self.handleColorKeyDraw();
        self.private().drawing_area.queueDraw();
    }

    fn handlePointerLeave(_: *gtk.EventControllerMotion, self: *Self) callconv(.C) void {
        const state = &(self.private().state orelse return);
        state.hover_tile = null;
        self.private().drawing_area.queueDraw();
    }

    fn handleKeyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Self) callconv(.C) bool {
        const state = &(self.private().state orelse return false);
        switch (keyval) {
            gdk.KEY_Up => {
                if (state.hover_tile) |*hover_tile| {
                    if (hover_tile.row > state.max_column_hints) {
                        hover_tile.row -= 1;
                    }
                } else {
                    state.hover_tile = .{ .row = state.max_column_hints, .column = state.max_row_hints };
                }
                self.handleColorKeyDraw();
                self.private().drawing_area.queueDraw();
            },
            gdk.KEY_Down => {
                if (state.hover_tile) |*hover_tile| {
                    if (hover_tile.row < state.max_column_hints + state.row_hints.len - 1) {
                        hover_tile.row += 1;
                    }
                } else {
                    state.hover_tile = .{ .row = state.max_column_hints, .column = state.max_row_hints };
                }
                self.handleColorKeyDraw();
                self.private().drawing_area.queueDraw();
            },
            gdk.KEY_Left => {
                if (state.hover_tile) |*hover_tile| {
                    if (hover_tile.column > state.max_row_hints) {
                        hover_tile.column -= 1;
                    }
                } else {
                    state.hover_tile = .{ .row = state.max_column_hints, .column = state.max_row_hints };
                }
                self.handleColorKeyDraw();
                self.private().drawing_area.queueDraw();
            },
            gdk.KEY_Right => {
                if (state.hover_tile) |*hover_tile| {
                    if (hover_tile.column < state.max_row_hints + state.column_hints.len - 1) {
                        hover_tile.column += 1;
                    }
                } else {
                    state.hover_tile = .{ .row = state.max_column_hints, .column = state.max_row_hints };
                }
                self.handleColorKeyDraw();
                self.private().drawing_area.queueDraw();
            },
            gdk.KEY_1 => self.handleColorKeyPressed(1),
            gdk.KEY_2 => self.handleColorKeyPressed(2),
            gdk.KEY_3 => self.handleColorKeyPressed(3),
            gdk.KEY_4 => self.handleColorKeyPressed(4),
            gdk.KEY_5 => self.handleColorKeyPressed(5),
            gdk.KEY_6 => self.handleColorKeyPressed(6),
            gdk.KEY_7 => self.handleColorKeyPressed(7),
            gdk.KEY_8 => self.handleColorKeyPressed(8),
            gdk.KEY_9 => self.handleColorKeyPressed(9),
            gdk.KEY_0 => self.handleColorKeyPressed(0),
            else => return false,
        }
        return true;
    }

    fn handleKeyReleased(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Self) callconv(.C) void {
        switch (keyval) {
            gdk.KEY_1,
            gdk.KEY_2,
            gdk.KEY_3,
            gdk.KEY_4,
            gdk.KEY_5,
            gdk.KEY_6,
            gdk.KEY_7,
            gdk.KEY_8,
            gdk.KEY_9,
            gdk.KEY_0,
            => self.handleColorKeyReleased(),
            else => {},
        }
    }

    fn handleColorKeyPressed(self: *Self, n: usize) void {
        const state = &(self.private().state orelse return);
        state.holding_color_key = if (n <= state.available_colors.len) n else null;
        self.handleColorKeyDraw();
    }

    fn handleColorKeyReleased(self: *Self) void {
        const state = &(self.private().state orelse return);
        state.holding_color_key = null;
    }

    fn handleColorKeyDraw(self: *Self) void {
        const state = &(self.private().state orelse return);
        const n = state.holding_color_key orelse return;
        const hover_tile = state.hover_tile orelse return;
        const hover_tile_index = state.tileIndex(hover_tile.row, hover_tile.column) orelse return;
        state.tile_colors[hover_tile_index] = if (n > 0) state.available_colors[n - 1] else null;
        self.private().drawing_area.queueDraw();
    }

    fn computeDimensions(state: State, width_int: c_int, height_int: c_int) Dimensions {
        const width = @intToFloat(f64, width_int);
        const height = @intToFloat(f64, height_int);
        const rows = @intToFloat(f64, state.row_hints.len + state.max_column_hints);
        const columns = @intToFloat(f64, state.column_hints.len + state.max_row_hints);

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

    fn handleColorSelected(_: *ColorPicker, maybe_color: *glib.Variant, self: *Self) callconv(.C) void {
        const state = &(self.private().state orelse return);
        if (maybe_color.getMaybe()) |color| {
            const r = color.getChildValue(0).getDouble();
            const g = color.getChildValue(1).getDouble();
            const b = color.getChildValue(2).getDouble();
            state.selected_color = .{ .r = r, .g = g, .b = b };
        } else {
            state.selected_color = null;
        }
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub var parent: ?*Parent.Class = null;

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.implementDispose(&dispose);
            class.setTemplateFromSlice(template);
            class.bindTemplateChild("drawing_area", .{ .private = true });
            class.bindTemplateChild("color_picker", .{ .private = true });
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Instance);
    };
};

pub const ColorPicker = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const Private = struct {
        box: *gtk.Box,
        color: Color,

        pub var offset: c_int = 0;
    };

    const template = @embedFile("ui/color-picker.ui");

    pub const getType = gobject.registerType(Self, .{
        .name = "NonogramsColorPicker",
    });
    var color_select: c_uint = 0;

    pub fn new() *Self {
        return Self.newWith(.{});
    }

    pub fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();
        self.setLayoutManager(gtk.BinLayout.new().as(gtk.LayoutManager));
    }

    fn dispose(self: *Self) callconv(.C) void {
        while (self.getFirstChild()) |child| child.unparent();
        Class.parent.?.callDispose(self.as(gobject.Object));
    }

    pub fn load(self: *Self, puzzle: pbn.Puzzle) void {
        while (self.private().box.getFirstChild()) |child| child.unparent();

        const none_button = ColorButton.new(
            Color.fromPbn(puzzle.colors.get(puzzle.background_color) orelse pbn.Color.white) catch Color.white,
            Color.fromPbn(puzzle.colors.get(puzzle.default_color) orelse pbn.Color.black) catch Color.black,
        );
        self.private().box.append(none_button.as(gtk.Widget));
        _ = none_button.connectToggled(*Self, &handleButtonToggled, self, .{});

        var last_button: *gtk.ToggleButton = none_button.as(gtk.ToggleButton);
        for (puzzle.colors.values()) |color| {
            const button = ColorButton.new(Color.fromPbn(color) catch Color.black, null);
            button.setGroup(last_button);
            self.private().box.append(button.as(gtk.Widget));
            last_button = button.as(gtk.ToggleButton);
            if (mem.eql(u8, color.name, puzzle.default_color)) {
                button.setActive(true);
            }
            _ = button.connectToggled(*Self, &handleButtonToggled, self, .{});
        }
    }

    fn handleButtonToggled(button: *ColorButton, self: *Self) callconv(.C) void {
        if (!button.getActive()) {
            return;
        }

        const ColorTuple = struct { f64, f64, f64 };
        const color: ?ColorTuple = if (button.getSelectionColor()) |color| .{ color.r, color.g, color.b } else null;
        var self_value = gobject.Value.newFrom(self);
        defer self_value.unset();
        var v_value = gobject.Value.newFrom(glib.Variant.newFrom(color));
        defer v_value.unset();
        const params = [_]gobject.Value{ self_value, v_value };
        gobject.signalEmitv(&params, color_select, 0, null);
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub var parent: ?*Parent.Class = null;

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.implementDispose(&dispose);
            class.setTemplateFromSlice(template);
            class.bindTemplateChild("box", .{ .private = true });
            var param_types = [_]gobject.Type{gobject.typeFor(*glib.Variant)};
            color_select = gobject.signalNewv("color-selected", getType(), .{}, null, null, null, null, gobject.typeFor(void), 1, &param_types);
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Instance);
    };
};

pub const ColorButton = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.ToggleButton;
    const Self = @This();

    pub const Private = struct {
        toggle_button: *gtk.ToggleButton,
        drawing_area: *gtk.DrawingArea,
        color: Color,
        x_color: ?Color,

        pub var offset: c_int = 0;
    };

    const template = @embedFile("ui/color-button.ui");

    pub const getType = gobject.registerType(Self, .{
        .name = "NonogramsColorButton",
    });

    pub fn new(color: Color, x_color: ?Color) *Self {
        const self = Self.newWith(.{});
        self.private().color = color;
        self.private().x_color = x_color;
        return self;
    }

    pub fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();
        self.private().drawing_area.setDrawFunc(&draw, self, null);
    }

    pub fn getSelectionColor(self: *Self) ?Color {
        return if (self.private().x_color == null) self.private().color else null;
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), user_data));
        const w = @intToFloat(f64, width);
        const h = @intToFloat(f64, height);
        const color = self.private().color;
        cr.setSourceRgb(color.r, color.g, color.b);
        cr.rectangle(0, 0, w, h);
        cr.fill();
        if (self.private().x_color) |x_color| {
            cr.setSourceRgb(x_color.r, x_color.g, x_color.b);
            cr.setLineWidth(Dimensions.gap_frac * w);
            cr.moveTo(w * 0.25, h * 0.25);
            cr.lineTo(w * 0.75, h * 0.75);
            cr.stroke();
            cr.moveTo(w * 0.75, h * 0.25);
            cr.lineTo(w * 0.25, h * 0.75);
            cr.stroke();
        }
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub var parent: ?*Parent.Class = null;

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.setTemplateFromSlice(template);
            class.bindTemplateChild("drawing_area", .{ .private = true });
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Instance);
    };
};
