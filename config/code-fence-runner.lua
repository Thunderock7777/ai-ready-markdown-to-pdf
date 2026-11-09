-- code-fence-runner.lua : executes/renders fenced blocks, with a persistent SHA-1 cache.
--
-- ================================ USER GUIDE ================================
--  Executable languages: python, c, cpp (c++, cxx, cc), java
--                  Fenced blocks execute by default after confirmation on a cache miss.
--                  trusted=true skips confirmation for a normal first run.
--                  print() / standard output is captured and shown under the code.
--                  If the block fails, compiler errors or tracebacks are shown in the PDF.
--                  Python additionally captures figures automatically (savefig / plt.show).
--                  compile.bat sets the working directory to the first input's directory.
--  latex / tex   every block is rendered (source hidden).  If it contains
--                  \begin{document}...\end{document}, ONLY the text between them is kept,
--                  with ONE exception: command definitions in the preamble (before
--                  \begin{document}) are rescued and placed in front of the kept text, so the
--                  block can use them and they reach the final LaTeX file.  Recognised:
--                  \newcommand, \renewcommand, \providecommand (also the * forms), with any
--                  [n] / [default] arguments and a brace-balanced body; \newcommand is made
--                  robust.  Also rescued: \DeclareRobustCommand, \NewDocumentCommand,
--                  \DeclareDocumentCommand, \DeclareMathOperator, \DeclarePairedDelimiter,
--                  \newtheorem (except environments already defined by the template),
--                  \newenvironment, \newunicodechar, font-family commands (\newfontfamily,
--                  \newfontface, \renewfontfamily, etc.), low-level primitives (\def, \gdef,
--                  \edef, \let), \usetikzlibrary, \usepgfplotslibrary, \usepgflibrary, \tikzset,
--                  \pgfplotsset, \sisetup, and \theoremstyle.
--                  Preamble-only commands (\DeclareMathOperator, \DeclarePairedDelimiter,
--                  \newunicodechar, \usepackage, libraries) are hoisted to the document preamble.
--                  \DeclareMathOperator and \DeclarePairedDelimiter are hoisted with \let\cmd\relax
--                  to prevent clashes with pre-existing template/kernel operators and delimiters.
--                  All macros, definitions (\def), \let, font families, and environments remain
--                  strictly local to {\begingroup...\par\endgroup}.
--                  Cross-fence protection: defining or redefining any global command, theorem
--                  (\newtheorem), or conflicting package options across fences automatically
--                  demotes that block to a code listing (run=false) with a console warning.
--                  Pasted \usepackage requests are retained only for packages not managed by
--                  the template; options for skipped packages are discarded to prevent clashes.
--                  Commented-out commands are ignored.  Other preamble content
--                  (\documentclass, for example) is discarded.
--                  A bare snippet is pasted as is, so it must not contain \usepackage etc.
--
--  Attributes (same for every executable language)
--     trusted=true        skip confirmation for a normal first run
--     run=false           do not execute; the block stays a normal code listing
--     run=true            explicitly execute this block (confirmation still applies)
--                         run=true does not bypass cache; use run=new or cache=false to force a run
--     run=new             always execute this block now, bypassing cache, then refresh its entry
--     show=false          hide the source listing         (latex: show=true shows it)
--     output=false        hide printed text
--     error=false         hide the error report in the PDF (it is still printed on the console)
--     maxlines=N          show only the first N lines of printed text
--     cache=false         always re-run this block (equivalent cache bypass to run=new)
--     figures=false       python only: save figures normally but do not embed them in the PDF
--     deps="a.csv,b.npy"  extra files whose CONTENT is part of the cache key
--     img="fig.png"       python only, legacy: a figure the code writes itself
--  Python tracks the data files a block READS automatically; other languages need deps=.
--  Cache keys include runtime/library versions. Successful Python runs also record workspace
--  file side effects so a cache hit can restore outputs consumed by later blocks. The cache
--  uses a 200-entry least-recently-used index; deleting it is always safe.
--
-- ============================ ARCHITECTURE (read me) =========================
--  1. utilities        files, hashing, cache folder
--  2. language registry   one `register{...}` entry per language
--  3. cache               runtime fingerprint, dependencies, side-effect restore, LRU pruning
--  4. runner              language-agnostic: execute, capture, collect
--  5. renderer            language-agnostic: source / output / error / figures
--  6. CodeBlock           dispatch by class name, then inject recovered LaTeX preambles
--
--  The filter runs after markdown-normalizer.lua: its document callback sees the normalized combined
--  AST, so executable blocks from every input file run once in source order. The preceding
--  filter must remain first because it rebuilds the AST from cleaned Markdown/TXT sources.
--
--  CONTRACT between runner and a language entry
--    The runner writes the user's code to   <prefix>_code.<ext>   (so line numbers in error
--    messages are the block's own) and your TEMPLATE to   <prefix>_run.<ext>, replacing:
--        @@CODE@@    quoted path of the user's code file   -> your template must run it
--        @@PREFIX@@  quoted path prefix for artifacts      -> save figures as  <prefix>_<n>.png
--        @@DEPS@@    quoted path for a list of files read  -> optional (auto_deps = true only)
--    stdout / stderr / stdin are handled by the runner at OS level (stdin is empty, so a
--    stray input()/readline() cannot hang the build).  Exit status 0 = success.
--    Figures are discovered as  <prefix>_<n>.(png|jpg|jpeg|pdf), sorted by n.
--  Fields:  id, names{}, exe_env, exe_default, ext, template, quote(path) [optional],
--           command(exe, script) [optional], auto_deps [optional], label [optional]
--  R / Julia:  same fields.  R:  template runs  source(@@CODE@@)  between png(<prefix>_%d.png)
--  and dev.off();  Julia:  include(@@CODE@@)  plus the plotting package's save call.
-- =============================================================================

-- ------------------------------ 1. utilities --------------------------------
local IS_WIN   = package.config:sub(1, 1) == "\\"
local NULL_DEV = IS_WIN and "NUL" or "/dev/null"

local function warn(m) io.stderr:write("[code-fence-runner] " .. m .. "\n") end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("a"); f:close()
  return s
end
local function write_file(p, s)
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end
local function file_exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  return false
end
local function file_hash(p) local s = read_file(p); return s and pandoc.sha1(s) or nil end
local function slash(p)     return (p:gsub("\\", "/")) end
local function to_os_path(p)
  if IS_WIN and type(p) == "string" then return (p:gsub("/", "\\")) end
  return p
end

local function quote_executable(exe)
  if exe:match('^".*"$') or exe:match("^'.*'$") then return exe end
  if IS_WIN then return '"' .. to_os_path(exe) .. '"' end
  return "'" .. exe:gsub("'", "'\\''") .. "'"
end
local function trim_end(s)  return (s:gsub("%s+$", "")) end
local function crlf_to_lf(s) return (s:gsub("\r\n", "\n")) end

