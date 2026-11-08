const std = @import("std");
const testing = std.testing;

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

pub const Kind = enum { press, repeat, release };

pub const Key = union(enum) {
    codepoint: u21,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    f: u8, // F1 to F12
};

pub const KeyEvent = struct {
    key: Key,
    mods: Mods = .{},
    kind: Kind = .press,
    shifted: ?u21 = null,
    base: ?u21 = null,
};

pub const Result = union(enum) {
    key: struct { event: KeyEvent, len: usize },
    other: usize,
    incomplete,
    invalid: usize,
};

const max_seq = 64;

pub fn parse(bytes: []const u8) Result {
    if (bytes.len == 0) return .incomplete;
    if (bytes[0] != 0x1b) return parsePlain(bytes);
    if (bytes.len == 1) return .incomplete; // lone ESC
    return switch (bytes[1]) {
        '[' => parseCsi(bytes),
        'O' => parseSs3(bytes),
        // legacy alt+key. with kitty flag 1, the terminal does not send this form.
        else => .{ .key = .{ .event = .{ .key = .{ .codepoint = 0x1b } }, .len = 1 } },
    };
}

fn parseCsi(bytes: []const u8) Result {
    var fields: [3][3]u32 = @splat(@splat(0));
    var f: usize = 0;
    var s: usize = 0;
    var private = false;

    var i: usize = 2;
    const final: u8 = while (i < bytes.len and i < max_seq) : (i += 1) {
        const b = bytes[i];
        switch (b) {
            '0'...'9' => if (f < fields.len and s < fields[f].len) {
                const v = &fields[f][s];
                v.* = v.* *| 10 +| (b - '0');
            },
            ':' => s += 1,
            ';' => {
                f += 1;
                s = 0;
            },
            '<', '=', '>', '?' => private = true,
            0x40...0x7e => break b,
            else => return .{ .invalid = i + 1 },
        }
    } else {
        return if (i >= max_seq) .{ .invalid = i } else .incomplete;
    };
    const len = i + 1;

    if (private) return .{ .other = len };

    const key: Key = switch (final) {
        'u' => .{ .codepoint = std.math.cast(u21, fields[0][0]) orelse return .{ .invalid = len } },
        '~' => tildeKey(fields[0][0]) orelse return .{ .other = len },
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'S' => .{ .f = 4 },
        else => return .{ .other = len },
    };

    const m = fields[1][0];
    return .{ .key = .{ .len = len, .event = .{
        .key = key,
        .mods = if (m > 1) @bitCast(@as(u8, @truncate(m - 1))) else .{},
        .kind = switch (fields[1][1]) {
            2 => .repeat,
            3 => .release,
            else => .press,
        },
        .shifted = if (final == 'u') nonzero(fields[0][1]) else null,
        .base = if (final == 'u') nonzero(fields[0][2]) else null,
    } } };
}

fn tildeKey(n: u32) ?Key {
    return switch (n) {
        2 => .insert,
        3 => .delete,
        5 => .page_up,
        6 => .page_down,
        7 => .home,
        8 => .end,
        11...15 => .{ .f = @intCast(n - 10) }, // f1 to f5
        17...21 => .{ .f = @intCast(n - 11) }, // f6 to f10
        23, 24 => .{ .f = @intCast(n - 12) }, // f11 to f12
        else => null,
    };
}

fn parseSs3(bytes: []const u8) Result {
    if (bytes.len < 3) return .incomplete;
    const key: Key = switch (bytes[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        'R' => .{ .f = 3 },
        'S' => .{ .f = 4 },
        else => return .{ .invalid = 3 },
    };
    return .{ .key = .{ .event = .{ .key = key }, .len = 3 } };
}

fn parsePlain(bytes: []const u8) Result {
    const b = bytes[0];
    const event: KeyEvent = switch (b) {
        0x00 => .{ .key = .{ .codepoint = ' ' }, .mods = .{ .ctrl = true } },
        0x08 => .{ .key = .{ .codepoint = 127 }, .mods = .{ .ctrl = true } },
        0x09, 0x0d, 0x7f => .{ .key = .{ .codepoint = b } },
        0x01...0x07, 0x0a...0x0c, 0x0e...0x1a => .{
            .key = .{ .codepoint = 'a' + b - 1 },
            .mods = .{ .ctrl = true },
        },
        // Terminals send 0x1f for both ctrl+/ and ctrl+_. Emacs reads it as C-/.
        0x1f => .{ .key = .{ .codepoint = '/' }, .mods = .{ .ctrl = true } },
        0x20...0x7e => .{ .key = .{ .codepoint = b } },
        0x80...0xff => {
            const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .invalid = 1 };
            if (bytes.len < n) return .incomplete;
            const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .invalid = n };
            return .{ .key = .{ .event = .{ .key = .{ .codepoint = cp } }, .len = n } };
        },
        else => return .{ .invalid = 1 },
    };
    return .{ .key = .{ .event = event, .len = 1 } };
}

fn nonzero(v: u32) ?u21 {
    return if (v == 0) null else std.math.cast(u21, v);
}

test "Esc" {
    const r = parse("\x1b[27u");
    try testing.expectEqual(@as(u21, 27), r.key.event.key.codepoint);
    try testing.expectEqual(@as(usize, 5), r.key.len);
}

test "Ctrl+C" {
    const r = parse("\x1b[99;5u");
    try testing.expectEqual(@as(u21, 'c'), r.key.event.key.codepoint);
    try testing.expect(r.key.event.mods.ctrl);
}

test "legacy Ctrl+/ is 0x1f" {
    const r = parse("\x1f");
    try testing.expectEqual(@as(u21, '/'), r.key.event.key.codepoint);
    try testing.expect(r.key.event.mods.ctrl);
}

test "Ctrl+Delete" {
    const r = parse("\x1b[3;5~");
    try testing.expect(r.key.event.key == .delete);
    try testing.expect(r.key.event.mods.ctrl);
}

test "Delete release" {
    const r = parse("\x1b[3;1:3~");
    try testing.expectEqual(Kind.release, r.key.event.kind);
}

test "incomplete sequence" {
    try testing.expect(parse("\x1b[99;5") == .incomplete);
}

test "query reply is not a key" {
    try testing.expectEqual(@as(usize, 5), parse("\x1b[?1u").other);
}
