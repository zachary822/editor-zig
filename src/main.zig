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
const history = @import("history.zig");
const History = history.History;
const Histories = history.Histories;
const completion = @import("completion.zig");
const ts = @import("syntax.zig");
const text_worker = @import("text_worker.zig");
const options = @import("options.zig");
const layout = @import("layout.zig");
const face = @import("face.zig");
const lua_api = @import("lua_api.zig");
const PrefixArg = @import("prefix_arg.zig").PrefixArg;
const isearch = @import("isearch.zig");
const Isearch = isearch.Isearch;

const kitty_on = "\x1b[>1u";
const kitty_off = "\x1b[<u";

/// Commands that are written in Zig. Lua can bind keys to these by name,
/// for example `editor.bind("C-a", "backward_char")`.
pub const Builtin = enum {
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
    // Incremental search. The last two work only during a search.
    isearch_forward,
    isearch_backward,
    isearch_delete_char,
    isearch_exit,
    /// M-x: runs a command by name.
    execute_extended_command,
    // Buffers and windows.
    switch_to_buffer,
    kill_buffer,
    split_window_below,
    split_window_right,
    other_window,
    delete_window,
    delete_other_windows,
    quit_window,

    /// The properties of a command. See `builtin_info`.
    const Info = struct {
        /// How the command uses a prefix argument: it repeats, it reads the
        /// argument itself, or it runs once.
        arg: enum { repeat, reads, once } = .repeat,
        /// The command beeps in the minibuffer, as Emacs does not allow a
        /// minibuffer inside a minibuffer.
        main_only: bool = false,
        /// The command works during a search. Other commands end the search
        /// first, as in Emacs.
        in_search: bool = false,
        /// The command that a negative prefix argument runs, for example
        /// C-u - 3 C-f runs backward_char 3 times.
        opposite: ?Builtin = null,
    };

    fn info(self: Builtin) Info {
        return builtin_info.get(self);
    }
};

/// The properties of each command. The compiler makes sure that each
/// command has an entry.
const builtin_info = std.enums.EnumArray(Builtin, Builtin.Info).init(.{
    .previous_line = .{ .opposite = .next_line },
    .next_line = .{ .opposite = .previous_line },
    .backward_char = .{ .opposite = .forward_char },
    .forward_char = .{ .opposite = .backward_char },
    .move_beginning_of_line = .{},
    .move_end_of_line = .{},
    .scroll_up_command = .{ .arg = .reads, .main_only = true },
    .scroll_down_command = .{ .arg = .reads, .main_only = true },
    .newline = .{},
    .tab_to_tab_stop = .{ .arg = .reads },
    .delete_backward_char = .{ .opposite = .delete_char },
    .delete_char = .{ .opposite = .delete_backward_char },
    .kill_line = .{ .arg = .reads },
    .set_mark_command = .{ .arg = .reads },
    .exchange_point_and_mark = .{ .arg = .once },
    .kill_region = .{ .arg = .once },
    .kill_ring_save = .{ .arg = .once },
    .yank = .{ .arg = .reads },
    .yank_pop = .{},
    .undo = .{ .opposite = .redo },
    .redo = .{ .opposite = .undo },
    .find_file = .{ .arg = .once, .main_only = true },
    .save_buffer = .{ .arg = .once, .main_only = true },
    .quit = .{ .arg = .once, .main_only = true },
    .exit_minibuffer = .{ .arg = .once },
    .minibuffer_complete = .{ .arg = .once },
    .previous_history_element = .{ .in_search = true },
    .next_history_element = .{ .in_search = true },
    .forward_sexp = .{ .main_only = true, .opposite = .backward_sexp },
    .backward_sexp = .{ .main_only = true, .opposite = .forward_sexp },
    .backward_up_list = .{ .main_only = true },
    .down_list = .{ .main_only = true },
    .beginning_of_defun = .{ .main_only = true, .opposite = .end_of_defun },
    .end_of_defun = .{ .main_only = true, .opposite = .beginning_of_defun },
    .universal_argument = .{ .arg = .once },
    .digit_argument = .{ .arg = .once },
    .negative_argument = .{ .arg = .once },
    .isearch_forward = .{ .arg = .once, .main_only = true, .in_search = true },
    .isearch_backward = .{ .arg = .once, .main_only = true, .in_search = true },
    .isearch_delete_char = .{ .arg = .once, .in_search = true },
    .isearch_exit = .{ .arg = .once, .in_search = true },
    .execute_extended_command = .{ .arg = .reads, .main_only = true },
    .switch_to_buffer = .{ .arg = .once, .main_only = true },
    .kill_buffer = .{ .arg = .once, .main_only = true },
    .split_window_below = .{ .arg = .once, .main_only = true },
    .split_window_right = .{ .arg = .once, .main_only = true },
    .other_window = .{ .main_only = true },
    .delete_window = .{ .arg = .once, .main_only = true },
    .delete_other_windows = .{ .arg = .once, .main_only = true },
    .quit_window = .{ .arg = .once, .main_only = true },
});

pub const Command = union(enum) {
    builtin: Builtin,
    /// A Lua function, kept in the Lua registry by `luaL_ref`.
    lua: c_int,
};

pub const Keymap = keymap.Keymap(Command);
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
    .{ "C-s", .isearch_forward },
    .{ "C-r", .isearch_backward },
    .{ "M-x", .execute_extended_command },
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
    .{ "C-x b", .switch_to_buffer },
    .{ "C-x k", .kill_buffer },
    .{ "C-x 2", .split_window_below },
    .{ "C-x 3", .split_window_right },
    .{ "C-x o", .other_window },
    .{ "C-x 0", .delete_window },
    .{ "C-x 1", .delete_other_windows },
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

/// The search keymap. The dispatcher searches it before the global keymap
/// during a search, as Emacs `isearch-mode-map`. Printable keys add to the
/// search text. Other keys end the search and then run.
const isearch_bindings = [_]struct { []const u8, Builtin }{
    .{ "C-s", .isearch_forward },
    .{ "C-r", .isearch_backward },
    .{ "DEL", .isearch_delete_char },
    .{ "RET", .isearch_exit },
    .{ "M-p", .previous_history_element },
    .{ "M-n", .next_history_element },
};

const prefix_arg_max = @import("prefix_arg.zig").max_count;

/// The number of lines that stay on the screen after C-v or M-v, as Emacs
/// `next-screen-context-lines`.
const page_context_lines = 2;

/// A buffer in the buffer list: a `Buffer` with a name, its syntax tree and
/// an optional keymap that works only in it.
pub const BufferEntry = struct {
    id: u32,
    name: []u8,
    buf: Buffer,
    syntax: ?ts.Syntax = null,
    /// Keys that work only in this buffer, for example from Lua `buf:bind`.
    keymap: ?*Keymap = null,
    /// Options that this buffer sets, for example from Lua `buf:set_option`.
    options: options.Overrides = .{},
};

/// The settings of a floating window. The position and size are in screen
/// cells, and they include the border.
pub const Float = struct {
    row: usize,
    col: usize,
    width: usize,
    height: usize,
    border: bool = true,
};

/// A window shows a buffer in a part of the screen.
pub const Window = struct {
    id: u32,
    entry: *BufferEntry,
    /// The buffer line at the top of the window.
    top: usize = 0,
    /// The display column at the left edge of the window.
    left: usize = 0,
    /// The cursor of the window while it is not selected. The selected
    /// window uses the cursor of its buffer, as Emacs `window-point`.
    point: usize = 0,
    /// The screen area from the last layout: for a tiled window, the text
    /// and the mode line row; for a floating window, the text and the border.
    rect: layout.Rect = .{},
    /// Null for a window in the split layout.
    float: ?Float = null,
    /// Lua: a function that draws on the window after its text.
    on_draw: ?c_int = null,
};

/// What RET does with the minibuffer input. Each caller gives the action
/// as a function, so one prompt needs no code in other places.
const Accept = union(enum) {
    /// Any text.
    text: *const fn (*Editor, []const u8) anyerror!void,
    /// A file name. The editor rejects an empty name and expands "~" first.
    file_name: *const fn (*Editor, []const u8) anyerror!void,
    /// "yes" or "no". The function runs for "yes".
    yes_or_no: *const fn (*Editor) anyerror!void,
};

/// The options of a minibuffer prompt, as the arguments of Emacs
/// `completing-read`.
const ReadOptions = struct {
    prompt: []const u8,
    initial: []const u8 = "",
    /// The name of the history for M-p and M-n, for example "file".
    history: ?[]const u8 = null,
    completion: ?completion.Source = null,
    /// RET accepts only a candidate of `completion`.
    require_match: bool = false,
    /// The prompt frees the `completion.strings` slice when it closes. The
    /// strings themselves belong to the caller.
    owns_strings: bool = false,
    /// The value of an empty input, as the Emacs `completing-read` default.
    default: ?[]const u8 = null,
    accept: Accept,
};

/// An open minibuffer prompt: the input and what to do with it.
const Reader = struct {
    mb: Minibuffer,
    completion: ?completion.Source,
    require_match: bool,
    owns_strings: bool,
    /// A copy, owned by the prompt.
    default: ?[]u8,
    accept: Accept,
};

const yes_no: []const []const u8 = &.{ "yes", "no" };

/// The names of all builtin commands, for M-x completion.
const command_names = blk: {
    const field_names = @typeInfo(Builtin).@"enum".field_names;
    var names: [field_names.len][]const u8 = undefined;
    for (field_names, 0..) |name, i| names[i] = name;
    break :blk names;
};

fn bindDefaults(km: *Keymap, mb_km: *Keymap, is_km: *Keymap, gpa: std.mem.Allocator) !void {
    for (default_bindings) |b| try km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
    for (minibuffer_bindings) |b| try mb_km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
    for (isearch_bindings) |b| try is_km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
}

