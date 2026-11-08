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
const rope_zig = @import("rope");
const Rope = rope_zig.Rope;
const Snapshot = rope_zig.Snapshot;
const text_worker = @import("text_worker.zig");

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

    /// True if the match passes all predicates of its pattern. It reads the
    /// node text from `snap` into `scratch`.
    fn passes(self: *const Highlights, match: *const c.TSQueryMatch, snap: Snapshot, gpa: std.mem.Allocator, scratch: *std.ArrayList(u8)) !bool {
        const pattern = self.patterns[match.pattern_index];
        if (pattern.disabled) return false;
        const captures = match.captures[0..match.capture_count];
        for (pattern.predicates) |pred| {
            // As in Neovim, a predicate on a capture that did not match passes.
            const range = captureRange(captures, pred.capture, snap.len()) orelse continue;
            scratch.clearRetainingCapacity();
            try appendRange(gpa, scratch, snap, range);
            const result = switch (pred.kind) {
                .eq => blk: {
                    if (pred.other_capture) |id| {
                        const other = captureRange(captures, id, snap.len()) orelse continue;
                        const split = scratch.items.len;
                        try appendRange(gpa, scratch, snap, other);
                        break :blk std.mem.eql(u8, scratch.items[0..split], scratch.items[split..]);
                    }
                    break :blk std.mem.eql(u8, scratch.items, pred.string);
                },
                .match => regex.isMatch(pred.string, pred.syntax, scratch.items),
                .any_of => blk: {
                    for (pred.strings) |str| if (std.mem.eql(u8, scratch.items, str)) break :blk true;
                    break :blk false;
                },
            };
            if (result == pred.negate) return false;
        }
        return true;
    }
};

const ByteRange = struct { start: usize, end: usize };

fn captureRange(captures: []const c.TSQueryCapture, id: u32, len: usize) ?ByteRange {
    for (captures) |cap| {
        if (cap.index != id) continue;
        const start = c.ts_node_start_byte(cap.node);
        const end = c.ts_node_end_byte(cap.node);
        if (end > len or start > end) return null;
        return .{ .start = start, .end = end };
    }
    return null;
}

