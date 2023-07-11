// Types and a parser for the format described in https://webpbn.com/pbn_fmt.html
// The triddler puzzle type is not supported.

const std = @import("std");
const xml = @import("xml");
const ascii = std.ascii;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const EnumArray = std.EnumArray;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;

pub const Error = error{InvalidPbn} || Allocator.Error;
pub const WriteError = fs.File.OpenError || fs.File.SyncError || fs.File.WriteError;

pub const PuzzleSet = struct {
    puzzles: []const Puzzle,
    source: ?[:0]const u8,
    id: ?[:0]const u8,
    title: ?[:0]const u8,
    author: ?[:0]const u8,
    author_id: ?[:0]const u8,
    copyright: ?[:0]const u8,
    arena: ArenaAllocator,

    pub fn parseBytes(allocator: Allocator, bytes: []const u8) Error!PuzzleSet {
        var stream = std.io.fixedBufferStream(bytes);
        var r = xml.reader(allocator, stream.reader(), xml.encoding.Utf8Decoder{}, .{
            // Normalization doesn't matter for anything we're doing
            .enable_normalization = false,
            // The PBN format does not use namespaces
            .namespace_aware = false,
        });
        defer r.deinit();
        return parseXml(allocator, &r) catch |err| switch (err) {
            // TODO: https://github.com/ianprime0509/zig-xml/issues/21
            error.CannotUndeclareNsPrefix,
            error.InvalidNsBinding,
            error.InvalidQName,
            error.UndeclaredNsPrefix,
            error.QNameNotAllowed,
            => unreachable,
            error.DoctypeNotSupported,
            error.DuplicateAttribute,
            error.InvalidCharacterReference,
            error.InvalidEncoding,
            error.InvalidPiTarget,
            error.InvalidUtf8,
            error.MismatchedEndTag,
            error.Overflow,
            error.SyntaxError,
            error.UndeclaredEntityReference,
            error.UnexpectedEndOfInput,
            => return error.InvalidPbn,
            else => |other| return other,
        };
    }

    pub fn writeFile(self: PuzzleSet, path: [:0]const u8) WriteError!void {
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();
        var buffered_writer = io.bufferedWriter(file.writer());
        const writer = xml.writer(buffered_writer.writer());
        try self.writeDoc(writer);
        try buffered_writer.flush();
        try file.sync();
    }

    pub fn deinit(self: *PuzzleSet) void {
        self.arena.deinit();
    }

    fn parseXml(allocator: Allocator, reader: anytype) !PuzzleSet {
        var puzzle_set: ?PuzzleSet = null;
        while (try reader.next()) |event| {
            switch (event) {
                .element_start => |e| if (e.name.is(null, "puzzleset")) {
                    puzzle_set = try parseInternal(allocator, reader.children());
                } else {
                    try reader.children().skip();
                },
                else => {},
            }
        }
        return puzzle_set orelse error.InvalidPbn;
    }

    fn parseInternal(a: Allocator, children: anytype) !PuzzleSet {
        var arena = ArenaAllocator.init(a);
        const allocator = arena.allocator();

        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var puzzles = ArrayListUnmanaged(Puzzle){};

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "source")) {
                    source = try textContent(allocator, children.children());
                } else if (child.name.is(null, "id")) {
                    id = try textContent(allocator, children.children());
                } else if (child.name.is(null, "title")) {
                    title = try textContent(allocator, children.children());
                } else if (child.name.is(null, "author")) {
                    author = try textContent(allocator, children.children());
                } else if (child.name.is(null, "authorid")) {
                    author_id = try textContent(allocator, children.children());
                } else if (child.name.is(null, "copyright")) {
                    copyright = try textContent(allocator, children.children());
                } else if (child.name.is(null, "puzzle")) {
                    try puzzles.append(allocator, try Puzzle.parse(allocator, child, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .source = source,
            .id = id,
            .title = title,
            .author = author,
            .author_id = author_id,
            .copyright = copyright,
            .puzzles = try puzzles.toOwnedSlice(allocator),
            .arena = arena,
        };
    }

    fn writeDoc(self: PuzzleSet, writer: anytype) !void {
        try writer.writeEvent(.{ .xml_declaration = .{ .version = "1.0", .encoding = "UTF-8", .standalone = true } });
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "puzzleset" } } });
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
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "puzzleset" } } });
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

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Puzzle {
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

        for (start.attributes) |attr| {
            if (attr.name.is(null, "defaultcolor")) {
                default_color = try allocator.dupeZ(u8, attr.value);
            } else if (attr.name.is(null, "backgroundcolor")) {
                background_color = try allocator.dupeZ(u8, attr.value);
            }
        }

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "source")) {
                    source = try textContent(allocator, children.children());
                } else if (child.name.is(null, "id")) {
                    id = try textContent(allocator, children.children());
                } else if (child.name.is(null, "title")) {
                    title = try textContent(allocator, children.children());
                } else if (child.name.is(null, "author")) {
                    author = try textContent(allocator, children.children());
                } else if (child.name.is(null, "authorid")) {
                    author_id = try textContent(allocator, children.children());
                } else if (child.name.is(null, "copyright")) {
                    copyright = try textContent(allocator, children.children());
                } else if (child.name.is(null, "description")) {
                    description = try textContent(allocator, children.children());
                } else if (child.name.is(null, "color")) {
                    const color = try Color.parse(allocator, child, children.children());
                    try colors.put(allocator, color.name, color);
                } else if (child.name.is(null, "clues")) {
                    const clues = try Clues.parse(allocator, child, children.children());
                    switch (clues.type) {
                        .rows => row_clues = clues,
                        .columns => column_clues = clues,
                    }
                } else if (child.name.is(null, "solution")) {
                    try solutions.append(allocator, try Solution.parse(allocator, child, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
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
            .solutions = try solutions.toOwnedSlice(allocator),
        };
    }

    fn write(self: Puzzle, writer: anytype) !void {
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "puzzle" }, .attributes = &.{
            .{ .name = .{ .local = "defaultcolor" }, .value = self.default_color },
            .{ .name = .{ .local = "backgroundcolor" }, .value = self.background_color },
        } } });
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
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "puzzle" } } });
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
            .r = @as(f64, @floatFromInt(rgb.r)) / 255,
            .g = @as(f64, @floatFromInt(rgb.g)) / 255,
            .b = @as(f64, @floatFromInt(rgb.b)) / 255,
        };
    }

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Color {
        var name: ?[:0]const u8 = null;
        var char: ?u8 = null;

        for (start.attributes) |attr| {
            if (attr.name.is(null, "name")) {
                name = try allocator.dupeZ(u8, attr.value);
            } else if (attr.name.is(null, "char")) {
                if (attr.value.len != 1) {
                    return error.InvalidPbn;
                }
                char = attr.value[0];
            }
        }

        const value: [:0]const u8 = try textContent(allocator, children.children());

        return .{
            .name = name orelse return error.InvalidPbn,
            .char = char,
            .value = value,
        };
    }

    fn write(self: Color, writer: anytype) !void {
        // TODO: OK the current writer API is really bad
        var attrs = std.BoundedArray(xml.Event.Attribute, 2){};
        attrs.appendAssumeCapacity(.{ .name = .{ .local = "name" }, .value = self.name });
        var char_buf: [1]u8 = undefined;
        if (self.char) |char| {
            char_buf[0] = char;
            attrs.appendAssumeCapacity(.{ .name = .{ .local = "char" }, .value = &char_buf });
        }
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "color" }, .attributes = attrs.slice() } });
        try writer.writeEvent(.{ .element_content = .{ .content = self.value } });
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "color" } } });
    }
};

