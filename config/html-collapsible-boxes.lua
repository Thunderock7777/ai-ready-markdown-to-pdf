-- html-collapsible-boxes.lua
-- Pandoc Lua filter for LaTeX-to-HTML conversion (whiteboard_html layout).
-- Transforms LaTeX marginbox and tcolorbox environments into HTML5 <details> and <summary>
-- elements with progressive hierarchical collapse, dynamic width, Option A annotations,
-- Tree View (Markmap), PDF-style Table of Contents, and offline/CDN asset modes.

local hex_map = {}
local whiteboard_width_css = nil
local html_assets = "offline"
local html_box_mode = "popup"
local html_cdn_base = "https://cdn.jsdelivr.net/gh/Thunderock7777/ai-ready-markdown-to-pdf@main"
local max_box_depth = 1
local annot_box_counter = 0
local annot_sec_counter = 0
local html_embed_counter = 0

local B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
do
  for i = 1, #B64_ALPHA do
    B64_REV[B64_ALPHA:byte(i)] = i - 1
  end
end

local function b64decode(data)
  if not data or data == "" then return "" end
  local out = {}
  local vals = {}
  for i = 1, #data do
    local b = data:byte(i)
    if b == 61 then
      vals[#vals + 1] = -1
    elseif B64_REV[b] then
      vals[#vals + 1] = B64_REV[b]
    end
    if #vals == 4 then
      local v1, v2, v3, v4 = vals[1], vals[2], vals[3], vals[4]
      vals = {}
      if v1 >= 0 and v2 >= 0 then
        out[#out + 1] = string.char(v1 * 4 + math.floor(v2 / 16))
        if v3 >= 0 then
          out[#out + 1] = string.char(((v2 % 16) * 16) + math.floor(v3 / 4))
          if v4 >= 0 then
            out[#out + 1] = string.char(((v3 % 4) * 64) + v4)
          end
        end
      end
    end
  end
  return table.concat(out)
end

local function b64encode(data)
  if not data or data == "" then return "" end
  local out = {}
  local len = #data
  for i = 1, len, 3 do
    local b1 = data:byte(i)
    local b2 = (i + 1 <= len) and data:byte(i + 1) or nil
    local b3 = (i + 2 <= len) and data:byte(i + 2) or nil
    local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    local c1 = math.floor(n / 262144) % 64 + 1
    local c2 = math.floor(n / 4096) % 64 + 1
    local c3 = math.floor(n / 64) % 64 + 1
    local c4 = n % 64 + 1
    out[#out + 1] = B64_ALPHA:sub(c1, c1)
      .. B64_ALPHA:sub(c2, c2)
      .. (b2 and B64_ALPHA:sub(c3, c3) or "=")
      .. (b3 and B64_ALPHA:sub(c4, c4) or "=")
  end
  return table.concat(out)
end

local function escape_html(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function is_box_div(el)
  return el.tag == "Div" and (el.classes:includes("marginbox") or el.classes:includes("tcolorbox") or el.classes:includes("vbox"))
end

local function read_text_file(p)
  if not p or p == "" then return nil end
  local f = io.open(p, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function load_viewer_js()
  local cfg_dir = os.getenv("MD2PDF_CONFIG_DIR")
  if cfg_dir and cfg_dir ~= "" then
    cfg_dir = cfg_dir:gsub("[\\/]+$", "")
    local js = read_text_file(cfg_dir .. "/wb-viewer.js")
    if js and js ~= "" then return js end
  end
  if PANDOC_SCRIPT_FILE then
    local dir = PANDOC_SCRIPT_FILE:match("^(.*)[\\/][^\\/]+$")
    if dir then
      local js = read_text_file(dir .. "/wb-viewer.js")
      if js and js ~= "" then return js end
    end
  end
  return nil
end

local function load_graph_bundle()
  local json_path = os.getenv("MD2PDF_GRAPH_JSON")
  if not json_path or json_path == "" then
    return nil
  end
  local payload_json = read_text_file(json_path)
  if not payload_json or payload_json == "" then return nil end

  local vendor_json = nil
  local vendor_path = os.getenv("MD2PDF_GRAPH_VENDOR")
  if vendor_path and vendor_path ~= "" then
    vendor_json = read_text_file(vendor_path)
  end

  return {
    payload_json = payload_json,
    vendor_json = vendor_json
  }
end

local function transform_html_embed(el)
  local raw = pandoc.utils.stringify(el):gsub("%s+", "")
  local title_b64, missing_b64, err_b64, inlined_str, html_b64 = raw:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
  if not html_b64 then
    return el
  end
  html_embed_counter = html_embed_counter + 1
  local embed_id = "wb-html-" .. tostring(html_embed_counter)
  local title = escape_html(b64decode(title_b64))
  if title == "" then title = "Open Interactive HTML" end
  local missing = escape_html(b64decode(missing_b64))
  local err_msg = escape_html(b64decode(err_b64))
  local inlined_count = tonumber(inlined_str) or 0

  if err_msg ~= "" then
    return pandoc.RawBlock("html", string.format(
      '<div class="wb-html-card wb-html-error" role="alert"><strong>%s</strong> — %s</div>',
      title, err_msg
    ))
  end

  local pill = ""
  if inlined_count > 0 then
    pill = string.format('<span class="wb-html-meta-pill">Inlined %d local asset%s</span>', inlined_count, inlined_count == 1 and "" or "s")
  end
  local warn_html = ""
  if missing ~= "" then
    warn_html = string.format(
      '<div class="wb-html-missing">⚠ Missing local asset(s): %s — HTML will still launch without them.</div>',
      missing
    )
  end

  local card_html = string.format([[
<div class="wb-html-card">
  <div class="wb-html-card-row">
    <span class="wb-html-card-title">📄 %s</span>
    <div class="wb-html-card-actions">
      %s
      <button type="button" class="wb-html-launch" data-wb-html-target="%s">Open in New Tab ↗</button>
    </div>
  </div>
  %s
</div>
<script type="text/plain" class="wb-html-b64" id="%s">%s</script>]],
    title, pill, embed_id, warn_html, embed_id, html_b64)
  return pandoc.RawBlock("html", card_html)
end

local function compute_doc_id(doc)
  local title = ""
  if doc.meta and doc.meta.title then
    title = pandoc.utils.stringify(doc.meta.title)
  end
  local seed = title .. "|" .. tostring(#doc.blocks) .. "|" .. tostring(whiteboard_width_css or "")
  local h = 2166136261
  for i = 1, #seed do
    h = (h * 16777619 + seed:byte(i)) % 4294967296
  end
  return string.format("wb-%08x", h)
end

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
  local box_mode = content:match("%% HTML_BOX_MODE:%s*(%S+)")
  if box_mode and (box_mode == "popup" or box_mode == "inline") then
    html_box_mode = box_mode
  end
  local assets = content:match("%% HTML_ASSETS:%s*(%S+)")
  if assets and (assets == "cdn" or assets == "offline") then
    html_assets = assets
  end
  local cdn = content:match("%% HTML_CDN_BASE:%s*([^\r\n]+)")
  if cdn then
    cdn = cdn:match("^%s*(.-)%s*$"):gsub("/+$", "")
    if cdn ~= "" then html_cdn_base = cdn end
  end
end

local MIME_BY_EXT = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  svg = "image/svg+xml"
}

local function inline_local_image(el)
  if html_assets ~= "cdn" or not el.src or el.src == "" then
    return nil
  end
  if el.src:match("^https?://") or el.src:match("^data:") or el.src:match("^//") then
    return nil
  end
  local ext = (el.src:match("%.([%a%d]+)$") or ""):lower()
  local mime = MIME_BY_EXT[ext]
  if not mime then return nil end
  local bytes = read_text_file(el.src)
  if not bytes then return nil end
  el.src = "data:" .. mime .. ";base64," .. b64encode(bytes)
  return el
end

local process_block_sequence

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
  annot_box_counter = annot_box_counter + 1
  local box_annot_id = "box-" .. tostring(annot_box_counter)

  local processed_body = process_block_sequence(body_blocks, depth + 1)
  local safe_title = escape_html(title)

  local open_html = string.format([[
<details class="marginbox" id="wb-%s" style="--box-col: %s;">
  <summary class="marginbox-header">%s</summary>
  <div class="marginbox-body" data-wb-annot-id="%s">]], box_annot_id, color_hex, safe_title, box_annot_id)

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

process_block_sequence = function(blocks, depth)
  local out = {}
  local flow_buf = {}

  local function flush_flow()
    if #flow_buf == 0 then return end
    annot_sec_counter = annot_sec_counter + 1
    local sec_id = "sec-" .. tostring(annot_sec_counter)
    out[#out + 1] = pandoc.RawBlock("html", string.format('<div class="wb-flow-section" data-wb-annot-id="%s">', sec_id))
    for _, fb in ipairs(flow_buf) do
      out[#out + 1] = fb
    end
    out[#out + 1] = pandoc.RawBlock("html", '</div>')
    flow_buf = {}
  end

  for _, b in ipairs(blocks) do
    if is_box_div(b) then
      flush_flow()
      local sub_res = transform_div(b, math.max(1, depth))
      for _, sb in ipairs(sub_res) do
        out[#out + 1] = sb
      end
    elseif b.tag == "Div" and b.classes:includes("wbhtmlembed") then
      flow_buf[#flow_buf + 1] = transform_html_embed(b)
    else
      flow_buf[#flow_buf + 1] = b
    end
  end
  flush_flow()
  return out
end

function Pandoc(doc)
  load_tex_metadata()
  annot_box_counter = 0
  annot_sec_counter = 0
  html_embed_counter = 0

  if html_assets == "cdn" then
    doc = doc:walk({ Image = inline_local_image })
  end

  local new_blocks = process_block_sequence(doc.blocks, 0)
  local doc_id = compute_doc_id(doc)

  if not whiteboard_width_css then
    if html_box_mode == "inline" then
      local needed_in = 11.0 + math.max(0, max_box_depth - 1) * 1.5
      whiteboard_width_css = string.format("%.2fin", needed_in)
    else
      whiteboard_width_css = "min(94vw, 68rem)"
    end
  end

  local header_includes = doc.meta["header-includes"] or pandoc.MetaList({})
  if header_includes.t ~= "MetaList" then
    header_includes = pandoc.MetaList({ header_includes })
  end

  local cdn_css_tag = ""
  local cdn_head_script = ""
  if html_assets == "cdn" then
    cdn_css_tag = string.format('<link id="wbCdnCssLink" rel="stylesheet" href="%s/config/latex.css" onerror="window.__wbCdnCssErr=true;if(window.__wbShowCdnOffline)window.__wbShowCdnOffline(\'Failed to load CDN stylesheet (latex.css)\',false);" />\n', escape_html(html_cdn_base))
    cdn_head_script = [[
<script>
window.__wbIsCdnMode = true;
window.__wbShowCdnOffline = function(reason, isMidSession) {
  try {
    var b = document.getElementById('wbCdnOfflineBanner');
    var t = document.getElementById('wbCdnOfflineTitle');
    var d = document.getElementById('wbCdnOfflineMsg');
    var r = document.getElementById('wbCdnOfflineReason');
    if (!b) { window.__wbPendingCdnBanner = { reason: reason || '', mid: !!isMidSession }; return; }
    b.style.display = 'flex';
    b.style.background = isMidSession ? '#92400e' : '#b91c1c';
    b.style.borderColor = isMidSession ? '#78350f' : '#7f1d1d';
    if (t) t.textContent = isMidSession ? 'Connection Lost (CDN Mode): ' : 'Internet Connection Required (CDN Mode): ';
    if (d) {
      d.textContent = isMidSession
        ? 'You are currently offline. Already-loaded notes, Table of Contents, Pen/Highlighter/Notes, Save HTML, Save As, and Print continue working. Turn on Wi-Fi, Ethernet, or Mobile Data if you need uncached equations or Tree View, then click Reload.'
        : 'Please turn on Wi-Fi, Ethernet, or Mobile Data so this CDN HTML file can load its stylesheet, math renderer, and interactive viewer, then click Reload.';
    }
    if (r) r.textContent = reason ? ('Detail: ' + reason) : '';
  } catch (e) {}
};
window.__wbHideCdnOffline = function() {
  try {
    var b = document.getElementById('wbCdnOfflineBanner');
    if (b) b.style.display = 'none';
  } catch (e) {}
};
</script>
]]
  end

  local head_html = string.format([==[
%s%s<style id="wbBaseVars">
:root {
  --whiteboard-width: %s;
  --document-width: var(--whiteboard-width);
}
html.wb-compat-ok #viewerCompatWarning {
  display: none !important;
}
</style>
<script>
(function() {
  try {
    var root = document.documentElement;
    var hasDetails = ('open' in document.createElement('details'));
    var hasCssVars = !!(window.CSS && window.CSS.supports && window.CSS.supports('--wb-test', '1'));
    var hasDom = !!(document.querySelector && document.querySelectorAll && root.classList && window.NodeList && NodeList.prototype && NodeList.prototype.forEach);
    var hasStyleEl = !!document.getElementById('wbBaseVars');
    if (hasDetails && hasCssVars && hasDom && hasStyleEl) {
      root.classList.add('wb-compat-ok');
    } else {
      window.__wbCompatFailure = [];
      if (!hasDetails) window.__wbCompatFailure.push('HTML5 collapsible <details> boxes not supported');
      if (!hasCssVars) window.__wbCompatFailure.push('CSS custom properties not supported');
      if (!hasStyleEl) window.__wbCompatFailure.push('Document stylesheets were stripped');
      if (!hasDom) window.__wbCompatFailure.push('Required DOM APIs not available');
    }
  } catch (e) {
    window.__wbCompatFailure = ['Compatibility precheck failed'];
  }
})();
</script>
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
</script>]==], cdn_css_tag, cdn_head_script, whiteboard_width_css)

  header_includes[#header_includes + 1] = pandoc.MetaBlocks({ pandoc.RawBlock("html", head_html) })
  doc.meta["header-includes"] = header_includes

  local cdn_banner_html = ""
  if html_assets == "cdn" then
    cdn_banner_html = [[
<div id="wbCdnOfflineBanner" role="status" aria-live="polite" style="display:none; position:sticky; top:54px; z-index:9500; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; background:#b91c1c; color:#ffffff; border:2px solid #7f1d1d; border-radius:8px; padding:12px 16px; margin:12px auto 16px auto; max-width:960px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; font-size:14px; line-height:1.45; box-shadow:0 6px 18px rgba(0,0,0,0.22);">
  <div style="flex:1 1 320px; min-width:220px;">
    <strong id="wbCdnOfflineTitle">Internet Connection Required (CDN Mode): </strong>
    <span id="wbCdnOfflineMsg">Please turn on Wi-Fi, Ethernet, or Mobile Data so this CDN HTML file can load its stylesheet, math renderer, and interactive viewer, then click Reload.</span>
    <div id="wbCdnOfflineReason" style="margin-top:4px; font-size:12px; opacity:0.9;"></div>
  </div>
  <div style="display:flex; align-items:center; gap:8px; flex:0 0 auto;">
    <button id="btnCdnReload" type="button" onclick="window.location.reload();" style="background:#ffffff; color:#111827; border:none; border-radius:6px; padding:7px 14px; font-weight:700; font-size:13px; cursor:pointer;">&#x21bb; Reload Page</button>
    <button id="btnCdnDismiss" type="button" onclick="if(window.__wbHideCdnOffline)window.__wbHideCdnOffline();" style="background:rgba(255,255,255,0.16); color:#ffffff; border:1px solid rgba(255,255,255,0.38); border-radius:6px; padding:6px 10px; font-size:12px; cursor:pointer;">Dismiss</button>
  </div>
</div>
]]
  end

  local compat_banner_html = cdn_banner_html .. [[
<div id="viewerCompatWarning" class="viewer-compat-warning" role="alert" style="display:block; background:#b91c1c; color:#ffffff; border:3px solid #7f1d1d; border-radius:6px; padding:14px 18px; margin:12px auto 20px auto; max-width:960px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; font-size:15px; line-height:1.45; box-shadow:0 4px 12px rgba(0,0,0,0.2);">
  <strong>Incompatible HTML Viewer Detected:</strong> This interactive whiteboard HTML requires a modern web browser (such as Chrome, Edge, Firefox, or Safari) with JavaScript, HTML5 collapsible boxes, CSS styles, and MathJax enabled. Built-in file previewers or restricted HTML viewers cannot render equations, styles, or collapsible boxes properly—please open this file in a web browser.
  <div id="viewerCompatReason" style="margin-top:6px; font-size:13px; color:#fee2e2;"></div>
</div>]]

  local include_before = doc.meta["include-before"] or pandoc.MetaList({})
  if include_before.t ~= "MetaList" then
    include_before = pandoc.MetaList({ include_before })
  end
  include_before[#include_before + 1] = pandoc.MetaBlocks({ pandoc.RawBlock("html", compat_banner_html) })
  doc.meta["include-before"] = include_before

  local graph_bundle = load_graph_bundle()
  local toc_btn_html = ""
  local graph_btn_html = ""
  local graph_workspace_html = ""
  if graph_bundle then
    toc_btn_html = '<button id="btnToggleToc" type="button" class="wb-toc-btn wb-has-tip wb-tip-left" data-wb-tip="Table of Contents" title="Table of Contents" aria-label="Toggle Table of Contents">TOC</button>\n    <span class="wb-annot-sep"></span>\n    '
    graph_btn_html = '<button id="btnToggleGraph" type="button" class="wb-graph-btn" title="Open interactive Markmap Tree View" aria-label="Toggle Tree View">Tree View</button>\n    <span class="wb-annot-sep"></span>\n    '
    local vendor_tag = ""
    if html_assets ~= "cdn" and graph_bundle.vendor_json then
      vendor_tag = '<script type="application/json" id="wbVendorGz">' .. graph_bundle.vendor_json .. '</script>\n'
    end
    local data_attrs = string.format('id="wbGraphData" data-wb-assets="%s" data-wb-cdn-base="%s"', escape_html(html_assets), escape_html(html_cdn_base))
    graph_workspace_html = [===[
<aside id="wbTocDrawer" class="wb-toc-drawer" aria-label="Table of Contents">
  <div class="wb-toc-header">
    <span class="wb-toc-title">Table of Contents</span>
    <div class="wb-toc-actions">
      <button id="btnTocExpandAll" type="button" title="Expand all sections">⊞</button>
      <button id="btnTocCollapseAll" type="button" title="Collapse subsections">⊟</button>
      <button id="btnTocClose" type="button" title="Close Table of Contents (Esc)">✕</button>
    </div>
  </div>
  <div class="wb-toc-filter-wrap">
    <input id="wbTocFilter" type="search" placeholder="Filter sections..." aria-label="Filter Table of Contents" />
    <button id="btnTocFilterClear" type="button" title="Clear filter">×</button>
  </div>
  <div id="wbTocList" class="wb-toc-list" role="tree"></div>
</aside>
<section id="wbGraphWorkspace" class="wb-graph-workspace" aria-label="Interactive Markmap Tree View">
  <div id="wbGraphSplitter" class="wb-graph-splitter" role="separator" aria-orientation="vertical" title="Drag to resize Split View (double-click to reset 60/40)"></div>
  <div class="wb-graph-header">
    <div class="wb-graph-group">
      <button id="btnGraphModeFull" type="button" class="is-active" title="Full-screen Tree View">Full</button>
      <button id="btnGraphModeSplit" type="button" title="Side-by-side Split View (Tree + Notes)">Split</button>
      <span class="wb-graph-sep"></span>
      <button type="button" class="wb-graph-depth is-active" data-depth="1" title="Expand level 1 branches">L1</button>
      <button type="button" class="wb-graph-depth" data-depth="2" title="Expand level 2 branches">L2</button>
      <button type="button" class="wb-graph-depth" data-depth="3" title="Expand level 3 branches">L3</button>
      <button type="button" class="wb-graph-depth" data-depth="0" title="Expand all branches">All</button>
      <span class="wb-graph-sep"></span>
      <span class="wb-graph-search-wrap">
        <input id="wbGraphSearch" type="search" placeholder="Search nodes..." aria-label="Search Tree View nodes" />
        <button id="btnGraphSearchClear" type="button" title="Clear search">×</button>
        <button id="btnGraphMatchPrev" type="button" title="Previous match" disabled>◀</button>
        <button id="btnGraphMatchNext" type="button" title="Next match" disabled>▶</button>
        <span id="wbGraphMatchCount" class="wb-graph-count">0 / 0</span>
      </span>
    </div>
    <div class="wb-graph-group">
      <button id="btnGraphZoomOut" type="button" title="Zoom out">−</button>
      <button id="btnGraphFit" type="button" title="Fit mindmap to screen">Fit</button>
      <button id="btnGraphZoomIn" type="button" title="Zoom in">+</button>
      <span class="wb-graph-sep"></span>
      <button id="btnGraphExportSvg" type="button" title="Download interactive mindmap as .svg">Export .svg</button>
      <button id="btnGraphNewTab" type="button" title="Open interactive Markmap in a new browser tab">New Tab ↗</button>
      <button id="btnGraphClose" type="button" title="Close Tree View (Esc)">Close ✕</button>
    </div>
  </div>
  <div class="wb-graph-stage" id="wbGraphStage">
    <svg id="wbGraphSvg"></svg>
  </div>
  <div class="wb-graph-footer">
    <div class="wb-graph-sel-info">
      <span id="wbGraphSelLabel" class="wb-graph-sel-label">Click any node or its ↗ button to jump to notes</span>
      <button id="btnGraphJumpSelected" type="button" class="wb-graph-jump-main" disabled title="Jump to selected node in notes">Jump to Note ↗</button>
    </div>
    <span class="wb-graph-hint-text">○ Fold/unfold • Node click selects • Dedicated ↗ button jumps (opens collapsed boxes)</span>
  </div>
</section>
<script type="application/json" ]===] .. data_attrs .. '>' .. graph_bundle.payload_json .. '</script>\n' .. vendor_tag
  end

  local viewer_script_html = ""
  if html_assets == "cdn" then
    viewer_script_html = string.format([[<script id="wbCdnViewerJs" src="%s/config/wb-viewer.js" onerror="window.__wbCdnViewerErr=true;if(window.__wbShowCdnOffline)window.__wbShowCdnOffline('Failed to load interactive viewer script (wb-viewer.js)',false);"></script>
<script>
(function() {
  if (!window.__wbIsCdnMode) return;
  if (window.__wbPendingCdnBanner) {
    window.__wbShowCdnOffline(window.__wbPendingCdnBanner.reason, window.__wbPendingCdnBanner.mid);
  }
  function checkInitialCdn() {
    var errs = [];
    if (typeof navigator !== 'undefined' && navigator.onLine === false) errs.push('Browser is offline');
    if (window.__wbCdnCssErr) errs.push('CDN stylesheet (latex.css) failed to download');
    if (window.__wbCdnViewerErr || !window.__wbViewerLoaded) errs.push('CDN viewer script (wb-viewer.js) failed to download');
    if (errs.length && window.__wbShowCdnOffline) {
      window.__wbShowCdnOffline(errs.join('; '), false);
    }
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', checkInitialCdn);
  } else {
    checkInitialCdn();
  }
  window.addEventListener('offline', function() {
    var missingCore = !!(window.__wbCdnCssErr || window.__wbCdnViewerErr || !window.__wbViewerLoaded);
    if (window.__wbShowCdnOffline) {
      window.__wbShowCdnOffline('Network connection turned off', !missingCore);
    }
  });
  window.addEventListener('online', function() {
    var missingCore = !!(window.__wbCdnCssErr || window.__wbCdnViewerErr || !window.__wbViewerLoaded);
    if (!missingCore && window.__wbHideCdnOffline) {
      window.__wbHideCdnOffline();
    } else if (window.__wbShowCdnOffline) {
      window.__wbShowCdnOffline('Internet restored — click Reload Page to load CDN styles and viewer scripts', false);
    }
  });
})();
</script>]], escape_html(html_cdn_base))
  else
    local viewer_js = load_viewer_js() or ""
    viewer_script_html = "<script>\n" .. viewer_js .. "\n</script>"
  end

  local annot_data_html = string.format('<script type="application/json" id="wbAnnotationsData" data-wb-doc-id="%s" data-wb-box-mode="%s">{"v":1,"updatedAt":0,"containers":{}}</script>', doc_id, escape_html(html_box_mode))
  local toolbar_html = annot_data_html .. [===[
<div class="floating-toolbar" id="floatingToolbar" role="toolbar" aria-label="Document Controls">
  <div class="wb-toolbar-group">
    ]===] .. toc_btn_html .. [===[<button id="btnToolCursor" type="button" class="is-active" title="Select / Read mode (Esc)">Cursor</button>
    <button id="btnToolPen" type="button" title="Freehand Pen">Pen</button>
    <button id="btnToolHighlight" type="button" title="Cursor Line-by-Line Highlight">Highlight</button>
    <button id="btnToolNote" type="button" title="Drop Sticky Note">Note</button>
    <button id="btnToolEraser" type="button" title="Click or drag over ink, highlights, or notes to erase">Eraser</button>
    <span class="wb-annot-sep"></span>
    <button type="button" class="wb-annot-swatch is-selected" data-wb-color="#dc2626" style="background:#dc2626;" title="Red" aria-label="Red"></button>
    <button type="button" class="wb-annot-swatch" data-wb-color="#2563eb" style="background:#2563eb;" title="Blue" aria-label="Blue"></button>
    <button type="button" class="wb-annot-swatch" data-wb-color="#16a34a" style="background:#16a34a;" title="Green" aria-label="Green"></button>
    <button type="button" class="wb-annot-swatch" data-wb-color="#facc15" style="background:#facc15;" title="Yellow" aria-label="Yellow"></button>
    <button type="button" class="wb-annot-swatch" data-wb-color="#111827" style="background:#111827;" title="Black" aria-label="Black"></button>
    <input id="wbAnnotSize" class="wb-annot-size" type="range" min="1.5" max="8" step="0.5" value="2.5" title="Stroke size" aria-label="Stroke size" />
    <span class="wb-annot-sep"></span>
    <button id="btnAnnotUndo" type="button" title="Undo (Ctrl+Z)">Undo</button>
    <button id="btnAnnotClear" type="button" title="Clear all annotations">Clear</button>
  </div>
  <div class="wb-toolbar-group">
    <span id="wbAnnotStatus" class="wb-annot-status"></span>
    <button id="btnPrintDoc" type="button" title="Print / Save as PDF (Ctrl+P)" aria-label="Print document">Print</button>
    <button id="btnAnnotSave" type="button" class="wb-annot-save-btn wb-has-tip" data-wb-tip="For local storage &amp; updating this file, use Save HTML" title="For local storage &amp; updating this file, use Save HTML">Save HTML</button>
    <button id="btnAnnotSaveAs" type="button" class="wb-has-tip" data-wb-tip="For sharing a standalone HTML file, use Save As" title="For sharing a standalone HTML file, use Save As">Save As</button>
    <span class="wb-annot-sep"></span>
    ]===] .. graph_btn_html .. [===[<button id="btnToggleTheme" type="button" title="Switch theme" aria-label="Toggle dark/light theme">
      <span id="toggleThemeIcon">🌓</span> Theme
    </button>
    <button id="btnScrollTop" type="button" title="Scroll to top" aria-label="Scroll to top">
      ↑ Top
    </button>
    <span class="wb-annot-sep"></span>
    <button id="btnToggleBoxes" type="button" title="Expand or collapse all boxes" aria-label="Toggle all boxes">
      <span id="toggleBoxesIcon">⊞</span> <span id="toggleBoxesLabel">Expand All</span>
    </button>
  </div>
</div>
<div class="wb-save-modal" id="wbSaveAsModal" role="dialog" aria-modal="true" aria-labelledby="wbSaveAsTitle">
  <div class="wb-save-modal-card">
    <h3 id="wbSaveAsTitle">Save Annotated HTML As</h3>
    <label for="wbSaveAsName">File name</label>
    <input id="wbSaveAsName" type="text" value="annotated.html" />
    <p id="wbSaveAsHint" class="wb-save-modal-hint">Choose a file name to save a self-contained copy with all ink strokes, highlights, and notes embedded.</p>
    <div class="wb-save-modal-actions">
      <button id="btnSaveAsCancel" type="button">Cancel</button>
      <button id="btnSaveAsPicker" type="button">Choose Folder...</button>
      <button id="btnSaveAsConfirm" type="button" class="primary">Save Copy</button>
    </div>
  </div>
</div>
<div class="wb-unsaved-popup" id="wbUnsavedPopup" role="dialog" aria-live="polite" aria-label="Unsaved HTML Annotations">
  <div class="wb-unsaved-popup-head">
    <strong>Unsaved Annotations</strong>
    <button id="btnPopupDismiss" type="button" class="wb-unsaved-close" title="Dismiss" aria-label="Dismiss">×</button>
  </div>
  <p class="wb-unsaved-popup-msg">Your browser draft is auto-saved, but the standalone HTML file has not been saved yet.</p>
  <div class="wb-unsaved-popup-actions">
    <button id="btnPopupSave" type="button" class="primary">Save HTML</button>
    <button id="btnPopupSaveAs" type="button">Save As</button>
    <button id="btnPopupLater" type="button">Later</button>
  </div>
</div>
<div class="wb-box-modal-backdrop" id="wbBoxModalBackdrop" role="dialog" aria-modal="true" aria-labelledby="wbBoxModalTitle">
  <div class="wb-box-modal" id="wbBoxModal">
    <div class="wb-box-modal-header" id="wbBoxModalHeader">
      <nav class="wb-box-modal-breadcrumbs" id="wbBoxModalBreadcrumbs" aria-label="Box navigation"></nav>
      <span id="wbBoxModalTitle" class="wb-sr-only">Box Details</span>
      <div class="wb-box-modal-actions">
        <button id="btnBoxModalBack" type="button" title="Back to parent box">← Back</button>
        <button id="btnBoxModalClose" type="button" title="Close window (Esc)">✕</button>
      </div>
    </div>
    <div class="wb-box-modal-body" id="wbBoxModalBody"></div>
  </div>
</div>
]===] .. graph_workspace_html .. viewer_script_html

  new_blocks[#new_blocks + 1] = pandoc.RawBlock("html", toolbar_html)

  return pandoc.Pandoc(new_blocks, doc.meta)
end
