//! Tree-sitter support: languages that load at runtime, syntax trees,
//! highlighting and structural movement.
//!
//! `init.lua` registers languages with `editor.language`. A language is a
//! grammar compiled to a shared library that exports `tree_sitter_<name>`,
//! and an optional `highlights.scm` query file. The editor loads a language
//! the first time that a file needs it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const c = @import("c");
const regex = @import("regex.zig");
const files = @import("files.zig");
const Buffer = @import("buffer.zig").Buffer;

/// The color groups for highlighting. Query capture names map to these.
pub const Face = enum(u8) {
    none,
    keyword,
    string,
    comment,
    function,
    type,
    constant,
    attribute,
};

/// Capture names and their faces. The longest name that is a prefix of the
/// capture name (at a "." boundary) wins, so "function.builtin" can differ
/// from "function". Names that are not here, such as "variable" and
/// "punctuation", get no color.
const face_table = [_]struct { []const u8, Face }{
    .{ "comment", .comment },
    .{ "string", .string },
    .{ "character", .string },
    .{ "keyword", .keyword },
    .{ "conditional", .keyword },
    .{ "repeat", .keyword },
    .{ "include", .keyword },
    .{ "exception", .keyword },
    .{ "storageclass", .keyword },
    .{ "function", .function },
    .{ "method", .function },
    .{ "constructor", .function },
    .{ "type", .type },
    .{ "constant", .constant },
    .{ "boolean", .constant },
    .{ "number", .constant },
    .{ "float", .constant },
    .{ "variable.builtin", .constant },
    .{ "attribute", .attribute },
    .{ "label", .attribute },
    .{ "module", .attribute },
    .{ "namespace", .attribute },
    .{ "tag", .attribute },
};

pub fn faceForCapture(name: []const u8) Face {
    if (name.len == 0 or name[0] == '_') return .none; // private captures
    var best: Face = .none;
    var best_len: usize = 0;
    for (face_table) |entry| {
        const key = entry[0];
        if (!std.mem.startsWith(u8, name, key)) continue;
        if (name.len > key.len and name[key.len] != '.') continue;
        if (key.len > best_len) {
            best = entry[1];
            best_len = key.len;
        }
    }
    return best;
}

// Predicates

const Predicate = struct {
    kind: enum { eq, match, any_of },
    negate: bool,
    capture: u32,
    /// For `eq`: compare with this capture, or with `string` if null.
    other_capture: ?u32 = null,
    /// For `eq` and `match`. The query owns the memory.
    string: []const u8 = "",
    syntax: regex.Syntax = .regex,
    /// For `any_of`.
    strings: []const []const u8 = &.{},
};

const PatternPredicates = struct {
    /// True if the pattern uses a predicate that the editor does not know.
    /// A disabled pattern never matches.
    disabled: bool = false,
    predicates: []Predicate = &.{},
};