pub const Clues = struct {
    type: Type,
    lines: []const Line,

    pub const Type = enum { columns, rows };

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Clues {
        var @"type": ?Type = null;
        var lines = ArrayListUnmanaged(Line){};

        for (start.attributes) |attr| {
            if (attr.name.is(null, "type")) {
                @"type" = meta.stringToEnum(Type, attr.value) orelse return error.InvalidPbn;
            }
        }

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "line")) {
                    try lines.append(allocator, try Line.parse(allocator, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .type = @"type" orelse return error.InvalidPbn,
            .lines = try lines.toOwnedSlice(allocator),
        };
    }

    fn write(self: Clues, writer: anytype) !void {
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "clues" }, .attributes = &.{
            .{ .name = .{ .local = "type" }, .value = @tagName(self.type) },
        } } });
        for (self.lines) |line| {
            try line.write(writer);
        }
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "clues" } } });
    }
};

pub const Line = struct {
    counts: []const Count,

    fn parse(allocator: Allocator, children: anytype) !Line {
        var counts = ArrayListUnmanaged(Count){};

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "count")) {
                    try counts.append(allocator, try Count.parse(allocator, child, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .counts = try counts.toOwnedSlice(allocator),
        };
    }

    fn write(self: Line, writer: anytype) !void {
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "line" } } });
        for (self.counts) |count| {
            try count.write(writer);
        }
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "line" } } });
    }
};

