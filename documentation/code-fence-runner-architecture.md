CODE FENCE RUNNER: ARCHITECTURE AND BUILD GUIDE
===============================================

Purpose and scope
-----------------
This guide documents config\code-fence-runner.lua: how Pandoc invokes it,
language registration and dispatch, Python, C, C++, Java, and LaTeX/TeX behavior, cache and
figure artifacts, every named Lua and embedded wrapper function, and a
step-by-step extension and validation procedure.

The runner is the second Lua filter in compile.bat. It receives the normalized
combined Pandoc AST from markdown-normalizer.lua. It executes recognized
executable-language blocks (Python, C, C++, Java), renders their source/output/errors/figures, and
renders LaTeX/TeX blocks without executing them. Executable blocks run with the invoking
user's permissions; the filter is not a sandbox.

Build and call lifecycle
------------------------
The file is Lua code loaded by Pandoc at conversion time. No separate binary
build exists.

1. compile.bat places markdown-normalizer.lua before code-fence-runner.lua on
   Pandoc's command line. The ordering is a contract, not cosmetic.
2. Pandoc invokes the exported Pandoc(doc) callback after the normalizer.
3. The runner creates a fresh local preamble array, then walks the document's
   CodeBlock nodes. Pandoc calls the inline CodeBlock callback for each block.
4. process_code_block returns nil for run=false or an unrecognized first class
   name, preserving the original block. It sends a registered rendered
   language to its render handler (currently latex/tex), or routes an
   executable language through run_exec and render.
5. Executable language aliases resolve to their registered language specifications:
   - Python: python, py, python3, py3 (selected via PYTHON or default "py" on Windows)
   - C: c (selected via C_COMPILER or default "gcc")
   - C++: cpp, c++, cxx, cc (selected via CPP_COMPILER or default "g++")
   - Java: java (selected via JAVA_RUNNER or default "java"; compiler via JAVAC_COMPILER or "javac")
   The runner fingerprints the runtime/compiler, builds a cache key, restores a valid
   result when possible, and otherwise asks before execution unless trusted=true.
   run=new and cache=false always require a fresh confirmation.
6. run_fresh writes the user source and generated wrapper in MD2PDF_CACHE,
   executes it with OS-level stdin/stdout/stderr redirection, gathers output,
   error, figure, dependency, and side-effect metadata, then returns a result
   record. Failed executions are not cacheable.
7. render creates Pandoc blocks for source, output, error, and discovered
   figure images, respecting fence attributes. It trims trailing output
   whitespace, applies maxlines, optionally adds OUTPUT_LABEL, and verifies
   each figure still exists before creating an Image. If no captured figure
   is available, img may supply a legacy local image.
8. Pasted full-document LaTeX preamble commands rescued by render_latex are
   appended to existing header-includes by add_latex_preamble.
9. Pandoc(doc) returns the updated document to Pandoc for LaTeX generation.
   XeLaTeX is invoked later by compile.bat.

The file returns { { Pandoc = Pandoc } }, declaring its Pandoc document
callback. It does not produce a PDF itself.

Inputs, language specification, and state
------------------------------------------
Pandoc CodeBlock
  el.text       original fence source.
  el.classes    language classes; the first class is lowercased for dispatch.
  el.attributes key/value fence attributes such as run, trusted, show, output,
                error, maxlines, cache, figures, deps, and img.
  el is the Pandoc element passed by the document walk.

LANGS
  Maps each lowercased language alias to a language spec table. register(spec)
  validates and fills executable defaults before adding each alias.

Executable spec fields
  id            canonical language name; used in cache identity and CSS class.
  names         aliases mapped into LANGS.
  exe_env       environment variable selecting the executable.
  exe_default  executable used when exe_env is unset/empty.
  ext           extension for cached user-code and wrapper files.
  template      wrapper source containing @@TOKEN@@ substitutions.
  quote(path)  path quoting function; defaults to Lua string quoting.
  command      optional custom executable invocation builder.
  auto_deps    whether the wrapper records opened workspace inputs.
  label         display label used in error messages.
  fp            SHA-1 fingerprint of the wrapper template.
  render        when present, identifies a non-executable language renderer.

Python spec
  id=python; aliases python, py, python3, py3; executable environment
  variable PYTHON; default python for direct filter invocation; cached files
  use .py; automatic dependency tracking is enabled. compile.bat sets PYTHON
  to py.