/// A compiled highlight query with its faces and predicates.
pub const Highlights = struct {
    query: *c.TSQuery,
    /// The face for each capture id.
    faces: []Face,
    /// The predicates for each pattern.
    patterns: []PatternPredicates,

    fn init(gpa: std.mem.Allocator, language: *const c.TSLanguage, source: []const u8, err_buf: []u8) !Highlights {
        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const query = c.ts_query_new(language, source.ptr, @intCast(source.len), &err_offset, &err_type) orelse {
            const line = std.mem.count(u8, source[0..@min(err_offset, source.len)], "\n") + 1;
            _ = std.fmt.bufPrint(err_buf, "query error ({s}) on line {d}", .{ queryErrorName(err_type), line }) catch {};
            return error.QueryError;
        };
        errdefer c.ts_query_delete(query);

        const capture_count = c.ts_query_capture_count(query);
        const faces = try gpa.alloc(Face, capture_count);
        errdefer gpa.free(faces);
        for (faces, 0..) |*f, i| {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(query, @intCast(i), &len);
            f.* = faceForCapture(name[0..len]);
        }

        const pattern_count = c.ts_query_pattern_count(query);
        const patterns = try gpa.alloc(PatternPredicates, pattern_count);
        @memset(patterns, .{});
        errdefer freePatterns(gpa, patterns);
        for (patterns, 0..) |*p, i| p.* = try parsePredicates(gpa, query, @intCast(i));

        return .{ .query = query, .faces = faces, .patterns = patterns };
    }

    fn deinit(self: *Highlights, gpa: std.mem.Allocator) void {
        freePatterns(gpa, self.patterns);
        gpa.free(self.faces);
        c.ts_query_delete(self.query);
        self.* = undefined;
    }

    fn freePatterns(gpa: std.mem.Allocator, patterns: []PatternPredicates) void {
        for (patterns) |p| {
            for (p.predicates) |pred| if (pred.strings.len > 0) gpa.free(pred.strings);
            if (p.predicates.len > 0) gpa.free(p.predicates);
        }
        gpa.free(patterns);
    }

    /// True if the match passes all predicates of its pattern.
    fn passes(self: *const Highlights, match: *const c.TSQueryMatch, text: []const u8) bool {
        const pattern = self.patterns[match.pattern_index];
        if (pattern.disabled) return false;
        const captures = match.captures[0..match.capture_count];
        for (pattern.predicates) |pred| {
            // As in Neovim, a predicate on a capture that did not match passes.
            const node_text = captureText(captures, pred.capture, text) orelse continue;
            const result = switch (pred.kind) {
                .eq => blk: {
                    const other = if (pred.other_capture) |id| captureText(captures, id, text) orelse continue else pred.string;
                    break :blk std.mem.eql(u8, node_text, other);
                },
                .match => regex.isMatch(pred.string, pred.syntax, node_text),
                .any_of => blk: {
                    for (pred.strings) |s| if (std.mem.eql(u8, node_text, s)) break :blk true;
                    break :blk false;
                },
            };
            if (result == pred.negate) return false;
        }
        return true;
    }
};

fn captureText(captures: []const c.TSQueryCapture, id: u32, text: []const u8) ?[]const u8 {
    for (captures) |cap| {
        if (cap.index != id) continue;
        const start = c.ts_node_start_byte(cap.node);
        const end = c.ts_node_end_byte(cap.node);
        if (end > text.len or start > end) return null;
        return text[start..end];
    }
    return null;
}

fn queryErrorName(err: c.TSQueryError) []const u8 {
    return switch (err) {
        c.TSQueryErrorSyntax => "syntax",
        c.TSQueryErrorNodeType => "unknown node type",
        c.TSQueryErrorField => "unknown field",
        c.TSQueryErrorCapture => "unknown capture",
        c.TSQueryErrorStructure => "impossible pattern",
        c.TSQueryErrorLanguage => "language",
        else => "unknown",
    };
}

/// Reads the predicates of one pattern. See the tree-sitter documentation
/// for `ts_query_predicates_for_pattern`: each predicate is a list of steps
/// that ends with a "done" step, and its first step is the name.
fn parsePredicates(gpa: std.mem.Allocator, query: *c.TSQuery, pattern: u32) !PatternPredicates {
    var count: u32 = 0;
    const steps_ptr = c.ts_query_predicates_for_pattern(query, pattern, &count);
    if (count == 0) return .{};
    const steps = steps_ptr[0..count];

    var preds: std.ArrayList(Predicate) = .empty;
    errdefer {
        for (preds.items) |p| if (p.strings.len > 0) gpa.free(p.strings);
        preds.deinit(gpa);
    }
    var disabled = false;

    var i: usize = 0;
    while (i < steps.len) {
        var end = i;
        while (end < steps.len and steps[end].type != c.TSQueryPredicateStepTypeDone) end += 1;
        const group = steps[i..end];
        i = end + 1;
        if (group.len == 0 or group[0].type != c.TSQueryPredicateStepTypeString) {
            disabled = true;
            continue;
        }
        const name = stringValue(query, group[0].value_id);
        const args = group[1..];
        if (std.mem.endsWith(u8, name, "!")) continue; // directives, for example #set!

        const pred = parseOne(gpa, query, name, args) catch |err| switch (err) {
            error.Unsupported => {
                disabled = true;
                continue;
            },
            else => |e| return e,
        };
        try preds.append(gpa, pred);
    }
    return .{ .disabled = disabled, .predicates = try preds.toOwnedSlice(gpa) };
}