pub const Editor = struct {
    max_y: c_int,
    max_x: c_int,
    /// All buffers, most recently selected first, as the Emacs buffer list.
    buffers: std.ArrayList(*BufferEntry) = .empty,
    /// All windows: the tiled windows of `layout` and the floating windows.
    windows: std.ArrayList(*Window) = .empty,
    layout: layout.Layout,
    /// The floating windows in drawing order, the top one last.
    floats: std.ArrayList(*Window) = .empty,
    /// The window that has the cursor and gets the keys.
    selected: *Window,
    /// The window that was selected before, so a closed window can give the
    /// focus back, for example a popup.
    previous_window: ?u32 = null,
    next_id: u32 = 1,
    running: bool = true,
    dispatcher: Dispatcher,
    /// The Lua state for Lua commands. Tests can omit it.
    L: ?*c.lua_State,
    kill_ring: KillRing,
    /// True after `initScreen`. Without a screen (in tests), the editor makes
    /// no ncurses calls, and `bell` only counts.
    screen: bool = false,
    bells: usize = 0,
    /// The last builtin command, or null after a typed key or a Lua command.
    /// Consecutive kills and yank-pop use it.
    last_command: ?Builtin = null,
    /// The text that the last yank or yank-pop inserted. Yank-pop replaces it.
    yank_start: usize = 0,
    yank_end: usize = 0,
    gpa: std.mem.Allocator,
    io: Io,
    /// The home directory, for "~" in file names.
    home: ?[]const u8,
    /// The open minibuffer prompt.
    reader: ?Reader = null,
    /// The prefix argument of M-x, for the command that M-x runs.
    command_arg: ?PrefixArg = null,
    /// The keymap that comes before the global keymap in the minibuffer.
    minibuffer_keymap: *const Keymap,
    /// The named input histories: "file", "search", "command" and so on.
    histories: Histories,
    /// The languages from `init.lua`.
    languages: *ts.Languages,
    /// The named text styles.
    faces: face.Faces,
    /// The terminal attribute of each face, made when the editor needs it.
    /// Null means not made yet. A face change empties the cache.
    attr_cache: std.ArrayList(?c_int) = .empty,
    attr_cache_version: u64 = 0,
    /// The foreground and background of each ncurses color pair. Pair n is
    /// at index n - 1.
    color_pairs: std.ArrayList([2]face.Color) = .empty,
    /// Lua: a function that gives the mode line text of a window.
    mode_line_fn: ?c_int = null,
    /// The global options. A buffer can override them.
    options: options.Options = .{},
    /// The thread for background work on buffer text, for example syntax
    /// trees. The editor makes it when the first buffer needs it.
    executor: ?*text_worker.Executor = null,
    /// Lua functions for `editor.on("buffer_open", fn)`, as registry references.
    buffer_open_hooks: std.ArrayList(c_int) = .empty,
    /// The window that a Lua `on_draw` function draws on now. A canvas
    /// works only during its window's function.
    drawing_window: ?u32 = null,
    /// The text area of `drawing_window`.
    drawing_rect: layout.Rect = .{},
    /// The number of canvas:text calls, for tests.
    canvas_calls: usize = 0,
    /// The vertical lines between side-by-side windows, from the last layout.
    separators: std.ArrayList(layout.Separator) = .empty,
    /// The buffer that C-x k asks about, while the yes or no question is open.
    pending_kill: ?u32 = null,
    /// The prefix argument while the user types it (C-u 12 ...).
    prefix_arg: ?PrefixArg = null,
    /// The active incremental search.
    search: ?Isearch = null,
    /// The keymap that comes before the global keymap during a search.
    isearch_keymap: *const Keymap,
    /// The message in the echo area. The next key clears it. While the
    /// minibuffer is open, it shows after the input in brackets.
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub const Options = struct {
        io: Io,
        home: ?[]const u8 = null,
        L: ?*c.lua_State = null,
        global_keymap: *const Keymap,
        minibuffer_keymap: *const Keymap,
        isearch_keymap: *const Keymap,
        languages: *ts.Languages,
        /// The screen size until `initScreen` reads the real size.
        rows: c_int = 24,
        cols: c_int = 80,
    };

    /// Makes an editor with a "*scratch*" buffer in one window. It makes no
    /// ncurses calls, so tests and `init.lua` can use it before the screen
    /// opens.
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Editor {
        var faces = try face.Faces.init(gpa);
        errdefer faces.deinit();
        var self: Editor = .{
            .max_y = opts.rows,
            .max_x = opts.cols,
            .layout = undefined,
            .selected = undefined,
            .dispatcher = .init(opts.global_keymap),
            .L = opts.L,
            .kill_ring = .init(gpa),
            .gpa = gpa,
            .io = opts.io,
            .home = opts.home,
            .minibuffer_keymap = opts.minibuffer_keymap,
            .histories = .init(gpa),
            .languages = opts.languages,
            .faces = faces,
            .isearch_keymap = opts.isearch_keymap,
        };
        errdefer self.deinitLists();
        const scratch = try self.createBuffer("*scratch*");
        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);
        win.* = .{ .id = self.newId(), .entry = scratch };
        try self.windows.append(gpa, win);
        self.selected = win;
        self.layout = try layout.Layout.init(gpa, win.id);
        self.relayout();
        return self;
    }

    /// Connects the editor to the ncurses screen: the real size and colors.
    /// Call it after `initscr`.
    pub fn initScreen(self: *Editor) void {
        self.screen = true;
        if (c.has_colors()) {
            _ = c.start_color();
            // Keep the terminal's own colors for the default face (color -1).
            _ = c.use_default_colors();
        }
        self.resize();
    }

    fn newId(self: *Editor) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    /// The keymap that comes before the global keymap for the first key of a
    /// sequence: the minibuffer keymap, the search keymap, or the keymap of
    /// the selected window's buffer. The editor computes it from its state
    /// before each key, so no feature needs to set and clear it.
    fn currentOverlay(self: *const Editor) ?*const Keymap {
        if (self.reader != null) return self.minibuffer_keymap;
        if (self.search != null) return self.isearch_keymap;
        return self.selected.entry.keymap;
    }

    /// Rings the terminal bell. Without a screen, only counts.
    pub fn bell(self: *Editor) void {
        self.bells += 1;
        if (self.screen) _ = c.beep();
    }

    /// The buffer entry of the selected window.
    pub fn cur(self: *const Editor) *BufferEntry {
        return self.selected.entry;
    }

    /// The buffer of the selected window.
    pub fn curBuf(self: *const Editor) *Buffer {
        return &self.selected.entry.buf;
    }

    /// The buffer that editing commands change: the minibuffer while it is
    /// open, and the selected window's buffer at other times.
    fn activeBuffer(self: *Editor) *Buffer {
        if (self.reader) |*r| return &r.mb.buffer;
        return self.curBuf();
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffer_open_hooks.items) |ref| self.freeLuaRef(ref);
        self.buffer_open_hooks.deinit(self.gpa);
        if (self.search) |*s| s.deinit();
        if (self.reader) |*r| freeReader(self.gpa, r);
        self.histories.deinit();
        self.kill_ring.deinit();
        self.deinitLists();
        // After the buffers: their syntax workers use the executor.
        if (self.executor) |ex| ex.destroy();
        self.layout.deinit();
        self.faces.deinit();
        self.attr_cache.deinit(self.gpa);
        self.color_pairs.deinit(self.gpa);
        self.separators.deinit(self.gpa);
    }

    fn deinitLists(self: *Editor) void {
        for (self.windows.items) |w| self.gpa.destroy(w);
        self.windows.deinit(self.gpa);
        self.floats.deinit(self.gpa);
        for (self.buffers.items) |e| self.destroyEntry(e);
        self.buffers.deinit(self.gpa);
    }

    /// Returns false when the editor must stop.
    pub fn handleKey(self: *Editor, event: keys.KeyEvent) bool {
        if (event.kind == .release) return self.running;
        self.message_len = 0;
        const in_sequence = self.dispatcher.isPending();
        self.dispatcher.overlay = self.currentOverlay();
        switch (self.dispatcher.feed(event)) {
            .run => |cmd| {
                // As in Emacs, other commands end the search, then run.
                if (self.search != null and !(cmd == .builtin and cmd.builtin.info().in_search)) self.endSearch();
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
                if (!in_sequence and self.search != null) {
                    // C-g removes the failed part of the search text, or
                    // cancels the search and goes back to the start.
                    if (!self.search.?.cancelFailing()) self.cancelSearch();
                } else if (!in_sequence and self.reader != null) {
                    // C-g in the minibuffer cancels the prompt.
                    self.closeMinibuffer();
                    self.setMessage("Quit", .{});
                } else {
                    self.activeBuffer().deactivateMark();
                }
                self.bell();
            },
            // An unbound printable key inserts itself, but not after a prefix.
            .unbound => |chord| typed: {
                if (!in_sequence and chord.isPrintable() and self.search != null) {
                    // During a search, typed text goes into the search text.
                    self.search.?.addChar(event.typedCodepoint().?) catch {
                        self.bell();
                    };
                    self.syncSearchCursor();
                    break :typed;
                }
                if (self.search != null) self.endSearch();
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
                    self.selfInsert(cp, if (arg) |a| a.count() else 1) catch |err| self.reportError(err);
                } else {
                    self.prefix_arg = null;
                    self.last_command = null;
                    self.bell();
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
    pub fn run(self: *Editor, cmd: Command, arg: ?PrefixArg) void {
        const n: i64 = if (arg) |a| a.count() else 1;
        if (@abs(n) > prefix_arg_max) {
            self.setMessage("Count too large", .{});
            self.bell();
            return;
        }
        switch (cmd) {
            .builtin => |b| {
                if (arg == null or b.info().arg == .reads) {
                    _ = self.runBuiltin(b, arg);
                    return;
                }
                if (b.info().arg == .once) {
                    _ = self.runBuiltin(b, null);
                    return;
                }
                const each = if (n < 0) b.info().opposite orelse b else b;
                var i: u64 = 0;
                while (i < @abs(n)) : (i += 1) {
                    if (!self.runBuiltin(each, null)) break; // stop at the first error
                }
            },
            .lua => |ref| {
                self.last_command = null;
                const L = self.L orelse return self.bell();
                var i: u64 = 0;
                while (i < @abs(n)) : (i += 1) {
                    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
                    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK) {
                        lua_api.showError(self, L, "command"); // pops the message
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
        if (self.reader != null and b.info().main_only) {
            self.bell();
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
            .tab_to_tab_stop => self.tabToTabStop(buf, arg),
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
            .previous_history_element => self.historyStep(.previous),
            .next_history_element => self.historyStep(.next),
            .forward_sexp => self.syntaxMove(ts.Syntax.forwardSexp),
            .backward_sexp => self.syntaxMove(ts.Syntax.backwardSexp),
            .backward_up_list => self.syntaxMove(ts.Syntax.backwardUpList),
            .down_list => self.syntaxMove(ts.Syntax.downList),
            .beginning_of_defun => self.syntaxMove(ts.Syntax.beginningOfDefun),
            .end_of_defun => self.syntaxMove(ts.Syntax.endOfDefun),
            // handleKey runs these before the dispatch reaches this function.
            .universal_argument, .digit_argument, .negative_argument => {},
            .isearch_forward => self.isearchCommand(.forward),
            .isearch_backward => self.isearchCommand(.backward),
            .isearch_delete_char => self.isearchDelete(),
            .isearch_exit => if (self.search != null) self.endSearch() else error.NotSearching,
            .execute_extended_command => self.executeExtendedCommand(arg),
            .switch_to_buffer => self.switchToBufferCommand(),
            .kill_buffer => self.killBufferCommand(),
            .split_window_below => if (self.splitWindow(.below)) |_| {} else |err| err,
            .split_window_right => if (self.splitWindow(.right)) |_| {} else |err| err,
            .other_window => self.otherWindow(),
            .delete_window => self.deleteWindow(self.selected),
            .delete_other_windows => self.deleteOtherWindows(),
            .quit_window => self.quitWindow(),
        };
        result catch |err| {
            self.reportError(err);
            return false;
        };
        return true;
    }

    /// Rings the bell for a failed command. Some errors also get a message.
    fn reportError(self: *Editor, err: anyerror) void {
        if (err == error.ReadOnly) self.setMessage("Buffer is read-only", .{});
        self.bell();
    }

    fn popToMark(buf: *Buffer) !void {
        const m = buf.mark orelse return error.NoMark;
        buf.moveTo(m);
        buf.deactivateMark();
    }

    // Incremental search

    /// C-s and C-r. Outside a search, they start one. During a search, they
    /// go to the next match. With no search text, they use the last one.
    fn isearchCommand(self: *Editor, dir: isearch.Direction) !void {
        if (self.search == null) {
            const text = try self.curBuf().copyRange(self.gpa, 0, self.curBuf().len());
            self.search = Isearch.init(self.gpa, text, self.curBuf().cursor, dir);
            return;
        }
        const s = &self.search.?;
        if (s.query.items.len == 0) {
            // C-s C-s: the newest search in the history.
            const last = (try self.histories.get("search")).get(0) orelse return error.NoPreviousSearch;
            s.dir = dir;
            try s.addText(last);
        } else {
            try s.repeat(dir);
        }
        self.syncSearchCursor();
    }

    /// DEL during a search: goes back one step.
    fn isearchDelete(self: *Editor) !void {
        const s = if (self.search) |*s| s else return error.NotSearching;
        if (!s.deleteChar()) return error.NothingToDelete;
        self.syncSearchCursor();
    }

    /// M-p and M-n: in the minibuffer, or during a search.
    fn historyStep(self: *Editor, step: enum { previous, next }) !void {
        if (self.reader) |*r| {
            return if (step == .previous) r.mb.historyPrevious() else r.mb.historyNext();
        }
        const s = if (self.search) |*s| s else return error.NoHistory;
        const h = try self.histories.get("search");
        try if (step == .previous) s.historyPrevious(h) else s.historyNext(h);
        self.syncSearchCursor();
    }

    /// Moves the buffer cursor to the search position.
    fn syncSearchCursor(self: *Editor) void {
        if (self.search) |*s| self.curBuf().moveTo(s.cursor);
    }

    /// Ends the search at the current match. As in Emacs, if the cursor
    /// moved, the mark goes to the start of the search, and the search text
    /// becomes the last search.
    fn endSearch(self: *Editor) void {
        var s = self.search orelse return;
        self.search = null;
        defer s.deinit();
        if (self.histories.get("search")) |h| h.add(s.query.items) catch {} else |_| {}
        if (self.curBuf().cursor != s.origin) {
            self.curBuf().mark = s.origin;
            self.setMessage("Mark saved where search started", .{});
        }
    }

    /// C-g during a search: goes back to the start and ends the search.
    fn cancelSearch(self: *Editor) void {
        var s = self.search orelse return;
        self.search = null;
        self.curBuf().moveTo(s.origin);
        s.deinit();
    }

    // Echo area and minibuffer

    /// Shows a message in the echo area until the next key.
    pub fn setMessage(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch &self.message_buf;
        self.message_len = text.len;
    }

    /// Opens the minibuffer. See `ReadOptions`.
    fn read(self: *Editor, opts: ReadOptions) !void {
        std.debug.assert(self.reader == null);
        errdefer if (opts.owns_strings) self.gpa.free(opts.completion.?.strings);
        const hist: ?*History = if (opts.history) |name| try self.histories.get(name) else null;
        const default = if (opts.default) |d| try self.gpa.dupe(u8, d) else null;
        errdefer if (default) |d| self.gpa.free(d);
        self.reader = .{
            .mb = try .init(self.gpa, opts.prompt, opts.initial, hist),
            .completion = opts.completion,
            .require_match = opts.require_match,
            .owns_strings = opts.owns_strings,
            .default = default,
            .accept = opts.accept,
        };
    }

    /// Asks for a file name, as Emacs `read-file-name`: the input starts
    /// with the directory of the current file, with the "file" history and
    /// file name completion.
    fn readFileName(self: *Editor, prompt: []const u8, accept: *const fn (*Editor, []const u8) anyerror!void) !void {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        try self.read(.{
            .prompt = prompt,
            .initial = self.defaultDirectory(&dir_buf),
            .history = "file",
            .completion = .file_names,
            .accept = .{ .file_name = accept },
        });
    }

    /// Asks a yes or no question, as Emacs `yes-or-no-p`. RET accepts only
    /// "yes" or "no", and TAB completes them.
    fn yesOrNo(self: *Editor, question: []const u8, on_yes: *const fn (*Editor) anyerror!void) !void {
        var buf: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buf, "{s} (yes or no) ", .{question}) catch question;
        try self.read(.{
            .prompt = prompt,
            .completion = .{ .strings = yes_no },
            .require_match = true,
            .accept = .{ .yes_or_no = on_yes },
        });
    }

    /// The directory of the current file with a "/", or "" if the buffer
    /// has no file. `buf` holds the text.
    fn defaultDirectory(self: *const Editor, buf: []u8) []const u8 {
        const path = self.curBuf().file_path orelse return "";
        const dir = std.fs.path.dirname(path) orelse return "";
        return std.fmt.bufPrint(buf, "{s}/", .{dir}) catch "";
    }

    fn closeMinibuffer(self: *Editor) void {
        if (self.reader) |*r| freeReader(self.gpa, r);
        self.reader = null;
    }

    fn freeReader(gpa: std.mem.Allocator, r: *Reader) void {
        r.mb.deinit();
        if (r.owns_strings) gpa.free(r.completion.?.strings);
        if (r.default) |d| gpa.free(d);
    }

    /// RET in the minibuffer. If the prompt needs a candidate and the input
    /// is not one, the minibuffer stays open with "[No match]". Otherwise,
    /// it closes the minibuffer, adds the input to the history and runs the
    /// action. The action can open a new prompt.
    fn exitMinibuffer(self: *Editor) !void {
        const r = if (self.reader) |*r| r else return error.NotInMinibuffer;
        var input = try r.mb.text(self.gpa);
        defer self.gpa.free(input);
        if (input.len == 0) if (r.default) |d| {
            self.gpa.free(input);
            input = try self.gpa.dupe(u8, d);
        };
        if (r.require_match) {
            if (r.completion) |src| if (!completion.isCandidate(src, input)) {
                self.setMessage("No match", .{});
                return error.NoMatch;
            };
        }
        if (r.mb.history) |h| try h.add(input);
        const accept = r.accept;
        self.closeMinibuffer();
        self.runAccept(accept, input) catch |err| {
            self.setMessage("Error: {t}", .{err});
            return err;
        };
    }

    fn runAccept(self: *Editor, accept: Accept, input: []const u8) !void {
        switch (accept) {
            .text => |f| try f(self, input),
            .file_name => |f| {
                if (input.len == 0) return self.setMessage("No file name", .{});
                const path = try files.expandPath(self.gpa, input, self.home);
                defer self.gpa.free(path);
                try f(self, path);
            },
            // require_match makes sure that the input is "yes" or "no".
            .yes_or_no => |f| if (std.mem.eql(u8, input, "yes")) try f(self) else self.setMessage("Cancelled", .{}),
        }
    }

    /// TAB in the minibuffer: completes the input from the prompt's source.
    /// - One match: the input becomes that match.
    /// - More matches with a longer common prefix: the input becomes the prefix.
    /// - More matches with no longer prefix: the echo area lists them.
    fn minibufferComplete(self: *Editor) !void {
        const r = if (self.reader) |*r| r else return error.NotInMinibuffer;
        const source = r.completion orelse return error.NoCompletion;

        const input = try r.mb.text(self.gpa);
        defer self.gpa.free(input);
        var comp = try completion.complete(self.io, Io.Dir.cwd(), self.gpa, source, input, self.home);
        defer comp.deinit();

        switch (comp.matches.len) {
            0 => {
                self.setMessage("No match", .{});
                return error.NoMatch;
            },
            1 => {
                try r.mb.setText(comp.text);
                // A directory name continues, so it gets no message.
                if (!std.mem.endsWith(u8, comp.text, "/")) self.setMessage("Sole completion", .{});
            },
            else => if (comp.text.len > input.len) {
                try r.mb.setText(comp.text);
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

    /// M-x: asks for a command name and runs the command, as Emacs
    /// `execute-extended-command`. A prefix argument before M-x goes to the
    /// command: C-u 3 M-x forward_char moves 3 characters.
    fn executeExtendedCommand(self: *Editor, arg: ?PrefixArg) !void {
        try self.read(.{
            .prompt = "M-x ",
            .history = "command",
            .completion = .{ .strings = &command_names },
            .require_match = true,
            .accept = .{ .text = runNamedCommand },
        });
        self.command_arg = arg;
    }

    fn runNamedCommand(self: *Editor, name: []const u8) anyerror!void {
        const b = std.meta.stringToEnum(Builtin, name) orelse return error.UnknownCommand;
        const arg = self.command_arg;
        self.command_arg = null;
        self.run(.{ .builtin = b }, arg);
    }

    // Files

    /// C-x C-f. The file opens in a new buffer, or in the buffer that visits
    /// it already.
    fn findFileCommand(self: *Editor) !void {
        try self.readFileName("Find file: ", findFile);
    }

    pub const OpenedFile = struct {
        entry: *BufferEntry,
        /// True if this call made the buffer. Then the caller calls
        /// `bufferOpened` after its own work on the buffer.
        new: bool,
        /// True if the file does not exist yet. The first save makes it.
        missing: bool,
    };

    /// The buffer that visits the file `path`: a buffer that visits it
    /// already, or a new buffer with the file text and its language. It
    /// does not show the buffer, and it does not call the hooks. An error
    /// if the file cannot be read.
    pub fn openFileBuffer(self: *Editor, given_path: []const u8) !OpenedFile {
        // Buffers keep absolute paths, so "a.txt" and "/dir/a.txt" find
        // the same buffer.
        const path = try self.absolutePath(given_path);
        defer self.gpa.free(path);
        for (self.buffers.items) |e| {
            const p = e.buf.file_path orelse continue;
            if (std.mem.eql(u8, p, path)) return .{ .entry = e, .new = false, .missing = false };
        }
        const text = try files.readFile(self.io, Io.Dir.cwd(), self.gpa, path);
        defer if (text) |t| self.gpa.free(t);

        var new_buf: Buffer = if (text) |t| try .initText(self.gpa, t) else .init(self.gpa);
        new_buf.setFilePath(path) catch |err| {
            new_buf.deinit();
            return err;
        };
        const e = try self.addBuffer(std.fs.path.basename(path), new_buf);
        self.attachSyntax(e);
        return .{ .entry = e, .new = true, .missing = text == null };
    }

    /// `path` as an absolute path without "." and ".." parts and without
    /// symbolic links, from the current directory. Two paths for the same
    /// file then compare equal. For a file that does not exist yet, only
    /// its directory is resolved. The caller frees it.
    pub fn absolutePath(self: *Editor, path: []const u8) ![]u8 {
        // First an absolute path without "." and ".." parts.
        const plain = if (std.fs.path.isAbsolute(path))
            try std.fs.path.resolveAlloc(self.gpa, &.{path})
        else blk: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try Io.Dir.cwd().realPath(self.io, &cwd_buf);
            break :blk try std.fs.path.resolveAlloc(self.gpa, &.{ cwd_buf[0..n], path });
        };
        defer self.gpa.free(plain);
        // Then resolve symbolic links, as the current directory is resolved:
        // the full path if the file exists, or else its directory.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.realPathFileAbsolute(self.io, plain, &buf)) |n| {
            return self.gpa.dupe(u8, buf[0..n]);
        } else |_| {}
        if (std.fs.path.dirname(plain)) |dir| {
            if (Io.Dir.realPathFileAbsolute(self.io, dir, &buf)) |n| {
                return std.fs.path.resolveAlloc(self.gpa, &.{ buf[0..n], std.fs.path.basename(plain) });
            } else |_| {}
        }
        return self.gpa.dupe(u8, plain);
    }

    /// Shows the file `path` in the selected window. If a buffer visits the
    /// file, it uses that buffer. If the file does not exist, the buffer is
    /// empty, and the first save makes the file.
    pub fn findFile(self: *Editor, path: []const u8) anyerror!void {
        const opened = self.openFileBuffer(path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.setMessage("Cannot open {s}: {t}", .{ path, err }),
        };
        self.showBuffer(self.selected, opened.entry) catch |err| {
            // The buffer exists now, so it must get its hooks anyway.
            if (opened.new) self.bufferOpened(opened.entry.id);
            return err;
        };
        if (!opened.new) return;
        self.last_command = null;
        if (opened.missing) self.setMessage("(New file)", .{});
        // Last: a hook can kill the buffer, so the entry is not used after it.
        self.bufferOpened(opened.entry.id);
    }

    /// Opens a buffer for each file. The selected window shows the first
    /// file, and the buffer list has the files in the same order, so C-x b
    /// RET goes to the second file. "~" in a path means the home directory.
    pub fn openFiles(self: *Editor, paths: []const []const u8) !void {
        // The last file opens first, so the first file ends at the front of
        // the buffer list.
        var i = paths.len;
        while (i > 0) {
            i -= 1;
            const expanded = try files.expandPath(self.gpa, paths[i], self.home);
            defer self.gpa.free(expanded);
            try self.findFile(expanded);
        }
    }

    /// Finds the language of a buffer's file and makes a syntax tree for it.
    /// If the grammar cannot load, the echo area shows the cause, and the
    /// buffer has no highlighting.
    fn attachSyntax(self: *Editor, e: *BufferEntry) void {
        if (e.syntax) |*s| s.deinit();
        e.syntax = null;
        const path = e.buf.file_path orelse return;
        const cfg = self.languages.forPath(path) orelse return;
        const lang = self.languages.load(self.io, cfg) catch {
            return self.setMessage("Cannot load language {s}: {s}", .{ cfg.name, self.languages.lastError() });
        };
        const executor = self.textExecutor() catch |err| {
            return self.setMessage("Cannot use language {s}: {t}", .{ cfg.name, err });
        };
        e.syntax = ts.Syntax.init(executor, lang, &e.buf.rope) catch |err| {
            return self.setMessage("Cannot use language {s}: {t}", .{ cfg.name, err });
        };
    }

    /// The executor for background work, made the first time.
    fn textExecutor(self: *Editor) !*text_worker.Executor {
        if (self.executor) |ex| return ex;
        const ex = try text_worker.Executor.create(self.gpa, self.io);
        self.executor = ex;
        return ex;
    }

    /// Moves the cursor with a syntax tree function.
    fn syntaxMove(self: *Editor, comptime move: fn (*const ts.Syntax, usize) ?usize) !void {
        const syn = if (self.cur().syntax) |*s| s else {
            self.setMessage("No syntax tree for this buffer", .{});
            return error.NoSyntax;
        };
        try syn.updateWait(self.curBuf());
        const pos = move(syn, self.curBuf().cursor) orelse return error.CannotMove;
        self.curBuf().moveTo(pos);
    }

    /// C-x C-s. Asks for a file name if the buffer has no file.
    fn saveBuffer(self: *Editor) !void {
        if (self.curBuf().file_path == null) return self.readFileName("File to save in: ", saveAs);
        if (!self.curBuf().isModified()) return self.setMessage("(No changes need to be saved)", .{});
        try self.writeFile();
    }

    /// Saves the buffer under a new name. The buffer gets the new file name
    /// as its name, and the new name can have a language.
    fn saveAs(self: *Editor, given_path: []const u8) anyerror!void {
        const path = try self.absolutePath(given_path);
        defer self.gpa.free(path);
        try self.curBuf().setFilePath(path);
        try self.writeFile();
        try self.renameBuffer(self.cur(), std.fs.path.basename(path));
        self.attachSyntax(self.cur());
    }

    fn writeFile(self: *Editor) !void {
        const path = self.curBuf().file_path.?;
        files.writeBuffer(self.io, Io.Dir.cwd(), self.gpa, path, self.curBuf()) catch |err| {
            return self.setMessage("Cannot save {s}: {t}", .{ path, err });
        };
        self.curBuf().markSaved();
        self.setMessage("Wrote {s}", .{path});
    }

    /// C-x C-c. If a buffer that visits a file has unsaved changes, asks
    /// first. As in Emacs, other buffers do not count.
    fn quit(self: *Editor) !void {
        for (self.buffers.items) |e| {
            if (e.buf.file_path != null and e.buf.isModified()) {
                return self.yesOrNo("Modified buffers exist; exit anyway?", stopEditor);
            }
        }
        self.running = false;
    }

    fn stopEditor(self: *Editor) anyerror!void {
        self.running = false;
    }

    // Buffers

    /// Adds a buffer at the end of the buffer list. If a buffer has the name
    /// already, the name gets "<2>", "<3>" and so on, as in Emacs. The
    /// editor takes ownership of `buffer`, also after an error.
    pub fn addBuffer(self: *Editor, name: []const u8, buffer: Buffer) !*BufferEntry {
        var b = buffer;
        errdefer b.deinit();
        const unique = try self.uniqueName(name);
        errdefer self.gpa.free(unique);
        const e = try self.gpa.create(BufferEntry);
        errdefer self.gpa.destroy(e);
        e.* = .{ .id = self.newId(), .name = unique, .buf = b };
        try self.buffers.append(self.gpa, e);
        return e;
    }

    /// Makes an empty buffer. It does not call the `buffer_open` hooks: the
    /// caller calls `bufferOpened` after its own work on the buffer.
    pub fn createBuffer(self: *Editor, name: []const u8) !*BufferEntry {
        return self.addBuffer(name, .init(self.gpa));
    }

    /// The options of a buffer: its overrides, then the global values.
    pub fn optionsFor(self: *const Editor, e: *const BufferEntry) options.Options {
        return options.resolve(self.options, e.options);
    }

    /// TAB: indents to the next indent level. With `indent_tabs`, it inserts
    /// a tab character. Otherwise it inserts spaces up to the next multiple
    /// of `indent_width`, so it lines up with other indented lines. With an
    /// active region, it indents each line of the region by one level.
    ///
    /// A count (C-u 3 TAB) indents that many levels as one edit, so one
    /// undo takes all of it away.
    fn tabToTabStop(self: *Editor, buf: *Buffer, arg: ?PrefixArg) !void {
        const count = if (arg) |a| a.count() else 1;
        if (count < 0) return error.NegativeCount;
        if (count == 0) return; // C-u 0 TAB does nothing
        const levels: usize = @intCast(count);
        // In the minibuffer, use the options of the selected buffer.
        const o = self.optionsFor(self.cur());
        const unit = options.indentUnit(o);
        const in_region = buf.activeRegion() != null;
        // Without a region and with spaces, the first level only goes to
        // the next multiple of `indent_width`, so it lines up with other
        // indented lines. The other levels are whole units.
        const first: []const u8 = if (in_region or o.indent_tabs)
            unit
        else
            options.spacesOf(o.indent_width - buf.displayColumn(buf.cursor, o.tab_width) % o.indent_width);
        const text = try self.gpa.alloc(u8, first.len + (levels - 1) * unit.len);
        defer self.gpa.free(text);
        @memcpy(text[0..first.len], first);
        var i = first.len;
        while (i < text.len) : (i += unit.len) @memcpy(text[i..][0..unit.len], unit);

        if (in_region) return buf.indentRegion(text);
        try buf.insert(text);
    }

    /// Calls the `buffer_open` hooks for a new buffer. Call it last, after
    /// all work on the buffer: a hook can change the buffer or kill it. A
    /// hook can also add hooks, so the loop reads the length each time. If
    /// a hook kills the buffer, the other hooks do not run.
    pub fn bufferOpened(self: *Editor, id: u32) void {
        var i: usize = 0;
        while (i < self.buffer_open_hooks.items.len) : (i += 1) {
            if (self.bufferById(id) == null) return;
            lua_api.callBufferHook(self, self.buffer_open_hooks.items[i], id);
        }
    }

    fn uniqueName(self: *const Editor, name: []const u8) ![]u8 {
        if (self.findBuffer(name) == null) return self.gpa.dupe(u8, name);
        var n: usize = 2;
        while (true) : (n += 1) {
            const candidate = try std.fmt.allocPrint(self.gpa, "{s}<{d}>", .{ name, n });
            if (self.findBuffer(candidate) == null) return candidate;
            self.gpa.free(candidate);
        }
    }

    fn renameBuffer(self: *Editor, e: *BufferEntry, name: []const u8) !void {
        if (std.mem.eql(u8, e.name, name)) return;
        const unique = try self.uniqueName(name);
        self.gpa.free(e.name);
        e.name = unique;
    }

    pub fn findBuffer(self: *const Editor, name: []const u8) ?*BufferEntry {
        for (self.buffers.items) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn bufferById(self: *const Editor, id: u32) ?*BufferEntry {
        for (self.buffers.items) |e| if (e.id == id) return e;
        return null;
    }

    pub fn windowById(self: *const Editor, id: u32) ?*Window {
        for (self.windows.items) |w| if (w.id == id) return w;
        return null;
    }

    fn destroyEntry(self: *Editor, e: *BufferEntry) void {
        if (e.syntax) |*s| s.deinit();
        if (e.keymap) |km| {
            km.deinit(self.gpa);
            self.gpa.destroy(km);
        }
        e.buf.deinit();
        self.gpa.free(e.name);
        self.gpa.destroy(e);
    }

    /// Moves a buffer to the front of the buffer list.
    fn moveToFront(self: *Editor, e: *BufferEntry) void {
        const i = std.mem.indexOfScalar(*BufferEntry, self.buffers.items, e) orelse return;
        std.mem.rotate(*BufferEntry, self.buffers.items[0 .. i + 1], i);
    }

    /// Shows a buffer in a window, as Emacs `set-window-buffer`.
    pub fn showBuffer(self: *Editor, win: *Window, e: *BufferEntry) !void {
        if (win == self.selected and self.search != null) self.endSearch();
        if (win.entry != e) {
            win.entry = e;
            win.top = 0;
            win.left = 0;
            // The selected window uses the buffer cursor. Another window
            // starts at the same place.
            if (win != self.selected) win.point = e.buf.cursor;
        }
        if (win == self.selected) self.moveToFront(e);
    }

    /// The buffer that C-x b and C-x k offer when the input is empty: the
    /// most recent buffer that is not `except`.
    fn otherBuffer(self: *const Editor, except: *const BufferEntry) ?*BufferEntry {
        for (self.buffers.items) |e| if (e != except) return e;
        return null;
    }

    /// Kills a buffer. A window that shows it shows another buffer, and a
    /// floating window that shows it closes. If it was the last buffer, a new
    /// "*scratch*" buffer takes its place. That buffer does not get the
    /// `buffer_open` hooks: a hook that kills it would make this recursive.
    pub fn killBuffer(self: *Editor, e: *BufferEntry) !void {
        if (self.search != null) self.endSearch();
        const i = std.mem.indexOfScalar(*BufferEntry, self.buffers.items, e) orelse return error.NoSuchBuffer;
        _ = self.buffers.orderedRemove(i);
        const replacement = if (self.buffers.items.len > 0) self.buffers.items[0] else blk: {
            break :blk self.createBuffer("*scratch*") catch |err| {
                self.buffers.insert(self.gpa, i, e) catch {};
                return err;
            };
        };
        var j: usize = self.floats.items.len;
        while (j > 0) {
            j -= 1;
            const w = self.floats.items[j];
            if (w.entry == e) self.deleteWindow(w) catch {};
        }
        for (self.windows.items) |w| if (w.entry == e) {
            w.entry = replacement;
            w.top = 0;
            w.left = 0;
            w.point = replacement.buf.cursor;
        };
        self.destroyEntry(e);
    }

    fn bufferNames(self: *Editor) ![]const []const u8 {
        const names = try self.gpa.alloc([]const u8, self.buffers.items.len);
        for (self.buffers.items, names) |e, *n| n.* = e.name;
        return names;
    }

    /// C-x b: switches to a buffer by name. A new name makes a new buffer.
    fn switchToBufferCommand(self: *Editor) !void {
        const default = if (self.otherBuffer(self.cur())) |o| o.name else null;
        var buf_text: [300]u8 = undefined;
        const prompt = if (default) |d|
            std.fmt.bufPrint(&buf_text, "Switch to buffer (default {s}): ", .{d}) catch "Switch to buffer: "
        else
            "Switch to buffer: ";
        try self.read(.{
            .prompt = prompt,
            .history = "buffer",
            .completion = .{ .strings = try self.bufferNames() },
            .owns_strings = true,
            .default = default,
            .accept = .{ .text = switchToBufferNamed },
        });
    }

    fn switchToBufferNamed(self: *Editor, name: []const u8) anyerror!void {
        if (self.findBuffer(name)) |e| return self.showBuffer(self.selected, e);
        const e = try self.createBuffer(name);
        try self.showBuffer(self.selected, e);
        self.bufferOpened(e.id);
    }

    /// C-x k: kills a buffer by name. If it visits a file and has unsaved
    /// changes, asks first.
    fn killBufferCommand(self: *Editor) !void {
        var buf_text: [300]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buf_text, "Kill buffer (default {s}): ", .{self.cur().name}) catch "Kill buffer: ";
        try self.read(.{
            .prompt = prompt,
            .history = "buffer",
            .completion = .{ .strings = try self.bufferNames() },
            .owns_strings = true,
            .require_match = true,
            .default = self.cur().name,
            .accept = .{ .text = killBufferNamed },
        });
    }

    fn killBufferNamed(self: *Editor, name: []const u8) anyerror!void {
        const e = self.findBuffer(name) orelse return error.NoSuchBuffer;
        if (e.buf.file_path != null and e.buf.isModified()) {
            self.pending_kill = e.id;
            var q: [300]u8 = undefined;
            const question = std.fmt.bufPrint(&q, "Buffer {s} modified; kill anyway?", .{e.name}) catch "Buffer modified; kill anyway?";
            return self.yesOrNo(question, killPendingBuffer);
        }
        try self.killBuffer(e);
    }

    fn killPendingBuffer(self: *Editor) anyerror!void {
        const id = self.pending_kill orelse return;
        self.pending_kill = null;
        const e = self.bufferById(id) orelse return;
        try self.killBuffer(e);
    }

    /// A window to show a buffer in, other than `except`: the split window
    /// that was selected before, another split window, or a new split below
    /// `except`. It does not use floating windows. The selection does not
    /// change.
    pub fn windowForDisplay(self: *Editor, except: *Window) !*Window {
        if (self.previous_window) |id| if (self.windowById(id)) |w| {
            if (w != except and w.float == null) return w;
        };
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.gpa);
        try self.layout.leaves(&ids);
        for (ids.items) |id| if (id != except.id) return self.windowById(id).?;
        const old = self.selected;
        self.selected = except;
        defer self.selected = old;
        return self.splitWindow(.below);
    }

    // Windows

    /// The text area of the screen: all rows above the echo area.
    fn screenArea(self: *const Editor) layout.Rect {
        const rows: usize = @intCast(@max(0, self.max_y));
        const cols: usize = @intCast(@max(0, self.max_x));
        return .{ .rows = rows -| 1, .cols = cols };
    }

    /// Computes the screen area of each window. The split layout fills the
    /// screen above the echo area, and each floating window keeps its place,
    /// inside the screen.
    pub fn relayout(self: *Editor) void {
        const area = self.screenArea();
        var placed: std.ArrayList(layout.Placed) = .empty;
        defer placed.deinit(self.gpa);
        self.separators.clearRetainingCapacity();
        self.layout.rects(area, &placed, &self.separators) catch return;
        for (placed.items) |p| if (self.windowById(p.id)) |w| {
            w.rect = p.rect;
        };
        for (self.floats.items) |w| {
            const f = w.float.?;
            const row = @min(f.row, area.rows);
            const col = @min(f.col, area.cols);
            w.rect = .{ .row = row, .col = col, .rows = @min(f.height, area.rows - row), .cols = @min(f.width, area.cols - col) };
        }
    }

    /// The part of a window that shows text: without the mode line of a
    /// tiled window, and without the border of a floating window.
    fn textRect(win: *const Window) layout.Rect {
        var r = win.rect;
        if (win.float) |f| {
            if (f.border and r.rows >= 3 and r.cols >= 3) {
                r = .{ .row = r.row + 1, .col = r.col + 1, .rows = r.rows - 2, .cols = r.cols - 2 };
            }
        } else if (r.rows >= 2) {
            r.rows -= 1; // the mode line
        }
        return r;
    }

    /// Makes a window the selected window, as Emacs `select-window`.
    pub fn selectWindow(self: *Editor, win: *Window) void {
        if (win == self.selected) return;
        if (self.search != null) self.endSearch();
        self.selected.point = self.selected.entry.buf.cursor;
        self.previous_window = self.selected.id;
        self.selected = win;
        win.entry.buf.cursor = @min(win.point, win.entry.buf.len());
        self.moveToFront(win.entry);
    }

    /// Splits the selected window. The new window shows the same buffer at
    /// the same place, and the selected window stays selected, as in Emacs.
    pub fn splitWindow(self: *Editor, dir: layout.Dir) !*Window {
        const old = self.selected;
        if (old.float != null) return error.CannotSplitFloat;
        const win = try self.gpa.create(Window);
        errdefer self.gpa.destroy(win);
        win.* = .{ .id = self.newId(), .entry = old.entry, .top = old.top, .left = old.left, .point = old.entry.buf.cursor };
        try self.windows.append(self.gpa, win);
        errdefer _ = self.windows.pop();
        try self.layout.split(old.id, win.id, dir);
        self.relayout();
        return win;
    }

    /// Opens a floating window above the split windows.
    pub fn openFloat(self: *Editor, e: *BufferEntry, f: Float, focus: bool) !*Window {
        const win = try self.gpa.create(Window);
        errdefer self.gpa.destroy(win);
        win.* = .{ .id = self.newId(), .entry = e, .float = f, .point = e.buf.cursor };
        try self.windows.append(self.gpa, win);
        errdefer _ = self.windows.pop();
        try self.floats.append(self.gpa, win);
        self.relayout();
        if (focus) self.selectWindow(win);
        return win;
    }

    /// Closes a window. The last split window cannot close.
    pub fn deleteWindow(self: *Editor, win: *Window) !void {
        if (win.float == null) {
            try self.layout.remove(win.id);
        } else if (std.mem.indexOfScalar(*Window, self.floats.items, win)) |i| {
            _ = self.floats.orderedRemove(i);
        }
        if (win == self.selected) {
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(self.gpa);
            try self.layout.leaves(&ids);
            // The window that was selected before, or the first split window.
            const before = if (self.previous_window) |id| self.windowById(id) else null;
            const next = if (before != null and before.? != win) before.? else self.windowById(ids.items[0]).?;
            if (self.search != null) self.endSearch();
            // Do not save the cursor of a window that goes away.
            self.selected = next;
            next.entry.buf.cursor = @min(next.point, next.entry.buf.len());
        }
        if (std.mem.indexOfScalar(*Window, self.windows.items, win)) |i| _ = self.windows.orderedRemove(i);
        self.freeLuaRef(win.on_draw);
        self.gpa.destroy(win);
        self.relayout();
    }

    /// C-x 1: closes all other split windows.
    fn deleteOtherWindows(self: *Editor) !void {
        if (self.selected.float != null) return error.FloatWindow;
        var removed: std.ArrayList(u32) = .empty;
        defer removed.deinit(self.gpa);
        try self.layout.only(self.selected.id, &removed);
        for (removed.items) |id| {
            const w = self.windowById(id) orelse continue;
            if (std.mem.indexOfScalar(*Window, self.windows.items, w)) |i| _ = self.windows.orderedRemove(i);
            self.freeLuaRef(w.on_draw);
            self.gpa.destroy(w);
        }
        self.relayout();
    }

    /// C-x o: selects the next window: the split windows in screen order,
    /// then the floating windows.
    fn otherWindow(self: *Editor) !void {
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(self.gpa);
        try self.layout.leaves(&order);
        for (self.floats.items) |w| try order.append(self.gpa, w.id);
        if (order.items.len < 2) return error.NoOtherWindow;
        const i = std.mem.indexOfScalar(u32, order.items, self.selected.id) orelse 0;
        self.selectWindow(self.windowById(order.items[(i + 1) % order.items.len]).?);
    }

    /// "q" in a special buffer: closes the window, or shows another buffer
    /// if it is the last window, as Emacs `quit-window`.
    fn quitWindow(self: *Editor) !void {
        const win = self.selected;
        if (win.float != null or self.windows.items.len - self.floats.items.len > 1) {
            return self.deleteWindow(win);
        }
        const other = self.otherBuffer(win.entry) orelse return error.NoOtherBuffer;
        try self.showBuffer(win, other);
    }

    pub fn freeLuaRef(self: *Editor, ref: ?c_int) void {
        const r = ref orelse return;
        const L = self.L orelse return;
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
    }

    // Faces

    /// The terminal attribute of a face: a color pair, and bold, underline
    /// and reverse. Without a screen, 0.
    pub fn faceAttr(self: *Editor, id: face.FaceId) c_int {
        if (!self.screen) return 0;
        if (self.attr_cache_version != self.faces.version or self.attr_cache.items.len != self.faces.count()) {
            self.attr_cache.clearRetainingCapacity();
            self.attr_cache.appendNTimes(self.gpa, null, self.faces.count()) catch return 0;
            self.attr_cache_version = self.faces.version;
        }
        if (id >= self.attr_cache.items.len) return 0;
        if (self.attr_cache.items[id]) |a| return a;
        const a = self.makeAttr(self.faces.get(id));
        self.attr_cache.items[id] = a;
        return a;
    }

    fn makeAttr(self: *Editor, style: face.Style) c_int {
        var a: c_int = 0;
        if (style.bold) a |= @intCast(c.A_BOLD);
        if (style.underline) a |= @intCast(c.A_UNDERLINE);
        if (style.reverse) a |= @intCast(c.A_REVERSE);
        if (c.has_colors()) {
            const fg = fitColor(style.fg);
            const bg = fitColor(style.bg);
            if (fg != face.default_color or bg != face.default_color) {
                if (self.colorPair(fg, bg)) |pair| a |= @intCast(c.COLOR_PAIR(pair));
            }
        } else if (style.bg != face.default_color) {
            a |= @intCast(c.A_REVERSE); // no colors: show a background as reverse video
        }
        return a;
    }

    /// A color that the terminal has: a bright color becomes the normal
    /// color on an 8-color terminal, and other missing colors become the
    /// default color.
    fn fitColor(color: face.Color) face.Color {
        if (color < 0 or color < c.COLORS) return color;
        if (color < 16) return color - 8;
        return face.default_color;
    }

    /// The ncurses color pair for a foreground and background. It makes the
    /// pair the first time. Null if the terminal has no more pairs.
    fn colorPair(self: *Editor, fg: face.Color, bg: face.Color) ?c_short {
        for (self.color_pairs.items, 1..) |p, n| {
            if (p[0] == fg and p[1] == bg) return @intCast(n);
        }
        const n = self.color_pairs.items.len + 1;
        if (n >= c.COLOR_PAIRS or n > std.math.maxInt(c_short)) return null;
        self.color_pairs.append(self.gpa, .{ fg, bg }) catch return null;
        _ = c.init_pair(@intCast(n), fg, bg);
        return @intCast(n);
    }

    /// The face of a syntax group: the built-in face with the same name.
    fn syntaxFace(f: ts.Face) ?face.FaceId {
        return switch (f) {
            .none => null,
            inline else => |tag| @field(face.Builtin, @tagName(tag)).id(),
        };
    }

    /// The number of screen rows for text in the selected window.
    fn textRows(self: *const Editor) usize {
        return @max(1, textRect(self.selected).rows);
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
        const moved = self.curBuf().moveLines(down, step);
        if (moved == 0) return if (down) error.EndOfBuffer else error.BeginningOfBuffer;
        if (down) self.selected.top += moved else self.selected.top -|= moved;
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

    pub fn resize(self: *Editor) void {
        if (!self.screen) return;
        self.max_y = c.getmaxy(c.stdscr);
        self.max_x = c.getmaxx(c.stdscr);
        self.relayout();
    }

    /// Scrolls a window so that `point` is in its text area.
    fn scrollWindow(win: *Window, point: usize, text: layout.Rect, tab_width: usize) void {
        const b = &win.entry.buf;
        const line = b.lineOf(point);
        if (line < win.top) win.top = line;
        if (line >= win.top + text.rows) win.top = line - text.rows + 1;
        const col = b.displayColumn(point, tab_width);
        if (col < win.left) win.left = col;
        if (col >= win.left + text.cols) win.left = col - text.cols + 1;
    }

    const Pos = struct { row: usize, col: usize };

    /// Draws all windows and the echo area, and puts the cursor in the
    /// selected window or in the minibuffer.
    pub fn render(self: *Editor) void {
        self.relayout();
        _ = c.erase();
        var cursor: ?Pos = null;

        for (self.windows.items) |w| {
            if (w.float != null) continue;
            const p = self.drawWindow(w);
            if (w == self.selected) cursor = p;
        }
        const border = self.faceAttr(face.Builtin.border.id());
        for (self.separators.items) |sep| {
            for (0..sep.rows) |i| drawText(sep.row + i, sep.col, "│", border);
        }
        for (self.floats.items) |w| {
            self.drawFloatFrame(w);
            const p = self.drawWindow(w);
            if (w == self.selected) cursor = p;
        }

        if (self.max_y > 0) {
            const echo_row: usize = @intCast(self.max_y - 1);
            const cols: usize = @intCast(@max(1, self.max_x));
            if (self.reader) |*r| {
                const mb_col = self.drawMinibuffer(&r.mb, @intCast(echo_row), cols);
                _ = c.move(@intCast(echo_row), @intCast(mb_col));
                _ = c.refresh();
                return;
            }
            // A message keeps its start. The screen edge cuts the end.
            var msg_line: CellLine = .{ .row = @intCast(echo_row), .cols = cols, .left = 0, .attr = 0, .draw = true };
            if (self.search) |*s| {
                var prompt_buf: [256]u8 = undefined;
                msg_line.putText(s.prompt(&prompt_buf));
            } else {
                msg_line.putText(self.message_buf[0..self.message_len]);
            }
        }
        if (cursor) |p| _ = c.move(@intCast(p.row), @intCast(p.col));
        _ = c.refresh();
    }

    /// Clears the area of a floating window and draws its border.
    fn drawFloatFrame(self: *Editor, w: *const Window) void {
        const r = w.rect;
        for (0..r.rows) |i| {
            for (0..r.cols) |j| drawText(r.row + i, r.col + j, " ", 0);
        }
        const f = w.float.?;
        if (!f.border or r.rows < 3 or r.cols < 3) return;
        const attr = self.faceAttr(face.Builtin.border.id());
        const bottom = r.row + r.rows - 1;
        const right = r.col + r.cols - 1;
        for (r.col + 1..right) |col| {
            drawText(r.row, col, "─", attr);
            drawText(bottom, col, "─", attr);
        }
        for (r.row + 1..bottom) |row| {
            drawText(row, r.col, "│", attr);
            drawText(row, right, "│", attr);
        }
        drawText(r.row, r.col, "┌", attr);
        drawText(r.row, right, "┐", attr);
        drawText(bottom, r.col, "└", attr);
        drawText(bottom, right, "┘", attr);
    }

    /// Draws one window: its text, its mode line, and its Lua draw function.
    /// Returns the screen position of its cursor. Each codepoint uses one
    /// cell. Long lines are cut at the window edge, and all lines of a window
    /// scroll horizontally together.
    fn drawWindow(self: *Editor, win: *Window) ?Pos {
        const e = win.entry;
        const b = &e.buf;
        const text = textRect(win);
        const selected = win == self.selected;
        var result: ?Pos = null;

        if (text.rows > 0 and text.cols > 0) {
            const point = if (selected) b.cursor else @min(win.point, b.len());
            const tab_width: usize = self.optionsFor(e).tab_width;
            scrollWindow(win, point, text, tab_width);
            const region = if (selected) b.activeRegion() else null;

            // Faces for the visible bytes only.
            const vis_start = b.lineOffset(win.top);
            const vis_end = b.lineOffset(win.top + text.rows);
            const syntax_faces = self.visibleFaces(e, vis_start, vis_end);
            defer self.gpa.free(syntax_faces);
            const hl = self.visibleHighlights(b, vis_start, vis_end);
            defer self.gpa.free(hl);
            const marks = if (selected) self.visibleSearchMarks(vis_start, vis_end) else self.gpa.alloc(u8, 0) catch &.{};
            defer self.gpa.free(marks);
            const region_attr = self.faceAttr(face.Builtin.region.id());
            const isearch_attr = self.faceAttr(face.Builtin.isearch.id());
            const lazy_attr = self.faceAttr(face.Builtin.lazy_highlight.id());

            var line: usize = 0;
            var col: usize = 0;
            var pos: usize = 0;
            var cursor_line: usize = 0;
            var cursor_col: usize = 0;

            // A codepoint can cross a chunk boundary, so collect its bytes here.
            var cp_buf: [4]u8 = undefined;
            var cp_len: usize = 0;
            var cp_need: usize = 0;
            var cp_start: usize = 0;

            var it = b.rope.chunks();
            outer: while (it.next()) |chunk| {
                for (chunk) |byte| {
                    defer pos += 1;
                    if (cp_len == 0) {
                        if (pos == point) {
                            cursor_line = line;
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
                        if (line >= win.top + text.rows) break :outer;
                        continue;
                    }
                    const visible = line >= win.top;
                    const row = text.row + (line -| win.top);
                    const vi = cp_start -| vis_start;
                    const in_vis = cp_start >= vis_start and vi < syntax_faces.len;
                    const in_region = if (region) |r| cp_start >= r.start and cp_start < r.end else false;
                    // Search colors win, then the region, then highlight
                    // ranges, then syntax colors.
                    const mark: u8 = if (in_vis and vi < marks.len) marks[vi] else 0;
                    const strong: c_int = switch (mark) {
                        2 => isearch_attr,
                        1 => lazy_attr,
                        else => if (in_region) region_attr else if (in_vis and vi < hl.len and hl[vi] != 0) self.faceAttr(hl[vi]) else 0,
                    };
                    if (bytes[0] == '\t') {
                        const next = (col / tab_width + 1) * tab_width;
                        // erase() cleared these cells. Draw spaces only to show a color.
                        if (visible and strong != 0) {
                            while (col < next) : (col += 1) drawCell(text, win.left, row, col, " ", strong);
                        }
                        col = next;
                        continue;
                    }
                    if (visible) {
                        const shown: []const u8 = if (bytes[0] < 0x20 or bytes[0] == 0x7f or
                            !std.unicode.utf8ValidateSlice(bytes)) "?" else bytes;
                        const attr = if (strong != 0) strong else if (in_vis) if (syntaxFace(syntax_faces[vi])) |f| self.faceAttr(f) else 0 else 0;
                        drawCell(text, win.left, row, col, shown, attr);
                    }
                    col += 1;
                }
            }
            if (pos == point) {
                cursor_line = line;
                cursor_col = col;
            }
            result = .{
                .row = text.row + (cursor_line -| win.top),
                .col = text.col + @min(cursor_col -| win.left, text.cols - 1),
            };
        }

        if (win.float == null and win.rect.rows >= 2) self.drawModeLine(win);
        if (win.on_draw) |ref| lua_api.callOnDraw(self, win, ref, text);
        return result;
    }

    /// Draws the mode line of a window: the modified mark, the buffer name,
    /// and the cursor line and column, as in Emacs. A Lua function can give
    /// other text. The selected window has the `mode_line` face, and the
    /// other windows have `mode_line_inactive`.
    fn drawModeLine(self: *Editor, win: *Window) void {
        const r = win.rect;
        const row = r.row + r.rows - 1;
        const selected = win == self.selected;
        const attr = self.faceAttr(if (selected) face.Builtin.mode_line.id() else face.Builtin.mode_line_inactive.id());
        const b = &win.entry.buf;
        const point = if (selected) b.cursor else @min(win.point, b.len());
        const tab_width: usize = self.optionsFor(win.entry).tab_width;

        var text_buf: [512]u8 = undefined;
        const text = lua_api.modeLineText(self, win, &text_buf) orelse blk: {
            const state = if (b.read_only) "%%" else if (b.isModified()) "**" else "--";
            break :blk std.fmt.bufPrint(&text_buf, "-:{s}-  {s}    L{d} C{d}", .{
                state, win.entry.name, b.lineOf(point) + 1, b.displayColumn(point, tab_width),
            }) catch &text_buf;
        };

        if (attr != 0) _ = c.attron(attr);
        defer if (attr != 0) {
            _ = c.attroff(attr);
        };
        for (0..r.cols) |i| drawText(row, r.col + i, " ", 0);
        var line: CellLine = .{ .row = @intCast(row), .col = r.col, .cols = r.cols, .left = 0, .attr = 0, .draw = true };
        line.putText(text);
    }

    /// Draws the prompt, the input and a message in brackets on the echo row.
    /// A long line scrolls so that the cursor stays on the screen. Control
    /// characters in the input show as "^J" and so on. Returns the cursor
    /// column.
    fn drawMinibuffer(self: *Editor, mb: *Minibuffer, row: c_int, cols: usize) usize {
        const input = mb.text(self.gpa) catch return 0;
        defer self.gpa.free(input);
        const message = self.message_buf[0..self.message_len];
        const region_attr = self.faceAttr(face.Builtin.region.id());

        // The first pass finds the cursor cell. The second pass draws.
        var line: CellLine = .{ .row = row, .cols = cols, .left = mb.left, .attr = region_attr, .draw = false };
        line.layout(mb.prompt, input, mb.buffer.cursor, mb.buffer.activeRegion(), message);
        // When the cursor goes back into the first screen width, show the
        // line from its start, so the prompt is visible again.
        if (line.cursor_cell < mb.left) mb.left = if (line.cursor_cell < cols) 0 else line.cursor_cell;
        if (line.cursor_cell >= mb.left + cols) mb.left = line.cursor_cell - cols + 1;

        line = .{ .row = row, .cols = cols, .left = mb.left, .attr = region_attr, .draw = true };
        line.layout(mb.prompt, input, mb.buffer.cursor, mb.buffer.activeRegion(), message);
        return line.cursor_cell - mb.left;
    }

    /// For each byte from `start` to `end`: 2 in the current search match,
    /// 1 in another match, 0 at other places. Without a search, all zeros.
    /// The caller frees it.
    fn visibleSearchMarks(self: *Editor, start: usize, end: usize) []u8 {
        const marks = self.gpa.alloc(u8, end - start) catch return &.{};
        @memset(marks, 0);
        const s = if (self.search) |*s| s else return marks;
        const q = s.query.items;
        if (q.len == 0) return marks;
        const fold = s.foldCase();
        // Start early enough to find a match that begins before `start`.
        var from = start -| (q.len - 1);
        while (isearch.findForward(s.text, q, from, fold)) |i| {
            if (i >= end) break;
            paint(u8, marks, start, i, i + q.len, 1);
            from = i + 1;
        }
        if (s.match) |m| paint(u8, marks, start, m.start, m.end, 2);
        return marks;
    }

    fn paint(comptime T: type, marks: []T, base: usize, lo: usize, hi: usize, value: T) void {
        const a = @max(lo, base);
        const b = @min(hi, base + marks.len);
        if (a < b) @memset(marks[a - base .. b - base], value);
    }

    /// The highlight face of each byte from `start` to `end`, or 0 for no
    /// highlight. A later highlight wins over an earlier one. The caller
    /// frees it.
    fn visibleHighlights(self: *Editor, b: *const Buffer, start: usize, end: usize) []face.FaceId {
        const out = self.gpa.alloc(face.FaceId, end - start) catch return &.{};
        @memset(out, 0);
        for (b.highlights.items) |h| paint(face.FaceId, out, start, h.start, h.end, h.face);
        return out;
    }

    /// The syntax face of each byte from `start` to `end`. Without a syntax
    /// tree, or after an error, all faces are `.none`. The caller frees it.
    fn visibleFaces(self: *Editor, e: *BufferEntry, start: usize, end: usize) []ts.Face {
        const faces = self.gpa.alloc(ts.Face, end - start) catch return &.{};
        @memset(faces, .none);
        const syn = if (e.syntax) |*s| s else return faces;
        syn.update(&e.buf) catch return faces;
        syn.highlight(start, faces) catch @memset(faces, .none);
        return faces;
    }
};

/// Lays out one screen line cell by cell, and draws the cells from `left` on
/// if `draw` is true. It records the cell of the cursor.
const CellLine = struct {
    row: c_int,
    /// The screen column of the first cell.
    col: usize = 0,
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
        _ = c.mvaddnstr(self.row, @intCast(self.col + self.cell - self.left), text.ptr, @intCast(text.len));
        if (highlight) _ = c.attroff(self.attr);
    }
};

/// Draws one cell of a window's text: `col` is the display column in the
/// buffer, and `left` is the first display column of the window.
fn drawCell(text: layout.Rect, left: usize, row: usize, col: usize, cell: []const u8, attr: c_int) void {
    if (col < left or col >= left + text.cols) return;
    drawText(row, text.col + col - left, cell, attr);
}

fn drawText(row: usize, col: usize, text: []const u8, attr: c_int) void {
    if (attr != 0) _ = c.attron(attr);
    _ = c.mvaddnstr(@intCast(row), @intCast(col), text.ptr, @intCast(text.len));
    if (attr != 0) _ = c.attroff(attr);
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

/// Returns `~/.config/editor-zig/init.lua`, or null if `HOME` has no value.
fn configPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[:0]u8 {
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.joinZ(arena, &.{ home, ".config", "editor-zig", "init.lua" });
}

/// Returns `<prefix>/share/editor-zig/lua` for an executable in
/// `<prefix>/bin`: the directory of the plugins that come with the editor.
/// Returns null if the editor cannot find its own path.
fn pluginDir(io: Io, arena: std.mem.Allocator) ?[]const u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, arena) catch return null;
    const prefix = std.fs.path.dirname(exe_dir) orelse return null;
    return std.fs.path.join(arena, &.{ prefix, "share", "editor-zig", "lua" }) catch null;
}

/// Lets `require` find modules in `dir`:
/// `require("foo")` loads `<dir>/foo.lua` or `<dir>/foo/init.lua`, and
/// `require("a.b")` loads `<dir>/a/b.lua`. C modules load from `<dir>/?.so`.
/// The directory comes before the paths that are in `package.path` now, so
/// its modules win.
///
/// Lua path templates use ";" between templates and "?" for the module
/// name, and they have no escape. A directory with one of these characters
/// cannot be in the path, so this returns error.UnusableDir.
fn addDirToPath(L: *c.lua_State, dir: []const u8) !void {
    if (std.mem.indexOfAny(u8, dir, ";?") != null) return error.UnusableDir;
    _ = c.lua_getglobal(L, "package");
    defer c.lua_settop(L, -2); // pop `package`
    prependSearchPath(L, "path", dir, &.{ "?.lua", "?/init.lua" });
    prependSearchPath(L, "cpath", dir, &.{"?.so"});
}

/// Sets `package[field]` to "<dir>/<pattern>;" for each pattern, then the
/// old value. `package` must be on the top of the stack.
fn prependSearchPath(L: *c.lua_State, comptime field: [:0]const u8, dir: []const u8, comptime patterns: []const []const u8) void {
    inline for (patterns) |pattern| {
        _ = c.lua_pushlstring(L, dir.ptr, dir.len);
        _ = c.lua_pushstring(L, "/" ++ pattern ++ ";");
    }
    // `package` is below the strings.
    _ = c.lua_getfield(L, -1 - 2 * @as(c_int, patterns.len), field);
    c.lua_concat(L, 2 * patterns.len + 1);
    c.lua_setfield(L, -2, field);
}

/// Loads and runs the config file. If the file is missing or has an error,
/// the editor starts without it, and an error shows in the echo area.
/// Modules next to the file load with `require`. They come before the
/// plugins that come with the editor, so a config module can replace one.
fn loadConfig(editor: *Editor, L: *c.lua_State, path: [:0]const u8) void {
    if (std.fs.path.dirname(path)) |dir| addDirToPath(L, dir) catch {
        editor.setMessage("init.lua: require cannot find modules in {s}: its path has \";\" or \"?\"", .{dir});
    };
    if (c.luaL_loadfilex(L, path.ptr, null) != c.LUA_OK or
        c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK)
    {
        // A missing file is not an error. Show other errors at startup.
        var len: usize = 0;
        const msg = c.lua_tolstring(L, -1, &len);
        const text = if (msg) |m| m[0..len] else "";
        if (std.mem.indexOf(u8, text, "cannot open") == null) editor.setMessage("init.lua: {s}", .{text});
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
    var is_km: Keymap = .{};
    defer is_km.deinit(gpa);
    try bindDefaults(&km, &mb_km, &is_km, gpa);
    const home = init.environ_map.get("HOME");

    // The editor's syntax trees use the languages, so the languages must be
    // freed after the editor. This defer runs after `editor.deinit`.
    var languages: ts.Languages = .init(gpa);
    defer languages.deinit();

    const L = c.luaL_newstate() orelse return error.LuaInit;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    // The editor needs no screen yet, so init.lua can make buffers and
    // windows. Load the config before ncurses takes control of the terminal.
    var editor: Editor = try .init(gpa, .{
        .io = io,
        .home = home,
        .L = L,
        .global_keymap = &km,
        .minibuffer_keymap = &mb_km,
        .isearch_keymap = &is_km,
        .languages = &languages,
    });
    defer editor.deinit();
    var lua_ctx: lua_api.Context = .{ .gpa = gpa, .keymap = &km, .languages = &languages, .home = home, .editor = &editor };
    lua_api.register(L, &lua_ctx);
    // Add the plugin directory first, so the config directory comes before it.
    if (pluginDir(io, init.arena.allocator())) |dir| addDirToPath(L, dir) catch {
        editor.setMessage("require cannot find the editor plugins in {s}: its path has \";\" or \"?\"", .{dir});
    };
    if (try configPath(init.arena.allocator(), init.environ_map)) |path| {
        loadConfig(&editor, L, path);
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

    editor.initScreen();

    // `editor_zig a b c` opens a buffer for each file, as `emacs a b c` does.
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var args = init.minimal.args.iterate();
    _ = args.skip(); // the program name
    while (args.next()) |path| try paths.append(gpa, path);
    try editor.openFiles(paths.items);
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
    _ = @import("text_worker.zig");
    _ = options;
    _ = @import("prefix_arg.zig");
    _ = @import("isearch.zig");
    _ = @import("history.zig");
    _ = @import("layout.zig");
    _ = @import("face.zig");
}

// Editor tests. They make an editor without a screen and send it keys.

const testing = std.testing;

/// An editor for tests, with its keymaps. It lives on the heap, so the
/// pointers between its parts stay valid.
const TestEditor = struct {
    km: Keymap = .{},
    mb_km: Keymap = .{},
    is_km: Keymap = .{},
    languages: ts.Languages,
    ed: Editor = undefined,
    L: ?*c.lua_State = null,
    lua_ctx: lua_api.Context = undefined,

    fn create() !*TestEditor {
        const gpa = testing.allocator;
        const t = try gpa.create(TestEditor);
        t.* = .{ .languages = .init(gpa) };
        try bindDefaults(&t.km, &t.mb_km, &t.is_km, gpa);
        t.ed = try .init(gpa, .{
            .io = testing.io,
            .global_keymap = &t.km,
            .minibuffer_keymap = &t.mb_km,
            .isearch_keymap = &t.is_km,
            .languages = &t.languages,
        });
        return t;
    }

    /// An editor with a Lua state and the `editor` API.
    fn createWithLua() !*TestEditor {
        const t = try create();
        const L = c.luaL_newstate() orelse return error.LuaInit;
        c.luaL_openlibs(L);
        t.L = L;
        t.ed.L = L;
        t.lua_ctx = .{ .gpa = testing.allocator, .keymap = &t.km, .languages = &t.languages, .home = null, .editor = &t.ed };
        lua_api.register(L, &t.lua_ctx);
        return t;
    }

    /// Runs Lua code. A Lua error prints its message and fails the test.
    fn lua(t: *TestEditor, code: [:0]const u8) !void {
        const L = t.L.?;
        if (c.luaL_loadstring(L, code.ptr) != c.LUA_OK or c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK) {
            std.debug.print("Lua error: {s}\n", .{c.lua_tolstring(L, -1, null)});
            c.lua_settop(L, -2);
            return error.LuaError;
        }
    }

    /// Runs Lua code that must give an error, and returns true if the error
    /// message has `want`.
    fn luaFails(t: *TestEditor, code: [:0]const u8, want: []const u8) !bool {
        const L = t.L.?;
        if (c.luaL_loadstring(L, code.ptr) != c.LUA_OK) return error.LuaSyntax;
        if (c.lua_pcallk(L, 0, 0, 0, 0, null) == c.LUA_OK) return false;
        defer c.lua_settop(L, -2);
        const msg = std.mem.span(c.lua_tolstring(L, -1, null));
        return std.mem.indexOf(u8, msg, want) != null;
    }

    fn destroy(t: *TestEditor) void {
        const gpa = testing.allocator;
        t.ed.deinit();
        if (t.L) |L| c.lua_close(L);
        t.languages.deinit();
        t.is_km.deinit(gpa);
        t.mb_km.deinit(gpa);
        t.km.deinit(gpa);
        gpa.destroy(t);
    }

    /// Sends keys in Emacs notation, for example "C-x C-f" or "M-x".
    fn press(t: *TestEditor, notation: []const u8) !void {
        var buf: [16]keymap.Chord = undefined;
        for (try keymap.parseKeys(notation, &buf)) |chord| {
            _ = t.ed.handleKey(.{ .key = chord.key, .mods = .{
                .ctrl = chord.ctrl,
                .alt = chord.alt,
                .shift = chord.shift,
                .super = chord.super,
            } });
        }
    }

    /// Types text, one key for each codepoint.
    fn typeText(t: *TestEditor, text: []const u8) !void {
        var it = (try std.unicode.Utf8View.init(text)).iterator();
        while (it.nextCodepoint()) |cp| _ = t.ed.handleKey(.{ .key = .{ .codepoint = cp } });
    }

    fn expectText(t: *TestEditor, want: []const u8) !void {
        const got = try t.ed.curBuf().copyRange(testing.allocator, 0, t.ed.curBuf().len());
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn message(t: *TestEditor) []const u8 {
        return t.ed.message_buf[0..t.ed.message_len];
    }
};

test "editor: typing, C-u and undo" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("ab");
    try t.press("C-u 3");
    try t.typeText("x");
    try t.expectText("abxxx");
    try t.press("C-u - 2 C-f"); // back 2
    try testing.expectEqual(3, t.ed.curBuf().cursor);
    try t.press("C-/");
    try t.expectText("ab");
    try testing.expectEqual(0, t.ed.bells);
}

test "editor: isearch, RET and C-s C-s" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("one two one");
    try t.press("C-a");
    try t.press("C-s");
    try t.typeText("one");
    try testing.expectEqual(3, t.ed.curBuf().cursor);
    try t.press("C-s");
    try testing.expectEqual(11, t.ed.curBuf().cursor);
    try t.press("RET");
    try testing.expect(t.ed.search == null);
    try testing.expectEqual(0, t.ed.curBuf().mark.?); // the start of the search
    try t.press("C-a C-s C-s"); // the last search again
    try testing.expectEqual(3, t.ed.curBuf().cursor);
    try t.press("C-g"); // back to the start
    try testing.expectEqual(0, t.ed.curBuf().cursor);
}

fn minibufferText(t: *TestEditor) ![]u8 {
    return t.ed.reader.?.mb.text(testing.allocator);
}

fn expectMinibuffer(t: *TestEditor, want: []const u8) !void {
    const got = try minibufferText(t);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "editor: M-x completes a command name and gives it the prefix argument" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("abcdef");
    try t.press("C-a C-u 3 M-x");
    try testing.expectEqualStrings("M-x ", t.ed.reader.?.mb.prompt);
    try t.typeText("forward_ch");
    try t.press("TAB");
    try expectMinibuffer(t, "forward_char");
    try t.press("RET");
    try testing.expect(t.ed.reader == null);
    try testing.expectEqual(3, t.ed.curBuf().cursor);

    // The "command" history has the name now.
    try t.press("M-x M-p");
    try expectMinibuffer(t, "forward_char");
    try t.press("C-g");
    try testing.expect(t.ed.reader == null);
}

test "editor: M-x accepts only a command name" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.press("M-x");
    try t.typeText("nope");
    try t.press("RET");
    try testing.expect(t.ed.reader != null); // still open
    try testing.expectEqualStrings("No match", t.message());
    try testing.expectEqual(1, t.ed.bells);
    try t.press("C-g");
    try testing.expect(t.ed.reader == null);
}

test "editor: a yes or no question" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.ed.curBuf().setFilePath("/nowhere/x.txt"); // only file buffers count
    try t.typeText("x"); // modified
    try t.press("C-x C-c");
    try testing.expectEqualStrings("Modified buffers exist; exit anyway? (yes or no) ", t.ed.reader.?.mb.prompt);
    try t.press("C-g");
    try t.press("C-x C-c");
    try t.typeText("maybe");
    try t.press("RET");
    try testing.expect(t.ed.reader != null); // not yes or no: stays open

    try t.press("C-a C-k"); // normal editing works in the minibuffer
    try t.typeText("n");
    try t.press("TAB RET"); // "n" completes to "no"
    try testing.expectEqualStrings("Cancelled", t.message());
    try testing.expect(t.ed.running);

    try t.press("C-x C-c");
    try t.typeText("y");
    try t.press("TAB RET");
    try testing.expect(!t.ed.running);
}

test "a config directory with \";\" or \"?\" is not added to the require path" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a;b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a;b/init.lua", .data = "loaded = true" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.joinZ(testing.allocator, &.{ dir, "a;b", "init.lua" });
    defer testing.allocator.free(path);
    loadConfig(&t.ed, t.L.?, path);
    try testing.expect(std.mem.indexOf(u8, t.message(), "require cannot find modules") != null);
    try t.lua(
        \\assert(loaded == true) -- the file still runs
        \\assert(not package.path:find("a;b", 1, true))
    );
}

test "init.lua can require modules from its own directory" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "pkg");
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mod.lua", .data = "return { name = 'mod' }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/init.lua", .data = "return { name = 'pkg' }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/b.lua", .data = "return { name = 'a.b' }" });
    // A file with the name of a standard library module does not replace
    // it, because `package.loaded` has the library before init.lua runs.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "string.lua", .data = "return 'not loaded'" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "init.lua", .data =
        \\found = require("mod").name .. " " .. require("pkg").name .. " " .. require("a.b").name
    });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.joinZ(testing.allocator, &.{ dir, "init.lua" });
    defer testing.allocator.free(path);
    loadConfig(&t.ed, t.L.?, path);

    try testing.expectEqualStrings("", t.message()); // no error
    try t.lua(
        \\assert(found == "mod pkg a.b", tostring(found))
        \\-- The standard library is already loaded, so require gives it.
        \\assert(require("string") == string)
    );
}

