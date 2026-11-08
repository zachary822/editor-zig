const std = @import("std");
const Io = std.Io;
const c = @import("c");
const keys = @import("keys.zig");
const keymap = @import("keymap.zig");
const Buffer = @import("buffer.zig").Buffer;
const KillRing = @import("kill_ring.zig").KillRing;
const files = @import("files.zig");
const minibuffer = @import("minibuffer.zig");
const Minibuffer = minibuffer.Minibuffer;
const History = minibuffer.History;
const completion = @import("completion.zig");
const ts = @import("syntax.zig");
const PrefixArg = @import("prefix_arg.zig").PrefixArg;

const kitty_on = "\x1b[>1u";
const kitty_off = "\x1b[<u";

/// Commands that are written in Zig. Lua can bind keys to these by name,
/// for example `editor.bind("C-a", "backward_char")`.
const Builtin = enum {
    previous_line,
    next_line,
    backward_char,
    forward_char,
    move_beginning_of_line,
    move_end_of_line,
    /// C-v: show the next page. Emacs calls this "scroll up".
    scroll_up_command,
    /// M-v: show the previous page.
    scroll_down_command,
    newline,
    tab_to_tab_stop,
    delete_backward_char,
    delete_char,
    kill_line,
    set_mark_command,
    exchange_point_and_mark,
    kill_region,
    kill_ring_save,
    yank,
    yank_pop,
    undo,
    redo,
    find_file,
    save_buffer,
    quit,
    // Minibuffer commands. Outside the minibuffer, they beep.
    exit_minibuffer,
    minibuffer_complete,
    previous_history_element,
    next_history_element,
    // Structural movement with the syntax tree.
    forward_sexp,
    backward_sexp,
    backward_up_list,
    down_list,
    beginning_of_defun,
    end_of_defun,
    // The prefix argument: C-u, M-0 to M-9 and M--.
    universal_argument,
    digit_argument,
    negative_argument,

    /// The command that a negative prefix argument runs, for example
    /// C-u - 3 C-f runs backward_char 3 times.
    fn opposite(self: Builtin) ?Builtin {
        return switch (self) {
            .forward_char => .backward_char,
            .backward_char => .forward_char,
            .next_line => .previous_line,
            .previous_line => .next_line,
            .delete_char => .delete_backward_char,
            .delete_backward_char => .delete_char,
            .forward_sexp => .backward_sexp,
            .backward_sexp => .forward_sexp,
            .beginning_of_defun => .end_of_defun,
            .end_of_defun => .beginning_of_defun,
            .undo => .redo,
            .redo => .undo,
            else => null,
        };
    }

    /// True for commands that read the prefix argument themselves. The other
    /// commands repeat, or run once if `runsOnce` is true.
    fn readsArg(self: Builtin) bool {
        return switch (self) {
            .kill_line, .yank, .set_mark_command, .scroll_up_command, .scroll_down_command => true,
            else => false,
        };
    }

    fn runsOnce(self: Builtin) bool {
        return switch (self) {
            .exchange_point_and_mark, .kill_region, .kill_ring_save, .find_file, .save_buffer => true,
            .quit, .exit_minibuffer, .minibuffer_complete => true,
            .universal_argument, .digit_argument, .negative_argument => true,
            else => false,
        };
    }

    /// True for commands that do nothing useful in the minibuffer. They beep
    /// there, as Emacs does not allow a minibuffer inside a minibuffer.
    fn mainBufferOnly(self: Builtin) bool {
        return switch (self) {
            .scroll_up_command, .scroll_down_command, .find_file, .save_buffer, .quit => true,
            .forward_sexp, .backward_sexp, .backward_up_list, .down_list => true,
            .beginning_of_defun, .end_of_defun => true,
            else => false,
        };
    }
};

const Command = union(enum) {
    builtin: Builtin,
    /// A Lua function, kept in the Lua registry by `luaL_ref`.
    lua: c_int,
};

const Keymap = keymap.Keymap(Command);
const Dispatcher = keymap.Dispatcher(Command);

const default_bindings = [_]struct { []const u8, Builtin }{
    .{ "<up>", .previous_line },
    .{ "C-p", .previous_line },
    .{ "<down>", .next_line },
    .{ "C-n", .next_line },
    .{ "<left>", .backward_char },
    .{ "C-b", .backward_char },
    .{ "<right>", .forward_char },
    .{ "C-f", .forward_char },
    .{ "<home>", .move_beginning_of_line },
    .{ "C-a", .move_beginning_of_line },
    .{ "<end>", .move_end_of_line },
    .{ "C-e", .move_end_of_line },
    .{ "C-v", .scroll_up_command },
    .{ "<next>", .scroll_up_command },
    .{ "M-v", .scroll_down_command },
    .{ "<prior>", .scroll_down_command },
    .{ "RET", .newline },
    .{ "TAB", .tab_to_tab_stop },
    .{ "DEL", .delete_backward_char },
    .{ "<delete>", .delete_char },
    .{ "C-d", .delete_char },
    .{ "C-k", .kill_line },
    // Terminals send C-SPC and C-@ as 0x00, which is C-SPC here.
    .{ "C-SPC", .set_mark_command },
    .{ "C-x C-x", .exchange_point_and_mark },
    .{ "C-w", .kill_region },
    .{ "M-w", .kill_ring_save },
    .{ "C-y", .yank },
    .{ "M-y", .yank_pop },
    .{ "C-/", .undo },
    .{ "C-x u", .undo },
    // Emacs binds redo to C-? and C-M-_. Terminals send C-M-_ as ESC 0x1f,
    // which is C-M-/ here. C-S-/ is C-? on a US keyboard with Kitty.
    .{ "C-M-/", .redo },
    .{ "C-S-/", .redo },
    .{ "C-M-f", .forward_sexp },
    .{ "C-M-b", .backward_sexp },
    .{ "C-M-u", .backward_up_list },
    .{ "C-M-d", .down_list },
    .{ "C-M-a", .beginning_of_defun },
    .{ "C-M-e", .end_of_defun },
    .{ "C-u", .universal_argument },
    .{ "M--", .negative_argument },
    .{ "M-0", .digit_argument },
    .{ "M-1", .digit_argument },
    .{ "M-2", .digit_argument },
    .{ "M-3", .digit_argument },
    .{ "M-4", .digit_argument },
    .{ "M-5", .digit_argument },
    .{ "M-6", .digit_argument },
    .{ "M-7", .digit_argument },
    .{ "M-8", .digit_argument },
    .{ "M-9", .digit_argument },
    .{ "C-x C-f", .find_file },
    .{ "C-x C-s", .save_buffer },
    .{ "C-x C-c", .quit },
};

/// The minibuffer keymap. The dispatcher searches it before the global
/// keymap while the minibuffer is open, as Emacs `minibuffer-local-map`.
const minibuffer_bindings = [_]struct { []const u8, Builtin }{
    .{ "RET", .exit_minibuffer },
    .{ "TAB", .minibuffer_complete },
    .{ "M-p", .previous_history_element },
    .{ "<up>", .previous_history_element },
    .{ "M-n", .next_history_element },
    .{ "<down>", .next_history_element },
};

