// Types and a parser for the format described in https://webpbn.com/pbn_fmt.html
// The triddler puzzle type is not supported.

const std = @import("std");
const xml = @import("xml");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Error = error{InvalidPbn} || Allocator.Error;
pub const WriteError = std.fs.File.OpenError || std.fs.File.SyncError || std.fs.File.WriteError;

pub const PuzzleSet = struct {
    puzzles: []const Puzzle,
    source: ?[:0]const u8,
    id: ?[:0]const u8,
    title: ?[:0]const u8,
    author: ?[:0]const u8,
    author_id: ?[:0]const u8,
    copyright: ?[:0]const u8,
    notes: []const [:0]const u8,
    arena: ArenaAllocator,

    pub fn parseBytes(allocator: Allocator, bytes: []const u8) Error!PuzzleSet {
        var doc = xml.StaticDocument.init(bytes);
        return parseDoc(allocator, &doc);
    }

    pub fn parseReader(allocator: Allocator, data_reader: anytype) (Error || @TypeOf(data_reader).Error)!PuzzleSet {
        var doc = xml.streamingDocument(allocator, data_reader);
        defer doc.deinit();
        return parseDoc(allocator, &doc);
    }

    pub fn writeFile(set: PuzzleSet, path: [:0]const u8) WriteError!void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffered_writer = std.io.bufferedWriter(file.writer());
        var out = xml.streamingOutput(buffered_writer.writer());
        var writer = out.writer(.{ .indent = "  " });
        try set.writeDoc(&writer);
        try buffered_writer.flush();
        try file.sync();
    }

    pub fn deinit(set: *PuzzleSet) void {
        set.arena.deinit();
    }

    fn parseDoc(allocator: Allocator, doc: anytype) !PuzzleSet {
        var reader = doc.reader(allocator, .{
            // The PBN format does not use namespaces
            .namespace_aware = false,
        });
        defer reader.deinit();
        return parseXml(allocator, &reader) catch |err| switch (err) {
            error.MalformedXml => return error.InvalidPbn,
            else => |other| return other,
        };
    }

    fn parseXml(allocator: Allocator, reader: anytype) !PuzzleSet {
        try reader.skipProlog();
        if (!mem.eql(u8, reader.elementName(), "puzzleset")) return error.InvalidPbn;
        var repository = try parseInternal(allocator, reader);
        errdefer repository.deinit();
        try reader.skipDocument();
        return repository;
    }

    fn parseInternal(a: Allocator, reader: anytype) !PuzzleSet {
        var arena = ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var puzzles = std.ArrayList(Puzzle).init(allocator);
        var notes = std.ArrayList([:0]const u8).init(allocator);

        while (true) {
            switch (try reader.read()) {
                .element_start => {
                    const child = reader.elementName();
                    if (mem.eql(u8, child, "source")) {
                        source = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "id")) {
                        id = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "title")) {
                        title = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "author")) {
                        author = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "authorid")) {
                        author_id = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "copyright")) {
                        copyright = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "puzzle")) {
                        try puzzles.append(try Puzzle.parse(allocator, reader));
                    } else if (mem.eql(u8, child, "note")) {
                        try notes.append(try readElementTextAllocZ(allocator, reader));
                    } else {
                        try reader.skipElement();
                    }
                },
                .element_end => break,
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
            .puzzles = try puzzles.toOwnedSlice(),
            .notes = try notes.toOwnedSlice(),
            .arena = arena,
        };
    }

    fn writeDoc(set: PuzzleSet, writer: anytype) !void {
        try writer.xmlDeclaration("UTF-8", true);
        try writer.elementStart("puzzleset");
        if (set.source) |source| {
            try writeTextElement(writer, "source", source);
        }
        if (set.id) |id| {
            try writeTextElement(writer, "id", id);
        }
        if (set.title) |title| {
            try writeTextElement(writer, "title", title);
        }
        if (set.author) |author| {
            try writeTextElement(writer, "author", author);
        }
        if (set.author_id) |author_id| {
            try writeTextElement(writer, "authorid", author_id);
        }
        if (set.copyright) |copyright| {
            try writeTextElement(writer, "copyright", copyright);
        }
        for (set.puzzles) |puzzle| {
            try puzzle.write(writer);
        }
        for (set.notes) |note| {
            try writeTextElement(writer, "note", note);
        }
        try writer.elementEnd("puzzleset");
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
    colors: std.StringArrayHashMapUnmanaged(Color),
    default_color: [:0]const u8,
    background_color: [:0]const u8,
    row_clues: Clues,
    column_clues: Clues,
    solutions: []const Solution,
    notes: []const [:0]const u8,

    fn parse(allocator: Allocator, reader: anytype) !Puzzle {
        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var description: ?[:0]const u8 = null;
        var colors = std.StringArrayHashMap(Color).init(allocator);
        const default_color = default_color: {
            const index = reader.attributeIndex("defaultcolor") orelse break :default_color "black";
            break :default_color try attributeValueAllocZ(allocator, reader, index);
        };
        const background_color = background_color: {
            const index = reader.attributeIndex("backgroundcolor") orelse break :background_color "white";
            break :background_color try attributeValueAllocZ(allocator, reader, index);
        };
        var row_clues: ?Clues = null;
        var column_clues: ?Clues = null;
        var solutions = std.ArrayList(Solution).init(allocator);
        var notes = std.ArrayList([:0]const u8).init(allocator);

        // Predefined colors
        try colors.put("black", Color.black);
        try colors.put("white", Color.white);

        while (true) {
            switch (try reader.read()) {
                .element_start => {
                    const child = reader.elementName();
                    if (mem.eql(u8, child, "source")) {
                        source = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "id")) {
                        id = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "title")) {
                        title = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "author")) {
                        author = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "authorid")) {
                        author_id = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "copyright")) {
                        copyright = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "description")) {
                        description = try readElementTextAllocZ(allocator, reader);
                    } else if (mem.eql(u8, child, "color")) {
                        const color = try Color.parse(allocator, reader);
                        try colors.put(color.name, color);
                    } else if (mem.eql(u8, child, "clues")) {
                        const clues = try Clues.parse(allocator, reader);
                        switch (clues.type) {
                            .rows => row_clues = clues,
                            .columns => column_clues = clues,
                        }
                    } else if (mem.eql(u8, child, "solution")) {
                        try solutions.append(try Solution.parse(allocator, reader));
                    } else if (mem.eql(u8, child, "note")) {
                        try notes.append(try readElementTextAllocZ(allocator, reader));
                    } else {
                        try reader.skipElement();
                    }
                },
                .element_end => break,
                else => {},
            }
        }

        if (row_clues == null or column_clues == null) {
            find_solution: {
                for (solutions.items) |solution| {
                    if (solution.type == .goal) {
                        const clues = try solution.image.toClues(allocator, colors.values(), background_color);
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
            .colors = colors.unmanaged,
            .default_color = default_color,
            .background_color = background_color,
            // row_clues and column_clues cannot be null here since we tried to
            // derive them above, already failing if that wasn't possible
            .row_clues = row_clues.?,
            .column_clues = column_clues.?,
            .solutions = try solutions.toOwnedSlice(),
            .notes = try notes.toOwnedSlice(),
        };
    }

    fn write(puzzle: Puzzle, writer: anytype) !void {
        try writer.elementStart("puzzle");
        try writer.attribute("defaultcolor", puzzle.default_color);
        try writer.attribute("backgroundcolor", puzzle.background_color);
        if (puzzle.source) |source| {
            try writeTextElement(writer, "source", source);
        }
        if (puzzle.id) |id| {
            try writeTextElement(writer, "id", id);
        }
        if (puzzle.title) |title| {
            try writeTextElement(writer, "title", title);
        }
        if (puzzle.author) |author| {
            try writeTextElement(writer, "author", author);
        }
        if (puzzle.author_id) |author_id| {
            try writeTextElement(writer, "authorid", author_id);
        }
        if (puzzle.copyright) |copyright| {
            try writeTextElement(writer, "copyright", copyright);
        }
        if (puzzle.description) |description| {
            try writeTextElement(writer, "description", description);
        }
        for (puzzle.colors.values()) |color| {
            try color.write(writer);
        }
        try puzzle.row_clues.write(writer);
        try puzzle.column_clues.write(writer);
        for (puzzle.solutions) |solution| {
            try solution.write(writer);
        }
        for (puzzle.notes) |note| {
            try writeTextElement(writer, "note", note);
        }
        try writer.elementEnd("puzzle");
    }
};

pub const Color = struct {
    name: [:0]const u8,
    char: ?u8,
    value: [:0]const u8,

    pub const black = Color{ .name = "black", .char = 'X', .value = "000" };
    pub const white = Color{ .name = "white", .char = '.', .value = "fff" };

    pub fn toRgb(color: Color) error{InvalidColor}!struct { r: u8, g: u8, b: u8 } {
        if (color.value.len == 3) {
            return .{
                .r = std.fmt.parseInt(u8, &.{ color.value[0], color.value[0] }, 16) catch return error.InvalidColor,
                .g = std.fmt.parseInt(u8, &.{ color.value[1], color.value[1] }, 16) catch return error.InvalidColor,
                .b = std.fmt.parseInt(u8, &.{ color.value[2], color.value[2] }, 16) catch return error.InvalidColor,
            };
        } else if (color.value.len == 6) {
            return .{
                .r = std.fmt.parseInt(u8, color.value[0..2], 16) catch return error.InvalidColor,
                .g = std.fmt.parseInt(u8, color.value[2..4], 16) catch return error.InvalidColor,
                .b = std.fmt.parseInt(u8, color.value[4..6], 16) catch return error.InvalidColor,
            };
        } else {
            return error.InvalidColor;
        }
    }

    pub fn toFloatRgb(color: Color) error{InvalidColor}!struct { r: f64, g: f64, b: f64 } {
        const rgb = try color.toRgb();
        return .{
            .r = @as(f64, @floatFromInt(rgb.r)) / 255,
            .g = @as(f64, @floatFromInt(rgb.g)) / 255,
            .b = @as(f64, @floatFromInt(rgb.b)) / 255,
        };
    }

    fn parse(allocator: Allocator, reader: anytype) !Color {
        const name = name: {
            const index = reader.attributeIndex("name") orelse return error.InvalidPbn;
            break :name try attributeValueAllocZ(allocator, reader, index);
        };
        const char = char: {
            const index = reader.attributeIndex("char") orelse break :char null;
            const value = try reader.attributeValue(index);
            if (value.len != 1) return error.InvalidPbn;
            break :char value[0];
        };

        const value = try readElementTextAllocZ(allocator, reader);

        return .{
            .name = name,
            .char = char,
            .value = value,
        };
    }

    fn write(color: Color, writer: anytype) !void {
        try writer.elementStart("color");
        try writer.attribute("name", color.name);
        if (color.char) |char| {
            try writer.attribute("char", &[_]u8{char});
        }
        try writer.text(color.value);
        try writer.elementEnd("color");
    }
};

pub const Clues = struct {
    type: Type,
    lines: []const Line,

    pub const Type = enum { columns, rows };

    fn parse(allocator: Allocator, reader: anytype) !Clues {
        const @"type" = type: {
            const index = reader.attributeIndex("type") orelse return error.InvalidPbn;
            break :type std.meta.stringToEnum(Type, try reader.attributeValue(index)) orelse return error.InvalidPbn;
        };
        var lines = std.ArrayList(Line).init(allocator);

        while (true) {
            switch (try reader.read()) {
                .element_start => {
                    const child = reader.elementName();
                    if (mem.eql(u8, child, "line")) {
                        try lines.append(try Line.parse(allocator, reader));
                    } else {
                        try reader.skipElement();
                    }
                },
                .element_end => break,
                else => {},
            }
        }

        return .{
            .type = @"type",
            .lines = try lines.toOwnedSlice(),
        };
    }

    fn write(clues: Clues, writer: anytype) !void {
        try writer.elementStart("clues");
        try writer.attribute("type", @tagName(clues.type));
        for (clues.lines) |line| {
            try line.write(writer);
        }
        try writer.elementEnd("clues");
    }
};

pub const Line = struct {
    counts: []const Count,

    fn parse(allocator: Allocator, reader: anytype) !Line {
        var counts = std.ArrayList(Count).init(allocator);

        while (true) {
            switch (try reader.read()) {
                .element_start => {
                    const child = reader.elementName();
                    if (mem.eql(u8, child, "count")) {
                        try counts.append(try Count.parse(allocator, reader));
                    } else {
                        try reader.skipElement();
                    }
                },
                .element_end => break,
                else => {},
            }
        }

        return .{
            .counts = try counts.toOwnedSlice(),
        };
    }

    fn write(line: Line, writer: anytype) !void {
        try writer.elementStart("line");
        for (line.counts) |count| {
            try count.write(writer);
        }
        try writer.elementEnd("line");
    }
};

pub const Count = struct {
    color: ?[:0]const u8,
    n: usize,

    fn parse(allocator: Allocator, reader: anytype) !Count {
        const color = color: {
            const index = reader.attributeIndex("color") orelse break :color null;
            break :color try attributeValueAllocZ(allocator, reader, index);
        };

        const n = std.fmt.parseInt(usize, try reader.readElementText(), 10) catch return error.InvalidPbn;

        return .{
            .color = color,
            .n = n,
        };
    }

    fn write(count: Count, writer: anytype) !void {
        try writer.elementStart("count");
        if (count.color) |color| {
            try writer.attribute("color", color);
        }
        var buf: [32]u8 = undefined;
        try writer.text(std.fmt.bufPrint(&buf, "{}", .{count.n}) catch unreachable);
        try writer.elementEnd("count");
    }
};

pub const Solution = struct {
    type: Type,
    image: Image,
    notes: []const [:0]const u8,

    pub const Type = enum { goal, solution, saved };

    fn parse(allocator: Allocator, reader: anytype) !Solution {
        const @"type" = type: {
            const index = reader.attributeIndex("type") orelse break :type .goal;
            break :type std.meta.stringToEnum(Type, try reader.attributeValue(index)) orelse return error.InvalidPbn;
        };
        var image: ?Image = null;
        var notes = std.ArrayList([:0]const u8).init(allocator);

        while (true) {
            switch (try reader.read()) {
                .element_start => {
                    const child = reader.elementName();
                    if (mem.eql(u8, child, "image")) {
                        image = try Image.parse(allocator, reader);
                    } else if (mem.eql(u8, child, "note")) {
                        try notes.append(try readElementTextAllocZ(allocator, reader));
                    } else {
                        try reader.skipElement();
                    }
                },
                .element_end => break,
                else => {},
            }
        }

        return .{
            .type = @"type",
            .image = image orelse return error.InvalidPbn,
            .notes = try notes.toOwnedSlice(),
        };
    }

    fn write(solution: Solution, writer: anytype) !void {
        try writer.elementStart("solution");
        try writer.attribute("type", @tagName(solution.type));
        try solution.image.write(writer);
        for (solution.notes) |note| {
            try writeTextElement(writer, "note", note);
        }
        try writer.elementEnd("solution");
    }
};

pub const Image = struct {
    rows: usize,
    columns: usize,
    chars: []const []const u8,

    pub fn deinit(image: Image, allocator: Allocator) void {
        for (image.chars) |options| {
            allocator.free(options);
        }
        allocator.free(image.chars);
    }

    pub fn fromText(allocator: Allocator, text: []const u8) Error!Image {
        var chars = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (chars.items) |options| {
                allocator.free(options);
            }
            chars.deinit();
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
                if (std.ascii.isWhitespace(row_chars[row_pos])) {
                    continue;
                } else if (row_chars[row_pos] == '[') {
                    const options_end = mem.indexOfScalarPos(u8, row_chars, row_pos + 1, ']') orelse return error.InvalidPbn;
                    try chars.append(try allocator.dupeZ(u8, row_chars[row_pos + 1 .. options_end]));
                    row_pos = options_end + 1;
                    row_columns += 1;
                } else {
                    try chars.append(try allocator.dupeZ(u8, &.{row_chars[row_pos]}));
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
            .chars = try chars.toOwnedSlice(),
        };
    }

    pub fn toClues(image: Image, allocator: Allocator, colors: []const Color, background_color: []const u8) Error!struct { rows: Clues, columns: Clues } {
        var color_names = std.AutoHashMap(u8, [:0]const u8).init(allocator);
        defer color_names.deinit();
        try color_names.ensureTotalCapacity(@intCast(colors.len));
        var bg_color_char: ?u8 = null;
        for (colors) |color| {
            if (color.char) |char| {
                color_names.putAssumeCapacity(char, color.name);
                if (mem.eql(u8, color.name, background_color)) {
                    bg_color_char = char;
                }
            }
        }

        var row_lines = try std.ArrayList(Line).initCapacity(allocator, image.rows);
        for (0..image.rows) |i| {
            var counts = std.ArrayList(Count).init(allocator);
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..image.columns) |j| {
                const options = image.chars[image.columns * i + j];
                if (options.len != 1) {
                    return error.InvalidPbn;
                }
                const color = options[0];
                if (color != run_color) {
                    if (run_len > 0 and run_color != bg_color_char) {
                        try counts.append(.{
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
                try counts.append(.{
                    .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                    .n = run_len,
                });
            }
            row_lines.appendAssumeCapacity(.{ .counts = try counts.toOwnedSlice() });
        }

        var column_lines = try std.ArrayList(Line).initCapacity(allocator, image.columns);
        for (0..image.columns) |j| {
            var counts = std.ArrayList(Count).init(allocator);
            var run_color: ?u8 = null;
            var run_len: usize = 0;
            for (0..image.rows) |i| {
                const options = image.chars[image.columns * i + j];
                if (options.len != 1) {
                    return error.InvalidPbn;
                }
                const color = options[0];
                if (color != run_color) {
                    if (run_len > 0 and run_color != bg_color_char) {
                        try counts.append(.{
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
                try counts.append(.{
                    .color = color_names.get(run_color.?) orelse return error.InvalidPbn,
                    .n = run_len,
                });
            }
            column_lines.appendAssumeCapacity(.{ .counts = try counts.toOwnedSlice() });
        }

        return .{
            .rows = .{ .type = .rows, .lines = try row_lines.toOwnedSlice() },
            .columns = .{ .type = .columns, .lines = try column_lines.toOwnedSlice() },
        };
    }

    fn parse(allocator: Allocator, reader: anytype) !Image {
        return try fromText(allocator, try reader.readElementText());
    }

    fn write(image: Image, writer: anytype) !void {
        try writer.elementStart("image");
        try writer.text("\n");
        var row_iter = mem.window([]const u8, image.chars, image.columns, image.columns);
        while (row_iter.next()) |row| {
            try writer.text("|");
            for (row) |options| {
                if (options.len == 1) {
                    try writer.text(&[_]u8{options[0]});
                } else {
                    try writer.text("[");
                    try writer.text(options);
                    try writer.text("]");
                }
            }
            try writer.text("|\n");
        }
        try writer.elementEnd("image");
    }
};

fn writeTextElement(writer: anytype, name: []const u8, value: []const u8) !void {
    try writer.elementStart(name);
    try writer.text(value);
    try writer.elementEnd(name);
}

fn attributeValueAllocZ(allocator: Allocator, reader: anytype, index: usize) ![:0]u8 {
    var value = std.ArrayList(u8).init(allocator);
    defer value.deinit();
    try reader.attributeValueWrite(index, value.writer());
    return try value.toOwnedSliceSentinel(0);
}

fn readElementTextAllocZ(allocator: Allocator, reader: anytype) ![:0]u8 {
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    try reader.readElementTextWrite(text.writer());
    return try text.toOwnedSliceSentinel(0);
}
