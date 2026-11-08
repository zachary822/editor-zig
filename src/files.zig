//! Reading and writing files for buffers.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

/// Replaces a leading "~" or "~/" with `home`. Returns a new path that the
/// caller owns.
pub fn expandPath(gpa: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    if (home) |h| {
        if (std.mem.eql(u8, path, "~")) return gpa.dupe(u8, h);
        if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(gpa, &.{ h, path[2..] });
    }
    return gpa.dupe(u8, path);
}

/// Reads a whole file. Returns null if the file does not exist.
pub fn readFile(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

/// Writes the buffer text to `path`. The write goes to a temporary file that
/// then replaces the file, so an error cannot leave a half-written file.
/// If `path` is a symbolic link, the real file gets the new text. An existing
/// file keeps its permissions.
pub fn writeBuffer(io: Io, dir: Io.Dir, gpa: std.mem.Allocator, path: []const u8, buf: *const Buffer) !void {
    const real: ?[:0]u8 = dir.realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    defer if (real) |r| gpa.free(r);
    const target: []const u8 = real orelse path;

    const permissions: Io.File.Permissions = if (real != null)
        (try dir.statFile(io, target, .{})).permissions
    else
        .default_file;

    var atomic = try dir.createFileAtomic(io, target, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buf);
    var it = buf.rope.chunks();
    while (it.next()) |chunk| writer.interface.writeAll(chunk) catch return writer.err.?;
    writer.interface.flush() catch return writer.err.?;

    try atomic.replace(io);
}

test "expandPath replaces a leading tilde" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8, []const u8 }{
        .{ "~/notes.txt", "/home/me", "/home/me/notes.txt" },
        .{ "~", "/home/me", "/home/me" },
        .{ "a/~/b", "/home/me", "a/~/b" },
        .{ "~other/x", "/home/me", "~other/x" },
        .{ "~/x", null, "~/x" },
    };
    for (cases) |case| {
        const got = try expandPath(gpa, case[0], case[1]);
        defer gpa.free(got);
        try testing.expectEqualStrings(case[2], got);
    }
}

test "write and read a buffer" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(null, try readFile(io, tmp.dir, gpa, "missing.txt"));

    var buf = try Buffer.initText(gpa, "first\n");
    defer buf.deinit();
    try writeBuffer(io, tmp.dir, gpa, "a.txt", &buf);

    buf.cursor = buf.len();
    try buf.insert("second\n");
    try writeBuffer(io, tmp.dir, gpa, "a.txt", &buf); // replaces the file

    const text = (try readFile(io, tmp.dir, gpa, "a.txt")).?;
    defer gpa.free(text);
    try testing.expectEqualStrings("first\nsecond\n", text);
}

test "writing through a symbolic link changes the real file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});

    var buf = try Buffer.initText(gpa, "new");
    defer buf.deinit();
    try writeBuffer(io, tmp.dir, gpa, "link.txt", &buf);

    const text = (try readFile(io, tmp.dir, gpa, "real.txt")).?;
    defer gpa.free(text);
    try testing.expectEqualStrings("new", text);

    // The link is still a link.
    var link_buf: [64]u8 = undefined;
    const n = try tmp.dir.readLink(io, "link.txt", &link_buf);
    try testing.expectEqualStrings("real.txt", link_buf[0..n]);
}