pub const Count = struct {
    color: ?[:0]const u8,
    n: usize,

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Count {
        var color: ?[:0]const u8 = null;

        for (start.attributes) |attr| {
            if (attr.name.is(null, "color")) {
                color = try allocator.dupeZ(u8, attr.value);
            }
        }

        const n = blk: {
            const content = try textContent(allocator, children.children());
            defer allocator.free(content);
            break :blk fmt.parseInt(usize, content, 10) catch return error.InvalidPbn;
        };

        return .{
            .color = color,
            .n = n,
        };
    }

    fn write(self: Count, writer: anytype) !void {
        // TODO: improve the XML writer API. This should be easier.
        var attrs = std.BoundedArray(xml.Event.Attribute, 1){};
        if (self.color) |color| {
            attrs.appendAssumeCapacity(.{ .name = .{ .local = "color" }, .value = color });
        }
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "count" }, .attributes = attrs.slice() } });
        var buf: [32]u8 = undefined;
        try writer.writeEvent(.{ .element_content = .{ .content = fmt.bufPrint(&buf, "{}", .{self.n}) catch unreachable } });
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "count" } } });
    }
};

pub const Solution = struct {
    type: Type,
    image: Image,

    pub const Type = enum { goal, solution, saved };

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Solution {
        var @"type": ?Type = null;
        var image: ?Image = null;

        for (start.attributes) |attr| {
            if (attr.name.is(null, "type")) {
                @"type" = meta.stringToEnum(Type, attr.value) orelse return error.InvalidPbn;
            }
        }

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "image")) {
                    image = try Image.parse(allocator, children.children());
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .type = @"type" orelse .goal,
            .image = image orelse return error.InvalidPbn,
        };
    }

    fn write(self: Solution, writer: anytype) !void {
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "solution" }, .attributes = &.{
            .{ .name = .{ .local = "type" }, .value = @tagName(self.type) },
        } } });
        try self.image.write(writer);
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "solution" } } });
    }
};