C spec
  id=c; alias c; compiler environment variable C_COMPILER; default gcc;
  cached files use .c; supports full programs with main() and bare snippets
  (automatically wrapped with standard includes and int main). Compiled
  with -O2 -lm and executed with OS redirection; compiled binaries are purged
  immediately after run.

C++ spec
  id=cpp; aliases cpp, c++, cxx, cc; compiler environment variable CPP_COMPILER;
  default g++; cached files use .cpp; supports full programs with main()
  and bare snippets (automatically wrapped with standard C++ headers and
  int main). Compiled with -O2 -std=c++17 and executed with OS redirection;
  binaries are purged immediately.

Java spec
  id=java; alias java; runner environment variable JAVA_RUNNER (default java);
  compiler environment variable JAVAC_COMPILER (default javac); cached files
  use .java. Supports classes with main() and bare snippets (wrapped in public
  class Main). Uses javac -d <dir> when available or falls back to single-file
  source execution via java. Isolates Java classes in per-block cache directories.

LaTeX spec
  latex and tex aliases resolve to render_latex. It has no executable and its
  source is converted to raw LaTeX blocks. It is not run by a shell.

LaTeX extraction policy tables
  SCAFFOLDING_MACROS:
    maketitle tableofcontents title author date @title @author @date (redefinition
    triggers automatic run=false demotion to a syntax-highlighted code block)
  DEF_NAMES:
    newcommand renewcommand providecommand DeclareRobustCommand
  FONT_FAMILY_COMMANDS:
    newfontfamily renewfontfamily setfontfamily providefontfamily
    newfontface renewfontface setfontface providefontface (fontspec family/face
    definitions rescued from preamble deletion and retained in local_cmds)
  PRIMITIVE_DEFS:
    def gdef edef (plus \let; low-level TeX definition and assignment primitives
    rescued from preamble deletion and retained in local_cmds)
  TEMPLATE_THEOREMS:
    theorem lemma proposition corollary definition example remark
  SIMPLE_PREAMBLE:
    usetikzlibrary usepgfplotslibrary usepgflibrary pgfplotsset tikzset
    sisetup theoremstyle newunicodechar
  THREE_ARG_PREAMBLE:
    NewDocumentCommand DeclareDocumentCommand
  SKIP_PACKAGES and SKIP_PACKAGE_NAMES:
    inputenc fontenc fontspec geometry hyperref babel polyglossia lmodern
    microtype fancyhdr parskip graphicx xcolor amsmath amssymb amsfonts
    amsthm mathtools physics braket tikz pgf pgfplots booktabs longtable
    array float caption fvextra xurl soul etoolbox newunicodechar
    unicode-math bm cancel mhchem placeins multirow calc footnotehyper
    textcomp mathrsfs bookmark color siunitx circuitikz tcolorbox algorithm
    algpseudocode chemfig subcaption listings enumitem adjustbox
    pgfplotstable tikz-cd footnote.
    This runner copy belongs to its separate full-LaTeX-preamble parser; keep
    it aligned with both the normalizer list and config\custom.tex.

Cache root and naming
  MD2PDF_CACHE selects the cache directory. If unset, the runner uses TEMP,
  TMPDIR, or "." plus md2pdf_cache. CACHE_SCHEMA is rf4; CACHE_LIMIT is 200;
  CACHE_INDEX is <cache>/.index.
  At filter load, pandoc.system.make_directory(CACHE_DIR, true) creates the
  cache directory tree if needed.
  A source/spec/options/dependency hash produces a name fence_<sha1>. The
  prefix is then used for .out, .err, .meta, .deps, .writes, generated code,
  wrapper, and numbered figure/side-effect files. purge(name) removes artifacts
  for that exact block key; touch_cache(name) maintains recency and LRU cleanup.

