//! A text buffer: a rope of UTF-8 bytes and a cursor.
//!
//! The cursor is a byte offset and is always on a codepoint boundary.
//! Columns count codepoints, not display cells.

const std = @import("std");
const testing = std.testing;
const rope_zig = @import("rope");
const Rope = rope_zig.Rope;
const Snapshot = rope_zig.Snapshot;

/// The kind of an edit. Consecutive edits of the same kind, except `.other`,
/// make one undo group.
const EditKind = enum { insert, delete_backward, delete_forward, other };

const UndoEntry = struct {
    snap: Snapshot,
    cursor: usize,
};

/// The maximum number of undo steps that the buffer keeps.
const max_undo = 1000;
/// The maximum number of edits in one undo group, as in Emacs.
const max_group = 20;

pub const Buffer = struct {
    rope: Rope,
    cursor: usize = 0,
    /// The column that vertical movement tries to keep. Horizontal movement
    /// and edits clear it.
    goal_col: ?usize = null,
    /// The text and cursor before each undo step. The newest step is last.
    undo_stack: std.ArrayList(UndoEntry) = .empty,
    /// The text and cursor before each undo, for redo. A new edit clears it.
    redo_stack: std.ArrayList(UndoEntry) = .empty,
    /// The kind of the last edit, for undo groups. Movement clears it.
    last_edit: ?EditKind = null,
    group_len: usize = 0,
    /// The other end of the region. Null until the first set-mark. Edits
    /// move it like an Emacs marker.
    mark: ?usize = null,
    /// True while the region is active and shown, as in Emacs
    /// `transient-mark-mode`. Edits and C-g make it inactive.
    mark_active: bool = false,
    /// The file that this buffer visits, owned by the buffer. Null for a
    /// buffer that has no file yet.
    file_path: ?[]u8 = null,
    /// The text at the last save or load. The buffer is modified when the
    /// rope root is not this root. The snapshot keeps the root shared, so the
    /// rope never changes it in place, and an undo back to it gives the same
    /// pointer.
    saved: Snapshot = .{ .root = null },
    /// Changes on each text change. A syntax tree uses it to know when to
    /// parse again.
    version: u64 = 0,

    pub const Region = struct { start: usize, end: usize };

    pub fn init(gpa: std.mem.Allocator) Buffer {
        return .{ .rope = .init(gpa) };
    }

    /// Makes a buffer that holds `text` and is not modified.
    pub fn initText(gpa: std.mem.Allocator, text: []const u8) !Buffer {
        var buf: Buffer = .{ .rope = try .fromSlice(gpa, text) };
        buf.saved = buf.rope.snapshot();
        return buf;
    }

    pub fn deinit(self: *Buffer) void {
        const gpa = self.rope.gpa;
        for (self.undo_stack.items) |entry| self.rope.release(entry.snap);
        self.undo_stack.deinit(gpa);
        for (self.redo_stack.items) |entry| self.rope.release(entry.snap);
        self.redo_stack.deinit(gpa);
        self.rope.release(self.saved);
        if (self.file_path) |p| gpa.free(p);
        self.rope.deinit();
        self.* = undefined;
    }

    pub fn len(self: *const Buffer) usize {
        return self.rope.len();
    }

    // File state

    /// True if the text is not the same as at the last save or load.
    pub fn isModified(self: *const Buffer) bool {
        return self.rope.root != self.saved.root;
    }

    /// Records that the current text is saved.
    pub fn markSaved(self: *Buffer) void {
        self.rope.release(self.saved);
        self.saved = self.rope.snapshot();
    }

    /// Sets the file that the buffer visits. The buffer copies `path`.
    pub fn setFilePath(self: *Buffer, path: []const u8) !void {
        const gpa = self.rope.gpa;
        const copy = try gpa.dupe(u8, path);
        if (self.file_path) |p| gpa.free(p);
        self.file_path = copy;
    }

    // Mark and region

    /// Sets the mark at the cursor and makes the region active.
    pub fn setMark(self: *Buffer) void {
        self.mark = self.cursor;
        self.mark_active = true;
    }

    pub fn deactivateMark(self: *Buffer) void {
        self.mark_active = false;
    }

    /// Swaps the cursor and the mark, and makes the region active.
    pub fn exchangePointAndMark(self: *Buffer) !void {
        const m = self.mark orelse return error.NoMark;
        self.mark = self.cursor;
        self.cursor = m;
        self.mark_active = true;
        self.moved();
    }

    /// The text between the cursor and the mark, or null if there is no mark.
    pub fn region(self: *const Buffer) ?Region {
        const m = self.mark orelse return null;
        return .{ .start = @min(m, self.cursor), .end = @max(m, self.cursor) };
    }

    /// The region while it is active, for display.
    pub fn activeRegion(self: *const Buffer) ?Region {
        return if (self.mark_active) self.region() else null;
    }

    /// Deletes the region and returns its text, owned by the caller.
    pub fn killRegion(self: *Buffer, gpa: std.mem.Allocator) ![]u8 {
        const r = self.region() orelse return error.NoMark;
        const text = try self.copyRange(gpa, r.start, r.end);
        errdefer gpa.free(text);
        if (r.end > r.start) {
            try self.recordUndo(.other);
            try self.editDelete(r.start, r.end - r.start);
        }
        self.cursor = r.start;
        self.goal_col = null;
        self.mark_active = false;
        return text;
    }

    /// Returns a copy of the region text, owned by the caller, and makes the
    /// region inactive.
    pub fn copyRegion(self: *Buffer, gpa: std.mem.Allocator) ![]u8 {
        const r = self.region() orelse return error.NoMark;
        const text = try self.copyRange(gpa, r.start, r.end);
        self.mark_active = false;
        return text;
    }

    /// Inserts into the rope, moves the mark and makes the region inactive.
    /// All edits go through this function or `editDelete`.
    fn editInsert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.rope.insert(pos, text);
        self.version +%= 1;
        // As an Emacs marker, the mark stays before text inserted at its position.
        if (self.mark) |*m| {
            if (m.* > pos) m.* += text.len;
        }
        self.mark_active = false;
    }

    /// Deletes from the rope, moves the mark and makes the region inactive.
    fn editDelete(self: *Buffer, start: usize, count: usize) !void {
        try self.rope.delete(start, count);
        self.version +%= 1;
        if (self.mark) |*m| {
            if (m.* >= start + count) {
                m.* -= count;
            } else if (m.* > start) {
                m.* = start;
            }
        }
        self.mark_active = false;
    }

    // Editing

    /// Inserts text at the cursor as one undo step.
    pub fn insert(self: *Buffer, text: []const u8) !void {
        try self.insertKind(text, .other);
    }

    /// Inserts a typed codepoint. Typed text makes undo groups.
    pub fn insertCodepoint(self: *Buffer, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try self.insertKind(buf[0..n], .insert);
    }

    fn insertKind(self: *Buffer, text: []const u8, kind: EditKind) !void {
        if (text.len == 0) return;
        try self.recordUndo(kind);
        try self.editInsert(self.cursor, text);
        self.cursor += text.len;
        self.goal_col = null;
    }

    /// Deletes the codepoint before the cursor.
    pub fn deleteBackward(self: *Buffer) !void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary(self.cursor);
        try self.recordUndo(.delete_backward);
        try self.editDelete(start, self.cursor - start);
        self.cursor = start;
        self.goal_col = null;
    }

    /// Deletes the codepoint at the cursor.
    pub fn deleteForward(self: *Buffer) !void {
        if (self.cursor == self.len()) return;
        const end = self.nextBoundary(self.cursor);
        try self.recordUndo(.delete_forward);
        try self.editDelete(self.cursor, end - self.cursor);
        self.goal_col = null;
    }

    /// Deletes from the cursor to the end of the line, as Emacs `kill-line`
    /// does. If only spaces and tabs come after the cursor, it also deletes
    /// the newline. Thus on an empty line, it joins the next line.
    /// Returns the deleted text, owned by the caller, or null if nothing was
    /// deleted.
    pub fn killLine(self: *Buffer, gpa: std.mem.Allocator) !?[]u8 {
        const end = self.lineEnd(self.cursor);
        var blank = true;
        var p = self.cursor;
        while (p < end) : (p += 1) {
            const b = self.rope.byteAt(p);
            if (b != ' ' and b != '\t') {
                blank = false;
                break;
            }
        }
        const stop = if (blank and end < self.len()) end + 1 else end;
        if (stop == self.cursor) return null;

        const text = try self.copyRange(gpa, self.cursor, stop);
        errdefer gpa.free(text);
        try self.recordUndo(.other);
        try self.editDelete(self.cursor, stop - self.cursor);
        self.goal_col = null;
        return text;
    }

    /// Emacs `kill-line` with a count. With `n > 0`, kills from the cursor
    /// through the next `n` newlines. With `n <= 0`, kills back to the start
    /// of the line `-n` lines up, so 0 kills to the start of this line.
    /// Returns the text, owned by the caller, or null if nothing was killed.
    pub fn killLines(self: *Buffer, gpa: std.mem.Allocator, n: i64) !?[]u8 {
        const line = self.cursorLine();
        const target = if (n > 0)
            self.lineOffset(line +| @as(usize, @intCast(n)))
        else
            self.lineOffset(line -| @as(usize, @intCast(-n)));
        const start = @min(self.cursor, target);
        const end = @max(self.cursor, target);
        if (start == end) return null;

        const text = try self.copyRange(gpa, start, end);
        errdefer gpa.free(text);
        try self.recordUndo(.other);
        try self.editDelete(start, end - start);
        self.cursor = start;
        self.goal_col = null;
        return text;
    }

    /// Replaces the bytes from `start` to `end` with `text` as one undo step,
    /// and puts the cursor after the new text.
    pub fn replaceRange(self: *Buffer, start: usize, end: usize, text: []const u8) !void {
        std.debug.assert(start <= end and end <= self.len());
        try self.recordUndo(.other);
        if (end > start) try self.editDelete(start, end - start);
        try self.editInsert(start, text);
        self.cursor = start + text.len;
        self.goal_col = null;
    }

    /// Returns a copy of the bytes from `start` to `end`, owned by the caller.
    pub fn copyRange(self: *const Buffer, gpa: std.mem.Allocator, start: usize, end: usize) ![]u8 {
        std.debug.assert(start <= end and end <= self.len());
        const out = try gpa.alloc(u8, end - start);
        var pos: usize = 0; // buffer position of the current chunk
        var it = self.rope.chunks();
        while (it.next()) |chunk| : (pos += chunk.len) {
            const lo = @max(start, pos);
            const hi = @min(end, pos + chunk.len);
            if (lo < hi) @memcpy(out[lo - start .. hi - start], chunk[lo - pos .. hi - pos]);
            if (pos + chunk.len >= end) break;
        }
        return out;
    }

    // Undo and redo

    /// Puts the text and cursor back to how they were before the last undo
    /// step. Each undo goes one more step back.
    pub fn undo(self: *Buffer) !void {
        if (self.undo_stack.items.len == 0) return error.NothingToUndo;
        try self.pushState(&self.redo_stack);
        self.popState(&self.undo_stack);
    }

    /// Does again the change that the last undo took away.
    pub fn redo(self: *Buffer) !void {
        if (self.redo_stack.items.len == 0) return error.NothingToRedo;
        try self.pushState(&self.undo_stack);
        self.popState(&self.redo_stack);
    }

    /// Saves the current text and cursor on `stack`. If the stack is full,
    /// the oldest entry is discarded.
    fn pushState(self: *Buffer, stack: *std.ArrayList(UndoEntry)) !void {
        if (stack.items.len == max_undo) {
            self.rope.release(stack.orderedRemove(0).snap);
        }
        const snap = self.rope.snapshot();
        stack.append(self.rope.gpa, .{ .snap = snap, .cursor = self.cursor }) catch |err| {
            self.rope.release(snap);
            return err;
        };
    }

    /// Replaces the current text and cursor with the newest entry of `stack`.
    fn popState(self: *Buffer, stack: *std.ArrayList(UndoEntry)) void {
        const entry = stack.pop().?;
        self.rope.restore(entry.snap);
        self.version +%= 1;
        self.rope.release(entry.snap);
        self.cursor = entry.cursor;
        self.goal_col = null;
        self.last_edit = null;
        // The saved text can be shorter, so keep the mark inside it.
        if (self.mark) |*m| m.* = @min(m.*, self.len());
        self.mark_active = false;
    }

    /// Saves the text before an edit, unless the edit continues a group.
    /// A new edit also clears the redo stack.
    fn recordUndo(self: *Buffer, kind: EditKind) !void {
        for (self.redo_stack.items) |entry| self.rope.release(entry.snap);
        self.redo_stack.clearRetainingCapacity();

        if (kind != .other and self.last_edit == kind and self.group_len < max_group) {
            self.group_len += 1;
            return;
        }
        try self.pushState(&self.undo_stack);
        self.last_edit = kind;
        self.group_len = 1;
    }

    // Movement

    pub fn forwardChar(self: *Buffer) void {
        if (self.cursor < self.len()) self.cursor = self.nextBoundary(self.cursor);
        self.moved();
    }

    pub fn backwardChar(self: *Buffer) void {
        if (self.cursor > 0) self.cursor = self.prevBoundary(self.cursor);
        self.moved();
    }

    pub fn lineStartPos(self: *Buffer) void {
        self.cursor = self.lineStart(self.cursor);
        self.moved();
    }

    pub fn lineEndPos(self: *Buffer) void {
        self.cursor = self.lineEnd(self.cursor);
        self.moved();
    }

    pub fn nextLine(self: *Buffer) void {
        const goal = self.goal_col orelse self.column(self.cursor);
        self.last_edit = null;
        const end = self.lineEnd(self.cursor);
        if (end == self.len()) return; // last line
        self.cursor = self.posAtColumn(end + 1, goal);
        self.goal_col = goal;
    }

    pub fn previousLine(self: *Buffer) void {
        const goal = self.goal_col orelse self.column(self.cursor);
        self.last_edit = null;
        const start = self.lineStart(self.cursor);
        if (start == 0) return; // first line
        self.cursor = self.posAtColumn(self.lineStart(start - 1), goal);
        self.goal_col = goal;
    }

    /// Moves the cursor down (or up) by at most `count` lines and keeps the
    /// goal column. Returns the number of lines that the cursor moved.
    pub fn moveLines(self: *Buffer, down: bool, count: usize) usize {
        var n: usize = 0;
        while (n < count) : (n += 1) {
            const before = self.cursor;
            if (down) self.nextLine() else self.previousLine();
            if (self.cursor == before) break; // first or last line
        }
        return n;
    }

    /// Moves the cursor to a byte position, for example from a syntax tree.
    /// The position must be on a codepoint boundary.
    pub fn moveTo(self: *Buffer, pos: usize) void {
        std.debug.assert(pos <= self.len());
        self.cursor = pos;
        self.moved();
    }

    /// Horizontal movement clears the goal column and ends an undo group.
    fn moved(self: *Buffer) void {
        self.goal_col = null;
        self.last_edit = null;
    }

    // Queries

    /// The byte position where zero-based line `line` starts. If the buffer
    /// has fewer lines, returns the buffer length.
    pub fn lineOffset(self: *const Buffer, line: usize) usize {
        if (line == 0) return 0;
        var seen: usize = 0;
        var pos: usize = 0;
        var it = self.rope.chunks();
        while (it.next()) |chunk| : (pos += chunk.len) {
            for (chunk, 0..) |b, i| {
                if (b != '\n') continue;
                seen += 1;
                if (seen == line) return pos + i + 1;
            }
        }
        return self.len();
    }

    /// The zero-based line number of the cursor.
    pub fn cursorLine(self: *const Buffer) usize {
        var line: usize = 0;
        var pos: usize = 0;
        var it = self.rope.chunks();
        while (it.next()) |chunk| {
            if (pos + chunk.len >= self.cursor) {
                return line + std.mem.count(u8, chunk[0 .. self.cursor - pos], "\n");
            }
            line += std.mem.count(u8, chunk, "\n");
            pos += chunk.len;
        }
        return line;
    }

    /// The column of `pos`, in codepoints from the start of its line.
    pub fn column(self: *const Buffer, pos: usize) usize {
        var col: usize = 0;
        var p = self.lineStart(pos);
        while (p < pos) : (p += 1) {
            if (!isContinuation(self.rope.byteAt(p))) col += 1;
        }
        return col;
    }

    /// The screen column of `pos` from the start of its line. A tab moves to
    /// the next multiple of `tab_width`. Each other codepoint uses one column.
    pub fn displayColumn(self: *const Buffer, pos: usize, tab_width: usize) usize {
        var col: usize = 0;
        var p = self.lineStart(pos);
        while (p < pos) : (p += 1) {
            const b = self.rope.byteAt(p);
            if (b == '\t') {
                col = (col / tab_width + 1) * tab_width;
            } else if (!isContinuation(b)) {
                col += 1;
            }
        }
        return col;
    }

    fn lineStart(self: *const Buffer, pos: usize) usize {
        var p = pos;
        while (p > 0 and self.rope.byteAt(p - 1) != '\n') p -= 1;
        return p;
    }

    fn lineEnd(self: *const Buffer, pos: usize) usize {
        var p = pos;
        while (p < self.len() and self.rope.byteAt(p) != '\n') p += 1;
        return p;
    }

    /// The position `col` codepoints after `start`, but not past the line end.
    fn posAtColumn(self: *const Buffer, start: usize, col: usize) usize {
        var p = start;
        var n: usize = 0;
        while (n < col and p < self.len() and self.rope.byteAt(p) != '\n') : (n += 1) {
            p = self.nextBoundary(p);
        }
        return p;
    }

    fn nextBoundary(self: *const Buffer, pos: usize) usize {
        var p = pos + 1;
        while (p < self.len() and isContinuation(self.rope.byteAt(p))) p += 1;
        return p;
    }

    fn prevBoundary(self: *const Buffer, pos: usize) usize {
        var p = pos - 1;
        while (p > 0 and isContinuation(self.rope.byteAt(p))) p -= 1;
        return p;
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xc0 == 0x80;
}