const tab_width = 8;

const prefix_arg_max = @import("prefix_arg.zig").max_count;

/// The number of lines that stay on the screen after C-v or M-v, as Emacs
/// `next-screen-context-lines`.
const page_context_lines = 2;

/// The ncurses color pair for the region.
const region_pair = 1;

/// The ncurses colors for each syntax face. Face n uses color pair n + 1.
const face_colors = std.enums.EnumArray(ts.Face, c_short).init(.{
    .none = -1,
    .keyword = c.COLOR_MAGENTA,
    .string = c.COLOR_GREEN,
    .comment = 8, // bright black, if the terminal has 16 colors
    .function = c.COLOR_BLUE,
    .type = c.COLOR_CYAN,
    .constant = c.COLOR_RED,
    .attribute = c.COLOR_YELLOW,
});

/// The screen rows below the text: the mode line and the echo area.
const footer_rows = 2;

/// What the open minibuffer asks for.
const Prompt = enum {
    find_file,
    write_file,
    /// "yes" discards unsaved changes, then asks for a file to open.
    confirm_find_file,
    /// "yes" quits without a save.
    confirm_quit,

    fn text(self: Prompt) []const u8 {
        return switch (self) {
            .find_file => "Find file: ",
            .write_file => "File to save in: ",
            .confirm_find_file => "Buffer modified; discard changes? (yes or no) ",
            .confirm_quit => "Modified buffer exists; exit anyway? (yes or no) ",
        };
    }

    /// The prompt after an answer that is not "yes" or "no".
    fn retryText(self: Prompt) []const u8 {
        return switch (self) {
            inline else => |p| "Please answer yes or no.  " ++ comptime p.text(),
        };
    }
};

fn bindDefaults(km: *Keymap, mb_km: *Keymap, gpa: std.mem.Allocator) !void {
    for (default_bindings) |b| try km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
    for (minibuffer_bindings) |b| try mb_km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
}

