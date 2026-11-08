//! The Lua API: the global `editor` table.
//!
//!     editor.bind(keys, command)            -- a global key binding
//!     editor.language(name, options)        -- a tree-sitter language
//!     editor.message(text)                  -- text in the echo area
//!     editor.run(command_name)              -- runs a builtin command
//!     editor.face(name, style)              -- defines or changes a face
//!     editor.set_mode_line(fn | nil)        -- fn(info) returns the mode line text
//!
//!     editor.buffer.create{ name = , read_only = }   -- or create(name)
//!     editor.buffer.get(name)  editor.buffer.current()  editor.buffer.list()
//!     buf:name() buf:text() buf:set_text(s) buf:append(s)
//!     buf:highlight(start, end, face) buf:clear_highlights()
//!     buf:bind(keys, command) buf:set_read_only(bool)
//!     buf:cursor() buf:set_cursor(pos) buf:kill() buf:valid()
//!
//!     editor.window.split{ buffer = , side = "below" | "right", focus = false }
//!     editor.window.float{ buffer = , row = , col = , width = , height = ,
//!                          border = true, focus = true }
//!     editor.window.current()
//!     win:close() win:buffer() win:set_buffer(buf) win:focus() win:valid()
//!     win:on_draw(fn | nil)  -- fn(canvas, width, height), after the text
//!     canvas:text(row, col, text, face)
//!
//! Positions are byte offsets from 0, and a range includes its start and not
//! its end. Buffer and window handles hold only an ID. After a buffer is
//! killed or a window is closed, a call on its handle is a Lua error.

const std = @import("std");
const c = @import("c");
const main = @import("main.zig");
const Editor = main.Editor;
const BufferEntry = main.BufferEntry;
const Window = main.Window;
const face = @import("face.zig");
const files = @import("files.zig");
const ts = @import("syntax.zig");
const layout = @import("layout.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    /// The global keymap, for `editor.bind`.
    keymap: *main.Keymap,
    languages: *ts.Languages,
    home: ?[]const u8,
    editor: *Editor,
};

const buffer_mt = "editor.buffer";
const window_mt = "editor.window";
const canvas_mt = "editor.canvas";

const Fn = struct { [:0]const u8, c.lua_CFunction };

/// Makes the global `editor` table.
pub fn register(L: *c.lua_State, ctx: *Context) void {
    defineClass(L, ctx, buffer_mt, &.{
        .{ "name", bufName },             .{ "text", bufText },
        .{ "set_text", bufSetText },      .{ "append", bufAppend },
        .{ "highlight", bufHighlight },   .{ "clear_highlights", bufClearHighlights },
        .{ "bind", bufBind },             .{ "set_read_only", bufSetReadOnly },
        .{ "cursor", bufCursor },         .{ "set_cursor", bufSetCursor },
        .{ "kill", bufKill },             .{ "valid", bufValid },
    });
    defineClass(L, ctx, window_mt, &.{
        .{ "close", winClose },           .{ "buffer", winBuffer },
        .{ "set_buffer", winSetBuffer },  .{ "focus", winFocus },
        .{ "valid", winValid },           .{ "on_draw", winOnDraw },
    });
    defineClass(L, ctx, canvas_mt, &.{.{ "text", canvasText }});

    c.lua_createtable(L, 0, 8);
    setFunctions(L, ctx, &.{
        .{ "bind", luaBind },             .{ "language", luaLanguage },
        .{ "message", luaMessage },       .{ "run", luaRun },
        .{ "face", luaFace },             .{ "set_mode_line", luaSetModeLine },
    });
    c.lua_createtable(L, 0, 4);
    setFunctions(L, ctx, &.{
        .{ "create", bufferCreate }, .{ "get", bufferGet },
        .{ "current", bufferCurrent }, .{ "list", bufferList },
    });
    c.lua_setfield(L, -2, "buffer");
    c.lua_createtable(L, 0, 3);
    setFunctions(L, ctx, &.{
        .{ "split", windowSplit }, .{ "float", windowFloat }, .{ "current", windowCurrent },
    });
    c.lua_setfield(L, -2, "window");
    c.lua_setglobal(L, "editor");
}

/// Sets each function in the table at the top of the stack. Each function
/// gets the context as its upvalue.
fn setFunctions(L: *c.lua_State, ctx: *Context, fns: []const Fn) void {
    for (fns) |f| {
        c.lua_pushlightuserdata(L, ctx);
        c.lua_pushcclosure(L, f[1], 1);
        c.lua_setfield(L, -2, f[0]);
    }
}