test "a config module replaces a plugin with the same name" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "plugins");
    try tmp.dir.createDirPath(testing.io, "config");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugins/both.lua", .data = "return 'plugin'" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugins/only.lua", .data = "return 'plugin'" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config/both.lua", .data = "return 'config'" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config/init.lua", .data =
        \\found = require("both") .. " " .. require("only")
    });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const plugins = try std.fs.path.join(testing.allocator, &.{ dir, "plugins" });
    defer testing.allocator.free(plugins);
    const path = try std.fs.path.joinZ(testing.allocator, &.{ dir, "config", "init.lua" });
    defer testing.allocator.free(path);
    // The same order as main: the plugin directory first, then the config.
    try addDirToPath(t.L.?, plugins);
    loadConfig(&t.ed, t.L.?, path);

    try testing.expectEqualStrings("", t.message()); // no error
    try t.lua(
        \\assert(found == "config plugin", tostring(found))
    );
}

test "editor: open and save files with prompts, completion and history" {
    const t = try TestEditor.create();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "hello" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    // Find file: complete "no" to "notes.txt", then open it.
    try t.press("C-x C-f");
    try expectMinibuffer(t, ""); // no file yet: no directory
    try t.typeText(dir);
    try t.typeText("/no");
    try t.press("TAB");
    try testing.expectEqualStrings("Sole completion", t.message());
    try t.press("RET");
    try t.expectText("hello");

    // Edit and save.
    try t.typeText("> ");
    try t.press("C-x C-s");
    const saved = try tmp.dir.readFileAlloc(testing.io, "notes.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("> hello", saved);

    // The next prompt starts in the file's directory, and M-p gives the
    // last file name.
    try t.press("C-x C-f");
    const want_dir = try std.fmt.allocPrint(testing.allocator, "{s}/", .{dir});
    defer testing.allocator.free(want_dir);
    try expectMinibuffer(t, want_dir);
    try t.press("M-p");
    const want_file = try std.fmt.allocPrint(testing.allocator, "{s}/notes.txt", .{dir});
    defer testing.allocator.free(want_file);
    try expectMinibuffer(t, want_file);
    try t.press("C-g");

    // A new buffer asks for a name, in the same directory.
    try t.ed.showBuffer(t.ed.selected, try t.ed.createBuffer("new"));
    try t.typeText("new");
    try t.press("C-x C-s");
    try testing.expectEqualStrings("File to save in: ", t.ed.reader.?.mb.prompt);
    try t.typeText(dir);
    try t.typeText("/new.txt");
    try t.press("RET");
    const written = try tmp.dir.readFileAlloc(testing.io, "new.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("new", written);
}

test "editor: M-p and M-n in isearch use the search history" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("one two three");
    try t.press("C-a C-s");
    try t.typeText("one");
    try t.press("RET C-a C-s");
    try t.typeText("three");
    try t.press("RET C-a C-s M-p");
    try testing.expectEqualStrings("three", t.ed.search.?.query.items);
    try testing.expectEqual(13, t.ed.curBuf().cursor);
    try t.press("M-p");
    try testing.expectEqualStrings("one", t.ed.search.?.query.items);
    try testing.expectEqual(3, t.ed.curBuf().cursor);
    try t.press("M-n M-n");
    try testing.expectEqualStrings("", t.ed.search.?.query.items);
    try t.press("C-g");
    try testing.expect(t.ed.search == null);
}

fn tiledCount(t: *TestEditor) usize {
    return t.ed.windows.items.len - t.ed.floats.items.len;
}

test "editor: split, select and close windows" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("line one");
    try t.press("RET");
    try t.typeText("line two");
    const first = t.ed.selected;

    try t.press("C-x 2");
    try testing.expectEqual(2, tiledCount(t));
    try testing.expectEqual(first, t.ed.selected); // the old window stays selected
    // Each window has a half of the 23 text rows, with a mode line.
    try testing.expectEqual(layout.Rect{ .row = 0, .col = 0, .rows = 11, .cols = 80 }, first.rect);

    // Each window keeps its own cursor in the same buffer.
    try t.press("C-o"); // not bound: beep, no change
    try t.press("C-a");
    try t.press("C-x o");
    try testing.expect(t.ed.selected != first);
    try testing.expectEqual(17, t.ed.curBuf().cursor); // the cursor at the split
    try t.press("C-x o");
    try testing.expectEqual(first, t.ed.selected);
    try testing.expectEqual(9, t.ed.curBuf().cursor); // the start of line two

    try t.press("C-x 3");
    try testing.expectEqual(3, tiledCount(t));
    try t.press("C-x 0"); // closes the selected window
    try testing.expectEqual(2, tiledCount(t));
    try t.press("C-x 1");
    try testing.expectEqual(1, tiledCount(t));
    const bells = t.ed.bells;
    try t.press("C-x 0"); // the last window cannot close
    try testing.expectEqual(bells + 1, t.ed.bells);
}

