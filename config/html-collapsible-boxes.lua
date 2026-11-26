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
local annot_box_counter = 0
local annot_sec_counter = 0
local html_embed_counter = 0

local B64_REV = {}
do
  local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #alpha do
    B64_REV[alpha:byte(i)] = i - 1
  end
end

local function b64decode(data)
  if not data or data == "" then return "" end
  local out = {}
  local vals = {}
  for i = 1, #data do
    local b = data:byte(i)
    if b == 61 then -- '='
      vals[#vals + 1] = -1
    elseif B64_REV[b] then
      vals[#vals + 1] = B64_REV[b]
    end
    if #vals == 4 then
      local v1, v2, v3, v4 = vals[1], vals[2], vals[3], vals[4]
      vals = {}
      if v1 >= 0 and v2 >= 0 then
        local c1 = v1 * 4 + math.floor(v2 / 16)
        out[#out + 1] = string.char(c1)
        if v3 >= 0 then
          local c2 = ((v2 % 16) * 16) + math.floor(v3 / 4)
          out[#out + 1] = string.char(c2)
          if v4 >= 0 then
            local c3 = ((v3 % 4) * 64) + v4
            out[#out + 1] = string.char(c3)
          end
        end
      end
    end
  end
  return table.concat(out)
end

local function escape_html(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function is_box_div(el)
  return el.tag == "Div" and (el.classes:includes("marginbox") or el.classes:includes("tcolorbox") or el.classes:includes("vbox"))
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
  annot_box_counter = annot_box_counter + 1
  local box_annot_id = "box-" .. tostring(annot_box_counter)

  local processed_body = process_block_sequence(body_blocks, depth + 1)

  local safe_title = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")

  local open_html = string.format([[
<details class="marginbox" style="--box-col: %s;">
  <summary class="marginbox-header">%s</summary>
  <div class="marginbox-body" data-wb-annot-id="%s">]], color_hex, safe_title, box_annot_id)

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

function process_block_sequence(blocks, depth)
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
  local new_blocks = process_block_sequence(doc.blocks, 0)
  local doc_id = compute_doc_id(doc)

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
<style id="wbBaseVars">
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
</script>]==], whiteboard_width_css)

  header_includes[#header_includes + 1] = pandoc.MetaBlocks({ pandoc.RawBlock("html", head_html) })
  doc.meta["header-includes"] = header_includes

  local compat_banner_html = [[
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

  -- Floating reading, compatibility & Option A annotation toolbar
  local annot_data_html = string.format('<script type="application/json" id="wbAnnotationsData" data-wb-doc-id="%s">{"v":1,"updatedAt":0,"containers":{}}</script>', doc_id)
  local toolbar_html = annot_data_html .. [===[
<div class="floating-toolbar" id="floatingToolbar" role="toolbar" aria-label="Document Controls">
  <div class="wb-toolbar-group">
    <button id="btnToggleBoxes" type="button" title="Expand or collapse all boxes" aria-label="Toggle all boxes">
      <span id="toggleBoxesIcon">⊞</span> <span id="toggleBoxesLabel">Expand All</span>
    </button>
    <span class="wb-annot-sep"></span>
    <button id="btnToolCursor" type="button" class="is-active" title="Select / Read mode (Esc)">Cursor</button>
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
    <button id="btnToggleTheme" type="button" title="Switch theme" aria-label="Toggle dark/light theme">
      <span id="toggleThemeIcon">🌓</span> Theme
    </button>
    <button id="btnScrollTop" type="button" title="Scroll to top" aria-label="Scroll to top">
      ↑ Top
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
<script>
(function() {
  // Capture pristine HTML before MathJax or overlays mutate the DOM
  var pristineHtmlSnapshot = '';
  try {
    pristineHtmlSnapshot = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
  } catch (e) {}

  // 0. Viewer Compatibility Verification (ES5-safe)
  function showCompatWarning(reasons) {
    try {
      if (document.documentElement && document.documentElement.classList) {
        document.documentElement.classList.remove('wb-compat-ok');
      }
      var banner = document.getElementById('viewerCompatWarning');
      if (banner) {
        banner.style.display = 'block';
      }
      var reasonEl = document.getElementById('viewerCompatReason');
      if (reasonEl && reasons && reasons.length) {
        reasonEl.textContent = 'Detected issue: ' + reasons.join('; ') + '.';
      }
    } catch (e) {}
  }

  if (window.__wbCompatFailure && window.__wbCompatFailure.length) {
    showCompatWarning(window.__wbCompatFailure);
  }

  function checkMathStartup(mjx) {
    if (!mjx || !mjx.startup || !mjx.startup.promise) {
      return false;
    }
    mjx.startup.promise.then(function() {
      if (document.querySelector('.math') && !document.querySelector('mjx-container')) {
        showCompatWarning(['MathJax loaded but failed to render equations']);
      }
    }, function() {
      showCompatWarning(['MathJax failed to initialize equations in this viewer']);
    });
    return true;
  }

  function verifyStylesAndMath() {
    var issues = [];
    try {
      if (window.getComputedStyle) {
        var wb = (window.getComputedStyle(document.documentElement).getPropertyValue('--whiteboard-width') || '').replace(/^\s+|\s+$/g, '');
        if (!wb) {
          issues.push('Document CSS variables and layout stylesheets were blocked or stripped');
        }
      }
    } catch (e) {
      issues.push('Unable to verify document CSS support');
    }

    if (document.querySelector('.math') && !checkMathStartup(window.MathJax)) {
      setTimeout(function() {
        if (!checkMathStartup(window.MathJax) && document.querySelector('.math') && !document.querySelector('mjx-container')) {
          showCompatWarning(['MathJax equation engine could not load (scripts or network may be blocked)']);
        }
      }, 1500);
    }

    if (issues.length) {
      showCompatWarning(issues);
    }
  }

  if (document.readyState === 'complete') {
    verifyStylesAndMath();
  } else if (window.addEventListener) {
    window.addEventListener('load', verifyStylesAndMath);
  }

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
      syncAllLayerSizes();
    });
  }

  // 2. Theme Toggle (Auto -> Dark -> Light -> Auto)
  var btnTheme = document.getElementById('btnToggleTheme');
  var currentTheme = 'auto';
  try {
    currentTheme = localStorage.getItem('latex-theme') || 'auto';
  } catch (e) {}

  function applyTheme(theme) {
    document.body.classList.remove('latex-dark', 'latex-light');
    if (theme === 'dark') document.body.classList.add('latex-dark');
    if (theme === 'light') document.body.classList.add('latex-light');
    try {
      localStorage.setItem('latex-theme', theme);
    } catch (e) {}
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

  // 4. Option A Per-Container Annotations & Save HTML Engine
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var dataEl = document.getElementById('wbAnnotationsData');
  var docId = dataEl ? (dataEl.getAttribute('data-wb-doc-id') || 'wb-default') : 'wb-default';
  var draftKey = 'wb-annot-draft:' + docId;
  var annotState = { v: 1, updatedAt: 0, containers: {} };
  var undoStack = [];
  var activeTool = 'cursor';
  var activeColor = '#dc2626';
  var activeSize = 2.5;
  var annotBarOpen = false;
  var isDirty = false;
  var statusEl = document.getElementById('wbAnnotStatus');
  var unsavedPopupEl = document.getElementById('wbUnsavedPopup');

  function setStatus(msg) {
    if (statusEl) statusEl.textContent = msg || '';
  }

  function showUnsavedPopup() {
    if (!isDirty || !unsavedPopupEl) return;
    unsavedPopupEl.classList.add('is-open');
  }

  function hideUnsavedPopup() {
    if (unsavedPopupEl) unsavedPopupEl.classList.remove('is-open');
  }

  function setDirtyState(dirty) {
    isDirty = !!dirty;
    var saveBtnEl = document.getElementById('btnAnnotSave');
    if (saveBtnEl) {
      if (saveBtnEl.classList) saveBtnEl.classList.toggle('is-dirty', isDirty);
      saveBtnEl.textContent = isDirty ? 'Save HTML •' : 'Save HTML';
    }
    if (!isDirty) {
      hideUnsavedPopup();
    }
  }

  function cloneState(st) {
    return JSON.parse(JSON.stringify(st));
  }

  function pushUndo() {
    undoStack.push(JSON.stringify(annotState));
    if (undoStack.length > 60) undoStack.shift();
  }

  function saveDraft() {
    annotState.updatedAt = Date.now();
    setDirtyState(true);
    try {
      localStorage.setItem(draftKey, JSON.stringify(annotState));
      setStatus('Unsaved draft');
    } catch (e) {
      setStatus('Edited');
    }
  }

  function loadInitialAnnotations() {
    var embedded = { v: 1, updatedAt: 0, containers: {} };
    if (dataEl && dataEl.textContent) {
      try {
        var parsed = JSON.parse(dataEl.textContent);
        if (parsed && parsed.containers) embedded = parsed;
      } catch (e) {}
    }
    annotState = cloneState(embedded);
    try {
      var rawDraft = localStorage.getItem(draftKey);
      if (rawDraft) {
        var draft = JSON.parse(rawDraft);
        if (draft && draft.containers && (draft.updatedAt || 0) > (embedded.updatedAt || 0)) {
          annotState = draft;
          setDirtyState(true);
          setStatus('Draft restored');
        }
      }
    } catch (e) {}
  }

  function getContainerData(cid) {
    if (!annotState.containers[cid]) {
      annotState.containers[cid] = { strokes: [], rects: [], notes: [] };
    }
    if (!annotState.containers[cid].strokes) annotState.containers[cid].strokes = [];
    if (!annotState.containers[cid].rects) annotState.containers[cid].rects = [];
    if (!annotState.containers[cid].notes) annotState.containers[cid].notes = [];
    return annotState.containers[cid];
  }

  function pointsToPath(pts) {
    if (!pts || !pts.length) return '';
    if (pts.length === 1) {
      return 'M ' + pts[0][0] + ' ' + pts[0][1] + ' L ' + (pts[0][0] + 0.1) + ' ' + pts[0][1];
    }
    var parts = ['M ' + pts[0][0] + ' ' + pts[0][1]];
    for (var i = 1; i < pts.length; i++) {
      parts.push('L ' + pts[i][0] + ' ' + pts[i][1]);
    }
    return parts.join(' ');
  }

  function ensureSvgLayer(container) {
    var svg = null;
    for (var i = 0; i < container.children.length; i++) {
      var ch = container.children[i];
      if (ch.classList && ch.classList.contains('wb-annot-layer')) {
        svg = ch;
        break;
      }
    }
    if (!svg) {
      svg = document.createElementNS(SVG_NS, 'svg');
      svg.setAttribute('class', 'wb-annot-layer');
      svg.setAttribute('aria-hidden', 'true');
      container.appendChild(svg);
    }
    syncLayerSize(container, svg);
    return svg;
  }

  function syncLayerSize(container, svg) {
    if (!container || !svg) return;
    var w = Math.max(container.scrollWidth || 0, container.clientWidth || 0);
    var h = Math.max(container.scrollHeight || 0, container.clientHeight || 0);
    if (w > 0) svg.style.width = w + 'px';
    if (h > 0) svg.style.height = h + 'px';
  }

  function syncAllLayerSizes() {
    var containers = document.querySelectorAll('[data-wb-annot-id]');
    containers.forEach(function(c) {
      for (var i = 0; i < c.children.length; i++) {
        if (c.children[i].classList && c.children[i].classList.contains('wb-annot-layer')) {
          syncLayerSize(c, c.children[i]);
          break;
        }
      }
    });
  }

  function createStrokeEl(cid, stroke) {
    var p = document.createElementNS(SVG_NS, 'path');
    p.setAttribute('class', 'wb-annot-stroke');
    p.setAttribute('data-stroke-id', stroke.id);
    p.setAttribute('d', pointsToPath(stroke.pts));
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', stroke.color);
    p.setAttribute('stroke-width', String(stroke.width));
    p.setAttribute('stroke-linecap', 'round');
    p.setAttribute('stroke-linejoin', 'round');
    p.setAttribute('stroke-opacity', String(stroke.opacity));
    p.addEventListener('pointerdown', function(e) {
      if (activeTool !== 'eraser') return;
      e.stopPropagation();
      eraseAnnotation(cid, stroke.id);
    });
    return p;
  }

  function createRectEl(cid, r) {
    var rect = document.createElementNS(SVG_NS, 'rect');
    rect.setAttribute('class', 'wb-annot-stroke wb-annot-rect');
    rect.setAttribute('data-stroke-id', r.id);
    rect.setAttribute('x', String(r.x));
    rect.setAttribute('y', String(r.y));
    rect.setAttribute('width', String(r.w));
    rect.setAttribute('height', String(r.h));
    rect.setAttribute('rx', '3');
    rect.setAttribute('fill', r.color);
    rect.setAttribute('fill-opacity', String(r.opacity || 0.35));
    rect.addEventListener('pointerdown', function(e) {
      if (activeTool !== 'eraser') return;
      e.stopPropagation();
      eraseAnnotation(cid, r.id);
    });
    return rect;
  }

  function eraseAnnotation(cid, itemId) {
    var cdata = getContainerData(cid);
    var lists = [cdata.strokes, cdata.rects];
    for (var l = 0; l < lists.length; l++) {
      var arr = lists[l];
      for (var i = 0; i < arr.length; i++) {
        if (arr[i].id === itemId) {
          pushUndo();
          arr.splice(i, 1);
          saveDraft();
          renderContainer(cid);
          return true;
        }
      }
    }
    return false;
  }

  function createNoteEl(container, cid, note) {
    var box = document.createElement('div');
    box.className = 'wb-sticky-note';
    box.setAttribute('data-note-id', note.id);
    box.style.left = note.x + 'px';
    box.style.top = note.y + 'px';

    var bar = document.createElement('div');
    bar.className = 'wb-sticky-note-bar';
    bar.innerHTML = '<span>Note</span>';
    var delBtn = document.createElement('button');
    delBtn.type = 'button';
    delBtn.className = 'wb-sticky-note-del';
    delBtn.textContent = '×';
    delBtn.title = 'Delete note';
    delBtn.addEventListener('click', function(e) {
      e.stopPropagation();
      pushUndo();
      var cdata = getContainerData(cid);
      cdata.notes = cdata.notes.filter(function(n) { return n.id !== note.id; });
      saveDraft();
      renderContainer(cid);
    });
    bar.appendChild(delBtn);

    var ta = document.createElement('textarea');
    ta.placeholder = 'Write note...';
    ta.value = note.text || '';
    var undoCaptured = false;
    ta.addEventListener('input', function() {
      if (!undoCaptured) {
        pushUndo();
        undoCaptured = true;
      }
      note.text = ta.value;
      saveDraft();
    });

    // Dragging note inside its anchored container
    bar.addEventListener('pointerdown', function(e) {
      if (e.target === delBtn) return;
      if (activeTool === 'eraser') {
        delBtn.click();
        return;
      }
      e.preventDefault();
      e.stopPropagation();
      pushUndo();
      var startX = e.clientX;
      var startY = e.clientY;
      var origX = note.x;
      var origY = note.y;
      function onMove(ev) {
        note.x = Math.max(0, Math.round(origX + (ev.clientX - startX)));
        note.y = Math.max(0, Math.round(origY + (ev.clientY - startY)));
        box.style.left = note.x + 'px';
        box.style.top = note.y + 'px';
      }
      function onUp() {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        saveDraft();
      }
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    });

    box.appendChild(bar);
    box.appendChild(ta);
    box.addEventListener('pointerdown', function(e) {
      if (activeTool !== 'eraser') return;
      e.preventDefault();
      e.stopPropagation();
      delBtn.click();
    }, true);
    container.appendChild(box);
    return ta;
  }

  function renderContainer(cid) {
    var container = document.querySelector('[data-wb-annot-id="' + cid + '"]');
    if (!container) return;
    for (var i = container.children.length - 1; i >= 0; i--) {
      var ch = container.children[i];
      if (ch.classList && (ch.classList.contains('wb-annot-layer') || ch.classList.contains('wb-sticky-note'))) {
        container.removeChild(ch);
      }
    }
    var cdata = getContainerData(cid);
    if (cdata.rects.length > 0 || cdata.strokes.length > 0) {
      var svg = ensureSvgLayer(container);
      cdata.rects.forEach(function(r) {
        svg.appendChild(createRectEl(cid, r));
      });
      cdata.strokes.forEach(function(st) {
        svg.appendChild(createStrokeEl(cid, st));
      });
    }
    cdata.notes.forEach(function(n) {
      createNoteEl(container, cid, n);
    });
  }

  function renderAllAnnotations() {
    var containers = document.querySelectorAll('[data-wb-annot-id]');
    containers.forEach(function(c) {
      renderContainer(c.getAttribute('data-wb-annot-id'));
    });
  }

  function setTool(tool) {
    activeTool = tool;
    document.body.classList.remove('wb-annot-draw', 'wb-annot-highlight', 'wb-annot-note', 'wb-annot-erase');
    if (tool === 'pen') {
      document.body.classList.add('wb-annot-draw');
    } else if (tool === 'highlight') {
      document.body.classList.add('wb-annot-highlight');
    } else if (tool === 'note') {
      document.body.classList.add('wb-annot-note');
    } else if (tool === 'eraser') {
      document.body.classList.add('wb-annot-erase');
    }
    var ids = { cursor: 'btnToolCursor', pen: 'btnToolPen', highlight: 'btnToolHighlight', note: 'btnToolNote', eraser: 'btnToolEraser' };
    Object.keys(ids).forEach(function(k) {
      var b = document.getElementById(ids[k]);
      if (b) b.classList.toggle('is-active', k === tool);
    });
  }

  // Drawing / Cursor line-by-line highlighting / Note / Drag-erase delegation
  var drawingCtx = null;

  function containerPoint(container, clientX, clientY) {
    var rect = container.getBoundingClientRect();
    var x = Math.round((clientX - rect.left + (container.scrollLeft || 0)) * 10) / 10;
    var y = Math.round((clientY - rect.top + (container.scrollTop || 0)) * 10) / 10;
    return [x, y];
  }

  function collectRangeRectsByContainer(range) {
    var perContainer = {};
    function pushRect(container, r) {
      if (!container || !r || r.width < 2 || r.height < 2) return;
      var cid = container.getAttribute('data-wb-annot-id');
      if (!cid) return;
      var crect = container.getBoundingClientRect();
      var x = Math.round((r.left - crect.left + (container.scrollLeft || 0)) * 10) / 10;
      var y = Math.round((r.top - crect.top + (container.scrollTop || 0)) * 10) / 10;
      var w = Math.round(r.width * 10) / 10;
      var h = Math.round(r.height * 10) / 10;
      if (!perContainer[cid]) perContainer[cid] = [];
      perContainer[cid].push({ x: x, y: y, w: w, h: h });
    }

    var root = range.commonAncestorContainer;
    if (root && root.nodeType === 3 && root.parentNode) root = root.parentNode;
    if (!root) return perContainer;

    if (document.createTreeWalker && window.NodeFilter) {
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null, false);
      var node = walker.currentNode;
      while (node) {
        var parentEl = (node.nodeType === 3) ? node.parentNode : node;
        if (parentEl && parentEl.closest && !parentEl.closest('.floating-toolbar, .wb-annot-toolbar, .wb-sticky-note, .wb-save-modal, summary.marginbox-header')) {
          var container = parentEl.closest('[data-wb-annot-id]');
          if (container) {
            if (node.nodeType === 3 && /\S/.test(node.nodeValue || '') && (!range.intersectsNode || range.intersectsNode(node))) {
              try {
                var sub = document.createRange();
                var startOff = (node === range.startContainer) ? range.startOffset : 0;
                var endOff = (node === range.endContainer) ? range.endOffset : (node.nodeValue || '').length;
                if (endOff > startOff) {
                  sub.setStart(node, startOff);
                  sub.setEnd(node, endOff);
                  var rects = sub.getClientRects ? sub.getClientRects() : [];
                  for (var ri = 0; ri < rects.length; ri++) pushRect(container, rects[ri]);
                }
              } catch (err) {}
            } else if (node.nodeType === 1 && node.tagName === 'MJX-CONTAINER' && (!range.intersectsNode || range.intersectsNode(node))) {
              pushRect(container, node.getBoundingClientRect());
            }
          }
        }
        node = walker.nextNode();
      }
    } else if (range.getClientRects && root.closest) {
      var cFallback = root.closest('[data-wb-annot-id]');
      var list = range.getClientRects();
      for (var k = 0; k < list.length; k++) pushRect(cFallback, list[k]);
    }

    // Merge horizontal fragments on the same visual line cleanly
    Object.keys(perContainer).forEach(function(cid) {
      var items = perContainer[cid];
      items.sort(function(a, b) {
        if (Math.abs(a.y - b.y) > 4) return a.y - b.y;
        return a.x - b.x;
      });
      var merged = [];
      for (var i = 0; i < items.length; i++) {
        var cur = items[i];
        var prev = merged.length ? merged[merged.length - 1] : null;
        if (prev && Math.abs(cur.y - prev.y) <= Math.max(6, Math.min(cur.h, prev.h) * 0.5) && cur.x <= prev.x + prev.w + 24) {
          var minX = Math.min(prev.x, cur.x);
          var maxX = Math.max(prev.x + prev.w, cur.x + cur.w);
          var minY = Math.min(prev.y, cur.y);
          var maxY = Math.max(prev.y + prev.h, cur.y + cur.h);
          prev.x = minX;
          prev.y = minY;
          prev.w = Math.round((maxX - minX) * 10) / 10;
          prev.h = Math.round((maxY - minY) * 10) / 10;
        } else {
          merged.push(cur);
        }
      }
      perContainer[cid] = merged;
    });
    return perContainer;
  }

  function applyCursorHighlightFromSelection() {
    if (activeTool !== 'highlight' || !window.getSelection) return false;
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return false;
    var addedAny = false;
    var allByContainer = {};
    for (var rIdx = 0; rIdx < sel.rangeCount; rIdx++) {
      var partMap = collectRangeRectsByContainer(sel.getRangeAt(rIdx));
      Object.keys(partMap).forEach(function(cid) {
        if (!allByContainer[cid]) allByContainer[cid] = [];
        partMap[cid].forEach(function(box) { allByContainer[cid].push(box); });
      });
    }
    var cids = Object.keys(allByContainer);
    if (!cids.length) return false;
    pushUndo();
    var ts = Date.now();
    var seq = 0;
    cids.forEach(function(cid) {
      var list = allByContainer[cid];
      if (!list.length) return;
      var cdata = getContainerData(cid);
      list.forEach(function(b) {
        seq += 1;
        cdata.rects.push({
          id: 'h-' + ts + '-' + seq + '-' + Math.floor(Math.random() * 100),
          color: activeColor,
          opacity: 0.35,
          x: b.x,
          y: b.y,
          w: b.w,
          h: b.h
        });
        addedAny = true;
      });
      renderContainer(cid);
    });
    if (addedAny) {
      saveDraft();
      try { sel.removeAllRanges(); } catch (e) {}
    }
    return addedAny;
  }

  document.addEventListener('pointerdown', function(e) {
    if (activeTool === 'cursor' || activeTool === 'highlight') return;
    var tgt = (e.target && e.target.nodeType === 3) ? e.target.parentNode : e.target;
    if (tgt && tgt.closest && (tgt.closest('.floating-toolbar') || tgt.closest('.wb-annot-toolbar') || tgt.closest('.wb-save-modal') || tgt.closest('summary.marginbox-header') || tgt.closest('.wb-sticky-note'))) {
      return;
    }
    var container = tgt && tgt.closest ? tgt.closest('[data-wb-annot-id]') : null;
    if (!container) return;
    var cid = container.getAttribute('data-wb-annot-id');
    var pt = containerPoint(container, e.clientX, e.clientY);

    if (activeTool === 'note') {
      e.preventDefault();
      pushUndo();
      var nid = 'n-' + Date.now() + '-' + Math.floor(Math.random() * 1000);
      var note = { id: nid, x: pt[0], y: pt[1], text: '' };
      getContainerData(cid).notes.push(note);
      saveDraft();
      renderContainer(cid);
      var newTa = container.querySelector('.wb-sticky-note[data-note-id="' + nid + '"] textarea');
      if (newTa) newTa.focus();
      setTool('cursor');
      return;
    }

    if (activeTool === 'pen') {
      e.preventDefault();
      pushUndo();
      var stroke = {
        id: 's-' + Date.now() + '-' + Math.floor(Math.random() * 1000),
        tool: 'pen',
        color: activeColor,
        width: activeSize,
        opacity: 1,
        pts: [pt]
      };
      var svg = ensureSvgLayer(container);
      var pathEl = createStrokeEl(cid, stroke);
      svg.appendChild(pathEl);
      drawingCtx = { cid: cid, container: container, stroke: stroke, pathEl: pathEl };
      if (container.setPointerCapture && e.pointerId !== undefined) {
        try { container.setPointerCapture(e.pointerId); } catch (err) {}
      }
    }
  });

  document.addEventListener('pointermove', function(e) {
    if (activeTool === 'eraser' && e.buttons === 1) {
      var hit = document.elementFromPoint(e.clientX, e.clientY);
      if (hit && hit.classList && hit.classList.contains('wb-annot-stroke')) {
        var c = hit.closest('[data-wb-annot-id]');
        if (c) eraseAnnotation(c.getAttribute('data-wb-annot-id'), hit.getAttribute('data-stroke-id'));
      }
      return;
    }
    if (!drawingCtx) return;
    var pt = containerPoint(drawingCtx.container, e.clientX, e.clientY);
    var pts = drawingCtx.stroke.pts;
    var last = pts[pts.length - 1];
    if (Math.abs(pt[0] - last[0]) + Math.abs(pt[1] - last[1]) < 1.5) return;
    pts.push(pt);
    drawingCtx.pathEl.setAttribute('d', pointsToPath(pts));
  });

  function finishPointer() {
    if (activeTool === 'highlight') {
      setTimeout(applyCursorHighlightFromSelection, 10);
    }
    if (!drawingCtx) return;
    getContainerData(drawingCtx.cid).strokes.push(drawingCtx.stroke);
    drawingCtx = null;
    saveDraft();
  }
  document.addEventListener('pointerup', finishPointer);
  document.addEventListener('mouseup', finishPointer);
  document.addEventListener('pointercancel', finishPointer);

  // Wire annotation toolbar UI
  var toolButtons = [
    ['btnToolCursor', 'cursor'],
    ['btnToolPen', 'pen'],
    ['btnToolHighlight', 'highlight'],
    ['btnToolNote', 'note'],
    ['btnToolEraser', 'eraser']
  ];
  toolButtons.forEach(function(pair) {
    var el = document.getElementById(pair[0]);
    if (el) {
      el.addEventListener('click', function() {
        setTool(pair[1]);
        if (pair[1] === 'highlight' && activeColor === '#dc2626') {
          var yellowSwatch = document.querySelector('.wb-annot-swatch[data-wb-color="#facc15"]');
          if (yellowSwatch) yellowSwatch.click();
        }
      });
    }
  });

  document.querySelectorAll('.wb-annot-swatch').forEach(function(sw) {
    sw.addEventListener('click', function() {
      activeColor = sw.getAttribute('data-wb-color') || '#dc2626';
      document.querySelectorAll('.wb-annot-swatch').forEach(function(o) {
        o.classList.toggle('is-selected', o === sw);
      });
      if (activeTool === 'cursor' || activeTool === 'eraser') setTool('pen');
    });
  });

  var sizeSlider = document.getElementById('wbAnnotSize');
  if (sizeSlider) {
    sizeSlider.addEventListener('input', function() {
      activeSize = parseFloat(sizeSlider.value) || 2.5;
    });
  }

  var btnUndo = document.getElementById('btnAnnotUndo');
  if (btnUndo) {
    btnUndo.addEventListener('click', function() {
      if (!undoStack.length) return;
      try {
        annotState = JSON.parse(undoStack.pop());
        saveDraft();
        renderAllAnnotations();
      } catch (e) {}
    });
  }

  var btnClear = document.getElementById('btnAnnotClear');
  if (btnClear) {
    btnClear.addEventListener('click', function() {
      if (!confirm('Clear all ink strokes, highlights, and notes on this document?')) return;
      pushUndo();
      annotState = { v: 1, updatedAt: Date.now(), containers: {} };
      saveDraft();
      renderAllAnnotations();
    });
  }

  function buildAnnotatedHtml() {
    var payload = JSON.stringify(annotState).replace(/</g, '\\u003c');
    var reData = /(<script\b[^>]*\bid=["']wbAnnotationsData["'][^>]*>)[\s\S]*?(<\/script>)/i;
    var source = pristineHtmlSnapshot;
    if (!source || !reData.test(source)) {
      source = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
    }
    source = source.replace(reData, function(_, openTag, closeTag) {
      return openTag + payload + closeTag;
    });
    source = source.replace(/^(<!DOCTYPE html>\s*<html\b[^>]*?)\s*\bwb-compat-ok\b/i, '$1');
    return source;
  }

  function getMainFileName() {
    var fallback = (document.title || 'whiteboard').replace(/[\\/:*?"<>|]+/g, '_').replace(/\s+/g, '_') + '.html';
    try {
      var pathParts = window.location.pathname.split('/');
      var curName = decodeURIComponent(pathParts[pathParts.length - 1] || '');
      if (curName && /\.html?$/i.test(curName)) return curName;
    } catch (e) {}
    return fallback;
  }

  // IndexedDB handle cache so Save HTML can silently overwrite once handle is linked
  var activeFileHandle = null;
  function withHandleDb(fn) {
    if (!window.indexedDB) return;
    try {
      var req = window.indexedDB.open('wbAnnotFileHandles', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('handles')) db.createObjectStore('handles');
      };
      req.onsuccess = function() { fn(req.result); };
    } catch (e) {}
  }

  withHandleDb(function(db) {
    try {
      var tx = db.transaction('handles', 'readonly');
      var getReq = tx.objectStore('handles').get(docId);
      getReq.onsuccess = function() {
        if (getReq.result) activeFileHandle = getReq.result;
      };
    } catch (e) {}
  });

  function persistFileHandle(handle) {
    activeFileHandle = handle;
    withHandleDb(function(db) {
      try {
        var tx = db.transaction('handles', 'readwrite');
        tx.objectStore('handles').put(handle, docId);
      } catch (e) {}
    });
  }

  function writeToHandle(handle, htmlOut) {
    var ensurePerm = handle.requestPermission ? handle.requestPermission({ mode: 'readwrite' }) : Promise.resolve('granted');
    return ensurePerm.then(function(state) {
      if (state !== 'granted') throw new Error('Permission denied');
      return handle.createWritable().then(function(writable) {
        return writable.write(htmlOut).then(function() {
          return writable.close();
        });
      });
    });
  }

  function markSavedSuccess(msg) {
    try { localStorage.setItem(draftKey, JSON.stringify(annotState)); } catch (e) {}
    setDirtyState(false);
    setStatus(msg);
  }

  function triggerDownload(htmlOut, fileName, msg) {
    var blob = new Blob([htmlOut], { type: 'text/html;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    setTimeout(function() {
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }, 500);
    markSavedSuccess(msg || ('Saved ' + fileName));
  }

  var btnSave = document.getElementById('btnAnnotSave');
  if (btnSave) {
    btnSave.addEventListener('click', function() {
      annotState.updatedAt = Date.now();
      var htmlOut = buildAnnotatedHtml();
      var mainName = getMainFileName();

      if (activeFileHandle) {
        writeToHandle(activeFileHandle, htmlOut).then(function() {
          markSavedSuccess('Overwrote ' + (activeFileHandle.name || mainName));
        }).catch(function(err) {
          if (err && err.name === 'AbortError') return;
          activeFileHandle = null;
          triggerDownload(htmlOut, mainName, 'Saved ' + mainName);
        });
        return;
      }

      if (window.showSaveFilePicker) {
        window.showSaveFilePicker({
          suggestedName: mainName,
          types: [{ description: 'HTML Document', accept: { 'text/html': ['.html'] } }]
        }).then(function(handle) {
          persistFileHandle(handle);
          return writeToHandle(handle, htmlOut);
        }).then(function() {
          markSavedSuccess('Overwrote ' + ((activeFileHandle && activeFileHandle.name) || mainName));
        }).catch(function(err) {
          if (err && err.name === 'AbortError') return;
          triggerDownload(htmlOut, mainName, 'Downloaded ' + mainName);
        });
      } else {
        triggerDownload(htmlOut, mainName, 'Saved ' + mainName);
      }
    });
  }

  // Save As small modal window
  var saveAsModal = document.getElementById('wbSaveAsModal');
  var saveAsInput = document.getElementById('wbSaveAsName');
  var saveAsPickerBtn = document.getElementById('btnSaveAsPicker');
  var saveAsConfirmBtn = document.getElementById('btnSaveAsConfirm');
  var saveAsCancelBtn = document.getElementById('btnSaveAsCancel');
  var btnSaveAs = document.getElementById('btnAnnotSaveAs');

  function openSaveAsModal() {
    if (!saveAsModal) return;
    var mainName = getMainFileName();
    if (saveAsInput) {
      saveAsInput.value = mainName.replace(/\.html?$/i, '') + '_annotated.html';
    }
    saveAsModal.classList.add('is-open');
    if (saveAsInput) {
      saveAsInput.focus();
      saveAsInput.select();
    }
  }

  function closeSaveAsModal() {
    if (saveAsModal) saveAsModal.classList.remove('is-open');
  }

  function normalizeHtmlFilename(val) {
    var clean = (val || '').replace(/[\\/:*?"<>|]+/g, '_').replace(/^\s+|\s+$/g, '');
    if (!clean) clean = getMainFileName();
    if (!/\.html?$/i.test(clean)) clean += '.html';
    return clean;
  }

  if (btnSaveAs) {
    btnSaveAs.addEventListener('click', openSaveAsModal);
  }
  if (saveAsCancelBtn) {
    saveAsCancelBtn.addEventListener('click', closeSaveAsModal);
  }
  if (saveAsModal) {
    saveAsModal.addEventListener('click', function(e) {
      if (e.target === saveAsModal) closeSaveAsModal();
    });
  }
  if (saveAsConfirmBtn) {
    saveAsConfirmBtn.addEventListener('click', function() {
      annotState.updatedAt = Date.now();
      var chosenName = normalizeHtmlFilename(saveAsInput ? saveAsInput.value : '');
      var htmlOut = buildAnnotatedHtml();
      closeSaveAsModal();
      triggerDownload(htmlOut, chosenName, 'Saved As ' + chosenName);
    });
  }
  if (saveAsPickerBtn) {
    saveAsPickerBtn.addEventListener('click', function() {
      annotState.updatedAt = Date.now();
      var chosenName = normalizeHtmlFilename(saveAsInput ? saveAsInput.value : '');
      var htmlOut = buildAnnotatedHtml();
      if (window.showSaveFilePicker) {
        window.showSaveFilePicker({
          suggestedName: chosenName,
          types: [{ description: 'HTML Document', accept: { 'text/html': ['.html'] } }]
        }).then(function(handle) {
          persistFileHandle(handle);
          return writeToHandle(handle, htmlOut);
        }).then(function() {
          closeSaveAsModal();
          markSavedSuccess('Saved As ' + ((activeFileHandle && activeFileHandle.name) || chosenName));
        }).catch(function(err) {
          if (err && err.name === 'AbortError') return;
          closeSaveAsModal();
          triggerDownload(htmlOut, chosenName, 'Saved As ' + chosenName);
        });
      } else {
        closeSaveAsModal();
        triggerDownload(htmlOut, chosenName, 'Saved As ' + chosenName);
      }
    });
  }
  if (saveAsInput) {
    saveAsInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && saveAsConfirmBtn) {
        e.preventDefault();
        saveAsConfirmBtn.click();
      } else if (e.key === 'Escape') {
        closeSaveAsModal();
      }
    });
  }

  document.addEventListener('keydown', function(e) {
    if (e.target && /^(INPUT|TEXTAREA|SELECT)$/i.test(e.target.tagName)) return;
    if ((e.ctrlKey || e.metaKey) && (e.key === 'z' || e.key === 'Z') && undoStack.length > 0) {
      e.preventDefault();
      if (btnUndo) btnUndo.click();
    } else if (e.key === 'Escape') {
      if (saveAsModal && saveAsModal.classList.contains('is-open')) {
        closeSaveAsModal();
      } else if (activeTool !== 'cursor') {
        setTool('cursor');
      }
    }
  });

  var btnPrint = document.getElementById('btnPrintDoc');
  if (btnPrint) {
    btnPrint.addEventListener('click', function() {
      if (window.print) window.print();
    });
  }

  function syncTopBarBodyOffset() {
    try {
      var bar = document.getElementById('floatingToolbar');
      if (bar && bar.offsetHeight > 0 && document.body && document.body.style) {
        document.body.style.paddingTop = (bar.offsetHeight + 16) + 'px';
      }
    } catch (e) {}
  }

  // Expand all collapsible boxes before Ctrl+P / print, restore afterward
  function expandAllForPrint() {
    var boxes = document.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox');
    boxes.forEach(function(d) {
      if (!d.open && !d.hasAttribute('data-wb-print-was-closed')) {
        d.setAttribute('data-wb-print-was-closed', '1');
      }
      d.open = true;
    });
    if (document.body && document.body.style) document.body.style.paddingTop = '0px';
    syncAllLayerSizes();
  }

  function restoreAfterPrint() {
    var boxes = document.querySelectorAll('details[data-wb-print-was-closed="1"]');
    boxes.forEach(function(d) {
      d.open = false;
      d.removeAttribute('data-wb-print-was-closed');
    });
    syncTopBarBodyOffset();
    syncAllLayerSizes();
  }

  window.addEventListener('beforeprint', expandAllForPrint);
  window.addEventListener('afterprint', restoreAfterPrint);
  if (window.matchMedia) {
    var printMq = window.matchMedia('print');
    var onPrintMq = function(ev) {
      if (ev.matches) expandAllForPrint();
      else restoreAfterPrint();
    };
    if (printMq.addEventListener) printMq.addEventListener('change', onPrintMq);
    else if (printMq.addListener) printMq.addListener(onPrintMq);
  }

  document.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox').forEach(function(d) {
    d.addEventListener('toggle', function() {
      setTimeout(syncAllLayerSizes, 20);
    });
  });
  window.addEventListener('resize', function() {
    syncTopBarBodyOffset();
    syncAllLayerSizes();
  });
  window.addEventListener('load', function() {
    syncTopBarBodyOffset();
    syncAllLayerSizes();
  });

  var btnPopupSave = document.getElementById('btnPopupSave');
  var btnPopupSaveAs = document.getElementById('btnPopupSaveAs');
  var btnPopupDismiss = document.getElementById('btnPopupDismiss');
  var btnPopupLater = document.getElementById('btnPopupLater');
  if (btnPopupSave) {
    btnPopupSave.addEventListener('click', function() {
      if (btnSave) btnSave.click();
    });
  }
  if (btnPopupSaveAs) {
    btnPopupSaveAs.addEventListener('click', function() {
      hideUnsavedPopup();
      openSaveAsModal();
    });
  }
  function dismissReminder() {
    hideUnsavedPopup();
  }
  if (btnPopupDismiss) btnPopupDismiss.addEventListener('click', dismissReminder);
  if (btnPopupLater) btnPopupLater.addEventListener('click', dismissReminder);
  if (statusEl) {
    statusEl.addEventListener('click', function() {
      if (isDirty) showUnsavedPopup();
    });
  }

  window.addEventListener('beforeunload', function(e) {
    if (!isDirty) return;
    setTimeout(showUnsavedPopup, 150);
    e.preventDefault();
    e.returnValue = '';
    return '';
  });

  syncTopBarBodyOffset();
  loadInitialAnnotations();
  renderAllAnnotations();

  // 5. Embedded HTML Tab Launcher (creates on-click Blob URL and opens in new tab)
  document.addEventListener('click', function(e) {
    var tgt = (e.target && e.target.nodeType === 3) ? e.target.parentNode : e.target;
    var btn = tgt && tgt.closest ? tgt.closest('.wb-html-launch') : null;
    if (!btn) return;
    var payloadId = btn.getAttribute('data-wb-html-target');
    var payloadEl = payloadId ? document.getElementById(payloadId) : null;
    if (!payloadEl) return;
    try {
      var b64 = (payloadEl.textContent || '').replace(/\s+/g, '');
      var binStr = window.atob ? window.atob(b64) : '';
      var bytes = new Uint8Array(binStr.length);
      for (var i = 0; i < binStr.length; i++) {
        bytes[i] = binStr.charCodeAt(i);
      }
      var blob = new Blob([bytes], { type: 'text/html;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var opened = window.open ? window.open(url, '_blank') : null;
      if (!opened) {
        var a = document.createElement('a');
        a.href = url;
        a.target = '_blank';
        a.rel = 'noopener';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
      }
      setTimeout(function() { URL.revokeObjectURL(url); }, 60000);
    } catch (err) {
      alert('Unable to open embedded HTML in a new tab: ' + err);
    }
  });
})();
</script>]===]

  new_blocks[#new_blocks + 1] = pandoc.RawBlock("html", toolbar_html)

  return pandoc.Pandoc(new_blocks, doc.meta)
end