fn parseOne(gpa: std.mem.Allocator, query: *c.TSQuery, name: []const u8, args: []const c.TSQueryPredicateStep) !Predicate {
    const negate = std.mem.startsWith(u8, name, "not-");
    const base = if (negate) name[4..] else name;
    if (args.len < 2 or args[0].type != c.TSQueryPredicateStepTypeCapture) return error.Unsupported;
    const capture = args[0].value_id;

    if (std.mem.eql(u8, base, "eq?")) {
        if (args.len != 2) return error.Unsupported;
        if (args[1].type == c.TSQueryPredicateStepTypeCapture) {
            return .{ .kind = .eq, .negate = negate, .capture = capture, .other_capture = args[1].value_id };
        }
        return .{ .kind = .eq, .negate = negate, .capture = capture, .string = stringValue(query, args[1].value_id) };
    }
    if (std.mem.eql(u8, base, "match?") or std.mem.eql(u8, base, "lua-match?")) {
        if (args.len != 2 or args[1].type != c.TSQueryPredicateStepTypeString) return error.Unsupported;
        const syntax: regex.Syntax = if (base[0] == 'l') .lua else .regex;
        const pattern = stringValue(query, args[1].value_id);
        regex.validate(pattern, syntax) catch return error.Unsupported;
        return .{ .kind = .match, .negate = negate, .capture = capture, .string = pattern, .syntax = syntax };
    }
    if (std.mem.eql(u8, base, "any-of?")) {
        const strings = try gpa.alloc([]const u8, args.len - 1);
        for (args[1..], strings) |arg, *s| {
            if (arg.type != c.TSQueryPredicateStepTypeString) {
                gpa.free(strings);
                return error.Unsupported;
            }
            s.* = stringValue(query, arg.value_id);
        }
        return .{ .kind = .any_of, .negate = negate, .capture = capture, .strings = strings };
    }
    return error.Unsupported;
}

fn stringValue(query: *c.TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    const ptr = c.ts_query_string_value_for_id(query, id, &len);
    return ptr[0..len];
}

// Languages

pub const Loaded = struct {
    lib: std.DynLib,
    language: *const c.TSLanguage,
    highlights: ?Highlights,
};

pub const LanguageConfig = struct {
    name: []u8,
    extensions: [][]u8,
    filenames: [][]u8,
    parser_path: []u8,
    highlights_path: ?[]u8,
    /// The function that the library exports, "tree_sitter_<name>" by default.
    symbol: [:0]u8,
    state: union(enum) { unloaded, loaded: Loaded, failed } = .unloaded,
};

/// The options of `editor.language`. The registry copies all strings.
pub const LanguageOptions = struct {
    name: []const u8,
    parser: []const u8,
    extensions: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    highlights: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
};

