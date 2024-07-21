// Types and a parser for the format described in https://webpbn.com/pbn_fmt.html
// The triddler puzzle type is not supported.

const std = @import("std");
const xml = @import("xml");
const libxml2 = @import("libxml2");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Error = error{InvalidPbn} || Allocator.Error;

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
        var stream = std.io.fixedBufferStream(bytes);
        return try parseReader(allocator, stream.reader());
    }

    pub fn parseReader(allocator: Allocator, data_reader: anytype) (Error || @TypeOf(data_reader).Error)!PuzzleSet {
        var reader = xml.reader(allocator, data_reader, .{
            .DecoderType = xml.encoding.Utf8Decoder,
            // Normalization doesn't matter for anything we're doing
            .enable_normalization = false,
            // The PBN format does not use namespaces
            .namespace_aware = false,
        });
        defer reader.deinit();
        return parseXml(allocator, &reader) catch |err| switch (err) {
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

    pub fn writeFile(set: PuzzleSet, path: [:0]const u8) error{XmlError}!void {
        const writer = try libxml2.Writer.newForPath(path);
        defer writer.free();
        try set.writeDoc(writer);
    }

    pub fn deinit(set: *PuzzleSet) void {
        set.arena.deinit();
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
                    try puzzles.append(try Puzzle.parse(allocator, child, children.children()));
                } else if (child.name.is(null, "note")) {
                    try notes.append(try textContent(allocator, children.children()));
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
            .puzzles = try puzzles.toOwnedSlice(),
            .notes = try notes.toOwnedSlice(),
            .arena = arena,
        };
    }

    fn writeDoc(set: PuzzleSet, writer: *libxml2.Writer) !void {
        try writer.setIndent(2);
        try writer.startDocument(null, "UTF-8", null);
        try writer.startElement("puzzleset");
        if (set.source) |source| {
            try writer.writeElement("source", source);
        }
        if (set.id) |id| {
            try writer.writeElement("id", id);
        }
        if (set.title) |title| {
            try writer.writeElement("title", title);
        }
        if (set.author) |author| {
            try writer.writeElement("author", author);
        }
        if (set.author_id) |author_id| {
            try writer.writeElement("authorid", author_id);
        }
        if (set.copyright) |copyright| {
            try writer.writeElement("copyright", copyright);
        }
        for (set.puzzles) |puzzle| {
            try puzzle.write(writer);
        }
        for (set.notes) |note| {
            try writer.writeElement("note", note);
        }
        try writer.endElement();
        try writer.endDocument();
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

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Puzzle {
        var source: ?[:0]const u8 = null;
        var id: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var author: ?[:0]const u8 = null;
        var author_id: ?[:0]const u8 = null;
        var copyright: ?[:0]const u8 = null;
        var description: ?[:0]const u8 = null;
        var colors = std.StringArrayHashMap(Color).init(allocator);
        var default_color: ?[:0]const u8 = null;
        var background_color: ?[:0]const u8 = null;
        var row_clues: ?Clues = null;
        var column_clues: ?Clues = null;
        var solutions = std.ArrayList(Solution).init(allocator);
        var notes = std.ArrayList([:0]const u8).init(allocator);

        // Predefined colors
        try colors.put("black", Color.black);
        try colors.put("white", Color.white);

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
                    try colors.put(color.name, color);
                } else if (child.name.is(null, "clues")) {
                    const clues = try Clues.parse(allocator, child, children.children());
                    switch (clues.type) {
                        .rows => row_clues = clues,
                        .columns => column_clues = clues,
                    }
                } else if (child.name.is(null, "solution")) {
                    try solutions.append(try Solution.parse(allocator, child, children.children()));
                } else if (child.name.is(null, "note")) {
                    try notes.append(try textContent(allocator, children.children()));
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
            .colors = colors.unmanaged,
            .default_color = default_color orelse "black",
            .background_color = background_color orelse "white",
            // row_clues and column_clues cannot be null here since we tried to
            // derive them above, already failing if that wasn't possible
            .row_clues = row_clues.?,
            .column_clues = column_clues.?,
            .solutions = try solutions.toOwnedSlice(),
            .notes = try notes.toOwnedSlice(),
        };
    }

    fn write(puzzle: Puzzle, writer: *libxml2.Writer) !void {
        try writer.startElement("puzzle");
        try writer.writeAttribute("defaultcolor", puzzle.default_color);
        try writer.writeAttribute("backgroundcolor", puzzle.background_color);
        if (puzzle.source) |source| {
            try writer.writeElement("source", source);
        }
        if (puzzle.id) |id| {
            try writer.writeElement("id", id);
        }
        if (puzzle.title) |title| {
            try writer.writeElement("title", title);
        }
        if (puzzle.author) |author| {
            try writer.writeElement("author", author);
        }
        if (puzzle.author_id) |author_id| {
            try writer.writeElement("authorid", author_id);
        }
        if (puzzle.copyright) |copyright| {
            try writer.writeElement("copyright", copyright);
        }
        if (puzzle.description) |description| {
            try writer.writeElement("description", description);
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
            try writer.writeElement("note", note);
        }
        try writer.endElement();
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

    fn write(color: Color, writer: *libxml2.Writer) !void {
        try writer.startElement("color");
        try writer.writeAttribute("name", color.name);
        if (color.char) |char| {
            try writer.writeAttribute("char", &[_]u8{char} ++ "");
        }
        try writer.write(color.value);
        try writer.endElement();
    }
};

pub const Clues = struct {
    type: Type,
    lines: []const Line,

    pub const Type = enum { columns, rows };

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Clues {
        var @"type": ?Type = null;
        var lines = std.ArrayList(Line).init(allocator);

        for (start.attributes) |attr| {
            if (attr.name.is(null, "type")) {
                @"type" = std.meta.stringToEnum(Type, attr.value) orelse return error.InvalidPbn;
            }
        }

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "line")) {
                    try lines.append(try Line.parse(allocator, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .type = @"type" orelse return error.InvalidPbn,
            .lines = try lines.toOwnedSlice(),
        };
    }

    fn write(clues: Clues, writer: *libxml2.Writer) !void {
        try writer.startElement("clues");
        try writer.writeAttribute("type", @tagName(clues.type));
        for (clues.lines) |line| {
            try line.write(writer);
        }
        try writer.endElement();
    }
};

pub const Line = struct {
    counts: []const Count,

    fn parse(allocator: Allocator, children: anytype) !Line {
        var counts = std.ArrayList(Count).init(allocator);

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "count")) {
                    try counts.append(try Count.parse(allocator, child, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .counts = try counts.toOwnedSlice(),
        };
    }

    fn write(line: Line, writer: anytype) !void {
        try writer.startElement("line");
        for (line.counts) |count| {
            try count.write(writer);
        }
        try writer.endElement();
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
            break :blk std.fmt.parseInt(usize, content, 10) catch return error.InvalidPbn;
        };

        return .{
            .color = color,
            .n = n,
        };
    }

    fn write(count: Count, writer: *libxml2.Writer) !void {
        try writer.startElement("count");
        if (count.color) |color| {
            try writer.writeAttribute("color", color);
        }
        var buf: [32]u8 = undefined;
        try writer.write(std.fmt.bufPrintZ(&buf, "{}", .{count.n}) catch unreachable);
        try writer.endElement();
    }
};