const Editor = struct {
    max_y: c_int,
    max_x: c_int,
    buffer: Buffer,
    /// The buffer line at the top of the screen.
    top: usize = 0,
    /// The display column at the left edge of the screen.
    left: usize = 0,
    running: bool = true,
    dispatcher: Dispatcher,
    L: *c.lua_State,
    kill_ring: KillRing,
    /// The last builtin command, or null after a typed key or a Lua command.
    /// Consecutive kills and yank-pop use it.
    last_command: ?Builtin = null,
    /// The text that the last yank or yank-pop inserted. Yank-pop replaces it.
    yank_start: usize = 0,
    yank_end: usize = 0,
    /// The ncurses attribute for the active region.
    region_attr: c_int,
    gpa: std.mem.Allocator,
    io: Io,
    /// The home directory, for "~" in file names.
    home: ?[]const u8,
    /// The open minibuffer and what it asks for.
    minibuffer: ?Minibuffer = null,
    prompt: Prompt = .find_file,
    /// The keymap that comes before the global keymap in the minibuffer.
    minibuffer_keymap: *const Keymap,
    /// Earlier file names, for M-p and M-n, as Emacs `file-name-history`.
    file_history: History,
    /// The languages from `init.lua`.
    languages: *ts.Languages,
    /// The syntax tree of the main buffer, if its file has a language.
    syntax: ?ts.Syntax = null,
    /// The ncurses attribute for each syntax face.
    face_attrs: std.enums.EnumArray(ts.Face, c_int) = .initFill(0),
    /// The prefix argument while the user types it (C-u 12 ...).
    prefix_arg: ?PrefixArg = null,
    /// The message in the echo area. The next key clears it. While the
    /// minibuffer is open, it shows after the input in brackets.
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    fn init(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, L: *c.lua_State, km: *const Keymap, mb_km: *const Keymap, languages: *ts.Languages) Editor {
        var self: Editor = .{
            .max_y = c.getmaxy(c.stdscr),
            .max_x = c.getmaxx(c.stdscr),
            .buffer = .init(gpa),
            .dispatcher = .init(km),
            .L = L,
            .kill_ring = .init(gpa),
            .region_attr = initColors(),
            .gpa = gpa,
            .io = io,
            .home = home,
            .minibuffer_keymap = mb_km,
            .file_history = .init(gpa),
            .languages = languages,
        };
        self.initFaceColors();
        return self;
    }

    /// Makes a color pair for each syntax face: a foreground color on the
    /// terminal's own background.
    fn initFaceColors(self: *Editor) void {
        if (!c.has_colors()) return;
        for (std.enums.values(ts.Face)) |face| {
            if (face == .none) continue;
            var color = face_colors.get(face);
            if (color >= c.COLORS) color = c.COLOR_BLUE; // no bright black
            const pair: c_short = @intCast(@intFromEnum(face) + 1);
            _ = c.init_pair(pair, color, -1);
            self.face_attrs.set(face, @intCast(c.COLOR_PAIR(pair)));
        }
    }

    /// The buffer that editing commands change: the minibuffer while it is
    /// open, and the main buffer at other times.
    fn activeBuffer(self: *Editor) *Buffer {
        if (self.minibuffer) |*mb| return &mb.buffer;
        return &self.buffer;
    }

    /// Sets up colors and returns the attribute for the region: black text
    /// on a yellow background, or reverse video if the terminal has no colors.
    fn initColors() c_int {
        if (!c.has_colors()) return @intCast(c.A_REVERSE);
        _ = c.start_color();
        // Keep the terminal's own colors for normal text (color -1).
        _ = c.use_default_colors();
        _ = c.init_pair(region_pair, c.COLOR_BLACK, c.COLOR_YELLOW);
        return @intCast(c.COLOR_PAIR(region_pair));
    }

    fn deinit(self: *Editor) void {
        if (self.syntax) |*s| s.deinit();
        if (self.minibuffer) |*mb| mb.deinit();
        self.file_history.deinit();
        self.kill_ring.deinit();
        self.buffer.deinit();
    }

    /// Returns false when the editor must stop.
    fn handleKey(self: *Editor, event: keys.KeyEvent) bool {
        if (event.kind == .release) return self.running;
        self.message_len = 0;
        const in_sequence = self.dispatcher.isPending();
        switch (self.dispatcher.feed(event)) {
            .run => |cmd| {
                // The prefix argument commands change the argument and keep it.
                if (cmd == .builtin and self.prefixCommand(cmd.builtin, event)) {} else {
                    const arg = self.prefix_arg;
                    self.prefix_arg = null;
                    self.run(cmd, arg);
                }
            },
            .prefix, .ignored => {},
            .cancel => {
                self.prefix_arg = null;
                self.last_command = null;
                if (!in_sequence and self.minibuffer != null) {
                    // C-g in the minibuffer cancels the prompt.
                    self.closeMinibuffer();
                    self.setMessage("Quit", .{});
                } else {
                    self.activeBuffer().deactivateMark();
                }
                _ = c.beep();
            },
            // An unbound printable key inserts itself, but not after a prefix.
            .unbound => |chord| typed: {
                if (!in_sequence and chord.isPrintable()) {
                    const cp = event.typedCodepoint().?;
                    // After C-u, digits and "-" are a part of the number.
                    if (self.prefix_arg) |*a| if (a.takesChar(cp)) {
                        if (cp == '-') a.addMinus() else a.addDigit(@intCast(cp - '0'));
                        break :typed;
                    };
                    const arg = self.prefix_arg;
                    self.prefix_arg = null;
                    self.last_command = null;
                    self.selfInsert(cp, if (arg) |a| a.count() else 1) catch {
                        _ = c.beep();
                    };
                } else {
                    self.prefix_arg = null;
                    self.last_command = null;
                    _ = c.beep();
                }
            },
        }
        // As in Emacs, show the argument while the user types it.
        if (self.prefix_arg) |a| self.setMessage("C-u {d}-", .{a.count()});
        return self.running;
    }

    /// Runs C-u, M-0 to M-9 and M--. Returns false for other commands.
    fn prefixCommand(self: *Editor, b: Builtin, event: keys.KeyEvent) bool {
        switch (b) {
            .universal_argument => self.prefix_arg = PrefixArg.universal(self.prefix_arg),
            .negative_argument => self.prefix_arg = PrefixArg.negativeArgument(self.prefix_arg),
            .digit_argument => {
                const cp = event.typedCodepoint() orelse return true;
                if (cp < '0' or cp > '9') return true;
                self.prefix_arg = PrefixArg.digitArgument(self.prefix_arg, @intCast(cp - '0'));
            },
            else => return false,
        }
        return true;
    }

    /// Inserts a typed character `n` times as one undo step (C-u 5 x).
    fn selfInsert(self: *Editor, cp: u21, n: i64) !void {
        if (n < 0) return error.NegativeCount;
        if (n > prefix_arg_max) return error.CountTooLarge;
        if (n == 1) return self.activeBuffer().insertCodepoint(cp);
        var one: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &one);
        const text = try self.gpa.alloc(u8, len * @as(usize, @intCast(n)));
        defer self.gpa.free(text);
        var i: usize = 0;
        while (i < text.len) : (i += len) @memcpy(text[i..][0..len], one[0..len]);
        try self.activeBuffer().insert(text);
    }

    /// Runs a command with the prefix argument, if there is one. Most
    /// commands repeat. A negative count runs the opposite command.
    fn run(self: *Editor, cmd: Command, arg: ?PrefixArg) void {
        const n: i64 = if (arg) |a| a.count() else 1;
        if (@abs(n) > prefix_arg_max) {
            self.setMessage("Count too large", .{});
            _ = c.beep();
            return;
        }
        switch (cmd) {
            .builtin => |b| {
                if (arg == null or b.readsArg()) {
                    _ = self.runBuiltin(b, arg);
                    return;
                }
                if (b.runsOnce()) {
                    _ = self.runBuiltin(b, null);
                    return;
                }
                const each = if (n < 0) b.opposite() orelse b else b;
                var i: u64 = 0;
                while (i < @abs(n)) : (i += 1) {
                    if (!self.runBuiltin(each, null)) break; // stop at the first error
                }
            },
            .lua => |ref| {
                self.last_command = null;
                var i: u64 = 0;
                while (i < @abs(n)) : (i += 1) {
                    _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, ref);
                    if (c.lua_pcallk(self.L, 0, 0, 0, 0, null) != c.LUA_OK) {
                        c.lua_settop(self.L, -2); // pop the error message
                        break;
                    }
                }
            },
        }
    }

    /// Runs one builtin command. `arg` is the prefix argument for commands
    /// that read it. Returns false (and beeps) if the command fails.
    fn runBuiltin(self: *Editor, b: Builtin, arg: ?PrefixArg) bool {
        const prev = self.last_command;
        self.last_command = b;
        if (self.minibuffer != null and b.mainBufferOnly()) {
            _ = c.beep();
            return false;
        }
        const buf = self.activeBuffer();
        const result: anyerror!void = switch (b) {
            .previous_line => buf.previousLine(),
            .next_line => buf.nextLine(),
            .backward_char => buf.backwardChar(),
            .forward_char => buf.forwardChar(),
            .move_beginning_of_line => buf.lineStartPos(),
            .move_end_of_line => buf.lineEndPos(),
            .scroll_up_command => self.scrollCommand(true, arg),
            .scroll_down_command => self.scrollCommand(false, arg),
            .newline => buf.insert("\n"),
            .tab_to_tab_stop => buf.insert("\t"),
            .delete_backward_char => buf.deleteBackward(),
            .delete_char => buf.deleteForward(),
            .kill_line => self.killLine(isKill(prev), arg),
            // C-u C-SPC jumps to the mark, as in Emacs.
            .set_mark_command => if (arg != null) popToMark(buf) else buf.setMark(),
            .exchange_point_and_mark => buf.exchangePointAndMark(),
            .kill_region => self.killRegion(isKill(prev)),
            .kill_ring_save => self.copyRegion(),
            .yank => self.yank(arg),
            .yank_pop => self.yankPop(prev),
            .undo => buf.undo(),
            .redo => buf.redo(),
            .find_file => self.findFileCommand(),
            .save_buffer => self.saveBuffer(),
            .quit => self.quit(),
            .exit_minibuffer => self.exitMinibuffer(),
            .minibuffer_complete => self.minibufferComplete(),
            .previous_history_element => if (self.minibuffer) |*mb| mb.historyPrevious() else error.NotInMinibuffer,
            .next_history_element => if (self.minibuffer) |*mb| mb.historyNext() else error.NotInMinibuffer,
            .forward_sexp => self.syntaxMove(ts.Syntax.forwardSexp),
            .backward_sexp => self.syntaxMove(ts.Syntax.backwardSexp),
            .backward_up_list => self.syntaxMove(ts.Syntax.backwardUpList),
            .down_list => self.syntaxMove(ts.Syntax.downList),
            .beginning_of_defun => self.syntaxMove(ts.Syntax.beginningOfDefun),
            .end_of_defun => self.syntaxMove(ts.Syntax.endOfDefun),
            // handleKey runs these before the dispatch reaches this function.
            .universal_argument, .digit_argument, .negative_argument => {},
        };
        result catch {
            _ = c.beep();
            return false;
        };
        return true;
    }

    fn popToMark(buf: *Buffer) !void {
        const m = buf.mark orelse return error.NoMark;
        buf.moveTo(m);
        buf.deactivateMark();
    }

    // Echo area and minibuffer

    /// Shows a message in the echo area until the next key.
    fn setMessage(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch &self.message_buf;
        self.message_len = text.len;
    }

    fn openMinibuffer(self: *Editor, prompt: Prompt, initial: []const u8) !void {
        return self.openMinibufferText(prompt, prompt.text(), initial);
    }

    /// Opens the minibuffer with a different prompt text. `text` must be a
    /// static string.
    fn openMinibufferText(self: *Editor, prompt: Prompt, text: []const u8, initial: []const u8) !void {
        std.debug.assert(self.minibuffer == null);
        const history: ?*History = switch (prompt) {
            .find_file, .write_file => &self.file_history,
            .confirm_find_file, .confirm_quit => null,
        };
        self.minibuffer = try .init(self.gpa, text, initial, history);
        self.prompt = prompt;
        self.dispatcher.overlay = self.minibuffer_keymap;
    }

    fn closeMinibuffer(self: *Editor) void {
        if (self.minibuffer) |*mb| mb.deinit();
        self.minibuffer = null;
        self.dispatcher.overlay = null;
    }

    /// RET in the minibuffer: closes it, adds the input to the history and
    /// acts on the input.
    fn exitMinibuffer(self: *Editor) !void {
        const mb = if (self.minibuffer) |*m| m else return error.NotInMinibuffer;
        const input = try mb.text(self.gpa);
        defer self.gpa.free(input);
        if (mb.history) |h| try h.add(input);
        self.closeMinibuffer();
        self.finishPrompt(self.prompt, input) catch |err| {
            self.setMessage("Error: {t}", .{err});
            return err;
        };
    }

    /// TAB in the minibuffer: completes the file name, as Emacs does.
    /// - One match: the input becomes that name.
    /// - More matches with a longer common prefix: the input becomes the prefix.
    /// - More matches with no longer prefix: the echo area lists them.
    fn minibufferComplete(self: *Editor) !void {
        const mb = if (self.minibuffer) |*m| m else return error.NotInMinibuffer;
        if (self.prompt != .find_file and self.prompt != .write_file) return error.NoCompletion;

        const input = try mb.text(self.gpa);
        defer self.gpa.free(input);
        var comp = try completion.completeFileName(self.io, Io.Dir.cwd(), self.gpa, input, self.home);
        defer comp.deinit();

        switch (comp.matches.len) {
            0 => {
                self.setMessage("No match", .{});
                return error.NoMatch;
            },
            1 => {
                try mb.setText(comp.text);
                if (!std.mem.endsWith(u8, comp.text, "/")) self.setMessage("Sole completion", .{});
            },
            else => if (comp.text.len > input.len) {
                try mb.setText(comp.text);
            } else {
                self.listMatches(comp.matches);
            },
        }
    }

    /// Shows completion matches in the echo area: "{a.txt | b.txt | src/}".
    fn listMatches(self: *Editor, matches: []const []const u8) void {
        var w: std.Io.Writer = .fixed(&self.message_buf);
        w.writeAll("{") catch {};
        for (matches, 0..) |m, i| {
            if (i > 0) w.writeAll(" | ") catch break;
            w.writeAll(m) catch break;
        }
        w.writeAll("}") catch {};
        self.message_len = w.end;
    }

    /// Acts on the input of a minibuffer that the user accepted with RET.
    fn finishPrompt(self: *Editor, prompt: Prompt, input: []const u8) !void {
        switch (prompt) {
            .find_file, .write_file => {
                if (input.len == 0) return self.setMessage("No file name", .{});
                const path = try files.expandPath(self.gpa, input, self.home);
                defer self.gpa.free(path);
                if (prompt == .find_file) {
                    try self.findFile(path);
                } else {
                    try self.buffer.setFilePath(path);
                    try self.writeFile();
                    self.attachSyntax(); // the new name can have a language
                }
            },
            .confirm_find_file, .confirm_quit => {
                if (std.mem.eql(u8, input, "yes")) {
                    if (prompt == .confirm_quit) {
                        self.running = false;
                    } else {
                        try self.openFindFile();
                    }
                } else if (std.mem.eql(u8, input, "no")) {
                    self.setMessage("Cancelled", .{});
                } else {
                    // As in Emacs, ask again until the answer is yes or no.
                    try self.openMinibufferText(prompt, prompt.retryText(), "");
                }
            },
        }
    }

    // Files

    /// C-x C-f. If the buffer has unsaved changes, asks first.
    fn findFileCommand(self: *Editor) !void {
        if (self.buffer.isModified()) return self.openMinibuffer(.confirm_find_file, "");
        try self.openFindFile();
    }

    /// Asks for a file name. The input starts with the directory of the
    /// current file, as in Emacs.
    fn openFindFile(self: *Editor) !void {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const initial: []const u8 = blk: {
            const path = self.buffer.file_path orelse break :blk "";
            const dir = std.fs.path.dirname(path) orelse break :blk "";
            break :blk std.fmt.bufPrint(&dir_buf, "{s}/", .{dir}) catch "";
        };
        try self.openMinibuffer(.find_file, initial);
    }

    /// Replaces the buffer with the text of `path`. If the file does not
    /// exist, the buffer is empty, and the first save makes the file.
    fn findFile(self: *Editor, path: []const u8) !void {
        const text = files.readFile(self.io, Io.Dir.cwd(), self.gpa, path) catch |err| {
            return self.setMessage("Cannot open {s}: {t}", .{ path, err });
        };
        defer if (text) |t| self.gpa.free(t);

        var new_buf: Buffer = if (text) |t| try .initText(self.gpa, t) else .init(self.gpa);
        errdefer new_buf.deinit();
        try new_buf.setFilePath(path);

        self.buffer.deinit();
        self.buffer = new_buf;
        self.top = 0;
        self.left = 0;
        self.last_command = null;
        if (text == null) self.setMessage("(New file)", .{});
        self.attachSyntax();
    }

    /// Finds the language of the buffer's file and makes a syntax tree for
    /// it. If the grammar cannot load, the echo area shows the cause, and
    /// the buffer has no highlighting.
    fn attachSyntax(self: *Editor) void {
        if (self.syntax) |*s| s.deinit();
        self.syntax = null;
        const path = self.buffer.file_path orelse return;
        const cfg = self.languages.forPath(path) orelse return;
        const lang = self.languages.load(self.io, cfg) catch {
            return self.setMessage("Cannot load language {s}: {s}", .{ cfg.name, self.languages.lastError() });
        };
        self.syntax = ts.Syntax.init(self.gpa, lang) catch |err| {
            return self.setMessage("Cannot use language {s}: {t}", .{ cfg.name, err });
        };
    }

    /// Moves the cursor with a syntax tree function.
    fn syntaxMove(self: *Editor, comptime move: fn (*const ts.Syntax, usize) ?usize) !void {
        const syn = if (self.syntax) |*s| s else {
            self.setMessage("No syntax tree for this buffer", .{});
            return error.NoSyntax;
        };
        try syn.update(&self.buffer);
        const pos = move(syn, self.buffer.cursor) orelse return error.CannotMove;
        self.buffer.moveTo(pos);
    }

    /// C-x C-s. Asks for a file name if the buffer has no file.
    fn saveBuffer(self: *Editor) !void {
        if (self.buffer.file_path == null) return self.openMinibuffer(.write_file, "");
        if (!self.buffer.isModified()) return self.setMessage("(No changes need to be saved)", .{});
        try self.writeFile();
    }

    fn writeFile(self: *Editor) !void {
        const path = self.buffer.file_path.?;
        files.writeBuffer(self.io, Io.Dir.cwd(), self.gpa, path, &self.buffer) catch |err| {
            return self.setMessage("Cannot save {s}: {t}", .{ path, err });
        };
        self.buffer.markSaved();
        self.setMessage("Wrote {s}", .{path});
    }

    /// C-x C-c. If the buffer has unsaved changes, asks first.
    fn quit(self: *Editor) !void {
        if (self.buffer.isModified()) return self.openMinibuffer(.confirm_quit, "");
        self.running = false;
    }

    /// The number of screen rows for buffer text.
    fn textRows(self: *const Editor) usize {
        const rows: usize = @intCast(@max(0, self.max_y));
        return @max(1, rows -| footer_rows);
    }

    /// Shows the next (or previous) page. The screen and the cursor move by
    /// the same number of lines, so the cursor stays on the same screen row.
    /// At the end (or start) of the buffer, the cursor moves as far as it can.
    /// If it cannot move, the command gives an error (a beep).
    fn scrollPage(self: *Editor, down: bool) !void {
        const rows = self.textRows();
        return self.scrollLines(down, @max(1, rows -| page_context_lines));
    }

    /// C-v and M-v. With a prefix argument N, scroll N lines, not a page, as
    /// in Emacs. A negative N scrolls the other way.
    fn scrollCommand(self: *Editor, down: bool, arg: ?PrefixArg) !void {
        const a = arg orelse return self.scrollPage(down);
        const n = a.count();
        if (n == 0) return;
        return self.scrollLines(down != (n < 0), @intCast(@abs(n)));
    }

    fn scrollLines(self: *Editor, down: bool, step: usize) !void {
        const moved = self.buffer.moveLines(down, step);
        if (moved == 0) return if (down) error.EndOfBuffer else error.BeginningOfBuffer;
        if (down) self.top += moved else self.top -|= moved;
    }

    /// True for commands whose kills join into one kill ring entry when they
    /// come one after the other.
    fn isKill(cmd: ?Builtin) bool {
        return cmd == .kill_line or cmd == .kill_region;
    }

    /// Kills the rest of the line into the kill ring. Consecutive kills add
    /// to the same entry, so C-k C-k kills a line and its newline together.
    /// With a prefix argument N, kills N whole lines (see `Buffer.killLines`).
    fn killLine(self: *Editor, append: bool, arg: ?PrefixArg) !void {
        const buf = self.activeBuffer();
        const text = if (arg) |a|
            try buf.killLines(self.kill_ring.gpa, a.count()) orelse return
        else
            try buf.killLine(self.kill_ring.gpa) orelse return;
        try self.addKill(text, append);
    }

    /// Kills the region (C-w) into the kill ring.
    fn killRegion(self: *Editor, append: bool) !void {
        const text = try self.activeBuffer().killRegion(self.kill_ring.gpa);
        try self.addKill(text, append);
    }

    /// Copies the region (M-w) into the kill ring and leaves the text.
    fn copyRegion(self: *Editor) !void {
        const text = try self.activeBuffer().copyRegion(self.kill_ring.gpa);
        try self.kill_ring.push(text);
    }

    /// Gives `text` to the kill ring. An empty kill adds nothing.
    fn addKill(self: *Editor, text: []u8, append: bool) !void {
        if (text.len == 0) return self.kill_ring.gpa.free(text);
        if (append) try self.kill_ring.appendToNewest(text) else try self.kill_ring.push(text);
    }

    /// Inserts the newest kill at the cursor. As in Emacs:
    /// - C-u N C-y inserts the Nth newest kill.
    /// - C-u C-y puts the cursor before the text and the mark after it.
    fn yank(self: *Editor, arg: ?PrefixArg) !void {
        const numeric = if (arg) |a| !a.raw else false;
        const text = if (numeric) blk: {
            const n = arg.?.count();
            if (n < 1) return error.InvalidCount;
            break :blk self.kill_ring.yankAt(@intCast(n - 1));
        } else self.kill_ring.yank();
        const t = text orelse return error.KillRingEmpty;

        const buf = self.activeBuffer();
        self.yank_start = buf.cursor;
        try buf.insert(t);
        self.yank_end = buf.cursor;
        if (arg != null and !numeric) {
            buf.mark = self.yank_end;
            buf.moveTo(self.yank_start);
        }
    }

    /// Replaces the text that the last yank inserted with the kill before it.
    /// Works only right after a yank or a yank-pop.
    fn yankPop(self: *Editor, prev: ?Builtin) !void {
        if (prev != .yank and prev != .yank_pop) return error.PreviousNotYank;
        const text = self.kill_ring.yankPop() orelse return error.KillRingEmpty;
        try self.activeBuffer().replaceRange(self.yank_start, self.yank_end, text);
        self.yank_end = self.activeBuffer().cursor;
    }

    fn resize(self: *Editor) void {
        self.max_y = c.getmaxy(c.stdscr);
        self.max_x = c.getmaxx(c.stdscr);
    }

    /// Scrolls vertically and horizontally so that the cursor is on the screen.
    fn scroll(self: *Editor) void {
        const rows = self.textRows();
        const line = self.buffer.cursorLine();
        if (line < self.top) self.top = line;
        if (line >= self.top + rows) self.top = line - rows + 1;

        const cols: usize = @intCast(@max(1, self.max_x));
        const col = self.buffer.displayColumn(self.buffer.cursor, tab_width);
        if (col < self.left) self.left = col;
        if (col >= self.left + cols) self.left = col - cols + 1;
    }

    /// Draws the visible part of the buffer and puts the cursor on the screen.
    /// All lines scroll horizontally together. Each codepoint uses one cell.
    /// The active region shows in reverse video.
    fn render(self: *Editor) void {
        self.scroll();
        _ = c.erase();

        const rows = self.textRows();
        const cols: usize = @intCast(@max(1, self.max_x));
        const cursor = self.buffer.cursor;
        const region = self.buffer.activeRegion();

        // Syntax faces for the visible bytes only.
        const vis_start = self.buffer.lineOffset(self.top);
        const faces = self.visibleFaces(vis_start, self.buffer.lineOffset(self.top + rows));
        defer self.gpa.free(faces);

        var line: usize = 0;
        var col: usize = 0;
        var pos: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;

        // A codepoint can cross a chunk boundary, so collect its bytes here.
        var cp_buf: [4]u8 = undefined;
        var cp_len: usize = 0;
        var cp_need: usize = 0;
        var cp_start: usize = 0;

        var it = self.buffer.rope.chunks();
        outer: while (it.next()) |chunk| {
            for (chunk) |byte| {
                defer pos += 1;
                if (cp_len == 0) {
                    if (pos == cursor) {
                        cursor_row = line -| self.top;
                        cursor_col = col;
                    }
                    cp_need = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                    cp_start = pos;
                }
                cp_buf[cp_len] = byte;
                cp_len += 1;
                if (cp_len < cp_need) continue;
                const bytes = cp_buf[0..cp_len];
                cp_len = 0;

                if (bytes[0] == '\n') {
                    line += 1;
                    col = 0;
                    if (line >= self.top + rows) break :outer;
                    continue;
                }
                const highlight = if (region) |r| cp_start >= r.start and cp_start < r.end else false;
                const visible = line >= self.top;
                const row: c_int = @intCast(line -| self.top);
                if (bytes[0] == '\t') {
                    const next = (col / tab_width + 1) * tab_width;
                    // erase() cleared these cells. Draw spaces only to show the region.
                    if (visible and highlight) {
                        while (col < next) : (col += 1) self.drawCell(row, col, cols, " ", self.region_attr);
                    }
                    col = next;
                    continue;
                }
                if (visible) {
                    const text: []const u8 = if (bytes[0] < 0x20 or bytes[0] == 0x7f or
                        !std.unicode.utf8ValidateSlice(bytes)) "?" else bytes;
                    // The region color wins over the syntax color.
                    const attr = if (highlight) self.region_attr else blk: {
                        const i = cp_start -| vis_start;
                        break :blk if (cp_start >= vis_start and i < faces.len) self.face_attrs.get(faces[i]) else 0;
                    };
                    self.drawCell(row, col, cols, text, attr);
                }
                col += 1;
            }
        }
        if (pos == cursor) {
            cursor_row = line -| self.top;
            cursor_col = col;
        }

        // The footer needs the full screen height. On a tiny screen, skip it.
        if (self.max_y > footer_rows) {
            self.drawModeLine(@intCast(rows), cols);
            const echo_row: c_int = self.max_y - 1;
            if (self.minibuffer) |*mb| {
                const mb_col = self.drawMinibuffer(mb, echo_row, cols);
                _ = c.move(echo_row, @intCast(mb_col));
                _ = c.refresh();
                return;
            }
            // A message keeps its start. The screen edge cuts the end.
            var msg_line: CellLine = .{ .row = echo_row, .cols = cols, .left = 0, .attr = 0, .draw = true };
            msg_line.putText(self.message_buf[0..self.message_len]);
        }

        const screen_col = @min(cursor_col -| self.left, cols - 1);
        _ = c.move(@intCast(cursor_row), @intCast(screen_col));
        _ = c.refresh();
    }

    /// Draws the mode line in reverse video: the modified mark, the buffer
    /// name and the cursor line and column, as in Emacs.
    fn drawModeLine(self: *const Editor, row: c_int, cols: usize) void {
        const buf = &self.buffer;
        const name = if (buf.file_path) |p| std.fs.path.basename(p) else "*scratch*";
        const state = if (buf.isModified()) "**" else "--";
        const line_no = buf.cursorLine() + 1;
        const col_no = buf.displayColumn(buf.cursor, tab_width);

        var text_buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "-:{s}-  {s}    L{d} C{d}", .{ state, name, line_no, col_no }) catch &text_buf;

        _ = c.attron(@intCast(c.A_REVERSE));
        defer _ = c.attroff(@intCast(c.A_REVERSE));
        _ = c.move(row, 0);
        var i: usize = 0;
        while (i < cols) : (i += 1) _ = c.addch(' ');
        _ = drawTail(row, &.{text}, cols);
    }

    /// Draws the prompt, the input and a message in brackets on the echo row.
    /// A long line scrolls so that the cursor stays on the screen. Control
    /// characters in the input show as "^J" and so on. Returns the cursor
    /// column.
    fn drawMinibuffer(self: *Editor, mb: *Minibuffer, row: c_int, cols: usize) usize {
        const input = mb.text(self.gpa) catch return 0;
        defer self.gpa.free(input);
        const message = self.message_buf[0..self.message_len];

        // The first pass finds the cursor cell. The second pass draws.
        var line: CellLine = .{ .row = row, .cols = cols, .left = mb.left, .attr = self.region_attr, .draw = false };
        line.layout(mb.prompt, input, mb.buffer.cursor, mb.buffer.activeRegion(), message);
        // When the cursor goes back into the first screen width, show the
        // line from its start, so the prompt is visible again.
        if (line.cursor_cell < mb.left) mb.left = if (line.cursor_cell < cols) 0 else line.cursor_cell;
        if (line.cursor_cell >= mb.left + cols) mb.left = line.cursor_cell - cols + 1;

        line = .{ .row = row, .cols = cols, .left = mb.left, .attr = self.region_attr, .draw = true };
        line.layout(mb.prompt, input, mb.buffer.cursor, mb.buffer.activeRegion(), message);
        return line.cursor_cell - mb.left;
    }

    /// Draws one cell at a buffer display column, if the column is on screen.
    fn drawCell(self: *const Editor, row: c_int, col: usize, cols: usize, text: []const u8, attr: c_int) void {
        if (col < self.left or col >= self.left + cols) return;
        if (attr != 0) _ = c.attron(attr);
        _ = c.mvaddnstr(row, @intCast(col - self.left), text.ptr, @intCast(text.len));
        if (attr != 0) _ = c.attroff(attr);
    }

    /// The syntax face of each byte from `start` to `end`. Without a syntax
    /// tree, or after an error, all faces are `.none`. The caller frees it.
    fn visibleFaces(self: *Editor, start: usize, end: usize) []ts.Face {
        const faces = self.gpa.alloc(ts.Face, end - start) catch return &.{};
        @memset(faces, .none);
        const syn = if (self.syntax) |*s| s else return faces;
        syn.update(&self.buffer) catch return faces;
        syn.highlight(start, faces) catch @memset(faces, .none);
        return faces;
    }
};

