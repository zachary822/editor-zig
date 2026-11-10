-- grammars.lua: download, compile and register tree-sitter grammars.
--
-- Use it from init.lua:
--
--   local grammars = require("grammars")
--   grammars.setup({ "zig", "c", "lua" })
--
-- For each language, setup() installs the grammar if its parser library is
-- missing or was built from a different version, and then registers the
-- language with editor.language(). An install:
--   1. clones the grammar repository at a fixed tag (needs git),
--   2. compiles the grammar to a shared library with `tree-sitter build`
--      (needs the tree-sitter CLI). Without the CLI, it compiles
--      src/parser.c and src/scanner.c with zig, or else cc,
--   3. copies the highlight queries.
--
-- Only the first start (or a version change) downloads and compiles. The
-- output of the commands goes to ~/.cache/editor-zig/grammars.log. If an
-- install fails, the editor shows a message when it starts.
--
-- To add a language, add an entry to M.languages (see the fields below).
-- To build a grammar again, delete its file in ~/.config/editor-zig/parsers.

local M = {}

local home = os.getenv("HOME")
M.parser_dir = home .. "/.config/editor-zig/parsers"
M.query_dir = home .. "/.config/editor-zig/queries"
M.build_dir = home .. "/.cache/editor-zig/grammars"
M.log_file = home .. "/.cache/editor-zig/grammars.log"

local gh = "https://github.com/"
local js_repo = { url = gh .. "tree-sitter/tree-sitter-javascript", rev = "v0.25.0" }
local ts_repo = { url = gh .. "tree-sitter/tree-sitter-typescript", rev = "v0.23.2" }

-- The fields of a language:
--   repo        the git repository and the tag to download
--   location    the directory in the repository that holds src/ (default: the root)
--   extensions  the file extensions that use the language
--   filenames   exact file names that use the language
--   queries     the highlight query files, in order. Later patterns win.
--               Each entry is a path in `repo`, or { other_repo, path }.
--               The default is { "queries/highlights.scm" }.
M.languages = {
  zig = {
    repo = { url = gh .. "tree-sitter-grammars/tree-sitter-zig", rev = "v1.1.2" },
    extensions = { "zig", "zon" },
  },
  c = {
    repo = { url = gh .. "tree-sitter/tree-sitter-c", rev = "v0.24.2" },
    extensions = { "c", "h" },
  },
  lua = {
    repo = { url = gh .. "tree-sitter-grammars/tree-sitter-lua", rev = "v0.5.0" },
    extensions = { "lua" },
  },
  html = {
    repo = { url = gh .. "tree-sitter/tree-sitter-html", rev = "v0.23.2" },
    extensions = { "html", "htm" },
  },
  python = {
    repo = { url = gh .. "tree-sitter/tree-sitter-python", rev = "v0.25.0" },
    extensions = { "py", "pyi" },
  },
  javascript = {
    repo = js_repo,
    extensions = { "js", "mjs", "cjs", "jsx" },
    queries = { "queries/highlights.scm", "queries/highlights-jsx.scm" },
  },
  -- The TypeScript queries only add to the JavaScript queries, so the
  -- JavaScript queries come first.
  typescript = {
    repo = ts_repo,
    location = "typescript",
    extensions = { "ts", "mts", "cts" },
    queries = { { js_repo, "queries/highlights.scm" }, "queries/highlights.scm" },
  },
  tsx = {
    repo = ts_repo,
    location = "tsx",
    extensions = { "tsx" },
    queries = {
      { js_repo, "queries/highlights.scm" },
      { js_repo, "queries/highlights-jsx.scm" },
      "queries/highlights.scm",
    },
  },
}

-- Helpers

