// Types and a parser for the format described in https://webpbn.com/pbn_fmt.html
// The triddler puzzle type is not supported.

const std = @import("std");
const c = @import("c.zig");
const xml = @import("xml.zig");
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const EnumArray = std.EnumArray;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;

pub const Error = error{InvalidPbn} || Allocator.Error;
pub const WriteError = error{WriteFailed};

pub const PuzzleSet = struct {
    puzzles: []const Puzzle,
    source: ?[:0]const u8,
    id: ?[:0]const u8,
    title: ?[:0]const u8,
    author: ?[:0]const u8,
    author_id: ?[:0]const u8,
    copyright: ?[:0]const u8,
    arena: ArenaAllocator,

    pub fn parseBytes(allocator: Allocator, bytes: []const u8, url: [:0]const u8) Error!PuzzleSet {
        const doc = xml.parseBytes(bytes, url) catch return error.InvalidPbn;
        defer c.xmlFreeDoc(doc);
        return try parseDoc(allocator, doc);
    }

    pub fn parseFile(allocator: Allocator, file: [:0]const u8) Error!PuzzleSet {
        const doc = xml.parseFile(file) catch return error.InvalidPbn;
        defer c.xmlFreeDoc(doc);
        return try parseDoc(allocator, doc);
    }

    pub fn writeFile(self: PuzzleSet, file: [:0]const u8) WriteError!void {
        const writer = c.xmlNewTextWriterFilename(file, 0).?;
        defer c.xmlFreeTextWriter(writer);
        _ = c.xmlTextWriterSetIndent(writer, 2);
        self.writeDoc(writer) catch return error.WriteFailed;
    }

    pub fn deinit(self: *PuzzleSet) void {
        self.arena.deinit();
    }

    fn parseDoc(a: Allocator, doc: *c.xmlDoc) !PuzzleSet {
        var arena = ArenaAllocator.init(a);
        const allocator = arena.allocator();
        const node: *c.xmlNode = c.xmlDocGetRootElement(doc) orelse return error.InvalidPbn;

        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var puzzles = ArrayListUnmanaged(Puzzle){};

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "source")) {
                source = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "id")) {
                id = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "title")) {
                title = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "author")) {
                author = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "authorid")) {
                author_id = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "copyright")) {
                copyright = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "puzzle")) {
                try puzzles.append(allocator, try Puzzle.parse(allocator, child));
            }
        }

        return .{
            .source = source,
            .id = id,
            .title = title,
            .author = author,
            .author_id = author_id,
            .copyright = copyright,
            .puzzles = puzzles.items,
            .arena = arena,
        };
    }

    fn writeDoc(self: PuzzleSet, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartDocument(writer, "1.0", "UTF-8", "yes"));
        try xml.handle(c.xmlTextWriterStartElement(writer, "puzzleset"));
        if (self.source) |source| {
            try writeTextElement(writer, "source", source);
        }
        if (self.id) |id| {
            try writeTextElement(writer, "id", id);
        }
        if (self.title) |title| {
            try writeTextElement(writer, "title", title);
        }
        if (self.author) |author| {
            try writeTextElement(writer, "author", author);
        }
        if (self.author_id) |author_id| {
            try writeTextElement(writer, "authorid", author_id);
        }
        if (self.copyright) |copyright| {
            try writeTextElement(writer, "copyright", copyright);
        }
        for (self.puzzles) |puzzle| {
            try puzzle.write(writer);
        }
        try xml.handle(c.xmlTextWriterEndElement(writer));
        try xml.handle(c.xmlTextWriterEndDocument(writer));
    }
};

