MARKDOWN NORMALIZER: ARCHITECTURE AND BUILD GUIDE
================================================

Purpose and scope
-----------------
This guide explains config\markdown-normalizer.lua: its runtime entry point,
the data and state it uses, the order in which its functions run, what each
function is responsible for, and how to extend and validate the filter.

The normalizer is the first Lua filter in compile.bat. It performs text-level
cleanup before Pandoc parses supported Markdown/TXT inputs, rebuilds a
combined document for multiple cleanable inputs, then applies ordered Pandoc
AST transformations. It does not execute Python or write normalized text back
to the input files.

This is a guide to the implementation, not a promise that every arbitrary
Markdown, HTML, Unicode, or LaTeX construct is recognized. Keep behavior
changes narrow, preserve warnings for meaningful removals, and verify any
change with an input that exercises its exact path.

Build and call lifecycle
------------------------
The filter is Lua source loaded by Pandoc at conversion time; it has no
separate compile or link step.

1. compile.bat checks its input paths and the required config files, changes
   the working directory to the first input's directory, and starts Pandoc.
2. Pandoc initially parses the inputs and invokes Lua filters in command-line
   order. compile.bat must list markdown-normalizer.lua before
   code-fence-runner.lua.
3. Pandoc calls this filter's top-level Pandoc(doc) callback once with its
   current Pandoc document. The callback first calls load_cleaned_input(doc).
4. For supported .md, .markdown, and .txt file sets, load_cleaned_input reads
   every original file, calls clean(raw), reparses each cleaned source with
   pandoc.read(..., CONFIG.reader), concatenates parsed blocks in input order,
   merges metadata, and returns a replacement Pandoc document.
5. If any input is stdin, is not a configured cleanable extension, or cannot
   be reopened, load_cleaned_input returns the original Pandoc document.
   Stdin and reopen failures are reported. Unsupported extensions use the
   original parse and continue through AST repairs. State is snapshotted before
   cleaning and restored on fallback, so partial changes from earlier inputs
   cannot leak into finalization.
6. Pandoc(doc) applies AST_PASSES in sequence. Each pass is a separate
   doc:walk, so later passes see changes made by earlier passes.
7. Pandoc(doc) runs FINALIZE_STEPS in sequence to add metadata and
   header-includes and print accumulated warnings.
8. If bibliography or references metadata exists, Pandoc(doc) invokes
   pandoc.utils.citeproc when the Pandoc version exposes it. It then returns
   the document to Pandoc, which proceeds to the next filter and writer.

The code returns { { Pandoc = Pandoc } }. That is Pandoc's Lua-filter
declaration for this document-level callback. The runner must remain later in
the filter chain so its CodeBlock walk receives this normalized, combined AST.

Configuration, registries, and state
------------------------------------

CONFIG
  strip_citations
    Enables the citations scrub rule. Known AI-generated marker syntax is
    removed and the removed-character count is reported.
  strip_emoji
    Enables the emoji scrub rule. Unsupported symbols are removed; selected
    check/cross/warning symbols are mapped to printable alternatives.
  keep_links
    When true, preserve Markdown Link nodes. When false, replace each Link with
    its inline content, discarding the destination.
  strip_utm
    Enables removal of recognized utm_* tracking parameters from text.
  cleanable_extensions
    Set of extensions for which original source files are re-read and fully
    cleaned: md, markdown, txt. Other input types receive AST processing only.
  reader
    The Pandoc Markdown reader extensions used to parse cleaned source:
    dollar/single-backslash TeX math, raw TeX, list continuation support, pipe
    tables, YAML metadata, fenced Divs, bare URI autolinking, and disabled
    subscript/superscript interpretation. The literal reader string is
    "markdown+tex_math_dollars+tex_math_single_backslash+raw_tex"
    .. "+lists_without_preceding_blankline+pipe_tables-yaml_metadata_block"
    .. "+fenced_divs+autolink_bare_uris-subscript-superscript".

REGISTRY
  Pure lookup data. It controls package skips; theorem/div/list/math
  environment sets; body-hoisted, dropped-preamble, and metadata commands;
  Greek and text-command names; image extensions; template-defined
  superscript characters; and Unicode code-point replacement tables for
  invisible characters, spaces, emoji, superscript, and subscript symbols.
  The table fields are SKIP_PACKAGES, THEOREMS, DIV_ENVS, BODY_HOIST,
  PREAMBLE_DROP, PREAMBLE_META, LIST_ENVS, MATH_ENVS, GREEK_CAPITALS,
  TEXT_COMMANDS, IMAGE_EXTENSIONS, TEMPLATE_DEFINED_CHARS,
  INVISIBLE_CODEPOINTS, SPACE_CODEPOINTS, EMOJI_CODEPOINTS,
  SUPERSCRIPT_LETTERS, SUPERSCRIPT_SIGNS, and SUBSCRIPT_CHARS.
  word_set(words) converts a whitespace-separated name list into a true-valued
  membership set.

