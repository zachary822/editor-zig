//! Emacs-style key bindings: chords, prefix keymaps and a dispatcher.
//!
//! A keymap maps a chord to a command or to one more keymap (a prefix key).
//! The dispatcher reads one key event at a time and walks the keymap tree.
//! Bindings use Emacs notation, for example "C-x C-s", "M-x" and "<up>".

const std = @import("std");
const testing = std.testing;
const keys = @import("keys.zig");

/// One key with its modifiers, normalized so that it can be compared.
pub const Chord = struct {
    key: keys.Key,
    ctrl: bool = false,
    alt: bool = false, // Emacs "M-"
    shift: bool = false,
    super: bool = false,

    pub fn from(ev: keys.KeyEvent) Chord {
        return normalize(.{
            .key = ev.key,
            .ctrl = ev.mods.ctrl,
            .alt = ev.mods.alt or ev.mods.meta,
            .shift = ev.mods.shift,
            .super = ev.mods.super,
        });
    }

    pub fn eql(a: Chord, b: Chord) bool {
        return std.meta.eql(a, b);
    }

    /// True for a key that types text: a codepoint without ctrl, alt or super.
    pub fn isPrintable(self: Chord) bool {
        if (self.ctrl or self.alt or self.super) return false;
        return switch (self.key) {
            .codepoint => |cp| cp >= 0x20 and cp != 0x7f,
            else => false,
        };
    }
};

/// Legacy terminals send "A" for shift+a, and Kitty sends "a" with shift for
/// ctrl+shift+a. Both become "a" with shift, so "A" and "S-a" are the same key.
fn normalize(chord: Chord) Chord {
    var out = chord;
    switch (out.key) {
        .codepoint => |cp| if (cp >= 'A' and cp <= 'Z') {
            out.key = .{ .codepoint = cp + ('a' - 'A') };
            out.shift = true;
        },
        else => {},
    }
    return out;
}

const esc: Chord = .{ .key = .{ .codepoint = 0x1b } };
const cancel: Chord = .{ .key = .{ .codepoint = 'g' }, .ctrl = true };

pub const ParseError = error{ EmptySequence, TooManyKeys, InvalidModifier, UnknownKey };

/// Parses Emacs key notation, for example "C-x C-s", into `buf`.
pub fn parseKeys(text: []const u8, buf: []Chord) ParseError![]Chord {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n == buf.len) return error.TooManyKeys;
        buf[n] = try parseChord(tok);
        n += 1;
    }
    if (n == 0) return error.EmptySequence;
    return buf[0..n];
}

/// Parses one chord, for example "C-M-f", "<up>", "RET" or "C--".
pub fn parseChord(tok: []const u8) ParseError!Chord {
    var chord: Chord = .{ .key = undefined };
    var rest = tok;
    while (rest.len > 2 and rest[1] == '-') : (rest = rest[2..]) {
        switch (rest[0]) {
            'C' => chord.ctrl = true,
            'M' => chord.alt = true,
            'S' => chord.shift = true,
            's' => chord.super = true,
            else => return error.InvalidModifier,
        }
    }
    if (rest.len == 0) return error.UnknownKey;

    if (rest.len > 2 and rest[0] == '<' and rest[rest.len - 1] == '>') {
        chord.key = namedKey(rest[1 .. rest.len - 1]) orelse return error.UnknownKey;
    } else if (namedKey(rest)) |key| {
        chord.key = key;
    } else {
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.UnknownKey;
        if (n != rest.len) return error.UnknownKey;
        const cp = std.unicode.utf8Decode(rest) catch return error.UnknownKey;
        chord.key = .{ .codepoint = cp };
    }
    return normalize(chord);
}

fn namedKey(name: []const u8) ?keys.Key {
    const Named = struct { []const u8, keys.Key };
    const table = [_]Named{
        .{ "RET", .{ .codepoint = 0x0d } },    .{ "return", .{ .codepoint = 0x0d } },
        .{ "TAB", .{ .codepoint = 0x09 } },    .{ "tab", .{ .codepoint = 0x09 } },
        .{ "ESC", .{ .codepoint = 0x1b } },    .{ "escape", .{ .codepoint = 0x1b } },
        .{ "DEL", .{ .codepoint = 0x7f } },    .{ "backspace", .{ .codepoint = 0x7f } },
        .{ "SPC", .{ .codepoint = ' ' } },     .{ "space", .{ .codepoint = ' ' } },
        .{ "up", .up },                        .{ "down", .down },
        .{ "left", .left },                    .{ "right", .right },
        .{ "home", .home },                    .{ "end", .end },
        .{ "insert", .insert },                .{ "delete", .delete },
        .{ "prior", .page_up },                .{ "next", .page_down },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    if (name.len >= 2 and name[0] == 'f') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return .{ .f = n };
    }
    return null;
}