/// Makes a metatable whose `__index` holds the methods.
fn defineClass(L: *c.lua_State, ctx: *Context, name: [:0]const u8, methods: []const Fn) void {
    _ = c.luaL_newmetatable(L, name);
    c.lua_createtable(L, 0, @intCast(methods.len));
    setFunctions(L, ctx, methods);
    c.lua_setfield(L, -2, "__index");
    c.lua_settop(L, -2);
}

fn ctxOf(L: *c.lua_State) *Context {
    return @ptrCast(@alignCast(c.lua_touserdata(L, c.lua_upvalueindex(1))));
}

/// Raises a Lua error. It does not return: luaL_error makes a longjmp.
fn raise(L: *c.lua_State, comptime fmt: [:0]const u8, args: anytype) noreturn {
    _ = @call(.auto, c.luaL_error, .{ L, fmt.ptr } ++ args);
    unreachable;
}

fn pushHandle(L: *c.lua_State, mt: [:0]const u8, id: u32) void {
    const p: *u32 = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(u32), 0)));
    p.* = id;
    c.luaL_setmetatable(L, mt);
}

fn handleId(L: *c.lua_State, idx: c_int, mt: [:0]const u8) u32 {
    const p: *u32 = @ptrCast(@alignCast(c.luaL_checkudata(L, idx, mt)));
    return p.*;
}

fn checkBuffer(L: *c.lua_State, idx: c_int) *BufferEntry {
    return ctxOf(L).editor.bufferById(handleId(L, idx, buffer_mt)) orelse raise(L, "the buffer is no longer valid", .{});
}

fn checkWindow(L: *c.lua_State, idx: c_int) *Window {
    return ctxOf(L).editor.windowById(handleId(L, idx, window_mt)) orelse raise(L, "the window is no longer valid", .{});
}

fn checkString(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.luaL_checklstring(L, idx, &len);
    return ptr[0..len];
}

/// A Lua error with the name of a Zig error.
fn raiseErr(L: *c.lua_State, what: [:0]const u8, err: anyerror) noreturn {
    raise(L, "%s: %s", .{ what.ptr, @errorName(err).ptr });
}

/// Reads a command: a Lua function (it takes a registry reference) or the
/// name of a builtin command.
fn checkCommand(L: *c.lua_State, idx: c_int) main.Command {
    return switch (c.lua_type(L, idx)) {
        c.LUA_TFUNCTION => blk: {
            c.lua_pushvalue(L, idx);
            break :blk .{ .lua = c.luaL_ref(L, c.LUA_REGISTRYINDEX) };
        },
        c.LUA_TSTRING => blk: {
            const name = checkString(L, idx);
            const b = std.meta.stringToEnum(main.Builtin, name) orelse raise(L, "unknown command: %s", .{c.lua_tolstring(L, idx, null)});
            break :blk .{ .builtin = b };
        },
        else => {
            _ = c.luaL_typeerror(L, idx, "function or command name");
            unreachable;
        },
    };
}

// The editor table

/// Lua: `editor.message(text)`. Shows text in the echo area.
fn luaMessage(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    ctxOf(L).editor.setMessage("{s}", .{checkString(L, 1)});
    return 0;
}

/// Lua: `editor.run(name)`. Runs a builtin command, for example
/// `editor.run("split_window_below")`.
fn luaRun(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const name = checkString(L, 1);
    const b = std.meta.stringToEnum(main.Builtin, name) orelse raise(L, "unknown command: %s", .{c.lua_tolstring(L, 1, null)});
    ctxOf(L).editor.run(.{ .builtin = b }, null);
    return 0;
}

/// Lua: `editor.bind(keys, command)`. `keys` is Emacs notation, for example
/// "C-x C-s". `command` is a Lua function or a builtin command name.
fn luaBind(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ctx = ctxOf(L);
    const notation = checkString(L, 1);
    const cmd = checkCommand(L, 2);
    ctx.keymap.bindKeys(ctx.gpa, notation, cmd) catch |err| {
        if (cmd == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, cmd.lua);
        raiseErr(L, "editor.bind", err);
    };
    return 0;
}

