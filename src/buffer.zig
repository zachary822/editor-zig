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
    /// The kind of the last edit, for undo groups. Movement clears it.
    last_edit: ?EditKind = null,
    group_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Buffer {
        return .{ .rope = .init(gpa) };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.undo_stack.items) |entry| self.rope.release(entry.snap);
        self.undo_stack.deinit(self.rope.gpa);
        self.rope.deinit();
        self.* = undefined;
    }

    pub fn len(self: *const Buffer) usize {
        return self.rope.len();
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
        try self.rope.insert(self.cursor, text);
        self.cursor += text.len;
        self.goal_col = null;
    }

    /// Deletes the codepoint before the cursor.
    pub fn deleteBackward(self: *Buffer) !void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary(self.cursor);
        try self.recordUndo(.delete_backward);
        try self.rope.delete(start, self.cursor - start);
        self.cursor = start;
        self.goal_col = null;
    }

    /// Deletes the codepoint at the cursor.
    pub fn deleteForward(self: *Buffer) !void {
        if (self.cursor == self.len()) return;
        const end = self.nextBoundary(self.cursor);
        try self.recordUndo(.delete_forward);
        try self.rope.delete(self.cursor, end - self.cursor);
        self.goal_col = null;
    }

    /// Deletes from the cursor to the end of the line, as Emacs `kill-line`
    /// does. If only spaces and tabs come after the cursor, it also deletes
    /// the newline. Thus on an empty line, it joins the next line.
    pub fn killLine(self: *Buffer) !void {
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
        if (stop == self.cursor) return;
        try self.recordUndo(.other);
        try self.rope.delete(self.cursor, stop - self.cursor);
        self.goal_col = null;
    }

    // Undo

    /// Puts the text and cursor back to how they were before the last undo
    /// step. Each undo goes one more step back. There is no redo.
    pub fn undo(self: *Buffer) error{NothingToUndo}!void {
        const entry = self.undo_stack.pop() orelse return error.NothingToUndo;
        self.rope.restore(entry.snap);
        self.rope.release(entry.snap);
        self.cursor = entry.cursor;
        self.goal_col = null;
        self.last_edit = null;
    }

    /// Saves the text before an edit, unless the edit continues a group.
    fn recordUndo(self: *Buffer, kind: EditKind) !void {
        if (kind != .other and self.last_edit == kind and self.group_len < max_group) {
            self.group_len += 1;
            return;
        }
        const gpa = self.rope.gpa;
        if (self.undo_stack.items.len == max_undo) {
            self.rope.release(self.undo_stack.orderedRemove(0).snap);
        }
        const snap = self.rope.snapshot();
        self.undo_stack.append(gpa, .{ .snap = snap, .cursor = self.cursor }) catch |err| {
            self.rope.release(snap);
            return err;
        };
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

    /// Horizontal movement clears the goal column and ends an undo group.
    fn moved(self: *Buffer) void {
        self.goal_col = null;
        self.last_edit = null;
    }

    // Queries

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

test "killLine deletes to the end of the line, then the newline" {
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insert("hello world\nnext\n  \nlast");
    buf.cursor = 5;
    try buf.killLine();
    try expectText(&buf, "hello\nnext\n  \nlast");
    try buf.killLine(); // at line end: join the next line
    try expectText(&buf, "hellonext\n  \nlast");

    buf.cursor = 10; // start of "  " line
    try buf.killLine(); // only blanks: delete them and the newline
    try expectText(&buf, "hellonext\nlast");

    buf.cursor = buf.len();
    try buf.killLine(); // end of buffer: nothing to delete
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
    try buf.killLine();
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