/// A tree of bindings. `Command` is the caller's command type.
pub fn Keymap(comptime Command: type) type {
    return struct {
        const Self = @This();

        pub const Binding = union(enum) {
            command: Command,
            prefix: *Self,
        };

        map: std.AutoHashMapUnmanaged(Chord, Binding) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |b| freeBinding(gpa, b.*);
            self.map.deinit(gpa);
        }

        fn freeBinding(gpa: std.mem.Allocator, b: Binding) void {
            switch (b) {
                .command => {},
                .prefix => |sub| {
                    sub.deinit(gpa);
                    gpa.destroy(sub);
                },
            }
        }

        pub fn get(self: *const Self, chord: Chord) ?Binding {
            return self.map.get(chord);
        }

        /// Binds a key sequence to a command. A later binding replaces an
        /// earlier one. If a key in the middle of the sequence is a command,
        /// it becomes a prefix key.
        pub fn bind(self: *Self, gpa: std.mem.Allocator, seq: []const Chord, cmd: Command) !void {
            if (seq.len == 0) return error.EmptySequence;
            var map = self;
            for (seq[0 .. seq.len - 1]) |chord| {
                const gop = try map.map.getOrPut(gpa, chord);
                if (gop.found_existing and gop.value_ptr.* == .prefix) {
                    map = gop.value_ptr.prefix;
                    continue;
                }
                const sub = gpa.create(Self) catch |err| {
                    if (!gop.found_existing) map.map.removeByPtr(gop.key_ptr);
                    return err;
                };
                sub.* = .{};
                gop.value_ptr.* = .{ .prefix = sub };
                map = sub;
            }
            const gop = try map.map.getOrPut(gpa, seq[seq.len - 1]);
            if (gop.found_existing) freeBinding(gpa, gop.value_ptr.*);
            gop.value_ptr.* = .{ .command = cmd };
        }

        /// Binds a key sequence in Emacs notation, for example "C-x C-s".
        pub fn bindKeys(self: *Self, gpa: std.mem.Allocator, notation: []const u8, cmd: Command) !void {
            var buf: [16]Chord = undefined;
            try self.bind(gpa, try parseKeys(notation, &buf), cmd);
        }
    };
}

/// Reads key events and walks a keymap tree. The caller runs the commands.
pub fn Dispatcher(comptime Command: type) type {
    return struct {
        const Self = @This();
        const Map = Keymap(Command);

        pub const Action = union(enum) {
            /// Run this command. The sequence is complete.
            run: Command,
            /// The key started or continued a prefix. Wait for more keys.
            prefix,
            /// C-g cancelled the sequence.
            cancel,
            /// The sequence has no binding.
            unbound: Chord,
            /// The event is a key release.
            ignored,
        };

        root: *const Map,
        current: ?*const Map = null,
        /// ESC was pressed. The next key gets the alt modifier.
        meta: bool = false,

        pub fn init(root: *const Map) Self {
            return .{ .root = root };
        }

        pub fn reset(self: *Self) void {
            self.current = null;
            self.meta = false;
        }

        /// True while the dispatcher waits for more keys of a sequence.
        pub fn isPending(self: *const Self) bool {
            return self.current != null or self.meta;
        }

        pub fn feed(self: *Self, ev: keys.KeyEvent) Action {
            if (ev.kind == .release) return .ignored;
            var chord = Chord.from(ev);
            if (self.meta) {
                chord.alt = true;
                self.meta = false;
            }

            if (chord.eql(cancel)) {
                self.reset();
                return .cancel;
            }

            const map = self.current orelse self.root;
            if (map.get(chord)) |b| switch (b) {
                .prefix => |next| {
                    self.current = next;
                    return .prefix;
                },
                .command => |cmd| {
                    self.reset();
                    return .{ .run = cmd };
                },
            };

            // As in Emacs, an unbound ESC is a prefix that means Meta. Legacy
            // terminals send alt+x as ESC and then x.
            if (self.current == null and chord.eql(esc)) {
                self.meta = true;
                return .prefix;
            }

            self.reset();
            return .{ .unbound = chord };
        }
    };
}

// Tests

fn press(cp: u21, mods: keys.Mods) keys.KeyEvent {
    return .{ .key = .{ .codepoint = cp }, .mods = mods };
}

