//! The minibuffer: a buffer for one line of input in the echo area, as in
//! Emacs.
//!
//! The input is a normal `Buffer`, so all editing commands work in it. The
//! editor gives the keys to the minibuffer buffer while it is open, with a
//! small minibuffer keymap for RET, TAB and the history keys.

const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

/// A list of earlier inputs, newest last, as an Emacs history variable.
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

pub const Minibuffer = struct {
    gpa: std.mem.Allocator,
    /// The prompt text. It must stay valid while the minibuffer is open.
    prompt: []const u8,
    buffer: Buffer,
    /// The first screen cell that the echo area shows, for long input.
    left: usize = 0,
    history: ?*History,
    /// The history entry in the buffer, counted back from the newest. Null
    /// while the buffer holds the user's own input.
    history_offset: ?usize = null,
    /// The user's own input, kept while the buffer shows history entries.
    saved_input: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, prompt: []const u8, initial: []const u8, history: ?*History) !Minibuffer {
        var buffer = try Buffer.initText(gpa, initial);
        buffer.cursor = buffer.len();
        return .{ .gpa = gpa, .prompt = prompt, .buffer = buffer, .history = history };
    }

    pub fn deinit(self: *Minibuffer) void {
        if (self.saved_input) |s| self.gpa.free(s);
        self.buffer.deinit();
        self.* = undefined;
    }

    /// Returns a copy of the input, owned by the caller.
    pub fn text(self: *const Minibuffer, gpa: std.mem.Allocator) ![]u8 {
        return self.buffer.copyRange(gpa, 0, self.buffer.len());
    }

    /// Replaces the input as one undo step and puts the cursor at the end.
    pub fn setText(self: *Minibuffer, new_text: []const u8) !void {
        try self.buffer.replaceRange(0, self.buffer.len(), new_text);
    }

    /// M-p: shows the history entry before the current one.
    pub fn historyPrevious(self: *Minibuffer) !void {
        const history = self.history orelse return error.NoHistory;
        const offset = if (self.history_offset) |o| o + 1 else 0;
        const entry = history.get(offset) orelse return error.BeginningOfHistory;
        if (self.history_offset == null) self.saved_input = try self.text(self.gpa);
        try self.setText(entry);
        self.history_offset = offset;
    }

    /// M-n: shows the history entry after the current one. After the newest
    /// entry, it shows the user's own input again.
    pub fn historyNext(self: *Minibuffer) !void {
        const history = self.history orelse return error.NoHistory;
        const offset = self.history_offset orelse return error.EndOfHistory;
        if (offset == 0) {
            const saved = self.saved_input.?;
            try self.setText(saved);
            self.gpa.free(saved);
            self.saved_input = null;
            self.history_offset = null;
        } else {
            try self.setText(history.get(offset - 1).?);
            self.history_offset = offset - 1;
        }
    }
};

fn expectInput(mb: *const Minibuffer, want: []const u8) !void {
    const got = try mb.text(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

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

test "M-p and M-n walk the history and restore the typed input" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    try h.add("old.txt");
    try h.add("new.txt");

    var mb = try Minibuffer.init(testing.allocator, "Find file: ", "src/", &h);
    defer mb.deinit();
    try mb.buffer.insert("ty"); // the user types
    try expectInput(&mb, "src/ty");

    try mb.historyPrevious();
    try expectInput(&mb, "new.txt");
    try testing.expectEqual(7, mb.buffer.cursor);
    try mb.historyPrevious();
    try expectInput(&mb, "old.txt");
    try testing.expectError(error.BeginningOfHistory, mb.historyPrevious());

    try mb.historyNext();
    try expectInput(&mb, "new.txt");
    try mb.historyNext();
    try expectInput(&mb, "src/ty");
    try testing.expectError(error.EndOfHistory, mb.historyNext());
}

test "a minibuffer without history" {
    var mb = try Minibuffer.init(testing.allocator, "? ", "", null);
    defer mb.deinit();
    try testing.expectError(error.NoHistory, mb.historyPrevious());
}
