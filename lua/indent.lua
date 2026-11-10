-- indent: indentation on RET, from the tree-sitter syntax tree.
--
--   require("indent").setup()
--
-- One indent level comes from the editor options, so RET and TAB agree:
--
--   editor.options.indent_width = 4         -- spaces in one level
--   editor.options.indent_tabs = false      -- true: one tab for each level
--   buf:set_option("indent_width", 2)       -- for one buffer only
--
-- RET does these steps, as one undo step:
--   1. If the current line starts with a closer or a branch ("}", "end",
--      "else", ... see M.dedenters), it indents that line again, so it
--      lines up with its opener.
--   2. It inserts a newline. Between a pair, for example {|}, the closing
--      bracket goes to its own line:
--          {
--              |
--          }
--   3. It indents the new line.
--
-- Where the indentation comes from:
--   - Code that parses: `buf:indent_for`, from the syntax tree. It adds one
--     level to the real indentation of the line that opens the enclosing
--     structure, so it follows the style that the file already uses.
--   - Code that does not parse yet (while you type, a block often has no
--     end yet), files without a grammar, and multi-line strings and
--     comments: text rules. A new line gets the indentation of the previous
--     line, plus one level if that line ends with an opener (M.openers). A
--     closer or branch line gets one level less than the previous line, or
--     the same level if the previous line is an opener.
--
-- M.indent_line(buf, pos) indents one line. You can bind it to a key:
--   editor.on("buffer_open", function(buf)
--     buf:bind("C-c TAB", function() require("indent").indent_line(buf, buf:cursor()) end)
--   end)
--
-- Only buffers that visit a file get RET. Set `filter` to change that:
--   setup({ filter = function(buf) return true end })

local M = {}

M.brackets = { ["("] = ")", ["["] = "]", ["{"] = "}" }

-- Lua patterns for a line that opens a block. M.openers apply to all files,
-- and M.openers_by_extension adds more for some file extensions.
M.openers = { "[%{%[%(][ \t]*$" }
local c_like = { "^[ \t]*case%f[^%w_].*:[ \t]*$", "^[ \t]*default[ \t]*:[ \t]*$" }
M.openers_by_extension = {
  py = { ":[ \t]*$" },
  pyi = { ":[ \t]*$" },
  lua = {
    "%f[%w_]then[ \t]*$", "%f[%w_]do[ \t]*$", "%f[%w_]else[ \t]*$", "%f[%w_]repeat[ \t]*$",
    "%f[%w_]function[^%(]*%b()[ \t]*$",
  },
  c = c_like, h = c_like, cpp = c_like, js = c_like, ts = c_like, jsx = c_like, tsx = c_like,
}

-- Lua patterns for a line that closes a block or starts a branch of it.
M.dedenters = {
  "^[ \t]*[%}%)%]]",
  "^[ \t]*</",
  "^[ \t]*end%f[^%w_]",
  "^[ \t]*else%f[^%w_]",
  "^[ \t]*elif%f[^%w_]",
  "^[ \t]*elseif%f[^%w_]",
  "^[ \t]*except%f[^%w_]",
  "^[ \t]*finally%f[^%w_]",
  "^[ \t]*catch%f[^%w_]",
  "^[ \t]*until%f[^%w_]",
}

-- The indent settings of a buffer: { width = , tabs = , unit = }, where
-- `unit` is the text of one level.
function M.settings(buf)
  local width = buf:option("indent_width")
  local tabs = buf:option("indent_tabs")
  return { width = width, tabs = tabs, unit = tabs and "\t" or string.rep(" ", width) }
end

local function extension(buf)
  return (buf:path() or ""):match("%.([^./]+)$")
end

local function matches_any(text, patterns)
  for _, pattern in ipairs(patterns or {}) do
    if text:find(pattern) then return true end
  end
  return false
end

local function is_opener(buf, text)
  return matches_any(text, M.openers) or matches_any(text, M.openers_by_extension[extension(buf)])
end

local function is_dedenter(text)
  return matches_any(text, M.dedenters)
end

-- The start and the text of the previous line that is not blank, or nil.
local function previous_line(buf, line_start)
  local pos = line_start
  while pos > 0 do
    local ls, le = buf:line_range(pos - 1)
    local text = buf:sub(ls, le)
    if text:find("%S") then return ls, text end
    pos = ls
  end
  return nil