pub const Image = struct {
    rows: usize,
    columns: usize,
    chars: []const []const u8,

    pub fn deinit(self: Image, allocator: Allocator) void {
        for (self.chars) |options| {
            allocator.free(options);
        }
        allocator.free(self.chars);
    }

    pub fn fromText(allocator: Allocator, text: []const u8) Error!Image {
        var chars = ArrayListUnmanaged([]const u8){};
        errdefer {
            for (chars.items) |options| {
                allocator.free(options);
            }
            chars.deinit(allocator);
        }

        var rows: usize = 0;
        var columns: usize = 0;
        var pos: usize = 0;
        var maybe_row_start = mem.indexOfScalarPos(u8, text, pos, '|');
        while (maybe_row_start) |row_start| : (maybe_row_start = mem.indexOfScalarPos(u8, text, pos, '|')) {
            const row_end = mem.indexOfScalarPos(u8, text, row_start + 1, '|') orelse return error.InvalidPbn;
            const row_chars = text[row_start + 1 .. row_end];
            var row_columns: usize = 0;
            var row_pos: usize = 0;

            while (row_pos < row_chars.len) {
                if (ascii.isWhitespace(row_chars[row_pos])) {
                    continue;
                } else if (row_chars[row_pos] == '[') {
                    const options_end = mem.indexOfScalarPos(u8, row_chars, row_pos + 1, ']') orelse return error.InvalidPbn;
                    try chars.append(allocator, try allocator.dupeZ(u8, row_chars[row_pos + 1 .. options_end]));
                    row_pos = options_end + 1;
                    row_columns += 1;
                } else {
                    try chars.append(allocator, try allocator.dupeZ(u8, &.{row_chars[row_pos]}));
                    row_pos += 1;
                    row_columns += 1;
                }
            }

            if (columns == 0) {
                columns = row_columns;
            } else if (columns != row_columns) {
                return error.InvalidPbn;
            }
            rows += 1;
            pos = row_end + 1;
        }

        return .{
            .rows = rows,
            .columns = columns,
            .chars = try chars.toOwnedSlice(allocator),
        };
    }

    pub fn toClues(self: Image, allocator: Allocator, colors: []const Color, background_color: []const u8) Error!struct { rows: Clues, columns: Clues } {
        var color_names = AutoHashMapUnmanaged(u8, [:0]const u8){};
        defer color_names.deinit(allocator);
        try color_names.ensureTotalCapacity(allocator, @intCast(colors.len));
        var bg_color_char: ?u8 = null;
        for (colors) |color| {
            if (color.char) |char| {
                color_names.putAssumeCapacity(char, color.name);
                if (mem.eql(u8, color.name, background_color)) {
                    bg_color_char = char;
                }
            }
        }

        var row_lines = try ArrayListUnmanaged(Line).initCapacity(allocator, self.rows);
        for (0..self.rows) |i| {
            var counts = ArrayListUnmanaged(Count){};
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..self.columns) |j| {
                const options = self.chars[self.columns * i + j];
                if (options.len != 1) {
                    return error.InvalidPbn;
                }
                const color = options[0];
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
            row_lines.appendAssumeCapacity(.{ .counts = try counts.toOwnedSlice(allocator) });
        }

        var column_lines = try ArrayListUnmanaged(Line).initCapacity(allocator, self.columns);
        for (0..self.columns) |j| {
            var counts = ArrayListUnmanaged(Count){};
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..self.rows) |i| {
                const options = self.chars[self.columns * i + j];
                if (options.len != 1) {
                    return error.InvalidPbn;
                }
                const color = options[0];
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
            column_lines.appendAssumeCapacity(.{ .counts = try counts.toOwnedSlice(allocator) });
        }

        return .{
            .rows = .{ .type = .rows, .lines = try row_lines.toOwnedSlice(allocator) },
            .columns = .{ .type = .columns, .lines = try column_lines.toOwnedSlice(allocator) },
        };
    }

    fn parse(allocator: Allocator, children: anytype) !Image {
        const text = try textContent(allocator, children);
        defer allocator.free(text);
        return try fromText(allocator, text);
    }

    fn write(self: Image, writer: anytype) !void {
        try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = "image" } } });
        var row_iter = mem.window([]const u8, self.chars, self.columns, self.columns);
        while (row_iter.next()) |row| {
            try writer.writeEvent(.{ .element_content = .{ .content = "|" } });
            for (row) |options| {
                if (options.len == 1) {
                    try writer.writeEvent(.{ .element_content = .{ .content = &[_]u8{options[0]} } });
                } else {
                    try writer.writeEvent(.{ .element_content = .{ .content = "[" } });
                    for (options) |char| {
                        try writer.writeEvent(.{ .element_content = .{ .content = &[_]u8{char} } });
                    }
                    try writer.writeEvent(.{ .element_content = .{ .content = "]" } });
                }
            }
            try writer.writeEvent(.{ .element_content = .{ .content = "|\n" } });
        }
        try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = "image" } } });
    }
};

fn writeTextElement(writer: anytype, name: [:0]const u8, value: [:0]const u8) !void {
    try writer.writeEvent(.{ .element_start = .{ .name = .{ .local = name } } });
    try writer.writeEvent(.{ .element_content = .{ .content = value } });
    try writer.writeEvent(.{ .element_end = .{ .name = .{ .local = name } } });
}

fn textContent(allocator: Allocator, children: anytype) ![:0]u8 {
    var text = ArrayListUnmanaged(u8){};
    while (try children.next()) |event| {
        switch (event) {
            .element_content => |e| try text.appendSlice(allocator, e.content),
            else => {},
        }
    }
    return try text.toOwnedSliceSentinel(allocator, 0);
}
