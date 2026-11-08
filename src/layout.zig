//! The window layout: a tree of splits, as Emacs window splits.
//!
//! The tree holds window IDs only. The editor owns the windows. `rects`
//! computes the screen rectangle of each window and the positions of the
//! vertical separators between side-by-side windows.

const std = @import("std");
const testing = std.testing;

pub const Rect = struct {
    row: usize = 0,
    col: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
};

pub const Dir = enum {
    /// One window above the other (Emacs C-x 2, `split-window-below`).
    below,
    /// One window next to the other (Emacs C-x 3, `split-window-right`).
    right,
};

const Node = union(enum) {
    leaf: u32,
    split: struct { dir: Dir, first: *Node, second: *Node },
};

/// A vertical line between two side-by-side windows.
pub const Separator = struct { row: usize, col: usize, rows: usize };

pub const Placed = struct { id: u32, rect: Rect };

pub const Layout = struct {
    gpa: std.mem.Allocator,
    root: *Node,

    pub fn init(gpa: std.mem.Allocator, first: u32) !Layout {
        const root = try gpa.create(Node);
        root.* = .{ .leaf = first };
        return .{ .gpa = gpa, .root = root };
    }

    pub fn deinit(self: *Layout) void {
        self.freeNode(self.root);
        self.* = undefined;
    }

    fn freeNode(self: *Layout, n: *Node) void {
        switch (n.*) {
            .leaf => {},
            .split => |s| {
                self.freeNode(s.first);
                self.freeNode(s.second);
            },
        }
        self.gpa.destroy(n);
    }

    /// Splits the window `id` in two halves. The new window `new_id` goes
    /// below or to the right.
    pub fn split(self: *Layout, id: u32, new_id: u32, dir: Dir) !void {
        const leaf = findLeaf(self.root, id) orelse return error.NoSuchWindow;
        const first = try self.gpa.create(Node);
        errdefer self.gpa.destroy(first);
        const second = try self.gpa.create(Node);
        first.* = .{ .leaf = id };
        second.* = .{ .leaf = new_id };
        leaf.* = .{ .split = .{ .dir = dir, .first = first, .second = second } };
    }

    /// Removes the window `id`. Its sibling takes its space. The last window
    /// cannot go.
    pub fn remove(self: *Layout, id: u32) !void {
        if (self.root.* == .leaf) {
            return if (self.root.leaf == id) error.LastWindow else error.NoSuchWindow;
        }
        const parent = findParent(self.root, id) orelse return error.NoSuchWindow;
        const s = parent.split;
        const gone, const kept = if (s.first.* == .leaf and s.first.leaf == id) .{ s.first, s.second } else .{ s.second, s.first };
        parent.* = kept.*;
        self.gpa.destroy(gone);
        self.gpa.destroy(kept);
    }

    /// Makes `id` the only window. Gives the IDs of the other windows in
    /// `removed`, so the caller can free them.
    pub fn only(self: *Layout, id: u32, removed: *std.ArrayList(u32)) !void {
        if (findLeaf(self.root, id) == null) return error.NoSuchWindow;
        var all: std.ArrayList(u32) = .empty;
        defer all.deinit(self.gpa);
        try self.leaves(&all);
        for (all.items) |w| if (w != id) try removed.append(self.gpa, w);
        const root = try self.gpa.create(Node);
        root.* = .{ .leaf = id };
        self.freeNode(self.root);
        self.root = root;
    }

    /// The window IDs in screen order: top to bottom, left to right.
    pub fn leaves(self: *const Layout, out: *std.ArrayList(u32)) !void {
        try collect(self.root, self.gpa, out);
    }

    pub fn contains(self: *const Layout, id: u32) bool {
        return findLeaf(self.root, id) != null;
    }

    /// Computes the rectangle of each window in `area`. Each half of a split
    /// gets half of the space, and the first half gets the smaller half. A
    /// side-by-side split puts a one-column separator between the halves.
    pub fn rects(self: *const Layout, area: Rect, out: *std.ArrayList(Placed), seps: *std.ArrayList(Separator)) !void {
        try place(self.root, area, self.gpa, out, seps);
    }
};

fn findLeaf(n: *Node, id: u32) ?*Node {
    return switch (n.*) {
        .leaf => |w| if (w == id) n else null,
        .split => |s| findLeaf(s.first, id) orelse findLeaf(s.second, id),
    };
}

