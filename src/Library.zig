entries: []const Entry,
arena: ArenaAllocator,

const std = @import("std");
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const c_allocator = std.heap.c_allocator;
const glib = @import("glib");
const default_puzzles = @import("puzzles").default_puzzles;
const application_id = @import("main.zig").application_id;
const pbn = @import("pbn.zig");
const oom = @import("util.zig").oom;

const Library = @This();

pub const Entry = struct {
    path: [:0]const u8,
    title: ?[:0]const u8,
};

pub fn deinit(library: *Library) void {
    library.arena.deinit();
}

pub fn load() !Library {
    const library_path = libraryPathAlloc();
    defer c_allocator.free(library_path);
    var library_dir = try fs.cwd().makeOpenPath(library_path, .{ .iterate = true });
    defer library_dir.close();

    var arena = ArenaAllocator.init(c_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var entries = ArrayListUnmanaged(Entry){};
    var library_dir_iter = library_dir.iterate();
    while (try library_dir_iter.next()) |child| {
        if (child.kind != .file or !mem.endsWith(u8, child.name, ".pbn")) {
            continue;
        }

        const child_file = library_dir.openFile(child.name, .{}) catch continue;
        defer child_file.close();
        var child_buf_reader = io.bufferedReader(child_file.reader());
        var puzzle_set = pbn.PuzzleSet.parseReader(allocator, child_buf_reader.reader()) catch continue;
        defer puzzle_set.deinit();
        try entries.append(allocator, .{
            .path = fs.path.joinZ(allocator, &.{ library_path, child.name }) catch oom(),
            .title = if (puzzle_set.title) |title| allocator.dupeZ(u8, title) catch oom() else null,
        });
    }

    return .{ .entries = entries.toOwnedSlice(allocator) catch oom(), .arena = arena };
}

pub fn copyDefaultPuzzles() !void {
    const library_path = libraryPathAlloc();
    defer c_allocator.free(library_path);
    var library_dir = try fs.cwd().makeOpenPath(library_path, .{});
    defer library_dir.close();

    for (default_puzzles) |default_puzzle| {
        try library_dir.writeFile(default_puzzle.name, default_puzzle.data);
    }
}

fn libraryPathAlloc() []u8 {
    return fs.path.join(c_allocator, &.{ mem.span(glib.getUserDataDir()), application_id }) catch oom();
}