/// Lua: `editor.face(name, { fg = , bg = , bold = , underline = , reverse = })`.
/// A color is a name ("red", "bright_blue", "default") or a number from 0
/// to 255. A missing field gets the default value.
fn luaFace(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const name = checkString(L, 1);
    c.luaL_checktype(L, 2, c.LUA_TTABLE);
    var style: face.Style = .{};
    style.fg = colorField(L, "fg");
    style.bg = colorField(L, "bg");
    style.bold = boolField(L, 2, "bold", false);
    style.underline = boolField(L, 2, "underline", false);
    style.reverse = boolField(L, 2, "reverse", false);
    _ = ctxOf(L).editor.faces.define(name, style) catch |err| raiseErr(L, "editor.face", err);
    return 0;
}

fn colorField(L: *c.lua_State, comptime field: [:0]const u8) face.Color {
    defer c.lua_settop(L, -2);
    switch (c.lua_getfield(L, 2, field)) {
        c.LUA_TNIL => return face.default_color,
        c.LUA_TNUMBER => {
            const n = c.lua_tointegerx(L, -1, null);
            if (n < -1 or n > 255) raise(L, "editor.face: %s must be from 0 to 255", .{field.ptr});
            return @intCast(n);
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len);
            return face.parseColor(ptr[0..len]) orelse raise(L, "editor.face: unknown color: %s", .{ptr});
        },
        else => raise(L, "editor.face: %s must be a color name or number", .{field.ptr}),
    }
}

fn boolField(L: *c.lua_State, idx: c_int, comptime field: [:0]const u8, default: bool) bool {
    defer c.lua_settop(L, -2);
    if (c.lua_getfield(L, idx, field) == c.LUA_TNIL) return default;
    return c.lua_toboolean(L, -1) != 0;
}

fn intField(L: *c.lua_State, idx: c_int, comptime field: [:0]const u8, default: ?usize) usize {
    defer c.lua_settop(L, -2);
    switch (c.lua_getfield(L, idx, field)) {
        c.LUA_TNIL => return default orelse raise(L, "the field %s is required", .{field.ptr}),
        c.LUA_TNUMBER => {
            const n = c.lua_tointegerx(L, -1, null);
            if (n < 0) raise(L, "%s must not be negative", .{field.ptr});
            return @intCast(n);
        },
        else => raise(L, "%s must be a number", .{field.ptr}),
    }
}

/// Lua: `editor.set_mode_line(fn)`. The function gets a table with
/// `buffer` (the name), `line`, `col`, `modified`, `read_only` and
/// `selected`, and returns the mode line text. `nil` gives the default.
fn luaSetModeLine(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    if (c.lua_type(L, 1) != c.LUA_TNIL) c.luaL_checktype(L, 1, c.LUA_TFUNCTION);
    ed.freeLuaRef(ed.mode_line_fn);
    ed.mode_line_fn = null;
    if (c.lua_type(L, 1) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(L, 1);
        ed.mode_line_fn = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    }
    return 0;
}

// editor.buffer

/// Lua: `editor.buffer.create(name)` or `editor.buffer.create{ name = ,
/// read_only = }`. If the name exists, the new buffer gets "<2>" and so on.
fn bufferCreate(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    var read_only = false;
    var name_len: usize = 0;
    const name_ptr: [*]const u8 = blk: {
        if (c.lua_type(L, 1) == c.LUA_TTABLE) {
            read_only = boolField(L, 1, "read_only", false);
            if (c.lua_getfield(L, 1, "name") != c.LUA_TSTRING) raise(L, "editor.buffer.create: the field name is required", .{});
            break :blk c.lua_tolstring(L, -1, &name_len);
        }
        break :blk c.luaL_checklstring(L, 1, &name_len);
    };
    const e = ed.createBuffer(name_ptr[0..name_len]) catch |err| raiseErr(L, "editor.buffer.create", err);
    e.buf.read_only = read_only;
    pushHandle(L, buffer_mt, e.id);
    return 1;
}

/// Lua: `editor.buffer.get(name)`. The buffer, or nil.
fn bufferGet(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = ctxOf(L).editor.findBuffer(checkString(L, 1)) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    pushHandle(L, buffer_mt, e.id);
    return 1;
}

/// Lua: `editor.buffer.current()`. The buffer of the selected window.
fn bufferCurrent(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    pushHandle(L, buffer_mt, ctxOf(L).editor.cur().id);
    return 1;
}