Exact name-set contents in the current source
  THEOREMS:
    theorem lemma proposition corollary definition example remark
  DIV_ENVS:
    proof abstract quote, plus every name in THEOREMS.
  BODY_HOIST:
    usepackage usetikzlibrary usepgfplotslibrary usepgflibrary pgfplotsset
    tikzset newcommand providecommand DeclareRobustCommand
    NewDocumentCommand DeclareDocumentCommand DeclareMathOperator newtheorem
    newenvironment sisetup DeclarePairedDelimiter theoremstyle
  PREAMBLE_DROP:
    documentclass geometry pagestyle thispagestyle setmainfont setsansfont
    setmonofont maketitle
  PREAMBLE_META:
    title author date
  LIST_ENVS:
    itemize enumerate description
  MATH_ENVS:
    align alignat flalign equation gather multline eqnarray
  GREEK_CAPITALS:
    Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega
  TEXT_COMMANDS:
    text textrm textit textbf textsf texttt mbox hbox
  IMAGE_EXTENSIONS:
    png jpg jpeg pdf
  TEMPLATE_DEFINED_CHARS:
    U+207F (ⁿ)
  SKIP_PACKAGES:
    inputenc fontenc fontspec geometry hyperref babel polyglossia lmodern
    microtype fancyhdr parskip graphicx xcolor amsmath amssymb amsfonts
    amsthm mathtools physics braket tikz pgf pgfplots booktabs longtable
    array float caption fvextra xurl soul etoolbox newunicodechar
    unicode-math bm cancel mhchem placeins multirow calc footnotehyper
    textcomp mathrsfs bookmark color siunitx circuitikz tcolorbox algorithm
    algpseudocode chemfig subcaption listings enumitem adjustbox
    pgfplotstable tikz-cd footnote

Exact Unicode mapping inputs in the current source
  INVISIBLE_CODEPOINTS removed:
    U+200B, U+200C, U+200D, U+2060, U+FEFF, U+00AD, U+202A, U+202C,
    U+200E, U+200F.
  SPACE_CODEPOINTS replaced by ASCII space:
    U+00A0, U+202F, U+2009, U+2007, U+2002, U+2003.
  EMOJI_CODEPOINTS removed when encountered:
    U+FE0F, U+2705, U+274C, U+274E, U+26A0, U+2728, U+2B50, U+2B06,
    U+2B07, U+2757, U+2753, U+203C, plus byte sequences in the
    U+1F300..U+1F6FF range. Before this removal, ✅ becomes ✓, ❌ becomes ✗, and
    ⚠ / ⚠️ become !.
  SUPERSCRIPT_LETTERS (code point -> base):
    U+02B0 h, U+02B2 j, U+02B3 r, U+02B7 w, U+02B8 y, U+02E1 l,
    U+02E2 s, U+02E3 x, U+1D43 a, U+1D47 b, U+1D9C c, U+1D48 d,
    U+1D49 e, U+1DA0 f, U+1D4D g, U+2071 i, U+1D4F k, U+1D50 m,
    U+207F n, U+1D52 o, U+1D56 p, U+1D57 t, U+1D58 u, U+1D5B v,
    U+1DBB z.
  SUPERSCRIPT_SIGNS (math replacement):
    U+2070 0, U+00B9 1, U+00B2 2, U+00B3 3, U+2074..U+2079 4..9,
    U+207A +, U+207B -, U+207C =, U+207D (, U+207E ).
  SUBSCRIPT_CHARS (math replacement):
    U+2080..U+2089 0..9, U+208A +, U+208B -, U+208C =,
    U+208D (, U+208E ), U+2090 a, U+2091 e, U+2092 o, U+2093 x,
    U+2095 h, U+2096 k, U+2097 l, U+2098 m, U+2099 n, U+209A p,
    U+209B s, U+209C t.

State
  The only mutable per-filter-run table:
  hoisted         LaTeX lines to append to header-includes.
  extra_meta      title/author/date values rescued from a pasted full document.
  env_opts        optional arguments saved when theorem/proof-like blocks are
                  converted to fenced Divs.
  code_super      set of superscript letters found in code spans/blocks.
  super_fixes     count of AST text/math nodes changed for Unicode scripts.
  md_list_fixes   count of Markdown emphasis markers converted inside LaTeX
                  list environments.
  citation_strips count of removed citation-marker characters.
  emoji_strips    count of removed unsupported emoji characters.