pub const Languages = struct {
    gpa: std.mem.Allocator,
    /// Pointers, so a `Loaded` keeps its address when the list grows.
    items: std.ArrayList(*LanguageConfig) = .empty,
    /// The cause of the last load error.
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Languages {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Languages) void {
        for (self.items.items) |cfg| self.destroy(cfg);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    fn destroy(self: *Languages, cfg: *LanguageConfig) void {
        const gpa = self.gpa;
        switch (cfg.state) {
            .loaded => |*l| {
                if (l.highlights) |*h| h.deinit(gpa);
                l.lib.close();
            },
            .unloaded, .failed => {},
        }
        gpa.free(cfg.name);
        for (cfg.extensions) |e| gpa.free(e);
        gpa.free(cfg.extensions);
        for (cfg.filenames) |f| gpa.free(f);
        gpa.free(cfg.filenames);
        gpa.free(cfg.parser_path);
        if (cfg.highlights_path) |h| gpa.free(h);
        gpa.free(cfg.symbol);
        gpa.destroy(cfg);
    }

    /// Adds a language, or replaces a language with the same name that is
    /// not loaded yet.
    pub fn register(self: *Languages, opts: LanguageOptions) !void {
        const gpa = self.gpa;
        if (opts.name.len == 0) return error.EmptyName;

        const cfg = try gpa.create(LanguageConfig);
        errdefer gpa.destroy(cfg);
        const name = try gpa.dupe(u8, opts.name);
        errdefer gpa.free(name);
        const extensions = try dupeAll(gpa, opts.extensions);
        errdefer freeAll(gpa, extensions);
        const filenames = try dupeAll(gpa, opts.filenames);
        errdefer freeAll(gpa, filenames);
        const parser_path = try gpa.dupe(u8, opts.parser);
        errdefer gpa.free(parser_path);
        const highlights_path = if (opts.highlights) |h| try gpa.dupe(u8, h) else null;
        errdefer if (highlights_path) |h| gpa.free(h);
        const symbol = if (opts.symbol) |s|
            try gpa.dupeSentinel(u8, s, 0)
        else
            try std.fmt.allocPrintSentinel(gpa, "tree_sitter_{s}", .{opts.name}, 0);
        errdefer gpa.free(symbol);

        cfg.* = .{
            .name = name,
            .extensions = extensions,
            .filenames = filenames,
            .parser_path = parser_path,
            .highlights_path = highlights_path,
            .symbol = symbol,
        };

        for (self.items.items, 0..) |old, i| {
            if (!std.mem.eql(u8, old.name, opts.name)) continue;
            if (old.state == .loaded) return error.AlreadyLoaded;
            self.destroy(old);
            self.items.items[i] = cfg;
            return;
        }
        try self.items.append(gpa, cfg);
    }

    /// The language for a file: a file name match first, then an extension
    /// match. Later registrations win.
    pub fn forPath(self: *const Languages, path: []const u8) ?*LanguageConfig {
        const base = std.fs.path.basename(path);
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const cfg = self.items.items[i];
            for (cfg.filenames) |f| if (std.mem.eql(u8, f, base)) return cfg;
        }
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        if (dot == 0) return null; // ".bashrc" has no extension
        const ext = base[dot + 1 ..];
        i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const cfg = self.items.items[i];
            for (cfg.extensions) |e| if (std.mem.eql(u8, e, ext)) return cfg;
        }
        return null;
    }

    /// Loads the grammar library and the highlight query the first time. If
    /// loading fails, `lastError` gives the cause, and later calls fail at
    /// once.
    pub fn load(self: *Languages, io: Io, cfg: *LanguageConfig) !*Loaded {
        switch (cfg.state) {
            .loaded => |*l| return l,
            .failed => return error.LoadFailed,
            .unloaded => {},
        }
        const loaded = self.loadInner(io, cfg) catch |err| {
            cfg.state = .failed;
            if (self.err_len == 0) self.setError("{t}", .{err});
            return err;
        };
        cfg.state = .{ .loaded = loaded };
        return &cfg.state.loaded;
    }

    fn loadInner(self: *Languages, io: Io, cfg: *LanguageConfig) !Loaded {
        self.err_len = 0;
        var lib = std.DynLib.open(cfg.parser_path) catch |err| {
            self.setError("cannot open {s}: {t}", .{ cfg.parser_path, err });
            return err;
        };
        errdefer lib.close();

        const LanguageFn = *const fn () callconv(.c) ?*const c.TSLanguage;
        const func = lib.lookup(LanguageFn, cfg.symbol) orelse {
            self.setError("no symbol {s} in {s}", .{ cfg.symbol, cfg.parser_path });
            return error.SymbolNotFound;
        };
        const language = func() orelse return error.NoLanguage;

        // Make sure that this tree-sitter library can use the grammar.
        const abi = c.ts_language_abi_version(language);
        if (abi < c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION or abi > c.TREE_SITTER_LANGUAGE_VERSION) {
            self.setError("grammar ABI {d} is not in {d}..{d}", .{ abi, c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION, c.TREE_SITTER_LANGUAGE_VERSION });
            return error.IncompatibleLanguage;
        }

        var highlights: ?Highlights = null;
        if (cfg.highlights_path) |path| {
            const source = (try files.readFile(io, Io.Dir.cwd(), self.gpa, path)) orelse {
                self.setError("no file {s}", .{path});
                return error.FileNotFound;
            };
            defer self.gpa.free(source);
            highlights = try Highlights.init(self.gpa, language, source, &self.err_buf);
        }
        return .{ .lib = lib, .language = language, .highlights = highlights };
    }

    fn setError(self: *Languages, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.err_buf, fmt, args) catch &self.err_buf;
        self.err_len = text.len;
    }

    pub fn lastError(self: *const Languages) []const u8 {
        if (self.err_len > 0) return self.err_buf[0..self.err_len];
        // Highlights.init writes into err_buf without the length.
        return std.mem.sliceTo(&self.err_buf, 0);
    }
};