/// Lua: `editor.buffer.list()`. All buffers, most recent first.
fn bufferList(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    c.lua_createtable(L, @intCast(ed.buffers.items.len), 0);
    for (ed.buffers.items, 1..) |e, i| {
        pushHandle(L, buffer_mt, e.id);
        c.lua_rawseti(L, -2, @intCast(i));
    }
    return 1;
}

// Buffer methods

fn bufName(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    _ = c.lua_pushlstring(L, e.name.ptr, e.name.len);
    return 1;
}

fn bufText(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    const ed = ctxOf(L).editor;
    const text = e.buf.copyRange(ed.gpa, 0, e.buf.len()) catch |err| raiseErr(L, "buf:text", err);
    _ = c.lua_pushlstring(L, text.ptr, text.len);
    ed.gpa.free(text);
    return 1;
}

fn bufSetText(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    e.buf.setText(checkString(L, 2)) catch |err| raiseErr(L, "buf:set_text", err);
    return 0;
}

fn bufAppend(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    e.buf.appendText(checkString(L, 2)) catch |err| raiseErr(L, "buf:append", err);
    return 0;
}

/// Lua: `buf:highlight(start, end, face)`. A face for a byte range. The
/// range moves with edits.
fn bufHighlight(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    const start = c.luaL_checkinteger(L, 2);
    const end = c.luaL_checkinteger(L, 3);
    const face_name = checkString(L, 4);
    const id = ctxOf(L).editor.faces.lookup(face_name) orelse raise(L, "unknown face: %s", .{c.lua_tolstring(L, 4, null)});
    if (start < 0 or end < start) raise(L, "buf:highlight: invalid range", .{});
    e.buf.addHighlight(@intCast(start), @intCast(end), id) catch |err| raiseErr(L, "buf:highlight", err);
    return 0;
}

fn bufClearHighlights(state: ?*c.lua_State) callconv(.c) c_int {
    checkBuffer(state.?, 1).buf.clearHighlights();
    return 0;
}

/// Lua: `buf:bind(keys, command)`. A key binding that works only in this
/// buffer. It comes before the global bindings.
fn bufBind(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    const e = checkBuffer(L, 1);
    const notation = checkString(L, 2);
    const cmd = checkCommand(L, 3);
    const km = e.keymap orelse blk: {
        const km = ed.gpa.create(main.Keymap) catch |err| raiseErr(L, "buf:bind", err);
        km.* = .{};
        e.keymap = km;
        break :blk km;
    };
    km.bindKeys(ed.gpa, notation, cmd) catch |err| {
        if (cmd == .lua) c.luaL_unref(L, c.LUA_REGISTRYINDEX, cmd.lua);
        raiseErr(L, "buf:bind", err);
    };
    return 0;
}

fn bufSetReadOnly(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    checkBuffer(L, 1).buf.read_only = c.lua_toboolean(L, 2) != 0;
    return 0;
}

fn bufCursor(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    c.lua_pushinteger(L, @intCast(checkBuffer(L, 1).buf.cursor));
    return 1;
}

fn bufSetCursor(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    const pos = c.luaL_checkinteger(L, 2);
    if (pos < 0 or pos > e.buf.len()) raise(L, "buf:set_cursor: the position is outside the text", .{});
    e.buf.moveTo(@intCast(pos));
    return 0;
}

fn bufKill(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const e = checkBuffer(L, 1);
    ctxOf(L).editor.killBuffer(e) catch |err| raiseErr(L, "buf:kill", err);
    return 0;
}

fn bufValid(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const id = handleId(L, 1, buffer_mt);
    c.lua_pushboolean(L, @intFromBool(ctxOf(L).editor.bufferById(id) != null));
    return 1;
}

// editor.window

/// The `buffer` field of an options table, or the selected window's buffer.
fn bufferField(L: *c.lua_State, idx: c_int) *BufferEntry {
    defer c.lua_settop(L, -2);
    if (c.lua_getfield(L, idx, "buffer") == c.LUA_TNIL) return ctxOf(L).editor.cur();
    return checkBuffer(L, c.lua_gettop(L));
}