local function replace_plain(s, from, to)           -- literal (non-pattern) replace-all
  local out, pos = {}, 1
  while true do
    local a, b = s:find(from, pos, true)
    if not a then break end
    out[#out + 1] = s:sub(pos, a - 1); out[#out + 1] = to; pos = b + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

local function first_lines(txt, n)
  n = tonumber(n)
  if not n or n < 1 then return txt end
  local keep, count = {}, 0
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    if count <= n then keep[#keep + 1] = line end
  end
  if count <= n then return txt end
  keep[#keep + 1] = string.format("... (%d more lines)", count - n)
  return table.concat(keep, "\n")
end

local function last_lines(txt, n)
  local all = {}
  for line in (txt .. "\n"):gmatch("(.-)\n") do all[#all + 1] = line end
  if #all <= n then return txt end
  local keep = { string.format("... (%d earlier lines omitted)", #all - n) }
  for i = #all - n + 1, #all do keep[#keep + 1] = all[i] end
  return table.concat(keep, "\n")
end

local CACHE_DIR = os.getenv("MD2PDF_CACHE")
if not CACHE_DIR or CACHE_DIR == "" then
  CACHE_DIR = (os.getenv("TEMP") or os.getenv("TMPDIR") or ".") .. "/md2pdf_cache"
end
CACHE_DIR = slash(CACHE_DIR):gsub("/+$", "")
pandoc.system.make_directory(CACHE_DIR, true)

-- Bump only when the Lua-side cache FORMAT changes.  A language template change needs no bump:
-- the template's own hash is part of the cache key.
local CACHE_SCHEMA = "rf4"
local CACHE_LIMIT = 200
local CACHE_INDEX = CACHE_DIR .. "/.index"

local function remove_tree(p)
  local ok, entries = pcall(pandoc.system.list_directory, p)
  if ok and entries then
    for _, item in ipairs(entries) do
      remove_tree(p .. "/" .. item)
    end
  end
  os.remove(p)
end

-- every artifact of one block is named  fence_<hash>.<something>  or  fence_<hash>_<something>
local function purge(name)
  local n = #name
  local ok, entries = pcall(pandoc.system.list_directory, CACHE_DIR)
  if not ok or not entries then return end
  for _, f in ipairs(entries) do
    local tail = f:sub(n + 1, n + 1)
    if f:sub(1, n) == name and (tail == "." or tail == "_") then
      remove_tree(CACHE_DIR .. "/" .. f)
    end
  end
end

local function touch_cache(name)
  local entries, seen = {}, {}
  local old = read_file(CACHE_INDEX) or ""
  if old == "" then
    local existing = {}
    for _, file in ipairs(pandoc.system.list_directory(CACHE_DIR)) do
      local item = file:match("^(fence_[%x]+)%.out$")
      if item then existing[#existing+1] = item end
    end
    table.sort(existing)
    for _, item in ipairs(existing) do
      if item ~= name and not seen[item] then entries[#entries+1] = item; seen[item] = true end
    end
  end
  for item in old:gmatch("[^\r\n]+") do
    if item ~= name and item:match("^fence_[%x]+$") and not seen[item] then
      entries[#entries+1] = item
      seen[item] = true
    end
  end
  entries[#entries+1] = name
  if #entries > CACHE_LIMIT then
    local remove = #entries - CACHE_LIMIT
    for i = 1, remove do purge(entries[i]) end
    local kept = {}
    for i = remove + 1, #entries do kept[#kept+1] = entries[i] end
    entries = kept
  end
  write_file(CACHE_INDEX, table.concat(entries, "\n") .. "\n")
end

local IMG_EXT = { png = true, jpg = true, jpeg = true, pdf = true }
local function find_figures(name)
  local found = {}
  for _, f in ipairs(pandoc.system.list_directory(CACHE_DIR)) do
    local n, ext = f:match("^" .. name .. "_(%d+)%.(%w+)$")
    if n and IMG_EXT[ext:lower()] then
      found[#found + 1] = { n = tonumber(n), path = CACHE_DIR .. "/" .. f }
    end
  end
  table.sort(found, function(a, b) return a.n < b.n end)
  local paths = {}
  for i, x in ipairs(found) do paths[i] = x.path end
  return paths
end

-- meta file: one figure path per line; its existence marks a finished, cacheable run
local function read_meta(p)
  local s = read_file(p)
  if not s then return nil end
  local figs = {}
  for line in s:gmatch("[^\r\n]+") do
    if not file_exists(line) then return nil end   -- an image was deleted: entry invalid
    figs[#figs + 1] = line
  end
  return figs
end

-- explicit deps="a.csv,b.npy": content hash of those files (part of the cache key)
local function deps_key(list)
  if not list then return "" end
  local parts = {}
  for name in list:gmatch("[^,]+") do
    name = name:match("^%s*(.-)%s*$")
    local h = file_hash(name)
    if h then
      parts[#parts + 1] = name .. "=" .. h
    else
      parts[#parts + 1] = name .. "=missing"
      warn("deps file not found: " .. name)
    end
  end
  return table.concat(parts, "\0")
end

-- automatic deps: the file list written by the run is stored together with content hashes
local function save_auto_deps(rawdeps, depsfile)
  local lines = {}
  local s = read_file(rawdeps)
  if s then
    for line in s:gmatch("[^\r\n]+") do
      local h = file_hash(line)
      if h then lines[#lines + 1] = line .. "\t" .. h end
    end
  end
  write_file(depsfile, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
  os.remove(rawdeps)
end

local function auto_deps_ok(depsfile)               -- every recorded file still has its content
  local s = read_file(depsfile)
  if not s then return false end
  for line in s:gmatch("[^\r\n]+") do
    local p, h = line:match("^(.-)\t(.*)$")
    if p and file_hash(p) ~= h then return false end
  end
  return true
end

local function restore_side_effects(manifest)
  local s = read_file(manifest)
  if not s then return false end
  for line in s:gmatch("[^\r\n]+") do
    local target, archive, hash = line:match("^(.-)\t(.-)\t(.*)$")
    local content = archive and read_file(archive)
    if not target or not content or pandoc.sha1(content) ~= hash then return false end
    local current = read_file(target)
    if current and pandoc.sha1(current) ~= hash then return false end
    if not current then
      local parent = target:match("^(.*)[/\\][^/\\]+$")
      local ok = parent and pcall(pandoc.system.list_directory, parent)
      if not ok then
        warn("cached side-effect directory is unavailable (" .. tostring(parent) ..
             "); treating the cache entry as stale")
        return false
      end
    end
  end
  for line in s:gmatch("[^\r\n]+") do
    local target, archive = line:match("^(.-)\t(.-)\t")
    if target and not file_exists(target) then write_file(target, read_file(archive)) end
  end
  return true
end

-- --------------------------- 2. language registry ---------------------------
local LANGS = {}

local function lua_quote(p) return string.format("%q", p) end

local function register(spec)
  assert(spec.id and spec.names, "register: id and names are required")
  if not spec.render then                          -- executable language: validate the entry
    assert(spec.exe_env and spec.exe_default and spec.ext and spec.template,
           "register(" .. spec.id .. "): exe_env, exe_default, ext and template are required")
    spec.quote = spec.quote or lua_quote
    spec.label = spec.label or spec.id
    local fp_src = spec.fp_source or (type(spec.template) == "string" and spec.template or (spec.id .. "_v1"))
    spec.fp    = pandoc.sha1(fp_src)        -- template change => automatic cache miss
  end
  for _, n in ipairs(spec.names) do LANGS[n:lower()] = spec end
end

-- ---- python -----------------------------------------------------------------
local PY_TEMPLATE = [=[
import os, sys, itertools, atexit, traceback, shutil, hashlib
sys.dont_write_bytecode = True           # no __pycache__ in the notes folder
sys.path.insert(0, os.getcwd())          # the script lives in the cache; keep local imports working
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8") # captured text is read back as UTF-8
    except Exception:
        pass

_CODE   = os.path.abspath(@@CODE@@)
_PREFIX = os.path.abspath(@@PREFIX@@)
_DEPS   = os.path.abspath(@@DEPS@@)
_WRITES = os.path.abspath(@@WRITES@@)
_CAPTURE_FIGURES = @@FIGURES@@

# ---- automatic dependency tracking: files READ by the block ----
_CWD = os.path.normcase(os.path.realpath(os.getcwd()))
_CACHE_PREFIX = os.path.normcase(os.path.realpath(_PREFIX))
_skip_paths = {sys.prefix, sys.base_prefix, sys.exec_prefix, sys.base_exec_prefix}
try:
    import site
    _skip_paths.add(site.getusersitepackages())
    _skip_paths.update(site.getsitepackages())
except Exception:
    pass
_SKIP = [os.path.normcase(os.path.realpath(_p)) for _p in _skip_paths if _p]
_deps = set()
_written = set()
_DATA_EXT = (".csv", ".tsv", ".txt", ".json", ".xlsx", ".xls", ".npy", ".npz",
             ".parquet", ".feather", ".pkl", ".pickle", ".h5", ".hdf5", ".dat",
             ".xml", ".yaml", ".yml", ".mat", ".sav", ".dta", ".py", ".rds", ".rdata", ".sas7bdat", ".db", ".sqlite", ".sqlite3")

def _audit(_ev, _args):
    if _ev != "open":
        return
    try:
        _p, _mode, _flags = _args
        if not isinstance(_p, (str, bytes, os.PathLike)):
            return                                     # file descriptor, not a path
        if _mode is None:
            _w = (_flags or 0) & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC)
        else:
            _w = any(_c in _mode for _c in "wax+")
        _full = os.path.realpath(os.path.abspath(os.fsdecode(_p)))
        _n = os.path.normcase(_full)
        _key = _n.replace("\\", "/")
        if (_n == _CACHE_PREFIX or _n.startswith(_CACHE_PREFIX + "_")
            or _n.startswith(_CACHE_PREFIX + ".")):
            return                                     # this block's own cache artifacts
        if _w:
            _written.add(_key)
            return                                     # files written by this run are outputs
        if _key in _written:
            return                                     # do not track reads of our own outputs
        if "__pycache__" in _n or _n.endswith((".pyc", ".pyo")):
            return
        if any(_n.startswith(_s + os.sep) for _s in _SKIP):
            return                                     # python install / venv / site-packages
        if "matplotlib" in _n:
            return                                     # matplotlib's own config/cache
        if not _n.startswith(_CWD + os.sep) and not _n.lower().endswith(_DATA_EXT):
            return                                     # outside the notes folder: data files only
        if os.path.isfile(_full):
            _deps.add(_key)
    except Exception:
        pass

try:
    sys.addaudithook(_audit)
except AttributeError:
    pass                                               # Python < 3.8: no auto-tracking

def _write_deps():
    with open(_DEPS, "w", encoding="utf-8") as _f:
        for _p in sorted(_deps - _written):
            _f.write(_p + "\n")
    _manifest = []
    _cwd_prefix = _CWD + os.sep
    for _p in sorted(_written):
        _target = os.path.normcase(os.path.realpath(_p.replace("/", os.sep)))
        if not _target.startswith(_cwd_prefix) or not os.path.isfile(_target):
            continue
        _digest = hashlib.sha1()
        with open(_target, "rb") as _source:
            while True:
                _chunk = _source.read(1024 * 1024)
                if not _chunk:
                    break
                _digest.update(_chunk)
        _archive = _PREFIX + "_sidefx_" + str(len(_manifest) + 1)
        shutil.copyfile(_target, _archive)
        _manifest.append(_target + "\t" + _archive + "\t" + _digest.hexdigest())
    with open(_WRITES, "w", encoding="utf-8") as _f:
        _f.write("\n".join(_manifest) + ("\n" if _manifest else ""))

atexit.register(_write_deps)

# ---- figure capture (matplotlib) ----
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.figure import Figure
    _HAVE_MPL = True
except ImportError:
    _HAVE_MPL = False

if _HAVE_MPL:
    _cnt = itertools.count(1)
    _orig = Figure.savefig
    _FIG_EXT = (".png", ".jpg", ".jpeg", ".pdf")

    def _has_content(fig):
        return bool(fig.axes or fig.texts or fig.images or fig.artists or fig.patches)

    def _sv(self, fname, *a, **k):
        r = _orig(self, fname, *a, **k)                # exactly what plain Python does: the user's own file is written
        self._md2pdf_saved = True
        if _CAPTURE_FIGURES and isinstance(fname, (str, os.PathLike)) and _has_content(self):
            ext = os.path.splitext(os.fspath(fname))[1].lower()
            kk = dict(k)
            if ext not in _FIG_EXT:                    # svg / eps / ... : LaTeX cannot include them
                ext = ".png"
            kk.pop("format", None)
            try:
                _orig(self, f"{_PREFIX}_{next(_cnt)}{ext}", *a, **kk)   # extra copy for the PDF
            except Exception as _e:
                print("[code-fence-runner] could not capture figure for the PDF:", _e, file=sys.stderr)
        return r

    Figure.savefig = _sv

    def _flush():                                      # figures nobody saved: capture, then close
        for _num in list(plt.get_fignums()):
            _fig = plt.figure(_num)
            if _CAPTURE_FIGURES and not getattr(_fig, "_md2pdf_saved", False) and _has_content(_fig):
                _orig(_fig, f"{_PREFIX}_{next(_cnt)}.png", bbox_inches="tight")
            plt.close(_fig)

    atexit.register(_flush)
    plt.show = lambda *a, **k: _flush()

# ---- run the user's code exactly like a script (own file => correct line numbers) ----
def _main():
    try:
        with open(_CODE, "r", encoding="utf-8") as _source:
            _code = _source.read()
        _globals = {
            "__name__": "__main__",
            "__file__": os.path.join(os.getcwd(), "__md2pdf_block__.py"),
            "__package__": None,
        }
        exec(compile(_code, _CODE, "exec"), _globals)
    except SystemExit:
        raise
    except BaseException as _e:
        _tb = _e.__traceback__
        while _tb is not None and _tb.tb_frame.f_code.co_filename != _CODE:
            _tb = _tb.tb_next                          # hide this wrapper's own frames
        traceback.print_exception(type(_e), _e, _tb)
        sys.exit(1)

_main()
]=]

register{
  id = "python", label = "Python", names = { "python", "py", "python3", "py3" },
  exe_env = "PYTHON", exe_default = IS_WIN and "py" or "python", ext = "py",
  auto_deps = true,
  template = PY_TEMPLATE,
}

-- ---- C ----------------------------------------------------------------------
local function has_c_main(code)
  return code:find("[%s\n]main%s*%(") ~= nil or code:find("^main%s*%(") ~= nil
end

local function c_template(code, codef, prefix)
  if has_c_main(code) then
    return code
  end
  return [[#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

int main(int argc, char **argv) {
#line 1 "code"
]] .. code .. [[

    return 0;
}
]]
end

local function c_command(exe, script, out, err, prefix, text)
  local bin = prefix .. (IS_WIN and "_bin.exe" or "_bin")
  local comp = quote_executable(exe) .. ' -O2 -o ' .. quote_executable(bin) .. ' ' .. quote_executable(script) .. ' -lm'
  local run = quote_executable(bin)
  return comp .. ' < ' .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '" && ' ..
         run .. ' < ' .. NULL_DEV .. ' >> "' .. to_os_path(out) .. '" 2>> "' .. to_os_path(err) .. '"'
end

register{
  id = "c", label = "C", names = { "c" },
  exe_env = "C_COMPILER", exe_default = "gcc", ext = "c",
  template = c_template,
  fp_source = "c_template_v1",
  command = c_command,
  cleanup = function(prefix)
    local bin = prefix .. (IS_WIN and "_bin.exe" or "_bin")
    os.remove(bin)
  end,
}

-- ---- C++ --------------------------------------------------------------------
local function has_cpp_main(code)
  return code:find("[%s\n]main%s*%(") ~= nil or code:find("^main%s*%(") ~= nil
end

local function cpp_template(code, codef, prefix)
  if has_cpp_main(code) then
    return code
  end
  return [[#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>

int main(int argc, char **argv) {
#line 1 "code"
]] .. code .. [[

    return 0;
}
]]
end

local function cpp_command(exe, script, out, err, prefix, text)
  local bin = prefix .. (IS_WIN and "_bin.exe" or "_bin")
  local comp = quote_executable(exe) .. ' -O2 -std=c++17 -o ' .. quote_executable(bin) .. ' ' .. quote_executable(script)
  local run = quote_executable(bin)
  return comp .. ' < ' .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '" && ' ..
         run .. ' < ' .. NULL_DEV .. ' >> "' .. to_os_path(out) .. '" 2>> "' .. to_os_path(err) .. '"'
end

register{
  id = "cpp", label = "C++", names = { "cpp", "c++", "cxx", "cc" },
  exe_env = "CPP_COMPILER", exe_default = "g++", ext = "cpp",
  template = cpp_template,
  fp_source = "cpp_template_v1",
  command = cpp_command,
  cleanup = function(prefix)
    local bin = prefix .. (IS_WIN and "_bin.exe" or "_bin")
    os.remove(bin)
  end,
}

-- ---- Java -------------------------------------------------------------------
local function detect_java_class(code)
  local name = code:match("public%s+class%s+([%a_][%w_]*)")
            or code:match("[%s\n]class%s+([%a_][%w_]*)")
            or code:match("^class%s+([%a_][%w_]*)")
  return name
end

local function has_java_main(code)
  return code:find("public%s+static%s+void%s+main") ~= nil
end

local function java_template(code, codef, prefix)
  if has_java_main(code) then
    return code
  end
  return [[import java.util.*;
import java.io.*;
import java.math.*;

public class Main {
    public static void main(String[] args) throws Exception {
]] .. code .. [[

    }
}
]]
end

local function java_script_file(prefix, code)
  local class_name = has_java_main(code) and (detect_java_class(code) or "Main") or "Main"
  local java_dir = prefix .. "_java"
  pandoc.system.make_directory(java_dir, true)
  return java_dir .. "/" .. class_name .. ".java"
end

local function java_command(exe, script, out, err, prefix, text)
  local class_name = has_java_main(text) and (detect_java_class(text) or "Main") or "Main"
  local java_dir = prefix .. "_java"
  local javac_env = os.getenv("JAVAC_COMPILER")
  local javac = (javac_env and javac_env ~= "") and javac_env or "javac"
  local has_javac = (javac_env and javac_env ~= "") or (os.execute((IS_WIN and "where " or "which ") .. javac .. " > " .. NULL_DEV .. " 2>&1") == 0)
  if has_javac then
    local comp = quote_executable(javac) .. ' -d "' .. to_os_path(java_dir) .. '" ' .. quote_executable(script)
    local run = quote_executable(exe) .. ' -cp "' .. to_os_path(java_dir) .. '" ' .. class_name
    return comp .. ' < ' .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '" && ' ..
           run .. ' < ' .. NULL_DEV .. ' >> "' .. to_os_path(out) .. '" 2>> "' .. to_os_path(err) .. '"'
  else
    return quote_executable(exe) .. ' ' .. quote_executable(script) ..
           ' < ' .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '"'
  end
end

register{
  id = "java", label = "Java", names = { "java" },
  exe_env = "JAVA_RUNNER", exe_default = "java", ext = "java",
  template = java_template,
  fp_source = "java_template_v1",
  script_file = java_script_file,
  command = java_command,
  cleanup = function(prefix, code)
    local java_dir = prefix .. "_java"
    remove_tree(java_dir)
  end,
}

-- ---- latex / tex (rendered, not executed) --------------------------------------
-- Preamble command definitions that survive the preamble deletion (see USER GUIDE).
local DEF_NAMES = {
  newcommand = true, renewcommand = true, providecommand = true,
  DeclareRobustCommand = true,
}
local SKIP_PACKAGES = {}
local SKIP_PACKAGE_NAMES = [[
  inputenc fontenc fontspec geometry hyperref babel polyglossia lmodern microtype
  fancyhdr parskip graphicx xcolor amsmath amssymb amsfonts amsthm mathtools physics braket
  tikz pgf pgfplots booktabs longtable array float caption fvextra xurl soul etoolbox
  newunicodechar unicode-math bm cancel mhchem placeins multirow calc footnotehyper
  textcomp mathrsfs bookmark color siunitx circuitikz tcolorbox algorithm algpseudocode
  chemfig subcaption listings enumitem adjustbox pgfplotstable tikz-cd footnote
]]
for name in SKIP_PACKAGE_NAMES:gmatch("%S+") do SKIP_PACKAGES[name] = true end
local TEMPLATE_THEOREMS = { theorem = true, lemma = true, proposition = true, corollary = true,
  definition = true, example = true, remark = true }
local SIMPLE_PREAMBLE = {
  usetikzlibrary = true, usepgfplotslibrary = true, usepgflibrary = true,
  pgfplotsset = true, tikzset = true, sisetup = true, theoremstyle = true,
  newunicodechar = true,
}
local THREE_ARG_PREAMBLE = { NewDocumentCommand = true, DeclareDocumentCommand = true }
-- Fontspec font family/face definition commands that survive preamble deletion (kept in local_cmds).
local FONT_FAMILY_COMMANDS = {
  newfontfamily = true, renewfontfamily = true,
  setfontfamily = true, providefontfamily = true,
  newfontface = true, renewfontface = true,
  setfontface = true, providefontface = true,
}
-- Low-level TeX definition primitives that survive preamble deletion (kept in local_cmds).
local PRIMITIVE_DEFS = { def = true, gdef = true, edef = true }

local function skip_space(s, i) return (s:find("%S", i)) or (#s + 1) end

local function match_group(s, i, open, close)       -- s[i] == open -> index of its matching close
  local depth = 0
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then i = i + 1                      -- skip an escaped character such as \{ or \%
    elseif c == open then depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
  return nil
end

local function in_comment(s, pos)                   -- is s[pos] after an unescaped % on its line?
  local ls = pos
  while ls > 1 and s:sub(ls - 1, ls - 1) ~= "\n" do ls = ls - 1 end
  local line = s:sub(ls, pos - 1)
  return line:find("^%%") ~= nil or line:find("[^\\]%%") ~= nil
end

local function extract_commands(pre)
  local commands, pos = {}, 1
  while true do
    local a = pre:find("\\", pos, true)
    if not a then break end
    local name = pre:sub(a + 1):match("^([%a@]+)")
    if not name then pos = a + 1
    else
      local cursor = a + 1 + #name
      local finish, command
      if not in_comment(pre, a) and DEF_NAMES[name] then
        if pre:sub(cursor, cursor) == "*" then cursor = cursor + 1 end
        cursor = skip_space(pre, cursor)
        if pre:sub(cursor, cursor) == "{" then
          cursor = match_group(pre, cursor, "{", "}")
          cursor = cursor and cursor + 1
        elseif pre:sub(cursor, cursor) == "\\" then
          local token = pre:sub(cursor):match("^\\[%a@]+")
          cursor = token and cursor + #token or cursor + 1
        else
          cursor = nil
        end
        while cursor do
          cursor = skip_space(pre, cursor)
          if pre:sub(cursor, cursor) == "[" then
            local e = match_group(pre, cursor, "[", "]")
            cursor = e and e + 1
          elseif pre:sub(cursor, cursor) == "{" then
            finish = match_group(pre, cursor, "{", "}")
            if finish then
              command = pre:sub(a, finish)
              if name == "newcommand" then
                command = command:gsub("^\\newcommand", "\\DeclareRobustCommand", 1)
              end
              break
            end
            cursor = nil
          else
            cursor = nil
          end
        end
      elseif not in_comment(pre, a) and FONT_FAMILY_COMMANDS[name] then
        if pre:sub(cursor, cursor) == "*" then cursor = cursor + 1 end
        cursor = skip_space(pre, cursor)
        if pre:sub(cursor, cursor) == "{" then
          cursor = match_group(pre, cursor, "{", "}")
          cursor = cursor and cursor + 1
        elseif pre:sub(cursor, cursor) == "\\" then
          local token = pre:sub(cursor):match("^\\[%a@]+")
          cursor = token and cursor + #token or cursor + 1
        else
          cursor = nil
        end
        if cursor then
          cursor = skip_space(pre, cursor)
          while pre:sub(cursor, cursor) == "[" do
            local opt_e = match_group(pre, cursor, "[", "]")
            if not opt_e then cursor = nil; break end
            cursor = skip_space(pre, opt_e + 1)
          end
        end
        if cursor and pre:sub(cursor, cursor) == "{" then
          local e = match_group(pre, cursor, "{", "}")
          if e then
            finish = e
            cursor = skip_space(pre, e + 1)
            while pre:sub(cursor, cursor) == "[" do
              local opt_e = match_group(pre, cursor, "[", "]")
              if not opt_e then break end
              finish = opt_e
              cursor = skip_space(pre, opt_e + 1)
            end
            command = pre:sub(a, finish)
          end
        end
      elseif not in_comment(pre, a) and (PRIMITIVE_DEFS[name] or name == "let") then
        if PRIMITIVE_DEFS[name] then
          cursor = skip_space(pre, cursor)
          if pre:sub(cursor, cursor) == "\\" then
            local token = pre:sub(cursor):match("^\\[%a@]+") or pre:sub(cursor, cursor + 1)
            cursor = cursor + #token
          elseif pre:sub(cursor, cursor) == "{" then
            local e = match_group(pre, cursor, "{", "}")
            cursor = e and e + 1
          else
            cursor = nil
          end
          if cursor then
            while cursor <= #pre and pre:sub(cursor, cursor) ~= "{" do
              cursor = cursor + 1
            end
            if cursor <= #pre and pre:sub(cursor, cursor) == "{" then
              finish = match_group(pre, cursor, "{", "}")
              if finish then
                command = pre:sub(a, finish)
              end
            end
          end
        elseif name == "let" then
          cursor = skip_space(pre, cursor)
          local first_token
          if pre:sub(cursor, cursor) == "\\" then
            first_token = pre:sub(cursor):match("^\\[%a@]+") or pre:sub(cursor, cursor + 1)
            cursor = cursor + #first_token
          elseif pre:sub(cursor, cursor) == "{" then
            local e = match_group(pre, cursor, "{", "}")
            if e then first_token = pre:sub(cursor, e); cursor = e + 1 end
          end
          if first_token then
            cursor = skip_space(pre, cursor)
            if pre:sub(cursor, cursor) == "=" then
              cursor = skip_space(pre, cursor + 1)
            end
            if pre:sub(cursor, cursor) == "\\" then
              local second_token = pre:sub(cursor):match("^\\[%a@]+") or pre:sub(cursor, cursor + 1)
              finish = cursor + #second_token - 1
              command = pre:sub(a, finish)
            elseif pre:sub(cursor, cursor) == "{" then
              finish = match_group(pre, cursor, "{", "}")
              if finish then command = pre:sub(a, finish) end
            elseif cursor <= #pre and pre:sub(cursor, cursor):match("%S") then
              finish = cursor
              command = pre:sub(a, finish)
            end
          end
        end
      elseif not in_comment(pre, a)
          and (name == "usepackage" or SIMPLE_PREAMBLE[name] or name == "DeclareMathOperator"
            or name == "newtheorem" or name == "DeclarePairedDelimiter" or name == "newenvironment"
            or THREE_ARG_PREAMBLE[name]) then
        local optional = ""
        if (name == "DeclareMathOperator" or name == "newtheorem")
            and pre:sub(cursor, cursor) == "*" then cursor = cursor + 1 end
        cursor = skip_space(pre, cursor)
        if name == "usepackage" and pre:sub(cursor, cursor) == "[" then
          local e = match_group(pre, cursor, "[", "]")
          if e then optional = pre:sub(cursor, e); cursor = e + 1 end
        end
        cursor = skip_space(pre, cursor)
        if pre:sub(cursor, cursor) == "{" then
          local first_end = match_group(pre, cursor, "{", "}")
          if first_end then
            if name == "DeclareMathOperator" or name == "newtheorem"
                or name == "DeclarePairedDelimiter" or name == "newenvironment" or name == "newunicodechar"
                or THREE_ARG_PREAMBLE[name] then
              local next_arg = skip_space(pre, first_end + 1)
              if (name == "newtheorem" or name == "newenvironment")
                  and pre:sub(next_arg, next_arg) == "[" then
                local optional_end = match_group(pre, next_arg, "[", "]")
                next_arg = optional_end and optional_end + 1 or next_arg
              end
              if name == "newenvironment" then
                next_arg = skip_space(pre, next_arg)
                if pre:sub(next_arg, next_arg) == "[" then
                  local optional_end = match_group(pre, next_arg, "[", "]")
                  next_arg = optional_end and optional_end + 1 or next_arg
                end
              end
              next_arg = skip_space(pre, next_arg)
              local second_end = pre:sub(next_arg, next_arg) == "{"
                  and match_group(pre, next_arg, "{", "}") or nil
              finish = second_end
              if second_end and (name == "newenvironment" or name == "DeclarePairedDelimiter"
                  or THREE_ARG_PREAMBLE[name]) then
                next_arg = skip_space(pre, second_end + 1)
                finish = pre:sub(next_arg, next_arg) == "{"
                    and match_group(pre, next_arg, "{", "}") or nil
              end
            else
              finish = first_end
            end
            if finish then
              local first = pre:sub(cursor + 1, first_end - 1)
              if name == "usepackage" then
                local keep = {}
                for package in first:gmatch("[^,%s]+") do
                  if not SKIP_PACKAGES[package] then keep[#keep+1] = package end
                end
                if #keep > 0 then command = "\\usepackage" .. optional .. "{" .. table.concat(keep, ",") .. "}" end
              elseif name ~= "newtheorem" or not TEMPLATE_THEOREMS[first] then
                command = pre:sub(a, finish)
              end
            end
          end
        end
      end
      if finish then
        if command then commands[#commands+1] = command end
        pos = finish + 1
      else
        pos = a + 1
      end
    end
  end
  return commands
end

-- Template scaffolding macros that cannot safely execute in the document body.
-- If a latex/tex code fence redefines them, it is treated as a code listing (run=false).
local SCAFFOLDING_MACROS = {
  maketitle = true,
  tableofcontents = true,
  title = true,
  author = true,
  date = true,
  ["@title"] = true,
  ["@author"] = true,
  ["@date"] = true,
}

local function has_scaffolding_redefinition(text)
  for name in pairs(SCAFFOLDING_MACROS) do
    local pat_name = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if text:match("\\re?newcommand%*?%s*{?%s*\\" .. pat_name .. "[%A]") or
       text:match("\\def%s*\\" .. pat_name .. "[%A]") or
       text:match("\\let%s*\\" .. pat_name .. "[%A]") then
      return name
    end
  end
  return nil
end

-- Identifies the unique target name for commands that have global or document-wide scope
-- (\DeclareMathOperator, \DeclarePairedDelimiter, \newunicodechar, \newtheorem)
-- to detect and prevent cross-fence naming collisions.
local function get_global_command_target(cmd)
  if cmd:match("^%s*\\DeclareMathOperator") then
    local sym = cmd:match("^%s*\\DeclareMathOperator%*?%s*(%b{})")
    if sym then sym = sym:sub(2, -2):match("^%s*(.-)%s*$")
    else sym = cmd:match("^%s*\\DeclareMathOperator%*?%s*(\\[%a@]+)") end
    if sym and not sym:match("^\\") then sym = "\\" .. sym end
    return sym
  end
  if cmd:match("^%s*\\DeclarePairedDelimiter") then
    local sym = cmd:match("^%s*\\DeclarePairedDelimiter%s*(%b{})")
    if sym then sym = sym:sub(2, -2):match("^%s*(.-)%s*$")
    else sym = cmd:match("^%s*\\DeclarePairedDelimiter%s*(\\[%a@]+)") end
    if sym and not sym:match("^\\") then sym = "\\" .. sym end
    return sym
  end
  if cmd:match("^%s*\\newunicodechar") then
    local sym = cmd:match("^%s*\\newunicodechar%s*(%b{})")
    if sym then sym = sym:sub(2, -2):match("^%s*(.-)%s*$") end
    if sym then return "\\newunicodechar{" .. sym .. "}" end
  end
  if cmd:match("^%s*\\newtheorem") then
    local sym = cmd:match("^%s*\\newtheorem%*?%s*(%b{})")
    if sym then sym = sym:sub(2, -2):match("^%s*(.-)%s*$") end
    if sym then return "\\newtheorem{" .. sym .. "}" end
  end
  return nil
end

local function render_latex(el, class, preamble, global_defs)
  local out = {}
  if el.attributes["show"] == "true" then
    out[#out + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { class }))
  end
  local body = el.text
  local bs, e = el.text:find("\\begin{document}", 1, true)
  if e then
    body = el.text:sub(e + 1)
    local inner = body:match("^(.*)\\end{document}")
    if inner then
      body = inner
    else
      warn("latex block has \\begin{document} but no \\end{document}: using everything after it")
    end
    -- Scope-isolated: packages, libraries, and preamble-only commands go to the preamble; macros stay local
    local commands = extract_commands(el.text:sub(1, bs - 1))
    local hoisted_cmds = {}
    local local_cmds = {}
    for _, cmd in ipairs(commands) do
      if cmd:match("^%s*\\usepackage") or cmd:match("^%s*\\usetikzlibrary")
          or cmd:match("^%s*\\usepgfplotslibrary") or cmd:match("^%s*\\usepgflibrary")
          or cmd:match("^%s*\\DeclareMathOperator") or cmd:match("^%s*\\newunicodechar")
          or cmd:match("^%s*\\DeclarePairedDelimiter") then
        hoisted_cmds[#hoisted_cmds + 1] = cmd
      else
        local_cmds[#local_cmds + 1] = cmd
      end
    end

    -- Disallow defining or redefining in subsequent fences commands that cause global/document-level conflicts
    -- (DeclareMathOperator, DeclarePairedDelimiter, newunicodechar, newtheorem, and conflicting usepackage options)
    local block_targets = {}
    local all_cmds_to_check = {}
    for _, cmd in ipairs(hoisted_cmds) do all_cmds_to_check[#all_cmds_to_check + 1] = cmd end
    for _, cmd in ipairs(local_cmds) do
      if cmd:match("^%s*\\newtheorem") then all_cmds_to_check[#all_cmds_to_check + 1] = cmd end
    end

    for _, cmd in ipairs(all_cmds_to_check) do
      if cmd:match("^%s*\\usepackage") then
        local opt = cmd:match("^%s*\\usepackage%s*(%b[])") or ""
        local pkgs = cmd:match("^%s*\\usepackage%s*%b[]%s*(%b{})") or cmd:match("^%s*\\usepackage%s*(%b{})")
        if pkgs then
          for pkg in pkgs:sub(2, -2):gmatch("[^,%s]+") do
            local target = "\\usepackage{" .. pkg .. "}"
            if global_defs and global_defs[target] and global_defs[target] ~= opt then
              warn(string.format("latex block imports package '%s' with conflicting options; rendering as code listing (run=false)", pkg))
              return nil
            end
            if global_defs then global_defs[target] = opt end
          end
        end
      else
        local target = get_global_command_target(cmd)
        if target then
          if (global_defs and global_defs[target]) or block_targets[target] then
            warn(string.format("latex block redefines global command '%s'; rendering as code listing (run=false)", target))
            return nil
          end
          block_targets[target] = true
        end
      end
    end

    for _, cmd in ipairs(all_cmds_to_check) do
      local target = get_global_command_target(cmd)
      if target and global_defs then
        global_defs[target] = cmd
      end
    end

    for _, cmd in ipairs(hoisted_cmds) do
      -- Make operator and delimiter declarations safe against pre-existing package or template definitions
      if cmd:match("^%s*\\DeclareMathOperator") or cmd:match("^%s*\\DeclarePairedDelimiter") then
        local target = get_global_command_target(cmd)
        if target and target:match("^\\[%a@]+") then
          cmd = "\\let" .. target .. "\\relax " .. cmd
        end
      end
      preamble[#preamble + 1] = cmd
    end

    if #local_cmds > 0 then
      body = table.concat(local_cmds, "\n") .. "\n" .. body
    end
  elseif el.text:find("\\usepackage") or el.text:find("\\documentclass") then
    warn("latex block has a preamble but no \\begin{document}: it is pasted as is and will " ..
         "fail; wrap the body in \\begin{document}...\\end{document}")
  end
  -- Universal Code Fence Isolation: wrap every block in a local scope
  -- so colors, styles, font sizes, lengths, and local macros never leak to outer document.
  local isolated_body = "{\\begingroup\n" .. body .. "\n\\par\\endgroup}"
  out[#out + 1] = pandoc.RawBlock("latex", isolated_body)
  return out
end

register{ id = "latex", names = { "latex", "tex" }, render = render_latex }

-- ------------------------------- 3. runner ----------------------------------
local ERR_LINES = 30            -- how many trailing lines of an error report go into the PDF
local OUTPUT_LABEL = "OUTPUT:"    -- heading shown above printed output (set to "" for no heading)

local function fill(template, vars)
  return (template:gsub("@@(%u+)@@", function(k)
    return assert(vars[k], "unknown template token @@" .. k .. "@@")
  end))
end

local function executable(spec)
  local e = os.getenv(spec.exe_env)
  if not e or e == "" then e = spec.exe_default end
  return e
end

local COMPILER_FINGERPRINTS = {}
local function runtime_fingerprint(spec, exe)
  local cache_key = spec.id .. ":" .. exe
  if COMPILER_FINGERPRINTS[cache_key] then return COMPILER_FINGERPRINTS[cache_key] end
  if spec.id == "python" then
    local command = exe:match('^"(.*)"$') or exe
    local code = "import importlib.metadata as m,sys; print(sys.version); " ..
        "print('\\n'.join(sorted((d.metadata.get('Name') or '')+'=='+d.version for d in m.distributions())))"
    local ok, result = pcall(pandoc.pipe, command, { "-c", code }, "")
    if not ok then
      warn("could not inspect Python package versions; caching is disabled for this execution")
      return nil
    end
    COMPILER_FINGERPRINTS[cache_key] = result
    return result
  elseif spec.id == "c" or spec.id == "cpp" then
    local command = exe:match('^"(.*)"$') or exe
    local ok, result = pcall(pandoc.pipe, command, { "--version" }, "")
    if ok and result and result ~= "" then
      local first_line = result:match("^[^\r\n]+") or result
      COMPILER_FINGERPRINTS[cache_key] = first_line
      return first_line
    end
    return "default"
  elseif spec.id == "java" then
    local command = exe:match('^"(.*)"$') or exe
    local ok, result = pcall(pandoc.pipe, command, { "-version" }, "")
    if ok and result and result ~= "" then
      local first_line = result:match("^[^\r\n]+") or result
      COMPILER_FINGERPRINTS[cache_key] = first_line
      return first_line
    end
    return "default"
  end
  return ""
end

local function command_line(spec, exe, script, out, err, prefix, text)
  if spec.command then
    local custom_cmd = spec.command(exe, script, out, err, prefix, text)
    if custom_cmd then
      if IS_WIN and custom_cmd:find('^"') then custom_cmd = '"' .. custom_cmd .. '"' end
      return custom_cmd
    end
  end
  local launch = quote_executable(exe) .. ' "' .. to_os_path(script) .. '"'
  local cmd = launch .. " < " .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '"'
  if IS_WIN and launch:find('^"') then cmd = '"' .. cmd .. '"' end   -- cmd.exe /c quote rule
  return cmd
end

local function execute(cmd)                         -- -> success, exit code   (Lua 5.1 .. 5.4)
  local a, _, c = os.execute(cmd)
  if a == true then return true, 0 end
  if type(a) == "number" then return a == 0, a end
  return false, c
end

local function echo_stderr(err)
  if err ~= "" then
    io.stderr:write(err)
    if not err:find("\n$") then io.stderr:write("\n") end
  end
end

-- one fresh execution; returns { ok, out, err, figs }
local function run_fresh(el, spec, exe, name)
  local prefix = CACHE_DIR .. "/" .. name
  local codef = prefix .. "_code." .. spec.ext
  local scriptf = spec.script_file and spec.script_file(prefix, el.text) or (prefix .. "_run." .. spec.ext)
  local outf, errf, rawdeps = prefix .. ".out", prefix .. ".err", prefix .. ".rawdeps"
  local rawwrites = prefix .. ".rawwrites"

  purge(name)
  write_file(codef, el.text)
  local script_content
  if type(spec.template) == "function" then
    script_content = spec.template(el.text, codef, prefix)
  else
    script_content = fill(spec.template, {
      CODE = spec.quote(codef), PREFIX = spec.quote(prefix), DEPS = spec.quote(rawdeps),
      WRITES = spec.quote(rawwrites),
      FIGURES = el.attributes["figures"] == "false" and "False" or "True" })
  end
  write_file(scriptf, script_content)

  local ok, code = execute(command_line(spec, exe, scriptf, outf, errf, prefix, el.text))
  os.remove(scriptf); os.remove(codef)
  if spec.cleanup then spec.cleanup(prefix, el.text) end

  local out = crlf_to_lf(read_file(outf) or "")
  local err = crlf_to_lf(read_file(errf) or "")
  os.remove(errf)
  echo_stderr(err)

  if not ok then
    local msg = spec.label .. " exited with an error (exit code " .. tostring(code) .. ")"
    if code == 127 or code == 9009 or err:find("not recognized") then            -- sh / cmd.exe use these for "command not found"
      msg = msg .. string.format(" -- if '%s' itself is missing, install it or set the %s environment variable",
                                 exe, spec.exe_env)
    end
    warn(msg)
    for _, v in ipairs({ slash(codef), (codef:gsub("/", "\\")), slash(scriptf), (scriptf:gsub("/", "\\")) }) do   -- show a readable name in the PDF
      err = replace_plain(err, v, "<code block>")
    end
    if trim_end(err) == "" then err = msg end
    purge(name)                                    -- never cache a failed run
    return { ok = false, out = out, err = err, figs = {} }
  end

  local figs = find_figures(name)
  if spec.auto_deps then save_auto_deps(rawdeps, prefix .. ".deps")
  else write_file(prefix .. ".deps", "") end
  local writes = read_file(rawwrites)
  if writes then write_file(prefix .. ".writes", writes) else write_file(prefix .. ".writes", "") end
  os.remove(rawwrites)
  write_file(prefix .. ".out", out)
  write_file(prefix .. ".meta", table.concat(figs, "\n") .. (#figs > 0 and "\n" or ""))
  return { ok = true, out = out, err = err, figs = figs }
end

local function run_exec(el, spec)
  local a = el.attributes
  local exe = executable(spec)
  local fingerprint = runtime_fingerprint(spec, exe)
  local working_dir = os.getenv("MD2PDF_WORKING_DIR") or ""
  if IS_WIN then working_dir = slash(working_dir):lower() end
  -- Relative paths and side-effect outputs are scoped to the first input's directory.
  local hash = pandoc.sha1(table.concat({
    CACHE_SCHEMA, spec.id, exe, spec.fp, el.text, a["img"] or "",
    a["figures"] or "", fingerprint or "", deps_key(a["deps"]), working_dir }, "\0"))
  local name = "fence_" .. hash
  local prefix = CACHE_DIR .. "/" .. name
  touch_cache(name)

  local force_run = a["run"] == "new" or a["cache"] == "false"
  -- Reuse valid results before prompting; forced fresh runs always require consent.
  if fingerprint ~= nil and not force_run and file_exists(prefix .. ".out") and auto_deps_ok(prefix .. ".deps")
      and restore_side_effects(prefix .. ".writes") then
    local figs = read_meta(prefix .. ".meta")
    if figs then
      warn("cache hit (" .. hash:sub(1, 8) .. ") -- skipped execution")
      return { ok = true, out = read_file(prefix .. ".out") or "", err = "", figs = figs }
    end
  end
  local confirm_env = os.getenv("MD2PDF_CONFIRM_EXEC") or os.getenv("MD2PDF_CONFIRM_" .. spec.id:upper()) or "1"
  if confirm_env ~= "0" and (force_run or a["trusted"] ~= "true") then
    local lang_label = spec.label or spec.id
    io.write(string.format("\n%s code needs to run", lang_label))
    if force_run then io.write(" (fresh run requested)") end
    io.write(":\n")
    io.write(el.text, "\n")
    io.write("Do you trust this code and want to run it? [y/N] ")
    io.flush()
    local answer = io.read("*l")
    if not answer or not answer:match("^[Yy]$") then
      warn(string.format("%s execution declined; rendering the block as source.", lang_label))
      return nil
    end
  end
  return run_fresh(el, spec, exe, name)
end

-- ------------------------------- 4. renderer --------------------------------
local function render(el, spec, res)
  local a, blocks = el.attributes, {}

  if a["show"] ~= "false" then
    blocks[#blocks + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { spec.id }))
  end

  if a["output"] ~= "false" then
    local txt = first_lines(trim_end(res.out), a["maxlines"])
    if txt ~= "" then
      if OUTPUT_LABEL ~= "" then
        blocks[#blocks + 1] = pandoc.Para({ pandoc.Strong({ pandoc.Str(OUTPUT_LABEL) }) })
      end
      blocks[#blocks + 1] = pandoc.CodeBlock(txt, pandoc.Attr("", { "output" }))
    end
  end

  if not res.ok and a["error"] ~= "false" then
    blocks[#blocks + 1] = pandoc.Para({ pandoc.Strong({ pandoc.Str(spec.label .. " error - this block did not finish:") }) })
    blocks[#blocks + 1] = pandoc.CodeBlock(last_lines(trim_end(res.err), ERR_LINES), pandoc.Attr("", { "error" }))
  end

  local figs = a["figures"] == "false" and {} or res.figs
  if #figs == 0 and a["figures"] ~= "false" and a["img"] and file_exists(a["img"]) then figs = { a["img"] } end
  for _, p in ipairs(figs) do
    if file_exists(p) then
      blocks[#blocks + 1] = pandoc.Para({ pandoc.Image({}, p) })
    else
      warn("expected image not found: " .. p)
    end
  end
  return blocks
end

-- ------------------------------ 5. dispatch ---------------------------------
local function process_code_block(el, preamble, global_defs)
  if el.attributes["run"] == "false" then return nil end
  local class = (el.classes[1] or ""):lower()
  local spec = LANGS[class]
  if not spec then return nil end
  if spec.id == "latex" then
    local scaffold = has_scaffolding_redefinition(el.text)
    if scaffold then
      warn(string.format("latex block redefines template scaffolding macro '\\%s'; rendering as code listing (run=false)", scaffold))
      return nil
    end
  end
  if spec.render then return spec.render(el, class, preamble, global_defs) end
  local result = run_exec(el, spec)
  if not result then return pandoc.CodeBlock(el.text, pandoc.Attr("", { spec.id })) end
  return render(el, spec, result)
end

local function add_latex_preamble(doc, preamble)
  if #preamble == 0 then return end
  local includes = { pandoc.MetaBlocks({
    pandoc.RawBlock("latex", table.concat(preamble, "\n"))
  }) }
  local old = doc.meta["header-includes"]
  if old then
    if old.t == "MetaList" then
      for _, item in ipairs(old) do includes[#includes+1] = item end
    else
      includes[#includes+1] = old
    end
  end
  doc.meta["header-includes"] = pandoc.MetaList(includes)
end

function Pandoc(doc)
  local preamble = {}
  local global_defs = {}
  doc = doc:walk({ CodeBlock = function(el) return process_code_block(el, preamble, global_defs) end })
  add_latex_preamble(doc, preamble)
  return doc
end

return { { Pandoc = Pandoc } }