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
  local has_javac = file_exists(javac) or file_exists(javac .. ".exe")
      or (os.execute((IS_WIN and "where " or "which ") .. quote_executable(javac) .. " > " .. NULL_DEV .. " 2>&1") == 0)
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

-- ---- Mermaid (rendered diagram) --------------------------------------------
local function mermaid_template(code)
  return code
end

local function mermaid_command(exe, script, out, err, prefix, text)
  local fig = prefix .. "_1.pdf"
  return quote_executable(exe) .. ' -i ' .. quote_executable(script) .. ' -o "' .. to_os_path(fig) .. '" -b transparent' ..
         ' < ' .. NULL_DEV .. ' > "' .. to_os_path(out) .. '" 2> "' .. to_os_path(err) .. '"'
end

register{
  id = "mermaid", label = "Mermaid", names = { "mermaid", "mmd" },
  exe_env = "MERMAID_CLI", exe_default = IS_WIN and "mmdc.cmd" or "mmdc", ext = "mmd",
  template = mermaid_template,
  fp_source = "mermaid_template_v1",
  is_diagram = true,
  command = mermaid_command,
}

-- ---- latex / tex (rendered, not executed) --------------------------------------
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
    if text:match("\\re?newcommand%*?%s*{?%s*\\" .. pat_name .. "%f[%A]") or
       text:match("\\[ged]?def%s*\\" .. pat_name .. "%f[%A]") or
       text:match("\\let%s*\\" .. pat_name .. "%f[%A]") or
       text:match("\\providecommand%*?%s*{?%s*\\" .. pat_name .. "%f[%A]") or
       text:match("\\DeclareRobustCommand%*?%s*{?%s*\\" .. pat_name .. "%f[%A]") then
      return name
    end
  end
  return nil
end

