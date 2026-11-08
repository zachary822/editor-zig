//! The kill ring: a list of killed text, newest first, as in Emacs.
//!
//! A kill adds an entry, or adds text to the newest entry when kills are
//! consecutive. A yank gets the newest entry. Each "yank-pop" goes to the
//! entry before it, and after the oldest entry it starts again at the newest.

const std = @import("std");
const testing = std.testing;

/// The maximum number of entries, as Emacs `kill-ring-max`.
pub const max_entries = 120;

pub const KillRing = struct {
    gpa: std.mem.Allocator,
    /// The entries, oldest first. The ring owns the memory.
    entries: std.ArrayList([]u8) = .empty,
    /// The entry that the last yank or yank-pop used, counted from the newest.
    yank_offset: usize = 0,

    pub fn init(gpa: std.mem.Allocator) KillRing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *KillRing) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds text that `gpa` allocated. The ring takes ownership of it, also
    /// when this function returns an error.
    pub fn push(self: *KillRing, text: []u8) !void {
        errdefer self.gpa.free(text);
        if (self.entries.items.len == max_entries) {
            self.gpa.free(self.entries.orderedRemove(0));
        }
        try self.entries.append(self.gpa, text);
    }

    /// Adds text to the end of the newest entry. If the ring is empty, adds
    /// a new entry. The ring takes ownership of `text`.
    pub fn appendToNewest(self: *KillRing, text: []u8) !void {
        if (self.entries.items.len == 0) return self.push(text);
        defer self.gpa.free(text);
        const newest = &self.entries.items[self.entries.items.len - 1];
        const joined = try std.mem.concat(self.gpa, u8, &.{ newest.*, text });
        self.gpa.free(newest.*);
        newest.* = joined;
    }

    /// The newest entry, for a yank. Null if the ring is empty.
    pub fn yank(self: *KillRing) ?[]const u8 {
        self.yank_offset = 0;
        return self.get(0);
    }

    /// The entry `offset` steps back from the newest, for C-u N C-y (offset
    /// N - 1). It wraps around the ring. Null if the ring is empty.
    pub fn yankAt(self: *KillRing, offset: usize) ?[]const u8 {
        const n = self.entries.items.len;
        if (n == 0) return null;
        self.yank_offset = offset % n;
        return self.get(self.yank_offset);
    }

    /// The entry before the one that the last yank used, for a yank-pop.
    pub fn yankPop(self: *KillRing) ?[]const u8 {
        const n = self.entries.items.len;
        if (n == 0) return null;
        self.yank_offset = (self.yank_offset + 1) % n;
        return self.get(self.yank_offset);
    }

    fn get(self: *const KillRing, offset: usize) ?[]const u8 {
        const n = self.entries.items.len;
        if (offset >= n) return null;
        return self.entries.items[n - 1 - offset];
    }
};

fn dupe(text: []const u8) ![]u8 {
    return testing.allocator.dupe(u8, text);
}

test "yank gets the newest kill, yank-pop goes back and wraps" {
    var ring: KillRing = .init(testing.allocator);
    defer ring.deinit();

    try testing.expectEqual(null, ring.yank());
    try ring.push(try dupe("one"));
    try ring.push(try dupe("two"));
    try ring.push(try dupe("three"));

    try testing.expectEqualStrings("three", ring.yank().?);
    try testing.expectEqualStrings("two", ring.yankPop().?);
    try testing.expectEqualStrings("one", ring.yankPop().?);
    try testing.expectEqualStrings("three", ring.yankPop().?);
    try testing.expectEqualStrings("three", ring.yank().?);
}

test "yankAt gets older entries, and yank-pop continues from there" {
    var ring: KillRing = .init(testing.allocator);
    defer ring.deinit();
    try testing.expectEqual(null, ring.yankAt(1));
    try ring.push(try dupe("one"));
    try ring.push(try dupe("two"));
    try ring.push(try dupe("three"));

    try testing.expectEqualStrings("two", ring.yankAt(1).?);
    try testing.expectEqualStrings("one", ring.yankPop().?);
    try testing.expectEqualStrings("three", ring.yankAt(3).?); // wraps
}

test "consecutive kills join into one entry" {
    var ring: KillRing = .init(testing.allocator);
    defer ring.deinit();

    try ring.appendToNewest(try dupe("first line"));
    try ring.appendToNewest(try dupe("\n"));
    try testing.expectEqual(1, ring.entries.items.len);
    try testing.expectEqualStrings("first line\n", ring.yank().?);
}

test "the ring discards the oldest entry when full" {
    var ring: KillRing = .init(testing.allocator);
    defer ring.deinit();

    for (0..max_entries + 1) |i| {
        try ring.push(try std.fmt.allocPrint(testing.allocator, "{d}", .{i}));
    }
    try testing.expectEqual(max_entries, ring.entries.items.len);
    try testing.expectEqualStrings("1", ring.entries.items[0]);
}