/// Lays out one screen line cell by cell, and draws the cells from `left` on
/// if `draw` is true. It records the cell of the cursor.
const CellLine = struct {
    row: c_int,
    cols: usize,
    left: usize,
    attr: c_int,
    draw: bool,
    cell: usize = 0,
    cursor_cell: usize = 0,

    fn layout(self: *CellLine, prompt: []const u8, input: []const u8, cursor: usize, region: ?Buffer.Region, message: []const u8) void {
        self.putText(prompt);
        var i: usize = 0;
        while (i < input.len) {
            if (i == cursor) self.cursor_cell = self.cell;
            const n = @min(std.unicode.utf8ByteSequenceLength(input[i]) catch 1, input.len - i);
            const bytes = input[i .. i + n];
            const highlight = if (region) |r| i >= r.start and i < r.end else false;
            const b = bytes[0];
            if (b < 0x20 or b == 0x7f) {
                self.put("^", highlight);
                self.put(&.{b ^ 0x40}, highlight); // 0x0a shows as ^J, 0x7f as ^?
            } else if (n == 1 and b >= 0x80) {
                self.put("?", highlight); // invalid UTF-8
            } else {
                self.put(bytes, highlight);
            }
            i += n;
        }
        if (cursor >= input.len) self.cursor_cell = self.cell;
        if (message.len > 0) {
            self.putText("  [");
            self.putText(message);
            self.putText("]");
        }
    }

    /// Puts text without highlight, one cell for each codepoint.
    fn putText(self: *CellLine, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const n = @min(std.unicode.utf8ByteSequenceLength(text[i]) catch 1, text.len - i);
            self.put(text[i .. i + n], false);
            i += n;
        }
    }

    fn put(self: *CellLine, text: []const u8, highlight: bool) void {
        defer self.cell += 1;
        if (!self.draw or self.cell < self.left or self.cell >= self.left + self.cols) return;
        if (highlight) _ = c.attron(self.attr);
        _ = c.mvaddnstr(self.row, @intCast(self.cell - self.left), text.ptr, @intCast(text.len));
        if (highlight) _ = c.attroff(self.attr);
    }
};

