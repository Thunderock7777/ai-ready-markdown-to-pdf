-- html-collapsible-boxes.lua
-- Pandoc Lua filter for LaTeX-to-HTML conversion (whiteboard_html layout).
-- Transforms LaTeX marginbox and tcolorbox environments into HTML5 <details> and <summary>
-- elements with progressive hierarchical collapse:
-- 1. If a box has a title, the summary bar displays that title.
-- 2. If untitled, the summary bar displays the custom prompt "Click for more info".
-- 3. Clicking any box opens ONLY its immediate children; grandchildren and deeper stay collapsed.
-- 4. Dynamic hex colors are extracted from \definecolor definitions in the .tex file and assigned to each box.

local color_map = {
  NavyBlue = "#1A469E",
  RoyalPurple = "#651A9E",
  ForestGreen = "#1A9E39",
  BurntOrange = "#9E6B1A",
  RubineRed = "#9E1A46",
  TealBlue = "#1A9E9E",
  Magenta = "#9E1A78",
  OliveGreen = "#769E1A",
  ProcessBlue = "#1A869E",
  Violet = "#781A9E",
  Gray = "#666666",
  blue = "#1A469E",
  red = "#9E1A46",
  green = "#1A9E39",
  amber = "#9E6B1A",
  orange = "#9E6B1A",
  purple = "#651A9E",
  teal = "#1A9E9E",
  cyan = "#1A869E",
  olive = "#769E1A",
  gray = "#666666",
}

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
  for name, hex in content:gmatch("\\definecolor%s*{([%w_]+)}%s*{HTML}%s*{([%x]+)}") do
    color_map[name] = "#" .. hex
    local d = name:match("genboxT%d+D(%d+)")
    if d then
      depth_colors[tonumber(d)] = "#" .. hex
    end
  end
end

local function transform_div(el, depth)
  if not (el.classes:includes("marginbox") or el.classes:includes("tcolorbox") or el.classes:includes("vbox")) then
    return el
  end

  local title = "Click for more info"
  local color_hex = nil
  local body_blocks = {}
  local start_idx = 1

  if #el.content > 0 and el.content[1].tag == "Para" then
    local p = el.content[1]
    local remaining_inlines = {}
    local found_title = false

    for _, inline in ipairs(p.content) do
      if inline.tag == "Span" and inline.identifier and inline.identifier:match("^boxcol:") then
        local col_name = inline.identifier:match("^boxcol:(.+)")
        if col_name and color_map[col_name] then
          color_hex = color_map[col_name]
        end
      elseif inline.tag == "Span" and not found_title and #remaining_inlines == 0 then
        local span_text = pandoc.utils.stringify(inline):match("^%s*(.-)%s*$")
        if span_text and span_text ~= "" then
          title = span_text
          found_title = true
        end
      else
        remaining_inlines[#remaining_inlines + 1] = inline
      end
    end

    if #remaining_inlines > 0 then
      body_blocks[#body_blocks + 1] = pandoc.Para(remaining_inlines)
    end
    start_idx = 2
  end

  for i = start_idx, #el.content do
    body_blocks[#body_blocks + 1] = el.content[i]
  end

  if not color_hex then
    color_hex = depth_colors[depth] or depth_colors[((depth - 1) % 6) + 1] or "#1A9E39"
  end

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

  local safe_title = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")

  local open_html = string.format([[
<details class="marginbox" style="--box-col: %s;">
  <summary class="marginbox-header">%s</summary>
  <div class="marginbox-body">]], color_hex, safe_title)

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