fn dupeAll(gpa: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (items) |item| {
        out[n] = try gpa.dupe(u8, item);
        n += 1;
    }
    return out;
}

fn freeAll(gpa: std.mem.Allocator, items: [][]u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

// Syntax trees

/// The parser and the syntax tree of one buffer.
pub const Syntax = struct {
    gpa: std.mem.Allocator,
    parser: *c.TSParser,
    lang: *const Loaded,
    tree: ?*c.TSTree = null,
    /// A copy of the text of the last parse. Predicates need the node text.
    text: []u8 = &.{},
    /// The buffer version of the last parse.
    version: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, lang: *const Loaded) !Syntax {
        const parser = c.ts_parser_new() orelse return error.OutOfMemory;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, lang.language)) return error.IncompatibleLanguage;
        return .{ .gpa = gpa, .parser = parser, .lang = lang };
    }

    pub fn deinit(self: *Syntax) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        self.gpa.free(self.text);
        c.ts_parser_delete(self.parser);
        self.* = undefined;
    }

    /// Parses the buffer again if it changed since the last parse. This is a
    /// full parse, not an incremental parse.
    pub fn update(self: *Syntax, buf: *const Buffer) !void {
        if (self.tree != null and self.version == buf.version) return;
        if (buf.len() > std.math.maxInt(u32)) return error.FileTooBig;
        const text = try buf.copyRange(self.gpa, 0, buf.len());
        errdefer self.gpa.free(text);
        const tree = c.ts_parser_parse_string(self.parser, null, text.ptr, @intCast(text.len)) orelse return error.ParseFailed;
        if (self.tree) |t| c.ts_tree_delete(t);
        self.gpa.free(self.text);
        self.tree = tree;
        self.text = text;
        self.version = buf.version;
    }

    fn root(self: *const Syntax) ?c.TSNode {
        const tree = self.tree orelse return null;
        return c.ts_tree_root_node(tree);
    }

    /// Fills `out` with the face of each byte from `start`. `out.len` is the
    /// number of bytes. Call `update` first.
    pub fn highlight(self: *const Syntax, start: usize, out: []Face) !void {
        @memset(out, .none);
        const hl = if (self.lang.highlights) |*h| h else return;
        const root_node = self.root() orelse return;
        const end = start + out.len;

        const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
        c.ts_query_cursor_exec(cursor, hl.query, root_node);

        const Span = struct { start: u32, end: u32, face: Face, pattern: u16 };
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(self.gpa);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!hl.passes(&match, self.text)) continue;
            for (match.captures[0..match.capture_count]) |cap| {
                const face = hl.faces[cap.index];
                if (face == .none) continue;
                try spans.append(self.gpa, .{
                    .start = c.ts_node_start_byte(cap.node),
                    .end = c.ts_node_end_byte(cap.node),
                    .face = face,
                    .pattern = match.pattern_index,
                });
            }
        }

        // Outer nodes first, so inner nodes paint over them. For the same
        // node, the last pattern in the query wins, as in Neovim: queries put
        // specific patterns, such as constants, after general ones, such as
        // types. The sort puts the last pattern first, and the loop below
        // skips the other patterns for the same node.
        std.mem.sort(Span, spans.items, {}, struct {
            fn lessThan(_: void, a: Span, b: Span) bool {
                if (a.start != b.start) return a.start < b.start;
                if (a.end != b.end) return a.end > b.end;
                return a.pattern > b.pattern;
            }
        }.lessThan);

        var prev: ?Span = null;
        for (spans.items) |s| {
            if (prev) |p| if (p.start == s.start and p.end == s.end) continue;
            prev = s;
            const lo = @max(s.start, start);
            const hi = @min(s.end, end);
            if (lo < hi) @memset(out[lo - start .. hi - start], s.face);
        }
    }

    // Structural movement. Each function returns the new byte position, or
    // null if the cursor cannot move. Call `update` first.

    /// The smallest node that contains `pos` strictly inside it, or the root.
    fn container(self: *const Syntax, pos: usize) ?c.TSNode {
        const r = self.root() orelse return null;
        const p: u32 = @intCast(pos);
        var n = c.ts_node_descendant_for_byte_range(r, p, p);
        while (!c.ts_node_is_null(n)) : (n = c.ts_node_parent(n)) {
            if (c.ts_node_start_byte(n) < p and p < c.ts_node_end_byte(n)) return n;
        }
        return r;
    }

    /// C-M-f: to the end of the next node at this level.
    pub fn forwardSexp(self: *const Syntax, pos: usize) ?usize {
        const n = self.container(pos) orelse return null;
        const count = c.ts_node_child_count(n);
        if (count == 0) return c.ts_node_end_byte(n); // inside a token
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const child = c.ts_node_child(n, i);
            if (c.ts_node_end_byte(child) > pos) return c.ts_node_end_byte(child);
        }
        return null;
    }

    /// C-M-b: to the start of the node before the cursor at this level.
    pub fn backwardSexp(self: *const Syntax, pos: usize) ?usize {
        const n = self.container(pos) orelse return null;
        const count = c.ts_node_child_count(n);
        if (count == 0) return c.ts_node_start_byte(n);
        var i = count;
        while (i > 0) {
            i -= 1;
            const child = c.ts_node_child(n, i);
            if (c.ts_node_start_byte(child) < pos) return c.ts_node_start_byte(child);
        }
        return null;
    }

    /// C-M-u: to the start of the node that contains the cursor.
    pub fn backwardUpList(self: *const Syntax, pos: usize) ?usize {
        var n = self.container(pos) orelse return null;
        if (c.ts_node_child_count(n) == 0) n = c.ts_node_parent(n); // inside a token
        if (c.ts_node_is_null(n) or c.ts_node_is_null(c.ts_node_parent(n))) return null; // the root
        return c.ts_node_start_byte(n);
    }

    /// C-M-d: into the next list, just after its opening bracket.
    pub fn downList(self: *const Syntax, pos: usize) ?usize {
        const n = self.container(pos) orelse return null;
        return firstOpenBracket(n, pos);
    }

    /// C-M-a: to the start of the top-level node before the cursor.
    pub fn beginningOfDefun(self: *const Syntax, pos: usize) ?usize {
        const r = self.root() orelse return null;
        var i = c.ts_node_child_count(r);
        while (i > 0) {
            i -= 1;
            const child = c.ts_node_child(r, i);
            if (c.ts_node_start_byte(child) < pos) return c.ts_node_start_byte(child);
        }
        return null;
    }

    /// C-M-e: to the end of the top-level node after the cursor.
    pub fn endOfDefun(self: *const Syntax, pos: usize) ?usize {
        const r = self.root() orelse return null;
        const count = c.ts_node_child_count(r);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const child = c.ts_node_child(r, i);
            if (c.ts_node_end_byte(child) > pos) return c.ts_node_end_byte(child);
        }
        return null;
    }
};

