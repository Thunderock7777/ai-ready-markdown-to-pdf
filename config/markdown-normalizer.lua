-- ======================================================================
--  markdown-normalizer.lua  --  Markdown/LaTeX cleanup -> publication-quality LaTeX
--
--  One .md / .txt file may freely mix Markdown and LaTeX:
--      $x$   $$..$$   \( .. \)   \[ .. \]   \begin{align}..\end{align}
--      \section{..}   \begin{tikzpicture}..   \usepackage{..}  ...
--  Works for text pasted from ChatGPT, Gemini, Claude, NotebookLM, etc.
--
--  The input file is NEVER modified.
--  Anything the filter drops or cannot do is reported on stderr as [markdown-normalizer] ...
-- ======================================================================
--
--  ARCHITECTURE
--  ------------
--  The filter is the document-normalization stage in the compiler pipeline.
--  It re-reads every Markdown/TXT source listed by Pandoc, cleans and parses
--  each source, concatenates their blocks in argument order, then repairs the
--  combined AST while preserving YAML/CLI metadata.  Other input types are
--  not re-read; they receive AST fixes only.  Every transformation stage below
--  is a LIST of small, named, single-purpose steps; the list is the only place
--  that decides what runs and in which order.
--
--      ordered input files
--         |
--         v
--   STAGE A  TEXT PASSES   (each source string -> cleaned source string)
--         |                 literal masking -> scrub -> structure/math repair ->
--         |                 preamble hoisting -> Markdown normalization
--         v
--   pandoc.read(...)       (Markdown + raw TeX; CONFIG.reader)
--         |
--         v
--   ordered block concatenation + metadata merge
--         |
--         v
--   STAGE B  AST PASSES    (combined Pandoc AST -> Pandoc AST)
--         |                 tables -> inline fixes -> block fixes
--         v
--   STAGE C  FINALIZE      (metadata, header-includes, summary warnings)
--         |
--         v
--   citeproc (after reparsing/cleaning, when bibliography metadata exists)
--         |
--         v
--   code-fence-runner.lua executes/renders code blocks -> Pandoc writes LaTeX
--
--  Metadata merge: cleaned YAML maps are combined in input order (first value
--  retained; later sources fill missing keys), then Pandoc's aggregate metadata
--  overlays that map.  This preserves Pandoc's multi-input YAML precedence and
--  CLI overrides; conflicting YAML keys therefore follow Pandoc's aggregate
--  result, not necessarily the first cleaned value.  Text blocks retain input
--  argument order.
--
--  FILE LAYOUT  (search for the "§" marker to jump between sections)
--  ----------------------------------------------------------------
--   §1  CONFIG            user-facing switches and the reader string
--   §2  REGISTRY          every lookup table / list of names (pure data)
--   §3  STATE             all mutable run-time state, in ONE table
--   §4  UTILITIES         logging, line iteration, fences, small helpers
--   §5  STAGE A           text passes
--         5.1 scrub rules        5.4 hoisting of preamble commands
--         5.2 fence masking      5.5 structural rewrites
--         5.3 math repair        5.6 text pipeline (TEXT_PASSES)
--   §6  STAGE B           AST passes
--         6.1 math               6.4 images / links / raw html
--         6.2 unicode scripts    6.5 tables / divs
--         6.3 code characters    6.6 AST pipeline (AST_PASSES)
--   §7  STAGE C           finalize
--   §8  ENTRY POINT       Pandoc() and the filter return value
--
--  HOW TO CHANGE THINGS  (follow the recipe, touch nothing else)
--  --------------------------------------------------------------
--   Turn a behaviour on/off ........ edit its flag in §1 CONFIG.
--   Stop a package being re-loaded .. add its name to REGISTRY.SKIP_PACKAGES.
--   Hoist another body command ...... add it to REGISTRY.BODY_HOIST.
--   Drop another preamble command ... add it to REGISTRY.PREAMBLE_DROP.
--   Treat an environment as Markdown  add it to REGISTRY.DIV_ENVS.
--   New text-cleaning rule .......... write `local function rule_xxx(text)`
--                                     in §5.1 and add a row to SCRUB_RULES.
--   New whole-text pass ............. write `local function pass_xxx(text)`
--                                     (string in, string out) and add a row
--                                     to TEXT_PASSES in §5.6.
--   New AST fix ..................... write the handler in §6.x and add it
--                                     to the matching filter in AST_PASSES.
--   New counter / collected data .... declare it in §3 STATE, never as a
--                                     loose file-level variable.
--
--  RULES THAT KEEP IT SAFE
--  -----------------------
--   R1  Text passes are pure `string -> string` and never touch fenced
--       code (use fence_mark / fence_next from §4).
--   R2  Data lives in §2, state lives in §3, logic lives in §4-§7.
--   R3  Anything dropped or rewritten in a way the user could not predict
--       must call warn(); silent loss of content is a bug.
--   R4  A function is defined ABOVE the first function that uses it
--       (Lua locals are not hoisted); §-order already guarantees this.
--   R5  After any change run the regression check at the bottom of this file.
-- ======================================================================


-- ======================================================================
-- §1  CONFIG  --  the only section a casual user should edit
-- ======================================================================
local CONFIG = {
  strip_citations = true,   -- [cite_start], [cite: 3], ChatGPT's private-use cite markers, 【..】
  strip_emoji     = true,   -- emoji / dingbats the fonts cannot print
  keep_links      = true,   -- false = keep only the link text
  strip_utm       = true,   -- remove ?utm_source=chatgpt.com style tracking from URLs

  -- Input extensions that get the full text cleaning.  Any other input type
  -- only receives the AST fixes of Stage B.
  cleanable_extensions = { md = true, txt = true, markdown = true },

  -- Reader used for the real parse.  tex_math_single_backslash gives \( \) and \[ \]
  -- natively; lists_without_preceding_blankline fixes AI lists glued to a paragraph;
  -- subscript/superscript are OFF so a stray ~ or ^ in prose is never reinterpreted.
  reader = "markdown+tex_math_dollars+tex_math_single_backslash+raw_tex"
        .. "+lists_without_preceding_blankline+pipe_tables+yaml_metadata_block"
        .. "+fenced_divs+autolink_bare_uris-subscript-superscript",
}


-- ======================================================================
-- §2  REGISTRY  --  lookup tables and name lists (pure data, no logic)
-- ======================================================================

-- Build a set from a whitespace-separated list of words.
local function word_set(words)
  local set = {}
  for w in words:gmatch("%S+") do set[w] = true end
  return set
end

local REGISTRY = {}

-- Packages already loaded (or deliberately controlled) by config/custom.tex.
-- A second \usepackage[options]{..} of these would cause "option clash" errors.
-- (mathrsfs is loaded by the template; braket is skipped because physics clashes
--  with it, the template defines \Bra \Ket \Braket \set \Set itself.)
REGISTRY.SKIP_PACKAGES = word_set([[
  inputenc fontenc fontspec geometry hyperref babel polyglossia lmodern microtype
  fancyhdr parskip graphicx xcolor amsmath amssymb amsfonts amsthm mathtools physics braket
  tikz pgf pgfplots booktabs longtable array float caption fvextra xurl soul etoolbox
  newunicodechar unicode-math bm cancel mhchem placeins multirow calc footnotehyper
  textcomp mathrsfs bookmark color siunitx circuitikz tcolorbox algorithm algpseudocode
  chemfig subcaption listings enumitem adjustbox pgfplotstable tikz-cd footnote
]])

-- Theorem-like environments (defined by the template, so \newtheorem of them is dropped).
REGISTRY.THEOREMS = word_set("theorem lemma proposition corollary definition example remark")

-- Environments whose body should still be parsed as Markdown (**bold**, lists, $math$ ...).
-- A bare \begin{theorem}..\end{theorem} is otherwise passed through as one raw LaTeX block.
REGISTRY.DIV_ENVS = word_set("proof abstract quote")
for name in pairs(REGISTRY.THEOREMS) do REGISTRY.DIV_ENVS[name] = true end

-- Commands that are moved to the LaTeX preamble when found in the BODY.
REGISTRY.BODY_HOIST = word_set([[
  usepackage usetikzlibrary usepgfplotslibrary usepgflibrary pgfplotsset tikzset
  newcommand providecommand DeclareRobustCommand NewDocumentCommand DeclareDocumentCommand
  DeclareMathOperator newtheorem newenvironment sisetup DeclarePairedDelimiter
  theoremstyle
]])

-- Commands of a pasted full document's preamble that are discarded (the template owns them).
REGISTRY.PREAMBLE_DROP = word_set([[
  documentclass geometry pagestyle thispagestyle setmainfont setsansfont setmonofont maketitle
]])

-- Metadata commands of a pasted preamble that are kept as pandoc metadata.
REGISTRY.PREAMBLE_META = word_set("title author date")

-- Environments whose emphasis marks are converted (see md_in_lists).
REGISTRY.LIST_ENVS = word_set("itemize enumerate description")

-- Math environments that must be emitted as themselves, not wrapped in \[ .. \].
REGISTRY.MATH_ENVS = word_set("align alignat flalign equation gather multline eqnarray")

-- Capital Greek letters that need protection inside \mathbf / \mathrm / \mathit.
REGISTRY.GREEK_CAPITALS = word_set("Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega")