// Tests

fn expectText(buf: *const Buffer, want: []const u8) !void {
    const got = try buf.rope.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "insert and delete at the cursor" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hllo");
    buf.cursor = 1;
    try buf.insertCodepoint('e');
    try expectText(&buf, "hello");
    try testing.expectEqual(2, buf.cursor);

    try buf.deleteBackward();
    try buf.deleteForward();
    try expectText(&buf, "hlo");
    try testing.expectEqual(1, buf.cursor);

    buf.cursor = 0;
    try buf.deleteBackward(); // nothing before the cursor
    buf.cursor = buf.len();
    try buf.deleteForward(); // nothing after the cursor
    try expectText(&buf, "hlo");
}

test "movement and deletion step over whole codepoints" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insertCodepoint('é'); // 2 bytes
    try buf.insertCodepoint('😀'); // 4 bytes
    try testing.expectEqual(6, buf.cursor);

    buf.backwardChar();
    try testing.expectEqual(2, buf.cursor);
    buf.backwardChar();
    try testing.expectEqual(0, buf.cursor);
    buf.forwardChar();
    try testing.expectEqual(2, buf.cursor);

    try buf.deleteForward();
    try expectText(&buf, "é");
    try buf.deleteBackward();
    try expectText(&buf, "");
}

test "vertical movement keeps the goal column" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("abcdef\nab\nabcdef");
    buf.cursor = 5; // line 0, column 5
    buf.nextLine();
    try testing.expectEqual(9, buf.cursor); // end of "ab"
    try testing.expectEqual(1, buf.cursorLine());
    buf.nextLine();
    try testing.expectEqual(15, buf.cursor); // line 2, column 5 again
    buf.nextLine(); // last line: no change
    try testing.expectEqual(15, buf.cursor);

    buf.previousLine();
    buf.previousLine();
    try testing.expectEqual(5, buf.cursor);
    try testing.expectEqual(0, buf.cursorLine());

    buf.lineEndPos();
    try testing.expectEqual(6, buf.cursor);
    buf.lineStartPos();
    try testing.expectEqual(0, buf.cursor);
}

