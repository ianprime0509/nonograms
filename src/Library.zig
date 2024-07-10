entries: []const Entry,
arena: ArenaAllocator,

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glib = @import("glib");
const default_puzzles = @import("puzzles").default_puzzles;
const application_id = @import("main.zig").application_id;
const pbn = @import("pbn.zig");

const Library = @This();

pub const Entry = struct {
    path: [:0]const u8,
    title: ?[:0]const u8,
};

pub fn deinit(library: *Library) void {
    library.arena.deinit();
}

pub fn load(parent_allocator: Allocator) !Library {
    const library_path = try libraryPathAlloc(parent_allocator);
    defer parent_allocator.free(library_path);
    var library_dir = try std.fs.cwd().makeOpenPath(library_path, .{ .iterate = true });
    defer library_dir.close();

    var arena = ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var entries = std.ArrayList(Entry).init(allocator);
    var library_dir_iter = library_dir.iterate();
    while (try library_dir_iter.next()) |child| {
        if (child.kind != .file or !mem.endsWith(u8, child.name, ".pbn")) {
            continue;
        }

        const child_file = library_dir.openFile(child.name, .{}) catch continue;
        defer child_file.close();
        var child_buf_reader = std.io.bufferedReader(child_file.reader());
        var puzzle_set = pbn.PuzzleSet.parseReader(allocator, child_buf_reader.reader()) catch continue;
        defer puzzle_set.deinit();
        try entries.append(.{
            .path = try std.fs.path.joinZ(allocator, &.{ library_path, child.name }),
            .title = if (puzzle_set.title) |title| try allocator.dupeZ(u8, title) else null,
        });
    }

    return .{ .entries = try entries.toOwnedSlice(), .arena = arena };
}

pub fn copyDefaultPuzzles(allocator: Allocator) !void {
    const library_path = try libraryPathAlloc(allocator);
    defer allocator.free(library_path);
    var library_dir = try std.fs.cwd().makeOpenPath(library_path, .{});
    defer library_dir.close();

    for (default_puzzles) |default_puzzle| {
        try library_dir.writeFile(.{ .sub_path = default_puzzle.name, .data = default_puzzle.data });
    }
}

fn libraryPathAlloc(allocator: Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ mem.span(glib.getUserDataDir()), application_id });
}