fn appendRange(gpa: std.mem.Allocator, list: *std.ArrayList(u8), snap: Snapshot, range: ByteRange) !void {
    const out = try list.addManyAsSlice(gpa, range.end - range.start);
    snap.copyRange(range.start, out);
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

/// The tree-sitter job for a `text_worker.Worker`. It keeps the last tree
/// and its snapshot. For each new snapshot, it finds the changed range with
/// `Snapshot.diff`, tells the old tree about it with `ts_tree_edit`, and
/// gives the old tree to the parser. The parser then reuses the parts that
/// did not change. The parser reads the snapshot directly, without a copy.
const ParseJob = struct {
    parser: *c.TSParser,
    old: ?struct { tree: *c.TSTree, snap: Snapshot } = null,

    pub const Output = *c.TSTree;
    /// The old snapshot, and the new one if the parse gives no tree.
    pub const max_retire: usize = 2;

    pub fn process(job: *ParseJob, ctx: *text_worker.Context, text: text_worker.Text) ?*c.TSTree {
        var old_tree: ?*c.TSTree = null;
        if (job.old) |o| {
            const edit = inputEdit(o.snap, text.snap);
            c.ts_tree_edit(o.tree, &edit);
            old_tree = o.tree;
        }
        var snap = text.snap;
        const input: c.TSInput = .{
            .payload = &snap,
            .read = readSnapshot,
            .encoding = c.TSInputEncodingUTF8,
            .decode = null,
        };
        // The progress callback stops the parse when the worker is
        // destroyed, so a kill does not wait for a parse nobody needs.
        const options: c.TSParseOptions = .{ .payload = ctx, .progress_callback = parseProgress };
        const tree = c.ts_parser_parse_with_options(job.parser, old_tree, input, options);

        if (job.old) |o| {
            c.ts_tree_delete(o.tree);
            ctx.retire(o.snap);
            job.old = null;
        }
        const t = tree orelse {
            // After a stopped parse, the next parse must start again.
            c.ts_parser_reset(job.parser);
            ctx.retire(text.snap);
            return null;
        };
        // The main thread gets `t`. The job keeps a copy for the next parse.
        job.old = .{ .tree = c.ts_tree_copy(t).?, .snap = text.snap };
        return t;
    }

    pub fn discard(_: *ParseJob, tree: *c.TSTree) void {
        c.ts_tree_delete(tree);
    }

    pub fn finish(job: *ParseJob, ctx: *text_worker.Context) void {
        if (job.old) |o| {
            c.ts_tree_delete(o.tree);
            ctx.retire(o.snap);
        }
        c.ts_parser_delete(job.parser);
    }
};

const ParseWorker = text_worker.Worker(ParseJob);

/// The `TSParseOptions.progress_callback`: true stops the parse.
fn parseProgress(state: [*c]c.TSParseState) callconv(.c) bool {
    const ctx: *const text_worker.Context = @ptrCast(@alignCast(state.*.payload.?));
    return ctx.cancelled();
}

/// The `TSInput.read` function: the bytes of the snapshot from `byte_index`
/// to the end of that chunk.
fn readSnapshot(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
    const snap: *const Snapshot = @ptrCast(@alignCast(payload.?));
    if (byte_index >= snap.len()) {
        bytes_read.* = 0;
        return "";
    }
    const chunk = snap.chunkAt(byte_index);
    bytes_read.* = @intCast(chunk.len);
    return chunk.ptr;
}

/// The edit that changes the text of `old` into the text of `new`. If many
/// edits occurred between two parses, this edit covers all of them. It is
/// correct, but the parser reuses less.
fn inputEdit(old: Snapshot, new: Snapshot) c.TSInputEdit {
    const d = Snapshot.diff(old, new);
    return .{
        .start_byte = @intCast(d.start),
        .old_end_byte = @intCast(d.old_end),
        .new_end_byte = @intCast(d.new_end),
        .start_point = tsPoint(old.pointAt(d.start)),
        .old_end_point = tsPoint(old.pointAt(d.old_end)),
        .new_end_point = tsPoint(new.pointAt(d.new_end)),
    };
}

fn tsPoint(p: rope_zig.Point) c.TSPoint {
    return .{ .row = @intCast(p.row), .column = @intCast(p.column) };
}

/// The syntax tree of one buffer. A background thread parses snapshots of
/// the buffer, so a large file does not stop the editor while the user types.
pub const Syntax = struct {
    gpa: std.mem.Allocator,
    lang: *const Loaded,
    worker: *ParseWorker,
    /// The newest tree that the main thread took. `update` edits it with
    /// `ts_tree_edit`, so its byte offsets match `snap`, also before the
    /// parse thread gives a new tree.
    tree: ?*c.TSTree = null,
    /// The text that `tree` matches. Predicates read the node text from it.
    snap: ?Snapshot = null,
    /// The buffer version that the parse thread parsed for `tree`.
    version: u64 = 0,
    /// The buffer version of `snap`. It is newer than `version` if the
    /// buffer changed after that parse.
    snap_version: u64 = 0,

    /// `rope` is the rope of the buffer. It must stay at its address until
    /// `deinit`.
    /// The executor runs the parses of all buffers.
    pub fn init(executor: *text_worker.Executor, lang: *const Loaded, rope: *Rope) !Syntax {
        const parser = c.ts_parser_new() orelse return error.OutOfMemory;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, lang.language)) return error.IncompatibleLanguage;
        // The job owns the parser from here.
        const worker = try ParseWorker.create(executor, rope, .{ .parser = parser });
        return .{ .gpa = executor.gpa, .lang = lang, .worker = worker };
    }

    pub fn deinit(self: *Syntax) void {
        if (self.snap) |s| self.worker.release(s);
        if (self.tree) |t| c.ts_tree_delete(t);
        self.worker.destroy();
        self.* = undefined;
    }

    /// Sends the text to the parse thread if the buffer changed since the
    /// last request, and takes the newest finished tree. It does not wait.
    /// If the tree is from an older version, it edits the tree to match the
    /// current text. The offsets are then correct, but nodes in the edited
    /// range can be out of date until the next parse.
    pub fn update(self: *Syntax, buf: *const Buffer) !void {
        try self.submit(buf);
        if (self.worker.take()) |r| self.install(r);
        self.alignTree(buf);
    }

    /// As `update`, but waits until the parse thread parsed the current
    /// text. Structural movement needs a tree that is a real parse.
    pub fn updateWait(self: *Syntax, buf: *const Buffer) !void {
        try self.submit(buf);
        if (self.tree == null or self.version != buf.version) {
            if (self.worker.wait(buf.version)) |r| self.install(r);
        }
        self.alignTree(buf);
        if (self.tree == null or self.version != buf.version) return error.ParseFailed;
    }

    /// Edits `tree` from the text of `snap` to the current text. The diff
    /// of two snapshots that share most leaves is fast, so this is cheap
    /// enough for each key.
    fn alignTree(self: *Syntax, buf: *const Buffer) void {
        const tree = self.tree orelse return;
        const old = self.snap.?;
        if (self.snap_version == buf.version) return;
        const new = self.worker.snapshot();
        const edit = inputEdit(old, new);
        c.ts_tree_edit(tree, &edit);
        self.worker.release(old);
        self.snap = new;
        self.snap_version = buf.version;
    }

    fn submit(self: *Syntax, buf: *const Buffer) !void {
        std.debug.assert(&buf.rope == self.worker.rope);
        if (buf.len() > std.math.maxInt(u32)) return error.FileTooBig;
        try self.worker.submit(buf.version);
    }

    fn install(self: *Syntax, r: ParseWorker.Result) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        if (self.snap) |s| self.worker.release(s);
        self.tree = r.output;
        self.snap = r.text.snap;
        self.version = r.text.version;
        self.snap_version = r.text.version;
    }

    /// The smallest node at `pos`, or null without a tree. Call `update`
    /// first, so that the tree matches the current text.
    pub fn nodeAt(self: *const Syntax, pos: usize) ?c.TSNode {
        const r = self.root() orelse return null;
        const p: u32 = @intCast(pos);
        const n = c.ts_node_descendant_for_byte_range(r, p, p);
        return if (c.ts_node_is_null(n)) null else n;
    }

    /// Where the indentation of a line comes from: the line where the
    /// innermost enclosing node starts (the "anchor line").
    pub const IndentAnchor = struct {
        /// The start of the anchor line, or null at the top level.
        line: ?usize,
        /// True: one level more than the anchor line. False: the same, for a
        /// line that closes the node (it starts with the last token of the
        /// node, for example "}", ")", "end" or "</div>") or starts a branch
        /// of it (for example "else").
        deeper: bool,
    };

    /// The indent anchor of a line from the syntax tree. `first` is the first
    /// byte of the line that is not a space or a tab, or the line end if the
    /// line is blank. Call `update` first.
    ///
    /// The caller adds one level to the real indentation of the anchor
    /// line, so the result follows the style that the file uses. Thus
    /// "} else {" gets the indentation of its "if", and the lines in the
    /// else block get one level more.
    ///
    /// Null without a tree, if the line starts inside a multi-line string
    /// or comment, or if an enclosing node has a syntax error. While you
    /// type, the code is often incomplete (a block without its end), and
    /// such a tree is not correct. Then the caller uses its own rules.
    pub fn indentAnchor(self: *const Syntax, first: usize, blank: bool) ?IndentAnchor {
        const r = self.root() orelse return null;
        const snap = self.snap orelse return null;
        const p: u32 = @intCast(first);
        const row = snap.pointAt(first).row;
        const leaf = c.ts_node_descendant_for_byte_range(r, p, p);
        var node = leaf;
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            if (c.ts_node_is_null(c.ts_node_parent(node))) break; // the root
            const start = c.ts_node_start_point(node);
            if (start.row >= row) continue;
            const kind = std.mem.span(c.ts_node_type(node));
            if (std.mem.indexOf(u8, kind, "string") != null or std.mem.indexOf(u8, kind, "comment") != null) return null;
            if (c.ts_node_has_error(node)) return null;
            const same = !blank and (closesAt(node, p) or startsBranch(leaf, p));
            return .{ .line = c.ts_node_start_byte(node) - start.column, .deeper = !same };
        }
        // Only the root encloses the line. An error in the root makes the
        // top level uncertain too.
        if (c.ts_node_has_error(r)) return null;
        return .{ .line = null, .deeper = false };
    }

    /// Keywords that start a branch of the node that encloses them. A line
    /// that starts with one gets the indentation of the anchor line.
    const branch_keywords = [_][]const u8{ "else", "elif", "elseif", "except", "finally", "catch" };

    /// True if the token at `p` is a branch keyword, for example "else".
    fn startsBranch(leaf: c.TSNode, p: u32) bool {
        if (c.ts_node_is_null(leaf) or c.ts_node_is_named(leaf) or c.ts_node_start_byte(leaf) != p) return false;
        const kind = std.mem.span(c.ts_node_type(leaf));
        for (branch_keywords) |k| if (std.mem.eql(u8, kind, k)) return true;
        return false;
    }

    /// True if the line at `p` closes `node`: the last child of
    /// `node` starts at `p`, and it is one of these:
    ///   - a closing token, for example "}", ")" or "end",
    ///   - an end tag, for example "</p>" (a node type with "end_tag" or
    ///     "closing" in it),
    ///   - a block that starts with "{" on its own line (Allman style).
    /// Other last children, for example the last statement of a case, do
    /// not close the node.
    fn closesAt(node: c.TSNode, p: u32) bool {
        const count = c.ts_node_child_count(node);
        if (count == 0) return false;
        const last = c.ts_node_child(node, count - 1);
        if (c.ts_node_start_byte(last) != p or c.ts_node_is_missing(last)) return false;
        if (!c.ts_node_is_named(last)) return true;
        const kind = std.mem.span(c.ts_node_type(last));
        if (std.mem.indexOf(u8, kind, "end_tag") != null or std.mem.indexOf(u8, kind, "closing") != null) return true;
        if (c.ts_node_child_count(last) == 0) return false;
        const first_token = c.ts_node_child(last, 0);
        return !c.ts_node_is_named(first_token) and std.mem.eql(u8, std.mem.span(c.ts_node_type(first_token)), "{");
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

        const snap = self.snap orelse return;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.gpa);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (!try hl.passes(&match, snap, self.gpa, &scratch)) continue;
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