Other file-scope variables
  IS_WIN             platform flag derived from package.config.
  NULL_DEV           NUL on Windows or /dev/null on Unix-like systems.
  IMG_EXT            image extensions discovered from the cache: PNG/JPG/PDF.
  LANGS              language alias -> specification map.
  COMPILER_FINGERPRINTS memo table indexed by spec.id .. ":" .. exe string.
  PY_TEMPLATE        Python wrapper source used by the Python specification.
  DEF_NAMES          definitions retained by full-document LaTeX extraction.
  SKIP_PACKAGE_NAMES readable package-name list; SKIP_PACKAGES is its set.
  TEMPLATE_THEOREMS  theorem environment names already supplied by custom.tex.
  SIMPLE_PREAMBLE    one-argument settings/declarations eligible for rescue.
  THREE_ARG_PREAMBLE command forms requiring three brace arguments.
  ERR_LINES          maximum traceback tail retained in a rendered error.
  OUTPUT_LABEL       label printed above captured stdout; empty disables it.
These are initialized once when Pandoc loads the filter. Per-document data,
such as the collected LaTeX preamble, is local to Pandoc(doc); cache records
persist in files under CACHE_DIR.

Python wrapper architecture
---------------------------
PY_TEMPLATE is Python source generated for every fresh Python execution.
fill(template, vars) substitutes uppercase tokens:

  @@CODE@@     absolute quoted cached user-code path.
  @@PREFIX@@   absolute quoted artifact prefix.
  @@DEPS@@     raw opened-input list path.
  @@WRITES@@   side-effect manifest path.
  @@FIGURES@@  Python boolean indicating whether PDF figure capture is enabled.

The wrapper then:
1. Disables bytecode files and adds the first-input working directory to
   sys.path so local imports can still resolve even though the script is in
   the cache.
2. Reconfigures stdout/stderr to UTF-8 when available.
3. Installs a best-effort Python audit hook for file-open dependencies and
   workspace-local writes. It excludes cache artifacts, interpreter/site
   package files, pycache, matplotlib internals, and outputs written earlier
   in the same run. Input files are content-hashed in Lua after execution.
4. Registers _write_deps with atexit. It writes the opened-file list and
   archives eligible workspace-local side effects with SHA-1 manifests.
5. Attempts to load Matplotlib, selects the noninteractive Agg backend, and
   monkey-patches Figure.savefig. The patch preserves the user's requested
   save and makes a PDF-compatible numbered copy when capture is enabled.
6. Registers _flush at exit and replaces plt.show with a call to _flush.
   Unsaved non-empty figures are captured as numbered PNGs; figures are closed.
7. Calls _main, which reads and compiles the cached source file using that
   file's path for traceback line numbers, then executes it as __main__ with
   __file__ presented as <working-directory>/__md2pdf_block__.py.
8. On a user-code exception, _main filters wrapper frames from the traceback
   when possible and exits with status 1. SystemExit is allowed to propagate.

The wrapper registers _write_deps before it registers _flush. Python executes
atexit callbacks in last-in, first-out order, so _flush runs before
_write_deps at normal interpreter shutdown. This lets figure files created
during final flushing exist before dependency/write manifests are finalized.
An explicit plt.show calls _flush immediately; already-closed figures are not
flushed a second time at shutdown.

Python wrapper functions and globals
  _audit(event, args)
    Audit hook. Handles open events, distinguishes reads/writes, filters
    excluded/system/cache paths, and records eligible file dependencies or
    side effects. It deliberately contains defensive exceptions because an
    audit hook must not break unrelated Python file operations.
  _write_deps()
    Writes the raw dependency list and creates content-hashed archived copies
    plus a target/archive/hash manifest for eligible side effects.
  _has_content(fig)
    Returns whether a Matplotlib Figure contains axes, text, images, artists,
    or patches, preventing empty figures from being captured.
  _sv(self, fname, *args, **kwargs)
    Wrapped Figure.savefig implementation. First invokes the original save
    behavior, then optionally saves an additional numbered copy for PDF
    embedding. Unsupported output formats are copied as PNG.
  _flush()
    Captures nonempty figures not already marked saved, then closes open
    figures. Used by plt.show and atexit.
  _main()
    Reads the user script, provides __name__, __file__, and __package__,
    executes compiled code, preserves SystemExit, and prints filtered
    tracebacks for other failures.
  _CWD, _CACHE_PREFIX, _SKIP, _DATA_EXT, _deps, _written
    Wrapper-level paths, exclusion rules, data-file extension set, and
    dependency/write collections. These are separate from Lua's cache state.
  Complete wrapper-global inventory:
    _CODE, _PREFIX, _DEPS, _WRITES are absolute paths derived from generated
    tokens; _CAPTURE_FIGURES is the embedding switch; _CWD and
    _CACHE_PREFIX are normalized absolute paths; _skip_paths is the initial
    set of interpreter roots and site-package roots; _SKIP is that set
    normalized for prefix comparisons; _deps and _written are sets populated
    by _audit;     _DATA_EXT is the configured data-file extension tuple:
    .csv .tsv .txt .json .xlsx .xls .npy .npz .parquet .feather .pkl .pickle
    .h5 .hdf5 .dat .xml .yaml .yml .mat .sav .dta .py .rds .rdata
    .sas7bdat .db .sqlite .sqlite3;
    _HAVE_MPL records whether Matplotlib imports succeeded. Only when
    _HAVE_MPL is true, _cnt is the numbered-artifact counter, _orig stores the
    original Figure.savefig method, and _FIG_EXT contains the supported
    direct-save extensions png/jpg/jpeg/pdf. The wrapper's _s, _p, _mode,
    _flags, _w, _full, _n, _key, _target, _digest, _source, _chunk, _f,
    _manifest, _num, _fig, _e, _tb, _code, and _globals names are function-
    local scratch values, not persistent protocol state.