pub const Puzzle = struct {
    source: ?[:0]const u8,
    id: ?[:0]const u8,
    title: ?[:0]const u8,
    author: ?[:0]const u8,
    author_id: ?[:0]const u8,
    copyright: ?[:0]const u8,
    description: ?[:0]const u8,
    colors: StringArrayHashMapUnmanaged(Color),
    default_color: [:0]const u8,
    background_color: [:0]const u8,
    row_clues: Clues,
    column_clues: Clues,
    solutions: []const Solution,

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Puzzle {
        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var description: ?[:0]const u8 = null;
        var colors = StringArrayHashMapUnmanaged(Color){};
        var default_color: ?[:0]const u8 = null;
        var background_color: ?[:0]const u8 = null;
        var row_clues: ?Clues = null;
        var column_clues: ?Clues = null;
        var solutions = ArrayListUnmanaged(Solution){};

        // Predefined colors
        try colors.put(allocator, "black", Color.black);
        try colors.put(allocator, "white", Color.white);

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "defaultcolor")) {
                default_color = try xml.attrContent(allocator, attr);
            } else if (xml.attrIs(attr, null, "backgroundcolor")) {
                background_color = try xml.attrContent(allocator, attr);
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "source")) {
                source = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "id")) {
                id = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "title")) {
                title = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "author")) {
                author = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "authorid")) {
                author_id = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "copyright")) {
                copyright = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "description")) {
                description = try xml.nodeContent(allocator, child);
            } else if (xml.nodeIs(child, null, "color")) {
                const color = try Color.parse(allocator, child);
                try colors.put(allocator, color.name, color);
            } else if (xml.nodeIs(child, null, "clues")) {
                const parsed_clues = try Clues.parse(allocator, child);
                switch (parsed_clues.type) {
                    .rows => row_clues = parsed_clues,
                    .columns => column_clues = parsed_clues,
                }
            } else if (xml.nodeIs(child, null, "solution")) {
                try solutions.append(allocator, try Solution.parse(allocator, child));
            }
        }

        if (row_clues == null or column_clues == null) {
            find_solution: {
                for (solutions.items) |solution| {
                    if (solution.type == .goal) {
                        const clues = try solution.image.toClues(allocator, colors.values(), background_color orelse "white");
                        row_clues = clues.rows;
                        column_clues = clues.columns;
                        break :find_solution;
                    }
                }
                return error.InvalidPbn;
            }
        }

        return .{
            .source = source,
            .id = id,
            .title = title,
            .author = author,
            .author_id = author_id,
            .copyright = copyright,
            .description = description,
            .colors = colors,
            .default_color = default_color orelse "black",
            .background_color = background_color orelse "white",
            // row_clues and column_clues cannot be null here since we tried to
            // derive them above, already failing if that wasn't possible
            .row_clues = row_clues.?,
            .column_clues = column_clues.?,
            .solutions = solutions.items,
        };
    }

    fn write(self: Puzzle, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "puzzle"));
        try xml.handle(c.xmlTextWriterWriteAttribute(writer, "defaultcolor", self.default_color));
        try xml.handle(c.xmlTextWriterWriteAttribute(writer, "backgroundcolor", self.background_color));
        if (self.source) |source| {
            try writeTextElement(writer, "source", source);
        }
        if (self.id) |id| {
            try writeTextElement(writer, "id", id);
        }
        if (self.title) |title| {
            try writeTextElement(writer, "title", title);
        }
        if (self.author) |author| {
            try writeTextElement(writer, "author", author);
        }
        if (self.author_id) |author_id| {
            try writeTextElement(writer, "authorid", author_id);
        }
        if (self.copyright) |copyright| {
            try writeTextElement(writer, "copyright", copyright);
        }
        if (self.description) |description| {
            try writeTextElement(writer, "description", description);
        }
        for (self.colors.values()) |color| {
            try color.write(writer);
        }
        try self.row_clues.write(writer);
        try self.column_clues.write(writer);
        for (self.solutions) |solution| {
            try solution.write(writer);
        }
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Color = struct {
    name: [:0]const u8,
    char: ?u8,
    value: [:0]const u8,

    pub const black = Color{ .name = "black", .char = 'X', .value = "000" };
    pub const white = Color{ .name = "white", .char = '.', .value = "fff" };

    pub fn toRgb(self: Color) error{InvalidColor}!struct { r: u8, g: u8, b: u8 } {
        if (self.value.len == 3) {
            return .{
                .r = fmt.parseInt(u8, &.{ self.value[0], self.value[0] }, 16) catch return error.InvalidColor,
                .g = fmt.parseInt(u8, &.{ self.value[1], self.value[1] }, 16) catch return error.InvalidColor,
                .b = fmt.parseInt(u8, &.{ self.value[2], self.value[2] }, 16) catch return error.InvalidColor,
            };
        } else if (self.value.len == 6) {
            return .{
                .r = fmt.parseInt(u8, self.value[0..2], 16) catch return error.InvalidColor,
                .g = fmt.parseInt(u8, self.value[2..4], 16) catch return error.InvalidColor,
                .b = fmt.parseInt(u8, self.value[4..6], 16) catch return error.InvalidColor,
            };
        } else {
            return error.InvalidColor;
        }
    }

    pub fn toFloatRgb(self: Color) error{InvalidColor}!struct { r: f64, g: f64, b: f64 } {
        const rgb = try self.toRgb();
        return .{
            .r = @intToFloat(f64, rgb.r) / 255,
            .g = @intToFloat(f64, rgb.g) / 255,
            .b = @intToFloat(f64, rgb.b) / 255,
        };
    }

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Color {
        var name: ?[:0]const u8 = null;
        var char: ?u8 = null;
        const value: ?[:0]const u8 = try xml.nodeContent(allocator, node);

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "name")) {
                name = try xml.attrContent(allocator, attr);
            } else if (xml.attrIs(attr, null, "char")) {
                const content = try xml.attrContent(allocator, attr);
                defer allocator.free(content);
                if (content.len != 1) {
                    return error.InvalidPbn;
                }
                char = content[0];
            }
        }

        return .{
            .name = name orelse return error.InvalidPbn,
            .char = char,
            .value = value orelse return error.InvalidPbn,
        };
    }

    fn write(self: Color, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "color"));
        try xml.handle(c.xmlTextWriterWriteAttribute(writer, "name", self.name));
        if (self.char) |char| {
            try xml.handle(c.xmlTextWriterWriteAttribute(writer, "char", &[_:0]u8{ char, 0 }));
        }
        try xml.handle(c.xmlTextWriterWriteString(writer, self.value));
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Clues = struct {
    type: Type,
    lines: []const Line,

    pub const Type = enum { columns, rows };

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Clues {
        var @"type": ?Type = null;
        var lines = ArrayListUnmanaged(Line){};

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "type")) {
                const content = try xml.attrContent(allocator, attr);
                defer allocator.free(content);
                @"type" = meta.stringToEnum(Type, content) orelse return error.InvalidPbn;
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "line")) {
                try lines.append(allocator, try Line.parse(allocator, child));
            }
        }

        return .{
            .type = @"type" orelse return error.InvalidPbn,
            .lines = lines.items,
        };
    }

    fn write(self: Clues, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "clues"));
        try xml.handle(c.xmlTextWriterWriteAttribute(writer, "type", @tagName(self.type)));
        for (self.lines) |line| {
            try line.write(writer);
        }
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Line = struct {
    counts: []const Count,

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Line {
        var counts = ArrayListUnmanaged(Count){};

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "count")) {
                try counts.append(allocator, try Count.parse(allocator, child));
            }
        }

        return .{
            .counts = counts.items,
        };
    }

    fn write(self: Line, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "line"));
        for (self.counts) |count| {
            try count.write(writer);
        }
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Count = struct {
    color: ?[:0]const u8,
    n: usize,

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Count {
        var color: ?[:0]const u8 = null;
        const n = blk: {
            const content = try xml.nodeContent(allocator, node.children);
            defer allocator.free(content);
            break :blk fmt.parseInt(usize, content, 10) catch return error.InvalidPbn;
        };

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "color")) {
                color = try xml.attrContent(allocator, attr);
            }
        }

        return .{
            .color = color,
            .n = n,
        };
    }

    fn write(self: Count, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "count"));
        if (self.color) |color| {
            try xml.handle(c.xmlTextWriterWriteAttribute(writer, "color", color));
        }
        var buf: [32]u8 = undefined;
        const fmtlen = fmt.formatIntBuf(&buf, self.n, 10, .lower, .{});
        buf[fmtlen] = 0;
        try xml.handle(c.xmlTextWriterWriteString(writer, buf[0..fmtlen :0]));
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Solution = struct {
    type: Type,
    image: Image,

    pub const Type = enum { goal, solution, saved };

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Solution {
        var @"type": ?Type = null;
        var image: ?Image = null;

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "type")) {
                const content = try xml.attrContent(allocator, attr);
                defer allocator.free(content);
                @"type" = meta.stringToEnum(Type, content) orelse return error.InvalidPbn;
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "image")) {
                image = try Image.parse(allocator, node);
            }
        }

        return .{
            .type = @"type" orelse .goal,
            .image = image orelse return error.InvalidPbn,
        };
    }

    fn write(self: Solution, writer: *c.xmlTextWriter) !void {
        try xml.handle(c.xmlTextWriterStartElement(writer, "solution"));
        try xml.handle(c.xmlTextWriterWriteAttribute(writer, "type", @tagName(self.type)));
        try self.image.write(writer);
        try xml.handle(c.xmlTextWriterEndElement(writer));
    }
};

