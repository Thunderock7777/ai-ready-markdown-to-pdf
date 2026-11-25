-- html-collapsible-boxes.lua
-- Pandoc Lua filter for LaTeX-to-HTML conversion (whiteboard_html layout).
-- Transforms LaTeX marginbox and tcolorbox environments into HTML5 <details> and <summary>
-- elements with progressive hierarchical collapse:
-- 1. If a box has a title, the summary bar displays that title.
-- 2. If untitled, the summary bar displays the custom prompt "Click for more info".
-- 3. Clicking any box opens ONLY its immediate children; grandchildren and deeper stay collapsed.
-- 4. Dynamic hex colors are extracted from \definecolor definitions in the .tex file and assigned by nesting depth.

local depth_colors = {
  [1] = "#1A9E39",
  [2] = "#9E6B1A",
  [3] = "#1A469E",
  [4] = "#9E1A91",
  [5] = "#1A9E9E",
  [6] = "#5C9E1A",
}

local function load_colors_from_tex()
  local path = PANDOC_STATE and PANDOC_STATE.input_files and PANDOC_STATE.input_files[1]
  if not path then return end
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  for d, hex in content:gmatch("\\definecolor%s*{genboxT%d+D(%d+)}%s*{HTML}%s*{([%x]+)}") do
    depth_colors[tonumber(d)] = "#" .. hex
  end
end

local function transform_div(el, depth)
  if not (el.classes:includes("marginbox") or el.classes:includes("tcolorbox") or el.classes:includes("vbox")) then
    return el
  end

  local title = "Click for more info"
  local body_blocks = {}
  local start_idx = 1

  if #el.content > 0 and el.content[1].tag == "Para" then
    local p = el.content[1]
    if #p.content > 0 and p.content[1].tag == "Span" then
      local span_text = pandoc.utils.stringify(p.content[1]):match("^%s*(.-)%s*$")
      if span_text and span_text ~= "" then
        title = span_text
      end
      local remaining_inlines = {}
      for i = 2, #p.content do
        remaining_inlines[#remaining_inlines + 1] = p.content[i]
      end
      if #remaining_inlines > 0 then
        body_blocks[#body_blocks + 1] = pandoc.Para(remaining_inlines)
      end
      start_idx = 2
    end
  end

  for i = start_idx, #el.content do
    body_blocks[#body_blocks + 1] = el.content[i]
  end

  local color_hex = depth_colors[depth] or depth_colors[((depth - 1) % 6) + 1] or "#1A9E39"

  local processed_body = {}
  for _, b in ipairs(body_blocks) do
    if b.tag == "Div" and (b.classes:includes("marginbox") or b.classes:includes("tcolorbox") or b.classes:includes("vbox")) then
      local sub_res = transform_div(b, depth + 1)
      if type(sub_res) == "table" and sub_res[1] then
        for _, sb in ipairs(sub_res) do processed_body[#processed_body + 1] = sb end
      else
        processed_body[#processed_body + 1] = sub_res
      end
    else
      processed_body[#processed_body + 1] = b
    end
  end

  local open_html = string.format([[
<details class="marginbox" style="--box-col: %s;">
  <summary class="marginbox-header">%s</summary>
  <div class="marginbox-body">]], color_hex, title)

  local close_html = [[
  </div>
</details>]]

  local res = { pandoc.RawBlock("html", open_html) }
  for _, b in ipairs(processed_body) do
    res[#res + 1] = b
  end
  res[#res + 1] = pandoc.RawBlock("html", close_html)
  return res
end

function Pandoc(doc)
  load_colors_from_tex()
  local new_blocks = {}
  for _, b in ipairs(doc.blocks) do
    if b.tag == "Div" and (b.classes:includes("marginbox") or b.classes:includes("tcolorbox") or b.classes:includes("vbox")) then
      local sub = transform_div(b, 1)
      for _, sb in ipairs(sub) do new_blocks[#new_blocks + 1] = sb end
    else
      new_blocks[#new_blocks + 1] = b
    end
  end
  return pandoc.Pandoc(new_blocks, doc.meta)
end