/// Draws `parts` one after the other at the start of `row`. If the text is
/// too long for the screen, it drops codepoints from the start, so the end
/// stays visible with one free cell for the cursor. Returns the column after
/// the text.
fn drawTail(row: c_int, parts: []const []const u8, cols: usize) usize {
    var total: usize = 0;
    for (parts) |p| total += codepointCount(p);
    var skip = total -| (cols -| 1);

    var col: usize = 0;
    _ = c.move(row, 0);
    for (parts) |p| {
        var i: usize = 0;
        while (i < p.len) {
            const n = std.unicode.utf8ByteSequenceLength(p[i]) catch 1;
            const end = @min(i + n, p.len);
            if (skip > 0) {
                skip -= 1;
            } else {
                _ = c.addnstr(p[i..end].ptr, @intCast(end - i));
                col += 1;
            }
            i = end;
        }
    }
    return col;
}

fn codepointCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if (b & 0xc0 != 0x80) n += 1;
    }
    return n;
}

const Input = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn feed(self: *Input, ch: c_int, editor: *Editor) bool {
        if (ch == c.KEY_RESIZE) {
            editor.resize();
            return true;
        }
        if (ch < 0 or ch > 0xff) return true;

        self.buf[self.len] = @intCast(ch);
        self.len += 1;

        while (self.len > 0) {
            const used: usize = switch (keys.parse(self.buf[0..self.len])) {
                .incomplete => break,
                .key => |k| blk: {
                    if (!editor.handleKey(k.event)) return false;
                    break :blk k.len;
                },
                .other, .invalid => |n| n,
            };

            @memmove(self.buf[0 .. self.len - used], self.buf[used..self.len]);
            self.len -= used;
        }
        return true;
    }

    fn timeout(self: *Input, editor: *Editor) bool {
        if (self.len == 1 and self.buf[0] == 0x1b) {
            self.len = 0;
            return editor.handleKey(.{ .key = .{ .codepoint = 0x1b } });
        }
        return true;
    }
};