/// The end of the first "(", "[" or "{" token inside `node` at or after
/// `pos`, in text order.
fn firstOpenBracket(node: c.TSNode, pos: usize) ?usize {
    const count = c.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_child(node, i);
        if (c.ts_node_end_byte(child) <= pos) continue;
        if (c.ts_node_child_count(child) == 0) {
            if (c.ts_node_start_byte(child) < pos or c.ts_node_is_named(child)) continue;
            const kind = std.mem.span(c.ts_node_type(child));
            if (std.mem.eql(u8, kind, "(") or std.mem.eql(u8, kind, "[") or std.mem.eql(u8, kind, "{")) {
                return c.ts_node_end_byte(child);
            }
        } else if (firstOpenBracket(child, pos)) |found| {
            return found;
        }
    }
    return null;
}

test "capture names map to faces by the longest prefix" {
    try testing.expectEqual(Face.keyword, faceForCapture("keyword"));
    try testing.expectEqual(Face.keyword, faceForCapture("keyword.function"));
    try testing.expectEqual(Face.function, faceForCapture("function.builtin"));
    try testing.expectEqual(Face.constant, faceForCapture("variable.builtin"));
    try testing.expectEqual(Face.none, faceForCapture("variable"));
    try testing.expectEqual(Face.none, faceForCapture("variable.parameter"));
    try testing.expectEqual(Face.comment, faceForCapture("comment.documentation"));
    try testing.expectEqual(Face.none, faceForCapture("_name")); // private
    try testing.expectEqual(Face.none, faceForCapture("typewriter")); // "type" needs a "." boundary
}

