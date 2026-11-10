-- buffer_list: a list of the buffers, as Emacs `list-buffers`.
--
--   require("buffer_list").setup()            -- binds C-x C-b
--   require("buffer_list").setup({ key = "C-c b" })
--
-- C-x C-b shows the list in another window. The selection does not move.
-- Columns: "." for the buffer that was current, "*" for a file buffer with
-- unsaved changes, "%" for a read-only buffer, then the name, the size in
-- bytes and the file.
--
-- Keys in the list:
--   RET   show the buffer of the cursor line in this window
--   o     show it in another window, and select that window
--   C-o   show it in another window; the cursor stays in the list
--   n p   the next and the previous line
--   g     make the list again
--   q     close the window

local M = {}

M.name = "*Buffer List*"

-- The buffer of each line of the list. Line 1 is the header, so
-- `line_buffers[1]` is on line 2.
local line_buffers = {}

-- The line number of the cursor, from 1.
local function cursor_line(buf)
  local _, newlines = buf:sub(0, buf:cursor()):gsub("\n", "")
  return newlines + 1
end

-- The position of the start of line `n` (from 1), or the end of the text.
local function line_start(buf, n)
  local text = buf:sub(0, buf:len())
  local pos = 0
  for _ = 2, n do
    local nl = text:find("\n", pos + 1, true)
    if not nl then return #text end
    pos = nl
  end
  return pos
end

-- Writes the list into `list`. `current` gets the "." mark.
local function fill(list, current)
  local lines = { string.format(" MR %-24s %8s  File", "Buffer", "Size") }
  line_buffers = {}
  for _, b in ipairs(editor.buffer.list()) do
    if b ~= list then
      local mark = (b == current) and "." or " "
      local modified = (b:path() and b:modified()) and "*" or " "
      local ro = b:read_only() and "%" or " "
      lines[#lines + 1] = string.format("%s%s%s %-24s %8d  %s",
        mark, modified, ro, b:name(), b:len(), b:path() or "")
      line_buffers[#line_buffers + 1] = b
    end
  end
  list:set_text(table.concat(lines, "\n") .. "\n")
  list:highlight(0, #lines[1], "keyword")
end

-- The buffer on the cursor line of the list, or nil with a message.
local function target(list)
  local b = line_buffers[cursor_line(list) - 1]
  if not b then
    editor.message("No buffer on this line")
    return nil
  end
  if not b:valid() then
    editor.message("This buffer was killed; press g")
    return nil
  end
  return b
end

-- The first buffer in the buffer list that is not `except`.
local function other_buffer(except)
  for _, b in ipairs(editor.buffer.list()) do
    if b ~= except then return b end
  end
  return nil
end

local function bind_keys(list)
  list:bind("RET", function()
    local b = target(list)
    if b then editor.window.current():set_buffer(b) end
  end)
  list:bind("o", function()
    local b = target(list)
    if b then editor.window.display(b):focus() end
  end)
  list:bind("C-o", function()
    local b = target(list)
    if b then editor.window.display(b) end
  end)
  list:bind("g", function()
    local line = cursor_line(list)
    fill(list, other_buffer(list))
    list:set_cursor(line_start(list, line))
  end)
  list:bind("n", "next_line")
  list:bind("p", "previous_line")
  list:bind("q", "quit_window")
end

-- Shows the list in another window.
function M.show()
  local current = editor.buffer.current()
  local list = editor.buffer.get(M.name)
  if not list then
    list = editor.buffer.create({ name = M.name, read_only = true })
    -- A buffer_open hook can kill the new buffer.
    if not list:valid() then return end
    bind_keys(list)
  end
  fill(list, current)
  -- Start on the first buffer line, below the header.
  list:set_cursor(line_start(list, 2))
  editor.window.display(list)
end

function M.setup(opts)
  opts = opts or {}
  editor.bind(opts.key or "C-x C-b", M.show)
end

return M