fn findParent(n: *Node, id: u32) ?*Node {
    switch (n.*) {
        .leaf => return null,
        .split => |s| {
            for ([_]*Node{ s.first, s.second }) |child| {
                if (child.* == .leaf and child.leaf == id) return n;
            }
            return findParent(s.first, id) orelse findParent(s.second, id);
        },
    }
}

fn collect(n: *const Node, gpa: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
    switch (n.*) {
        .leaf => |w| try out.append(gpa, w),
        .split => |s| {
            try collect(s.first, gpa, out);
            try collect(s.second, gpa, out);
        },
    }
}

fn place(n: *const Node, area: Rect, gpa: std.mem.Allocator, out: *std.ArrayList(Placed), seps: *std.ArrayList(Separator)) !void {
    switch (n.*) {
        .leaf => |w| try out.append(gpa, .{ .id = w, .rect = area }),
        .split => |s| switch (s.dir) {
            .below => {
                const top = area.rows / 2;
                try place(s.first, .{ .row = area.row, .col = area.col, .rows = top, .cols = area.cols }, gpa, out, seps);
                try place(s.second, .{ .row = area.row + top, .col = area.col, .rows = area.rows - top, .cols = area.cols }, gpa, out, seps);
            },
            .right => {
                // One column for the separator.
                const usable = area.cols -| 1;
                const left = usable / 2;
                try place(s.first, .{ .row = area.row, .col = area.col, .rows = area.rows, .cols = left }, gpa, out, seps);
                if (area.cols > 0) try seps.append(gpa, .{ .row = area.row, .col = area.col + left, .rows = area.rows });
                try place(s.second, .{ .row = area.row, .col = area.col + left + 1, .rows = area.rows, .cols = usable - left }, gpa, out, seps);
            },
        },
    }
}

fn layoutOf(l: *const Layout, area: Rect) !struct { placed: std.ArrayList(Placed), seps: std.ArrayList(Separator) } {
    var placed: std.ArrayList(Placed) = .empty;
    var seps: std.ArrayList(Separator) = .empty;
    try l.rects(area, &placed, &seps);
    return .{ .placed = placed, .seps = seps };
}

test "split below, then right, and the rectangles" {
    var l = try Layout.init(testing.allocator, 1);
    defer l.deinit();
    try l.split(1, 2, .below);
    try l.split(2, 3, .right);

    var r = try layoutOf(&l, .{ .rows = 20, .cols = 81 });
    defer r.placed.deinit(testing.allocator);
    defer r.seps.deinit(testing.allocator);
    try testing.expectEqual(3, r.placed.items.len);
    try testing.expectEqual(Placed{ .id = 1, .rect = .{ .row = 0, .col = 0, .rows = 10, .cols = 81 } }, r.placed.items[0]);
    try testing.expectEqual(Placed{ .id = 2, .rect = .{ .row = 10, .col = 0, .rows = 10, .cols = 40 } }, r.placed.items[1]);
    try testing.expectEqual(Placed{ .id = 3, .rect = .{ .row = 10, .col = 41, .rows = 10, .cols = 40 } }, r.placed.items[2]);
    try testing.expectEqual(1, r.seps.items.len);
    try testing.expectEqual(Separator{ .row = 10, .col = 40, .rows = 10 }, r.seps.items[0]);
}

test "remove gives the space to the sibling" {
    var l = try Layout.init(testing.allocator, 1);
    defer l.deinit();
    try testing.expectError(error.LastWindow, l.remove(1));
    try l.split(1, 2, .right);
    try l.split(1, 3, .below);
    try l.remove(1);

    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(testing.allocator);
    try l.leaves(&ids);
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, ids.items);
    try l.remove(2);
    ids.clearRetainingCapacity();
    try l.leaves(&ids);
    try testing.expectEqualSlices(u32, &.{3}, ids.items);
    try testing.expectError(error.NoSuchWindow, l.remove(9));
}

test "only keeps one window and reports the others" {
    var l = try Layout.init(testing.allocator, 1);
    defer l.deinit();
    try l.split(1, 2, .below);
    try l.split(2, 3, .right);
    var removed: std.ArrayList(u32) = .empty;
    defer removed.deinit(testing.allocator);
    try l.only(3, &removed);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, removed.items);
    try testing.expect(l.contains(3));
    try testing.expect(!l.contains(1));
}
