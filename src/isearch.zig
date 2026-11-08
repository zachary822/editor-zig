//! Incremental search, as Emacs `isearch-forward` (C-s) and
//! `isearch-backward` (C-r).
//!
//! An `Isearch` keeps a copy of the buffer text. The editor ends the search
//! before any edit, so the copy stays correct while the search is active.
//! The search ignores ASCII case when the search text has no uppercase
//! letters, as the Emacs default `search-upper-case`.

const std = @import("std");
const testing = std.testing;
const history = @import("history.zig");

pub const Direction = enum { forward, backward };

pub const Match = struct { start: usize, end: usize };

pub const Isearch = struct {
    gpa: std.mem.Allocator,
    /// A copy of the buffer text, owned by the search.
    text: []u8,
    /// The cursor position when the search started. C-g goes back here.
    origin: usize,
    dir: Direction,
    query: std.ArrayList(u8) = .empty,
    /// The current match. After a failed search, the last match stays.
    match: ?Match = null,
    failing: bool = false,
    wrapped: bool = false,
    /// Where the editor puts the cursor: the end of a forward match, or the
    /// start of a backward match.
    cursor: usize,
    /// The state before each step, for DEL.
    steps: std.ArrayList(State) = .empty,
    /// The M-p and M-n position in the search history.
    nav: history.HistoryNav = .{},

    const State = struct {
        query_len: usize,
        /// The whole old search text, for a step that replaced it (M-p and
        /// M-n). Other steps only add text, so the old length is sufficient.
        old_query: ?[]u8 = null,
        dir: Direction,
        match: ?Match,
        failing: bool,
        wrapped: bool,
        cursor: usize,
    };

    /// Starts a search. The search takes ownership of `text`.
    pub fn init(gpa: std.mem.Allocator, text: []u8, origin: usize, dir: Direction) Isearch {
        return .{ .gpa = gpa, .text = text, .origin = origin, .dir = dir, .cursor = origin };
    }

    pub fn deinit(self: *Isearch) void {
        self.nav.deinit(self.gpa);
        for (self.steps.items) |st| if (st.old_query) |q| self.gpa.free(q);
        self.steps.deinit(self.gpa);
        self.query.deinit(self.gpa);
        self.gpa.free(self.text);
        self.* = undefined;
    }

    /// Adds a typed character and searches again from the current match, so
    /// the match grows at the same place when it can.
    pub fn addChar(self: *Isearch, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try self.addText(buf[0..n]);
    }

    /// Adds text to the search text, for example the last search for C-s
    /// with no search text.
    pub fn addText(self: *Isearch, text: []const u8) !void {
        try self.save();
        try self.query.appendSlice(self.gpa, text);
        self.search(.extend);
    }

    /// C-s or C-r during a search.
    /// - A new direction moves the cursor to the other end of the match.
    /// - After a failed search, the search wraps around the buffer.
    /// - At other times, it goes to the next match in the direction.
    pub fn repeat(self: *Isearch, dir: Direction) !void {
        if (self.query.items.len == 0) return error.EmptyQuery;
        try self.save();
        if (dir != self.dir) {
            self.dir = dir;
            if (self.match) |m| {
                if (!self.failing) {
                    self.cursor = if (dir == .forward) m.end else m.start;
                    return;
                }
            }
            self.search(.next);
            return;
        }
        if (self.failing) {
            self.wrapped = true;
            self.search(.wrap);
        } else {
            self.search(.next);
        }
    }

    /// M-p: replaces the search text with the search before it in `h`, and
    /// searches again from the start position.
    pub fn historyPrevious(self: *Isearch, h: *const history.History) !void {
        try self.replaceQuery(try self.nav.previous(self.gpa, h, self.query.items));
    }

    /// M-n: the search after it in `h`, or the user's own search text.
    pub fn historyNext(self: *Isearch, h: *const history.History) !void {
        try self.replaceQuery(try self.nav.next(h));
    }

    fn replaceQuery(self: *Isearch, text: []const u8) !void {
        try self.save();
        // Keep the old text for DEL. `text` can be the saved user input in
        // `nav`, so copy the old text before the query changes.
        self.steps.items[self.steps.items.len - 1].old_query = try self.gpa.dupe(u8, self.query.items);
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.gpa, text);
        self.match = null;
        self.failing = false;
        self.wrapped = false;
        self.cursor = self.origin;
        if (text.len > 0) self.search(.extend);
    }

    /// DEL: goes back one step. Returns false if there is no step.
    pub fn deleteChar(self: *Isearch) bool {
        const s = self.steps.pop() orelse return false;
        self.restore(s);
        return true;
    }

    /// C-g after a failed search: goes back to the last successful step.
    /// Returns false if the search is not failing.
    pub fn cancelFailing(self: *Isearch) bool {
        if (!self.failing) return false;
        while (self.failing) {
            if (!self.deleteChar()) break;
        }
        return true;
    }

    /// The echo area text, for example "Failing I-search backward: foo".
    pub fn prompt(self: *const Isearch, buf: []u8) []const u8 {
        const state = if (self.failing) "Failing " else if (self.wrapped) "Wrapped " else "";
        const dir = if (self.dir == .backward) " backward" else "";
        return std.fmt.bufPrint(buf, "{s}I-search{s}: {s}", .{ state, dir, self.query.items }) catch buf;
    }

    /// True if the search ignores case for this search text.
    pub fn foldCase(self: *const Isearch) bool {
        for (self.query.items) |b| if (std.ascii.isUpper(b)) return false;
        return true;
    }

    fn save(self: *Isearch) !void {
        try self.steps.append(self.gpa, .{
            .query_len = self.query.items.len,
            .dir = self.dir,
            .match = self.match,
            .failing = self.failing,
            .wrapped = self.wrapped,
            .cursor = self.cursor,
        });
    }

    fn restore(self: *Isearch, s: State) void {
        if (s.old_query) |q| {
            defer self.gpa.free(q);
            self.query.clearRetainingCapacity();
            // The old text was in the query before, so the capacity is sufficient.
            self.query.appendSliceAssumeCapacity(q[0..@min(q.len, self.query.capacity)]);
        } else {
            self.query.shrinkRetainingCapacity(s.query_len);
        }
        self.dir = s.dir;
        self.match = s.match;
        self.failing = s.failing;
        self.wrapped = s.wrapped;
        self.cursor = s.cursor;
    }

    fn search(self: *Isearch, mode: enum { extend, next, wrap }) void {
        const q = self.query.items;
        const fold = self.foldCase();
        const found: ?usize = switch (self.dir) {
            .forward => findForward(self.text, q, switch (mode) {
                .extend => if (self.match) |m| m.start else self.origin,
                .next => if (self.match) |m| m.end else self.origin,
                .wrap => 0,
            }, fold),
            .backward => blk: {
                // The largest match start that is not after `limit`.
                const limit: ?usize = switch (mode) {
                    .extend => if (self.match) |m| m.start else std.math.sub(usize, self.origin, q.len) catch null,
                    .next => if (self.match) |m| std.math.sub(usize, m.start, 1) catch null else std.math.sub(usize, self.origin, q.len) catch null,
                    .wrap => self.text.len,
                };
                break :blk findBackward(self.text, q, limit orelse break :blk null, fold);
            },
        };
        const i = found orelse {
            self.failing = true;
            return;
        };
        self.match = .{ .start = i, .end = i + q.len };
        self.failing = false;
        self.cursor = if (self.dir == .forward) i + q.len else i;
    }
};

