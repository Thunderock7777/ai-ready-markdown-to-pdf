-- html-collapsible-boxes.lua
-- Pandoc Lua filter for LaTeX-to-HTML conversion (whiteboard_html layout).
-- Transforms LaTeX marginbox and tcolorbox environments into HTML5 <details> and <summary>
-- elements with progressive hierarchical collapse:
-- 1. If a box has a title, the summary bar displays that title.
-- 2. If untitled, the summary bar displays the custom prompt "Click for more info".
-- 3. Clicking any box opens ONLY its immediate children; grandchildren and deeper stay collapsed.
-- 4. Dynamic hex colors are mapped directly from box attributes or \definecolor in the .tex file.

local hex_map = {}
local whiteboard_width_css = nil
local max_box_depth = 1

local function load_tex_metadata()
  local path = PANDOC_STATE and PANDOC_STATE.input_files and PANDOC_STATE.input_files[1]
  if not path then return end
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  for name, hex in content:gmatch("\\definecolor%s*{([%w_]+)}%s*{HTML}%s*{([%x]+)}") do
    hex_map[name] = "#" .. hex
  end
  local wb = content:match("%% WHITEBOARD_WIDTH:%s*([%d%.]+in)")
  if not wb then
    wb = content:match("paperwidth%s*=%s*([%d%.]+in)")
  end
  if wb then
    whiteboard_width_css = wb
  end
end

local function transform_div(el, depth)
  if not (el.classes:includes("marginbox") or el.classes:includes("tcolorbox") or el.classes:includes("vbox")) then
    return el
  end

  if depth > max_box_depth then
    max_box_depth = depth
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
        local val = inline.identifier:match("^boxcol:(.+)")
        if val then
          if val:match("^%x%x%x%x%x%x$") then
            color_hex = "#" .. val
          elseif hex_map[val] then
            color_hex = hex_map[val]
          end
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

  color_hex = color_hex or "#1A9E39"

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
  load_tex_metadata()
  local new_blocks = {}
  for _, b in ipairs(doc.blocks) do
    if b.tag == "Div" and (b.classes:includes("marginbox") or b.classes:includes("tcolorbox") or b.classes:includes("vbox")) then
      local sub = transform_div(b, 1)
      for _, sb in ipairs(sub) do new_blocks[#new_blocks + 1] = sb end
    else
      new_blocks[#new_blocks + 1] = b
    end
  end

  -- Determine dynamic whiteboard width from tex metadata or box nesting depth
  if not whiteboard_width_css then
    local needed_in = 11.0 + math.max(0, max_box_depth - 1) * 1.5
    whiteboard_width_css = string.format("%.2fin", needed_in)
  end

  local header_includes = doc.meta["header-includes"] or pandoc.MetaList({})
  if header_includes.t ~= "MetaList" then
    header_includes = pandoc.MetaList({ header_includes })
  end

  local head_html = string.format([==[
<style>
:root {
  --whiteboard-width: %s;
  --document-width: var(--whiteboard-width);
}
</style>
<script>
window.MathJax = {
  tex: {
    inlineMath: [['\\(', '\\)']],
    displayMath: [['\\[', '\\]']],
    processEscapes: true,
    processEnvironments: true,
    macros: {
      bm: ['\\boldsymbol{#1}', 1],
      bra: ['\\left\\langle{#1}\\right|', 1],
      ket: ['\\left|{#1}\\right\\rangle', 1],
      braket: ['\\left\\langle{#1}\\middle|{#2}\\right\\rangle', 2]
    }
  },
  svg: {
    fontCache: 'global'
  },
  options: {
    ignoreHtmlClass: 'tex2jax_ignore',
    processHtmlClass: 'tex2jax_process'
  }
};
</script>]==], whiteboard_width_css)

  header_includes[#header_includes + 1] = pandoc.MetaBlocks({ pandoc.RawBlock("html", head_html) })
  doc.meta["header-includes"] = header_includes

  -- Floating reading & navigation toolbar (Expand/Collapse All, Theme, Scroll Top)
  local toolbar_html = [[
<div class="floating-toolbar" id="floatingToolbar" role="toolbar" aria-label="Reading Controls">
  <button id="btnToggleBoxes" type="button" title="Expand or collapse all boxes" aria-label="Toggle all boxes">
    <span id="toggleBoxesIcon">⊞</span> <span id="toggleBoxesLabel">Expand All</span>
  </button>
  <button id="btnToggleTheme" type="button" title="Switch theme" aria-label="Toggle dark/light theme">
    <span id="toggleThemeIcon">🌓</span> Theme
  </button>
  <button id="btnScrollTop" type="button" title="Scroll to top" aria-label="Scroll to top">
    ↑ Top
  </button>
</div>
<script>
(function() {
  // 1. Box Expand / Collapse Toggle
  var btnBoxes = document.getElementById('btnToggleBoxes');
  var lblBoxes = document.getElementById('toggleBoxesLabel');
  var icoBoxes = document.getElementById('toggleBoxesIcon');
  var allExpanded = false;

  if (btnBoxes) {
    btnBoxes.addEventListener('click', function() {
      allExpanded = !allExpanded;
      var boxes = document.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox');
      boxes.forEach(function(d) { d.open = allExpanded; });
      if (lblBoxes) lblBoxes.textContent = allExpanded ? 'Collapse All' : 'Expand All';
      if (icoBoxes) icoBoxes.textContent = allExpanded ? '⊟' : '⊞';
    });
  }

  // 2. Theme Toggle (Auto -> Dark -> Light -> Auto)
  var btnTheme = document.getElementById('btnToggleTheme');
  var currentTheme = localStorage.getItem('latex-theme') || 'auto';

  function applyTheme(theme) {
    document.body.classList.remove('latex-dark', 'latex-light');
    if (theme === 'dark') document.body.classList.add('latex-dark');
    if (theme === 'light') document.body.classList.add('latex-light');
    localStorage.setItem('latex-theme', theme);
    currentTheme = theme;
  }

  if (currentTheme !== 'auto') {
    applyTheme(currentTheme);
  }

  if (btnTheme) {
    btnTheme.addEventListener('click', function() {
      if (currentTheme === 'auto') {
        var isDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        applyTheme(isDark ? 'light' : 'dark');
      } else if (currentTheme === 'dark') {
        applyTheme('light');
      } else {
        applyTheme('auto');
      }
    });
  }

  // 3. Scroll to Top
  var btnTop = document.getElementById('btnScrollTop');
  if (btnTop) {
    btnTop.addEventListener('click', function() {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  }
})();
</script>]]

  new_blocks[#new_blocks + 1] = pandoc.RawBlock("html", toolbar_html)

  return pandoc.Pandoc(new_blocks, doc.meta)
end