Derived tables
  SUPER_LETTERS maps supported Unicode superscript letters to their base
  letters. MATH_SUP and MATH_SUB map Unicode superscript/subscript characters
  to their LaTeX math replacements. They are built once from REGISTRY.
  SCRUB_RULES, TEXT_PASSES, AST_PASSES, and FINALIZE_STEPS are ordered
  dispatch tables: each connects a stable stage name with its function and
  determines which transformations run and in what sequence. GREEK_WRAP
  maps a math-font kind to the LaTeX wrapper function for recognized Greek
  commands.
  GREEK_WRAP has exactly three entries: bf emits \boldsymbol, rm emits
  \mathnormal after removing a leading var from the Greek command name, and it
  emits \mathnormal{\var...}.

STAGE A: source text passes
---------------------------
clean(text) runs TEXT_PASSES in this exact order. For each pass, mask_literals
protects code/literal regions; the pass transforms the remaining text; the
restore closure reinstates the protected source. The sequence is deliberate:
For each individual pass, clean makes a fresh literal store and placeholder
set. A placeholder created for one pass is restored before the next pass starts;
later passes do not operate on stale placeholders.

1. scrub
   Normalize invisible and lookalike space characters; optionally remove
   citation/emoji/tracking artifacts; normalize JSON-escaped math, HTML
   leftovers, and LaTeX reference/citation ties.
2. unwrap-document
   If a pasted full LaTeX document is detected, process its preamble, extract
   supported title/author/date metadata, and retain only the document body.
3. drop-maketitle
   Remove \maketitle because the template handles document title rendering.
4. space-tables
   Insert a blank line before a Markdown pipe table when needed, without
   inserting one inside recognized display math or fenced code.
5. multiline-math
   Repair selected inline math that spans prose lines and join a list-looking
   continuation only when the open formula is clearly math and closes within
   the same paragraph.
6. hoist-commands
   Move selected LaTeX commands from body text to State.hoisted, process
   commands found in a full-document preamble, and repair one-line math.
7. markdown-in-lists
   Convert Markdown bold/italic markers inside itemize, enumerate, and
   description environments to LaTeX emphasis commands.
8. environments-to-divs
   Convert supported multi-line theorem/proof-like environments into fenced
   Divs so Pandoc parses their Markdown content. Stage B restores their
   original LaTeX environment wrappers.

Detailed Stage A call path
  load_cleaned_input -> clean(raw) -> extract_yaml_fences -> TEXT_PASSES in order.
  clean -> extract_yaml_fences -> mask_literals -> pass.apply(masked) -> restore(transformed).
  scrub -> flush prose/code chunks -> scrub_chunk -> SCRUB_RULES in order.
  pass_unwrap_document -> mask_fences for delimiter detection and, when a full
  document is recognized, process_lines(preamble, true).
  pass_hoist_body_commands -> process_lines(body, false).
  process_lines -> hoist for selected command lines; package_commands for
  usepackage; fix_math_line for body text lines that stay in the document.
  fix_multiline_math -> split_lines -> is_structural_line/is_para_boundary/
  continues_open_math for lookahead -> fix_paragraph when flushing.
  md_in_lists -> context stack -> conv -> md_emph only in recognized list
  environments.
  envs_to_divs writes Div markers into text; pandoc.read parses them; later
  div_fix replaces those marker Divs with RawBlock begin/end wrappers.

STAGE B: AST passes
-------------------
AST_PASSES is also ordered:

tables
  table_fix walks Strong nodes in each Table. strong_fix moves complex math
  out of emphasis wrappers where a LaTeX table-cell failure is likely,
  recursively splitting nested inline formatting so text before and after
  the unformatted math retains its original formatting. The caption is
  preserved unchanged.

inlines
  math_pipeline applies display-math/Greek repair, followed by Unicode
  superscript/subscript conversion.
  image_fix validates local image scheme, extension, and file existence;
  invalid images are dropped with a warning.
  link_fix preserves links or unwraps them according to CONFIG.keep_links.
  RawInline removes HTML raw content and also checks raw TeX math environments.
  str_fix converts supported superscript letters in ordinary text.
  note_code_super records characters in Code and CodeBlock nodes for later
  preamble definitions without changing the displayed code.

blocks
  Figure removes a Figure that has no surviving Image.
  RawBlock removes HTML raw content and checks raw TeX math environments.
  Div div_fix recognizes this filter's lenv marker and rebuilds the matching
  LaTeX environment around the already-parsed Div contents.