test "modified state follows edits, saves and undo" {
    var buf = try Buffer.initText(testing.allocator, "hello");
    defer buf.deinit();
    try testing.expect(!buf.isModified());

    buf.cursor = 5;
    try buf.insertCodepoint('!');
    try testing.expect(buf.isModified());
    try buf.undo();
    try testing.expect(!buf.isModified()); // back to the loaded text

    try buf.insert(" world");
    buf.markSaved();
    try testing.expect(!buf.isModified());
    try buf.undo();
    try testing.expect(buf.isModified()); // the saved text has " world"
    try buf.redo();
    try testing.expect(!buf.isModified());

    try buf.setFilePath("a.txt");
    try buf.setFilePath("b.txt");
    try testing.expectEqualStrings("b.txt", buf.file_path.?);
}

test "lineOffset and version" {
    var buf = try Buffer.initText(testing.allocator, "ab\ncd\n\nef");
    defer buf.deinit();
    try testing.expectEqual(0, buf.lineOffset(0));
    try testing.expectEqual(3, buf.lineOffset(1));
    try testing.expectEqual(6, buf.lineOffset(2));
    try testing.expectEqual(7, buf.lineOffset(3));
    try testing.expectEqual(buf.len(), buf.lineOffset(4));

    const v0 = buf.version;
    buf.moveTo(1); // movement does not change the version
    try testing.expectEqual(v0, buf.version);
    try buf.insert("x");
    try testing.expect(buf.version != v0);
    const v1 = buf.version;
    try buf.undo();
    try testing.expect(buf.version != v1);
}