/// State that the Lua `editor` functions use.
const LuaContext = struct {
    gpa: std.mem.Allocator,
    keymap: *Keymap,
    languages: *ts.Languages,
    home: ?[]const u8,
    /// The editor, after it starts. Before that, `editor.message` keeps the
    /// message here, and the editor shows it at startup.
    editor: ?*Editor = null,
    pending_message: [256]u8 = undefined,
    pending_len: usize = 0,
};

/// Makes the global `editor` table for Lua.
fn registerLuaApi(L: *c.lua_State, ctx: *LuaContext) void {
    c.lua_createtable(L, 0, 3);
    const functions = [_]struct { [:0]const u8, c.lua_CFunction }{
        .{ "bind", luaBind },
        .{ "language", luaLanguage },
        .{ "message", luaMessage },
    };
    for (functions) |f| {
        c.lua_pushlightuserdata(L, ctx);
        c.lua_pushcclosure(L, f[1], 1);
        c.lua_setfield(L, -2, f[0]);
    }
    c.lua_setglobal(L, "editor");
}

/// Lua: `editor.message(text)`. Shows text in the echo area. In `init.lua`,
/// the editor shows the message when the screen opens, because `print`
/// output disappears then.
fn luaMessage(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ctx: *LuaContext = @ptrCast(@alignCast(c.lua_touserdata(L, c.lua_upvalueindex(1))));
    var len: usize = 0;
    const ptr = c.luaL_checklstring(L, 1, &len);
    const text = ptr[0..len];
    if (ctx.editor) |e| {
        e.setMessage("{s}", .{text});
    } else {
        const n = @min(text.len, ctx.pending_message.len);
        @memcpy(ctx.pending_message[0..n], text[0..n]);
        ctx.pending_len = n;
    }
    return 0;
}

