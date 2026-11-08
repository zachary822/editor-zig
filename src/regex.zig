//! A small backtracking pattern matcher for tree-sitter query predicates
//! (`#match?` and `#lua-match?`).
//!
//! It supports the subset that highlight queries use:
//! - `^` and `$` anchors
//! - `.`, literal bytes and escaped bytes (`\.` or `%.` in Lua syntax)
//! - classes: `\d \w \s \a \l \u \x \p` (or `%d`, `%w` and so on in Lua syntax)
//! - sets: `[A-Z_0-9]`, `[^...]`, with classes inside
//! - the quantifiers `*`, `+` and `?` (greedy) after a single atom
//! - groups `( ... )` with alternatives `a|b` (regex syntax), for example
//!   `^(abs|all|any)$`. Groups can nest 8 levels deep. A quantifier after a
//!   group is not supported.
//!
//! It matches bytes. A pattern that it cannot read is an error, so the caller
//! can disable the query pattern.

const std = @import("std");
const testing = std.testing;

pub const Syntax = enum { regex, lua };

pub const Error = error{InvalidPattern};

const max_depth = 8;

/// Makes sure that the pattern uses only the supported subset.
pub fn validate(pattern: []const u8, syntax: Syntax) Error!void {
    var alts = alternatives(pattern, syntax);
    while (alts.next()) |alt| {
        const body = if (std.mem.startsWith(u8, alt, "^")) alt[1..] else alt;
        try validateSeq(body, syntax, 0);
    }
}

fn validateSeq(p: []const u8, syntax: Syntax, depth: usize) Error!void {
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] == '$' and i == p.len - 1) return;
        if (p[i] == '(') {
            if (depth + 1 >= max_depth) return error.InvalidPattern;
            const close = try matchingParen(p[i..], syntax);
            var alts = alternatives(p[i + 1 .. i + close], syntax);
            while (alts.next()) |alt| try validateSeq(alt, syntax, depth + 1);
            i += close + 1;
            if (i < p.len and isQuantifier(p[i])) return error.InvalidPattern;
            continue;
        }
        if (p[i] == ')' or (syntax == .regex and p[i] == '|')) return error.InvalidPattern;
        i += try atomLen(p[i..], syntax);
        if (i < p.len and isQuantifier(p[i])) i += 1;
    }
}

/// True if the pattern matches a part of `text` (or the start of `text` if
/// the pattern starts with `^`). Call `validate` first.
pub fn isMatch(pattern: []const u8, syntax: Syntax, text: []const u8) bool {
    var alts = alternatives(pattern, syntax);
    while (alts.next()) |alt| {
        if (std.mem.startsWith(u8, alt, "^")) {
            if (matchHere(alt[1..], &.{}, syntax, text, 0)) return true;
            continue;
        }
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (matchHere(alt, &.{}, syntax, text, start)) return true;
        }
    }
    return false;
}

fn escapeChar(syntax: Syntax) u8 {
    return if (syntax == .lua) '%' else '\\';
}

fn isQuantifier(ch: u8) bool {
    return ch == '*' or ch == '+' or ch == '?';
}

/// Splits a pattern at the top-level "|" characters (regex syntax only).
const Alternatives = struct {
    p: []const u8,
    syntax: Syntax,
    pos: ?usize = 0,

    fn next(self: *Alternatives) ?[]const u8 {
        const start = self.pos orelse return null;
        var i = start;
        var depth: usize = 0;
        while (i < self.p.len) : (i += 1) {
            const ch = self.p[i];
            if (ch == escapeChar(self.syntax)) {
                i += 1;
            } else if (ch == '[') {
                const n = atomLen(self.p[i..], self.syntax) catch return self.finish(start);
                i += n - 1;
            } else if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -|= 1;
            } else if (ch == '|' and depth == 0 and self.syntax == .regex) {
                self.pos = i + 1;
                return self.p[start..i];
            }
        }
        return self.finish(start);
    }

    fn finish(self: *Alternatives, start: usize) []const u8 {
        self.pos = null;
        return self.p[start..];
    }
};

fn alternatives(p: []const u8, syntax: Syntax) Alternatives {
    return .{ .p = p, .syntax = syntax };
}

/// The index of the ")" that closes the "(" at `p[0]`.
fn matchingParen(p: []const u8, syntax: Syntax) Error!usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        const ch = p[i];
        if (ch == escapeChar(syntax)) {
            i += 1;
        } else if (ch == '[') {
            i += try atomLen(p[i..], syntax) - 1;
        } else if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return error.InvalidPattern;
}