/// Lua: `editor.window.split{ buffer = , side = "below" | "right",
/// focus = false }`. Splits the selected window. The new window shows the
/// buffer.
fn windowSplit(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    const e = bufferField(L, 1);
    const dir: layout.Dir = blk: {
        defer c.lua_settop(L, -2);
        if (c.lua_getfield(L, 1, "side") == c.LUA_TNIL) break :blk .below;
        var len: usize = 0;
        const side = c.lua_tolstring(L, -1, &len) orelse raise(L, "side must be \"below\" or \"right\"", .{});
        break :blk std.meta.stringToEnum(layout.Dir, side[0..len]) orelse raise(L, "side must be \"below\" or \"right\"", .{});
    };
    const focus = boolField(L, 1, "focus", false);
    const win = ed.splitWindow(dir) catch |err| raiseErr(L, "editor.window.split", err);
    ed.showBuffer(win, e) catch |err| raiseErr(L, "editor.window.split", err);
    if (focus) ed.selectWindow(win);
    pushHandle(L, window_mt, win.id);
    return 1;
}

/// Lua: `editor.window.float{ buffer = , row = , col = , width = ,
/// height = , border = true, focus = true }`. A floating window above the
/// split windows. The size includes the border.
fn windowFloat(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    c.luaL_checktype(L, 1, c.LUA_TTABLE);
    const e = bufferField(L, 1);
    const f: main.Float = .{
        .row = intField(L, 1, "row", 0),
        .col = intField(L, 1, "col", 0),
        .width = intField(L, 1, "width", null),
        .height = intField(L, 1, "height", null),
        .border = boolField(L, 1, "border", true),
    };
    const win = ed.openFloat(e, f, boolField(L, 1, "focus", true)) catch |err| raiseErr(L, "editor.window.float", err);
    pushHandle(L, window_mt, win.id);
    return 1;
}

fn windowCurrent(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    pushHandle(L, window_mt, ctxOf(L).editor.selected.id);
    return 1;
}

// Window methods

fn winClose(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const win = checkWindow(L, 1);
    ctxOf(L).editor.deleteWindow(win) catch |err| raiseErr(L, "win:close", err);
    return 0;
}

fn winBuffer(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    pushHandle(L, buffer_mt, checkWindow(L, 1).entry.id);
    return 1;
}

fn winSetBuffer(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const win = checkWindow(L, 1);
    const e = checkBuffer(L, 2);
    ctxOf(L).editor.showBuffer(win, e) catch |err| raiseErr(L, "win:set_buffer", err);
    return 0;
}

fn winFocus(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    ctxOf(L).editor.selectWindow(checkWindow(L, 1));
    return 0;
}

fn winValid(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const id = handleId(L, 1, window_mt);
    c.lua_pushboolean(L, @intFromBool(ctxOf(L).editor.windowById(id) != null));
    return 1;
}

/// Lua: `win:on_draw(fn)`. After the window's text, the editor calls
/// `fn(canvas, width, height)`. `nil` removes the function.
fn winOnDraw(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    const win = checkWindow(L, 1);
    if (c.lua_type(L, 2) != c.LUA_TNIL) c.luaL_checktype(L, 2, c.LUA_TFUNCTION);
    ed.freeLuaRef(win.on_draw);
    win.on_draw = null;
    if (c.lua_type(L, 2) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(L, 2);
        win.on_draw = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    }
    return 0;
}

/// Lua: `canvas:text(row, col, text, face)`. Draws text in the window's
/// text area. The window edge cuts text that does not fit. It works only
/// during the window's `on_draw` function.
fn canvasText(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const ed = ctxOf(L).editor;
    const id = handleId(L, 1, canvas_mt);
    if (ed.drawing_window != id) raise(L, "a canvas works only in its on_draw function", .{});
    const row = c.luaL_checkinteger(L, 2);
    const col = c.luaL_checkinteger(L, 3);
    const text = checkString(L, 4);
    const face_id: face.FaceId = if (c.lua_type(L, 5) <= c.LUA_TNIL) face.Builtin.default.id() else blk: {
        const name = checkString(L, 5);
        break :blk ed.faces.lookup(name) orelse raise(L, "unknown face: %s", .{c.lua_tolstring(L, 5, null)});
    };
    const r = ed.drawing_rect;
    if (row < 0 or col < 0 or row >= r.rows) return 0;
    ed.canvas_calls += 1;
    if (!ed.screen) return 0;
    const attr = ed.faceAttr(face_id);
    var cell: usize = @intCast(col);
    var i: usize = 0;
    while (i < text.len and cell < r.cols) : (cell += 1) {
        const n = @min(std.unicode.utf8ByteSequenceLength(text[i]) catch 1, text.len - i);
        if (attr != 0) _ = c.attron(attr);
        _ = c.mvaddnstr(@intCast(r.row + @as(usize, @intCast(row))), @intCast(r.col + cell), text[i..].ptr, @intCast(n));
        if (attr != 0) _ = c.attroff(attr);
        i += n;
    }
    return 0;
}

