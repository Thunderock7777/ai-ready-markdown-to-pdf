-- ======================================================================
--  tex-to-html-preprocessor.lua
--  Preprocesses LaTeX source for Pandoc HTML generation by converting
--  vector graphics environments (tikzpicture, circuitikz, etc.) and
--  arbitrary complex LaTeX in \begin{htmlsvg}...\end{htmlsvg} into
--  cached standalone SVGs via XeLaTeX + dvisvgm.
-- ======================================================================

local input_path = arg[1]
local output_path = arg[2]
local cache_dir = arg[3]

if not input_path or not output_path then
  io.stderr:write("Usage: texlua tex-to-html-preprocessor.lua <input.tex> <output.tex> [cache_dir]\n")
  os.exit(1)
end

cache_dir = cache_dir or "md2pdf_cache"
cache_dir = cache_dir:gsub("\\", "/")
if cache_dir:sub(-1) == "/" then
  cache_dir = cache_dir:sub(1, -2)
end

-- Ensure cache dir exists
if lfs and not lfs.attributes(cache_dir, "mode") then
  lfs.mkdir(cache_dir)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function write_file(path, content)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local content = read_file(input_path)
if not content then
  io.stderr:write("[tex-to-html-preprocessor] Error: cannot read input file: " .. input_path .. "\n")
  os.exit(1)
end