/// Lua: `editor.language(name, options)`. Registers a tree-sitter language.
///
///     editor.language("zig", {
///       parser = "~/.config/editor-zig/parsers/zig.dylib", -- required
///       extensions = { "zig", "zon" },
///       filenames = { "build.zig.zon" },
///       highlights = "~/.config/editor-zig/queries/zig/highlights.scm",
///       symbol = "tree_sitter_zig", -- the default is "tree_sitter_" .. name
///     })
///
/// The editor loads the parser the first time that a file needs it.
fn luaLanguage(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ctx: *LuaContext = @ptrCast(@alignCast(c.lua_touserdata(L, c.lua_upvalueindex(1))));
    c.luaL_checktype(L, 2, c.LUA_TTABLE);

    // luaL_error does not return and skips Zig defers, so free first.
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    const result = registerLanguage(L, ctx, arena.allocator());
    arena.deinit();
    result catch |err| return c.luaL_error(L, "editor.language: %s", @errorName(err).ptr);
    return 0;
}

fn registerLanguage(L: *c.lua_State, ctx: *LuaContext, a: std.mem.Allocator) !void {
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return error.NameMustBeString;
    const parser = try luaStringField(L, a, "parser") orelse return error.ParserIsRequired;
    const highlights = try luaStringField(L, a, "highlights");
    try ctx.languages.register(.{
        .name = name_ptr[0..name_len],
        .parser = try files.expandPath(a, parser, ctx.home),
        .highlights = if (highlights) |h| try files.expandPath(a, h, ctx.home) else null,
        .symbol = try luaStringField(L, a, "symbol"),
        .extensions = try luaStringListField(L, a, "extensions"),
        .filenames = try luaStringListField(L, a, "filenames"),
    });
}

/// Reads `options[field]` (argument 2) as a string, or null if it is nil.
fn luaStringField(L: *c.lua_State, a: std.mem.Allocator, comptime field: [:0]const u8) !?[]const u8 {
    defer c.lua_settop(L, -2);
    switch (c.lua_getfield(L, 2, field)) {
        c.LUA_TNIL => return null,
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len);
            return try a.dupe(u8, ptr[0..len]);
        },
        else => return @field(anyerror, field ++ "MustBeString"),
    }
}