// Calls from the editor

/// Calls a window's `on_draw` function with a canvas for its text area.
pub fn callOnDraw(ed: *Editor, win: *Window, ref: c_int, rect: layout.Rect) void {
    const L = ed.L orelse return;
    ed.drawing_window = win.id;
    ed.drawing_rect = rect;
    defer ed.drawing_window = null;
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
    pushHandle(L, canvas_mt, win.id);
    c.lua_pushinteger(L, @intCast(rect.cols));
    c.lua_pushinteger(L, @intCast(rect.rows));
    if (c.lua_pcallk(L, 3, 0, 0, 0, null) != c.LUA_OK) showError(ed, L, "on_draw");
}

/// The mode line text from the Lua function, or null for the default text.
pub fn modeLineText(ed: *Editor, win: *Window, out: []u8) ?[]const u8 {
    const ref = ed.mode_line_fn orelse return null;
    const L = ed.L orelse return null;
    const b = &win.entry.buf;
    const selected = win == ed.selected;
    const point = if (selected) b.cursor else @min(win.point, b.len());

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
    c.lua_createtable(L, 0, 6);
    _ = c.lua_pushlstring(L, win.entry.name.ptr, win.entry.name.len);
    c.lua_setfield(L, -2, "buffer");
    c.lua_pushinteger(L, @intCast(b.lineOf(point) + 1));
    c.lua_setfield(L, -2, "line");
    c.lua_pushinteger(L, @intCast(b.displayColumn(point, 8)));
    c.lua_setfield(L, -2, "col");
    c.lua_pushboolean(L, @intFromBool(b.isModified()));
    c.lua_setfield(L, -2, "modified");
    c.lua_pushboolean(L, @intFromBool(b.read_only));
    c.lua_setfield(L, -2, "read_only");
    c.lua_pushboolean(L, @intFromBool(selected));
    c.lua_setfield(L, -2, "selected");
    if (c.lua_pcallk(L, 1, 1, 0, 0, null) != c.LUA_OK) {
        showError(ed, L, "mode line");
        return null;
    }
    defer c.lua_settop(L, -2);
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
    const n = @min(len, out.len);
    @memcpy(out[0..n], ptr[0..n]);
    return out[0..n];
}

/// Shows the error message on the Lua stack in the echo area, and pops it.
fn showError(ed: *Editor, L: *c.lua_State, what: []const u8) void {
    var len: usize = 0;
    const msg = c.lua_tolstring(L, -1, &len);
    ed.setMessage("Lua error in {s}: {s}", .{ what, if (msg) |m| m[0..len] else "?" });
    c.lua_settop(L, -2);
}

// Languages

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
    const ctx = ctxOf(L);
    c.luaL_checktype(L, 2, c.LUA_TTABLE);

    // luaL_error does not return and skips Zig defers, so free first.
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    const result = registerLanguage(L, ctx, arena.allocator());
    arena.deinit();
    result catch |err| raiseErr(L, "editor.language", err);
    return 0;
}

fn registerLanguage(L: *c.lua_State, ctx: *Context, a: std.mem.Allocator) !void {
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, 1, &name_len) orelse return error.NameMustBeString;
    const parser = try stringField(L, a, "parser") orelse return error.ParserIsRequired;
    const highlights = try stringField(L, a, "highlights");
    try ctx.languages.register(.{
        .name = name_ptr[0..name_len],
        .parser = try files.expandPath(a, parser, ctx.home),
        .highlights = if (highlights) |h| try files.expandPath(a, h, ctx.home) else null,
        .symbol = try stringField(L, a, "symbol"),
        .extensions = try stringListField(L, a, "extensions"),
        .filenames = try stringListField(L, a, "filenames"),
    });
}

/// Reads `options[field]` (argument 2) as a string, or null if it is nil.
fn stringField(L: *c.lua_State, a: std.mem.Allocator, comptime field: [:0]const u8) !?[]const u8 {
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
fn stringListField(L: *c.lua_State, a: std.mem.Allocator, comptime field: [:0]const u8) ![]const []const u8 {
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