Exact Python wrapper helper behavior
  _audit accepts only audit events named "open". It classifies the operation
  using mode when supplied, otherwise the OS flags; resolves it to an absolute
  real path; ignores this fence's cache prefix, pycache/bytecode, interpreter
  and site-package roots, matplotlib internals, and most external files.
  Reads of files already written by this run are ignored. Workspace files and
  recognized data-file extensions are tracked if they exist. Audit-hook errors
  are swallowed intentionally so instrumentation does not break the user's
  ordinary file open.
  _write_deps writes sorted dependency paths, excludes paths also written by
  the block, and saves only existing files written inside the working
  directory. It hashes in 1 MiB chunks, copies each output to a unique
  <prefix>_sidefx_N archive, and writes target/archive/digest rows.
  _has_content tests only the listed Figure collections; an empty Figure is
  skipped.
  _sv first calls the original Figure.savefig with the original arguments,
  thereby preserving the user's requested output. It marks the Figure as
  saved, and for a non-empty figure with a path-like filename and capture
  enabled, makes a numbered cache copy. A requested extension outside PNG,
  JPG/JPEG, or PDF is changed to PNG for the captured copy; the copy attempt
  failure is printed to stderr without changing the original save result.
  _flush enumerates current pyplot figure numbers, captures each qualifying
  unsaved figure to a numbered PNG with tight bounding box, and closes every
  figure whether or not embedding is enabled. Replacing plt.show means show
  captures/closes figures instead of opening an interactive GUI window.
  _main uses a separate globals dictionary for each fence with __name__ set to
  "__main__", __package__ set to None, and the documented working-directory
  __file__. It reads UTF-8 source, compiles it with the cache code path as the
  compiler filename for accurate traceback lines, then executes. SystemExit
  propagates; other BaseException types are rendered after filtering leading
  wrapper frames where possible.

Cache artifact model
--------------------
For one block key, the main artifacts are:
  .out             captured stdout, used to render output and on cache hits.
  .meta            figure paths; existence marks a completed cache entry.
  .deps            recorded automatic input paths plus content digests.
  .writes          target, archived copy, and digest for side effects.
  _N.ext           numbered captured figures discovered and sorted by N.
  _code.py         original source during fresh execution.
  _run.py          generated wrapper during fresh execution; removed afterward.
  .err             captured stderr temporarily; echoed to console and removed.
  .rawdeps / .rawwrites
                   transient files produced by the wrapper then normalized
                   into .deps and .writes.
  .index            newline-separated LRU keys; it is cache bookkeeping, not
                    a result artifact for an individual block.

A cache hit requires a Python runtime fingerprint, no force-run attribute, a
saved .out, unchanged recorded automatic dependencies, successful side-effect
validation/restoration, and valid figure metadata. Any failed run purges the
entry and is not cached.

An empty .meta file is valid for a successful run with no figures: read_meta
returns an empty list, not nil. The separate .out, .deps, and .writes files
still need to exist and pass their respective checks for reuse.

