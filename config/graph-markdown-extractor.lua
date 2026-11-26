-- graph-markdown-extractor.lua
-- Runs on the normalized Pandoc AST (after markdown-normalizer.lua) to emit
-- clean standard Markmap Markdown preserving full document hierarchy:
-- # Root followed by unified nested bullet hierarchy for headings, subheadings,
-- marginbox/tcolorbox/vbox boxes (and headings inside boxes), lists, KaTeX-safe
-- math ($...$), code spans, and item-level jump-target metadata.

local function esc_attr(s)
  return (s or ""):gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function trim(s)
  return ((s or ""):gsub("^[ \t\r\n]*(.-)[ \t\r\n]*$", "%1"))
end

local function collapse_ws(s)
  local norm = (s or ""):gsub("\194\160", " ")
  return trim(norm:gsub("[ \t\r\n]+", " "))
end

local function norm_key(s)
  return collapse_ws(s):lower()
end

local function safe_code_span(text)
  local t = (text or ""):gsub("[\r\n]+", " ")
  if t:find("`", 1, true) then
    return "`` " .. t .. " ``"
  end
  return "`" .. t .. "`"
end

-- Truncate without ever splitting a multi-byte UTF-8 character sequence
local function utf8_truncate(s, max_bytes)
  s = s or ""
  if #s <= max_bytes then return s end
  local cut = max_bytes
  while cut > 0 do
    local b = s:byte(cut)
    local next_b = s:byte(cut + 1)
    if next_b and next_b >= 128 and next_b < 192 then
      cut = cut - 1
    elseif b >= 192 then
      cut = cut - 1
    else
      break
    end
  end
  return trim(s:sub(1, math.max(0, cut)))
end