test "parseKeys reads Emacs notation" {
    var buf: [4]Chord = undefined;

    const save = try parseKeys("C-x C-s", &buf);
    try testing.expectEqual(2, save.len);
    try testing.expect(save[0].eql(.{ .key = .{ .codepoint = 'x' }, .ctrl = true }));
    try testing.expect(save[1].eql(.{ .key = .{ .codepoint = 's' }, .ctrl = true }));

    try testing.expect((try parseChord("C-M-f")).eql(.{ .key = .{ .codepoint = 'f' }, .ctrl = true, .alt = true }));
    try testing.expect((try parseChord("<up>")).eql(.{ .key = .up }));
    try testing.expect((try parseChord("S-<f5>")).eql(.{ .key = .{ .f = 5 }, .shift = true }));
    try testing.expect((try parseChord("RET")).eql(.{ .key = .{ .codepoint = 0x0d } }));
    try testing.expect((try parseChord("C--")).eql(.{ .key = .{ .codepoint = '-' }, .ctrl = true }));
    try testing.expect((try parseChord("é")).eql(.{ .key = .{ .codepoint = 'é' } }));
}

test "uppercase and shift are the same key" {
    try testing.expect((try parseChord("A")).eql(try parseChord("S-a")));
    try testing.expect((try parseChord("C-A")).eql(try parseChord("C-S-a")));
    try testing.expect(Chord.from(press('A', .{})).eql(try parseChord("S-a")));
    try testing.expect(Chord.from(press('a', .{ .ctrl = true, .shift = true })).eql(try parseChord("C-A")));
}

test "parseKeys rejects bad notation" {
    var buf: [2]Chord = undefined;
    try testing.expectError(error.EmptySequence, parseKeys("   ", &buf));
    try testing.expectError(error.TooManyKeys, parseKeys("a b c", &buf));
    try testing.expectError(error.InvalidModifier, parseKeys("X-a", &buf));
    try testing.expectError(error.UnknownKey, parseKeys("<nope>", &buf));
    try testing.expectError(error.UnknownKey, parseKeys("ab", &buf));
}

const TestCmd = enum { save, quit, up, other };

test "dispatcher follows prefix keys" {
    const gpa = testing.allocator;
    var km: Keymap(TestCmd) = .{};
    defer km.deinit(gpa);
    try km.bindKeys(gpa, "C-x C-s", .save);
    try km.bindKeys(gpa, "C-x C-c", .quit);
    try km.bindKeys(gpa, "<up>", .up);

    var d: Dispatcher(TestCmd) = .init(&km);
    try testing.expectEqual(.prefix, d.feed(press('x', .{ .ctrl = true })));
    try testing.expect(d.isPending());
    try testing.expectEqual(TestCmd.save, d.feed(press('s', .{ .ctrl = true })).run);
    try testing.expect(!d.isPending());

    try testing.expectEqual(TestCmd.up, d.feed(.{ .key = .up }).run);
    try testing.expectEqual(.ignored, d.feed(.{ .key = .up, .kind = .release }));
    try testing.expectEqual(TestCmd.up, d.feed(.{ .key = .up, .kind = .repeat }).run);
}

test "dispatcher cancels and reports unbound keys" {
    const gpa = testing.allocator;
    var km: Keymap(TestCmd) = .{};
    defer km.deinit(gpa);
    try km.bindKeys(gpa, "C-x C-s", .save);

    var d: Dispatcher(TestCmd) = .init(&km);
    _ = d.feed(press('x', .{ .ctrl = true }));
    try testing.expectEqual(.cancel, d.feed(press('g', .{ .ctrl = true })));
    try testing.expect(!d.isPending());

    _ = d.feed(press('x', .{ .ctrl = true }));
    const a = d.feed(press('q', .{}));
    try testing.expect(a.unbound.eql(.{ .key = .{ .codepoint = 'q' } }));
    try testing.expect(!d.isPending());

    try testing.expect(d.feed(press('z', .{})).unbound.isPrintable());
}

test "ESC then a key is the same as alt" {
    const gpa = testing.allocator;
    var km: Keymap(TestCmd) = .{};
    defer km.deinit(gpa);
    try km.bindKeys(gpa, "M-x", .other);

    var d: Dispatcher(TestCmd) = .init(&km);
    try testing.expectEqual(TestCmd.other, d.feed(press('x', .{ .alt = true })).run);
    try testing.expectEqual(.prefix, d.feed(press(0x1b, .{})));
    try testing.expectEqual(TestCmd.other, d.feed(press('x', .{})).run);
}

test "later bindings replace earlier ones" {
    const gpa = testing.allocator;
    var km: Keymap(TestCmd) = .{};
    defer km.deinit(gpa);

    try km.bindKeys(gpa, "C-c", .quit);
    try km.bindKeys(gpa, "C-c a", .save); // C-c becomes a prefix
    try km.bindKeys(gpa, "C-c", .up); // the prefix becomes a command again

    var d: Dispatcher(TestCmd) = .init(&km);
    try testing.expectEqual(TestCmd.up, d.feed(press('c', .{ .ctrl = true })).run);
}
