const std = @import("std");
const Io = std.Io;
const c = @import("c");
const keys = @import("keys.zig");

const kitty_on = "\x1b[>1u";
const kitty_off = "\x1b[<u";

const Editor = struct {
    max_y: c_int,
    max_x: c_int,
    y: c_int = 0,
    x: c_int = 0,

    fn init() Editor {
        return .{ .max_y = c.getmaxy(c.stdscr), .max_x = c.getmaxx(c.stdscr) };
    }

    fn handleKey(self: *Editor, event: keys.KeyEvent) bool {
        if (event.kind == .release) return true;
        switch (event.key) {
            .up => {
                if (self.y > 0) self.y -= 1;
            },
            .down => {
                if (self.y < self.max_y - 1) self.y += 1;
            },
            .left => {
                if (self.x > 0) {
                    self.x -= 1;
                } else if (self.y > 0) {
                    self.y -= 1;
                    self.x = self.max_x - 1;
                }
            },
            .right => {
                if (self.x < self.max_x - 1) {
                    self.x += 1;
                } else if (self.y < self.max_y - 1) {
                    self.y += 1;
                    self.x = 0;
                }
            },
            .codepoint => |cp| {
                if (cp == 'c' and event.mods.ctrl) return false;
            },
            else => {},
        }
        return true;
    }

    fn resize(self: *Editor) void {
        self.max_y = c.getmaxy(c.stdscr);
        self.max_x = c.getmaxx(c.stdscr);
        self.y = @max(0, @min(self.max_y - 1, self.y));
        self.x = @max(0, @min(self.max_x - 1, self.x));
    }

    fn render(self: *const Editor) void {
        _ = c.move(self.y, self.x);
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

    // Load the config before ncurses takes control of the terminal.
    const L = c.luaL_newstate() orelse return error.LuaInit;
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    if (try configPath(init.arena.allocator(), init.environ_map)) |path| {
        loadConfig(L, path);
    }

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

    var editor: Editor = .init();

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
}