test "an empty new buffer is not modified" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();
    try testing.expect(!buf.isModified());
    try buf.insert("x");
    try testing.expect(buf.isModified());
}

test "region is between the mark and the cursor, in either order" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hello world");
    try testing.expectEqual(null, buf.region());
    try testing.expectError(error.NoMark, buf.exchangePointAndMark());

    buf.cursor = 6;
    buf.setMark();
    buf.lineEndPos(); // movement keeps the region active
    try testing.expectEqual(Buffer.Region{ .start = 6, .end = 11 }, buf.activeRegion().?);

    try buf.exchangePointAndMark();
    try testing.expectEqual(6, buf.cursor);
    try testing.expectEqual(11, buf.mark.?);
    try testing.expectEqual(Buffer.Region{ .start = 6, .end = 11 }, buf.region().?);
}

test "killRegion and copyRegion" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hello big world");
    buf.cursor = 6;
    buf.setMark();
    buf.cursor = 10;

    const copied = try buf.copyRegion(testing.allocator);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("big ", copied);
    try testing.expect(!buf.mark_active);
    try expectText(&buf, "hello big world");

    const killed = try buf.killRegion(testing.allocator);
    defer testing.allocator.free(killed);
    try testing.expectEqualStrings("big ", killed);
    try expectText(&buf, "hello world");
    try testing.expectEqual(6, buf.cursor);

    try buf.undo();
    try expectText(&buf, "hello big world");
}

