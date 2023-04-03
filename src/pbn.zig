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
const ArrayList = std.ArrayList;
const EnumArray = std.EnumArray;
const StringArrayHashMap = std.StringArrayHashMap;

pub const Error = error{InvalidPbn} || Allocator.Error;

pub const PuzzleSet = struct {
    puzzles: []const Puzzle,
    source: ?[]const u8,
    id: ?[]const u8,
    title: ?[]const u8,
    author: ?[]const u8,
    author_id: ?[]const u8,
    copyright: ?[]const u8,
    description: ?[]const u8,
    arena: ArenaAllocator,

    pub fn parseFile(allocator: Allocator, file: [:0]const u8) Error!PuzzleSet {
        const doc = xml.parseFile(file) catch return error.InvalidPbn;
        defer c.xmlFreeDoc(doc);
        return try parseDoc(allocator, doc);
    }

    pub fn deinit(self: *PuzzleSet) void {
        self.arena.deinit();
    }

    fn parseDoc(a: Allocator, doc: *c.xmlDoc) !PuzzleSet {
        var arena = ArenaAllocator.init(a);
        const allocator = arena.allocator();
        const node: *c.xmlNode = c.xmlDocGetRootElement(doc) orelse return error.InvalidPbn;

        var source: ?[]const u8 = null;
        var id: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var author_id: ?[]const u8 = null;
        var copyright: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var puzzles = ArrayList(Puzzle).init(allocator);

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "source")) {
                source = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "id")) {
                id = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "title")) {
                title = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "author")) {
                author = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "authorid")) {
                author_id = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "copyright")) {
                copyright = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "description")) {
                description = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "puzzle")) {
                try puzzles.append(try Puzzle.parse(allocator, doc, child));
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
            .puzzles = puzzles.items,
            .arena = arena,
        };
    }
};

pub const Puzzle = struct {
    source: ?[]const u8,
    id: ?[]const u8,
    title: ?[]const u8,
    author: ?[]const u8,
    author_id: ?[]const u8,
    copyright: ?[]const u8,
    description: ?[]const u8,
    colors: StringArrayHashMap(Color),
    default_color: []const u8,
    background_color: []const u8,
    clues: EnumArray(Clues.Type, ?Clues),
    solutions: []const Solution,

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Puzzle {
        var source: ?[]const u8 = null;
        var id: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var author_id: ?[]const u8 = null;
        var copyright: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var colors = StringArrayHashMap(Color).init(allocator);
        var default_color: ?[]const u8 = null;
        var background_color: ?[]const u8 = null;
        var clues = EnumArray(Clues.Type, ?Clues).initFill(null);
        var solutions = ArrayList(Solution).init(allocator);

        // Predefined colors
        try colors.put("black", Color.black);
        try colors.put("white", Color.white);

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "defaultcolor")) {
                default_color = try xml.attrContent(allocator, doc, attr);
            } else if (xml.attrIs(attr, null, "backgroundcolor")) {
                background_color = try xml.attrContent(allocator, doc, attr);
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "source")) {
                source = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "id")) {
                id = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "title")) {
                title = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "author")) {
                author = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "authorid")) {
                author_id = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "copyright")) {
                copyright = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "description")) {
                description = try xml.nodeContent(allocator, doc, child.children);
            } else if (xml.nodeIs(child, null, "color")) {
                const color = try Color.parse(allocator, doc, child);
                try colors.put(color.name, color);
            } else if (xml.nodeIs(child, null, "clues")) {
                const parsed_clues = try Clues.parse(allocator, doc, child);
                clues.set(parsed_clues.type, parsed_clues);
            } else if (xml.nodeIs(child, null, "solution")) {
                try solutions.append(try Solution.parse(allocator, doc, child));
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
            .clues = clues,
            .solutions = solutions.items,
        };
    }
};

pub const Color = struct {
    name: []const u8,
    char: ?u8,
    value: []const u8,

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

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Color {
        var name: ?[]const u8 = null;
        var char: ?u8 = null;
        const value: ?[]const u8 = try xml.nodeContent(allocator, doc, node.children);

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "name")) {
                name = try xml.attrContent(allocator, doc, attr);
            } else if (xml.attrIs(attr, null, "char")) {
                const content = try xml.attrContent(allocator, doc, attr);
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
};

pub const Clues = struct {
    type: Type,
    lines: []const Line,

    pub const Type = enum { columns, rows };

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Clues {
        var @"type": ?Type = null;
        var lines = ArrayList(Line).init(allocator);

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "type")) {
                const content = try xml.attrContent(allocator, doc, attr);
                defer allocator.free(content);
                @"type" = meta.stringToEnum(Type, content) orelse return error.InvalidPbn;
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "line")) {
                try lines.append(try Line.parse(allocator, doc, child));
            }
        }

        return .{
            .type = @"type" orelse return error.InvalidPbn,
            .lines = lines.items,
        };
    }
};

pub const Line = struct {
    counts: []const Count,

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Line {
        var counts = ArrayList(Count).init(allocator);

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "count")) {
                try counts.append(try Count.parse(allocator, doc, child));
            }
        }

        return .{
            .counts = counts.items,
        };
    }
};

pub const Count = struct {
    color: ?[]const u8,
    n: usize,

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Count {
        var color: ?[]const u8 = null;
        const n = blk: {
            const content = try xml.nodeContent(allocator, doc, node.children);
            defer allocator.free(content);
            break :blk fmt.parseInt(usize, content, 10) catch return error.InvalidPbn;
        };

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "color")) {
                color = try xml.attrContent(allocator, doc, attr);
            }
        }

        return .{
            .color = color,
            .n = n,
        };
    }
};

pub const Solution = struct {
    type: Type,
    image: Image,

    pub const Type = enum { goal, solution, saved };

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Solution {
        var @"type": ?Type = null;
        var image: ?Image = null;

        var maybe_attr: ?*c.xmlAttr = node.properties;
        while (maybe_attr) |attr| : (maybe_attr = attr.next) {
            if (xml.attrIs(attr, null, "type")) {
                const content = try xml.attrContent(allocator, doc, attr);
                defer allocator.free(content);
                @"type" = meta.stringToEnum(Type, content) orelse return error.InvalidPbn;
            }
        }

        var maybe_child: ?*c.xmlNode = node.children;
        while (maybe_child) |child| : (maybe_child = child.next) {
            if (xml.nodeIs(child, null, "image")) {
                image = try Image.parse(allocator, doc, node);
            }
        }

        return .{
            .type = @"type" orelse return error.InvalidPbn,
            .image = image orelse return error.InvalidPbn,
        };
    }
};

pub const Image = struct {
    text: []const u8,

    fn parse(allocator: Allocator, doc: *c.xmlDoc, node: *const c.xmlNode) !Image {
        return .{ .text = try xml.nodeContent(allocator, doc, node.children) };
    }
};