pub const Solution = struct {
    type: Type,
    image: Image,
    notes: []const [:0]const u8,

    pub const Type = enum { goal, solution, saved };

    fn parse(allocator: Allocator, start: xml.Event.ElementStart, children: anytype) !Solution {
        var @"type": ?Type = null;
        var image: ?Image = null;
        var notes = std.ArrayList([:0]const u8).init(allocator);

        for (start.attributes) |attr| {
            if (attr.name.is(null, "type")) {
                @"type" = std.meta.stringToEnum(Type, attr.value) orelse return error.InvalidPbn;
            }
        }

        while (try children.next()) |event| {
            switch (event) {
                .element_start => |child| if (child.name.is(null, "image")) {
                    image = try Image.parse(allocator, children.children());
                } else if (child.name.is(null, "note")) {
                    try notes.append(try textContent(allocator, children.children()));
                } else {
                    try children.children().skip();
                },
                else => {},
            }
        }

        return .{
            .type = @"type" orelse .goal,
            .image = image orelse return error.InvalidPbn,
            .notes = try notes.toOwnedSlice(),
        };
    }

    fn write(solution: Solution, writer: *libxml2.Writer) !void {
        try writer.startElement("solution");
        try writer.writeAttribute("type", @tagName(solution.type));
        try solution.image.write(writer);
        for (solution.notes) |note| {
            try writer.writeElement("note", note);
        }
        try writer.endElement();
    }
};

pub const Image = struct {
    rows: usize,
    columns: usize,
    chars: []const [:0]const u8,

    pub fn deinit(image: Image, allocator: Allocator) void {
        for (image.chars) |options| {
            allocator.free(options);
        }
        allocator.free(image.chars);
    }

    pub fn fromText(allocator: Allocator, text: []const u8) Error!Image {
        var chars = std.ArrayList([:0]const u8).init(allocator);
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

    fn parse(allocator: Allocator, children: anytype) !Image {
        const text = try textContent(allocator, children);
        defer allocator.free(text);
        return try fromText(allocator, text);
    }

    fn write(image: Image, writer: *libxml2.Writer) !void {
        try writer.startElement("image");
        try writer.write("\n");
        var row_iter = mem.window([:0]const u8, image.chars, image.columns, image.columns);
        while (row_iter.next()) |row| {
            try writer.write("|");
            for (row) |options| {
                if (options.len == 1) {
                    try writer.write(&[_]u8{options[0]} ++ "");
                } else {
                    try writer.write("[");
                    try writer.write(options);
                    try writer.write("]");
                }
            }
            try writer.write("|\n");
        }
        try writer.endElement();
    }
};

fn textContent(allocator: Allocator, children: anytype) ![:0]u8 {
    var text = std.ArrayList(u8).init(allocator);
    while (try children.next()) |event| {
        switch (event) {
            .element_content => |e| try text.appendSlice(e.content),
            else => {},
        }
    }
    return try text.toOwnedSliceSentinel(0);
}