test "edits move the mark and make the region inactive" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("abcdef");
    buf.cursor = 3;
    buf.setMark(); // mark at 3, before "d"

    buf.cursor = 0;
    try buf.insert("XY"); // before the mark: the mark moves
    try testing.expectEqual(5, buf.mark.?);
    try testing.expect(!buf.mark_active);

    buf.cursor = 5;
    try buf.insert("!"); // at the mark: the mark stays before the new text
    try testing.expectEqual(5, buf.mark.?);

    buf.cursor = 4;
    try buf.deleteForward(); // "c" before the mark
    try testing.expectEqual(4, buf.mark.?);

    buf.lineEndPos();
    try buf.deleteBackward(); // after the mark: no change
    try testing.expectEqual(4, buf.mark.?);

    buf.cursor = 2;
    buf.setMark();
    buf.cursor = 0;
    freeKill(try buf.killLine(testing.allocator)); // the mark was inside the kill
    try testing.expectEqual(0, buf.mark.?);

    try buf.undo(); // undo keeps the mark inside the text
    try testing.expect(buf.mark.? <= buf.len());
}

fn freeKill(text: ?[]u8) void {
    if (text) |t| testing.allocator.free(t);
}

test "killLines kills whole lines forward and backward" {
    var buf = try Buffer.initText(testing.allocator, "one\ntwo\nthree\nfour");
    defer buf.deinit();

    buf.cursor = 1; // "o|ne"
    const a = (try buf.killLines(testing.allocator, 2)).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("ne\ntwo\n", a);
    try expectText(&buf, "othree\nfour");

    buf.cursor = 3; // "oth|ree"
    const b = (try buf.killLines(testing.allocator, 0)).?; // to the line start
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("oth", b);
    try expectText(&buf, "ree\nfour");

    buf.cursor = 6; // "ree\nfo|ur"
    const c_ = (try buf.killLines(testing.allocator, -1)).?; // to the start of the line above
    defer testing.allocator.free(c_);
    try testing.expectEqualStrings("ree\nfo", c_);
    try expectText(&buf, "ur");

    buf.cursor = 0;
    const d = (try buf.killLines(testing.allocator, 5)).?; // past the last line: to the end
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("ur", d);
    try testing.expectEqual(null, try buf.killLines(testing.allocator, 1)); // empty buffer
}