test "editor: switch to, make and kill buffers" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.typeText("scratch text");

    try t.press("C-x b");
    try t.typeText("notes");
    try t.press("RET"); // a new name makes a new buffer
    try testing.expectEqualStrings("notes", t.ed.cur().name);
    try t.typeText("note text");

    try t.press("C-x b");
    try testing.expectEqualStrings("Switch to buffer (default *scratch*): ", t.ed.reader.?.mb.prompt);
    try t.press("RET"); // the default: the previous buffer
    try testing.expectEqualStrings("*scratch*", t.ed.cur().name);
    try t.expectText("scratch text");

    try t.press("C-x b");
    try t.typeText("no");
    try t.press("TAB"); // buffer name completion
    try expectMinibuffer(t, "notes");
    try t.press("RET");

    try t.press("C-x k RET"); // kills "notes", the default
    try testing.expectEqual(null, t.ed.findBuffer("notes"));
    try testing.expectEqualStrings("*scratch*", t.ed.cur().name);

    // Killing the last buffer makes a new *scratch* buffer.
    try t.press("C-x k RET");
    try testing.expectEqualStrings("*scratch*", t.ed.cur().name);
    try t.expectText("");
}

test "editor: a modified file buffer asks before C-x k" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.ed.curBuf().setFilePath("/nowhere/a.txt");
    try t.typeText("x");
    try t.press("C-x k RET");
    try testing.expectEqualStrings("Buffer *scratch* modified; kill anyway? (yes or no) ", t.ed.reader.?.mb.prompt);
    try t.typeText("yes");
    try t.press("RET");
    try t.expectText(""); // a new *scratch* buffer
}

