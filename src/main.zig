const std = @import("std");
const Io = std.Io;
const c = @import("c");
const keys = @import("keys.zig");
const keymap = @import("keymap.zig");
const Buffer = @import("buffer.zig").Buffer;

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
    newline,
    tab_to_tab_stop,
    delete_backward_char,
    delete_char,
    kill_line,
    undo,
    quit,
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
    .{ "RET", .newline },
    .{ "TAB", .tab_to_tab_stop },
    .{ "DEL", .delete_backward_char },
    .{ "<delete>", .delete_char },
    .{ "C-d", .delete_char },
    .{ "C-k", .kill_line },
    .{ "C-/", .undo },
    .{ "C-x u", .undo },
    .{ "C-x C-c", .quit },
};

const tab_width = 8;

fn bindDefaults(km: *Keymap, gpa: std.mem.Allocator) !void {
    for (default_bindings) |b| try km.bindKeys(gpa, b[0], .{ .builtin = b[1] });
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

    fn init(gpa: std.mem.Allocator, L: *c.lua_State, km: *const Keymap) Editor {
        return .{
            .max_y = c.getmaxy(c.stdscr),
            .max_x = c.getmaxx(c.stdscr),
            .buffer = .init(gpa),
            .dispatcher = .init(km),
            .L = L,
        };
    }

    fn deinit(self: *Editor) void {
        self.buffer.deinit();
    }

    /// Returns false when the editor must stop.
    fn handleKey(self: *Editor, event: keys.KeyEvent) bool {
        const in_sequence = self.dispatcher.isPending();
        switch (self.dispatcher.feed(event)) {
            .run => |cmd| self.run(cmd),
            .prefix, .ignored => {},
            .cancel => _ = c.beep(),
            // An unbound printable key inserts itself, but not after a prefix.
            .unbound => |chord| if (!in_sequence and chord.isPrintable()) {
                self.buffer.insertCodepoint(typedCodepoint(event)) catch {
                    _ = c.beep();
                };
            } else {
                _ = c.beep();
            },
        }
        return self.running;
    }

    /// The text that a printable key event types. The chord is normalized
    /// to lowercase, so use the event.
    fn typedCodepoint(event: keys.KeyEvent) u21 {
        const cp = event.key.codepoint;
        if (event.mods.shift) return event.shifted orelse cp;
        return cp;
    }

    fn run(self: *Editor, cmd: Command) void {
        switch (cmd) {
            .builtin => |b| self.runBuiltin(b),
            .lua => |ref| {
                _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, ref);
                if (c.lua_pcallk(self.L, 0, 0, 0, 0, null) != c.LUA_OK) {
                    c.lua_settop(self.L, -2); // pop the error message
                }
            },
        }
    }

    fn runBuiltin(self: *Editor, b: Builtin) void {
        const buf = &self.buffer;
        const result: anyerror!void = switch (b) {
            .previous_line => buf.previousLine(),
            .next_line => buf.nextLine(),
            .backward_char => buf.backwardChar(),
            .forward_char => buf.forwardChar(),
            .move_beginning_of_line => buf.lineStartPos(),
            .move_end_of_line => buf.lineEndPos(),
            .newline => buf.insert("\n"),
            .tab_to_tab_stop => buf.insert("\t"),
            .delete_backward_char => buf.deleteBackward(),
            .delete_char => buf.deleteForward(),
            .kill_line => buf.killLine(),
            .undo => buf.undo(),
            .quit => self.running = false,
        };
        result catch {
            _ = c.beep();
        };
    }

    fn resize(self: *Editor) void {
        self.max_y = c.getmaxy(c.stdscr);
        self.max_x = c.getmaxx(c.stdscr);
    }

    /// Scrolls vertically and horizontally so that the cursor is on the screen.
    fn scroll(self: *Editor) void {
        const rows: usize = @intCast(@max(1, self.max_y));
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
    fn render(self: *Editor) void {
        self.scroll();
        _ = c.erase();

        const rows: usize = @intCast(@max(1, self.max_y));
        const cols: usize = @intCast(@max(1, self.max_x));
        const cursor = self.buffer.cursor;

        var line: usize = 0;
        var col: usize = 0;
        var pos: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;

        // A codepoint can cross a chunk boundary, so collect its bytes here.
        var cp_buf: [4]u8 = undefined;
        var cp_len: usize = 0;
        var cp_need: usize = 0;

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
                const visible = line >= self.top;
                const row: c_int = @intCast(line -| self.top);
                if (bytes[0] == '\t') {
                    const next = (col / tab_width + 1) * tab_width;
                    col = next; // erase() already cleared these cells
                    continue;
                }
                if (visible and col >= self.left and col < self.left + cols) {
                    const text: []const u8 = if (bytes[0] < 0x20 or bytes[0] == 0x7f or
                        !std.unicode.utf8ValidateSlice(bytes)) "?" else bytes;
                    _ = c.mvaddnstr(row, @intCast(col - self.left), text.ptr, @intCast(text.len));
                }
                col += 1;
            }
        }
        if (pos == cursor) {
            cursor_row = line -| self.top;
            cursor_col = col;
        }

        const screen_col = @min(cursor_col -| self.left, cols - 1);
        _ = c.move(@intCast(cursor_row), @intCast(screen_col));
        _ = c.refresh();
    }
};

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
};

/// Makes the global `editor` table for Lua.
fn registerLuaApi(L: *c.lua_State, ctx: *LuaContext) void {
    c.lua_createtable(L, 0, 1);
    c.lua_pushlightuserdata(L, ctx);
    c.lua_pushcclosure(L, luaBind, 1);
    c.lua_setfield(L, -2, "bind");
    c.lua_setglobal(L, "editor");
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
    try bindDefaults(&km, gpa);

    // Load the config before ncurses takes control of the terminal.
    const L = c.luaL_newstate() orelse return error.LuaInit;
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    var lua_ctx: LuaContext = .{ .gpa = gpa, .keymap = &km };
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

    var editor: Editor = .init(gpa, L, &km);
    defer editor.deinit();
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
}