pub const Image = struct {
    text: [:0]const u8,

    pub fn toClues(self: Image, allocator: Allocator, colors: []const Color, background_color: []const u8) Error!struct { rows: Clues, columns: Clues } {
        var image_colors = ArrayListUnmanaged(u8){};
        defer image_colors.deinit(allocator);

        var rows: usize = 0;
        var columns: usize = 0;
        var pos: usize = 0;
        var maybe_row_start = mem.indexOfScalarPos(u8, self.text, pos, '|');
        while (maybe_row_start) |row_start| : (maybe_row_start = mem.indexOfScalarPos(u8, self.text, pos, '|')) {
            const row_end = mem.indexOfScalarPos(u8, self.text, row_start + 1, '|') orelse return error.InvalidPbn;
            const row_chars = self.text[row_start + 1 .. row_end];
            if (columns == 0) {
                columns = row_chars.len;
            } else if (columns != row_chars.len) {
                return error.InvalidPbn;
            }
            try image_colors.appendSlice(allocator, row_chars);
            rows += 1;
            pos = row_end + 1;
        }

        var color_names = AutoHashMapUnmanaged(u8, [:0]const u8){};
        defer color_names.deinit(allocator);
        try color_names.ensureTotalCapacity(allocator, @truncate(u32, colors.len));
        var bg_color_char: ?u8 = null;
        for (colors) |color| {
            if (color.char) |char| {
                try color_names.put(allocator, char, color.name);
                if (mem.eql(u8, color.name, background_color)) {
                    bg_color_char = char;
                }
            }
        }

        var row_lines = try ArrayListUnmanaged(Line).initCapacity(allocator, rows);
        for (0..rows) |i| {
            var counts = ArrayListUnmanaged(Count){};
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..columns) |j| {
                const color = image_colors.items[columns * i + j];
                if (color != run_color) {
                    if (run_len > 0 and run_color != bg_color_char) {
                        try counts.append(allocator, .{
                            .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                            .n = run_len,
                        });
                    }
                    run_color = color;
                    run_len = 0;
                }
                run_len += 1;
            }
            if (run_len > 0 and run_color != bg_color_char) {
                try counts.append(allocator, .{
                    .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                    .n = run_len,
                });
            }
            try row_lines.append(allocator, .{ .counts = counts.items });
        }
        var column_lines = try ArrayListUnmanaged(Line).initCapacity(allocator, columns);
        for (0..columns) |j| {
            var counts = ArrayListUnmanaged(Count){};
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..rows) |i| {
                const color = image_colors.items[columns * i + j];
                if (color != run_color) {
                    if (run_len > 0 and run_color != bg_color_char) {
                        try counts.append(allocator, .{
                            .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                            .n = run_len,
                        });
                    }
                    run_color = color;
                    run_len = 0;
                }
                run_len += 1;
            }
            if (run_len > 0 and run_color != bg_color_char) {
                try counts.append(allocator, .{
                    .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                    .n = run_len,
                });
            }
            try column_lines.append(allocator, .{ .counts = counts.items });
        }

        return .{
            .rows = .{ .type = .rows, .lines = row_lines.items },
            .columns = .{ .type = .columns, .lines = column_lines.items },
        };
    }

    fn parse(allocator: Allocator, node: *const c.xmlNode) !Image {
        return .{ .text = try xml.nodeContent(allocator, node) };
    }

    fn write(self: Image, writer: *c.xmlTextWriter) !void {
        try writeTextElement(writer, "image", self.text);
    }
};

fn writeTextElement(writer: *c.xmlTextWriter, name: [:0]const u8, value: [:0]const u8) !void {
    try xml.handle(c.xmlTextWriterStartElement(writer, name));
    try xml.handle(c.xmlTextWriterWriteString(writer, value));
    try xml.handle(c.xmlTextWriterEndElement(writer));
}