The key includes CACHE_SCHEMA, canonical language id, executable string,
template fingerprint, exact source text, img and figures attributes, runtime
fingerprint, content hashes from explicit deps=, and the first input's working
directory. This prevents a cache entry from one input folder from restoring
side effects into another folder. If a side-effect target's parent directory
is missing, that cache entry is treated as stale and Python runs again instead
of failing during restoration. The .index is a 200-entry LRU list. Network
responses, environment variables, time, and some external
state cannot be inferred; use run=new or cache=false when needed.
The key components are concatenated with NUL separators before SHA-1 hashing.
show, output, error, and maxlines do not affect execution results and are not
in the key; render applies them after retrieval, so the same cached result can
be presented with different display attributes. run and cache control whether
to bypass lookup, but are not key components. figures is in the key because it
changes figure capture; img is in the key because it changes the fallback
rendered image.

Function reference: utilities and cache
---------------------------------------
  warn(message)
    Writes a [code-fence-runner] diagnostic to stderr.
  read_file(path) -> string or nil
    Reads binary-safe file contents; returns nil when open fails.
  write_file(path, contents)
    Writes binary-safe bytes. Asserts that the file can be opened.
  file_exists(path) -> boolean
    Opens a file in binary mode and closes it.
  file_hash(path) -> SHA-1 or nil
    Hashes file contents with pandoc.sha1.
  slash(path) -> path
    Replaces Windows separators with forward slashes for internal consistency.
  trim_end(text) -> text
    Removes trailing whitespace for display.
  crlf_to_lf(text) -> text
    Normalizes Windows CRLF to LF in captured process output.
  replace_plain(text, search, replacement) -> text
    Replaces literal (not Lua-pattern) occurrences; used to hide cached paths
    in tracebacks.
  first_lines(text, count) -> text
    Converts count to a number; an absent, invalid, or less-than-one value
    means no limit. Otherwise retains the first count lines and appends an
    omitted-line count only if output was actually truncated.
  last_lines(text, count) -> text
    Retains the last count lines of a traceback and prefixes an omission
    message when earlier lines were removed. The renderer passes ERR_LINES.
  purge(name)
    Removes files whose names belong to the exact cache key.
  touch_cache(name)
    Moves a key to most-recent position in .index, reconstructs keys from
    existing .out files if the index is empty, and purges least-recent entries
    above CACHE_LIMIT. The scan used to reconstruct an absent/empty index
    accepts only fence_<hex>.out names; the index reader also deduplicates
    entries and rejects malformed key names.
  find_figures(name) -> sorted path list
    Lists supported numbered image artifacts and sorts numerically, not
    lexically, by suffix. Accepted formats are PNG, JPG, JPEG, and PDF.
  read_meta(path) -> figure list or nil
    Reads saved figure paths and invalidates metadata if a referenced image is
    absent.
  deps_key(list) -> cache-key text
    Parses comma-separated explicit deps= paths, hashes contents, records
    missing files distinctly, and warns for missing dependencies.
  save_auto_deps(raw_path, deps_path)
    Hashes files listed by the Python wrapper, writes path/digest rows, then
    removes the transient list.
  auto_deps_ok(deps_path) -> boolean
    Confirms every recorded path still hashes to its saved digest.
  restore_side_effects(manifest) -> boolean
    First validates archived copies and current target contents against each
    digest; then restores only targets that are missing. It refuses to
    overwrite a target whose current content differs from the recorded
    output.

