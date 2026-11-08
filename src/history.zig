//! Input histories, as Emacs history variables.
//!
//! - `History`: a list of earlier inputs, newest last.
//! - `Histories`: named histories, for example "file", "search" and
//!   "command". Each kind of input has its own history.
//! - `HistoryNav`: the position for M-p and M-n in one input. The minibuffer
//!   and incremental search both use it.

const std = @import("std");
const testing = std.testing;

pub const History = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    /// The maximum number of entries, as Emacs `history-length`.
    pub const max_items = 100;

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds a copy of `text`. It does not add empty text or text that is the
    /// same as the newest entry.
    pub fn add(self: *History, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.get(0)) |newest| {
            if (std.mem.eql(u8, newest, text)) return;
        }
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        if (self.items.items.len == max_items) self.gpa.free(self.items.orderedRemove(0));
        try self.items.append(self.gpa, copy);
    }

    /// The entry `offset` steps back from the newest (0 is the newest).
    pub fn get(self: *const History, offset: usize) ?[]const u8 {
        const n = self.items.items.len;
        if (offset >= n) return null;
        return self.items.items[n - 1 - offset];
    }
};

pub const Histories = struct {
    gpa: std.mem.Allocator,
    /// Pointers, so a `*History` stays valid when the map grows.
    map: std.StringHashMapUnmanaged(*History) = .empty,

    pub fn init(gpa: std.mem.Allocator) Histories {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Histories) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// The history with this name. It makes the history the first time.
    pub fn get(self: *Histories, name: []const u8) !*History {
        if (self.map.get(name)) |h| return h;
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        const h = try self.gpa.create(History);
        errdefer self.gpa.destroy(h);
        h.* = .init(self.gpa);
        try self.map.put(self.gpa, key, h);
        return h;
    }
};

/// The M-p and M-n position in one input. The first M-p saves the user's
/// own input, and M-n after the newest entry gives it back.
pub const HistoryNav = struct {
    /// The entry on display, counted back from the newest. Null while the
    /// input is the user's own.
    offset: ?usize = null,
    saved: ?[]u8 = null,

    pub fn deinit(self: *HistoryNav, gpa: std.mem.Allocator) void {
        if (self.saved) |s| gpa.free(s);
        self.* = undefined;
    }

    /// M-p: the entry before the current one. `current` is the input now.
    /// The returned text stays valid until the next call.
    pub fn previous(self: *HistoryNav, gpa: std.mem.Allocator, h: *const History, current: []const u8) ![]const u8 {
        const offset = if (self.offset) |o| o + 1 else 0;
        const entry = h.get(offset) orelse return error.BeginningOfHistory;
        if (self.offset == null) {
            const copy = try gpa.dupe(u8, current);
            if (self.saved) |s| gpa.free(s);
            self.saved = copy;
        }
        self.offset = offset;
        return entry;
    }

    /// M-n: the entry after the current one, or the user's own input after
    /// the newest entry. The returned text stays valid until the next call.
    pub fn next(self: *HistoryNav, h: *const History) ![]const u8 {
        const offset = self.offset orelse return error.EndOfHistory;
        if (offset == 0) {
            self.offset = null;
            return self.saved orelse "";
        }
        self.offset = offset - 1;
        return h.get(offset - 1).?;
    }
};

test "history keeps entries newest first and skips repeats" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    try h.add("a");
    try h.add("b");
    try h.add("b"); // same as the newest: not added
    try h.add(""); // empty: not added
    try testing.expectEqual(2, h.items.items.len);
    try testing.expectEqualStrings("b", h.get(0).?);
    try testing.expectEqualStrings("a", h.get(1).?);
    try testing.expectEqual(null, h.get(2));
}

test "history is limited" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    for (0..History.max_items + 3) |i| {
        var buf: [8]u8 = undefined;
        try h.add(try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }
    try testing.expectEqual(History.max_items, h.items.items.len);
    try testing.expectEqualStrings("3", h.items.items[0]);
}

test "named histories are separate and stay at the same address" {
    var hs: Histories = .init(testing.allocator);
    defer hs.deinit();
    const file = try hs.get("file");
    try file.add("a.txt");
    const search = try hs.get("search");
    try search.add("needle");
    for (0..20) |i| { // grow the map
        var buf: [8]u8 = undefined;
        _ = try hs.get(try std.fmt.bufPrint(&buf, "h{d}", .{i}));
    }
    try testing.expectEqual(file, try hs.get("file"));
    try testing.expectEqualStrings("a.txt", file.get(0).?);
    try testing.expectEqualStrings("needle", (try hs.get("search")).get(0).?);
}

test "HistoryNav walks back and gives back the user's input" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    try h.add("old");
    try h.add("new");
    var nav: HistoryNav = .{};
    defer nav.deinit(testing.allocator);

    try testing.expectError(error.EndOfHistory, nav.next(&h));
    try testing.expectEqualStrings("new", try nav.previous(testing.allocator, &h, "typed"));
    try testing.expectEqualStrings("old", try nav.previous(testing.allocator, &h, "new"));
    try testing.expectError(error.BeginningOfHistory, nav.previous(testing.allocator, &h, "old"));
    try testing.expectEqualStrings("new", try nav.next(&h));
    try testing.expectEqualStrings("typed", try nav.next(&h));
    try testing.expectError(error.EndOfHistory, nav.next(&h));
    // A second walk saves the input again.
    try testing.expectEqualStrings("new", try nav.previous(testing.allocator, &h, "other"));
    try testing.expectEqualStrings("other", try nav.next(&h));
}