Detailed AST call path
  Pandoc(doc) -> load_cleaned_input(doc) -> for each AST_PASSES row:
  doc:walk(pass.filter) -> finalizers -> optional citeproc -> return document.
  Within the inline walk, Math calls math_pipeline, which calls math_fix and
  then math_super on the changed or original element. RawInline tries
  raw_html_fix first and only calls rawblock_super if the element was not
  removed. The block walk applies the corresponding RawBlock sequence.
  table_fix owns an additional walk over the table's descendants; it saves and
  restores the caption because table content repair must not change it.
  Figure repair happens after inline Image validation so it can observe images
  removed by the earlier pass.

STAGE C: finalization
---------------------
FINALIZE_STEPS order matters because earlier steps can append to
State.hoisted:

1. define_code_superscripts adds \newunicodechar preamble declarations for
   superscript letters observed in code, excluding characters already defined
   by the template.
2. report_super_fixes prints the accumulated text/formula script-conversion
   count when nonzero.
3. report_scrub_counts prints citation and emoji removal totals when nonzero.
4. apply_page_layout maps the supported YAML `page-layout: presentation`
   preset to the template flag; unsupported values warn and retain A4.
5. apply_title_rule maps YAML boolean `title-rule` to the template flag,
   defaulting to true and warning on non-boolean values.
6. apply_extra_meta fills missing title/author/date metadata from a pasted
   full-document preamble; existing Pandoc metadata takes precedence.
7. inject_header_includes appends accumulated LaTeX to header-includes and
   reports the number of hoisted lines.

Function reference: utilities and text stage
--------------------------------------------
The signatures below describe the Lua values passed and returned. Functions
are local to the filter file unless identified as Pandoc(doc). In callbacks,
returning nil means "leave this AST element unchanged"; returning a node,
sequence, or empty sequence replaces or removes it according to Pandoc's walk
contract.

Configuration and utilities
  word_set(words) -> set
    Splits names on whitespace to build a boolean lookup table used by
    REGISTRY. Called while constructing registry tables.
  U(codepoint) -> UTF-8 string
    Encodes a Unicode code point with utf8.char. Used by scrubbing and derived
    character maps.
  warn(msg)
    Writes a filter-prefixed warning to stderr. Called by cleanup, AST, and
    finalization paths when behavior needs to be visible.
  each_line(text) -> iterator
    Returns lines while retaining a final empty line for newline-terminated
    input. Shared by line-oriented text passes.
  split_lines(text) -> array
    Materializes each_line into a 1-based line array. Used for look-ahead in
    multiline math repair.
  fence_mark(line, fence) -> fence run or nil
    Recognizes backtick/tilde fence openers and valid closers. While a fence is
    open, the closer must match its character, be at least as long, and have
    only whitespace after it.
  fence_next(fence, mark) -> next fence state
    Opens a fence or closes a matching one. Used by fence-aware passes.
  brace_balance(line) -> net brace count
    Counts unescaped braces while excluding comments. Used to collect
    multi-line LaTeX commands.
  drop_unless_link(src, pattern) -> text
    Removes matches unless followed by "(", preserving source-like labels
    that are actually Markdown link text.
  group_end(text, opening_brace_index) -> index or nil
    Finds the byte immediately after the matching closing brace, skipping
    escaped characters. Used to parse nested LaTeX groups.
  file_exists(path) -> boolean
    Opens a path in binary mode to verify local image existence.

Scrub rules (called in SCRUB_RULES order by scrub_chunk)
  rule_invisible_chars(text) -> text
    Deletes configured invisible code points.
  rule_space_lookalikes(text) -> text
    Replaces configured Unicode spacing characters with ASCII spaces and
    normalizes the non-breaking hyphen.
  rule_citations(text) -> text
    Removes recognized citation artifacts, preserves matching Markdown links,
    and increments State.citation_strips.
  rule_emoji(text) -> text
    Maps selected check/cross/warning characters, strips configured emoji, and
    increments State.emoji_strips for removals.
  rule_utm(text) -> text
    Removes supported utm_* query parameters while preserving adjacent query
    parameters where possible.
  rule_json_escaped_math(text) -> text
    Reduces doubled JSON escapes for math delimiters but keeps recognized
    LaTeX spacing forms such as \\[2mm].
  rule_html_leftovers(text) -> text
    Converts sub/sup tags to text-script commands and <br> to \newline.
  rule_latex_ties(text) -> text
    Converts a bare tilde before supported reference/citation commands to a
    LaTeX nonbreaking space.
  scrub_chunk(text) -> text
    Applies enabled SCRUB_RULES to one prose chunk.
  scrub(text) -> text
    Normalizes BOM/newlines, chunks at fences, and scrubs only prose. Its local
    flush(is_code) closure emits code unchanged and sends prose to scrub_chunk.
  mask_fences(text) -> text
    Replaces backslashes within fenced code with a sentinel so searches for
    full-document delimiters ignore code examples. Used by
    pass_unwrap_document.