Function reference: registration and LaTeX recovery
--------------------------------------------------
  lua_quote(path) -> quoted string
    Uses Lua %q quoting; default executable-language path quoting.
  register(spec)
    Validates executable specs, fills quote/label defaults, hashes the
    template, and maps all aliases to the same spec in LANGS. Render-only
    specs bypass executable-field validation.
  skip_space(text, index) -> next nonspace index
    Returns the first non-whitespace position or #text+1.
  match_group(text, index, open, close) -> closing index or nil
    Finds balanced nested braces/brackets while skipping escaped characters.
  in_comment(text, position) -> boolean
    Checks whether a LaTeX command position is after a percent that is not
    directly preceded by a backslash on its current line.
  extract_commands(preamble) -> command list
    Scans the part before begin{document}; ignores commented commands,
    extracts the explicitly supported command definitions/settings, skips
    template-managed packages and template theorem names, and upgrades
    extracted \newcommand to \DeclareRobustCommand. It uses DEF_NAMES,
    FONT_FAMILY_COMMANDS, SKIP_PACKAGES, SIMPLE_PREAMBLE, THREE_ARG_PREAMBLE, and
    TEMPLATE_THEOREMS as policy tables.
    DEF_NAMES accepts newcommand, renewcommand, providecommand, and
    DeclareRobustCommand, including starred spellings for the command forms
    where the parser allows a star. It handles a command name in a brace group
    or a control-sequence token, then optional bracket groups and a required
    brace-balanced body.
    FONT_FAMILY_COMMANDS accepts newfontfamily, renewfontfamily, setfontfamily,
    providefontfamily, newfontface, renewfontface, setfontface, and providefontface,
    preserving fontspec family and face declarations for local execution.
    PRIMITIVE_DEFS accepts def, gdef, and edef (alongside \let), parsing control sequences,
    optional parameter text, and balanced replacement bodies into local_cmds.
    SIMPLE_PREAMBLE accepts usetikzlibrary, usepgfplotslibrary,
    usepgflibrary, pgfplotsset, tikzset, sisetup, theoremstyle, and
    newunicodechar.
    Additional recognized commands are usepackage, DeclareMathOperator,
    newtheorem, DeclarePairedDelimiter, newenvironment, NewDocumentCommand,
    and DeclareDocumentCommand. The parser advances past a successfully
    parsed command, so it can recover multiple definitions from a preamble.
    For usepackage, it retains an optional [options] group and filters each
    comma-separated package against SKIP_PACKAGES. For newtheorem it supports
    the optional parent-counter argument and skips the template's predefined
    environment names. For newenvironment it supports optional argument-count
    and default-value
    groups and requires both begin/end bodies. DeclarePairedDelimiter requires
    its three brace groups. NewDocumentCommand and DeclareDocumentCommand
    require all three groups. Newtheorem allows an optional parent-counter
    group before its required counter-name group.
  get_global_command_target(cmd) -> target string or nil
    Identifies the unique target name for commands that have global or document-wide scope
    (\DeclareMathOperator, \DeclarePairedDelimiter, \newunicodechar, \newtheorem) to detect
    and prevent cross-fence naming collisions.
  render_latex(CodeBlock, class, preamble, global_defs) -> Pandoc blocks
    Optionally shows source when show=true. For full documents (with begin/end document),
    extracts preamble commands: package and library imports (\usepackage, \usetikzlibrary, etc.)
    and preamble-only declarations (\DeclareMathOperator, \newunicodechar, \DeclarePairedDelimiter)
    are automatically hoisted to preamble (header-includes), while macro definitions, low-level TeX
    primitives (\def, \gdef, \edef, \let), font family commands (\newfontfamily, \newfontface, etc.),
    and custom environments stay strictly local to the block body rather than leaking globally.
    Hoisted \DeclareMathOperator and \DeclarePairedDelimiter declarations are safely prefixed with
    \let\cmd\relax to prevent clashes with pre-existing template or kernel operators/delimiters
    (\Tr, \Pr, \Re, \abs, \norm, etc.).
    Cross-fence collision protection: if any block attempts to define or redefine a global command
    target (via \DeclareMathOperator, \DeclarePairedDelimiter, \newunicodechar, \newtheorem) or imports
    a package with conflicting options compared to an earlier block, render_latex emits a console
    warning and returns nil, automatically demoting the conflicting block to a syntax-highlighted
    code listing (run=false).
    For snippets with no full-document delimiter, it emits source directly. In all cases, enforces
    Universal Code Fence Isolation by wrapping the emitted body in
    {\begingroup\n ... \n\par\endgroup}, ensuring that definitions, colors, font sizes,
    lengths, and counter modifications remain strictly isolated to the block and cannot
    leak to outer Markdown prose or subsequent fences. If usepackage or documentclass appears
    in a snippet without begin{document}, it emits a console warning and returns nil, automatically
    demoting the block to a syntax-highlighted code listing (run=false) to prevent fatal document
    compilation crashes. Source display is opt-in for LaTeX (show=true). Redefinitions of document
    scaffolding macros trigger automatic demotion to a code listing (run=false).