-- Text-mode commands: Unicode scripts inside them become \textsuperscript / \textsubscript.
REGISTRY.TEXT_COMMANDS = word_set("text textrm textit textbf textsf texttt mbox hbox")

-- Image types LaTeX can include.
REGISTRY.IMAGE_EXTENSIONS = word_set("png jpg jpeg pdf")

-- Characters config/custom.tex already defines (no \newunicodechar needed for them).
REGISTRY.TEMPLATE_DEFINED_CHARS = { [utf8.char(0x207F)] = true }   -- ⁿ

-- Code points removed outright.
REGISTRY.INVISIBLE_CODEPOINTS = {
  0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD, 0x202A, 0x202C, 0x200E, 0x200F,
}

-- Code points replaced by an ordinary space.
REGISTRY.SPACE_CODEPOINTS = { 0x00A0, 0x202F, 0x2009, 0x2007, 0x2002, 0x2003 }

-- Emoji / dingbat code points outside the U+1F300..1FAFF block handled by a byte pattern.
REGISTRY.EMOJI_CODEPOINTS = {
  0xFE0F, 0x2705, 0x274C, 0x274E, 0x26A0, 0x2728, 0x2B50, 0x2B06, 0x2B07, 0x2757, 0x2753, 0x203C,
}

-- Unicode superscript LETTERS (pˢ  mⁿ  xʸ ...), missing from Latin Modern.  code point -> base letter
REGISTRY.SUPERSCRIPT_LETTERS = {
  [0x02B0]="h", [0x02B2]="j", [0x02B3]="r", [0x02B7]="w", [0x02B8]="y", [0x02E1]="l",
  [0x02E2]="s", [0x02E3]="x", [0x1D43]="a", [0x1D47]="b", [0x1D9C]="c", [0x1D48]="d",
  [0x1D49]="e", [0x1DA0]="f", [0x1D4D]="g", [0x2071]="i", [0x1D4F]="k", [0x1D50]="m",
  [0x207F]="n", [0x1D52]="o", [0x1D56]="p", [0x1D57]="t", [0x1D58]="u", [0x1D5B]="v",
  [0x1DBB]="z",
}

-- Unicode superscript digits / signs (math only).  code point -> replacement
REGISTRY.SUPERSCRIPT_SIGNS = {
  [0x2070]="0", [0x00B9]="1", [0x00B2]="2", [0x00B3]="3", [0x2074]="4",
  [0x2075]="5", [0x2076]="6", [0x2077]="7", [0x2078]="8", [0x2079]="9", [0x207A]="+",
  [0x207B]="-", [0x207C]="=", [0x207D]="(", [0x207E]=")",
}

-- Unicode subscript digits / signs / letters (math only).  code point -> replacement
REGISTRY.SUBSCRIPT_CHARS = {
  [0x2080]="0", [0x2081]="1", [0x2082]="2", [0x2083]="3", [0x2084]="4",
  [0x2085]="5", [0x2086]="6", [0x2087]="7", [0x2088]="8", [0x2089]="9", [0x208A]="+",
  [0x208B]="-", [0x208C]="=", [0x208D]="(", [0x208E]=")", [0x2090]="a", [0x2091]="e",
  [0x2092]="o", [0x2093]="x", [0x2095]="h", [0x2096]="k", [0x2097]="l", [0x2098]="m",
  [0x2099]="n", [0x209A]="p", [0x209B]="s", [0x209C]="t",
}


-- ======================================================================
-- §3  STATE  --  every piece of mutable run-time state lives here
-- ======================================================================
local State = {
  hoisted       = {},   -- lines that must live in the LaTeX preamble
  extra_meta    = {},   -- title / author / date taken from a pasted full document
  env_opts      = {},   -- optional [..] argument of environments that became Divs
  code_super    = {},   -- superscript letters that occur inside code (set of chars)
  super_fixes   = 0,    -- count: Unicode super/subscript conversions
  md_list_fixes = 0,    -- count: Markdown emphasis marks converted inside lists
  citation_strips = 0, -- count: AI citation markers removed
  emoji_strips   = 0,  -- count: unsupported emoji removed
}


-- ======================================================================
-- §4  UTILITIES
-- ======================================================================
local function U(codepoint) return utf8.char(codepoint) end

local function warn(msg) io.stderr:write("[markdown-normalizer] " .. msg .. "\n") end

-- Iterate over the lines of `text` (a trailing "\n" yields a final empty line).
local function each_line(text) return (text .. "\n"):gmatch("(.-)\n") end