fn matchesAt(text: []const u8, query: []const u8, i: usize, fold: bool) bool {
    if (i + query.len > text.len) return false;
    const part = text[i..][0..query.len];
    return if (fold) std.ascii.eqlIgnoreCase(part, query) else std.mem.eql(u8, part, query);
}

/// The first match that starts at or after `from`.
pub fn findForward(text: []const u8, query: []const u8, from: usize, fold: bool) ?usize {
    if (query.len == 0 or query.len > text.len) return null;
    var i = from;
    while (i + query.len <= text.len) : (i += 1) {
        if (matchesAt(text, query, i, fold)) return i;
    }
    return null;
}

/// The last match that starts at or before `limit`.
pub fn findBackward(text: []const u8, query: []const u8, limit: usize, fold: bool) ?usize {
    if (query.len == 0 or query.len > text.len) return null;
    var i = @min(limit, text.len - query.len) + 1;
    while (i > 0) {
        i -= 1;
        if (matchesAt(text, query, i, fold)) return i;
    }
    return null;
}

fn start(text: []const u8, origin: usize, dir: Direction) !Isearch {
    return .init(testing.allocator, try testing.allocator.dupe(u8, text), origin, dir);
}

fn typeText(s: *Isearch, text: []const u8) !void {
    for (text) |ch| try s.addChar(ch);
}

test "typing grows the match at the same place" {
    //                                0123456789012345678
    var s = try start("one two three twelve", 0, .forward);
    defer s.deinit();
    try typeText(&s, "t");
    try testing.expectEqual(Match{ .start = 4, .end = 5 }, s.match.?);
    try typeText(&s, "w");
    try testing.expectEqual(Match{ .start = 4, .end = 6 }, s.match.?);
    try testing.expectEqual(6, s.cursor);
    try typeText(&s, "e"); // "two" does not match "twe": go to "twelve"
    try testing.expectEqual(Match{ .start = 14, .end = 17 }, s.match.?);
    try testing.expect(!s.failing);
}