Function reference: execution and rendering
--------------------------------------------
  fill(template, vars) -> generated text
    Replaces @@UPPERCASE@@ tokens using a gsub callback. The callback asserts
    when a token has no value, so a broken spec fails explicitly rather than
    leaving a success-shaped placeholder in the generated wrapper.
  executable(spec) -> executable path/string
    Reads spec.exe_env and falls back to spec.exe_default when missing/empty.
  runtime_fingerprint(spec, exe) -> fingerprint, empty string, or nil
    For Python, asks the selected interpreter for Python version and sorted
    installed distribution versions, caches the result in COMPILER_FINGERPRINTS,
    and returns nil with a warning if inspection fails. Nil disables reuse.
    Non-Python executable specs return an empty fingerprint.
  quote_executable(exe) -> shell-quoted executable
    Leaves already quoted paths alone and applies platform-specific quoting.
  command_line(spec, exe, script, out, err) -> shell command
    Uses spec.command if supplied, otherwise quotes the executable/script;
    redirects stdin to the platform null device and stdout/stderr to files.
    Applies the cmd.exe outer-quote rule on Windows.
  execute(command) -> success boolean, exit code
    Normalizes os.execute return conventions across Lua versions.
  echo_stderr(text)
    Writes captured stderr to filter stderr, adding a final newline if absent.
  run_fresh(CodeBlock, spec, exe, name) -> result
    Purges old artifacts, writes source and generated wrapper, runs the
    command, reads normalized stdout/stderr, removes transient files, and
    echoes stderr. On failure it diagnoses missing executables, replaces
    cache paths in the traceback, purges the key, and returns {ok=false}.
    On success it discovers numbered figures, saves automatic deps only when
    spec.auto_deps is true (otherwise writes an empty .deps file), saves the
    write manifest, stdout, and figure metadata, then returns {ok=true}.
    Result fields are ok, out, err, and figs. Stderr is echoed even on success.
  run_exec(CodeBlock, spec) -> result
    Chooses executable and runtime fingerprint, hashes all cache-key parts,
    updates LRU recency, evaluates run=new/cache=false, validates cache files
    and side effects, and either returns cached content or prompts before a
    fresh Python execution. Valid cache hits do not prompt. Forced fresh Python
    runs always ask; trusted=true skips prompts only for ordinary uncached
    runs. Declining leaves the original code as a source listing.
  render(CodeBlock, spec, result) -> Pandoc block sequence
    Applies show/output/error/maxlines/figures/img attributes. It creates
    source and stdout CodeBlocks, a labeled error paragraph plus traceback
    CodeBlock for failed runs, and Image blocks for available figures.
  process_code_block(CodeBlock, preamble) -> replacement or nil
    Preserves run=false and unknown-language blocks. Resolves the first class
    through LANGS; calls a render-only handler or executes then renders.
  add_latex_preamble(doc, preamble)
    Adds rescued LaTeX as MetaBlocks in header-includes, preserving any
    existing MetaList or single metadata value.
  Pandoc(doc) -> Pandoc document
    Creates the collected preamble, walks CodeBlocks using
    process_code_block, injects any rescued commands, and returns the document.

Attributes and their call path
------------------------------
  run=false
    Checked first in process_code_block; block remains unexecuted source.
  run omitted / run=true
    Both follow normal execution/cache lookup. On a Python cache miss, the
    runner displays the code and asks for a Y confirmation; any other response
    leaves it as a source listing. A valid cache hit does not prompt.
  trusted=true
    Skips confirmation for an ordinary uncached Python run. It does not
    suppress confirmation for run=new or cache=false.
  run=new or cache=false
    run_exec bypasses cache and asks for confirmation every time before a
    Python execution; a successful run refreshes the same key's artifacts.
  show=false
    render omits source. For LaTeX, source is shown only when show=true.
  output=false
    render omits captured stdout.
  error=false
    render hides the error block; run_fresh still echoes stderr/diagnostics.
  maxlines=N
    render calls first_lines on output.
  figures=false
    Python wrapper avoids PDF capture; user's own savefig still writes its
    requested file. Renderer does not embed captured images. plt.show is still
    replaced with a noninteractive flush/close operation.
  deps="a.csv,b.npy"
    deps_key hashes explicit paths into the cache key.
  img="figure.png"
    If no captured figure exists and figures is not false, render can use this
    legacy local image if it exists relative to the build working directory.