Math and LaTeX text repair
  fix_math_line(line) -> line
    Handles same-line dollar math, escaped NotebookLM math, trims clearly
    mathematical inner whitespace, and escapes table-cell vertical bars.
    Its local unescape(inner) closure rejects currency-like contents lacking
    math markers.
  fix_paragraph(text) -> text
    Scans a paragraph with multiple lines and repairs clearly mathematical
    single-dollar delimiters. It skips escapes, exact-length code spans, and
    display math, and uses neighboring characters/math markers to distinguish
    obvious currency.
  open_math(text) -> closer or nil
    Reports an unmatched inline/display math delimiter at the end of text.
    Skips code spans and escaped characters.
  single_dollar_positions(text) -> positions
    Returns unescaped single-dollar positions outside code spans and display
    math. Used to decide whether a list-looking line continues a formula.
  is_structural_line(line) -> boolean
    Identifies blank lines, pipe-table rows, headings, LaTeX begin/end lines,
    and literal-mask markers.
  is_para_boundary(line) -> boolean
    Adds a code-fence opener to the structural paragraph-boundary conditions.
  continues_open_math(text, lines, start_index) -> boolean
    Looks ahead within the paragraph to see whether an open formula closes;
    for single-dollar math it additionally requires clear math syntax before
    treating a list-looking line as continuation.
  fix_multiline_math(text) -> text
    Groups paragraph lines, protects block boundaries/fences/indented code,
    invokes fix_paragraph on each group, and reports joined list-looking
    continuation lines. Its local flush() commits the current paragraph.