local function split_lines(text)
  local lines = {}
  for line in each_line(text) do lines[#lines + 1] = line end
  return lines
end

-- Code fences ------------------------------------------------------------
-- When no fence is open, recognize a valid opener and retain its full length.
-- While inside a fence, recognize only a same-character closing run at least
-- as long as the opener, followed by whitespace only.
local function fence_mark(line, fence)
  local run, rest = line:match("^%s*(```+)(.*)$")
  local ch = "`"
  if not run then run, rest = line:match("^%s*(~~~+)(.*)$"); ch = "~" end
  if not run then return nil end
  if fence then
    if run:sub(1, 1) == fence:sub(1, 1) and #run >= #fence and not rest:match("%S") then
      return run
    end
    return nil
  end
  if ch == "`" and rest:find("`", 1, true) then return nil end
  return run
end

local function fence_next(fence, mark)
  if not mark then return fence end
  if not fence then return mark end
  if mark:sub(1, 1) == fence:sub(1, 1) and #mark >= #fence then return nil end
  return fence
end

-- Brace balance of one line.  Escaped characters (\{ \} \\ \%) and comments are ignored,
-- otherwise  \newcommand{\lb}{\{}  looks unbalanced and swallows the rest of the document.
local function brace_balance(s)
  s = s:gsub("\\.", "")
  s = s:gsub("%%.*$", "")
  local o = select(2, s:gsub("{", ""))
  local c = select(2, s:gsub("}", ""))
  return o - c
end

-- Delete every match of `pat` unless it is directly followed by "(" (i.e. it is the
-- text of a Markdown link such as [source code](url), which must stay intact).
local function drop_unless_link(src, pat)
  return (src:gsub(pat .. "()", function(pos)
    if src:sub(pos, pos) == "(" then return nil end
    return ""
  end))
end

-- index just after the "}" that closes the "{" at position b (nil if unbalanced)
local function group_end(s, b)
  local depth, i = 1, b + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then i = i + 1
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then depth = depth - 1; if depth == 0 then return i + 1 end end
    i = i + 1
  end
  return nil
end

local function file_exists(path)
  local fh = io.open(path, "rb")
  if fh then fh:close(); return true end
  return false
end

-- Lookup tables derived from the REGISTRY (built once, read-only afterwards).
local SUPER_LETTERS = {}   -- char -> base letter     (text AND math)
for cp, base in pairs(REGISTRY.SUPERSCRIPT_LETTERS) do SUPER_LETTERS[U(cp)] = base end

local MATH_SUP, MATH_SUB = {}, {}   -- char -> replacement, used inside math
for ch, base in pairs(SUPER_LETTERS) do MATH_SUP[ch] = base end
for cp, base in pairs(REGISTRY.SUPERSCRIPT_SIGNS) do MATH_SUP[U(cp)] = base end
for cp, base in pairs(REGISTRY.SUBSCRIPT_CHARS)   do MATH_SUB[U(cp)] = base end


-- ======================================================================
-- §5  STAGE A  --  TEXT PASSES  (string -> string, before pandoc parses)
-- ======================================================================

-- ----------------------------------------------------------------------
-- §5.1  Scrub rules: invisible characters, emoji, AI citation markers ...
--       Each rule is `function(text) -> text`, applied to ONE chunk of
--       prose in the order of SCRUB_RULES.  Fenced code is never passed in.
-- ----------------------------------------------------------------------
local function rule_invisible_chars(text)
  for _, cp in ipairs(REGISTRY.INVISIBLE_CODEPOINTS) do text = text:gsub(U(cp), "") end
  return text
end

local function rule_space_lookalikes(text)
  for _, cp in ipairs(REGISTRY.SPACE_CODEPOINTS) do text = text:gsub(U(cp), " ") end
  text = text:gsub(U(0x2011), "-")                      -- non-breaking hyphen
  return text
end

local function rule_citations(text)
  local original_length = utf8.len(text) or #text
  text = text:gsub(U(0xE200) .. ".-" .. U(0xE201), "")  -- ChatGPT cite blocks
  text = text:gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")    -- leftover private-use chars
  text = text:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
  text = text:gsub(U(0x3010) .. ".-" .. U(0x3011), "")  -- 【12†source】
  text = text:gsub(":contentReference%[oaicite:%d+%]{index=%d+}", "")  -- older ChatGPT
  text = text:gsub("%[cite_start%]", "")                -- Gemini / NotebookLM
  text = text:gsub("%s?%[cite:%s*[%d,%s%-]+%]", "")
  text = drop_unless_link(text, "%s?%[source:[^%]]*%]")
  text = drop_unless_link(text, "%s?%[source%s+%d[%d,%s%-]*%]")
  State.citation_strips = State.citation_strips + original_length - (utf8.len(text) or #text)
  return text
end

local function rule_emoji(text)
  text = text:gsub("✅", "✓"):gsub("❌", "✗"):gsub("⚠️", "!"):gsub("⚠", "!")
  local removed, n = 0, 0
  text, n = text:gsub("\xF0\x9F[\x8C-\xAB][\x80-\xBF]", "")
  removed = removed + n
  for _, cp in ipairs(REGISTRY.EMOJI_CODEPOINTS) do
    text, n = text:gsub(U(cp), "")
    removed = removed + n
  end
  State.emoji_strips = State.emoji_strips + removed
  return text
end

local function rule_utm(text)
  -- keep the query string valid:  ?utm_a=1&b=2  ->  ?b=2     ?utm_a=1  ->  (nothing)
  text = text:gsub("&utm_[%w_]+=[^%s%)&>%]]*", "")
  text = text:gsub("%?utm_[%w_]+=[^%s%)&>%]]*&", "?")
  text = text:gsub("%?utm_[%w_]+=[^%s%)&>%]]*", "")
  return text
end

-- NotebookLM / JSON-escaped math:  \\( x \\)  and  \\[ .. \\]  ->  \( x \)  and  \[ .. \]
local function rule_json_escaped_math(text)
  text = text:gsub("\\\\([%(%)%]])", "\\%1")
  -- \\[ is also a real LaTeX line break with spacing: \\[2mm]  \\[-1ex]  \\[0.5\baselineskip]
  -- Those are kept; every other \\[ is a doubly-escaped display-math opener.
  local src = text
  text = src:gsub("\\\\%[()", function(pos)
    local tail = src:sub(pos, pos + 60)
    if tail:match("^%s*[%d%.%-]+%s*%a+%s*%]") then return nil end
    local name = tail:match("^%s*[%d%.%-]*%s*\\(%a+)%s*%]")
    if name and (name:find("skip") or name:find("amount") or name:find("width") or name:find("height")) then
      return nil
    end
    return "\\["
  end)
  return text
end

-- HTML leftovers that AI chat UIs like to emit
local function rule_html_leftovers(text)
  text = text:gsub("<sub>(.-)</sub>", "\\textsubscript{%1}")
  text = text:gsub("<sup>(.-)</sup>", "\\textsuperscript{%1}")
  text = text:gsub("<br%s*/?>", "\\newline ")
  return text
end

-- LaTeX habit "Eq.~\eqref{..}" : a bare ~ in Markdown prose is literal, so use a real tie
local function rule_latex_ties(text)
  text = text:gsub("~(\\%a*ref%f[%A])", "\\nobreakspace{}%1"):gsub("~(\\%a*cite%f[%A])", "\\nobreakspace{}%1")
  return text
end

-- Ordered list of scrub rules.  `when` names a CONFIG flag; no `when` = always on.
local SCRUB_RULES = {
  { name = "invisible-chars",     apply = rule_invisible_chars },
  { name = "space-lookalikes",    apply = rule_space_lookalikes },
  { name = "citations",           apply = rule_citations,   when = "strip_citations" },
  { name = "emoji",               apply = rule_emoji,       when = "strip_emoji" },
  { name = "utm-tracking",        apply = rule_utm,         when = "strip_utm" },
  { name = "json-escaped-math",   apply = rule_json_escaped_math },
  { name = "html-leftovers",      apply = rule_html_leftovers },
  { name = "latex-ties",          apply = rule_latex_ties },
}

local function scrub_chunk(text)
  for _, rule in ipairs(SCRUB_RULES) do
    if rule.when == nil or CONFIG[rule.when] then text = rule.apply(text) end
  end
  return text
end

-- Scrub everything EXCEPT fenced code blocks (``` or ~~~), so code samples are never altered.
local function scrub(text)
  text = text:gsub("^" .. U(0xFEFF), ""):gsub("\r\n?", "\n")
  local out, buf, fence = {}, {}, nil
  local function flush(is_code)
    if #buf == 0 then return end
    local s = table.concat(buf, "\n")
    out[#out+1] = is_code and s or scrub_chunk(s)
    buf = {}
  end
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if mark and not fence then
      flush(false); fence = mark; buf[#buf+1] = line
    elseif mark and fence then
      buf[#buf+1] = line; flush(true); fence = nil
    else
      buf[#buf+1] = line
    end
  end
  flush(fence ~= nil)
  return table.concat(out, "\n")
end

-- ----------------------------------------------------------------------
-- §5.2  Fence masking: lets plain-text searches ignore code samples
-- ----------------------------------------------------------------------
-- Same text, but every backslash inside a fenced block is replaced by \1, so a
-- "\begin{document}" shown as an example in a code block is never mistaken for a real one.
local function mask_fences(text)
  local out, fence = {}, nil
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if mark and not fence then
      fence = mark; out[#out+1] = (line:gsub("\\", "\1"))
    elseif mark and fence then
      fence = nil; out[#out+1] = (line:gsub("\\", "\1"))
    elseif fence then
      out[#out+1] = (line:gsub("\\", "\1"))
    else
      out[#out+1] = line
    end
  end
  return table.concat(out, "\n")
end

-- ----------------------------------------------------------------------
-- §5.3  Math repair
-- ----------------------------------------------------------------------

-- Fix $-math on ONE line: NotebookLM's \$..\$, "$ x $", and "|" inside table cells
local function fix_math_line(line)
  -- NotebookLM escapes its own math:  \$ \psi_0 \$   ->  $ \psi_0 $
  local function unescape(inner)
    if not inner:match("[\\^_{}=]") then return nil end      -- real currency, leave alone
    inner = inner:gsub("\\([_%^%*|])", "%1"):gsub("\\%$", "$")
    return inner
  end
  line = line:gsub("\\%$\\%$(.-)\\%$\\%$", function(i) local r = unescape(i); return r and ("$$" .. r .. "$$") or nil end)
  line = line:gsub("\\%$(.-)\\%$",           function(i) local r = unescape(i); return r and ("$"  .. r .. "$")  or nil end)

  local is_table = line:match("^%s*|") ~= nil
  local out, i, n = {}, 1, #line
  while i <= n do
    local s = line:find("%$", i)
    if not s then out[#out+1] = line:sub(i); break end
    if s > 1 and line:sub(s-1, s-1) == "\\" then              -- escaped dollar = currency
      out[#out+1] = line:sub(i, s); i = s + 1
    elseif line:sub(s+1, s+1) == "$" then                     -- $$ .. $$ on the same line
      local e = line:find("%$%$", s + 2)
      if not e then out[#out+1] = line:sub(i); break end
      out[#out+1] = line:sub(i, e + 1); i = e + 2
    else                                                      -- inline $ .. $
      local e = line:find("%$", s + 1)
      while e and line:sub(e-1, e-1) == "\\" do e = line:find("%$", e + 1) end
      if not e then out[#out+1] = line:sub(i); break end
      local inner = line:sub(s + 1, e - 1)
      if inner:match("[\\^_{}=]") then
        inner = inner:gsub("^%s+", ""):gsub("%s+$", "")       -- "$ x $" is not math in pandoc
        if is_table then inner = inner:gsub("([^\\])|", "%1\\vert "):gsub("^|", "\\vert ") end
      end
      out[#out+1] = line:sub(i, s - 1) .. "$" .. inner .. "$"
      i = e + 1
    end
  end
  return table.concat(out)
end

-- ---------------- inline $ .. $ that spans several lines ----------------------------
-- Pandoc accepts  $a +\n b$  but NOT  "$ a +\n b $"  (a space next to a $ means "currency").
-- fix_math_line already trims spaces for math on ONE line; here the same is done when the pair
-- crosses a line break, but only when it is clearly math:
--   * the text between the two $ contains a math marker  \ ^ _ { } =
--   * the closing $ is not glued to a word / command / bracket / digit that follows it,
--     and is not followed by a number ("$ 5 ... $ 7" is currency)
--   * the opening $ is not glued to a word before it
-- Never touched: code fences, indented code blocks, `code spans`, \$ , $$..$$, table rows,
-- headings, raw \begin/\end lines, and list items (a list item never continues into the next item).
local function fix_paragraph(s)
  if not s:find("\n", 1, true) or not s:find("$", 1, true) then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" then                                         -- escaped char (\$ included)
      out[#out+1] = s:sub(i, i + 1); i = i + 2
    elseif c == "`" then                                      -- code span: copy verbatim
      local k = #s:match("^`+", i)
      local j, close = i + k, nil
      while true do
        local a, b = s:find("`+", j)
        if not a then break end
        if b - a + 1 == k then close = b; break end
        j = b + 1
      end
      if close then out[#out+1] = s:sub(i, close); i = close + 1
      else out[#out+1] = s:sub(i, i + k - 1); i = i + k end
    elseif c == "$" then
      if s:sub(i + 1, i + 1) == "$" then                      -- $$ .. $$ : copy verbatim
        local e = s:find("$$", i + 2, true)
        if e then out[#out+1] = s:sub(i, e + 1); i = e + 2
        else out[#out+1] = "$$"; i = i + 2 end
      else
        local e = i + 1                                       -- closing unescaped $
        while true do
          e = s:find("[$\\]", e)
          if not e then break end
          if s:sub(e, e) == "\\" then e = e + 2 else break end
        end
        if not e then
          out[#out+1] = "$"; i = i + 1
        else
          local inner = s:sub(i + 1, e - 1)
          local after, before = s:sub(e + 1, e + 1), (i > 1) and s:sub(i - 1, i - 1) or ""
          if not inner:find("\n", 1, true) then               -- same line: fix_math_line's job
            out[#out+1] = s:sub(i, e); i = e + 1
          elseif not inner:match("^%s") and not inner:match("%s$") and not after:match("%d") then
            out[#out+1] = s:sub(i, e); i = e + 1              -- already valid for pandoc
          elseif inner:find("[\\^_{}=]") and not after:match("[%w\\{(%[$]") and not before:match("%w")
              and not s:sub(e + 1):match("^%s*%d") then          -- "$ 5 .. $ 7" is currency, not math
            local t = inner:gsub("^%s+", ""):gsub("%s+$", "")
            out[#out+1] = "$" .. t .. "$"; i = e + 1          -- trim: now valid math
          else
            out[#out+1] = "$"; i = i + 1                      -- not clearly math: leave as is
          end
        end
      end
    else
      local j = s:find("[\\`$]", i + 1)
      out[#out+1] = s:sub(i, (j or n + 1) - 1); i = j or n + 1
    end
  end
  return table.concat(out)
end

-- ---------------- list-item continuation lines inside open inline math ----------------------
-- A formula that continues on a line starting with "- ", "+ ", "* " or "1." looks like a new
-- list item (to this filter and to pandoc), so the $ .. $ pair is cut in two:
--       - The energy is $E = a
--         + b + c$                    <- read as a NEW list item, math is broken
-- open_math(s) returns the closer ("$", "$$", "\)" or "\]") of a math formula that is still open
-- at the end of s, or nil when every formula is closed.  Handles  $..$  $$..$$  \(..\)  \[..\]
-- like LaTeX does: inside a formula only its own closer ends it.  Code spans and escaped
-- characters (\$ \\ \\[2mm] ...) are skipped.
local function open_math(s)
  local i, n, closer = 1, #s, nil
  while i <= n do
    local c = s:sub(i, i)
    if closer then
      if c == "\\" then
        if (closer == "\\)" or closer == "\\]") and s:sub(i, i + 1) == closer then
          closer = nil
        end
        i = i + 2
      elseif c == "$" and closer == "$$" then
        if s:sub(i + 1, i + 1) == "$" then closer = nil; i = i + 2 else i = i + 1 end
      elseif c == "$" and closer == "$" then
        closer = nil; i = i + 1
      else
        i = i + 1
      end
    elseif c == "\\" then
      local d = s:sub(i + 1, i + 1)
      if d == "(" then closer = "\\)"
      elseif d == "[" then closer = "\\]" end
      i = i + 2
    elseif c == "`" then
      local k = #s:match("^`+", i)
      local j, close = i + k, nil
      while true do
        local a, b = s:find("`+", j)
        if not a then break end
        if b - a + 1 == k then close = b; break end
        j = b + 1
      end
      i = close and (close + 1) or (i + k)
    elseif c == "$" then
      if s:sub(i + 1, i + 1) == "$" then closer = "$$"; i = i + 2 else closer = "$"; i = i + 1 end
    else
      i = i + 1
    end
  end
  return closer
end

local function single_dollar_positions(s)
  local positions, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "`" then
      local ticks = #s:match("^`+", i)
      local search, close = i + ticks, nil
      while true do
        local a, b = s:find("`+", search)
        if not a then break end
        if b - a + 1 == ticks then close = b; break end
        search = b + 1
      end
      i = close and close + 1 or i + ticks
    elseif c == "$" then
      if s:sub(i + 1, i + 1) == "$" then
        local close = s:find("$$", i + 2, true)
        i = close and close + 2 or i + 2
      else
        positions[#positions+1] = i
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return positions
end

-- A line that is never part of running paragraph text: blank, table row, heading, \begin / \end.
local function is_structural_line(line)
  return not line:match("%S") or line:match("^%s*|") or line:match("^%s*#+%s")
      or line:match("^%s*\\begin%s*{") or line:match("^%s*\\end%s*{")
      or line:find("FIXGROUPS_LITERAL", 1, true) ~= nil
end

-- Same rule as a LaTeX compiler (Overleaf): once a single $ is open, the formula runs to the next
-- unescaped $ whatever the following lines start with.  So a list-looking line continues the
-- formula whenever the open $ is closed LATER IN THE SAME PARAGRAPH (a blank line, heading,
-- table row, \begin/\end line or code fence ends the paragraph; LaTeX would raise an error there,
-- so nothing is joined and the text is left as it is).
local function is_para_boundary(line)
  return is_structural_line(line) or fence_mark(line) ~= nil
end

local function continues_open_math(para_text, lines, idx)
  local closer = open_math(para_text)
  if not closer then return false end
  local pending
  if closer == "$" then
    local positions = single_dollar_positions(para_text)
    local opening = positions[#positions]
    if opening then pending = para_text:sub(opening + 1) end
  end
  local t = para_text
  for j = idx, #lines do
    if is_para_boundary(lines[j]) then return false end
    if pending then
      local continuation = pending .. "\n" .. lines[j]
      local positions = single_dollar_positions(continuation)
      if #positions > 0 then
        local formula = continuation:sub(1, positions[1] - 1)
        return formula:find("[\\^_{}=]") ~= nil
      end
    end
    t = t .. "\n" .. lines[j]
    if open_math(t) == nil then return true end
  end
  return false
end

local function fix_multiline_math(text)
  local out, para, list_para, fence = {}, {}, false, nil
  local joined_items = 0
  local function flush()
    if #para > 0 then out[#out+1] = fix_paragraph(table.concat(para, "\n")); para = {} end
  end
  local lines = split_lines(text)
  for idx, line in ipairs(lines) do
    local mark = fence_mark(line, fence)
    if mark then
      flush()
      fence = fence_next(fence, mark)
      out[#out+1] = line
    elseif fence or is_structural_line(line)
        or (#para == 0 and (line:match("^    ") or line:match("^\t"))) then
      flush(); out[#out+1] = line                              -- block boundary / not paragraph text
                                                               -- (incl. indented code blocks)
    else
      local is_item = line:match("^%s*[-*+]%s") or line:match("^%s*%d+[.)]%s")
      if is_item and #para > 0 and continues_open_math(table.concat(para, "\n"), lines, idx) then
        -- formula continues on a line that merely LOOKS like a list marker: glue it to the
        -- previous line so the marker is no longer at the start of a line
        para[#para] = para[#para] .. " " .. line:gsub("^%s+", "")
        joined_items = joined_items + 1
      else
        if #para > 0 and list_para and is_item then flush() end  -- next list item = new unit
        if #para == 0 then list_para = is_item ~= nil end
        para[#para+1] = line
      end
    end
  end
  flush()
  if joined_items > 0 then
    warn(string.format("joined %d formula continuation line(s) that started like a list item", joined_items))
  end
  return table.concat(out, "\n")
end

-- ----------------------------------------------------------------------
-- §5.4  Hoisting of preamble commands (\usepackage, \newcommand, ...)
-- ----------------------------------------------------------------------

-- Decide what to do with a (possibly multi-line) definition; returns true if it was consumed
-- (dropped or moved to State.hoisted), false if the caller must keep it in the body.
local function package_commands(block)
  local commands, pos = {}, 1
  while true do
    local start = block:find("\\usepackage", pos, true)
    if not start then break end
    local after = start + #"\\usepackage"
    if block:sub(after, after):match("[%a@]") then
      pos = after
    else
      local cursor = after
      while block:sub(cursor, cursor):match("%s") do cursor = cursor + 1 end
      local options = ""
      if block:sub(cursor, cursor) == "[" then
        options = block:sub(cursor):match("^%b[]") or ""
        if options == "" then return nil end
        cursor = cursor + #options
        while block:sub(cursor, cursor):match("%s") do cursor = cursor + 1 end
      end
      if block:sub(cursor, cursor) ~= "{" then return nil end
      local finish = group_end(block, cursor)
      if not finish then return nil end
      local names = block:sub(cursor + 1, finish - 2)
      local keep = {}
      for name in names:gmatch("[^,%s]+") do
        if not REGISTRY.SKIP_PACKAGES[name] then keep[#keep+1] = name end
      end
      if #keep > 0 then
        commands[#commands+1] = "\\usepackage" .. options .. "{" .. table.concat(keep, ",") .. "}"
      end
      pos = finish
    end
  end
  return commands
end

local function hoist(block, in_preamble)
  local cmd = block:match("^%s*\\(%a+)")
  if not cmd then return false end
  if in_preamble then
    if REGISTRY.PREAMBLE_DROP[cmd] then return true end
    local val = block:match("^%s*\\%a+%s*(%b{})")
    if REGISTRY.PREAMBLE_META[cmd] and val then
      State.extra_meta[cmd] = val:sub(2, -2); return true
    end
  elseif not REGISTRY.BODY_HOIST[cmd] then
    return false
  end
  if cmd == "usepackage" then
    local commands = package_commands(block:gsub("%%[^\n]*$", ""))
    if not commands then
      warn("could not parse pasted \\usepackage command; leaving it in the body")
      return false
    end
    for _, package in ipairs(commands) do State.hoisted[#State.hoisted+1] = package end
    return true
  elseif cmd == "newtheorem" then
    local nm = block:match("\\newtheorem%*?{([^}]*)}")
    if nm and REGISTRY.THEOREMS[nm] then return true end
  end
  -- A pasted \newcommand must win over packages the template loads (physics defines
  -- \ket, \dd, ...): DeclareRobustCommand takes the same syntax and never raises
  -- "command already defined".
  block = block:gsub("^(%s*)\\newcommand%f[%A]", "%1\\DeclareRobustCommand")
  State.hoisted[#State.hoisted+1] = block
  return true
end

-- Walk the text line by line, outside code fences, collecting preamble-type commands.
-- Returns the text that stays in the body (and runs fix_math_line on it).
local function process_lines(text, in_preamble)
  local out, fence, tikz_depth = {}, nil, 0
  local pending, bal = nil, 0
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if pending then
      pending = pending .. "\n" .. line; bal = bal + brace_balance(line)
      if bal <= 0 then
        if not hoist(pending, in_preamble) then out[#out+1] = pending end
        pending = nil
      end
    elseif mark then
      fence = fence_next(fence, mark)
      out[#out+1] = line
    elseif fence then
      out[#out+1] = line
    else
      local begins = 0
      for _ in line:gmatch("\\begin%s*{tikzpicture}") do begins = begins + 1 end
      local ends = 0
      for _ in line:gmatch("\\end%s*{tikzpicture}") do ends = ends + 1 end
      if tikz_depth > 0 or begins > 0 then
        out[#out+1] = line
        tikz_depth = math.max(0, tikz_depth + begins - ends)
      else
      local cmd = line:match("^%s*\\(%a+)")
      if cmd and (in_preamble or REGISTRY.BODY_HOIST[cmd]) and not line:match("^%s*\\begin") then
        bal = brace_balance(line)
        if bal > 0 then pending = line
        elseif not hoist(line, in_preamble) then out[#out+1] = fix_math_line(line) end
      elseif in_preamble then
        if line:match("%S") and not line:match("^%s*%%") then State.hoisted[#State.hoisted+1] = line end
      else
        out[#out+1] = fix_math_line(line)
      end
      end
    end
  end
  if pending then out[#out+1] = pending end
  return table.concat(out, "\n")
end

-- ----------------------------------------------------------------------
-- §5.5  Structural rewrites
-- ----------------------------------------------------------------------
local function is_table_row(line) return line:match("^%s*|.*|%s*$") ~= nil end

-- pandoc needs a blank line before a pipe table; AI output often omits it
local function space_tables(text)
  local out, fence, prev, display = {}, nil, "", nil
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if mark then
      fence = fence_next(fence, mark)
    elseif not fence and is_table_row(line) and prev:match("%S") and not is_table_row(prev) then
      if not display then out[#out+1] = "" end
    end
    out[#out+1] = line
    if not fence then
      if display == "$$" then
        local _, count = line:gsub("%$%$", "")
        if count % 2 == 1 then display = nil end
      elseif display == "\\]" then
        if line:find("\\]", 1, true) then display = nil end
      elseif line:find("$$", 1, true) then
        local _, count = line:gsub("%$%$", "")
        if count % 2 == 1 then display = "$$" end
      elseif line:find("\\[", 1, true) then
        display = "\\]"
        if line:find("\\]", 1, true) then display = nil end
      end
    end
    prev = line
  end
  return table.concat(out, "\n")
end

-- ---------------- Markdown emphasis inside itemize / enumerate / description ------------
-- Inside these three environments (and only there) **bold** -> \textbf{bold} and *italic* ->
-- \emph{italic}, done as plain text rewriting: pandoc never re-reads the list, so \item and the
-- list layout are untouched.  Skipped on purpose: math ($..$ $$..$$ \(..\) \[..\]), \* , the
-- optional [..] after \begin{..}, comments (% ..), fenced code, nested environments such as
-- tabular/tikzpicture (the innermost open environment must be the list), and a * that is
-- not a real emphasis marker (2*3*4, "5 * 3 and 2 * 4": needs non-space inside, not glued to a word).
local function md_emph(seg)
  local keep = {}
  local function stash(m) keep[#keep+1] = m; return "\2" .. #keep .. "\2" end
  seg = seg:gsub("\\%$", stash):gsub("\\%*", stash)
  seg = seg:gsub("%$%$.-%$%$", stash):gsub("%$[^%$]-%$", stash)
  seg = seg:gsub("\\%(.-\\%)", stash):gsub("\\%[.-\\%]", stash)
  local orig = seg
  seg = orig:gsub("()%*%*([^*]+)%*%*()", function(a, c, b)
    local pre, post = orig:sub(a - 1, a - 1), orig:sub(b, b)
    if c:match("^%s") or c:match("%s$") then return nil end
    if a > 1 and pre:match("[%w\\*]") then return nil end
    if post:match("[%w*]") then return nil end
    State.md_list_fixes = State.md_list_fixes + 1
    return "\\textbf{" .. c .. "}"
  end)
  orig = seg
  seg = orig:gsub("()%*([^*]+)%*()", function(a, c, b)
    local pre, post = orig:sub(a - 1, a - 1), orig:sub(b, b)
    if c:match("^%s") or c:match("%s$") then return nil end
    if a > 1 and pre:match("[%w\\*]") then return nil end
    if post:match("[%w*]") then return nil end
    State.md_list_fixes = State.md_list_fixes + 1
    return "\\emph{" .. c .. "}"
  end)
  return (seg:gsub("\2(%d+)\2", function(n) return keep[tonumber(n)] end))
end

local function md_in_lists(text)
  local out, fence, stack = {}, nil, {}
  local function conv(seg) return REGISTRY.LIST_ENVS[stack[#stack] or ""] and md_emph(seg) or seg end
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if mark then
      fence = fence_next(fence, mark)
      out[#out+1] = line
    elseif fence or line:sub(1, 1) == "%" then
      out[#out+1] = line                                  -- fenced code / comment line
    else
      local cpos = line:find("[^\\]%%")
      local body, tail = line, ""
      if cpos then body = line:sub(1, cpos); tail = line:sub(cpos + 1) end
      local res, pos = {}, 1
      for s, cmd, name, e in body:gmatch("()\\(%a+)%s*{(%a+)%*?}()") do
        if cmd == "begin" or cmd == "end" then
          res[#res+1] = conv(body:sub(pos, s - 1))
          res[#res+1] = body:sub(s, e - 1)
          pos = e
          if cmd == "begin" then
            stack[#stack+1] = name
            local opt = body:match("^%s*%b[]", e)            -- \begin{itemize}[leftmargin=*]
            if opt then res[#res+1] = body:sub(e, e + #opt - 1); pos = e + #opt end
          elseif stack[#stack] == name then
            stack[#stack] = nil
          end
        end
      end
      res[#res+1] = conv(body:sub(pos))
      out[#out+1] = table.concat(res) .. tail
    end
  end
  if State.md_list_fixes > 0 then
    warn(string.format("converted %d Markdown emphasis mark(s) inside itemize/enumerate/description", State.md_list_fixes))
  end
  return table.concat(out, "\n")
end

-- \begin{theorem}[Name] ... \end{theorem}  ->  fenced Div, so the body is parsed as Markdown.
-- div_fix() turns the Div back into \begin{theorem}[Name] ... \end{theorem}.
-- Only used when begin and end are on separate lines; everything else stays raw LaTeX.
local function envs_to_divs(text)
  local out, fence, cur = {}, nil, nil
  for line in each_line(text) do
    local mark = fence_mark(line, fence)
    if mark then
      fence = fence_next(fence, mark)
      out[#out+1] = line
    elseif fence then
      out[#out+1] = line
    else
      local env, rest = line:match("^%s*\\begin{(%a+)}(.*)$")
      if not cur and env and REGISTRY.DIV_ENVS[env] and not rest:find("\\end{" .. env .. "}", 1, true) then
        local opt, tail = rest:match("^%s*(%b[])(.*)$")
        if not opt then tail = rest end
        State.env_opts[#State.env_opts + 1] = opt or ""
        cur = env
        out[#out+1] = ""
        out[#out+1] = string.format('::: {.latexenv lenv="%s" lopt="%d"}', env, #State.env_opts)
        if tail:match("%S") then out[#out+1] = (tail:gsub("^%s+", "")) end
      else
        local before, e = line:match("^(.-)\\end{(%a+)}%s*$")
        if cur and e == cur then
          if before:match("%S") then out[#out+1] = before end
          out[#out+1] = ":::"
          out[#out+1] = ""
          cur = nil
        else
          out[#out+1] = line
        end
      end
    end
  end
  if cur then out[#out+1] = ":::" end   -- unclosed environment: close the Div anyway
  return table.concat(out, "\n")
end

-- ----------------------------------------------------------------------
-- §5.6  Text pipeline.  Each pass is `function(text) -> text`; ORDER MATTERS
--       and is documented on every row.
-- ----------------------------------------------------------------------

-- A pasted full document: process its preamble (hoist / drop / collect metadata) and keep
-- only the text between \begin{document} and \end{document}.
local function pass_unwrap_document(text)
  local masked = mask_fences(text)
  local bs, be = masked:find("\\begin{document}", 1, true)
  local es = masked:match("^.*()\\end{document}")   -- anchored: unanchored was quadratic (9 s per 500 lines)
  if bs and es and es > be and masked:sub(1, bs - 1):find("\\documentclass", 1, true) then
    local finish = masked:find("\\end{document}", es, true)
    if finish and masked:sub(finish + #"\\end{document}"):match("%S") then
      warn("discarded non-whitespace text after \\end{document} in pasted full document")
    end
    process_lines(text:sub(1, bs - 1), true)
    text = text:sub(be + 1, es - 1)
  end
  return text
end

local function pass_drop_maketitle(text)
  return (text:gsub("\\maketitle%s*", ""))
end

local function pass_hoist_body_commands(text)
  return process_lines(text, false)
end

local TEXT_PASSES = {
  { name = "scrub",               apply = scrub },                -- 1. normalise characters, strip AI debris
  { name = "unwrap-document",     apply = pass_unwrap_document }, -- 2. needs clean text to find \begin{document}
  { name = "drop-maketitle",      apply = pass_drop_maketitle },  -- 3. the template prints the title itself
  { name = "space-tables",        apply = space_tables },         -- 4. blank line before pipe tables
  { name = "multiline-math",      apply = fix_multiline_math },   -- 5. must see paragraphs BEFORE hoisting
  { name = "hoist-commands",      apply = pass_hoist_body_commands }, -- 6. also runs fix_math_line per line
  { name = "markdown-in-lists",   apply = md_in_lists },          -- 7. after hoisting: lists are final
  { name = "environments-to-divs",apply = envs_to_divs },         -- 8. last: output goes straight to pandoc
}

local function mask_inline_code(text, store)
  local out, pos = {}, 1
  while pos <= #text do
    local a, b = text:find("`+", pos)
    if not a then out[#out+1] = text:sub(pos); break end
    local slashes, j = 0, a - 1
    while j >= 1 and text:sub(j, j) == "\\" do slashes = slashes + 1; j = j - 1 end
    if slashes % 2 == 1 then
      out[#out+1] = text:sub(pos, b); pos = b + 1
    else
      local ticks = b - a + 1
      local close
      local search = b + 1
      while true do
        local x, y = text:find("`+", search)
        if not x then break end
        if y - x + 1 == ticks then
          local preceding, k = 0, x - 1
          while k >= 1 and text:sub(k, k) == "\\" do preceding = preceding + 1; k = k - 1 end
          if preceding % 2 == 0 then close = y; break end
        end
        search = y + 1
      end
      if close then
        out[#out+1] = text:sub(pos, a - 1)
        store[#store+1] = text:sub(a, close)
        out[#out+1] = "\1FIXGROUPS_LITERAL_" .. #store .. "\2"
        pos = close + 1
      else
        out[#out+1] = text:sub(pos, b)
        pos = b + 1
      end
    end
  end
  return table.concat(out)
end

local function mask_literals(text)
  local store, out, prose, block = {}, {}, {}, {}
  local fence, verbatim = nil, nil
  local function stash(value)
    store[#store+1] = value
    return "\1FIXGROUPS_LITERAL_" .. #store .. "\2"
  end
  local function flush_prose()
    if #prose > 0 then
      out[#out+1] = mask_inline_code(table.concat(prose, "\n"), store)
      prose = {}
    end
  end
  local function flush_block()
    flush_prose()
    out[#out+1] = stash(table.concat(block, "\n"))
    block = {}
  end
  for line in each_line(text) do
    if fence then
      block[#block+1] = line
      if fence_mark(line, fence) then fence = nil; flush_block() end
    elseif verbatim then
      block[#block+1] = line
      if line:find("\\end{" .. verbatim .. "}", 1, true) then verbatim = nil; flush_block() end
    else
      local mark = fence_mark(line)
      local env = line:match("^%s*\\begin{(verbatim%*?)}")
          or line:match("^%s*\\begin{(Verbatim%*?)}")
          or line:match("^%s*\\begin{(lstlisting%*?)}")
      if mark then
        flush_prose()
        fence = mark
        block = { line }
      elseif env then
        flush_prose()
        block = { line }
        if line:find("\\end{" .. env .. "}", 1, true) then flush_block()
        else verbatim = env end
      elseif line:match("^    ") or line:match("^\t") then
        flush_prose()
        out[#out+1] = stash(line)
      else
        prose[#prose+1] = line
      end
    end
  end
  if #block > 0 then flush_block() end
  flush_prose()
  local masked = table.concat(out, "\n")
  local function restore(value)
    return (value:gsub("\1FIXGROUPS_LITERAL_(%d+)\2", function(n)
      return store[tonumber(n)]
    end))
  end
  return masked, restore
end

local function clean(text)
  text = text:gsub("^" .. U(0xFEFF), ""):gsub("\r\n?", "\n")
  local fence, malformed = nil, 0
  for line in each_line(text) do
    if fence then
      if fence_mark(line, fence) then fence = nil end
    else
      local mark = fence_mark(line)
      if mark then
        fence = mark
      elseif line:match("^%s*```+.+```+%s*$") then
        malformed = malformed + 1
      end
    end
  end
  if fence then warn("unclosed code fence (opening fence uses " .. #fence .. " markers); remaining input is treated as code") end
  if malformed > 0 then warn(string.format("ignored %d malformed one-line code fence(s)", malformed)) end
  for _, pass in ipairs(TEXT_PASSES) do
    local masked, restore = mask_literals(text)
    text = restore(pass.apply(masked))
  end
  return text
end


-- ======================================================================
-- §6  STAGE B  --  AST PASSES  (pandoc AST -> pandoc AST)
-- ======================================================================

-- ----------------------------------------------------------------------
-- §6.1  Math
-- ----------------------------------------------------------------------
-- \mathbf{\Pi}, \mathrm{\Pi}, \mathit{\Pi} under xelatex ask the Bold/Regular/Italic TEXT font for
-- glyph U+0005 (blank + "Missing character" warning): capital Greek follows the font switch, but
-- those fonts have nothing in the old slots.  Inside such a group only the capital Greek command
-- itself is wrapped; the rest of the group is left exactly as written (nothing non-trivial ever
-- goes inside \boldsymbol, because bm breaks on e.g. \boldsymbol{E_+}):
--   \mathbf{..\Pi..} -> \boldsymbol{\Pi}  (bold)
--   \mathrm{..\Pi..} -> \mathnormal{\Pi}  (upright, same as a plain \Pi)
--   \mathit{..\Pi..} -> \mathnormal{\varPi} (italic)
local GREEK_WRAP = {
  bf = function(name) return "\\boldsymbol{\\" .. name .. "}" end,
  rm = function(name) return "\\mathnormal{\\" .. (name:gsub("^var", "")) .. "}" end,
  it = function(name) return "\\mathnormal{\\var" .. (name:gsub("^var", "")) .. "}" end,
}

local function wrap_greek(inner, kind)
  local out, pos = {}, 1
  for p, name, e in inner:gmatch("()\\(%a+)()") do
    local base = name:gsub("^var", "")
    local before = inner:sub(math.max(1, p - 14), p - 1)
    if (REGISTRY.GREEK_CAPITALS[name] or REGISTRY.GREEK_CAPITALS[base])
       and not before:find("\\bo?l?d?s?y?m?b?o?l?%s*{%s*$")
       and not before:find("\\bm%s*{%s*$")
       and not before:find("\\mathnormal%s*{%s*$") then
      out[#out + 1] = inner:sub(pos, p - 1)
      out[#out + 1] = GREEK_WRAP[kind](name)
      pos = e
    end
  end
  out[#out + 1] = inner:sub(pos)
  return table.concat(out)
end

-- kind = font of the enclosing group (nil at top level); the innermost font group decides
local function convert(s, kind)
  local function seg(t) return kind and wrap_greek(t, kind) or t end
  local out, pos = {}, 1
  while true do
    local a, b, k = s:find("\\math(%a%a)%s*{", pos)
    if not a then break end
    local e = GREEK_WRAP[k] and group_end(s, b)
    out[#out + 1] = seg(s:sub(pos, a - 1))
    if e then
      out[#out + 1] = s:sub(a, b) .. convert(s:sub(b + 1, e - 2), k) .. "}"
      pos = e
    else                                            -- \mathcal, \mathbb, unbalanced ...: untouched
      out[#out + 1] = seg(s:sub(a, b))
      pos = b + 1
    end
  end
  out[#out + 1] = seg(s:sub(pos))
  return table.concat(out)
end

local function bold_greek(s)
  if not s:find("\\math", 1, true) then return s end
  return convert(s, nil)
end

-- $$\begin{align}..\end{align}$$ would become \[\begin{align}..\] = LaTeX error.
-- Emit the environment itself instead (keeps numbering, \label and \eqref working).
local function math_fix(el)
  local changed = false
  local fixed = bold_greek(el.text)
  if fixed ~= el.text then el = pandoc.Math(el.mathtype, fixed); changed = true end
  if el.mathtype ~= "DisplayMath" then return changed and el or nil end
  local env = el.text:match("^%s*\\begin{(%a+)%*?}")
  if env and REGISTRY.MATH_ENVS[env] and el.text:match("\\end{" .. env .. "%*?}%s*$") then
    return pandoc.RawInline("latex", "\n" .. el.text:gsub("^%s+", ""):gsub("%s+$", "") .. "\n")
  end
  return changed and el or nil
end

-- ----------------------------------------------------------------------
-- §6.2  Unicode super/subscripts
-- ----------------------------------------------------------------------

-- Unicode superscript LETTERS (pˢ  mⁿ  xʸ ...) are missing from Latin Modern, so XeLaTeX prints a
-- blank and "Missing character".  Each one becomes \textsuperscript{base letter}, which follows
-- the current font (bold in **..**, headings, ...).  Only ordinary text is touched: math, code
-- spans and code blocks are separate AST elements and are left alone.
local function str_fix(el)
  local text, hit = el.text, false
  for ch in text:gmatch(utf8.charpattern) do
    if SUPER_LETTERS[ch] then hit = true; break end
  end
  if not hit then return nil end
  local out, buf = {}, {}
  local function flush()
    if #buf > 0 then out[#out+1] = pandoc.Str(table.concat(buf)); buf = {} end
  end
  for ch in text:gmatch(utf8.charpattern) do
    local base = SUPER_LETTERS[ch]
    if base then
      flush()
      out[#out+1] = pandoc.RawInline("latex", "\\textsuperscript{" .. base .. "}")
      State.super_fixes = State.super_fixes + 1
    else
      buf[#buf+1] = ch
    end
  end
  flush()
  return out
end

-- ------------- Unicode super/subscripts INSIDE MATH ---------------------------------------
-- config/custom.tex defines ¹ ² ⁻ ₁ ... one by one as ^{..} / _{..}, so  $10⁻¹$  became
-- 10^{-}^{1}  ("Double superscript") and  $x₁₂$  became  x_{1}_{2}  ("Double subscript").
-- Here every unbroken run is merged into ONE group:  10⁻¹ -> 10^{-1},  x₁₂ -> x_{12},
-- and letters the math font lacks (mˢ, xⁿ, yᵗ, ₐ ₙ ...) work too.  Applied to parsed math
-- ($..$, \(..\), $$..$$) and to raw math environments (align, equation, ...).
-- A "{}" is put in front only when the same kind of script is already open (x^{2}²), so
-- \int_0¹ becomes \int_0^{1} with the limit attached to the integral.
-- Inside \text{..} / \mbox{..} the runs become \textsuperscript / \textsubscript instead.
local function to_scripts(s, textmode)
  local out, sup, sub, hit = {}, {}, {}, false
  local function flush()
    if #sup > 0 then
      local body = table.concat(sup); sup = {}; hit = true
      if textmode then
        out[#out+1] = "\\textsuperscript{" .. body .. "}"
      else
        local prev = table.concat(out)
        local lead = (prev:find("%^%b{}$") or prev:find("%^[^{}\\]$")) and "{}" or ""
        out[#out+1] = lead .. "^{" .. body .. "}"
      end
    end
    if #sub > 0 then
      local body = table.concat(sub); sub = {}; hit = true
      if textmode then
        out[#out+1] = "\\textsubscript{" .. body .. "}"
      else
        local prev = table.concat(out)
        local lead = (prev:find("_%b{}$") or prev:find("_[^{}\\]$")) and "{}" or ""
        out[#out+1] = lead .. "_{" .. body .. "}"
      end
    end
  end
  for ch in s:gmatch(utf8.charpattern) do
    if MATH_SUP[ch] then
      if #sub > 0 then flush() end
      sup[#sup+1] = MATH_SUP[ch]
    elseif MATH_SUB[ch] then
      if #sup > 0 then flush() end
      sub[#sub+1] = MATH_SUB[ch]
    else
      flush(); out[#out+1] = ch
    end
  end
  flush()
  return table.concat(out), hit
end

-- split off \text{..}-like groups, convert math parts and text parts differently
local function scripts_in_math(s)
  local res, last, pos, any = {}, 1, 1, false
  local function add(piece, textmode)
    local t, h = to_scripts(piece, textmode)
    res[#res+1] = t; any = any or h
  end
  while true do
    local a, b, name = s:find("\\(%a+)%s*{", pos)
    if not a then break end
    local e = REGISTRY.TEXT_COMMANDS[name] and group_end(s, b)
    if e then
      add(s:sub(last, a - 1), false)
      res[#res+1] = s:sub(a, b)
      add(s:sub(b + 1, e - 2), true)
      res[#res+1] = "}"
      last, pos = e, e
    else
      pos = b + 1
    end
  end
  add(s:sub(last), false)
  return table.concat(res), any
end

local function math_super(el)
  if el.t ~= "Math" and el.t ~= "RawInline" then return nil end
  local new, hit = scripts_in_math(el.text)
  if not hit then return nil end
  State.super_fixes = State.super_fixes + 1
  if el.t == "Math" then return pandoc.Math(el.mathtype, new) end
  return pandoc.RawInline(el.format, new)
end

-- \begin{align} ... \end{align} written directly (not inside $$) is a raw LaTeX block.
-- (pandoc usually reads it as a RawInline inside a paragraph; sometimes as a RawBlock.)
local function rawblock_super(el)
  if not el.format:match("^%a*tex$") then return nil end
  local env = el.text:match("^%s*\\begin{(%a+)%*?}")
  if not (env and REGISTRY.MATH_ENVS[env]) then return nil end
  local new, hit = scripts_in_math(el.text)
  if not hit then return nil end
  State.super_fixes = State.super_fixes + 1
  if el.t == "RawBlock" then return pandoc.RawBlock(el.format, new) end
  return pandoc.RawInline(el.format, new)
end

-- ----------------------------------------------------------------------
-- §6.3  Characters inside code
-- ----------------------------------------------------------------------
-- Code spans and code blocks must keep their text as it is, so nothing is rewritten there.
-- Instead the character is DEFINED in the preamble (\newunicodechar), which also works in the
-- monospace font.  Only the characters that really occur in code are defined.
local function note_code_super(el)
  for ch in el.text:gmatch(utf8.charpattern) do
    if SUPER_LETTERS[ch] and not REGISTRY.TEMPLATE_DEFINED_CHARS[ch] then State.code_super[ch] = true end
  end
  return nil
end

-- ----------------------------------------------------------------------
-- §6.4  Images, links, raw html
-- ----------------------------------------------------------------------
-- Drop images LaTeX cannot include, and say so (a missing file would be a LaTeX error).
local function image_fix(el)
  local src = el.src or ""
  local ext = src:match("%.(%w+)$")
  local why
  if src:match("^%a[%w+.%-]+:") and not src:match("^%a:[/\\]") then   -- http: https: data: file: sandbox: blob: ... (not C:/ or C:\)
    why = "remote or sandbox image"
  elseif not (ext and REGISTRY.IMAGE_EXTENSIONS[ext:lower()]) then
    why = "unsupported type (png/jpg/pdf only)"
  elseif not (file_exists(src) or file_exists((src:gsub("%%20", " ")))) then
    why = "file not found next to the input"
  end
  if why then
    warn("dropped image (" .. why .. "): " .. src)
    return {}
  end
  return nil
end

-- A Figure whose image was dropped would be empty: drop the Figure too.
local function figure_fix(el)
  local has = false
  el:walk({ Image = function() has = true end })
  if not has then return {} end
  return nil
end

local function raw_html_fix(el)
  if el.format:match("^html") then return {} end
  return nil
end

local function link_fix(el)
  if not CONFIG.keep_links then return el.content end
  return nil
end

-- ----------------------------------------------------------------------
-- §6.5  Tables and environment Divs
-- ----------------------------------------------------------------------
-- \textbf{\(\begin{cases}..\end{cases}\)} crashes LaTeX INSIDE TABLE CELLS with
-- "Forbidden control sequence ... \check@nocorr@" (matrices, aligned, cases ... all do).
-- Only in table cells, and only for such math: remove formatting wrappers from
-- the math itself while retaining them on adjacent text. Captions and paragraphs are untouched.
local function bad_math(t)
  return t:find("\\begin%s*{") ~= nil or t:find("\\\\") ~= nil
      or t:find("^&") ~= nil or t:find("[^\\]&") ~= nil     -- alignment &, not \&
end

local function inline_with_content(inline, content)
  if inline.t == "Emph" then return pandoc.Emph(content) end
  if inline.t == "Underline" then return pandoc.Underline(content) end
  if inline.t == "Strong" then return pandoc.Strong(content) end
  if inline.t == "Strikeout" then return pandoc.Strikeout(content) end
  if inline.t == "Superscript" then return pandoc.Superscript(content) end
  if inline.t == "Subscript" then return pandoc.Subscript(content) end
  if inline.t == "SmallCaps" then return pandoc.SmallCaps(content) end
  if inline.t == "Quoted" then return pandoc.Quoted(inline.quotetype, content) end
  if inline.t == "Cite" then return pandoc.Cite(inline.citations, content) end
  if inline.t == "Link" then return pandoc.Link(content, inline.target, inline.title, inline.attr) end
  if inline.t == "Image" then return pandoc.Image(content, inline.src, inline.title, inline.attr) end
  if inline.t == "Span" then return pandoc.Span(content, inline.attr) end
  error("cannot preserve formatting for inline element " .. tostring(inline.t))
end

local function split_bad_math(inline)
  if inline.t == "Math" and bad_math(inline.text) then
    return { { bold = false, inline = inline } }
  end
  if inline.t == "Note" then
    local deep = false
    inline:walk({ Math = function(math) if bad_math(math.text) then deep = true end end })
    return { { bold = not deep, inline = inline } }
  end
  if not inline.content then return { { bold = true, inline = inline } } end

  local groups = {}
  for _, child in ipairs(inline.content) do
    for _, piece in ipairs(split_bad_math(child)) do
      local group = groups[#groups]
      if group and group.bold == piece.bold then
        group.content[#group.content + 1] = piece.inline
      else
        groups[#groups + 1] = { bold = piece.bold, content = { piece.inline } }
      end
    end
  end
  if #groups == 1 and groups[1].bold then
    return { { bold = true, inline = inline } }
  end
  local result = {}
  for _, group in ipairs(groups) do
    if group.bold then
      result[#result + 1] = {
        bold = true,
        inline = inline_with_content(inline, group.content),
      }
    else
      for _, child in ipairs(group.content) do
        result[#result + 1] = { bold = false, inline = child }
      end
    end
  end
  return result
end

local function strong_fix(el)
  local out, run, changed = {}, {}, false
  local function flush()
    if #run > 0 then out[#out + 1] = pandoc.Strong(run); run = {} end
  end
  for _, inline in ipairs(el.content) do
    for _, piece in ipairs(split_bad_math(inline)) do
      if piece.bold then
        run[#run + 1] = piece.inline
      else
        flush()
        out[#out + 1] = piece.inline
        changed = true
      end
    end
  end
  if changed then flush(); return out end
  return nil
end

local function table_fix(t)
  local cap = t.caption                                -- never touch the caption
  t = t:walk({ Strong = strong_fix })
  t.caption = cap
  return t
end

-- Inverse of envs_to_divs: turn the marker Div back into \begin{env}[opt] .. \end{env}.
local function div_fix(el)
  local env = el.attributes["lenv"]
  if not env then return nil end
  local opt = State.env_opts[tonumber(el.attributes["lopt"] or "")] or ""
  local out = { pandoc.RawBlock("latex", "\\begin{" .. env .. "}" .. opt) }
  for _, b in ipairs(el.content) do out[#out + 1] = b end
  out[#out + 1] = pandoc.RawBlock("latex", "\\end{" .. env .. "}")
  return out
end

-- ----------------------------------------------------------------------
-- §6.6  AST pipeline.  Each row is one `doc:walk(filter)`; ORDER MATTERS.
-- ----------------------------------------------------------------------
-- Math handler: repair bold Greek / math environments first, then Unicode scripts on the result.
local function math_pipeline(el)
  local r = math_fix(el)
  return math_super(r or el) or r
end

local AST_PASSES = {
  { name = "tables",  filter = { Table = table_fix } },
  { name = "inlines", filter = {
      Math      = math_pipeline,
      Image     = image_fix,
      Link      = link_fix,
      RawInline = function(el) return raw_html_fix(el) or rawblock_super(el) end,
      Str       = str_fix,
      Code      = note_code_super,
      CodeBlock = note_code_super,
  } },
  { name = "blocks",  filter = {
      Figure    = figure_fix,
      RawBlock  = function(el) return raw_html_fix(el) or rawblock_super(el) end,
      Div       = div_fix,
  } },
}


-- ======================================================================
-- §7  STAGE C  --  FINALIZE  (metadata, header-includes, summary warnings)
-- ======================================================================

-- Define, in the preamble, the superscript letters that occur inside code.
local function define_code_superscripts()
  local chars = {}
  for ch in pairs(State.code_super) do chars[#chars+1] = ch end
  if #chars == 0 then return end
  table.sort(chars)
  State.hoisted[#State.hoisted+1] = "\\usepackage{newunicodechar}"
  for _, ch in ipairs(chars) do
    State.hoisted[#State.hoisted+1] = "\\newunicodechar{" .. ch .. "}{\\textsuperscript{" .. SUPER_LETTERS[ch] .. "}}"
  end
  warn(string.format("defined %d superscript letter(s) for code text in the preamble", #chars))
end

local function report_super_fixes()
  if State.super_fixes > 0 then
    warn(string.format("converted %d text/formula piece(s) with Unicode super/subscripts (U+02E2, x\xC2\xB2, x\xE2\x82\x81 ...)", State.super_fixes))
  end
end

local function report_scrub_counts()
  if State.citation_strips > 0 then
    warn(string.format("removed %d citation-marker character(s)", State.citation_strips))
  end
  if State.emoji_strips > 0 then
    warn(string.format("removed %d unsupported emoji character(s); check/cross/warning symbols were preserved", State.emoji_strips))
  end
end

-- title / author / date taken from a pasted preamble (never overrides real metadata)
local function apply_extra_meta(doc)
  for k, v in pairs(State.extra_meta) do
    if doc.meta[k] == nil then doc.meta[k] = pandoc.MetaInlines({ pandoc.RawInline("latex", v) }) end
  end
end

-- Map only the supported YAML preset to the template flag; invalid values warn and keep A4.
local function apply_page_layout(doc)
  local value = doc.meta["page-layout"]
  if not value then return end
  local layout = pandoc.utils.stringify(value):match("^%s*(.-)%s*$"):lower()
  if layout == "presentation" then
    doc.meta.presentation_layout = pandoc.MetaBool(true)
  else
    warn("unsupported page-layout '" .. layout .. "'; using A4 (supported value: presentation)")
  end
end

-- everything collected in State.hoisted goes into pandoc's header-includes
local function inject_header_includes(doc)
  if #State.hoisted == 0 then return end
  local hi = doc.meta["header-includes"]
  local list = {}
  if hi then
    if hi.t == "MetaList" then for _, x in ipairs(hi) do list[#list+1] = x end else list[1] = hi end
  end
  list[#list+1] = pandoc.MetaBlocks({ pandoc.RawBlock("latex", table.concat(State.hoisted, "\n")) })
  doc.meta["header-includes"] = pandoc.MetaList(list)
  warn(string.format("moved %d preamble line(s) out of the body", #State.hoisted))
end

-- Ordered: later steps may read what earlier ones append to State.hoisted.
local FINALIZE_STEPS = {
  { name = "code-superscripts", apply = define_code_superscripts },
  { name = "report-scripts",    apply = report_super_fixes },
  { name = "report-scrubs",     apply = report_scrub_counts },
  { name = "page-layout",      apply = apply_page_layout },
  { name = "extra-meta",        apply = apply_extra_meta },
  { name = "header-includes",   apply = inject_header_includes },
}


-- ======================================================================
-- §8  ENTRY POINT
-- ======================================================================

-- Stage A + parse: replace pandoc's initial parse with the combined cleaned text for supported
-- inputs.  All input files must be cleanable; otherwise preserve Pandoc's original parse.
local function copy_state_value(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do copy[key] = copy_state_value(item) end
  return copy
end

local function load_cleaned_input(doc)
  local files = PANDOC_STATE and PANDOC_STATE.input_files or {}
  if #files == 0 then
    warn("stdin input cannot be re-read for text cleaning; applying AST fixes only")
    return doc
  end
  local initial_state = copy_state_value(State)
  local function fallback()
    for key in pairs(State) do State[key] = nil end
    for key, value in pairs(initial_state) do State[key] = value end
    return doc
  end
  local blocks, cleaned_meta = {}, nil
  for _, file in ipairs(files) do
    if file == "-" then
      warn("stdin input cannot be re-read for text cleaning; applying AST fixes only")
      return fallback()
    end
    local ext = file:match("%.(%w+)$")
    if not (ext and CONFIG.cleanable_extensions[ext:lower()]) then
      return fallback()                                   -- other input: just apply AST fixes
    end
    local fh, err = io.open(file, "rb")
    if not fh then
      fallback()
      warn("cannot open '" .. file .. "' (" .. tostring(err) .. ") -- input was NOT cleaned!")
      return doc
    end
    local raw = fh:read("a"); fh:close()
    local parsed = pandoc.read(clean(raw), CONFIG.reader)
    if not cleaned_meta then cleaned_meta = parsed.meta
    else
      for key, value in pairs(parsed.meta) do
        if cleaned_meta[key] == nil then cleaned_meta[key] = value end
      end
    end
    for _, block in ipairs(parsed.blocks) do blocks[#blocks+1] = block end
  end
  for key, value in pairs(doc.meta) do cleaned_meta[key] = value end
  return pandoc.Pandoc(blocks, cleaned_meta)                -- preserve cleaned YAML and CLI overrides
end

function Pandoc(doc)
  doc = load_cleaned_input(doc)                                  -- Stage A
  for _, pass in ipairs(AST_PASSES) do doc = doc:walk(pass.filter) end   -- Stage B
  for _, step in ipairs(FINALIZE_STEPS) do step.apply(doc) end   -- Stage C
  if doc.meta.bibliography or doc.meta.references then
    if pandoc.utils.citeproc then doc = pandoc.utils.citeproc(doc)
    else
      warn("this Pandoc version cannot run citeproc after text cleaning; use a version with pandoc.utils.citeproc")
    end
  end
  return doc
end

return { { Pandoc = Pandoc } }


-- ======================================================================
-- REGRESSION CHECK  (R5)
-- ======================================================================
--  Keep a representative sample (every feature listed in the header of
--  this file) as  sample.md  and a frozen reference output:
--
--      pandoc sample.md -f markdown -t latex --lua-filter=config/markdown-normalizer.lua \
--             -o sample.tex  2> sample.warnings.txt
--
--  Commit sample.tex and sample.warnings.txt.  After ANY edit of this file
--  re-run the command and diff against the frozen copies: the diff must be
--  empty, or contain exactly the change you intended.
-- ======================================================================