-- Extract plain prose words skipping raw LaTeX math (matches DOM elements cleanly
-- regardless of whether MathJax renders assistive MathML or SVGs).
local function inlines_prose_snip(inlines, include_math_fallback)
  local parts = {}
  local function walk(list)
    for _, el in ipairs(list or {}) do
      local tag = el.tag
      if tag == "Str" then
        parts[#parts + 1] = el.text or ""
      elseif tag == "Space" or tag == "SoftBreak" or tag == "LineBreak" then
        parts[#parts + 1] = " "
      elseif tag == "Code" then
        parts[#parts + 1] = el.text or ""
      elseif tag == "Math" then
        if include_math_fallback then
          parts[#parts + 1] = " " .. (el.text or "") .. " "
        end
      elseif tag == "Span" or tag == "Cite" then
        if not (el.identifier and el.identifier:match("^boxcol:")) then
          walk(el.content)
        end
      elseif el.content then
        walk(el.content)
      end
    end
  end
  walk(inlines)
  local s = collapse_ws(table.concat(parts, ""))
  if s == "" and not include_math_fallback then
    return inlines_prose_snip(inlines, true)
  end
  return utf8_truncate(s, 110)
end

-- Sanitize inline math so @iktakahiro/markdown-it-katex parses cleanly without
-- display-only errors (\tag), unicode dash strict warnings, or truncated braces.
local function clean_math_for_katex(raw_tex)
  local tex = collapse_ws(raw_tex or "")
  if tex == "" then return "", "" end

  local tag_suffix = ""
  tex = tex:gsub("\\tag%*?%s*(%b{})", function(grp)
    local inner = trim(grp:sub(2, -2))
    if inner ~= "" and tag_suffix == "" then
      tag_suffix = " (" .. inner .. ")"
    end
    return ""
  end)
  tex = tex:gsub("\\label%s*%b{}", "")
  tex = tex:gsub("\\nonumber%f[%A]", "")
  tex = tex:gsub("\\notag%f[%A]", "")
  tex = tex:gsub("\\bm%f[%A]", "\\boldsymbol")
  tex = tex:gsub("\226\128\147", "-")   -- UTF-8 en-dash (U+2013)
  tex = tex:gsub("\226\128\148", "--")  -- UTF-8 em-dash (U+2014)
  tex = tex:gsub("\226\136\146", "-")   -- UTF-8 minus sign (U+2212)
  tex = collapse_ws(tex)
  return tex, tag_suffix
end

local function single_inline_to_md(el)
  local tag = el.tag
  if tag == "Str" then
    return (el.text or ""):gsub("<", "&lt;"):gsub(">", "&gt;")
  elseif tag == "Space" or tag == "SoftBreak" or tag == "LineBreak" then
    return " "
  elseif tag == "Strong" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "**" .. table.concat(parts, "") .. "**"
  elseif tag == "Emph" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "*" .. table.concat(parts, "") .. "*"
  elseif tag == "Strikeout" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "~~" .. table.concat(parts, "") .. "~~"
  elseif tag == "Underline" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "<u>" .. table.concat(parts, "") .. "</u>"
  elseif tag == "Superscript" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "<sup>" .. table.concat(parts, "") .. "</sup>"
  elseif tag == "Subscript" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return "<sub>" .. table.concat(parts, "") .. "</sub>"
  elseif tag == "SmallCaps" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return table.concat(parts, "")
  elseif tag == "Code" then
    return safe_code_span(el.text)
  elseif tag == "Math" then
    local tex, tag_suffix = clean_math_for_katex(el.text)
    if tex == "" then
      return tag_suffix ~= "" and trim(tag_suffix) or ""
    end
    if #tex > 560 then
      return "[Equation" .. tag_suffix .. "]"
    end
    return "$" .. tex .. "$" .. tag_suffix
  elseif tag == "Link" then
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    local label = collapse_ws(table.concat(parts, ""))
    if label == "" then label = el.target or "link" end
    if el.target and el.target ~= "" then
      return "[" .. label .. "](" .. el.target .. ")"
    end
    return label
  elseif tag == "Image" then
    local cap = collapse_ws(pandoc.utils.stringify(el.caption))
    if cap == "" then cap = "figure" end
    return "[Image: " .. cap:gsub("<", "&lt;"):gsub(">", "&gt;") .. "]"
  elseif tag == "Quoted" then
    local q = (el.quotetype == "SingleQuote") and "'" or '"'
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return q .. table.concat(parts, "") .. q
  elseif tag == "Span" or tag == "Cite" then
    if el.identifier and el.identifier:match("^boxcol:") then
      return ""
    end
    local parts = {}
    for _, c in ipairs(el.content or {}) do parts[#parts + 1] = single_inline_to_md(c) end
    return table.concat(parts, "")
  elseif tag == "RawInline" then
    local fmt = el.format or ""
    if fmt == "html" then
      return el.text or ""
    elseif fmt == "tex" or fmt == "latex" then
      local txt = el.text or ""
      if txt:match("^\\hypertarget%b{}") or txt:match("^\\label%b{}") or txt:match("^\\vspace") or txt:match("^\\hspace") then
        return ""
      end
      local wrapped = txt:match("^\\textcolor%b{}{(.+)}$") or txt:match("^\\textbf{(.+)}$") or txt:match("^\\textit{(.+)}$")
      if wrapped then
        return wrapped:gsub("<", "&lt;"):gsub(">", "&gt;")
      end
    end
    return ""
  elseif el.content then
    local parts = {}
    for _, c in ipairs(el.content) do parts[#parts + 1] = single_inline_to_md(c) end
    return table.concat(parts, "")
  end
  return ""
end

local function inlines_to_md(inlines, max_len)
  local parts = {}
  local cur_len = 0
  local truncated = false
  for _, el in ipairs(inlines or {}) do
    local seg = single_inline_to_md(el)
    if seg ~= "" then
      if max_len and cur_len > 0 and (cur_len + #seg) > max_len and not seg:match("^[ \t\r\n]+$") then
        truncated = true
        break
      end
      parts[#parts + 1] = seg
      cur_len = cur_len + #seg
    end
  end
  local out = collapse_ws(table.concat(parts, ""))
  if truncated and out ~= "" then
    out = out .. " ..."
  end
  return out
end

local function extract_brace_arg(s, pos)
  if pos > #s or s:sub(pos, pos) ~= "{" then return nil, pos end
  local depth = 0
  local start = pos + 1
  for i = pos, #s do
    local ch = s:sub(i, i)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        return s:sub(start, i - 1), i + 1
      end
    end
  end
  return nil, pos
end

local function extract_bracket_arg(s, pos)
  if pos > #s or s:sub(pos, pos) ~= "[" then return nil, pos end
  local depth = 0
  local bdepth = 0
  local start = pos + 1
  for i = pos, #s do
    local ch = s:sub(i, i)
    if ch == "{" then depth = depth + 1
    elseif ch == "}" then depth = math.max(0, depth - 1)
    elseif ch == "[" and depth == 0 then bdepth = bdepth + 1
    elseif ch == "]" and depth == 0 then
      bdepth = bdepth - 1
      if bdepth == 0 then
        return s:sub(start, i - 1), i + 1
      end
    end
  end
  return nil, pos
end

local function parse_latex_box_begin(text)
  local trimmed = trim(text)
  local _, e_idx, env = trimmed:find("^\\begin%s*{(%a+)}")
  if not env then return nil end
  if env ~= "marginbox" and env ~= "tcolorbox" and env ~= "vbox" then
    return nil
  end
  local pos = e_idx + 1
  while pos <= #trimmed and trimmed:sub(pos, pos):match("%s") do pos = pos + 1 end
  local opts = nil
  if trimmed:sub(pos, pos) == "[" then
    opts, pos = extract_bracket_arg(trimmed, pos)
  end
  while pos <= #trimmed and trimmed:sub(pos, pos):match("%s") do pos = pos + 1 end
  local title_arg = nil
  if env == "marginbox" and trimmed:sub(pos, pos) == "{" then
    title_arg, pos = extract_brace_arg(trimmed, pos)
  end

  local title = title_arg and collapse_ws(title_arg) or ""
  if title == "" and opts then
    local tval = opts:match("title%s*=%s*(%b{})")
    if tval then
      title = collapse_ws(tval:sub(2, -2))
    else
      tval = opts:match("title%s*=%s*([^,%]]+)")
      if tval then title = collapse_ws(tval) end
    end
  end
  if title == "" then
    title = "Click for more info"
  end

  local hex = trimmed:match("\\hypertarget{boxcol:(%x%x%x%x%x%x)}")
  local color_hex = hex and ("#" .. hex) or nil
  if not color_hex and opts then
    local col_name = opts:match("colframe%s*=%s*([%w_]+)") or opts:match("color%s*=%s*([%w_]+)")
    local color_map = {
      NavyBlue = "#1e3a8a", RubineRed = "#be123c", ForestGreen = "#15803d",
      BurntOrange = "#c2410c", RoyalPurple = "#6d28d9", Gray = "#4b5563",
      TealBlue = "#0f766e", Magenta = "#a21caf", OliveGreen = "#4d7c0f",
      ProcessBlue = "#0284c7", Violet = "#7c3aed"
    }
    if col_name and color_map[col_name] then
      color_hex = color_map[col_name]
    end
  end

  return { env = env, title = title, color = color_hex }
end

local function make_mm_span(content_md, jump, extra_cls, color_hex, item_meta)
  local cls = "wb-mm-node" .. (extra_cls and (" " .. extra_cls) or "")
  local attrs = { string.format('class="%s"', esc_attr(cls)) }
  if jump then
    attrs[#attrs + 1] = string.format('data-wb-jtype="%s"', esc_attr(jump.jtype))
    if jump.jid and jump.jid ~= "" then
      attrs[#attrs + 1] = string.format('data-wb-jid="%s"', esc_attr(jump.jid))
    end
    if jump.jtitle and jump.jtitle ~= "" then
      attrs[#attrs + 1] = string.format('data-wb-jtitle="%s"', esc_attr(jump.jtitle))
    end
    if jump.jidx and jump.jidx > 0 then
      attrs[#attrs + 1] = string.format('data-wb-jidx="%d"', jump.jidx)
    end
    if jump.janc and jump.janc ~= "" then
      attrs[#attrs + 1] = string.format('data-wb-janc="%s"', esc_attr(jump.janc))
    end
  end
  if item_meta then
    if item_meta.jitem and item_meta.jitem ~= "" then
      attrs[#attrs + 1] = string.format('data-wb-jitem="%s"', esc_attr(item_meta.jitem))
    end
    if item_meta.jsnip and item_meta.jsnip ~= "" then
      attrs[#attrs + 1] = string.format('data-wb-jsnip="%s"', esc_attr(item_meta.jsnip))
    end
    if item_meta.jlidx and item_meta.jlidx > 0 then
      attrs[#attrs + 1] = string.format('data-wb-jlidx="%d"', item_meta.jlidx)
    end
  end
  if color_hex and color_hex ~= "" then
    attrs[#attrs + 1] = string.format('data-wb-color="%s"', esc_attr(color_hex))
  end
  return "<span " .. table.concat(attrs, " ") .. ">" .. content_md .. "</span>"
end

function Pandoc(doc)
  local lines = {}
  local heading_stack = {} -- array of { level = N, jump = ..., item_counts = {} }
  local box_stack = {}     -- array of { jump = ..., sub_headings = {}, item_counts = {} }
  local heading_counts = {}
  local box_counts = {}
  local top_item_counts = {}
  local box_seq = 0

  local doc_title = ""
  if doc.meta and doc.meta.title then
    doc_title = collapse_ws(pandoc.utils.stringify(doc.meta.title))
  end
  local root_label = doc_title ~= "" and doc_title or "Notes Graph"
  lines[#lines + 1] = "# " .. make_mm_span(root_label:gsub("<", "&lt;"):gsub(">", "&gt;"), {
    jtype = "top",
    jtitle = root_label,
    jidx = 1
  }, "wb-mm-root", nil, nil)

  local skip_env = nil

  local function current_sub_heading_depth()
    local d = 0
    for _, bf in ipairs(box_stack) do
      d = d + #bf.sub_headings
    end
    return d
  end

  local function current_base_indent()
    return #heading_stack + #box_stack + current_sub_heading_depth()
  end

  local function current_parent_hint()
    if #box_stack > 0 then
      return box_stack[#box_stack].jump.jtitle or ""
    end
    return ""
  end

  local function active_jump()
    if #box_stack > 0 then
      local top_box = box_stack[#box_stack]
      if #top_box.sub_headings > 0 then
        return top_box.sub_headings[#top_box.sub_headings].jump
      end
      return top_box.jump
    end
    if #heading_stack > 0 then
      return heading_stack[#heading_stack].jump
    end
    return { jtype = "top", jtitle = root_label, jidx = 1 }
  end

  local function next_item_lidx(jitem)
    local counts = top_item_counts
    if #box_stack > 0 then
      local bf = box_stack[#box_stack]
      if #bf.sub_headings > 0 then
        counts = bf.sub_headings[#bf.sub_headings].item_counts
      else
        counts = bf.item_counts
      end
    elseif #heading_stack > 0 then
      counts = heading_stack[#heading_stack].item_counts
    end
    counts[jitem] = (counts[jitem] or 0) + 1
    return counts[jitem]
  end

  local function emit_bullet(depth_offset, text_md, jump, extra_cls, color_hex, item_meta)
    local txt = trim(text_md)
    if txt == "" then return end
    local indent_lvl = math.max(0, current_base_indent() + (depth_offset or 0))
    lines[#lines + 1] = string.rep("  ", indent_lvl) .. "- " .. make_mm_span(txt, jump or active_jump(), extra_cls, color_hex, item_meta)
  end

  local walk_blocks
  local function walk_list(items, ordered, start_num, depth_offset)
    for idx, item_blocks in ipairs(items or {}) do
      local first_inline_md = nil
      local first_snip = ""
      local rest_blocks = {}
      for bi, b in ipairs(item_blocks) do
        if bi == 1 and (b.tag == "Plain" or b.tag == "Para") then
          first_inline_md = inlines_to_md(b.content, 280)
          first_snip = inlines_prose_snip(b.content, false)
        else
          rest_blocks[#rest_blocks + 1] = b
        end
      end
      local prefix = ordered and (tostring((start_num or 1) + idx - 1) .. ". ") or ""
      if first_inline_md and first_inline_md ~= "" then
        local meta = { jitem = "p", jsnip = first_snip, jlidx = next_item_lidx("p") }
        emit_bullet(depth_offset, prefix .. first_inline_md, active_jump(), "wb-mm-leaf", nil, meta)
        if #rest_blocks > 0 then
          walk_blocks(rest_blocks, depth_offset + 1)
        end
      elseif #rest_blocks > 0 then
        walk_blocks(rest_blocks, depth_offset)
      end
    end
  end

  local function extract_div_box(el)
    local title = "Click for more info"
    local color_hex = nil
    local body_blocks = {}
    if #el.content > 0 and el.content[1].tag == "Para" then
      local p = el.content[1]
      local rem = {}
      local found = false
      for _, inl in ipairs(p.content) do
        if inl.tag == "Span" and inl.identifier and inl.identifier:match("^boxcol:") then
          local hex = inl.identifier:match("^boxcol:(%x%x%x%x%x%x)$")
          if hex then color_hex = "#" .. hex end
        elseif inl.tag == "Span" and not found and #rem == 0 then
          local st = collapse_ws(pandoc.utils.stringify(inl))
          if st ~= "" then
            title = st
            found = true
          end
        else
          rem[#rem + 1] = inl
        end
      end
      if #rem > 0 then body_blocks[#body_blocks + 1] = pandoc.Para(rem) end
      for i = 2, #el.content do body_blocks[#body_blocks + 1] = el.content[i] end
    else
      body_blocks = el.content
    end
    return title, color_hex, body_blocks
  end

  walk_blocks = function(blocks, depth_offset)
    depth_offset = depth_offset or 0
    for _, b in ipairs(blocks or {}) do
      if skip_env then
        if b.tag == "RawBlock" and (b.format == "latex" or b.format == "tex") then
          if trim(b.text):find("^\\end%s*{" .. skip_env .. "}") then
            skip_env = nil
          end
        end
      elseif b.tag == "Header" then
        local plain = collapse_ws(pandoc.utils.stringify(b.content))
        local md = inlines_to_md(b.content, nil)
        local key = norm_key(plain)
        heading_counts[key] = (heading_counts[key] or 0) + 1
        local h_jump = {
          jtype = "h",
          jid = b.identifier or "",
          jtitle = plain,
          jidx = heading_counts[key],
          janc = current_parent_hint()
        }
        local label = "**" .. (md ~= "" and md or plain) .. "**"
        if #box_stack > 0 then
          local top_box = box_stack[#box_stack]
          while #top_box.sub_headings > 0 and top_box.sub_headings[#top_box.sub_headings].level >= b.level do
            table.remove(top_box.sub_headings)
          end
          emit_bullet(depth_offset, label, h_jump, "wb-mm-heading", nil, nil)
          top_box.sub_headings[#top_box.sub_headings + 1] = { level = b.level, jump = h_jump, item_counts = {} }
        else
          while #heading_stack > 0 and heading_stack[#heading_stack].level >= b.level do
            table.remove(heading_stack)
          end
          emit_bullet(depth_offset, label, h_jump, "wb-mm-heading", nil, nil)
          heading_stack[#heading_stack + 1] = { level = b.level, jump = h_jump, item_counts = {} }
        end
      elseif b.tag == "RawBlock" and (b.format == "latex" or b.format == "tex") then
        local t = trim(b.text)
        local begin_box = parse_latex_box_begin(t)
        if begin_box then
          box_seq = box_seq + 1
          local bkey = norm_key(begin_box.title)
          box_counts[bkey] = (box_counts[bkey] or 0) + 1
          local jtarget = {
            jtype = "box",
            jid = "wb-box-" .. tostring(box_seq),
            jtitle = begin_box.title,
            jidx = box_counts[bkey],
            janc = current_parent_hint()
          }
          local label = "**" .. begin_box.title:gsub("<", "&lt;"):gsub(">", "&gt;") .. "**"
          emit_bullet(depth_offset, label, jtarget, "wb-mm-box", begin_box.color, nil)
          box_stack[#box_stack + 1] = { jump = jtarget, sub_headings = {}, item_counts = {} }
        elseif t:match("^\\end%s*{marginbox}") or t:match("^\\end%s*{tcolorbox}") or t:match("^\\end%s*{vbox}") then
          if #box_stack > 0 then
            table.remove(box_stack)
          end
        else
          local vec_env = t:match("^\\begin%s*{(htmlsvg)}") or t:match("^\\begin%s*{(tikzpicture)}") or t:match("^\\begin%s*{(circuitikz)}")
          if vec_env then
            local meta = { jitem = "diag", jsnip = vec_env, jlidx = next_item_lidx("diag") }
            emit_bullet(depth_offset, "[Diagram: " .. vec_env .. "]", active_jump(), "wb-mm-leaf", nil, meta)
            if not t:find("\\end%s*{" .. vec_env .. "}") then
              skip_env = vec_env
            end
          end
        end
      elseif b.tag == "Div" then
        if b.classes:includes("marginbox") or b.classes:includes("tcolorbox") or b.classes:includes("vbox") then
          local title, color_hex, body_blocks = extract_div_box(b)
          box_seq = box_seq + 1
          local bkey = norm_key(title)
          box_counts[bkey] = (box_counts[bkey] or 0) + 1
          local jtarget = {
            jtype = "box",
            jid = "wb-box-" .. tostring(box_seq),
            jtitle = title,
            jidx = box_counts[bkey],
            janc = current_parent_hint()
          }
          emit_bullet(depth_offset, "**" .. title:gsub("<", "&lt;"):gsub(">", "&gt;") .. "**", jtarget, "wb-mm-box", color_hex, nil)
          box_stack[#box_stack + 1] = { jump = jtarget, sub_headings = {}, item_counts = {} }
          walk_blocks(body_blocks, 0)
          table.remove(box_stack)
        elseif b.classes:includes("wbhtmlembed") or b.classes:includes("html") then
          local t = collapse_ws(b.attributes and b.attributes["title"] or "Embedded HTML")
          local meta = { jitem = "html", jsnip = t, jlidx = next_item_lidx("html") }
          emit_bullet(depth_offset, "[Interactive HTML: " .. t .. "]", active_jump(), "wb-mm-leaf", nil, meta)
        else
          walk_blocks(b.content, depth_offset)
        end
      elseif b.tag == "Para" or b.tag == "Plain" then
        local md = inlines_to_md(b.content, 280)
        if md ~= "" then
          local meta = { jitem = "p", jsnip = inlines_prose_snip(b.content, false), jlidx = next_item_lidx("p") }
          emit_bullet(depth_offset, md, active_jump(), "wb-mm-leaf", nil, meta)
        end
      elseif b.tag == "BulletList" then
        walk_list(b.content, false, 1, depth_offset)
      elseif b.tag == "OrderedList" then
        local start_num = (b.listAttributes and b.listAttributes[1]) or 1
        walk_list(b.content, true, start_num, depth_offset)
      elseif b.tag == "BlockQuote" then
        walk_blocks(b.content, depth_offset)
      elseif b.tag == "CodeBlock" then
        local lang = (b.classes and b.classes[1]) or "code"
        if lang == "html" or lang == "htm" then
          local t = collapse_ws(b.attributes and b.attributes["title"] or "Embedded HTML")
          local meta = { jitem = "html", jsnip = t, jlidx = next_item_lidx("html") }
          emit_bullet(depth_offset, "[HTML Tab: " .. t .. "]", active_jump(), "wb-mm-leaf", nil, meta)
        else
          local first_line = ""
          for ln in (b.text or ""):gmatch("[^\r\n]+") do
            local cl = trim(ln)
            if cl ~= "" then
              first_line = cl
              break
            end
          end
          if #first_line > 72 then first_line = utf8_truncate(first_line, 69) .. "..." end
          local summary = "`" .. lang .. "`" .. (first_line ~= "" and (": " .. safe_code_span(first_line)) or " block")
          local meta = { jitem = "code", jsnip = first_line, jlidx = next_item_lidx("code") }
          emit_bullet(depth_offset, summary, active_jump(), "wb-mm-leaf", nil, meta)
        end
      elseif b.tag == "Table" then
        local cols = (b.colspecs and #b.colspecs) or 0
        local rows = 0
        local hdr_snip = ""
        if b.head and b.head.rows then
          rows = rows + #b.head.rows
          if b.head.rows[1] and b.head.rows[1].cells then
            local hparts = {}
            for _, cell in ipairs(b.head.rows[1].cells) do
              local cblocks = cell.contents or cell.content
              if cblocks then hparts[#hparts + 1] = collapse_ws(pandoc.utils.stringify(cblocks)) end
            end
            hdr_snip = utf8_truncate(collapse_ws(table.concat(hparts, " ")), 80)
          end
        end
        for _, tb in ipairs(b.bodies or {}) do
          rows = rows + (tb.body and #tb.body or 0)
        end
        local cap = b.caption and b.caption.long and collapse_ws(pandoc.utils.stringify(b.caption.long)) or ""
        local label = "Table (" .. tostring(rows) .. "×" .. tostring(cols) .. ")"
        if cap ~= "" then label = label .. ": " .. cap end
        local meta = { jitem = "tbl", jsnip = (cap ~= "" and cap or hdr_snip), jlidx = next_item_lidx("tbl") }
        emit_bullet(depth_offset, label:gsub("<", "&lt;"):gsub(">", "&gt;"), active_jump(), "wb-mm-leaf", nil, meta)
      end
    end
  end

  walk_blocks(doc.blocks, 0)

  local out_md = table.concat(lines, "\n") .. "\n"
  return pandoc.Pandoc({ pandoc.RawBlock("html", out_md) })
end