/// The length of the atom at the start of `p`.
fn atomLen(p: []const u8, syntax: Syntax) Error!usize {
    if (p.len == 0) return error.InvalidPattern;
    const esc = escapeChar(syntax);
    if (p[0] == esc) return if (p.len >= 2) 2 else error.InvalidPattern;
    if (p[0] == '[') {
        var i: usize = 1;
        if (i < p.len and p[i] == '^') i += 1;
        if (i < p.len and p[i] == ']') i += 1; // a "]" first is a literal
        while (i < p.len and p[i] != ']') : (i += 1) {
            if (p[i] == esc) i += 1;
        }
        if (i >= p.len) return error.InvalidPattern;
        return i + 1;
    }
    if (isQuantifier(p[0])) return error.InvalidPattern;
    return 1;
}

/// Matches `p` at `text[t..]`, then the continuations in `conts` (the last
/// one first). A group pushes the pattern after it as a continuation.
fn matchHere(p: []const u8, conts: []const []const u8, syntax: Syntax, text: []const u8, t: usize) bool {
    if (p.len == 0) {
        if (conts.len == 0) return true;
        return matchHere(conts[conts.len - 1], conts[0 .. conts.len - 1], syntax, text, t);
    }
    if (p.len == 1 and p[0] == '$') {
        return t == text.len and matchHere("", conts, syntax, text, t);
    }
    if (p[0] == '(') {
        const close = matchingParen(p, syntax) catch return false;
        if (conts.len >= max_depth) return false;
        var buf: [max_depth][]const u8 = undefined;
        @memcpy(buf[0..conts.len], conts);
        buf[conts.len] = p[close + 1 ..];
        const inner_conts = buf[0 .. conts.len + 1];
        var alts = alternatives(p[1..close], syntax);
        while (alts.next()) |alt| {
            if (matchHere(alt, inner_conts, syntax, text, t)) return true;
        }
        return false;
    }

    const n = atomLen(p, syntax) catch return false;
    const atom = p[0..n];
    const rest = p[n..];
    if (rest.len > 0 and isQuantifier(rest[0])) {
        const q = rest[0];
        const min: usize = if (q == '+') 1 else 0;
        const max: usize = if (q == '?') 1 else std.math.maxInt(usize);
        var count: usize = 0;
        while (t + count < text.len and count < max and atomMatches(atom, syntax, text[t + count])) count += 1;
        // Greedy: try the longest run first, then shorter ones.
        while (true) {
            if (count >= min and matchHere(rest[1..], conts, syntax, text, t + count)) return true;
            if (count == 0) return false;
            count -= 1;
        }
    }
    if (t < text.len and atomMatches(atom, syntax, text[t])) return matchHere(rest, conts, syntax, text, t + 1);
    return false;
}

fn atomMatches(atom: []const u8, syntax: Syntax, ch: u8) bool {
    const esc = escapeChar(syntax);
    if (atom[0] == '.' and atom.len == 1) return true;
    if (atom[0] == esc) return classMatches(atom[1], ch);
    if (atom[0] == '[') return setMatches(atom[1 .. atom.len - 1], syntax, ch);
    return atom[0] == ch;
}

/// `\d`, `%a` and so on. Other letters after the escape are literals.
fn classMatches(class: u8, ch: u8) bool {
    return switch (class) {
        'd' => std.ascii.isDigit(ch),
        'w' => std.ascii.isAlphanumeric(ch) or (ch == '_'),
        's' => std.ascii.isWhitespace(ch),
        'a' => std.ascii.isAlphabetic(ch),
        'l' => std.ascii.isLower(ch),
        'u' => std.ascii.isUpper(ch),
        'x' => std.ascii.isHex(ch),
        'p' => std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ',
        else => class == ch,
    };
}

fn setMatches(set: []const u8, syntax: Syntax, ch: u8) bool {
    const esc = escapeChar(syntax);
    var s = set;
    const negate = s.len > 0 and s[0] == '^';
    if (negate) s = s[1..];
    var found = false;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == esc and i + 1 < s.len) {
            if (classMatches(s[i + 1], ch)) found = true;
            i += 2;
        } else if (i + 2 < s.len and s[i + 1] == '-') {
            if (ch >= s[i] and ch <= s[i + 2]) found = true;
            i += 3;
        } else {
            if (s[i] == ch) found = true;
            i += 1;
        }
    }
    return found != negate;
}