test "killLine returns the deleted text" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("one two\n  \nend");
    buf.cursor = 4;
    const a = (try buf.killLine(testing.allocator)).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("two", a);

    buf.cursor = 4; // end of "one "
    const b = (try buf.killLine(testing.allocator)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("\n", b);

    buf.cursor = buf.len();
    try testing.expectEqual(null, try buf.killLine(testing.allocator));
}

test "copyRange crosses rope chunks" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    // Many single-byte inserts in the middle make a rope with many leaves.
    try buf.insert("ae");
    buf.cursor = 1;
    for ("bcd") |ch| try buf.insertCodepoint(ch);
    const big: [3000]u8 = @splat('x');
    buf.cursor = 0;
    try buf.insert(&big);

    const all = try buf.copyRange(testing.allocator, 0, buf.len());
    defer testing.allocator.free(all);
    try testing.expectEqualStrings(&big ++ "abcde", all);

    const part = try buf.copyRange(testing.allocator, 2999, 3002);
    defer testing.allocator.free(part);
    try testing.expectEqualStrings("xab", part);
}

test "redo does again what undo took away" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("one");
    try buf.insert(" two");
    try buf.undo();
    try buf.undo();
    try expectText(&buf, "");

    try buf.redo();
    try expectText(&buf, "one");
    try testing.expectEqual(3, buf.cursor);
    try buf.redo();
    try expectText(&buf, "one two");
    try testing.expectError(error.NothingToRedo, buf.redo());

    try buf.undo();
    try buf.insert("!"); // a new edit clears the redo stack
    try expectText(&buf, "one!");
    try testing.expectError(error.NothingToRedo, buf.redo());
    try buf.undo();
    try expectText(&buf, "one");
}

