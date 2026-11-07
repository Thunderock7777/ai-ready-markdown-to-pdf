-- ======================================================================
--  error-annotator.lua  --  Annotates localized XeLaTeX errors with red [!!!]
--
--  Usage:
--    texlua config/error-annotator.lua <tex_file> <log_file>
--
--  Parses the XeLaTeX log file for localized file:line errors within the
--  document body, wraps the offending lines with red [!!!] error badges,
--  neutralizes broken tokens via \detokenize, and writes the annotated .tex
--  so a recovery compilation can produce the final PDF with errors visually marked.
-- ======================================================================

local tex_path = arg[1]
local log_path = arg[2]

if not tex_path or not log_path then
  io.stderr:write("[error-annotator] Usage: texlua error-annotator.lua <tex_file> <log_file>\n")
  os.exit(1)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function split_lines(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  return lines
end

-- TeX log files wrap long lines at 79 columns (max_print_line).
-- Unwrap wrapped lines before matching file:line:error records.
local function unwrap_tex_log(content)
  local lines = {}
  local buffer = ""
  for line in (content .. "\n"):gmatch("(.-)\r?\n") do
    if #buffer > 0 then
      buffer = buffer .. line
      if #line < 79 then
        lines[#lines + 1] = buffer
        buffer = ""
      end
    elseif #line >= 79 then
      buffer = line
    else
      lines[#lines + 1] = line
    end
  end
  if #buffer > 0 then
    lines[#lines + 1] = buffer
  end
  return lines
end

local log_content = read_file(log_path)
if not log_content then
  os.exit(1)
end

local tex_name = tex_path:match("([^/\\]+%.tex)$") or tex_path
local tex_name_esc = tex_name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")

local log_lines = unwrap_tex_log(log_content)
local err_map = {}

for _, line in ipairs(log_lines) do
  local f, l, msg = line:match("([%a%d_%-%.\\/]*[/\\]" .. tex_name_esc .. "):(%d+):%s*(.*)")
  if not f then
    f, l, msg = line:match("^(" .. tex_name_esc .. "):(%d+):%s*(.*)")
  end
  if not f then
    f, l, msg = line:match("([%s%(]" .. tex_name_esc .. "):(%d+):%s*(.*)")
  end

  if f and l and msg then
    if not msg:find("Missing character") and not msg:find("Overfull") and not msg:find("Underfull") then
      local lnum = tonumber(l)
      if lnum and not err_map[lnum] then
        err_map[lnum] = msg
      end
    end
  end
end

local err_count = 0
for _ in pairs(err_map) do err_count = err_count + 1 end
if err_count == 0 then
  os.exit(1)
end

local tex_content = read_file(tex_path)
if not tex_content then
  os.exit(1)
end

local tex_lines = split_lines(tex_content)

local doc_start, doc_end = 1, #tex_lines
for i, line in ipairs(tex_lines) do
  if line:find("\\begin{document}", 1, true) then
    doc_start = i
  elseif line:find("\\end{document}", 1, true) then
    doc_end = i
    break
  end
end

local body_errors = {}
for lnum, msg in pairs(err_map) do
  if lnum >= doc_start and lnum <= doc_end then
    body_errors[#body_errors + 1] = { line = lnum, msg = msg }
  end
end

if #body_errors == 0 then
  os.exit(1)
end

table.sort(body_errors, function(a, b) return a.line > b.line end)

local function sanitize_for_detokenize(s)
  -- Escape unescaped % so it does not comment out the closing brace of \detokenize
  local safe = s:gsub("(\\*)%%", function(slashes)
    if #slashes % 2 == 0 then
      return slashes .. "\\%"
    else
      return slashes .. "%"
    end
  end)

  -- Balance unescaped braces so \detokenize{...} closes without runaway errors
  local opens = 0
  for slashes in safe:gmatch("(\\*)%{") do
    if #slashes % 2 == 0 then opens = opens + 1 end
  end

  local closes = 0
  for slashes in safe:gmatch("(\\*)%}") do
    if #slashes % 2 == 0 then closes = closes + 1 end
  end

  if opens > closes then
    safe = safe .. string.rep("}", opens - closes)
  elseif closes > opens then
    safe = string.rep("{", closes - opens) .. safe
  end

  return safe
end

local annotated = 0
for _, item in ipairs(body_errors) do
  local idx = item.line
  local orig = tex_lines[idx]
  if orig and not orig:find("\\textcolor{red}{\\textbf{[!!!]}}", 1, true) then
    local indent = orig:match("^(%s*)") or ""
    local rest = orig:match("^%s*(.-)%s*$") or ""

    -- Invariant: Do not detokenize structural environment delimiters (\begin{env} or \end{env}).
    -- Detokenizing \end{itemize} or \end{enumerate} leaves the environment open, causing
    -- list indentation and margins to leak into all subsequent paragraphs and code blocks.
    local is_env_boundary = rest:match("^\\end%s*{[^}]+}%s*$") or rest:match("^\\begin%s*{[^}]+}%s*$")

    if not is_env_boundary then
      local row_end = rest:match("(\\\\)$") or rest:match("(\\tabularnewline)$") or ""
      if row_end ~= "" then
        rest = rest:sub(1, -#row_end - 1)
        rest = rest:match("^(.-)%s*$") or rest
      end

      -- If the line starts with a list \item, preserve the \item command outside \detokenize
      -- so the list structure remains valid and doesn't trigger "missing \item" cascade errors.
      local item_prefix = rest:match("^(\\item%s*%b[])%s*") or rest:match("^(\\item)%s*")
      if item_prefix then
        rest = rest:sub(#item_prefix + 1):match("^%s*(.-)%s*$") or ""
      end

      local prefix = item_prefix and (item_prefix .. " ") or ""
      local suffix = (row_end ~= "") and (" " .. row_end) or ""

      if rest ~= "" then
        local safe_content = sanitize_for_detokenize(rest)
        tex_lines[idx] = indent .. prefix .. [[\text{\textcolor{red}{\textbf{[!!!]}} \detokenize{]] .. safe_content .. [[}}]] .. suffix
        annotated = annotated + 1
      elseif not item_prefix then
        tex_lines[idx] = indent .. [[\text{\textcolor{red}{\textbf{[!!!]}}}]] .. suffix
        annotated = annotated + 1
      end
    end
  end
end

if annotated > 0 then
  write_file(tex_path, table.concat(tex_lines, "\n"))
  io.write(string.format("[error-annotator] Marked %d error(s) in PDF with red [!!!]\n", annotated))
  os.exit(0)
end

os.exit(1)