test "editor: files open in their own buffers, with unique names" {
    const t = try TestEditor.create();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/x.txt", .data = "from a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/x.txt", .data = "from b" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var p1: [std.fs.max_path_bytes]u8 = undefined;
    var p2: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&p1, "{s}/a/x.txt", .{dir});
    const b = try std.fmt.bufPrint(&p2, "{s}/b/x.txt", .{dir});

    try t.ed.findFile(a);
    try testing.expectEqualStrings("x.txt", t.ed.cur().name);
    try t.ed.findFile(b);
    try testing.expectEqualStrings("x.txt<2>", t.ed.cur().name);
    try t.expectText("from b");
    try t.ed.findFile(a); // the same buffer again
    try testing.expectEqualStrings("x.txt", t.ed.cur().name);
    try testing.expectEqual(3, t.ed.buffers.items.len); // *scratch* and two files
}

test "lua: buffers, highlights, faces and handles" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    try t.lua(
        \\local b = editor.buffer.create{ name = "*notes*", read_only = true }
        \\b:set_text("Build passed\n3 warnings")
        \\editor.face("warning", { fg = "yellow", bold = true })
        \\b:highlight(13, 23, "warning")
        \\assert(b:name() == "*notes*")
        \\assert(b:text() == "Build passed\n3 warnings")
        \\assert(editor.buffer.get("*notes*"):name() == "*notes*")
        \\assert(editor.buffer.get("nope") == nil)
        \\assert(#editor.buffer.list() == 2)
        \\b:append("!")
    );
    const e = t.ed.findBuffer("*notes*").?;
    try testing.expect(e.buf.read_only);
    try testing.expectEqual(1, e.buf.highlights.items.len);
    try testing.expectEqual(t.ed.faces.lookup("warning").?, e.buf.highlights.items[0].face);
    try testing.expect(t.ed.faces.get(t.ed.faces.lookup("warning").?).bold);

    try t.lua(
        \\local b = editor.buffer.get("*notes*")
        \\b:kill()
        \\assert(not b:valid())
        \\_G.old = b
    );
    try testing.expect(try t.luaFails("old:name()", "no longer valid"));
    try testing.expect(try t.luaFails("editor.face('x', { fg = 'orange' })", "unknown color"));
    try testing.expect(try t.luaFails("editor.buffer.current():highlight(0, 1, 'nope')", "unknown face"));
}

