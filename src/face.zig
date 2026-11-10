//! Faces: named text styles, as Emacs faces.
//!
//! The editor draws all text with faces: the region, search matches, the
//! mode line, syntax colors, and highlight ranges from Lua. Lua can change
//! a built-in face or add new faces with `editor.face`.

const std = @import("std");
const testing = std.testing;

pub const FaceId = u16;

/// A terminal color: -1 is the terminal's own color, 0-7 are the ANSI
/// colors, 8-15 are the bright ANSI colors, and 16-255 are the other colors
/// of a 256-color terminal.
pub const Color = i16;

pub const default_color: Color = -1;

pub const Style = struct {
    fg: Color = default_color,
    bg: Color = default_color,
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

/// The faces that the editor itself uses. They have fixed IDs in this order.
pub const Builtin = enum(FaceId) {
    default,
    region,
    isearch,
    lazy_highlight,
    mode_line,
    mode_line_inactive,
    border,
    // Syntax faces. Their names are the same as the `syntax.Face` names.
    keyword,
    string,
    comment,
    function,
    type,
    constant,
    attribute,

    pub fn id(self: Builtin) FaceId {
        return @backingInt(self);
    }
};

const builtin_styles = std.enums.EnumArray(Builtin, Style).init(.{
    .default = .{},
    .region = .{ .fg = 0, .bg = 3 }, // black on yellow
    .isearch = .{ .fg = 7, .bg = 5 }, // white on magenta
    .lazy_highlight = .{ .fg = 0, .bg = 6 }, // black on cyan
    .mode_line = .{ .reverse = true, .bold = true },
    .mode_line_inactive = .{ .reverse = true },
    .border = .{ .fg = 8 },
    .keyword = .{ .fg = 5 },
    .string = .{ .fg = 2 },
    .comment = .{ .fg = 8 },
    .function = .{ .fg = 4 },
    .type = .{ .fg = 6 },
    .constant = .{ .fg = 1 },
    .attribute = .{ .fg = 3 },
});

const color_names = [_]struct { []const u8, Color }{
    .{ "default", -1 },
    .{ "black", 0 },
    .{ "red", 1 },
    .{ "green", 2 },
    .{ "yellow", 3 },
    .{ "blue", 4 },
    .{ "magenta", 5 },
    .{ "cyan", 6 },
    .{ "white", 7 },
    .{ "bright_black", 8 },
    .{ "bright_red", 9 },
    .{ "bright_green", 10 },
    .{ "bright_yellow", 11 },
    .{ "bright_blue", 12 },
    .{ "bright_magenta", 13 },
    .{ "bright_cyan", 14 },
    .{ "bright_white", 15 },
    .{ "gray", 8 },
    .{ "grey", 8 },
};

/// A color by name ("red", "bright_blue", "default") or by number ("208").
pub fn parseColor(text: []const u8) ?Color {
    for (color_names) |entry| if (std.mem.eql(u8, entry[0], text)) return entry[1];
    const n = std.fmt.parseInt(u8, text, 10) catch return null;
    return n;
}

pub const Faces = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayList([]u8) = .empty,
    styles: std.ArrayList(Style) = .empty,
    /// Changes on each change of a style, so the editor knows when its
    /// cached terminal attributes are old.
    version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) !Faces {
        var self: Faces = .{ .gpa = gpa };
        errdefer self.deinit();
        for (std.enums.values(Builtin)) |b| {
            const id = try self.define(@tagName(b), builtin_styles.get(b));
            std.debug.assert(id == b.id());
        }
        return self;
    }

    pub fn deinit(self: *Faces) void {
        for (self.names.items) |n| self.gpa.free(n);
        self.names.deinit(self.gpa);
        self.styles.deinit(self.gpa);
        self.* = undefined;
    }

    /// Sets the style of a face, and makes the face if it does not exist.
    pub fn define(self: *Faces, name: []const u8, style: Style) !FaceId {
        self.version +%= 1;
        if (self.lookup(name)) |id| {
            self.styles.items[id] = style;
            return id;
        }
        if (self.names.items.len > std.math.maxInt(FaceId)) return error.TooManyFaces;
        const copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(copy);
        try self.names.append(self.gpa, copy);
        errdefer _ = self.names.pop();
        try self.styles.append(self.gpa, style);
        return @intCast(self.names.items.len - 1);
    }

    pub fn lookup(self: *const Faces, name: []const u8) ?FaceId {
        for (self.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        return null;
    }

    pub fn get(self: *const Faces, id: FaceId) Style {
        return if (id < self.styles.items.len) self.styles.items[id] else .{};
    }

    pub fn count(self: *const Faces) usize {
        return self.names.items.len;
    }
};

test "built-in faces have fixed IDs, and define replaces a style" {
    var faces = try Faces.init(testing.allocator);
    defer faces.deinit();
    try testing.expectEqual(Builtin.region.id(), faces.lookup("region").?);
    try testing.expectEqual(@as(Color, 3), faces.get(Builtin.region.id()).bg);

    const v = faces.version;
    _ = try faces.define("region", .{ .bg = 4 });
    try testing.expectEqual(@as(Color, 4), faces.get(Builtin.region.id()).bg);
    try testing.expect(faces.version != v);

    const warning = try faces.define("warning", .{ .fg = 3, .bold = true });
    try testing.expectEqual(warning, faces.lookup("warning").?);
    try testing.expect(faces.get(warning).bold);
    try testing.expectEqual(null, faces.lookup("nope"));
}

test "parseColor reads names and numbers" {
    try testing.expectEqual(@as(?Color, 1), parseColor("red"));
    try testing.expectEqual(@as(?Color, 12), parseColor("bright_blue"));
    try testing.expectEqual(@as(?Color, -1), parseColor("default"));
    try testing.expectEqual(@as(?Color, 208), parseColor("208"));
    try testing.expectEqual(null, parseColor("orange"));
    try testing.expectEqual(null, parseColor("300"));
}