test "languages match by file name, then by extension" {
    var langs: Languages = .init(testing.allocator);
    defer langs.deinit();
    try langs.register(.{ .name = "zig", .parser = "/x/zig.so", .extensions = &.{ "zig", "zon" } });
    try langs.register(.{ .name = "make", .parser = "/x/make.so", .filenames = &.{"Makefile"} });
    try langs.register(.{ .name = "c", .parser = "/x/c.so", .extensions = &.{ "c", "h" }, .symbol = "my_c" });

    try testing.expectEqualStrings("zig", langs.forPath("src/main.zig").?.name);
    try testing.expectEqualStrings("zig", langs.forPath("build.zig.zon").?.name);
    try testing.expectEqualStrings("make", langs.forPath("/a/b/Makefile").?.name);
    try testing.expectEqualStrings("my_c", langs.forPath("x.h").?.symbol);
    try testing.expectEqualStrings("tree_sitter_zig", langs.forPath("a.zig").?.symbol);
    try testing.expectEqual(null, langs.forPath("notes.txt"));
    try testing.expectEqual(null, langs.forPath(".zig")); // a hidden file, no extension

    // A second registration with the same name replaces the first.
    try langs.register(.{ .name = "zig", .parser = "/y/zig.so", .extensions = &.{"zig"} });
    try testing.expectEqual(3, langs.items.items.len);
    try testing.expectEqualStrings("/y/zig.so", langs.forPath("a.zig").?.parser_path);
    try testing.expectEqual(null, langs.forPath("a.zon"));
}

test "a missing parser library is a load error with a cause" {
    var langs: Languages = .init(testing.allocator);
    defer langs.deinit();
    try langs.register(.{ .name = "nope", .parser = "/does/not/exist.so", .extensions = &.{"nope"} });
    const cfg = langs.forPath("a.nope").?;
    try testing.expectError(error.FileNotFound, langs.load(testing.io, cfg));
    try testing.expect(std.mem.indexOf(u8, langs.lastError(), "/does/not/exist.so") != null);
    try testing.expectError(error.LoadFailed, langs.load(testing.io, cfg)); // fails at once
}