test "lua: split and float windows, buffer keys and the mode line" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    try t.lua(
        \\local b = editor.buffer.create("*help*")
        \\b:set_text("press q")
        \\b:bind("q", function() editor.window.current():close() end)
        \\local w = editor.window.split{ buffer = b, side = "right", focus = true }
        \\assert(w:buffer():name() == "*help*")
        \\assert(editor.window.current():buffer():name() == "*help*")
        \\local f = editor.window.float{ buffer = b, row = 2, col = 10, width = 20, height = 5 }
        \\assert(editor.window.current():buffer():name() == "*help*")
        \\_G.float = f
    );
    try testing.expectEqual(2, tiledCount(t));
    try testing.expectEqual(1, t.ed.floats.items.len);
    const float = t.ed.floats.items[0];
    try testing.expectEqual(layout.Rect{ .row = 2, .col = 10, .rows = 5, .cols = 20 }, float.rect);
    try testing.expectEqual(float, t.ed.selected);

    try t.press("q"); // the buffer key closes the floating window
    try testing.expectEqual(0, t.ed.floats.items.len);
    try testing.expect(try t.luaFails("float:close()", "no longer valid"));

    try t.lua(
        \\editor.set_mode_line(function(info)
        \\  return info.buffer .. " L" .. info.line .. (info.selected and " *" or "")
        \\end)
    );
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("*help* L1 *", lua_api.modeLineText(&t.ed, t.ed.selected, &buf).?);
    try t.lua("editor.set_mode_line(nil)");
    try testing.expectEqual(null, lua_api.modeLineText(&t.ed, t.ed.selected, &buf));

    try t.lua("editor.run('delete_other_windows')");
    try testing.expectEqual(1, tiledCount(t));
}