local function quote(s)
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function write_file(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(text)
  f:close()
  return true
end

-- Runs a shell command. Its output goes to the log file.
local log_dir_made = false
local function run(cmd)
  if not log_dir_made then
    -- The log redirection needs the directory, so make it first.
    os.execute("mkdir -p " .. quote(M.log_file:match("^(.*)/")))
    log_dir_made = true
  end
  local log = io.open(M.log_file, "a")
  if log then
    log:write("$ " .. cmd .. "\n")
    log:close()
  end
  return os.execute(cmd .. " >>" .. quote(M.log_file) .. " 2>&1") == true
end

local function have(program)
  return os.execute("command -v " .. program .. " >/dev/null 2>&1") == true
end

local function shared_lib_extension()
  local p = io.popen("uname -s")
  local os_name = p and p:read("l") or ""
  if p then p:close() end
  return os_name == "Darwin" and "dylib" or "so"
end

local lib_ext = shared_lib_extension()

function M.parser_path(name)
  return M.parser_dir .. "/" .. name .. "." .. lib_ext
end

function M.highlights_path(name)
  return M.query_dir .. "/" .. name .. "/highlights.scm"
end

-- The version stamp: the repository and tag that built the parser.
local function stamp_path(name)
  return M.parser_dir .. "/" .. name .. ".version"
end

local function stamp(lang)
  return lang.repo.url .. "@" .. lang.repo.rev .. "/" .. (lang.location or "")
end

-- Installing

-- Clones each repository once for each setup() call.
local clones = {}

local function clone(repo)
  local key = repo.url .. "@" .. repo.rev
  if clones[key] then return clones[key] end
  local dir = M.build_dir .. "/" .. repo.url:match("([^/]+)$") .. "-" .. repo.rev
  if not exists(dir .. "/.git") then
    run("rm -rf " .. quote(dir))
    -- GIT_TERMINAL_PROMPT=0: a wrong URL fails at once. Without it, GitHub
    -- asks for a login, and git waits for input before the editor starts.
    if not run("GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch " .. quote(repo.rev) .. " "
        .. quote(repo.url) .. " " .. quote(dir) .. " </dev/null") then
      return nil
    end
  end
  clones[key] = dir
  return dir
end

-- Returns a function that compiles the grammar in `grammar_dir` (with its
-- sources in `src`) to the library `out`, or nil if no tool can compile it.
-- The tree-sitter CLI cannot use zig cc, so it uses the system cc.
local function builder()
  if have("tree-sitter") then
    return function(grammar_dir, _, out)
      return run("tree-sitter build -o " .. quote(out) .. " " .. quote(grammar_dir))
    end
  end
  local cc = (have("zig") and "zig cc") or (have("cc") and "cc") or nil
  if not cc then return nil end
  return function(_, src, out)
    local sources = quote(src .. "/parser.c")
    if exists(src .. "/scanner.c") then sources = sources .. " " .. quote(src .. "/scanner.c") end
    return run(cc .. " -shared -fPIC -O2 -I " .. quote(src) .. " " .. sources .. " -o " .. quote(out))
  end
end

-- Downloads and compiles one language. Returns true, or false and a cause.
function M.install(name)
  local lang = M.languages[name]
  if not lang then return false, "unknown language" end
  if not have("git") then return false, "git is not installed" end
  local build = builder()
  if not build then return false, "no tree-sitter CLI or C compiler (zig or cc)" end

  run("mkdir -p " .. quote(M.parser_dir) .. " " .. quote(M.query_dir .. "/" .. name)
      .. " " .. quote(M.build_dir))

  local dir = clone(lang.repo)
  if not dir then return false, "download failed" end

  -- The queries first, so a parser library means a complete install.
  local parts = {}
  for _, q in ipairs(lang.queries or { "queries/highlights.scm" }) do
    local base, path = dir, q
    if type(q) == "table" then
      base = clone(q[1])
      if not base then return false, "download failed" end
      path = q[2]
    end
    local text = read_file(base .. "/" .. path)
    if not text then return false, "no query file " .. path end
    parts[#parts + 1] = ";; from " .. path .. "\n" .. text
  end
  local ok, err = write_file(M.highlights_path(name), table.concat(parts, "\n"))
  if not ok then return false, err end

  local grammar_dir = dir .. (lang.location and ("/" .. lang.location) or "")
  local src = grammar_dir .. "/src"
  local out = M.parser_path(name)
  local tmp = out .. ".tmp"
  if not build(grammar_dir, src, tmp) then
    os.remove(tmp)
    return false, "compile failed"
  end
  os.rename(tmp, out)
  write_file(stamp_path(name), stamp(lang))
  return true
end

-- True if the parser is missing or was built from a different version.
function M.needs_install(name)
  local lang = M.languages[name]
  if not exists(M.parser_path(name)) then return true end
  local old = read_file(stamp_path(name))
  -- A parser without a stamp was built by hand. Keep it.
  return old ~= nil and old ~= stamp(lang)
end

-- Installs the missing languages, then registers all of them.
function M.setup(names)
  local failed = {}
  for _, name in ipairs(names) do
    local lang = M.languages[name]
    if not lang then
      failed[#failed + 1] = name .. " (unknown)"
    else
      if M.needs_install(name) then
        io.stderr:write("editor-zig: installing tree-sitter grammar " .. name .. " ...\n")
        local ok, cause = M.install(name)
        if not ok then failed[#failed + 1] = name .. " (" .. cause .. ")" end
      end
      if exists(M.parser_path(name)) then
        editor.language(name, {
          parser = M.parser_path(name),
          highlights = exists(M.highlights_path(name)) and M.highlights_path(name) or nil,
          extensions = lang.extensions,
          filenames = lang.filenames,
        })
      end
    end
  end
  if next(clones) then
    run("rm -rf " .. quote(M.build_dir))
    clones = {}
  end
  if #failed > 0 then
    editor.message("Grammar install failed: " .. table.concat(failed, ", ")
      .. ". See ~/.cache/editor-zig/grammars.log")
  end
end

return M