Preamble collection and structural text
  package_commands(block) -> command list or nil
    Parses one or more usepackage commands with optional arguments, skips
    packages already managed by the template, and returns retained requests.
    Nil means malformed syntax, so the caller can leave the original in place.
  hoist(block, in_preamble) -> consumed boolean
    Decides whether a LaTeX command should be dropped, mapped to metadata,
    skipped as template-defined, retained in the body, or appended to
    State.hoisted. Converts body \newcommand to \DeclareRobustCommand.
  process_lines(text, in_preamble) -> text
    Line-scans body or full-document preamble outside fences. Collects
    multi-line commands using brace_balance; avoids moving commands from inside
    tikzpicture; calls hoist and fix_math_line. Preamble prose/comment policy
    differs from body handling.
  is_table_row(line) -> boolean
    Recognizes a pipe-table-shaped line for space_tables.
  space_tables(text) -> text
    Adds a separating blank line before pipe tables outside code fences and
    display math.
  md_emph(segment) -> segment
    In a LaTeX list body, converts valid **bold** and *italic* markers to
    \textbf and \emph. A local stash function protects math and escaped
    markers during matching; State.md_list_fixes tracks conversions.
  md_in_lists(text) -> text
    Tracks nested LaTeX list environments and applies md_emph only while the
    innermost environment is itemize/enumerate/description. Its local conv
    closure applies the context-sensitive conversion; comments and fences are
    preserved.
  envs_to_divs(text) -> text
    Converts supported multi-line environments into fenced Div syntax and
    stores each optional argument in State.env_opts. The Div carries lenv and
    lopt attributes consumed later by div_fix.
  pass_unwrap_document(text) -> text
    Detects a pasted full document only when documentclass precedes
    begin{document} and a later end{document} exists. Calls process_lines on
    the preamble, warns about non-whitespace tail text, and keeps the body.
  pass_drop_maketitle(text) -> text
    Removes body occurrences of \maketitle.
  pass_hoist_body_commands(text) -> text
    Calls process_lines in body mode.
  mask_inline_code(text, store) -> masked text
    Stashes backtick code spans with matching tick lengths and unescaped
    delimiters; appends source spans to the shared store.
  is_yaml_metadata_opener(line) -> run string or nil, is_yaml boolean
    Checks whether a code fence opener specifies yaml or {.yaml} language
    tagging while filtering out blocks marked with run=false or run="false".
  extract_yaml_fences(text) -> normalized source, meta table
    Extracts fenced YAML metadata blocks (```yaml ... ``` or ~~~yaml ... ~~~)
    into a document metadata table prior to literal masking, while removing
    the block from body text. Traditional `--- ... ---` blocks are deliberately
    ignored as metadata. Preserves verbatim YAML code listings marked with run=false.
  normalize_fence_attributes(text) -> normalized source
    Scans code fence openers and normalizes space-separated attributes lacking
    braces (e.g., ```c run=false or ```java trusted=true) to standard Pandoc
    braced attribute syntax (e.g., ```{.c run=false}), ensuring universal
    attribute parsing across all languages.
  mask_literals(text) -> masked text, restore function
    Stashes fenced code, indented code, selected verbatim/listing environments,
    and inline code while leaving prose transformable. Local stash,
    flush_prose, and flush_block closures manage segments. The returned restore
    closure substitutes the original literal strings back into processed text.
  clean(text) -> normalized source, meta table
    Removes leading BOM, normalizes newlines, extracts fenced YAML metadata
    via extract_yaml_fences, normalizes fence attributes via normalize_fence_attributes,
    warns about malformed/unclosed fences, then runs each TEXT_PASSES entry with
    a fresh literal mask/restore cycle. Called once for each cleanable input file.

Function reference: AST and finalization
----------------------------------------
Math and Unicode
  wrap_greek(inner, kind) -> LaTeX text
    Wraps recognized capital Greek commands in the appropriate bold/upright/
    italic math command when nested inside selected math font groups.
  convert(text, kind) -> text
    Recursively scans balanced \mathbf/\mathrm/\mathit groups, transforms
    supported Greek commands, and leaves other or unbalanced groups alone.
    Its local seg closure applies the current font context to plain segments.
  bold_greek(text) -> text
    Fast-paths text without \math and otherwise calls convert at top level.
  math_fix(Math element) -> replacement or nil
    Applies bold Greek repair and converts selected display-math environments
    (align/equation-family) to raw LaTeX so they are not nested in \[...\].
  str_fix(Str element) -> inline sequence or nil
    Converts supported Unicode superscript letters in ordinary text to
    \textsuperscript. Its local flush closure emits uninterrupted ordinary
    text segments; increments State.super_fixes.
  to_scripts(text, textmode) -> replacement, changed boolean
    Converts contiguous Unicode superscript/subscript runs to grouped math
    scripts, or text-script commands in text mode. Its local flush closure
    groups runs and avoids double scripts with an empty group when needed.
  scripts_in_math(text) -> replacement, changed boolean
    Splits supported text commands (for example \text and \mbox), then calls
    to_scripts in math or text mode as appropriate. Its local add closure
    accumulates converted segments.
  math_super(Math or RawInline) -> replacement or nil
    Applies scripts_in_math and reconstructs the corresponding Pandoc element
    only when a conversion occurred.
  rawblock_super(RawBlock/RawInline) -> replacement or nil
    Handles recognized raw TeX math environments in either block or inline
    form, preserving element format and shape.
  note_code_super(Code/CodeBlock) -> nil
    Records supported superscript letters in code for later LaTeX declarations;
    deliberately does not change code text.
  math_pipeline(element) -> replacement or nil
    Runs math_fix first, then math_super on the repaired result if any. This
    ordering lets script conversion see repaired mathematical environments.

Images, tables, links, environments
  image_fix(Image) -> empty sequence or nil
    Rejects remote/sandbox schemes, unsupported extensions, and missing local
    files; warns with the reason. Valid local PNG/JPG/JPEG/PDF images remain.
  figure_fix(Figure) -> empty sequence or nil
    Walks the Figure for a surviving Image and removes an empty Figure.
  raw_html_fix(RawBlock/RawInline) -> empty sequence or nil
    Removes raw HTML nodes; leaves non-HTML raw formats unchanged.
  link_fix(Link) -> content or nil
    Returns Link content when CONFIG.keep_links is false; otherwise leaves the
    Link unchanged.
  bad_math(math_text) -> boolean
    Detects alignment/environment constructs that must not remain nested in a
    formatting wrapper in a table cell.
  inline_with_content(inline, content) -> inline
    Rebuilds supported inline containers with replacement children while
    preserving their attributes, citations, quote type, or link/image target.
  split_bad_math(inline) -> formatting-tagged inline pieces
    Recursively divides inline containers around problematic Math nodes,
    retaining wrappers on surrounding text and emitting problematic math
    without formatting wrappers.
  strong_fix(Strong) -> replacement or nil
    Uses split_bad_math to move problematic math out of the Strong wrapper,
    while rebuilding unaffected runs as Strong and preserving nested inline
    formatting on adjacent text. Its local flush closure emits each Strong run.
  table_fix(Table) -> Table
    Applies strong_fix to table descendants and restores the original caption.
  div_fix(Div) -> blocks or nil
    Rebuilds begin/end LaTeX blocks for a Div bearing this filter's lenv marker,
    restoring the saved optional argument referenced by lopt.

Document-level processing and finalization
  define_code_superscripts()
    Sorts State.code_super and appends \usepackage{newunicodechar} and
    declarations to State.hoisted for characters not already template-defined.
  report_super_fixes()
    Writes a summary warning when State.super_fixes is nonzero.
  report_scrub_counts()
    Writes citation and emoji removal summaries when their counters are
    nonzero.
  apply_page_layout(doc)
    Maps the supported `page-layout: presentation` YAML value to the template
    flag; other supplied values warn and leave the default A4 layout active.
  apply_title_rule(doc)
    Maps YAML boolean `title-rule` to the template flag, defaulting to true;
    non-boolean values warn and retain the visible title rule.
  apply_extra_meta(doc)
    Adds rescued title/author/date values only when the document metadata key
    is absent.
  inject_header_includes(doc)
    Appends a RawBlock of State.hoisted lines to the existing header-includes,
    preserving existing metadata as a MetaList.
  load_cleaned_input(doc) -> Pandoc document
    Coordinates source reading, extension checks, clean, reparsing, block
    concatenation, and YAML/Pandoc metadata merge. Snapshots and restores State
    when an unsupported or unreopenable input requires the original-doc fallback.
  Pandoc(doc) -> Pandoc document
    The actual Pandoc callback. Calls load_cleaned_input, walks AST_PASSES in
    order, applies FINALIZE_STEPS, conditionally runs citeproc, and returns the
    result to Pandoc.

Inline callbacks not named as standalone functions
--------------------------------------------------
Several small functions exist only inside their parent and should stay there
unless a real reuse case appears:
The inventory below describes their complete purpose and owner:

  drop_unless_link's gsub callback(pos)
    Checks the byte immediately following each match. It returns nil to keep
    a match when it is a Markdown link label followed by "(", otherwise returns
    an empty string to remove it.
  rule_json_escaped_math's gsub callback(pos)
    Examines the next 61 bytes. It preserves doubled backslashes that
    introduce a LaTeX line-break spacing amount or recognized length command;
    otherwise it emits a single-backslash display-math opener.
  scrub.flush(is_code)
    Flushes the line buffer. Code is appended as-is; prose is sent through
    scrub_chunk. Owned by scrub because it closes over the line buffer.
  fix_math_line.unescape(inner)
    Refuses to unescape a currency-like string without a math marker; otherwise
    removes selected escaping and returns the math body. Two gsub callbacks
    call it for escaped single- and double-dollar pairs.
  fix_multiline_math.flush()
    Sends the accumulated paragraph to fix_paragraph and clears the paragraph
    array. Called at structural boundaries, before fences, and at end of input.
  md_emph.stash(match)
    Saves protected math/escape fragments in keep and returns a numbered
    sentinel. The bold and italic gsub callbacks validate delimiter context,
    increment State.md_list_fixes on conversion, and emit \textbf/\emph.
    A final gsub callback restores sentinels from keep.
  md_in_lists.conv(segment)
    Applies md_emph only when the innermost stack entry is a configured list
    environment. It closes over the environment stack.
  mask_literals.stash(value)
    Adds a literal string to the shared store and returns its numbered
    placeholder.
  mask_literals.flush_prose()
    Joins pending prose, masks its inline code with mask_inline_code, and
    appends the transformed prose segment.
  mask_literals.flush_block()
    Flushes preceding prose and stashes the accumulated fenced/verbatim block.
  mask_literals.restore(value) and its gsub callback
    Replaces each generated placeholder with the matching original stored
    literal. The restore closure is returned by mask_literals to clean.
  GREEK_WRAP.bf/rm/it(name)
    Function-valued table entries that build bold, upright, and italic math
    wrappers for recognized Greek commands. Called by wrap_greek.
  convert.seg(text)
    Applies wrap_greek to a segment using the current recursive font kind, or
    returns it unchanged at top level.
  str_fix.flush()
    Emits buffered ordinary Unicode text as a Pandoc Str before a converted
    superscript RawInline and at end of the source string.
  to_scripts.flush()
    Emits pending superscript/subscript runs as text or math syntax, tracks
    whether a conversion happened, and inserts an empty group when needed to
    avoid extending an existing script.
  scripts_in_math.add(piece, textmode)
    Calls to_scripts and accumulates the returned text and changed flag.
  figure_fix's Image callback
    Sets a local boolean while walking the Figure. The parent removes the
    Figure if no Image remains.
  split_bad_math's group accumulator
    Coalesces adjacent pieces with the same bold state before rebuilding their
    inline containers, avoiding unnecessary wrapper fragments.
  strong_fix.flush()
    Emits the accumulated unaffected inline run as a Strong node before a
    problematic Math node, and emits any trailing run after it.
  AST_PASSES RawInline and RawBlock callbacks
    Short-circuit: remove HTML first; if it is not HTML, inspect recognized
    raw TeX math environments for Unicode script conversion.
  Pandoc's CodeBlock callback
    Captures the document-local preamble array and delegates each code block
    to process_code_block in the later filter.

These closures share local context such as source positions, a stash array,
an AST-node flag, or an output buffer. Preserve their lexical ownership and
their caller's nil/replacement semantics when editing them.

Step-by-step change and validation guide
----------------------------------------
1. Establish the exact behavior to change and the expected input/output. Inspect
   git status first; do not overwrite unrelated work.
2. Locate the owning stage:
     user setting / supported names       CONFIG or REGISTRY
     prose artifact scrub                  rule_* plus SCRUB_RULES
     complete text transformation         pass_* plus TEXT_PASSES
     AST node transformation               handler plus AST_PASSES
     counters / collected values           State
     header or rescued metadata            finalizer and State
     input selection/reparse               load_cleaned_input
3. Read the owner and its callers. These are local Lua functions; their order
   matters because local definitions are not hoisted. Define helpers above
   their first use.
4. Make the smallest general change at the source of the behavior. Preserve
   fenced/indented/inline code protection, existing metadata precedence,
   filter order, and explicit warnings for dropped or transformed content.
5. For a scrub rule, add the function and its row to SCRUB_RULES; add a CONFIG
   flag only if users need to enable/disable it. For a whole-text pass, add a
   single-purpose function and an ordered TEXT_PASSES row, documenting any
   dependency on prior/next passes. For an AST handler, add it to the correct
   element-type map in AST_PASSES, not to an unrelated traversal.
6. Create a small trusted .txt/.md case for the changed behavior. Exercise the
   real Pandoc parse/filter chain. From the repository root, an AST-level
   check can be run with:

     pandoc --from=markdown+yaml_metadata_block --to=native --lua-filter="config\markdown-normalizer.lua" "path\to\focused.txt"

   For mixed-input fallback, pass two cleanable `.txt` inputs followed by an
   unsupported input such as `.html`; check that no state collected from the
   text files leaks into the original Pandoc parse or its finalization.

   This one-line form works in PowerShell and Command Prompt. The native output
   is useful for checking Pandoc structure; also verify stderr warnings when
   warning counts/removals matter.
7. For integration/PDF output, invoke the actual wrapper with the focused file:

     .\compile.bat "path\to\focused.txt"

   This loads both filters in their required order and invokes XeLaTeX. Inspect
   the resulting PDF content and console output, not merely the exit code.
8. When the change affects supported behavior, update the lasting regression
   fixture and run it when the affected paths warrant full integration. The
   broad fixture includes intentional Python errors; follow its expected
   results rather than interpreting those deliberate errors as an unexpected
   build failure.
9. Run git diff --check; inspect the final source and documentation diffs. Do not
   include cache, temporary build files, or unrelated generated/user files.

Important invariants
--------------------
- This filter runs before code-fence-runner.lua. Never reverse that order.
- Text cleaning is performed on re-read source only for extensions listed in
  CONFIG.cleanable_extensions. Other inputs still receive AST passes.
- Input files are never rewritten. Multi-input block order follows
  PANDOC_STATE.input_files.
- The first cleaned YAML value is retained; later cleaned YAML fills missing
  keys; Pandoc's aggregate metadata overlays the combined cleaned metadata.
- TEXT_PASSES, AST_PASSES, and FINALIZE_STEPS are explicit ordered registries.
  Do not bypass these lists with hidden ordering in unrelated functions.
- Keep mutable counters and collected values in State. Call warn for
  consequential cleanup or unsupported content; do not silently drop it.
- The recognizers are intentionally partial. Avoid broad regex rewrites that
  could alter code, math, comments, or unrelated LaTeX.
- The Lua source ends with a commented frozen-sample regression recipe using
  sample.md, sample.tex, and sample.warnings.txt. It is not an automatically
  run test; confirm those sample/golden files are available before using that
  particular recipe. The repository's manual regression fixture is a separate
  end-to-end check.