test "lua: insert, sub, delete, undo groups, region and path" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    try t.lua(
        \\local b = editor.buffer.current()
        \\b:set_text("hello world")
        \\b:set_cursor(5)
        \\b:insert(",")
        \\assert(b:cursor() == 6)
        \\assert(b:sub(0, 6) == "hello,")
        \\assert(b:sub(10, 100) == "ld")    -- clamped to the text
        \\assert(b:sub(-5, 2) == "he")
        \\assert(b:sub(12, 13) == "")
        \\b:delete(0, 1)
        \\assert(b:sub(0, 5) == "ello,")
        \\assert(b:cursor() == 5)           -- moved with the text
        \\assert(b:path() == nil)
        \\b:append("\nnext line")
        \\local s, e = b:line_range(3)
        \\assert(s == 0 and e == 11, s .. " " .. e)
        \\s, e = b:line_range(14)
        \\assert(s == 12 and e == 21, s .. " " .. e)
        \\assert(b:line_range(999) == 12)   -- clamped
        \\b:delete(11, 21)
        \\assert(b:region() == nil)
        \\assert(b:nodes_at(0) == nil)      -- no syntax tree
    );
    try t.expectText("ello, world");
    try testing.expect(try t.luaFails("editor.buffer.current():delete(3, 1)", "invalid range"));

    // An undo group is one undo step, also with an error inside it.
    try t.lua(
        \\local b = editor.buffer.current()
        \\b:set_cursor(0)
        \\b:undo_group(function()
        \\  b:insert("(")
        \\  b:set_cursor(b:cursor() + 4)
        \\  b:insert(")")
        \\end)
    );
    try t.expectText("(ello), world");
    try t.press("C-/");
    try t.expectText("ello, world");
    try testing.expect(try t.luaFails(
        \\local b = editor.buffer.current()
        \\b:undo_group(function() b:insert("x") error("stop") end)
    , "stop"));
    try t.typeText("y"); // the group ended, so typing is a new step
    try t.press("C-/");
    try t.expectText("xello, world");

    // The active region.
    t.ed.curBuf().moveTo(1);
    try t.press("C-SPC");
    t.ed.curBuf().moveTo(5);
    try t.lua(
        \\local s, e = editor.buffer.current():region()
        \\assert(s == 1 and e == 5, tostring(s) .. " " .. tostring(e))
    );
}

