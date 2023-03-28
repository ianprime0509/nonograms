const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const adw = @import("adw");
const view = @import("view.zig");
const View = view.View;

pub fn main() !void {
    _ = Application.getType();
    _ = ApplicationWindow.getType();
    _ = View.getType();
    const status = Application.new().run(@intCast(c_int, std.os.argv.len), std.os.argv.ptr);
    std.os.exit(@intCast(u8, status));
}

const Application = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.Application;
    const Self = @This();

    pub const getType = gobject.registerType(Self, .{
        .name = "NonogramsApplication",
    });

    pub fn new() *Self {
        return Self.newWith(.{
            .application_id = "dev.ianjohnson.Nonograms",
            .flags = gio.ApplicationFlags{},
        });
    }

    fn activateImpl(self: *Self) callconv(.C) void {
        const win = ApplicationWindow.new(self);
        win.present();
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.implementActivate(&Self.activateImpl);
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Self);
    };
};

const ApplicationWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = adw.ApplicationWindow;
    const Self = @This();

    const template = @embedFile("ui/window.ui");

    pub const getType = gobject.registerType(ApplicationWindow, .{
        .name = "NonogramsApplicationWindow",
    });

    pub fn new(app: *Application) *Self {
        return Self.newWith(.{ .application = app });
    }

    pub fn init(self: *Self, _: *Class) callconv(.C) void {
        self.initTemplate();
    }

    pub usingnamespace Parent.Methods(Self);

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.C) void {
            class.setTemplate(glib.Bytes.newFromSlice(template));
        }

        pub usingnamespace Parent.Class.Methods(Class);
        pub usingnamespace Parent.Class.VirtualMethods(Class, Self);
    };
};
