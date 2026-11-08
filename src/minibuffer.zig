//! The minibuffer: a buffer for one line of input in the echo area, as in
//! Emacs.
//!
//! The input is a normal `Buffer`, so all editing commands work in it. The
//! editor gives the keys to the minibuffer buffer while it is open, with a
//! small minibuffer keymap for RET, TAB and the history keys.

const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const history = @import("history.zig");
const History = history.History;

pub const Minibuffer = struct {
    gpa: std.mem.Allocator,
    /// The prompt text, owned by the minibuffer.
    prompt: []u8,
    buffer: Buffer,
    /// The first screen cell that the echo area shows, for long input.
    left: usize = 0,
    history: ?*History,
    nav: history.HistoryNav = .{},

    pub fn init(gpa: std.mem.Allocator, prompt: []const u8, initial: []const u8, hist: ?*History) !Minibuffer {
        const prompt_copy = try gpa.dupe(u8, prompt);
        errdefer gpa.free(prompt_copy);
        var buffer = try Buffer.initText(gpa, initial);
        buffer.cursor = buffer.len();
        return .{ .gpa = gpa, .prompt = prompt_copy, .buffer = buffer, .history = hist };
    }

    pub fn deinit(self: *Minibuffer) void {
        self.nav.deinit(self.gpa);
        self.buffer.deinit();
        self.gpa.free(self.prompt);
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
        const h = self.history orelse return error.NoHistory;
        const current = try self.text(self.gpa);
        defer self.gpa.free(current);
        try self.setText(try self.nav.previous(self.gpa, h, current));
    }

    /// M-n: shows the history entry after the current one. After the newest
    /// entry, it shows the user's own input again.
    pub fn historyNext(self: *Minibuffer) !void {
        const h = self.history orelse return error.NoHistory;
        try self.setText(try self.nav.next(h));
    }
};

fn expectInput(mb: *const Minibuffer, want: []const u8) !void {
    const got = try mb.text(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
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

test "a minibuffer without history, with a prompt that is not static" {
    var prompt_buf: [32]u8 = undefined;
    const prompt = try std.fmt.bufPrint(&prompt_buf, "Save {s}? ", .{"a.txt"});
    var mb = try Minibuffer.init(testing.allocator, prompt, "", null);
    defer mb.deinit();
    @memset(&prompt_buf, 'x'); // the minibuffer has its own copy
    try testing.expectEqualStrings("Save a.txt? ", mb.prompt);
    try testing.expectError(error.NoHistory, mb.historyPrevious());
}