test "editor: TAB indents to the next level of indent_width" {
    const t = try TestEditor.create();
    defer t.destroy();
    try t.press("TAB"); // default: 4 spaces
    try t.expectText("    ");
    try t.typeText("ab");
    try t.press("TAB"); // from column 6 to column 8
    try t.expectText("    ab  ");
    try t.press("C-u 2 TAB");
    try t.expectText("    ab          ");
    const bells = t.ed.bells;
    try t.press("C-u 0 TAB"); // nothing, and no error
    try t.expectText("    ab          ");
    try testing.expectEqual(bells, t.ed.bells);

    t.ed.options.indent_width = 2;
    t.ed.curBuf().moveTo(0);
    try t.press("TAB");
    try t.expectText("      ab          ");

    t.ed.cur().options.indent_tabs = true; // a buffer override
    try t.press("TAB");
    try t.expectText("  \t    ab          ");
    try t.press("C-/"); // one TAB is one undo step
    try t.expectText("      ab          ");

    // With a region, TAB indents each line of it.
    t.ed.cur().options.indent_tabs = null;
    try t.ed.curBuf().setText("x\ny\nz");
    t.ed.curBuf().moveTo(0);
    try t.press("C-SPC");
    t.ed.curBuf().moveTo(3); // in line "y"
    try t.press("TAB");
    try t.expectText("  x\n  y\nz");
    try t.press("C-u 2 TAB"); // the region stays; two levels in one edit
    try t.expectText("      x\n      y\nz");
    try t.press("C-/");
    try t.expectText("  x\n  y\nz");
}

test "lua: editor.options and buffer options" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    try t.lua(
        \\assert(editor.options.indent_width == 4)
        \\assert(editor.options.indent_tabs == false)
        \\assert(editor.options.tab_width == 8)
        \\editor.options.indent_width = 2
        \\editor.options.tab_width = 4
        \\local b = editor.buffer.current()
        \\assert(b:option("indent_width") == 2)  -- the global value
        \\b:set_option("indent_width", 3)
        \\b:set_option("indent_tabs", true)
        \\assert(b:option("indent_width") == 3)
        \\assert(b:option("indent_tabs") == true)
        \\assert(editor.options.indent_width == 2) -- the global value stays
        \\local other = editor.buffer.create("other")
        \\assert(other:option("indent_width") == 2)
        \\b:set_option("indent_width", nil)
        \\assert(b:option("indent_width") == 2)
    );
    try testing.expectEqual(2, t.ed.options.indent_width);
    try testing.expectEqual(4, t.ed.options.tab_width);
    try testing.expectEqual(true, t.ed.cur().options.indent_tabs.?);

    try testing.expect(try t.luaFails("editor.options.indent_widht = 2", "unknown option"));
    try testing.expect(try t.luaFails("print(editor.options.nope)", "unknown option"));
    try testing.expect(try t.luaFails("editor.options.indent_width = 0", "from 1 to 16"));
    try testing.expect(try t.luaFails("editor.options.indent_width = 2.5", "integer"));
    try testing.expect(try t.luaFails("editor.options.indent_tabs = 1", "true or false"));
    try testing.expect(try t.luaFails("editor.buffer.current():set_option('tab_width', 99)", "from 1 to 16"));
    try testing.expectEqual(2, t.ed.options.indent_width); // the errors changed nothing
}

test "lua: a buffer_open hook can kill or change the new buffer safely" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    // A hook that kills some buffers, and one that binds a key in all.
    try t.lua(
        \\seen = {}
        \\editor.on("buffer_open", function(buf)
        \\  table.insert(seen, buf:name() .. (buf:valid() and "" or "!"))
        \\  if buf:name():match("^tmp") or buf:name() == "f.txt" then buf:kill() end
        \\end)
        \\editor.on("buffer_open", function(buf)
        \\  buf:bind("C-c x", function() end)
        \\  table.insert(seen, "second:" .. buf:name())
        \\end)
        \\local b = editor.buffer.create{ name = "tmp1", read_only = true }
        \\assert(not b:valid())
        \\local k = editor.buffer.create{ name = "keep", read_only = true }
        \\assert(k:valid())
    );
    // The second hook did not run for the killed buffer, and the first hook
    // saw the read-only flag that create set.
    try t.lua(
        \\assert(table.concat(seen, ",") == "tmp1,keep,second:keep", table.concat(seen, ","))
    );
    try testing.expect(t.ed.findBuffer("keep").?.buf.read_only);

    // findFile: the hook kills the file buffer. The window shows another
    // buffer, and nothing uses the freed entry.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "x" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "f.txt" });
    defer testing.allocator.free(path);
    try t.ed.findFile(path);
    try testing.expectEqual(null, t.ed.findBuffer("f.txt"));
    try testing.expect(!std.mem.eql(u8, "f.txt", t.ed.cur().name));
    t.ed.render();

    // Killing the last buffers: the replacement *scratch* gets no hooks, so
    // a hook that kills new buffers cannot make the kill recursive.
    try t.lua(
        \\editor.on("buffer_open", function(buf) buf:kill() end)
        \\for _, b in ipairs(editor.buffer.list()) do b:kill() end
        \\assert(#editor.buffer.list() == 1)
        \\assert(editor.buffer.list()[1]:name() == "*scratch*")
    );
}

test "lua: buffer_open hooks and errors in commands" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    try t.lua(
        \\opened = {}
        \\editor.on("buffer_open", function(buf)
        \\  table.insert(opened, buf:name())
        \\  buf:bind("(", function() buf:insert("()") buf:set_cursor(buf:cursor() - 1) end)
        \\end)
    );
    try testing.expect(try t.luaFails("editor.on('nope', print)", "unknown event"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "ab" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "f.txt" });
    defer testing.allocator.free(path);
    try t.ed.findFile(path);
    try t.lua(
        \\assert(#opened == 1 and opened[1] == "f.txt", table.concat(opened, ","))
        \\assert(editor.buffer.current():path():sub(-5) == "f.txt")
        \\editor.buffer.create("other")
        \\assert(#opened == 2 and opened[2] == "other")
    );

    // The buffer key from the hook works in the file buffer.
    try t.typeText("(x");
    try t.expectText("(x)ab");

    // In the minibuffer, the buffer key does not apply.
    try t.press("C-x C-f");
    try t.typeText("(");
    const mb = &t.ed.reader.?.mb.buffer;
    const prompt = try mb.copyRange(testing.allocator, 0, mb.len());
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.endsWith(u8, prompt, "(")); // no ")" after it
    try t.press("C-g");

    // An error in a Lua command shows in the echo area.
    try t.lua("editor.bind('C-c e', function() error('broken plugin') end)");
    try t.press("C-c e");
    try testing.expect(std.mem.indexOf(u8, t.message(), "broken plugin") != null);
}

test "editor: openFiles opens a buffer for each file, the first one shown" {
    const t = try TestEditor.create();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = name });
    }
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    var paths: [3][]const u8 = undefined;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }, 0..) |name, i| {
        paths[i] = try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ dir, name });
    }

    try t.ed.openFiles(&paths);
    try testing.expectEqual(4, t.ed.buffers.items.len); // *scratch* and three files
    try testing.expectEqualStrings("a.txt", t.ed.cur().name);
    try t.expectText("a.txt");
    // The buffer list has the files in the same order as the arguments.
    try testing.expectEqualStrings("b.txt", t.ed.buffers.items[1].name);
    try testing.expectEqualStrings("c.txt", t.ed.buffers.items[2].name);
    try t.press("C-x b RET");
    try testing.expectEqualStrings("b.txt", t.ed.cur().name);

    try t.ed.openFiles(&.{}); // no files: no change
    try testing.expectEqualStrings("b.txt", t.ed.cur().name);
}

test "lua: buffer.open, window.display, buffer info and equal handles" {
    const t = try TestEditor.createWithLua();
    defer t.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try t.lua("opened = 0; editor.on('buffer_open', function() opened = opened + 1 end)");
    // "link" is a symbolic link to the directory itself.
    try tmp.dir.symLink(testing.io, ".", "link", .{ .is_directory = true });

    var code_buf: [std.fs.max_path_bytes + 2048]u8 = undefined;
    const code = try std.fmt.bufPrintSentinel(&code_buf,
        \\local dir = "{s}"
        \\local a = editor.buffer.open(dir .. "/a.txt")
        \\assert(a:name() == "a.txt" and a:sub(0, 5) == "hello")
        \\assert(a:path() == dir .. "/a.txt")
        \\assert(a:len() == 5 and not a:modified() and not a:read_only())
        \\assert(editor.buffer.current():name() == "*scratch*") -- not shown
        \\assert(opened == 1)
        \\-- The same file again gives the same buffer, without the hooks.
        \\assert(editor.buffer.open(dir .. "/a.txt") == a)
        \\assert(opened == 1)
        \\-- A file that does not exist gives an empty buffer.
        \\local n = editor.buffer.open(dir .. "/new.txt")
        \\assert(n:len() == 0 and n:path() == dir .. "/new.txt")
        \\assert(opened == 2)
        \\a:insert("x")
        \\assert(a:modified())
        \\local ro = editor.buffer.create{{ name = "ro", read_only = true }}
        \\assert(ro:read_only())
        \\
        \\-- Handles: equal for the same buffer or window, not across types.
        \\assert(editor.buffer.get("a.txt") == a and a ~= n)
        \\assert(editor.window.current() == editor.window.current())
        \\assert(editor.window.current() ~= a)
        \\
        \\-- display: a split below, the selection stays; then the same window.
        \\local here = editor.window.current()
        \\local w = editor.window.display(a)
        \\assert(w ~= here and editor.window.current() == here)
        \\assert(w:buffer() == a)
        \\assert(editor.window.display(a) == w) -- shown already
        \\local w2 = editor.window.display(n) -- the other window again
        \\assert(w2 == w and w:buffer() == n)
        \\-- A path with ".." finds the same buffer.
        \\assert(editor.buffer.open(dir .. "/sub/../a.txt") == a)
        \\-- So does a path through a symbolic link, also for a new file.
        \\assert(editor.buffer.open(dir .. "/link/a.txt") == a)
        \\assert(editor.buffer.open(dir .. "/link/new.txt") == n)
        \\-- display does not use a floating window that was selected before.
        \\local f = editor.window.float{{ buffer = n, row = 1, col = 1, width = 10, height = 3 }}
        \\here:focus()
        \\local w3 = editor.window.display(ro)
        \\assert(w3 ~= f and w3:buffer() == ro)
    , .{dir}, 0);
    try t.lua(code);
    try testing.expectEqual(2, tiledCount(t));
    // A directory cannot be read as a file.
    const bad = try std.fmt.bufPrintSentinel(&code_buf, "editor.buffer.open(\"{s}\")", .{dir}, 0);
    try testing.expect(try t.luaFails(bad, "editor.buffer.open"));
}
