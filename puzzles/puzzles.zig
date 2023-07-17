pub const DefaultPuzzle = struct {
    name: []const u8,
    data: []const u8,
};

pub const default_puzzles: []const DefaultPuzzle = &.{
    .{ .name = "easy.pbn", .data = @embedFile("easy.pbn") },
};