end

-- The indentation of the line with the opening bracket that matches the
-- closing bracket at `pos`, or nil. It counts brackets back from `pos` and
-- does not know about strings and comments, so it stops after `limit` bytes.
local openers_of = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local function matching_open_indent(buf, pos, limit)
  local close = buf:sub(pos, pos + 1)
  local open = openers_of[close]
  if not open then return nil end
  local start = math.max(0, pos - (limit or 20000))
  local text = buf:sub(start, pos)
  local depth = 0
  for i = #text, 1, -1 do
    local ch = text:sub(i, i)
    if ch == close then
      depth = depth + 1
    elseif ch == open then
      if depth == 0 then
        local ls, le = buf:line_range(start + i - 1)
        return buf:sub(ls, le):match("^[ \t]*")
      end
      depth = depth - 1
    end
  end
  return nil
end

-- Removes one indent level from the end of `ws`.
local function dedent(ws, unit)
  if ws:sub(-#unit) == unit then return ws:sub(1, -#unit - 1) end
  if ws:sub(-1) == "\t" then return ws:sub(1, -2) end
  return ws:sub(1, math.max(0, #ws - #unit))
end

-- The indentation text that the line at `pos` must have.
local function wanted_indent(buf, pos)
  local unit = M.settings(buf).unit
  local ls, le = buf:line_range(pos)
  local line = buf:sub(ls, le)
  local own_ws = line:match("^[ \t]*")
  local blank = line:find("%S") == nil
  local tree = buf:indent_for(ls, true)
  if tree and not blank then return tree end

  local prev_start, prev_text = previous_line(buf, ls)
  if not prev_start then return tree or own_ws end
  local prev_ws = prev_text:match("^[ \t]*")
  local opener = is_opener(buf, prev_text)

  if not blank then
    -- No tree result for a line with text.
    if not is_dedenter(line) then return own_ws end
    -- A closing bracket lines up with the line of its opening bracket.
    local match = matching_open_indent(buf, ls + #own_ws)
    if match then return match end
    return opener and prev_ws or dedent(prev_ws, unit)
  end
  -- A blank line after an opener line gets one level more than it, also
  -- where the tree has no node yet for the new block ("case 1:").
  if opener then return prev_ws .. unit end
  return tree or prev_ws
end

-- Sets the indentation of the line at `pos`. The cursor keeps its place in
-- the text. A cursor in the old indentation goes to the end of the new one.
function M.indent_line(buf, pos)
  local ls, le = buf:line_range(pos)
  local ws = buf:sub(ls, le):match("^[ \t]*")
  local want = wanted_indent(buf, pos)
  local cur = buf:cursor()
  if cur >= ls + #ws then
    cur = cur - #ws + #want
  elseif cur >= ls then
    cur = ls + #want
  end
  if ws ~= want then
    buf:delete(ls, ls + #ws)
    buf:set_cursor(ls)
    buf:insert(want)
  end
  buf:set_cursor(cur)
end

local function on_return(buf)
  local p = buf:cursor()
  local line_start, line_end = buf:line_range(p)
  local before = buf:sub(line_start, p)
  local after = buf:sub(p, line_end)
  local last = before:match("(%S)[ \t]*$") -- the last character before the cursor
  local close = last and M.brackets[last]
  local spaces = #after:match("^[ \t]*")

  buf:undo_group(function()
    -- Spaces after the cursor would come before the new indentation.
    if spaces > 0 then buf:delete(p, p + spaces) end
    if is_dedenter(before) then M.indent_line(buf, buf:cursor()) end
    buf:insert("\n")
    local new_line = buf:cursor()
    if close and buf:sub(new_line, new_line + #close) == close then
      -- Between a pair: put the closing bracket on its own line.
      buf:insert("\n")
      buf:set_cursor(new_line)
      M.indent_line(buf, new_line + 1)
    end
    M.indent_line(buf, new_line)
  end)
end

function M.setup(opts)
  opts = opts or {}
  local filter = opts.filter or function(buf) return buf:path() ~= nil end
  local function maybe_attach(buf)
    if filter(buf) then buf:bind("RET", function() on_return(buf) end) end
  end
  editor.on("buffer_open", maybe_attach)
  -- Buffers that exist before setup.
  for _, buf in ipairs(editor.buffer.list()) do maybe_attach(buf) end
end

return M