-- Extract preamble definitions to supply to the standalone snippet
local function extract_preamble_defs(tex)
  local doc_start = tex:find("\\begin%s*{document}")
  local preamble = doc_start and tex:sub(1, doc_start - 1) or tex
  local defs = {}

  for m in preamble:gmatch("\\definecolor%s*%b{}%s*%b{}%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\usetikzlibrary%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\usepgfplotslibrary%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\pgfplotsset%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\tikzset%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\DeclareMathOperator%*?%s*\\[%w_]+%s*%b{}") do
    defs[#defs + 1] = m
  end
  for m in preamble:gmatch("\\DeclarePairedDelimiter%*?%s*\\[%w_]+%s*%b{}%s*%b{}") do
    defs[#defs + 1] = m
  end

  return table.concat(defs, "\n")
end

local extra_preamble = extract_preamble_defs(content)

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

local target_envs = {
  tikzpicture = true,
  circuitikz = true,
  chemfig = true,
  quantikz = true,
  forest = true,
  tikzcd = true,
  htmlsvg = true,
}

local MATHJAX_SUPPORTED_ENVS = {
  equation = true, ["equation*"] = true,
  align = true, ["align*"] = true,
  alignat = true, ["alignat*"] = true,
  gather = true, ["gather*"] = true,
  multline = true, ["multline*"] = true,
  flalign = true, ["flalign*"] = true,
  split = true,
  aligned = true,
  gathered = true,
  alignedat = true,
  matrix = true,
  pmatrix = true,
  bmatrix = true,
  Bmatrix = true,
  vmatrix = true,
  Vmatrix = true,
  smallmatrix = true,
  cases = true,
  dcases = true,
  rcases = true,
  drcases = true,
  array = true,
  subarray = true,
  subequations = true,
  CD = true,
}

local MATH_ENVS = {
  equation = true, ["equation*"] = true,
  align = true, ["align*"] = true,
  alignat = true, ["alignat*"] = true,
  gather = true, ["gather*"] = true,
  multline = true, ["multline*"] = true,
  flalign = true, ["flalign*"] = true,
}

local TABLE_ENVS = {
  tabular = true, ["tabular*"] = true, tabularx = true, tabulary = true,
  longtable = true, supertabular = true,
}

local function is_mathjax_incompatible(str)
  for env in str:gmatch("\\begin%s*{([%w_%*]+)}") do
    if not MATHJAX_SUPPORTED_ENVS[env] then
      return true, "unsupported environment: " .. env
    end
  end
  if str:find("\\draw%f[%A]") or str:find("\\path%f[%A]") or str:find("\\node%f[%A]")
     or str:find("\\coordinate%f[%A]") or str:find("\\filldraw%f[%A]") or str:find("\\clip%f[%A]")
     or str:find("\\tikz%f[%A]") or str:find("\\addplot%f[%A]") then
    return true, "vector/tikz command"
  end
  if str:find("\\chemfig%f[%A]") or str:find("\\diagbox%f[%A]") or str:find("\\feynmandiagram%f[%A]")
     or str:find("\\xymatrix%f[%A]") or str:find("\\tcbox%f[%A]") or str:find("\\multirow%f[%A]") then
    return true, "unsupported macro"
  end
  if str:find("\\raisebox%f[%A]") or str:find("\\rotatebox%f[%A]") or str:find("\\scalebox%f[%A]")
     or str:find("\\reflectbox%f[%A]") or str:find("\\parbox%f[%A]") or str:find("\\hbox%f[%A]")
     or str:find("\\vbox%f[%A]") or str:find("\\hrule%f[%A]") or str:find("\\vrule%f[%A]") then
    return true, "tex layout primitive"
  end
  if str:find("\\qw%f[%A]") or str:find("\\gate%f[%A]") or str:find("\\meter%f[%A]")
     or str:find("\\ctrl%f[%A]") or str:find("\\targ%f[%A]") then
    return true, "quantum circuit command"
  end
  return false
end

local function render_snippet_to_svg(snippet_body, env_name)
  snippet_body = normalize_math_unicode(snippet_body)
  local full_tex = [[
\documentclass[preview,border=2pt,varwidth]{standalone}
\def\pgfsysdriver{pgfsys-dvisvgm.def}
\usepackage{mathtools,amsmath,amssymb,amsfonts,bm}
\IfFileExists{physics.sty}{\usepackage{physics}}{}
\providecommand{\Bra}[1]{\left\langle #1\right|}
\providecommand{\Ket}[1]{\left|#1\right\rangle}
\providecommand{\Braket}[1]{\left\langle #1\right\rangle}
\providecommand{\set}[1]{\left\{#1\right\}}
\providecommand{\Set}[1]{\left\{#1\right\}}
\usepackage{xcolor}
\usepackage{graphicx}
\usepackage{tikz}
\usepackage{pgfplots}
\pgfplotsset{compat=1.18}
\usetikzlibrary{arrows.meta,calc,positioning,shapes,decorations.pathmorphing,decorations.pathreplacing}
\IfFileExists{circuitikz.sty}{\usepackage{circuitikz}}{}
\IfFileExists{chemfig.sty}{\usepackage{chemfig}}{}
\IfFileExists{quantikz.sty}{\usepackage{quantikz}}{}
\IfFileExists{forest.sty}{\usepackage{forest}}{}
\IfFileExists{tikz-cd.sty}{\usepackage{tikz-cd}}{}
\usepackage{booktabs,multirow,array}
\IfFileExists{colortbl.sty}{\usepackage{colortbl}}{}
\IfFileExists{diagbox.sty}{\usepackage{diagbox}}{}
]] .. extra_preamble .. "\n\\begin{document}\n" .. snippet_body .. "\n\\end{document}\n"

  local hash = md5 and md5.sumhexa(full_tex) or tostring(#full_tex)
  local svg_filename = "svg_" .. hash .. ".svg"
  local svg_path = cache_dir .. "/" .. svg_filename
  local clean_path = svg_path:gsub("\\", "/")

  -- Check cache
  local sz = lfs and lfs.attributes(clean_path, "size")
  if sz and sz > 0 then
    return clean_path
  end

  -- Cache miss: compile via XeLaTeX + dvisvgm
  local tmp_tex_name = "tmp_" .. hash .. ".tex"
  local tmp_tex_path = cache_dir .. "/" .. tmp_tex_name
  if not write_file(tmp_tex_path, full_tex) then
    io.stderr:write("[tex-to-html-preprocessor] Error writing temporary tex file: " .. tmp_tex_path .. "\n")
    return nil
  end

  local fwd_cache_dir = cache_dir:gsub("\\", "/")
  local fwd_tmp_tex = tmp_tex_path:gsub("\\", "/")
  local fwd_xdv = (cache_dir .. "/tmp_" .. hash .. ".xdv"):gsub("\\", "/")
  local fwd_svg = clean_path:gsub("\\", "/")

  local cmd_xelatex = string.format('xelatex -cnf-line=max_print_line=1000 -no-pdf -interaction=nonstopmode -output-directory="%s" "%s" >nul 2>&1',
    fwd_cache_dir, fwd_tmp_tex)
  os.execute(cmd_xelatex)

  local cmd_dvisvgm = string.format('dvisvgm --no-fonts -o "%s" "%s" >nul 2>&1', fwd_svg, fwd_xdv)
  os.execute(cmd_dvisvgm)

  -- Cleanup temporary auxiliary files
  os.remove(tmp_tex_path)
  os.remove(cache_dir .. "/tmp_" .. hash .. ".xdv")
  os.remove(cache_dir .. "/tmp_" .. hash .. ".aux")
  os.remove(cache_dir .. "/tmp_" .. hash .. ".log")

  sz = lfs and lfs.attributes(clean_path, "size")
  if sz and sz > 0 then
    return clean_path
  else
    io.stderr:write("[tex-to-html-preprocessor] Warning: failed to generate SVG for " .. env_name .. " (hash " .. hash .. ")\n")
    return nil
  end
end

-- Pandoc's LaTeX reader drops \begin{minipage}...\end{minipage} cells inside longtable
-- if they contain bare `\\` linebreaks. Convert top-level `\\` inside minipage cells
-- (outside math spans and nested environments like pmatrix) to `\newline`.
local function sanitize_table_minipage_breaks(tbl_tex)
  local function rewrite_minipage(body)
    local out = {}
    local i, len = 1, #body
    local math_paren = false
    local math_dollar = false
    local env_depth = 0
    while i <= len do
      if body:sub(i, i + 1) == "\\(" then
        math_paren = true
        out[#out + 1] = "\\("
        i = i + 2
      elseif math_paren and body:sub(i, i + 1) == "\\)" then
        math_paren = false
        out[#out + 1] = "\\)"
        i = i + 2
      elseif not math_paren and body:sub(i, i) == "$" and (i == 1 or body:sub(i - 1, i - 1) ~= "\\") then
        math_dollar = not math_dollar
        out[#out + 1] = "$"
        i = i + 1
      elseif body:sub(i, i + 5) == "\\begin" then
        env_depth = env_depth + 1
        out[#out + 1] = "\\begin"
        i = i + 6
      elseif body:sub(i, i + 3) == "\\end" then
        if env_depth > 0 then env_depth = env_depth - 1 end
        out[#out + 1] = "\\end"
        i = i + 4
      elseif not math_paren and not math_dollar and env_depth == 0 and body:sub(i, i + 1) == "\\\\" then
        local after = body:sub(i + 2, i + 2)
        if after == "[" or after == "*" then
          out[#out + 1] = "\\\\"
          i = i + 2
        else
          out[#out + 1] = "\\newline"
          i = i + 2
        end
      else
        out[#out + 1] = body:sub(i, i)
        i = i + 1
      end
    end
    return table.concat(out)
  end

  return tbl_tex:gsub("(\\begin%s*{minipage}%s*%b[]%s*%b{})(.-)(\\end%s*{minipage})", function(head, body, tail)
    return head .. rewrite_minipage(body) .. tail
  end)
end

-- Process target environments
local function process_environments(tex)
  local pos = 1
  local chunks = {}
  local doc_start = tex:find("\\begin%s*{document}") or 1

  chunks[#chunks + 1] = tex:sub(1, doc_start - 1)
  pos = doc_start

  while true do
    local b_start, b_end, env = tex:find("\\begin%s*{([%w_%*]+)}", pos)
    if not b_start then
      chunks[#chunks + 1] = tex:sub(pos)
      break
    end

    local is_target = target_envs[env]
    local is_math = MATH_ENVS[env]
    local is_table = TABLE_ENVS[env]

    if is_target or is_math or is_table then
      chunks[#chunks + 1] = tex:sub(pos, b_start - 1)

      -- Nesting-aware search for matching \end{env}
      local search_pos = b_end + 1
      local depth = 1
      local block_end = nil

      while depth > 0 do
        local next_b_start, next_b_end = tex:find("\\begin%s*{" .. env .. "}", search_pos)
        local next_e_start, next_e_end = tex:find("\\end%s*{" .. env .. "}", search_pos)

        if not next_e_start then
          -- Unmatched \begin, break
          break
        end

        if next_b_start and next_b_start < next_e_start then
          depth = depth + 1
          search_pos = next_b_end + 1
        else
          depth = depth - 1
          if depth == 0 then
            block_end = next_e_end
          else
            search_pos = next_e_end + 1
          end
        end
      end

      if block_end then
        local full_block = tex:sub(b_start, block_end)
        local should_convert = false
        local snippet_body = full_block

        if is_target then
          should_convert = true
          if env == "htmlsvg" then
            -- Strip \begin{htmlsvg} and \end{htmlsvg}
            local inner = full_block:match("^\\begin%s*{htmlsvg}%s*(.-)%s*\\end%s*{htmlsvg}$")
            snippet_body = inner or full_block
          end
        elseif is_math then
          local incomp, reason = is_mathjax_incompatible(full_block)
          if incomp then
            io.stdout:write("[tex-to-html-preprocessor] Auto-detected MathJax-incompatible " .. env .. " (" .. reason .. "); routing to SVG...\n")
            should_convert = true
          end
        elseif is_table then
          if full_block:find("\\diagbox%f[%A]") or full_block:find("\\chemfig%f[%A]")
             or full_block:find("\\draw%f[%A]") or full_block:find("\\node%f[%A]") then
            io.stdout:write("[tex-to-html-preprocessor] Auto-detected complex table construct in " .. env .. "; routing to SVG...\n")
            should_convert = true
          else
            full_block = sanitize_table_minipage_breaks(full_block)
          end
        end

        if should_convert then
          local svg_path = render_snippet_to_svg(snippet_body, env)
          if svg_path then
            chunks[#chunks + 1] = string.format("\n\\begin{center}\\includegraphics{%s}\\end{center}\n", svg_path)
          else
            chunks[#chunks + 1] = full_block
          end
        else
          chunks[#chunks + 1] = full_block
        end
        pos = block_end + 1
      else
        chunks[#chunks + 1] = tex:sub(b_start, b_end)
        pos = b_end + 1
      end
    else
      chunks[#chunks + 1] = tex:sub(pos, b_end)
      pos = b_end + 1
    end
  end

  return table.concat(chunks)
end

-- Process \htmlsvg{...} inline macro if present
local function process_inline_htmlsvg(tex)
  return tex:gsub("\\htmlsvg%s*(%b{})", function(braced)
    local inner = braced:sub(2, -2)
    local svg_path = render_snippet_to_svg(inner, "htmlsvg_inline")
    if svg_path then
      return string.format("\\includegraphics{%s}", svg_path)
    else
      return "\\htmlsvg{" .. inner .. "}"
    end
  end)
end

-- Automatically detect and route MathJax-incompatible display math \[ ... \] to SVG
local function process_display_math(tex)
  local leading = "\n" .. tex
  local out = leading:gsub("([^\\])\\%[(.-)\\%]", function(prefix, body)
    if body:find("\\includegraphics") then
      return prefix .. "\n" .. body .. "\n"
    end
    local incomp, reason = is_mathjax_incompatible(body)
    if incomp then
      io.stdout:write("[tex-to-html-preprocessor] Auto-detected MathJax-incompatible display math (" .. reason .. "); routing to SVG...\n")
      local svg_path = render_snippet_to_svg("\\[\n" .. body .. "\n\\]", "display_math")
      if svg_path then
        return prefix .. string.format("\n\\begin{center}\\includegraphics{%s}\\end{center}\n", svg_path)
      end
    end
    return prefix .. "\\[" .. body .. "\\]"
  end)
  return out:sub(2)
end

-- Automatically detect and route MathJax-incompatible inline math \( ... \) to SVG
local function process_inline_math(tex)
  local leading = "\n" .. tex
  local out = leading:gsub("([^\\])\\%((.-)\\%)", function(prefix, body)
    if body:find("\\includegraphics") then
      return prefix .. body
    end
    local incomp, reason = is_mathjax_incompatible(body)
    if incomp then
      io.stdout:write("[tex-to-html-preprocessor] Auto-detected MathJax-incompatible inline math (" .. reason .. "); routing to SVG...\n")
      local svg_path = render_snippet_to_svg("\\(" .. body .. "\\)", "inline_math")
      if svg_path then
        return prefix .. string.format("\\includegraphics{%s}", svg_path)
      end
    end
    return prefix .. "\\(" .. body .. "\\)"
  end)
  return out:sub(2)
end

local PANDOC_TEXT_ESCAPES = {
  textbackslash = "\\",
  textless = "<",
  textgreater = ">",
  textquotesingle = "'",
  textasciigrave = "`",
  textasciitilde = "~",
  textbar = "|"
}

local SINGLE_CHAR_ESCAPES = {
  ["{"] = "{", ["}"] = "}", ["%"] = "%", ["#"] = "#",
  ["&"] = "&", ["_"] = "_", ['"'] = '"', [" "] = " "
}

local function find_matching_brace(s, open_pos)
  local depth = 1
  local i = open_pos + 1
  local len = #s
  while i <= len do
    local ch = s:sub(i, i)
    if ch == "\\" then
      i = i + 2
    elseif ch == "{" then
      depth = depth + 1
      i = i + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then return i end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

local function unwrap_tok_macros(s)
  local cur = s
  while true do
    local out = {}
    local pos = 1
    local changed = false
    while true do
      local m_start, m_end = cur:find("\\%a+Tok%s*{", pos)
      if not m_start then
        out[#out + 1] = cur:sub(pos)
        break
      end
      local close_pos = find_matching_brace(cur, m_end)
      if not close_pos then
        out[#out + 1] = cur:sub(pos, m_end)
        pos = m_end + 1
      else
        if m_start > pos then
          out[#out + 1] = cur:sub(pos, m_start - 1)
        end
        out[#out + 1] = cur:sub(m_end + 1, close_pos - 1)
        pos = close_pos + 1
        changed = true
      end
    end
    cur = table.concat(out)
    if not changed then break end
  end
  return cur
end

local function unescape_pandoc_highlighting(raw)
  local stripped = unwrap_tok_macros(raw)
  stripped = stripped:gsub("{%-}", "-")

  local out = {}
  local pos = 1
  local len = #stripped
  while pos <= len do
    local bs = stripped:find("\\", pos, true)
    if not bs then
      out[#out + 1] = stripped:sub(pos)
      break
    end
    if bs > pos then
      out[#out + 1] = stripped:sub(pos, bs - 1)
    end
    local _, cmd_end, cmd = stripped:find("^\\(text%a+)%s*{%s*}", bs)
    if cmd and PANDOC_TEXT_ESCAPES[cmd] then
      out[#out + 1] = PANDOC_TEXT_ESCAPES[cmd]
      pos = cmd_end + 1
    elseif stripped:sub(bs, bs + 3) == "\\^{}" then
      out[#out + 1] = "^"
      pos = bs + 4
    else
      local next_ch = stripped:sub(bs + 1, bs + 1)
      local mapped = SINGLE_CHAR_ESCAPES[next_ch]
      if mapped then
        out[#out + 1] = mapped
        pos = bs + 2
      else
        out[#out + 1] = "\\"
        pos = bs + 1
      end
    end
  end
  return table.concat(out)
end

-- Convert Pandoc Highlighting/Shaded code environments back to plain verbatim/lstlisting
-- so Pandoc's LaTeX reader (-f latex -t html5) emits proper <pre><code> blocks with intact line breaks/indentation.
local function unwrap_highlighting_blocks(tex)
  local function format_code_env(inner)
    local plain = unescape_pandoc_highlighting(inner)
    plain = plain:gsub("^\r?\n", ""):gsub("\r?\n$", "")
    if not plain:find("\\end{verbatim}", 1, true) then
      return "\n\\begin{verbatim}\n" .. plain .. "\n\\end{verbatim}\n"
    else
      return "\n\\begin{lstlisting}\n" .. plain .. "\n\\end{lstlisting}\n"
    end
  end

  tex = tex:gsub("\\let\\verbatim\\undefined%s*", "")
  tex = tex:gsub("\\let\\endverbatim\\undefined%s*", "")
  tex = tex:gsub("\\DefineVerbatimEnvironment%s*{verbatim}%b{}%b{}%s*", "")
  tex = tex:gsub("\\RecustomVerbatimEnvironment%s*{Highlighting}%b{}%b{}%s*", "")
  tex = tex:gsub("\\begin%s*{Shaded}%s*\\begin%s*{Highlighting}%s*%b[](.-)\\end%s*{Highlighting}%s*\\end%s*{Shaded}", format_code_env)
  tex = tex:gsub("\\begin%s*{Shaded}%s*\\begin%s*{Highlighting}(.-)\\end%s*{Highlighting}%s*\\end%s*{Shaded}", format_code_env)
  tex = tex:gsub("\\begin%s*{Highlighting}%s*%b[](.-)\\end%s*{Highlighting}", format_code_env)
  tex = tex:gsub("\\begin%s*{Highlighting}(.-)\\end%s*{Highlighting}", format_code_env)
  return tex
end

local processed = process_environments(content)
processed = process_inline_htmlsvg(processed)
processed = process_display_math(processed)
processed = process_inline_math(processed)
processed = unwrap_highlighting_blocks(processed)

if not write_file(output_path, processed) then
  io.stderr:write("[tex-to-html-preprocessor] Error: cannot write output file: " .. output_path .. "\n")
  os.exit(1)
end

io.stdout:write("[tex-to-html-preprocessor] Preprocessed LaTeX written to " .. output_path .. "\n")