test "C-s goes to the next match, then fails, then wraps" {
    var s = try start("ab ab ab", 0, .forward);
    defer s.deinit();
    try typeText(&s, "ab");
    try testing.expectEqual(0, s.match.?.start);
    try s.repeat(.forward);
    try testing.expectEqual(3, s.match.?.start);
    try s.repeat(.forward);
    try testing.expectEqual(6, s.match.?.start);
    try s.repeat(.forward);
    try testing.expect(s.failing); // the last match stays
    try testing.expectEqual(6, s.match.?.start);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Failing I-search: ab", s.prompt(&buf));
    try s.repeat(.forward);
    try testing.expect(!s.failing);
    try testing.expect(s.wrapped);
    try testing.expectEqual(0, s.match.?.start);
    try testing.expectEqualStrings("Wrapped I-search: ab", s.prompt(&buf));
}

test "backward search and a change of direction" {
    //                        0123456789
    var s = try start("cat cat cat", 11, .backward);
    defer s.deinit();
    try typeText(&s, "cat");
    try testing.expectEqual(8, s.match.?.start);
    try testing.expectEqual(8, s.cursor); // backward: the cursor at the start
    try s.repeat(.backward);
    try testing.expectEqual(4, s.match.?.start);
    try s.repeat(.forward); // a new direction: the other end of the same match
    try testing.expectEqual(4, s.match.?.start);
    try testing.expectEqual(7, s.cursor);
    try s.repeat(.forward);
    try testing.expectEqual(8, s.match.?.start);
}

test "DEL goes back one step, and C-g removes the failed part" {
    var s = try start("foo food", 0, .forward);
    defer s.deinit();
    try typeText(&s, "food");
    try testing.expectEqual(4, s.match.?.start);
    try testing.expect(s.deleteChar());
    try testing.expectEqualStrings("foo", s.query.items);
    try testing.expectEqual(0, s.match.?.start); // the match before "d"

    try typeText(&s, "dxy");
    try testing.expect(s.failing);
    try testing.expect(s.cancelFailing());
    try testing.expectEqualStrings("food", s.query.items);
    try testing.expect(!s.failing);
    try testing.expect(!s.cancelFailing()); // not failing: C-g ends the search
}

test "lowercase search text ignores case, uppercase does not" {
    var s = try start("Hello hello", 0, .forward);
    defer s.deinit();
    try typeText(&s, "hello");
    try testing.expectEqual(0, s.match.?.start);
    try testing.expect(s.foldCase());

    var t = try start("Hello hello", 0, .forward);
    defer t.deinit();
    try typeText(&t, "He");
    try testing.expect(!t.foldCase());
    try t.repeat(.forward);
    try testing.expect(t.failing); // only one "He"
}

test "a search with no text cannot repeat" {
    var s = try start("abc", 0, .forward);
    defer s.deinit();
    try testing.expectError(error.EmptyQuery, s.repeat(.forward));
    try s.addText("b"); // the editor gives the last search text
    try testing.expectEqual(1, s.match.?.start);
}

test "M-p and M-n replace the search text from the history" {
    var h: history.History = .init(testing.allocator);
    defer h.deinit();
    try h.add("two");
    try h.add("one");

    var s = try start("one two one", 0, .forward);
    defer s.deinit();
    try typeText(&s, "o");
    try s.historyPrevious(&h);
    try testing.expectEqualStrings("one", s.query.items);
    try testing.expectEqual(Match{ .start = 0, .end = 3 }, s.match.?);
    try s.historyPrevious(&h);
    try testing.expectEqualStrings("two", s.query.items);
    try testing.expectEqual(Match{ .start = 4, .end = 7 }, s.match.?);
    try s.historyNext(&h);
    try s.historyNext(&h);
    try testing.expectEqualStrings("o", s.query.items); // the typed text again
    try testing.expect(s.deleteChar()); // DEL undoes the M-n step
    try testing.expectEqualStrings("one", s.query.items);
}

test "findForward and findBackward" {
    try testing.expectEqual(2, findForward("xxab", "ab", 0, false));
    try testing.expectEqual(null, findForward("xxab", "ab", 3, false));
    try testing.expectEqual(2, findBackward("xxabab", "ab", 3, false));
    try testing.expectEqual(4, findBackward("xxabab", "ab", 99, false));
    try testing.expectEqual(null, findBackward("xxab", "ab", 1, false));
    try testing.expectEqual(0, findForward("ABC", "abc", 0, true));
}
