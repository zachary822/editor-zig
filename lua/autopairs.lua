-- autopairs: closes brackets and quotes while you type.
--
--   require("autopairs").setup()
--   require("autopairs").setup({ pairs = { ["("] = ")", ['"'] = '"' } })
--
-- Rules:
--   - An opening character inserts the pair, and the cursor goes between.
--   - If the next character is the closing character, typing it moves over it.
--   - With an active region, the pair goes around the region.
--   - Inside a string or a comment, characters do not pair.
--   - A quote after or before a letter or digit does not pair (don't, it's).
--   - A bracket before a letter or digit does not pair (typing "(" before "foo").
--   - Backspace between an empty pair deletes both characters.
--
-- Only buffers that visit a file get the keys. Set `filter` to change that:
--   setup({ filter = function(buf) return true end })

local M = {}

M.default_pairs = {
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}",
  ['"'] = '"',
  ["'"] = "'",
  ["`"] = "`",
}

-- Node types that contain these words count as strings or comments.
M.no_pair_nodes = { "string", "comment", "char" }

local function is_word_byte(s)
  -- Bytes 128 to 255 are parts of UTF-8 letters.
  return s ~= "" and s:match("^[%w_\128-\255]$") ~= nil
end

-- True if pos is inside a string or comment node (not at its edge). It
-- waits for the parse of the current text, so that a string that you typed
-- a moment ago counts.
local function in_no_pair_node(buf, pos)
  local nodes = buf:nodes_at(pos, true)
  if not nodes then return false end
  for _, node in ipairs(nodes) do
    if node.from < pos and pos < node.to then
      for _, word in ipairs(M.no_pair_nodes) do
        if node.type:find(word, 1, true) then return true end
      end
    end
  end
  return false
end

local function wrap_region(buf, open, close)
  local s, e = buf:region()
  if not s then return false end
  buf:undo_group(function()
    buf:set_cursor(e)
    buf:insert(close)
    buf:set_cursor(s)
    buf:insert(open)
    buf:set_cursor(e + #open + #close)
  end)
  return true
end

local function insert_pair(buf, open, close)
  buf:undo_group(function()
    buf:insert(open .. close)
    buf:set_cursor(buf:cursor() - #close)
  end)
end

local function on_open(buf, open, close)
  if wrap_region(buf, open, close) then return end
  local p = buf:cursor()
  local next_char = buf:sub(p, p + 1)
  if open == close then
    -- A quote: move over the closing quote, or insert one quote.
    if next_char == close then return buf:set_cursor(p + #close) end
    if is_word_byte(buf:sub(p - 1, p)) or is_word_byte(next_char) then return buf:insert(open) end
  elseif is_word_byte(next_char) then
    return buf:insert(open)
  end
  if in_no_pair_node(buf, p) then return buf:insert(open) end
  insert_pair(buf, open, close)
end

local function on_close(buf, close)
  local p = buf:cursor()
  if buf:sub(p, p + #close) == close then
    buf:set_cursor(p + #close)
  else
    buf:insert(close)
  end
end

local function on_backspace(buf, pairs_)
  local p = buf:cursor()
  local before = buf:sub(p - 1, p)
  local close = pairs_[before]
  if close and buf:sub(p, p + #close) == close then
    buf:delete(p - 1, p + #close)
  else
    editor.run("delete_backward_char")
  end
end

local function attach(buf, pairs_)
  for open, close in pairs(pairs_) do
    buf:bind(open, function() on_open(buf, open, close) end)
    if open ~= close then
      buf:bind(close, function() on_close(buf, close) end)
    end
  end
  buf:bind("DEL", function() on_backspace(buf, pairs_) end)
end

function M.setup(opts)
  opts = opts or {}
  local pairs_ = opts.pairs or M.default_pairs
  local filter = opts.filter or function(buf) return buf:path() ~= nil end
  local function maybe_attach(buf)
    if filter(buf) then attach(buf, pairs_) end
  end
  editor.on("buffer_open", maybe_attach)
  -- Buffers that exist before setup.
  for _, buf in ipairs(editor.buffer.list()) do maybe_attach(buf) end
end

return M