fn expectMatch(pattern: []const u8, syntax: Syntax, text: []const u8, want: bool) !void {
    try validate(pattern, syntax);
    try testing.expectEqual(want, isMatch(pattern, syntax, text));
}

test "patterns from real highlight queries" {
    // tree-sitter-c: constants
    try expectMatch("^[A-Z][A-Z\\d_]*$", .regex, "MAX_SIZE_2", true);
    try expectMatch("^[A-Z][A-Z\\d_]*$", .regex, "MaxSize", false);
    try expectMatch("^[A-Z][A-Z\\d_]*$", .regex, "A", true);
    // tree-sitter-zig: constants need two or more characters
    try expectMatch("^[A-Z][A-Z_0-9]+$", .lua, "A", false);
    try expectMatch("^[A-Z][A-Z_0-9]+$", .lua, "AB_1", true);
    // tree-sitter-zig: types (no "$", so a prefix is sufficient)
    try expectMatch("^[A-Z_][a-zA-Z0-9_]*", .lua, "ArrayList", true);
    try expectMatch("^[A-Z_][a-zA-Z0-9_]*", .lua, "list", false);
    // tree-sitter-zig: doc comments
    try expectMatch("^//!", .lua, "//! module doc", true);
    try expectMatch("^//!", .lua, "// plain", false);
    // tree-sitter-html: tags
    try expectMatch("^[a-z][^.]*$", .regex, "div", true);
    try expectMatch("^[a-z][^.]*$", .regex, "x.y", false);
    // tree-sitter-python and tree-sitter-javascript: builtins
    const builtins = "^(abs|all|any|print|__import__)$";
    try expectMatch(builtins, .regex, "print", true);
    try expectMatch(builtins, .regex, "__import__", true);
    try expectMatch(builtins, .regex, "printer", false);
    try expectMatch(builtins, .regex, "ab", false);
}

test "anchors, search, classes and quantifiers" {
    try expectMatch("lo", .regex, "hello", true); // no "^": search
    try expectMatch("^lo", .regex, "hello", false);
    try expectMatch("o$", .regex, "hello", true);
    try expectMatch("^h.l+o?$", .regex, "hell", true);
    try expectMatch("^a\\.b$", .regex, "a.b", true);
    try expectMatch("^a\\.b$", .regex, "axb", false);
    try expectMatch("^%d+$", .lua, "123", true);
    try expectMatch("^%d+$", .lua, "12a", false);
    try expectMatch("^[^0-9]+$", .regex, "abc", true);
    try expectMatch("^[^0-9]+$", .regex, "a1c", false);
    try expectMatch("^[%w_]+$", .lua, "snake_case9", true);
    try expectMatch("^a*$", .regex, "", true);
}

test "groups and alternatives" {
    try expectMatch("^(ab|cd)e$", .regex, "abe", true);
    try expectMatch("^(ab|cd)e$", .regex, "cde", true);
    try expectMatch("^(ab|cd)e$", .regex, "ace", false);
    try expectMatch("^a(b(c|d)|e)f$", .regex, "abdf", true); // nested
    try expectMatch("^a(b(c|d)|e)f$", .regex, "aef", true);
    try expectMatch("^a(b(c|d)|e)f$", .regex, "abf", false);
    try expectMatch("^x[|]y$", .regex, "x|y", true); // "|" in a set is a literal
    try expectMatch("cat|dog", .regex, "hotdog", true); // top-level alternatives
    try expectMatch("^cat|^dog", .regex, "dogma", true);
    try expectMatch("^(a+|b)c$", .regex, "aaac", true); // a quantifier inside a group
    try expectMatch("^(%a)", .lua, "x", true); // a Lua capture is a group
    try expectMatch("^a|b$", .lua, "a|b", true); // "|" is a literal in Lua
}

test "invalid patterns are errors" {
    try testing.expectError(error.InvalidPattern, validate("[abc", .regex));
    try testing.expectError(error.InvalidPattern, validate("*a", .regex));
    try testing.expectError(error.InvalidPattern, validate("a\\", .regex));
    try testing.expectError(error.InvalidPattern, validate("(ab", .regex));
    try testing.expectError(error.InvalidPattern, validate("ab)", .regex));
    try testing.expectError(error.InvalidPattern, validate("(ab)+", .regex)); // quantified group
    try testing.expectError(error.InvalidPattern, validate("((((((((a))))))))", .regex)); // too deep
}
