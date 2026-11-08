//! File name completion for the minibuffer.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const files = @import("files.zig");

pub const Completion = struct {
    gpa: std.mem.Allocator,
    /// The completed input: the directory part of the input and the longest
    /// common prefix of the matches. With no matches, it is the input.
    text: []u8,
    /// The names in the directory that match, sorted. Directory names end
    /// with "/".
    matches: [][]u8,

    pub fn deinit(self: *Completion) void {
        for (self.matches) |m| self.gpa.free(m);
        self.gpa.free(self.matches);
        self.gpa.free(self.text);
        self.* = undefined;
    }
};

/// Completes the last part of a file name, as Emacs does for "Find file:".
/// The directory part (up to the last "/") selects the directory, relative
/// to `root` if it is not absolute. "~" in it means `home`. Names that start
/// with "." match only if the typed part also starts with ".".
pub fn completeFileName(io: Io, root: Io.Dir, gpa: std.mem.Allocator, input: []const u8, home: ?[]const u8) !Completion {
    const slash = std.mem.lastIndexOfScalar(u8, input, '/');
    const dir_part = if (slash) |s| input[0 .. s + 1] else "";
    const prefix = if (slash) |s| input[s + 1 ..] else input;

    var matches: std.ArrayList([]u8) = .empty;
    errdefer {
        for (matches.items) |m| gpa.free(m);
        matches.deinit(gpa);
    }

    const open_path = try files.expandPath(gpa, if (dir_part.len == 0) "." else dir_part, home);
    defer gpa.free(open_path);
    if (root.openDir(io, open_path, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (entry.name[0] == '.' and !std.mem.startsWith(u8, prefix, ".")) continue;
            const is_dir = switch (entry.kind) {
                .directory => true,
                // Follow a symbolic link to see if it is a directory.
                .sym_link => if (dir.statFile(io, entry.name, .{})) |st| st.kind == .directory else |_| false,
                else => false,
            };
            const name = try std.mem.concat(gpa, u8, &.{ entry.name, if (is_dir) "/" else "" });
            errdefer gpa.free(name);
            try matches.append(gpa, name);
        }
    } else |_| {} // No such directory: no matches.

    std.mem.sort([]u8, matches.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const common = if (matches.items.len == 0) prefix else commonPrefix(matches.items);
    const text = try std.mem.concat(gpa, u8, &.{ dir_part, common });
    errdefer gpa.free(text);
    return .{ .gpa = gpa, .text = text, .matches = try matches.toOwnedSlice(gpa) };
}

/// The longest prefix that all names share, cut at a codepoint boundary.
fn commonPrefix(names: []const []const u8) []const u8 {
    var n = names[0].len;
    for (names[1..]) |name| {
        n = @min(n, std.mem.indexOfDiff(u8, names[0][0..n], name) orelse n);
    }
    // Do not cut a multi-byte codepoint.
    while (n > 0 and n < names[0].len and names[0][n] & 0xc0 == 0x80) n -= 1;
    return names[0][0..n];
}

fn makeTree(dir: Io.Dir) !void {
    const io = testing.io;
    for ([_][]const u8{ "notes.txt", "note-2.txt", "readme.md", ".hidden", "src/main.zig", "src/mod.zig", "src/util.zig", "über.txt", "übung.txt" }) |path| {
        if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
        try dir.writeFile(io, .{ .sub_path = path, .data = "" });
    }
}

fn expectCompletion(dir: Io.Dir, input: []const u8, want_text: []const u8, want: []const []const u8) !void {
    var comp = try completeFileName(testing.io, dir, testing.allocator, input, null);
    defer comp.deinit();
    try testing.expectEqualStrings(want_text, comp.text);
    try testing.expectEqual(want.len, comp.matches.len);
    for (want, comp.matches) |w, m| try testing.expectEqualStrings(w, m);
}

test "completion extends to the common prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir);

    try expectCompletion(tmp.dir, "no", "note", &.{ "note-2.txt", "notes.txt" });
    try expectCompletion(tmp.dir, "r", "readme.md", &.{"readme.md"});
    try expectCompletion(tmp.dir, "sr", "src/", &.{"src/"});
    try expectCompletion(tmp.dir, "src/m", "src/m", &.{ "src/main.zig"[4..], "src/mod.zig"[4..] });
    try expectCompletion(tmp.dir, "src/u", "src/util.zig", &.{"util.zig"});
    try expectCompletion(tmp.dir, "x", "x", &.{});
    try expectCompletion(tmp.dir, "nodir/a", "nodir/a", &.{});
}

test "hidden files need a dot, and prefixes keep whole codepoints" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir);

    try expectCompletion(tmp.dir, ".h", ".hidden", &.{".hidden"});
    var comp = try completeFileName(testing.io, tmp.dir, testing.allocator, "", null);
    defer comp.deinit();
    for (comp.matches) |m| try testing.expect(m[0] != '.');

    // "über" and "übung" share "üb", not a part of the next codepoint.
    try expectCompletion(tmp.dir, "ü", "üb", &.{ "über.txt", "übung.txt" });
}

test "commonPrefix does not cut a codepoint" {
    // "é" is c3 a9 and "è" is c3 a8: they share only the first byte.
    try testing.expectEqualStrings("a", commonPrefix(&.{ "aé", "aè" }));
    try testing.expectEqualStrings("abc", commonPrefix(&.{ "abc", "abcd" }));
}
