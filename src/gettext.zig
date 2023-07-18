const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const c_allocator = std.heap.c_allocator;
const oom = @import("util.zig").oom;

const c = @cImport(@cInclude("libintl.h"));

const package = "nonograms";

pub fn init() !void {
    // TODO: figure out what path to use here (or rewrite gettext in Zig and avoid all this complexity???)
    const cwd = try fs.cwd().realpathAlloc(c_allocator, ".");
    defer c_allocator.free(cwd);
    const locale_path = try fs.path.joinZ(c_allocator, &.{ cwd, "locale" });
    defer c_allocator.free(locale_path);
    _ = c.bindtextdomain(package, locale_path);
    _ = c.bind_textdomain_codeset(package, "UTF-8");
    _ = c.textdomain(package);
}

pub fn gettext(msgid: [:0]const u8) [:0]const u8 {
    return mem.span(c.gettext(msgid));
}