test "replaceRange is one undo step" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hello world");
    try buf.replaceRange(6, 11, "there");
    try expectText(&buf, "hello there");
    try testing.expectEqual(11, buf.cursor);
    try buf.undo();
    try expectText(&buf, "hello world");
}

test "killLine deletes to the end of the line, then the newline" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hello world\nnext\n  \nlast");
    buf.cursor = 5;
    freeKill(try buf.killLine(testing.allocator));
    try expectText(&buf, "hello\nnext\n  \nlast");
    freeKill(try buf.killLine(testing.allocator)); // at line end: join the next line
    try expectText(&buf, "hellonext\n  \nlast");

    buf.cursor = 10; // start of "  " line
    freeKill(try buf.killLine(testing.allocator)); // only blanks: delete them and the newline
    try expectText(&buf, "hellonext\nlast");

    buf.cursor = buf.len();
    freeKill(try buf.killLine(testing.allocator)); // end of buffer: nothing to delete
    try expectText(&buf, "hellonext\nlast");
    try testing.expectEqual(buf.len(), buf.cursor);
}

test "undo groups typed text and restores the cursor" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    for ("abc") |ch| try buf.insertCodepoint(ch);
    buf.backwardChar(); // movement ends the group
    for ("XY") |ch| try buf.insertCodepoint(ch);
    try expectText(&buf, "abXYc");

    try buf.undo();
    try expectText(&buf, "abc");
    try testing.expectEqual(2, buf.cursor);
    try buf.undo();
    try expectText(&buf, "");
    try testing.expectEqual(0, buf.cursor);
    try testing.expectError(error.NothingToUndo, buf.undo());
}

