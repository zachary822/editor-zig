//! Editor options. The editor has global values, and each buffer can
//! override them. Lua sets them with `editor.options.<name> = value` and
//! `buf:set_option(name, value)`.

const std = @import("std");
const testing = std.testing;

pub const Options = struct {
    /// The number of spaces in one indent level, for TAB and plugins.
    indent_width: u8 = 4,
    /// True: TAB inserts a tab character, not spaces.
    indent_tabs: bool = false,
    /// The display width of a tab character.
    tab_width: u8 = 8,
};

/// The options that one buffer overrides. Null uses the global value.
pub const Overrides = struct {
    indent_width: ?u8 = null,
    indent_tabs: ?bool = null,
    tab_width: ?u8 = null,
};

pub const Name = std.meta.FieldEnum(Options);

/// The largest width for `indent_width` and `tab_width`.
pub const max_width = 16;

const spaces: [max_width]u8 = @splat(' ');

/// The text of one indent level: a tab, or `indent_width` spaces.
pub fn indentUnit(o: Options) []const u8 {
    return if (o.indent_tabs) "\t" else spaces[0..o.indent_width];
}

/// `n` spaces, for `n` from 0 to `max_width`.
pub fn spacesOf(n: usize) []const u8 {
    return spaces[0..n];
}

/// The global values with the overrides of one buffer.
pub fn resolve(global: Options, overrides: Overrides) Options {
    var out = global;
    inline for (comptime std.meta.fieldNames(Options)) |name| {
        if (@field(overrides, name)) |v| @field(out, name) = v;
    }
    return out;
}

comptime {
    // Each option must have an override with the same name and type.
    for (std.meta.fieldNames(Options)) |name| {
        const T = @FieldType(Options, name);
        if (@FieldType(Overrides, name) != ?T) @compileError("Overrides." ++ name ++ " must be ?" ++ @typeName(T));
    }
}

test "overrides win over the global values" {
    const global: Options = .{ .indent_width = 4, .tab_width = 8 };
    const got = resolve(global, .{ .indent_width = 2, .indent_tabs = true });
    try testing.expectEqual(Options{ .indent_width = 2, .indent_tabs = true, .tab_width = 8 }, got);
    try testing.expectEqual(global, resolve(global, .{}));
}

test "indentUnit is a tab or indent_width spaces" {
    try testing.expectEqualStrings("   ", indentUnit(.{ .indent_width = 3 }));
    try testing.expectEqualStrings("\t", indentUnit(.{ .indent_width = 3, .indent_tabs = true }));
}
