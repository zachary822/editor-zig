//! The Emacs prefix argument: C-u, C-u C-u, C-u 12, C-u -, M-5 and M--.
//!
//! The editor keeps a `PrefixArg` while the user types it, and gives it to
//! the next command.

const std = @import("std");
const testing = std.testing;

/// The largest count that the editor accepts.
pub const max_count = 1_000_000;

pub const PrefixArg = struct {
    value: i64 = 4,
    /// True for C-u without digits or "-". Some commands do something
    /// different for a raw C-u, for example C-u C-y.
    raw: bool = true,
    negative: bool = false,
    /// True after the first digit.
    digits: bool = false,
    /// False after a C-u that comes after digits. Then the next digits are
    /// normal text, so "C-u 5 C-u 1" inserts "11111".
    accepting: bool = true,

    /// C-u. Starts an argument of 4, or multiplies a raw argument by 4.
    pub fn universal(current: ?PrefixArg) PrefixArg {
        var arg = current orelse return .{};
        if (arg.digits or arg.negative) {
            arg.accepting = false;
        } else {
            arg.value = @min(arg.value * 4, max_count + 1);
        }
        return arg;
    }

    /// M-0 to M-9: starts an argument with a digit, or adds a digit.
    pub fn digitArgument(current: ?PrefixArg, d: u4) PrefixArg {
        var arg = current orelse PrefixArg{ .value = 0, .raw = false };
        arg.accepting = true;
        arg.addDigit(d);
        return arg;
    }

    /// M--: starts a negative argument, or changes the sign.
    pub fn negativeArgument(current: ?PrefixArg) PrefixArg {
        var arg = current orelse PrefixArg{ .value = 0, .raw = false };
        arg.accepting = true;
        arg.addMinus();
        return arg;
    }

    /// Adds a typed digit. The caller makes sure that `accepting` is true.
    pub fn addDigit(self: *PrefixArg, d: u4) void {
        self.value = if (self.digits) @min(self.value * 10 + d, max_count + 1) else d;
        self.digits = true;
        self.raw = false;
    }

    /// Adds a typed "-". It changes the sign only before the digits.
    pub fn addMinus(self: *PrefixArg) void {
        self.negative = !self.negative;
        self.raw = false;
    }

    /// True if a typed character belongs to the argument, not to the text.
    pub fn takesChar(self: PrefixArg, cp: u21) bool {
        if (!self.accepting) return false;
        if (cp >= '0' and cp <= '9') return true;
        return cp == '-' and !self.digits;
    }

    /// The signed count. "C-u -" alone is -1, as in Emacs.
    pub fn count(self: PrefixArg) i64 {
        if (self.negative and !self.digits) return -1;
        return if (self.negative) -self.value else self.value;
    }
};

test "C-u gives 4, and each more C-u multiplies by 4" {
    var arg = PrefixArg.universal(null);
    try testing.expectEqual(4, arg.count());
    try testing.expect(arg.raw);
    arg = PrefixArg.universal(arg);
    try testing.expectEqual(16, arg.count());
    arg = PrefixArg.universal(arg);
    try testing.expectEqual(64, arg.count());
}

test "digits after C-u replace the 4" {
    var arg = PrefixArg.universal(null);
    try testing.expect(arg.takesChar('1'));
    arg.addDigit(1);
    arg.addDigit(2);
    try testing.expectEqual(12, arg.count());
    try testing.expect(!arg.raw);
    try testing.expect(!arg.takesChar('-')); // "-" only before the digits
    try testing.expect(!arg.takesChar('x'));

    // A C-u after the digits ends the number. The next digits are text.
    arg = PrefixArg.universal(arg);
    try testing.expectEqual(12, arg.count());
    try testing.expect(!arg.takesChar('3'));
}

test "minus signs" {
    var arg = PrefixArg.universal(null);
    arg.addMinus();
    try testing.expectEqual(-1, arg.count()); // C-u -
    arg.addDigit(3);
    try testing.expectEqual(-3, arg.count()); // C-u - 3

    arg = PrefixArg.negativeArgument(null);
    try testing.expectEqual(-1, arg.count()); // M--
    arg = PrefixArg.digitArgument(arg, 5);
    try testing.expectEqual(-5, arg.count()); // M-- M-5
}

test "M-digits make a number" {
    var arg = PrefixArg.digitArgument(null, 5);
    arg = PrefixArg.digitArgument(arg, 3);
    try testing.expectEqual(53, arg.count());
    try testing.expectEqual(0, PrefixArg.digitArgument(null, 0).count());
}

test "large numbers stop above the maximum" {
    var arg = PrefixArg.digitArgument(null, 9);
    for (0..20) |_| arg.addDigit(9);
    try testing.expect(arg.count() > max_count);
    try testing.expect(arg.count() <= max_count + 1);
}