test "undo of killLine and deletions" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("one two");
    buf.lineStartPos();
    freeKill(try buf.killLine(testing.allocator));
    try expectText(&buf, "");
    try buf.undo();
    try expectText(&buf, "one two");
    try testing.expectEqual(0, buf.cursor);

    buf.lineEndPos();
    try buf.deleteBackward();
    try buf.deleteBackward();
    try buf.deleteBackward(); // one group
    try expectText(&buf, "one ");
    try buf.undo();
    try expectText(&buf, "one two");
    try testing.expectEqual(7, buf.cursor);
}

test "undo groups have a size limit" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    for (0..max_group + 5) |_| try buf.insertCodepoint('a');
    try buf.undo();
    try testing.expectEqual(max_group, buf.len());
    try buf.undo();
    try testing.expectEqual(0, buf.len());
}

test "display column expands tabs" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("x\n\tab\tc");
    try testing.expectEqual(0, buf.displayColumn(2, 8)); // line start
    try testing.expectEqual(8, buf.displayColumn(3, 8)); // after "\t"
    try testing.expectEqual(10, buf.displayColumn(5, 8)); // after "\tab"
    try testing.expectEqual(16, buf.displayColumn(6, 8)); // after "\tab\t"
    try testing.expectEqual(4, buf.displayColumn(3, 4));
}

test "moveLines stops at the first and last line" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("aaaa\nb\ncccc\ndddd");
    buf.cursor = 3; // line 0, column 3
    try testing.expectEqual(2, buf.moveLines(true, 2));
    try testing.expectEqual(2, buf.cursorLine());
    try testing.expectEqual(10, buf.cursor); // column 3 again, after "b"
    try testing.expectEqual(1, buf.moveLines(true, 5)); // only 1 line left
    try testing.expectEqual(0, buf.moveLines(true, 1));
    try testing.expectEqual(3, buf.moveLines(false, 10));
    try testing.expectEqual(3, buf.cursor);
}

test "goal column counts codepoints" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("éé\nabc");
    buf.cursor = 4; // after "éé", column 2
    buf.nextLine();
    try testing.expectEqual(7, buf.cursor); // "ab|c"
    buf.previousLine();
    try testing.expectEqual(4, buf.cursor);
}