-- Helper to strip LaTeX line comments (% ...)
local function strip_latex_comments(text)
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    local non_comment = line
    for i = 1, #line do
      if line:byte(i) == 37 then -- '%'
        local slashes = 0
        local j = i - 1
        while j >= 1 and line:byte(j) == 92 do
          slashes = slashes + 1
          j = j - 1
        end
        if slashes % 2 == 0 then
          non_comment = line:sub(1, i - 1)
          break
        end
      end
    end
    lines[#lines + 1] = non_comment
  end
  return table.concat(lines, "\n")
end

-- Extracts \use... and \Require... library and package import lines from text,
-- returning the list of import command lines and the remaining text.
local function extract_imports(text)
  local imports = {}
  local cleaned = text:gsub("(%s*\\[uR]%a*%s*%b[]%s*%b{})", function(m)
    local cmd = m:match("^%s*\\([%a@]+)")
    if cmd and (cmd:match("^use") or cmd:match("^Require")) then
      imports[#imports + 1] = m:match("^%s*(.-)%s*$")
      return ""
    end
    return m
  end)
  cleaned = cleaned:gsub("(%s*\\[uR]%a*%s*%b{})", function(m)
    local cmd = m:match("^%s*\\([%a@]+)")
    if cmd and (cmd:match("^use") or cmd:match("^Require")) then
      imports[#imports + 1] = m:match("^%s*(.-)%s*$")
      return ""
    end
    return m
  end)
  return imports, cleaned
end

-- Deduplicate library/package import additions into doc_state.loaded_packages
local function add_imports_to_preamble(imports, preamble, doc_state)
  for _, imp in ipairs(imports) do
    if not doc_state.loaded_packages[imp] then
      doc_state.loaded_packages[imp] = true
      preamble[#preamble + 1] = imp
    end
  end
end

-- Strip documentclass lines
local function strip_documentclass(text)
  text = text:gsub("\\documentclass%s*%b[]%s*%b{}", "")
  text = text:gsub("\\documentclass%s*%b{}", "")
  return text
end

local GREEK_UPPER = {
  [0]="\\mathbf{A}", [1]="\\mathbf{B}", [2]="\\boldsymbol{\\Gamma}", [3]="\\boldsymbol{\\Delta}", [4]="\\mathbf{E}",
  [5]="\\mathbf{Z}", [6]="\\mathbf{H}", [7]="\\boldsymbol{\\Theta}", [8]="\\mathbf{I}", [9]="\\mathbf{K}",
  [10]="\\boldsymbol{\\Lambda}", [11]="\\mathbf{M}", [12]="\\mathbf{N}", [13]="\\boldsymbol{\\Xi}", [14]="\\mathbf{O}",
  [15]="\\boldsymbol{\\Pi}", [16]="\\mathbf{P}", [17]="\\boldsymbol{\\varTheta}", [18]="\\boldsymbol{\\Sigma}", [19]="\\mathbf{T}",
  [20]="\\boldsymbol{\\Upsilon}", [21]="\\boldsymbol{\\Phi}", [22]="\\mathbf{X}", [23]="\\boldsymbol{\\Psi}", [24]="\\boldsymbol{\\Omega}"
}
local GREEK_LOWER = {
  [0]="\\alpha", [1]="\\beta", [2]="\\gamma", [3]="\\delta", [4]="\\epsilon",
  [5]="\\zeta", [6]="\\eta", [7]="\\theta", [8]="\\iota", [9]="\\kappa",
  [10]="\\lambda", [11]="\\mu", [12]="\\nu", [13]="\\xi", [14]="o",
  [15]="\\pi", [16]="\\rho", [17]="\\varsigma", [18]="\\sigma", [19]="\\tau",
  [20]="\\upsilon", [21]="\\phi", [22]="\\chi", [23]="\\psi", [24]="\\omega",
  [25]="\\partial", [26]="\\varepsilon", [27]="\\vartheta",
  [28]="\\varkappa", [29]="\\varphi", [30]="\\varrho", [31]="\\varpi"
}

local function cleanup_boldsymbol(s)
  if not s:find("\\boldsymbol", 1, true) and not s:find("\\bm", 1, true) then return s end
  s = s:gsub("\\boldsymbol%s*\\boldsymbol", "\\boldsymbol")
  s = s:gsub("\\boldsymbol%s*\\bm", "\\bm")
  s = s:gsub("\\bm%s*\\boldsymbol", "\\bm")
  s = s:gsub("\\bm%s*\\bm", "\\bm")
  s = s:gsub("\\boldsymbol%s*(\\mathbf%b{})", "%1")
  s = s:gsub("\\boldsymbol%s*(\\bm%b{})", "%1")
  s = s:gsub("\\bm%s*(\\mathbf%b{})", "%1")
  s = s:gsub("\\boldsymbol%s*(\\[%a]+)", function(cmd)
    if cmd == "\\mathbf" or cmd == "\\bm" or cmd == "\\boldsymbol" then return cmd end
    return "\\boldsymbol{" .. cmd .. "}"
  end)
  s = s:gsub("\\boldsymbol%s*([^\n\r%s{%a\\])", "\\boldsymbol{%1}")
  return s
end

local function normalize_math_unicode(s)
  if not s:find("[\240-\244]") then
    return cleanup_boldsymbol(s)
  end

  local chars = {}
  for ch in s:gmatch(utf8.charpattern) do
    local cp = utf8.codepoint(ch)
    local rep = nil

    if cp >= 0x1D400 and cp <= 0x1D419 then
      rep = "\\mathbf{" .. string.char(cp - 0x1D400 + 65) .. "}"
    elseif cp >= 0x1D41A and cp <= 0x1D433 then
      rep = "\\mathbf{" .. string.char(cp - 0x1D41A + 97) .. "}"
    elseif cp >= 0x1D434 and cp <= 0x1D44D then
      rep = string.char(cp - 0x1D434 + 65)
    elseif cp >= 0x1D44E and cp <= 0x1D467 then
      rep = string.char(cp - 0x1D44E + 97)
    elseif cp >= 0x1D468 and cp <= 0x1D481 then
      rep = "\\bm{" .. string.char(cp - 0x1D468 + 65) .. "}"
    elseif cp >= 0x1D482 and cp <= 0x1D49B then
      rep = "\\bm{" .. string.char(cp - 0x1D482 + 97) .. "}"
    elseif cp >= 0x1D49C and cp <= 0x1D4B5 then
      rep = "\\mathcal{" .. string.char(cp - 0x1D49C + 65) .. "}"
    elseif cp >= 0x1D4B6 and cp <= 0x1D4CF then
      rep = "\\mathcal{" .. string.char(cp - 0x1D4B6 + 97) .. "}"
    elseif cp >= 0x1D4D0 and cp <= 0x1D4E9 then
      rep = "\\bm{\\mathcal{" .. string.char(cp - 0x1D4D0 + 65) .. "}}"
    elseif cp >= 0x1D4EA and cp <= 0x1D503 then
      rep = "\\bm{\\mathcal{" .. string.char(cp - 0x1D4EA + 97) .. "}}"
    elseif cp >= 0x1D504 and cp <= 0x1D51D then
      rep = "\\mathfrak{" .. string.char(cp - 0x1D504 + 65) .. "}"
    elseif cp >= 0x1D51E and cp <= 0x1D537 then
      rep = "\\mathfrak{" .. string.char(cp - 0x1D51E + 97) .. "}"
    elseif cp >= 0x1D538 and cp <= 0x1D551 then
      rep = "\\mathbb{" .. string.char(cp - 0x1D538 + 65) .. "}"
    elseif cp >= 0x1D552 and cp <= 0x1D56B then
      rep = "\\mathbb{" .. string.char(cp - 0x1D552 + 97) .. "}"
    elseif cp >= 0x1D56C and cp <= 0x1D585 then
      rep = "\\bm{\\mathfrak{" .. string.char(cp - 0x1D56C + 65) .. "}}"
    elseif cp >= 0x1D586 and cp <= 0x1D59F then
      rep = "\\bm{\\mathfrak{" .. string.char(cp - 0x1D586 + 97) .. "}}"
    elseif cp >= 0x1D5A0 and cp <= 0x1D5B9 then
      rep = "\\mathsf{" .. string.char(cp - 0x1D5A0 + 65) .. "}"
    elseif cp >= 0x1D5BA and cp <= 0x1D5D3 then
      rep = "\\mathsf{" .. string.char(cp - 0x1D5BA + 97) .. "}"
    elseif cp >= 0x1D670 and cp <= 0x1D689 then
      rep = "\\mathtt{" .. string.char(cp - 0x1D670 + 65) .. "}"
    elseif cp >= 0x1D68A and cp <= 0x1D6A3 then
      rep = "\\mathtt{" .. string.char(cp - 0x1D68A + 97) .. "}"
    elseif cp >= 0x1D6A8 and cp <= 0x1D6C0 then
      rep = GREEK_UPPER[cp - 0x1D6A8]
    elseif cp >= 0x1D6C2 and cp <= 0x1D6E1 then
      local g = GREEK_LOWER[cp - 0x1D6C2]
      if g then
        rep = "\\bm{" .. g .. "}"
      end
    elseif cp >= 0x1D7CE and cp <= 0x1D7D7 then
      rep = "\\mathbf{" .. string.char(cp - 0x1D7CE + 48) .. "}"
    elseif cp >= 0x1D7D8 and cp <= 0x1D7E1 then
      rep = "\\mathbb{" .. string.char(cp - 0x1D7D8 + 48) .. "}"
    elseif cp >= 0x1D756 and cp <= 0x1D76F then
      rep = "\\mathbf{\\mathsf{" .. string.char(cp - 0x1D756 + 65) .. "}}"
    elseif cp >= 0x1D770 and cp <= 0x1D789 then
      rep = "\\mathbf{\\mathsf{" .. string.char(cp - 0x1D770 + 97) .. "}}"
    elseif cp >= 0x1D7F6 and cp <= 0x1D7FF then
      rep = "\\mathtt{" .. string.char(cp - 0x1D7F6 + 48) .. "}"
    end

    chars[#chars + 1] = rep or ch
  end

  return cleanup_boldsymbol(table.concat(chars))
end

local function render_latex_unv(el, class, preamble, doc_state)
  local out = {}
  if el.attributes["show"] == "true" then
    out[#out + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { class }))
  end

  -- Rule: Exactly ONE latex_unv block is allowed per document
  if doc_state.seen_unv_fence then
    warn("only one latex_unv block is allowed per document; subsequent block rendered as code listing (run=false)")
    return nil
  end
  doc_state.seen_unv_fence = true

  local pre_content = el.text
  local body_content = nil
  local bs, be = el.text:find("\\begin%s*{document}")
  if bs then
    pre_content = el.text:sub(1, bs - 1)
    local after_begin = el.text:sub(be + 1)
    local inner = after_begin:match("^(.*)\\end%s*{document}")
    body_content = inner or after_begin
  end

  -- Pre-document content is universal preamble: strip documentclass and hoist raw
  pre_content = strip_documentclass(pre_content)
  if pre_content:match("%S") then
    preamble[#preamble + 1] = pre_content:match("^%s*(.-)%s*$")
  end

  -- Post-document content is local body
  if body_content and body_content:match("%S") then
    local normalized = normalize_math_unicode(body_content:match("^%s*(.-)%s*$"))
    local isolated_body = "{\\begingroup\n" .. normalized .. "\n\\par\\endgroup}"
    out[#out + 1] = pandoc.RawBlock("latex", isolated_body)
  end

  return out
end

local function render_latex(el, class, preamble, doc_state)
  local out = {}
  if el.attributes["show"] == "true" then
    out[#out + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { class }))
  end

  local bs, be = el.text:find("\\begin%s*{document}")
  if bs then
    local pre_content = el.text:sub(1, bs - 1)
    local after_begin = el.text:sub(be + 1)
    local body_content = after_begin:match("^(.*)\\end%s*{document}") or after_begin

    -- Strip comments, documentclass, and extract library/package imports
    local no_comments = strip_latex_comments(pre_content)
    local no_docclass = strip_documentclass(no_comments)
    local imports, remaining = extract_imports(no_docclass)

    -- Rule: ONLY library/package imports (\use..., \Require...) are allowed before \begin{document}.
    -- If ANYTHING else remains before \begin{document}, it is a universal permeable violation!
    if remaining:match("%S") then
      warn("latex block contains commands before \\begin{document}; universal permeables require latex_unv; rendering as code listing (run=false)")
      return nil
    end

    -- Hoist extracted imports
    add_imports_to_preamble(imports, preamble, doc_state)

    -- Render local body
    if body_content:match("%S") then
      local normalized = normalize_math_unicode(body_content:match("^%s*(.-)%s*$"))
      local isolated_body = "{\\begingroup\n" .. normalized .. "\n\\par\\endgroup}"
      out[#out + 1] = pandoc.RawBlock("latex", isolated_body)
    end
    return out
  else
    -- No \begin{document}
    if el.text:find("\\documentclass") then
      warn("latex block contains \\documentclass without \\begin{document}; rendering as code listing (run=false)")
      return nil
    end

    -- Check if there are \use... or \Require... lines: extract and hoist them as the allowed exception
    local imports, remaining = extract_imports(el.text)
    add_imports_to_preamble(imports, preamble, doc_state)

    if remaining:match("%S") then
      local normalized = normalize_math_unicode(remaining:match("^%s*(.-)%s*$"))
      local isolated_body = "{\\begingroup\n" .. normalized .. "\n\\par\\endgroup}"
      out[#out + 1] = pandoc.RawBlock("latex", isolated_body)
    end
    return out
  end
end

local function render_htmlsvg(el, class, preamble, doc_state)
  local out = {}
  if el.attributes["show"] == "true" then
    out[#out + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { class }))
  end

  local bs, be = el.text:find("\\begin%s*{document}")
  local body_content = el.text
  if bs then
    local pre_content = el.text:sub(1, bs - 1)
    local after_begin = el.text:sub(be + 1)
    body_content = after_begin:match("^(.*)\\end%s*{document}") or after_begin

    local no_comments = strip_latex_comments(pre_content)
    local no_docclass = strip_documentclass(no_comments)
    local imports = extract_imports(no_docclass)
    add_imports_to_preamble(imports, preamble, doc_state)
  else
    local imports, remaining = extract_imports(el.text)
    add_imports_to_preamble(imports, preamble, doc_state)
    body_content = remaining
  end

  local normalized = normalize_math_unicode(body_content:match("^%s*(.-)%s*$"))
  local isolated_body = "\\begin{htmlsvg}\n{\\begingroup\n" .. normalized .. "\n\\par\\endgroup}\n\\end{htmlsvg}"
  out[#out + 1] = pandoc.RawBlock("latex", isolated_body)
  return out
end

-- ---- html (whiteboard_html interactive tab attachment + recursive local asset bundler) ----
local B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64encode(data)
  if not data or data == "" then return "" end
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1 = data:byte(i)
    local b2 = (i + 1 <= len) and data:byte(i + 1) or 0
    local b3 = (i + 2 <= len) and data:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64 + 1
    local c2 = math.floor(n / 4096) % 64 + 1
    local c3 = math.floor(n / 64) % 64 + 1
    local c4 = n % 64 + 1
    out[#out + 1] = B64_ALPHA:sub(c1, c1)
    out[#out + 1] = B64_ALPHA:sub(c2, c2)
    out[#out + 1] = (i + 1 <= len) and B64_ALPHA:sub(c3, c3) or "="
    out[#out + 1] = (i + 2 <= len) and B64_ALPHA:sub(c4, c4) or "="
    i = i + 3
  end
  return table.concat(out)
end

local HTML_MIME_MAP = {
  css = "text/css",
  js = "text/javascript",
  mjs = "text/javascript",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  svg = "image/svg+xml",
  ico = "image/x-icon",
  woff2 = "font/woff2",
  woff = "font/woff",
  ttf = "font/ttf",
  otf = "font/otf",
  json = "application/json",
}

local function mime_for_path(p)
  local ext = (p:match("%.([%a%d]+)$") or ""):lower()
  return HTML_MIME_MAP[ext] or "application/octet-stream"
end

local function is_remote_or_special_url(u)
  if not u or u == "" then return true end
  local low = u:lower()
  return low:match("^https?://") ~= nil
      or low:match("^//") ~= nil
      or low:match("^data:") ~= nil
      or low:match("^blob:") ~= nil
      or low:match("^mailto:") ~= nil
      or low:match("^tel:") ~= nil
      or low:match("^javascript:") ~= nil
      or low:match("^#") ~= nil
end

local function normalize_posix_path(p)
  p = slash(p or "")
  local prefix = ""
  if p:match("^//") then
    prefix = "//"
    p = p:sub(3)
  elseif p:match("^%a:/") then
    prefix = p:sub(1, 3)
    p = p:sub(4)
  elseif p:sub(1, 1) == "/" then
    prefix = "/"
    p = p:sub(2)
  end
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif prefix == "" then
        parts[#parts + 1] = ".."
      end
    elseif seg ~= "." and seg ~= "" then
      parts[#parts + 1] = seg
    end
  end
  return prefix .. table.concat(parts, "/")
end

local function dir_of_path(p)
  p = slash(p or "")
  local d = p:match("^(.*)/[^/]*$")
  return (d and d ~= "") and d or "."
end

local function base_name_of(p)
  p = slash(p or "")
  return p:match("([^/]+)$") or p
end

local function resolve_local_ref(base_dir, ref_url)
  local raw = (ref_url or ""):match("^%s*(.-)%s*$")
  local path_only, suffix = raw:match("^([^?#]+)(.*)$")
  path_only = path_only or raw
  suffix = suffix or ""
  if path_only:match("^file:///") then
    path_only = path_only:gsub("^file:///*", ""):gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end)
  end
  local norm_p = slash(path_only)
  local is_abs = norm_p:match("^%a:/") ~= nil or norm_p:sub(1, 1) == "/"
  local combined = is_abs and norm_p or ((base_dir or ".") .. "/" .. norm_p)
  return normalize_posix_path(combined), suffix
end

local function escape_latex_plain(s)
  return (s or "")
    :gsub("\\", "\\textbackslash{}")
    :gsub("([%%$#&_{}])", "\\%1")
    :gsub("~", "\\textasciitilde{}")
    :gsub("%^", "\\textasciicircum{}")
end

local function get_html_working_dir()
  local wd = os.getenv("MD2PDF_WORKING_DIR")
  if wd and wd ~= "" then return normalize_posix_path(wd) end
  if pandoc and pandoc.system and pandoc.system.get_working_directory then
    return normalize_posix_path(pandoc.system.get_working_directory())
  end
  return "."
end

local function extract_html_file_candidate(raw_text)
  local t = (raw_text or ""):match("^%s*(.-)%s*$")
  if t == "" or t:find("[\r\n<>]") then return nil end
  local unquoted = t:match('^"(.+)"$') or t:match("^'(.+)'$") or t
  if unquoted:lower():match("%.html?$") then
    return unquoted
  end
  return nil
end

local function extract_attr(attrs, name)
  if not attrs then return nil end
  local low_target = name:lower()
  for k, q, v in attrs:gmatch("([%a%d_%-:]+)%s*=%s*([\"'])(.-)%2") do
    if k:lower() == low_target then return v end
  end
  for k, v in attrs:gmatch("([%a%d_%-:]+)%s*=%s*([^%s\"'>]+)") do
    if k:lower() == low_target then return v end
  end
  return nil
end

local function strip_attr(attrs, name)
  if not attrs then return "" end
  local low_target = name:lower()
  local out = attrs:gsub("(%s*)([%a%d_%-:]+)(%s*=%s*[\"'][^\"']*[\"'])", function(sp, k, val)
    if k:lower() == low_target then return "" end
    return sp .. k .. val
  end)
  out = out:gsub("(%s*)([%a%d_%-:]+)(%s*=%s*[^%s\"'>]+)", function(sp, k, val)
    if k:lower() == low_target then return "" end
    return sp .. k .. val
  end)
  out = out:gsub("(%s+)(%a+)(%s*)", function(s1, k, s2)
    if k:lower() == low_target then return (s1 ~= "" and s2 ~= "") and " " or "" end
    return s1 .. k .. s2
  end)
  return out
end

local function record_missing_asset(stats, label)
  if not stats.missing_set[label] then
    stats.missing_set[label] = true
    stats.missing[#stats.missing + 1] = label
  end
end

local function inline_css_text(css_text, css_dir, stats, visited_css)
  visited_css = visited_css or {}

  -- Inline @import statements recursively first
  css_text = css_text:gsub("@import%s+url%(%s*([\"']?)([^\"')]+)%1%s*%)%s*;?", function(q, ref)
    if is_remote_or_special_url(ref) then return nil end
    local abs_path = resolve_local_ref(css_dir, ref)
    local key = abs_path:lower()
    if visited_css[key] then return "/* circular @import skipped: " .. ref .. " */" end
    local sub_css = read_file(to_os_path(abs_path))
    if not sub_css then
      record_missing_asset(stats, ref)
      return nil
    end
    visited_css[key] = true
    stats.inlined = stats.inlined + 1
    local res = inline_css_text(sub_css, dir_of_path(abs_path), stats, visited_css)
    visited_css[key] = nil
    return "/* inlined: " .. ref .. " */\n" .. res
  end)

  css_text = css_text:gsub("@import%s+([\"'])([^\"']+)%1%s*;?", function(q, ref)
    if is_remote_or_special_url(ref) then return nil end
    local abs_path = resolve_local_ref(css_dir, ref)
    local key = abs_path:lower()
    if visited_css[key] then return "/* circular @import skipped: " .. ref .. " */" end
    local sub_css = read_file(to_os_path(abs_path))
    if not sub_css then
      record_missing_asset(stats, ref)
      return nil
    end
    visited_css[key] = true
    stats.inlined = stats.inlined + 1
    local res = inline_css_text(sub_css, dir_of_path(abs_path), stats, visited_css)
    visited_css[key] = nil
    return "/* inlined: " .. ref .. " */\n" .. res
  end)

  -- Inline url(...) assets (fonts, background images, SVG icons)
  css_text = css_text:gsub("url%(%s*([\"']?)([^\"')]+)%1%s*%)", function(q, ref)
    if is_remote_or_special_url(ref) then return nil end
    local abs_path, suffix = resolve_local_ref(css_dir, ref)
    local bin = read_file(to_os_path(abs_path))
    if not bin then
      record_missing_asset(stats, ref)
      return nil
    end
    stats.inlined = stats.inlined + 1
    local frag = suffix:match("(#.*)$") or ""
    return string.format('url("data:%s;base64,%s%s")', mime_for_path(abs_path), b64encode(bin), frag)
  end)

  return css_text
end

local function inline_js_module(js_text, js_dir, stats, visited_js)
  visited_js = visited_js or {}

  local function resolve_module_spec(spec)
    if not spec or (not spec:match("^%./") and not spec:match("^%.%./")) then
      return nil
    end
    local abs_path = resolve_local_ref(js_dir, spec)
    local os_p = to_os_path(abs_path)
    if not file_exists(os_p) then
      if file_exists(to_os_path(abs_path .. ".js")) then
        abs_path = abs_path .. ".js"
        os_p = to_os_path(abs_path)
      elseif file_exists(to_os_path(abs_path .. ".mjs")) then
        abs_path = abs_path .. ".mjs"
        os_p = to_os_path(abs_path)
      end
    end
    local key = abs_path:lower()
    if visited_js[key] then return nil end
    local sub_js = read_file(os_p)
    if not sub_js then
      record_missing_asset(stats, spec)
      return nil
    end
    visited_js[key] = true
    stats.inlined = stats.inlined + 1
    local bundled = inline_js_module(sub_js, dir_of_path(abs_path), stats, visited_js)
    visited_js[key] = nil
    return "data:text/javascript;base64," .. b64encode(bundled)
  end

  -- 1. import/export ... from './rel.js'
  js_text = js_text:gsub("([%a_][%w_]*[^;\r\n'\"]-%s+from%s*)([\"'])([^\"']+)%2", function(prefix, q, spec)
    local rep = resolve_module_spec(spec)
    if rep then return prefix .. q .. rep .. q end
    return nil
  end)
  -- 2. Side-effect import './rel.js'
  js_text = js_text:gsub("(%f[%a]import%s*)([\"'])([^\"']+)%2", function(prefix, q, spec)
    local rep = resolve_module_spec(spec)
    if rep then return prefix .. q .. rep .. q end
    return nil
  end)
  -- 3. Literal dynamic import('./rel.js')
  js_text = js_text:gsub("(%f[%a]import%s*%(%s*)([\"'])([^\"']+)%2(%s*%))", function(prefix, q, spec, closep)
    local rep = resolve_module_spec(spec)
    if rep then return prefix .. q .. rep .. q .. closep end
    return nil
  end)

  return js_text
end

local function inline_html_nonraw_segment(seg, html_dir, stats)
  -- 1. Replace local <link rel="stylesheet" href="..."> and inline local favicon href
  seg = seg:gsub("<[Ll][Ii][Nn][Kk](%s[^>]-)/?>", function(attrs)
    local href = extract_attr(attrs, "href")
    if not href or is_remote_or_special_url(href) then return nil end
    local rel = (extract_attr(attrs, "rel") or ""):lower()
    local is_css = rel:find("stylesheet", 1, true) ~= nil or (rel == "" and href:lower():match("%.css([?#].*)?$") ~= nil)
    local abs_path = resolve_local_ref(html_dir, href)
    if is_css then
      local css = read_file(to_os_path(abs_path))
      if not css then
        record_missing_asset(stats, href)
        return nil
      end
      stats.inlined = stats.inlined + 1
      local inlined = inline_css_text(css, dir_of_path(abs_path), stats, { [abs_path:lower()] = true })
      inlined = inlined:gsub("</([Ss][Tt][Yy][Ll][Ee])", "<\\/%1")
      return "<style>\n/* inlined: " .. href .. " */\n" .. inlined .. "\n</style>"
    elseif rel:find("icon", 1, true) ~= nil then
      local bin = read_file(to_os_path(abs_path))
      if not bin then
        record_missing_asset(stats, href)
        return nil
      end
      stats.inlined = stats.inlined + 1
      local data_url = string.format("data:%s;base64,%s", mime_for_path(abs_path), b64encode(bin))
      local new_attrs = attrs:gsub("(href%s*=%s*)([\"'])([^\"']+)%2", function(k, q, _)
        return k .. q .. data_url .. q
      end, 1)
      return "<link" .. new_attrs .. ">"
    end
    return nil
  end)

  -- 2. Inline local <img src="...">, <source src="...">, and <image href/xlink:href="...">
  local function rewrite_tag_attr(tag_name, attrs, attr_name)
    local val = extract_attr(attrs, attr_name)
    if not val or is_remote_or_special_url(val) then return nil end
    local abs_path, suffix = resolve_local_ref(html_dir, val)
    local bin = read_file(to_os_path(abs_path))
    if not bin then
      record_missing_asset(stats, val)
      return nil
    end
    stats.inlined = stats.inlined + 1
    local frag = suffix:match("(#.*)$") or ""
    local data_url = string.format("data:%s;base64,%s%s", mime_for_path(abs_path), b64encode(bin), frag)
    local replaced = false
    local new_attrs = attrs:gsub("([%a%d_%-:]+%s*=%s*)([\"'])([^\"']+)%2", function(k_eq, q, v)
      if not replaced and k_eq:gsub("%s*=%s*$", ""):lower() == attr_name:lower() then
        replaced = true
        return k_eq .. q .. data_url .. q
      end
      return nil
    end)
    if not replaced then
      new_attrs = attrs:gsub("([%a%d_%-:]+%s*=%s*)([^%s\"'>]+)", function(k_eq, v)
        if not replaced and k_eq:gsub("%s*=%s*$", ""):lower() == attr_name:lower() then
          replaced = true
          return k_eq .. '"' .. data_url .. '"'
        end
        return nil
      end)
    end
    return "<" .. tag_name .. new_attrs .. ">"
  end

  seg = seg:gsub("<([Ii][Mm][Gg])(%s[^>]*)>", function(tag_name, attrs)
    return rewrite_tag_attr(tag_name, attrs, "src")
  end)
  seg = seg:gsub("<([Ss][Oo][Uu][Rr][Cc][Ee])(%s[^>]*)>", function(tag_name, attrs)
    return rewrite_tag_attr(tag_name, attrs, "src")
  end)
  seg = seg:gsub("<([Ii][Mm][Aa][Gg][Ee])(%s[^>]*)>", function(tag_name, attrs)
    return rewrite_tag_attr(tag_name, attrs, "href") or rewrite_tag_attr(tag_name, attrs, "xlink:href")
  end)

  return seg
end

local function inline_html_assets(html_text, html_dir)
  local stats = { inlined = 0, missing = {}, missing_set = {} }
  local out = {}
  local pos = 1
  local len = #html_text
  local low_html = html_text:lower()

  while pos <= len do
    local s_pos = low_html:find("<script", pos, true)
    local st_pos = low_html:find("<style", pos, true)
    local next_pos, kind = nil, nil
    if s_pos and (not st_pos or s_pos < st_pos) then
      local after = html_text:sub(s_pos + 7, s_pos + 7)
      if after == "" or after:match("[%s>]") then
        next_pos, kind = s_pos, "script"
      end
    elseif st_pos then
      local after = html_text:sub(st_pos + 6, st_pos + 6)
      if after == "" or after:match("[%s>]") then
        next_pos, kind = st_pos, "style"
      end
    end

    if not next_pos then
      if s_pos or st_pos then
        local skip_to = math.min(s_pos or (len + 1), st_pos or (len + 1))
        out[#out + 1] = inline_html_nonraw_segment(html_text:sub(pos, skip_to), html_dir, stats)
        pos = skip_to + 1
      else
        out[#out + 1] = inline_html_nonraw_segment(html_text:sub(pos), html_dir, stats)
        break
      end
    else
      if next_pos > pos then
        out[#out + 1] = inline_html_nonraw_segment(html_text:sub(pos, next_pos - 1), html_dir, stats)
      end

      local open_end = html_text:find(">", next_pos, true)
      if not open_end then
        out[#out + 1] = html_text:sub(next_pos)
        break
      end
      local open_tag = html_text:sub(next_pos, open_end)
      local tag_len = (kind == "script") and 7 or 6
      local attrs = open_tag:sub(tag_len + 1, -2)
      local close_pat = (kind == "script") and "</script>" or "</style>"
      local c_start, c_end = low_html:find(close_pat, open_end + 1, true)
      if not c_start then
        out[#out + 1] = html_text:sub(next_pos)
        break
      end
      local body = html_text:sub(open_end + 1, c_start - 1)
      local close_tag = html_text:sub(c_start, c_end)

      if kind == "style" then
        local inlined_style = inline_css_text(body, html_dir, stats, {})
        out[#out + 1] = open_tag .. inlined_style .. close_tag
      else
        local src = extract_attr(attrs, "src")
        local typ = (extract_attr(attrs, "type") or ""):lower()
        local is_module = (typ == "module")
        if src and not is_remote_or_special_url(src) then
          local abs_path = resolve_local_ref(html_dir, src)
          local js = read_file(to_os_path(abs_path))
          if js then
            stats.inlined = stats.inlined + 1
            if is_module then
              js = inline_js_module(js, dir_of_path(abs_path), stats, { [abs_path:lower()] = true })
            end
            js = js:gsub("</([Ss][Cc][Rr][Ii][Pp][Tt])", "<\\/%1")
            local new_attrs = strip_attr(strip_attr(attrs, "src"), "defer")
            out[#out + 1] = "<script" .. new_attrs .. ">\n/* inlined: " .. src .. " */\n" .. js .. "\n" .. close_tag
          else
            record_missing_asset(stats, src)
            out[#out + 1] = html_text:sub(next_pos, c_end)
          end
        else
          if is_module and body:match("%S") then
            body = inline_js_module(body, html_dir, stats, {})
          end
          out[#out + 1] = open_tag .. body .. close_tag
        end
      end
      pos = c_end + 1
    end
  end

  return table.concat(out), stats
end

local function render_html(el, class, preamble, doc_state)
  local out = {}
  if el.attributes["show"] == "true" then
    out[#out + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { class }))
  end

  local custom_title = el.attributes["title"] or el.attributes["label"] or el.attributes["caption"]
  local file_cand = extract_html_file_candidate(el.text)
  local working_dir = get_html_working_dir()
  local raw_html = nil
  local err_msg = ""
  local asset_dir = working_dir
  local fallback_title = "Open Interactive HTML"

  if file_cand then
    local resolved = resolve_local_ref(working_dir, file_cand)
    fallback_title = base_name_of(resolved)
    local content = read_file(to_os_path(resolved))
    if content then
      raw_html = content
      asset_dir = dir_of_path(resolved)
    else
      err_msg = "HTML file not found: " .. file_cand
      warn("[html] " .. err_msg)
    end
  else
    raw_html = el.text
  end

  local title = custom_title
  if (not title or title == "") and raw_html then
    local parsed_title = raw_html:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
    if parsed_title then
      parsed_title = parsed_title:gsub("%s+", " "):match("^%s*(.-)%s*$")
      if parsed_title ~= "" then title = parsed_title end
    end
  end
  title = (title and title ~= "") and title or fallback_title

  if not doc_state.is_whiteboard_html then
    local note_latex = string.format(
      "\\begin{quote}\\textbf{[Interactive HTML: %s]} Available in \\texttt{page-layout: whiteboard\\_html} to open in a browser tab.\\end{quote}",
      escape_latex_plain(title)
    )
    out[#out + 1] = pandoc.RawBlock("latex", note_latex)
    return out
  end

  local bundled_html, stats = "", { inlined = 0, missing = {}, missing_set = {} }
  if raw_html then
    bundled_html, stats = inline_html_assets(raw_html, asset_dir)
    if #stats.missing > 0 then
      warn("[html] Missing local asset(s) for '" .. title .. "': " .. table.concat(stats.missing, ", ") .. " (HTML will still launch)")
    end
  end

  local missing_str = table.concat(stats.missing, ", ")
  local payload_line = table.concat({
    b64encode(title),
    b64encode(missing_str),
    b64encode(err_msg),
    tostring(stats.inlined),
    b64encode(bundled_html)
  }, "|")

  out[#out + 1] = pandoc.RawBlock("latex", "\n\\begin{wbhtmlembed}\n" .. payload_line .. "\n\\end{wbhtmlembed}\n")
  return out
end

register{ id = "latex_unv", names = { "latex_unv", "tex_unv" }, render = render_latex_unv }
register{ id = "latex", names = { "latex", "tex" }, render = render_latex }
register{ id = "htmlsvg", names = { "htmlsvg", "svg" }, render = render_htmlsvg }
register{ id = "html", names = { "html", "htm" }, render = render_html }

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
  if IS_WIN and spec.id == "mermaid" and (e == "mmdc.cmd" or e == "mmdc") then
    local appdata = os.getenv("APPDATA")
    if appdata then
      local candidate = appdata .. "\\npm\\mmdc.cmd"
      if file_exists(candidate) then e = candidate end
    end
  end
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
  elseif spec.id == "mermaid" then
    local command = exe:match('^"(.*)"$') or exe
    local ok, result = pcall(pandoc.pipe, command, { "--version" }, "")
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
  local confirm_env = os.getenv("MD2PDF_CONFIRM_" .. spec.id:upper())
      or (spec.is_diagram and "0" or (os.getenv("MD2PDF_CONFIRM_EXEC") or "1"))
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

  local show_code = a["show"] == "true" or (not spec.is_diagram and a["show"] ~= "false")
  if show_code then
    blocks[#blocks + 1] = pandoc.CodeBlock(el.text, pandoc.Attr("", { spec.id }))
  end

  local show_output = a["output"] == "true" or (not spec.is_diagram and a["output"] ~= "false")
  if show_output then
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
      local img_attr = pandoc.Attr("", {}, {})
      if a["width"] then img_attr.attributes["width"] = a["width"] end
      local img = pandoc.Image({}, p, "", img_attr)
      if a["caption"] and pandoc.Figure then
        local cap = pandoc.read(a["caption"]).blocks
        blocks[#blocks + 1] = pandoc.Figure(pandoc.Plain({ img }), cap)
      else
        blocks[#blocks + 1] = pandoc.Para({ img })
      end
    else
      warn("expected image not found: " .. p)
    end
  end
  return blocks
end

-- ------------------------------ 5. dispatch ---------------------------------
local function process_code_block(el, preamble, doc_state)
  if el.attributes["run"] == "false" then return nil end
  local class = (el.classes[1] or ""):lower()
  local spec = LANGS[class]
  if not spec then return nil end
  if spec.id == "latex" or spec.id == "latex_unv" or spec.id == "htmlsvg" then
    local scaffold = has_scaffolding_redefinition(el.text)
    if scaffold then
      warn(string.format("%s block redefines template scaffolding macro '\\%s'; rendering as code listing (run=false)", spec.id, scaffold))
      return nil
    end
  end
  if spec.render then return spec.render(el, class, preamble, doc_state) end
  local result = run_exec(el, spec)
  if not result then return pandoc.CodeBlock(el.text, pandoc.Attr("", { spec.id })) end
  return render(el, spec, result)
end

local function add_latex_preamble(doc, preamble)
  if #preamble == 0 then return end
  local includes = {}
  local old = doc.meta["header-includes"]
  if old then
    if old.t == "MetaList" then
      for _, item in ipairs(old) do includes[#includes+1] = item end
    else
      includes[#includes+1] = old
    end
  end
  includes[#includes+1] = pandoc.MetaBlocks({
    pandoc.RawBlock("latex", table.concat(preamble, "\n"))
  })
  doc.meta["header-includes"] = pandoc.MetaList(includes)
end

function Pandoc(doc)
  local preamble = {}
  local is_wb_html = false
  if doc and doc.meta then
    local wb_flag = doc.meta.whiteboard_html
    if wb_flag == true or tostring(wb_flag) == "true" then
      is_wb_html = true
    elseif doc.meta["page-layout"] and pandoc.utils and pandoc.utils.stringify(doc.meta["page-layout"]) == "whiteboard_html" then
      is_wb_html = true
    end
  end
  local doc_state = { seen_unv_fence = false, loaded_packages = {}, is_whiteboard_html = is_wb_html }
  doc = doc:walk({ CodeBlock = function(el) return process_code_block(el, preamble, doc_state) end })
  add_latex_preamble(doc, preamble)
  return doc
end

return { { Pandoc = Pandoc } }