fn diffEdit(old: []const u8, new: []const u8) !c.TSInputEdit {
    var a = try Rope.fromSlice(testing.allocator, old);
    defer a.deinit();
    var b = try Rope.fromSlice(testing.allocator, new);
    defer b.deinit();
    const sa = a.snapshot();
    defer a.release(sa);
    const sb = b.snapshot();
    defer b.release(sb);
    return inputEdit(sa, sb);
}

fn expectEdit(old: []const u8, new: []const u8, start: u32, old_end: u32, new_end: u32) !void {
    const e = try diffEdit(old, new);
    try testing.expectEqual(start, e.start_byte);
    try testing.expectEqual(old_end, e.old_end_byte);
    try testing.expectEqual(new_end, e.new_end_byte);
}

test "inputEdit finds the changed range" {
    try expectEdit("abc", "abc", 3, 3, 3); // no change
    try expectEdit("abc", "abXc", 2, 2, 3); // insert
    try expectEdit("abXc", "abc", 2, 3, 2); // delete
    try expectEdit("abc", "aYc", 1, 2, 2); // replace
    try expectEdit("", "abc", 0, 0, 3);
    try expectEdit("abc", "", 0, 3, 0);
    // A repeated character: the prefix and the suffix must not overlap.
    try expectEdit("aa", "aaa", 2, 2, 3);
    try expectEdit("aaa", "aa", 2, 3, 2);
}

test "inputEdit gives rows and byte columns" {
    const e = try diffEdit("ab\ncd\nef", "ab\ncX\nY\nd\nef");
    try testing.expectEqual(c.TSPoint{ .row = 1, .column = 1 }, e.start_point);
    try testing.expectEqual(c.TSPoint{ .row = 1, .column = 1 }, e.old_end_point);
    try testing.expectEqual(c.TSPoint{ .row = 3, .column = 0 }, e.new_end_point);
    // A change on the first row adds to the start column.
    const f = try diffEdit("abc", "abXYc");
    try testing.expectEqual(c.TSPoint{ .row = 0, .column = 4 }, f.new_end_point);
}