/// Reads `options[field]` (argument 2) as a list of strings.
fn luaStringListField(L: *c.lua_State, a: std.mem.Allocator, comptime field: [:0]const u8) ![]const []const u8 {
    defer c.lua_settop(L, -2);
    switch (c.lua_getfield(L, 2, field)) {
        c.LUA_TNIL => return &.{},
        c.LUA_TTABLE => {},
        else => return @field(anyerror, field ++ "MustBeList"),
    }
    const n: usize = @intCast(c.lua_rawlen(L, -1));
    const out = try a.alloc([]const u8, n);
    for (out, 1..) |*item, i| {
        defer c.lua_settop(L, -2);
        if (c.lua_rawgeti(L, -1, @intCast(i)) != c.LUA_TSTRING) return @field(anyerror, field ++ "MustBeStrings");
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        item.* = try a.dupe(u8, ptr[0..len]);
    }
    return out;
}

/// Lua: `editor.bind(keys, command)`.
/// `keys` is Emacs notation, for example "C-x C-s". `command` is a Lua
/// function or the name of a builtin command, for example "forward_char".
fn luaBind(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ctx: *LuaContext = @ptrCast(@alignCast(c.lua_touserdata(L, c.lua_upvalueindex(1))));

    var len: usize = 0;
    const notation = c.luaL_checklstring(L, 1, &len);

    const cmd: Command = switch (c.lua_type(L, 2)) {
        c.LUA_TFUNCTION => blk: {
            c.lua_settop(L, 2);
            break :blk .{ .lua = c.luaL_ref(L, c.LUA_REGISTRYINDEX) };
        },
        c.LUA_TSTRING => blk: {
            var name_len: usize = 0;
            const name = c.lua_tolstring(L, 2, &name_len);
            const b = std.meta.stringToEnum(Builtin, name[0..name_len]) orelse
                return c.luaL_error(L, "unknown command: %s", name);
            break :blk .{ .builtin = b };
        },
        else => return c.luaL_typeerror(L, 2, "function or command name"),
    };

    ctx.keymap.bindKeys(ctx.gpa, notation[0..len], cmd) catch |err| {
        if (cmd == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, cmd.lua);
        return c.luaL_error(L, "cannot bind \"%s\": %s", notation, @errorName(err).ptr);
    };
    return 0;
}

/// Returns `~/.config/editor-zig/init.lua`, or null if `HOME` has no value.
fn configPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[:0]u8 {
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.joinZ(arena, &.{ home, ".config", "editor-zig", "init.lua" });
}

/// Loads and runs the config file. If the file is missing or has an error,
/// the editor starts without it.
fn loadConfig(L: *c.lua_State, path: [:0]const u8) void {
    if (c.luaL_loadfilex(L, path.ptr, null) != c.LUA_OK or
        c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK)
    {
        c.lua_settop(L, -2); // pop the error message
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var writer = Io.File.stdout().writer(io, &.{});
    var stdout = &writer.interface;

    const gpa = init.gpa;
    var km: Keymap = .{};
    defer km.deinit(gpa);
    var mb_km: Keymap = .{};
    defer mb_km.deinit(gpa);
    try bindDefaults(&km, &mb_km, gpa);
    const home = init.environ_map.get("HOME");

    // The editor's syntax trees use the languages, so the languages must be
    // freed after the editor. This defer runs after `editor.deinit`.
    var languages: ts.Languages = .init(gpa);
    defer languages.deinit();

    // Load the config before ncurses takes control of the terminal.
    const L = c.luaL_newstate() orelse return error.LuaInit;
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    var lua_ctx: LuaContext = .{ .gpa = gpa, .keymap = &km, .languages = &languages, .home = home };
    registerLuaApi(L, &lua_ctx);
    if (try configPath(init.arena.allocator(), init.environ_map)) |path| {
        loadConfig(L, path);
    }

    // Let ncurses draw UTF-8 text.
    _ = c.setlocale(c.LC_ALL, "");
    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.raw();
    _ = c.nonl();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, false);
    _ = c.curs_set(1);
    _ = c.refresh();

    const kitty = (queryKitty(stdout) catch null) != null;
    if (kitty) {
        try stdout.writeAll(kitty_on);
        try stdout.flush();
    }

    defer {
        if (kitty) {
            stdout.writeAll(kitty_off) catch {};
            stdout.flush() catch {};
        }
    }

    var editor: Editor = .init(gpa, io, home, L, &km, &mb_km, &languages);
    defer editor.deinit();
    lua_ctx.editor = &editor;
    defer lua_ctx.editor = null;
    if (lua_ctx.pending_len > 0) editor.setMessage("{s}", .{lua_ctx.pending_message[0..lua_ctx.pending_len]});

    // `editor_zig FILE` opens FILE, as `emacs FILE` does.
    var args = init.minimal.args.iterate();
    _ = args.skip(); // the program name
    if (args.next()) |path| {
        const expanded = try files.expandPath(gpa, path, editor.home);
        defer gpa.free(expanded);
        try editor.findFile(expanded);
    }
    editor.render();

    _ = c.wtimeout(c.stdscr, 50);

    var input: Input = .{};

    loop: while (true) {
        const ch = c.getch();
        const ok = if (ch == c.ERR) input.timeout(&editor) else input.feed(ch, &editor);
        if (!ok) break;

        _ = c.wtimeout(c.stdscr, 0);
        while (true) {
            const more = c.getch();
            if (more == c.ERR) break;
            if (!input.feed(more, &editor)) break :loop;
        }
        _ = c.wtimeout(c.stdscr, 50);

        editor.render();
    }
}

fn queryKitty(stdout: *Io.Writer) !?u8 {
    _ = c.wtimeout(c.stdscr, 500);
    defer _ = c.wtimeout(c.stdscr, -1);

    try stdout.writeAll("\x1b[?u\x1b[c");
    try stdout.flush();

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const ch = c.getch();
        if (ch == c.ERR) return error.NoReply;
        if (ch > 0xff) continue;

        buf[len] = @intCast(ch);
        len += 1;
        if (ch == 'c') break;
    }

    return parseKittyFlags(buf[0..len]);
}

fn parseKittyFlags(reply: []const u8) ?u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, reply, i, "\x1b[?")) |start| {
        var j = start + 3;
        while (j < reply.len and std.ascii.isDigit(reply[j])) j += 1;
        if (j < reply.len and reply[j] == 'u')
            return std.fmt.parseInt(u8, reply[start + 3 .. j], 10) catch null;
        i = j;
    }
    return null;
}

test {
    _ = keys;
    _ = keymap;
    _ = @import("buffer.zig");
    _ = @import("kill_ring.zig");
    _ = @import("files.zig");
    _ = @import("minibuffer.zig");
    _ = @import("completion.zig");
    _ = @import("regex.zig");
    _ = @import("syntax.zig");
    _ = @import("prefix_arg.zig");
}