Nested Lua closures and anonymous callbacks
-------------------------------------------
These functions are deliberately local to the operation whose state they
share:
  touch_cache's initialization/list callbacks
    The list-directory loop selects valid existing fence keys only when the
    index is empty; the line iterator filters old index entries; seen prevents
    duplicate entries.
  find_figures' table.sort comparator(a, b)
    Orders numeric suffixes ascending so figure _2 precedes figure _10.
  register's alias loop
    Maps every lowercased alias to the same validated spec object.
  extract_commands has no nested function objects; it uses cursor/index locals
    for escaped group scans and command-arity parsing.
  fill's gsub callback(token)
    Resolves each placeholder and asserts when its value is missing.
  Python _audit helpers are inline path/mode tests, not separate functions;
  plt.show is assigned a lambda forwarding arbitrary args to _flush.
  Pandoc(doc)'s CodeBlock callback
    Closes over the preamble array for this document and delegates to
    process_code_block.
This supplements, rather than replaces, the named-function references above.

Step-by-step change and validation guide
----------------------------------------
1. Establish the intended behavior, acceptance check, and trusted test input.
   Inspect git status and preserve unrelated files.
2. Decide which layer owns the change:
     language alias/spec          LANGS and register(spec)
     cache correctness            run_exec/cache helpers/runtime fingerprint
     process setup/capture        PY_TEMPLATE and run_fresh/command_line
     LaTeX preamble extraction    extract_commands/render_latex and policy sets
     PDF document blocks          render and process_code_block
     metadata integration         add_latex_preamble/Pandoc
3. Preserve the runner contract: write source separately from the wrapper,
   honor the exact code-file path in tracebacks, return result shape
   {ok,out,err,figs}, and do not cache failed runs.
4. For a new executable language, add a spec using register. Supply id, names,
   executable environment/default, extension, and a template with the tokens
   it needs. The template must execute @@CODE@@ and write any figures using
   the @@PREFIX@@ naming contract. Add custom quoting/command only if the
   language requires it. Use auto_deps only if its wrapper produces the
   expected dependency manifest. Unknown blocks should remain unchanged.
5. For cache changes, list every value that can alter execution or rendering.
   Update CACHE_SCHEMA when the on-disk Lua cache format changes; do not bump
   it merely for a template change because spec.fp already contributes to the
   key. Test first-run approval/decline, unchanged cache hit without a prompt,
   run=new/cache=false confirmation on every fresh run, changed dependency,
   missing side-effect restoration, and failed execution.
6. For preamble recovery, keep the parser narrow and balanced. Update command
   sets and extraction branches together; ensure comments are ignored and
   template-owned packages/theorems are not duplicated.
7. Build a small focused .txt document with the exact code/LaTeX fence and
   attributes. Approve only benign test code that you trust; the runner is
   not sandboxed.
8. Run the wrapper from the repository root:

     .\compile.bat "path\to\focused.txt"

   Verify PDF source/output/error/figure appearance and the console messages.
   For normalizer-only syntax/AST checks, use Pandoc's --to=native path; for a
   runner test, include only benign test code and approve its prompt as needed.
9. When a supported behavior changes, update the lasting regression fixture.
   Run filter-feature-regression.md when its affected integration surface
   warrants the broader test; its Python failure is deliberate. Do not claim a
   build was performed unless it actually was.
10. Run git diff --check, inspect the source/documentation diff, and exclude cache,
    temporary wrappers, generated files, and personal inputs unless explicitly
    requested.

Important invariants and limits
-------------------------------
- Filter order is normalizer first, runner second.
- Python executes as the current user; it is not sandboxed or permission-
  restricted by the filter.
- Exact Python source text participates in the cache key, including comments.
- Automatic file-open tracking is best-effort and does not cover every
  environment variable, network request, clock, subprocess input, or external
  dependency. deps= and run=new/cache=false are explicit controls.
- Cache artifacts are disposable but contain captured outputs, figures, and
  side-effect archives. Do not treat the cache as an input source of truth.
- The runner does not create the final PDF. Pandoc and XeLaTeX perform that
  work after both Lua filters have returned.
- Captured stderr is echoed to Pandoc's stderr; error=false affects only the
  rendered PDF block.
- figures=false suppresses embedding/capture copies, not a user's own
  savefig output and not the wrapper's noninteractive figure closing.
- A cache hit does not rerun Python. It restores only missing recorded
  workspace side effects and refuses to overwrite a modified output target.
