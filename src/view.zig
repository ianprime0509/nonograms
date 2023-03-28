const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const ArenaAllocator = std.heap.ArenaAllocator;
const raw_c_allocator = std.heap.raw_c_allocator;

const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    const white = Color{ .r = 1, .g = 1, .b = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const red = Color{ .r = 1, .g = 0, .b = 0 };
};

const Hint = struct {
    n: usize,
    color: Color,
};

const State = struct {
    colors: []Color,
    selected_color: Color,
    row_hints: [][]Hint,
    max_row_hints: usize,
    column_hints: [][]Hint,
    max_column_hints: usize,

    fn colorIndex(self: State, row: usize, column: usize) ?usize {
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
        draw_start: Point,
        state: State,
        dimensions: Dimensions,
        arena: ArenaAllocator,

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

        self.private().arena = ArenaAllocator.init(raw_c_allocator);
        const a = self.private().arena.allocator();

        const rows = 10;
        const columns = 15;
        const row_hints = a.alloc([]Hint, rows) catch @panic("OOM");
        for (row_hints) |*row| {
            row.* = a.alloc(Hint, 3) catch @panic("OOM");
            for (row.*) |*hint| {
                hint.* = Hint{ .n = 12, .color = Color.black };
            }
        }
        const column_hints = a.alloc([]Hint, columns) catch @panic("OOM");
        for (column_hints) |*column| {
            column.* = a.alloc(Hint, 3) catch @panic("OOM");
            for (column.*) |*hint| {
                hint.* = Hint{ .n = 12, .color = Color.black };
            }
        }
        const colors = a.alloc(Color, rows * columns) catch @panic("OOM");
        for (colors) |*color| {
            color.* = Color.white;
        }
        self.private().state = .{
            .colors = colors,
            .selected_color = Color.black,
            .row_hints = row_hints,
            .max_row_hints = 3,
            .column_hints = column_hints,
            .max_column_hints = 3,
        };
        self.private().dimensions = .{
            .board_pos = .{ .x = 0, .y = 0 },
            .tile_size = 0,
        };
    }

    fn dispose(self: *Self) callconv(.C) void {
        while (self.getFirstChild()) |child| child.unparent();
        self.private().arena.deinit();
        Class.parent.?.callDispose(self.as(gobject.Object));
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, user_data: ?*anyopaque) callconv(.C) void {
        const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), user_data));
        const state = self.private().state;
        const dims = self.private().dimensions;

        if (dims.tile_size <= 0) return;

        drawRules(cr, dims, state);

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

        for (state.colors, 0..) |color, n| {
            const i = state.max_column_hints + n / state.column_hints.len;
            const j = state.max_row_hints + n % state.column_hints.len;
            const pos = dims.tilePosition(i, j);
            drawTile(cr, color, pos, dims);
        }
    }

    fn drawHint(cr: *cairo.Context, layout: *pango.Layout, hint: Hint, pos: Point, dims: Dimensions) void {
        var buf: [32]u8 = undefined;
        cr.setSourceRgb(hint.color.r, hint.color.g, hint.color.b);
        const text = std.fmt.bufPrintZ(&buf, "{}", .{hint.n}) catch @panic("format");
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

    fn drawTile(cr: *cairo.Context, color: Color, pos: Point, dims: Dimensions) void {
        cr.setSourceRgb(color.r, color.g, color.b);
        cr.rectangle(pos.x, pos.y, dims.tile_size, dims.tile_size);
        cr.fill();
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

    fn handleDragBegin(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        self.private().draw_start = .{ .x = x, .y = y };
        self.handleDraw(x, y);
    }

    fn handleDragUpdate(_: *gtk.GestureDrag, x: f64, y: f64, self: *Self) callconv(.C) void {
        const draw_start = self.private().draw_start;
        self.handleDraw(draw_start.x + x, draw_start.y + y);
    }

    fn handleDraw(self: *Self, x: f64, y: f64) void {
        const state = self.private().state;
        const dims = self.private().dimensions;
        if (dims.positionTile(x, y)) |tile| {
            if (state.colorIndex(tile.row, tile.column)) |n| {
                state.colors[n] = state.selected_color;
                self.private().drawing_area.queueDraw();
            }
        }
    }

    fn handleResize(_: *gtk.DrawingArea, width_int: c_int, height_int: c_int, self: *Self) callconv(.C) void {
        const state = self.private().state;
        const dimensions = &self.private().dimensions;

        const width = @intToFloat(f64, width_int);
        const height = @intToFloat(f64, height_int);
        const rows = @intToFloat(f64, state.row_hints.len + state.max_column_hints);
        const columns = @intToFloat(f64, state.column_hints.len + state.max_row_hints);

        const max_tile_height = height / (rows + Dimensions.gap_frac * rows + Dimensions.gap_frac);
        const max_tile_width = width / (columns + Dimensions.gap_frac * columns + Dimensions.gap_frac);
        dimensions.*.tile_size = @min(max_tile_height, max_tile_width);
        const board_height = rows * dimensions.tile_size + (rows + 1) * Dimensions.gap_frac * dimensions.tile_size;
        const board_width = columns * dimensions.tile_size + (columns + 1) * Dimensions.gap_frac * dimensions.tile_size;
        dimensions.*.board_pos = .{
            .x = width / 2 - board_width / 2 + Dimensions.gap_frac * dimensions.tile_size,
            .y = height / 2 - board_height / 2 + Dimensions.gap_frac * dimensions.tile_size,
        };
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
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Instance);
    };
};
