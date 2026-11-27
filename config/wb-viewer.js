(function() {
  window.__wbViewerLoaded = true;
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
        if (window.__wbIsCdnMode && typeof window.__wbShowCdnOffline === 'function') {
          window.__wbShowCdnOffline('MathJax loaded but could not render equations cleanly', false);
        } else {
          showCompatWarning(['MathJax loaded but failed to render equations']);
        }
      }
    }, function() {
      if (window.__wbIsCdnMode && typeof window.__wbShowCdnOffline === 'function') {
        window.__wbShowCdnOffline('MathJax equation engine failed to initialize from CDN', false);
      } else {
        showCompatWarning(['MathJax failed to initialize equations in this viewer']);
      }
    });
    return true;
  }

  function verifyStylesAndMath() {
    var issues = [];
    var offlineCdn = !!(window.__wbIsCdnMode && ((typeof navigator !== 'undefined' && navigator.onLine === false) || window.__wbCdnCssErr));
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
          if (window.__wbIsCdnMode && typeof window.__wbShowCdnOffline === 'function') {
            window.__wbShowCdnOffline('MathJax equation engine could not download from CDN', false);
          } else {
            showCompatWarning(['MathJax equation engine could not load (scripts or network may be blocked)']);
          }
        }
      }, 1500);
    }

    if (offlineCdn && typeof window.__wbShowCdnOffline === 'function') {
      window.__wbShowCdnOffline('Network offline or CDN stylesheet failed to download', false);
    } else if (issues.length) {
      showCompatWarning(issues);
    }
  }

  if (document.readyState === 'complete') {
    verifyStylesAndMath();
  } else if (window.addEventListener) {
    window.addEventListener('load', verifyStylesAndMath);
  }

  // 1. Box Expand / Collapse Toggle & Floating Breadcrumb Box Window
  var annotMetaEl = document.getElementById('wbAnnotationsData');
  var defaultBoxMode = (annotMetaEl && annotMetaEl.getAttribute('data-wb-box-mode') === 'inline') ? 'inline' : 'popup';
  if (defaultBoxMode === 'inline' && document.body && document.body.classList) {
    document.body.classList.add('wb-boxes-inline');
  }

  var btnBoxes = document.getElementById('btnToggleBoxes');
  var lblBoxes = document.getElementById('toggleBoxesLabel');
  var icoBoxes = document.getElementById('toggleBoxesIcon');
  var allExpanded = (defaultBoxMode === 'inline');

  var boxModalBackdrop = document.getElementById('wbBoxModalBackdrop');
  var boxModalEl = document.getElementById('wbBoxModal');
  var boxModalCrumbs = document.getElementById('wbBoxModalBreadcrumbs');
  var boxModalBody = document.getElementById('wbBoxModalBody');
  var btnBoxModalBack = document.getElementById('btnBoxModalBack');
  var btnBoxModalClose = document.getElementById('btnBoxModalClose');
  var boxModalStack = []; // [{ det, bodyEl, placeholder, scrollTop }]

  function isInlineBoxMode() {
    return !!(document.body && document.body.classList && document.body.classList.contains('wb-boxes-inline'));
  }

  function getBoxBody(det) {
    if (!det) return null;
    if (det.__wbBodyEl) return det.__wbBodyEl;
    return det.querySelector ? det.querySelector(':scope > .marginbox-body') : null;
  }

  function mountBoxBodyToModal(entry) {
    if (!entry || !entry.bodyEl || !boxModalBody) return;
    if (!entry.placeholder && entry.bodyEl.parentNode === entry.det) {
      var ph = document.createElement('span');
      ph.className = 'wb-box-placeholder';
      ph.style.display = 'none';
      entry.det.insertBefore(ph, entry.bodyEl);
      entry.placeholder = ph;
    }
    entry.det.__wbBodyEl = entry.bodyEl;
    boxModalBody.appendChild(entry.bodyEl);
    if (boxModalEl && boxModalEl.style && entry.det.style) {
      var col = (entry.det.style.getPropertyValue && entry.det.style.getPropertyValue('--box-col')) || '#1A9E39';
      boxModalEl.style.setProperty('--modal-box-col', col || '#1A9E39');
    }
  }

  function restoreBoxBodyFromModal(entry) {
    if (!entry || !entry.bodyEl || !entry.det) return;
    if (entry.placeholder && entry.placeholder.parentNode === entry.det) {
      entry.det.insertBefore(entry.bodyEl, entry.placeholder);
      entry.det.removeChild(entry.placeholder);
      entry.placeholder = null;
    } else if (entry.bodyEl.parentNode !== entry.det) {
      entry.det.appendChild(entry.bodyEl);
    }
  }

  function getBoxTitleHtml(det) {
    var sum = det && det.querySelector ? det.querySelector(':scope > summary') : null;
    return sum ? (sum.innerHTML || sum.textContent || 'Box') : 'Box';
  }

  function renderBoxModalBreadcrumbs() {
    if (!boxModalCrumbs) return;
    boxModalCrumbs.innerHTML = '';

    function appendSep() {
      var sep = document.createElement('span');
      sep.className = 'wb-box-crumb-sep';
      sep.textContent = '›';
      boxModalCrumbs.appendChild(sep);
    }

    function appendCrumb(idx) {
      var crumb = document.createElement('button');
      crumb.type = 'button';
      crumb.className = 'wb-box-crumb' + (idx === boxModalStack.length - 1 ? ' is-current' : '');
      crumb.innerHTML = getBoxTitleHtml(boxModalStack[idx].det);
      crumb.title = boxModalStack[idx].det && boxModalStack[idx].det.querySelector
        ? ((boxModalStack[idx].det.querySelector(':scope > summary') || {}).textContent || '')
        : '';
      if (idx < boxModalStack.length - 1) {
        (function(targetIdx) {
          crumb.addEventListener('click', function() { jumpToBoxLevel(targetIdx); });
        })(idx);
      }
      boxModalCrumbs.appendChild(crumb);
    }

    if (boxModalStack.length <= 2) {
      for (var i = 0; i < boxModalStack.length; i++) {
        if (i > 0) appendSep();
        appendCrumb(i);
      }
    } else {
      appendCrumb(0);
      appendSep();
      var midTitles = [];
      for (var m = 1; m < boxModalStack.length - 1; m++) {
        var ms = boxModalStack[m].det && boxModalStack[m].det.querySelector ? boxModalStack[m].det.querySelector(':scope > summary') : null;
        if (ms && ms.textContent) midTitles.push(ms.textContent.trim());
      }
      var ell = document.createElement('button');
      ell.type = 'button';
      ell.className = 'wb-box-crumb wb-box-crumb-ellipsis';
      ell.textContent = '...';
      ell.title = midTitles.length ? ('Back to parent (' + midTitles.join(' › ') + ')') : 'Back to parent';
      ell.addEventListener('click', popBoxModal);
      boxModalCrumbs.appendChild(ell);
      appendSep();
      appendCrumb(boxModalStack.length - 1);
    }

    if (btnBoxModalBack) {
      btnBoxModalBack.style.display = boxModalStack.length > 1 ? 'inline-block' : 'none';
    }
  }

  function showCurrentBoxEntry(scrollVal) {
    var cur = boxModalStack[boxModalStack.length - 1];
    if (!cur || !boxModalBackdrop || !boxModalBody) return;
    mountBoxBodyToModal(cur);
    renderBoxModalBreadcrumbs();
    boxModalBackdrop.classList.add('is-open');
    if (document.documentElement && document.documentElement.classList) document.documentElement.classList.add('wb-modal-open');
    if (document.body && document.body.classList) document.body.classList.add('wb-modal-open');
    boxModalBody.scrollTop = typeof scrollVal === 'number' ? scrollVal : 0;
    setTimeout(syncAllLayerSizes, 15);
  }

  function openBoxModal(det) {
    if (!det || !boxModalBackdrop || !boxModalBody) return;
    var bodyEl = getBoxBody(det);
    if (!bodyEl) return;
    if (boxModalStack.length > 0) {
      var prev = boxModalStack[boxModalStack.length - 1];
      if (prev.det === det) return;
      prev.scrollTop = boxModalBody.scrollTop || 0;
      restoreBoxBodyFromModal(prev);
    }
    boxModalStack.push({ det: det, bodyEl: bodyEl, placeholder: null, scrollTop: 0 });
    showCurrentBoxEntry(0);
  }

  function openBoxModalChain(detList) {
    if (!detList || !detList.length || !boxModalBackdrop || !boxModalBody) return;
    closeBoxModal();
    for (var i = 0; i < detList.length; i++) {
      var bodyEl = getBoxBody(detList[i]);
      if (bodyEl) {
        boxModalStack.push({ det: detList[i], bodyEl: bodyEl, placeholder: null, scrollTop: 0 });
      }
    }
    if (boxModalStack.length > 0) {
      showCurrentBoxEntry(0);
    }
  }

  function jumpToBoxLevel(idx) {
    if (idx < 0 || idx >= boxModalStack.length - 1) return;
    var cur = boxModalStack[boxModalStack.length - 1];
    restoreBoxBodyFromModal(cur);
    boxModalStack.length = idx + 1;
    var target = boxModalStack[idx];
    showCurrentBoxEntry(target.scrollTop || 0);
  }

  function popBoxModal() {
    if (boxModalStack.length <= 1) {
      closeBoxModal();
      return;
    }
    var cur = boxModalStack.pop();
    restoreBoxBodyFromModal(cur);
    var prev = boxModalStack[boxModalStack.length - 1];
    showCurrentBoxEntry(prev.scrollTop || 0);
  }

  function closeBoxModal() {
    if (boxModalStack.length > 0) {
      var cur = boxModalStack[boxModalStack.length - 1];
      restoreBoxBodyFromModal(cur);
      boxModalStack = [];
    }
    if (boxModalBackdrop && boxModalBackdrop.classList) {
      boxModalBackdrop.classList.remove('is-open');
    }
    if (document.documentElement && document.documentElement.classList) document.documentElement.classList.remove('wb-modal-open');
    if (document.body && document.body.classList) document.body.classList.remove('wb-modal-open');
    setTimeout(syncAllLayerSizes, 15);
  }

  if (btnBoxModalBack) btnBoxModalBack.addEventListener('click', popBoxModal);
  if (btnBoxModalClose) btnBoxModalClose.addEventListener('click', closeBoxModal);
  if (boxModalBackdrop) {
    boxModalBackdrop.addEventListener('click', function(ev) {
      if (ev.target === boxModalBackdrop) closeBoxModal();
    });
  }

  if (btnBoxes) {
    btnBoxes.addEventListener('click', function() {
      allExpanded = !allExpanded;
      if (allExpanded) {
        closeBoxModal();
        if (document.body && document.body.classList) document.body.classList.add('wb-boxes-inline');
      } else {
        if (defaultBoxMode !== 'inline' && document.body && document.body.classList) {
          document.body.classList.remove('wb-boxes-inline');
        }
      }
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
    document.documentElement.classList.remove('latex-dark', 'latex-light');
    document.body.classList.remove('latex-dark', 'latex-light');
    if (theme === 'dark') {
      document.documentElement.classList.add('latex-dark');
      document.body.classList.add('latex-dark');
    }
    if (theme === 'light') {
      document.documentElement.classList.add('latex-light');
      document.body.classList.add('latex-light');
    }
    try {
      localStorage.setItem('latex-theme', theme);
    } catch (e) {}
    currentTheme = theme;
    if (typeof window.__wbGraphRefreshTheme === 'function') {
      window.__wbGraphRefreshTheme();
    }
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
        if (parentEl && parentEl.closest && !parentEl.closest('.floating-toolbar, .wb-annot-toolbar, .wb-sticky-note, .wb-save-modal, summary.marginbox-header, .marginbox-footer')) {
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
    if (tgt && tgt.closest && (tgt.closest('.floating-toolbar') || tgt.closest('.wb-annot-toolbar') || tgt.closest('.wb-save-modal') || tgt.closest('summary.marginbox-header') || tgt.closest('.marginbox-footer') || tgt.closest('.wb-sticky-note'))) {
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
    source = source.replace(/\s*\bwb-modal-open\b/g, '');
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
      } else if (boxModalBackdrop && boxModalBackdrop.classList.contains('is-open')) {
        closeBoxModal();
      } else if (document.body.classList.contains('wb-graph-open')) {
        if (typeof window.__wbGraphClose === 'function') window.__wbGraphClose();
      } else if (document.body.classList.contains('wb-toc-open')) {
        if (typeof window.__wbTocClose === 'function') window.__wbTocClose();
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
        document.documentElement.style.setProperty('--wb-toolbar-h', bar.offsetHeight + 'px');
      }
    } catch (e) {}
  }

  // Expand all collapsible boxes before Ctrl+P / print, restore afterward
  var wasGraphOpenBeforePrint = false;
  var wasTocOpenBeforePrint = false;
  var wasInlineBeforePrint = false;
  var savedModalDetsBeforePrint = [];
  function expandAllForPrint() {
    wasGraphOpenBeforePrint = document.body.classList.contains('wb-graph-open');
    wasTocOpenBeforePrint = document.body.classList.contains('wb-toc-open');
    wasInlineBeforePrint = isInlineBoxMode();
    savedModalDetsBeforePrint = boxModalStack.map(function(entry) { return entry.det; });
    if (savedModalDetsBeforePrint.length) closeBoxModal();
    if (!wasInlineBeforePrint && document.body && document.body.classList) {
      document.body.classList.add('wb-boxes-inline');
    }
    if (wasGraphOpenBeforePrint) document.body.classList.remove('wb-graph-open');
    if (wasTocOpenBeforePrint) document.body.classList.remove('wb-toc-open');
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
    if (!wasInlineBeforePrint && document.body && document.body.classList) {
      document.body.classList.remove('wb-boxes-inline');
    }
    if (savedModalDetsBeforePrint.length) {
      openBoxModalChain(savedModalDetsBeforePrint);
      savedModalDetsBeforePrint = [];
    }
    if (wasGraphOpenBeforePrint) {
      document.body.classList.add('wb-graph-open');
      wasGraphOpenBeforePrint = false;
    }
    if (wasTocOpenBeforePrint) {
      document.body.classList.add('wb-toc-open');
      wasTocOpenBeforePrint = false;
    }
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

  // 5. Embedded HTML Tab Launcher & Floating Box Modal Trigger
  document.addEventListener('click', function(e) {
    var tgt = (e.target && e.target.nodeType === 3) ? e.target.parentNode : e.target;
    var summaryEl = tgt && tgt.closest ? tgt.closest('details.marginbox > summary, details.tcolorbox > summary, details.vbox > summary') : null;
    if (summaryEl && !isInlineBoxMode()) {
      var parentDet = summaryEl.parentElement;
      if (parentDet) {
        e.preventDefault();
        openBoxModal(parentDet);
        return;
      }
    }
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

  // 6. Interactive Markmap Graph View
  (function initGraphView() {
    var btnToggleGraph = document.getElementById('btnToggleGraph');
    var workspace = document.getElementById('wbGraphWorkspace');
    var dataNode = document.getElementById('wbGraphData');
    var svgEl = document.getElementById('wbGraphSvg');
    if (!btnToggleGraph || !workspace || !dataNode || !svgEl) return;

    var btnFull = document.getElementById('btnGraphModeFull');
    var btnSplit = document.getElementById('btnGraphModeSplit');
    var btnClose = document.getElementById('btnGraphClose');
    var btnFit = document.getElementById('btnGraphFit');
    var btnZoomIn = document.getElementById('btnGraphZoomIn');
    var btnZoomOut = document.getElementById('btnGraphZoomOut');
    var btnExportSvg = document.getElementById('btnGraphExportSvg');
    var btnNewTab = document.getElementById('btnGraphNewTab');
    var btnJumpSelected = document.getElementById('btnGraphJumpSelected');
    var selLabelEl = document.getElementById('wbGraphSelLabel');
    var searchInput = document.getElementById('wbGraphSearch');
    var btnSearchClear = document.getElementById('btnGraphSearchClear');
    var btnMatchPrev = document.getElementById('btnGraphMatchPrev');
    var btnMatchNext = document.getElementById('btnGraphMatchNext');
    var matchCountEl = document.getElementById('wbGraphMatchCount');
    var depthBtns = workspace.querySelectorAll('.wb-graph-depth');

    var graphData = null;
    var mm = null;
    var activeTree = null;
    var graphMode = 'full';
    var currentDepth = 1;
    var selectedNode = null;
    var searchMatches = [];
    var searchIndex = -1;
    var renderHookInstalled = false;

    function normText(s) {
      return String(s || '').replace(/\s+/g, ' ').trim().toLowerCase();
    }

    function escapeHtmlStr(s) {
      return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    var vendorBundleCache = null;
    var assetsPromise = null;

    function parsePayload() {
      if (graphData) return graphData;
      try {
        var raw = JSON.parse(dataNode.textContent || '{}');
        if (raw && raw.root) {
          graphData = raw;
        }
      } catch (e) {
        graphData = null;
      }
      return graphData;
    }

    function gunzipBase64Json(b64) {
      if (!b64 || typeof DecompressionStream !== 'function') {
        return Promise.reject(new Error('Gzip decompression not supported in this browser'));
      }
      var binStr = window.atob ? window.atob(b64) : '';
      var bytes = new Uint8Array(binStr.length);
      for (var i = 0; i < binStr.length; i++) {
        bytes[i] = binStr.charCodeAt(i);
      }
      var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
      return new Response(stream).text().then(function(txt) {
        return JSON.parse(txt);
      });
    }

    function loadScriptSeq(src) {
      return new Promise(function(resolve, reject) {
        var s = document.createElement('script');
        s.src = src;
        s.onload = function() { resolve(); };
        s.onerror = function() { reject(new Error('Failed to load ' + src)); };
        document.head.appendChild(s);
      });
    }

    function ensureAssetsReadyAsync(needMarkmap) {
      var hasPayload = !!parsePayload();
      var hasVendor = !needMarkmap || !!(window.markmap && window.markmap.Markmap && window.d3);
      if (hasPayload && hasVendor) {
        return Promise.resolve(true);
      }
      if (assetsPromise) return assetsPromise;

      var steps = [];
      if (!hasPayload) {
        steps.push((function() {
          try {
            var meta = JSON.parse(dataNode.textContent || '{}');
            if (meta && meta.v === 2 && meta.gz) {
              return gunzipBase64Json(meta.gz).then(function(rootObj) {
                graphData = { root: rootObj, katexCss: (vendorBundleCache && vendorBundleCache.katexCss) || '' };
              });
            }
          } catch (e) {}
          return Promise.resolve();
        })());
      }

      if (!hasVendor) {
        var vendorNode = document.getElementById('wbVendorGz');
        var cdnMode = dataNode.getAttribute('data-wb-assets') === 'cdn';
        var cdnBase = (dataNode.getAttribute('data-wb-cdn-base') || 'https://cdn.jsdelivr.net/gh/Thunderock7777/ai-ready-markdown-to-pdf@main').replace(/\/+$/, '');

        if (vendorNode && vendorNode.textContent) {
          steps.push((function() {
            try {
              var vMeta = JSON.parse(vendorNode.textContent || '{}');
              if (vMeta && vMeta.gz) {
                return gunzipBase64Json(vMeta.gz).then(function(vObj) {
                  vendorBundleCache = vObj;
                  if (vObj.katexCss && graphData && !graphData.katexCss) {
                    graphData.katexCss = vObj.katexCss;
                  }
                  if (vObj.katexCss) ensureKatexStyles({ katexCss: vObj.katexCss });
                  if (vObj.d3 && !window.d3) (0, eval)(vObj.d3);
                  if (vObj.mm && !(window.markmap && window.markmap.Markmap)) (0, eval)(vObj.mm);
                });
              }
            } catch (e) {}
            return Promise.resolve();
          })());
        } else if (cdnMode) {
          steps.push((function() {
            var cssReady = Promise.resolve();
            if (!document.getElementById('wbMarkmapKatexLink')) {
              cssReady = new Promise(function(resolve) {
                var done = false;
                var finish = function() { if (!done) { done = true; resolve(); } };
                var lnk = document.createElement('link');
                lnk.id = 'wbMarkmapKatexLink';
                lnk.rel = 'stylesheet';
                lnk.href = cdnBase + '/config/markmap/vendor/katex/katex.min.css';
                lnk.onload = finish;
                lnk.onerror = finish;
                document.head.appendChild(lnk);
                setTimeout(finish, 3000);
              });
            }
            var scriptsReady = (window.d3 ? Promise.resolve() : loadScriptSeq(cdnBase + '/config/markmap/vendor/d3.min.js')).then(function() {
              if (window.markmap && window.markmap.Markmap) return;
              return loadScriptSeq(cdnBase + '/config/markmap/vendor/markmap-view.min.js');
            });
            return Promise.all([cssReady, scriptsReady]);
          })());
        }
      }

      assetsPromise = Promise.all(steps).then(function() {
        if (vendorBundleCache && vendorBundleCache.katexCss && graphData && !graphData.katexCss) {
          graphData.katexCss = vendorBundleCache.katexCss;
        }
        assetsPromise = null;
        return true;
      }, function(err) {
        assetsPromise = null;
        if (typeof console !== 'undefined' && console.error) console.error('Tree/TOC asset load failed:', err);
        if (dataNode.getAttribute('data-wb-assets') === 'cdn' && typeof window.__wbShowCdnOffline === 'function') {
          window.__wbShowCdnOffline('Could not download Tree View assets (d3 / markmap / KaTeX) from CDN', true);
        }
        return false;
      });
      return assetsPromise;
    }

    function ensureKatexStyles(payload) {
      if (!payload || !payload.katexCss) return;
      if (document.getElementById('wbMarkmapKatex')) return;
      var st = document.createElement('style');
      st.id = 'wbMarkmapKatex';
      st.textContent = payload.katexCss;
      document.head.appendChild(st);
    }

    function cloneWithDepth(node, depth, maxDepth) {
      var rawHtml = String(node.content || '').replace(/<button[^>]*class="wb-mm-jump"[^>]*>[\s\S]*?<\/button>/gi, '');
      var copy = {
        content: rawHtml,
        children: [],
        payload: node.payload ? JSON.parse(JSON.stringify(node.payload)) : {}
      };
      var children = Array.isArray(node.children) ? node.children : [];
      if (maxDepth > 0 && depth >= maxDepth && children.length > 0) {
        copy.payload.fold = 1;
      } else {
        copy.payload.fold = 0;
      }
      for (var i = 0; i < children.length; i++) {
        copy.children.push(cloneWithDepth(children[i], depth + 1, maxDepth));
      }
      return copy;
    }

    function ensureSvgJumpBadge(gEl, d, spH) {
      var wb = d && d.data && d.data.payload && d.data.payload.wb;
      var want = !!(wb && wb.jtype);
      var existing = null;
      var ch = gEl.children || [];
      for (var i = 0; i < ch.length; i++) {
        if (ch[i].classList && ch[i].classList.contains('wb-mm-jump-svg')) {
          existing = ch[i];
          break;
        }
      }
      if (!want) {
        if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
        return;
      }
      var hasKids = !!(d.data.children && d.data.children.length);
      var lineEndX = (typeof d.ySize === 'number') ? Math.max(24, d.ySize - spH) : 120;
      var nodeH = (typeof d.xSize === 'number') ? d.xSize : 24;
      var bx = Math.round(lineEndX + (hasKids ? 10 : 4));
      var by = Math.max(0, Math.round(nodeH - 20));

      if (!existing && document.createElementNS) {
        var ns = 'http://www.w3.org/2000/svg';
        existing = document.createElementNS(ns, 'g');
        existing.setAttribute('class', 'wb-mm-jump wb-mm-jump-svg');
        var titleEl = document.createElementNS(ns, 'title');
        titleEl.textContent = 'Jump to this note';
        var rectEl = document.createElementNS(ns, 'rect');
        rectEl.setAttribute('class', 'wb-mm-jump-bg');
        rectEl.setAttribute('x', '0');
        rectEl.setAttribute('y', '0');
        rectEl.setAttribute('width', '20');
        rectEl.setAttribute('height', '18');
        rectEl.setAttribute('rx', '4');
        rectEl.setAttribute('ry', '4');
        var txtEl = document.createElementNS(ns, 'text');
        txtEl.setAttribute('class', 'wb-mm-jump-ico');
        txtEl.setAttribute('x', '10');
        txtEl.setAttribute('y', '13');
        txtEl.setAttribute('text-anchor', 'middle');
        txtEl.textContent = '↗';
        existing.appendChild(titleEl);
        existing.appendChild(rectEl);
        existing.appendChild(txtEl);
        if (existing.addEventListener) {
          existing.addEventListener('mousedown', function(ev) { ev.stopPropagation(); });
          existing.addEventListener('dblclick', function(ev) { ev.stopPropagation(); });
        }
        gEl.appendChild(existing);
      }
      if (existing) {
        existing.setAttribute('transform', 'translate(' + bx + ',' + by + ')');
      }
    }

    function decorateNodes() {
      if (!mm || !mm.g) return;
      var matchSet = new Set(searchMatches);
      var activeMatch = (searchIndex >= 0 && searchIndex < searchMatches.length) ? searchMatches[searchIndex] : null;
      var spH = (mm.options && mm.options.spacingHorizontal) || 92;
      mm.g.selectAll('g.markmap-node').each(function(d) {
        if (!d || !d.data) return;
        var isSel = (selectedNode && d.data === selectedNode);
        var isMatch = matchSet.has(d.data);
        var isCurMatch = (activeMatch && d.data === activeMatch);
        this.classList.toggle('wb-mm-selected', !!isSel);
        this.classList.toggle('wb-mm-match', !!isMatch);
        this.classList.toggle('wb-mm-current-match', !!isCurMatch);
        ensureSvgJumpBadge(this, d, spH);
      });
    }

    function updateSelectionUi(nodeData) {
      selectedNode = nodeData || null;
      var wb = selectedNode && selectedNode.payload && selectedNode.payload.wb;
      if (wb && wb.jtype) {
        var titleText = wb.jtitle || wb.text || 'Selected Node';
        if (selLabelEl) selLabelEl.textContent = 'Selected: ' + titleText;
        if (btnJumpSelected) btnJumpSelected.disabled = false;
      } else {
        if (selLabelEl) selLabelEl.textContent = 'Click any node or its ↗ button to jump to notes';
        if (btnJumpSelected) btnJumpSelected.disabled = true;
      }
      decorateNodes();
    }

    function extractCleanProse(el) {
      if (!el) return '';
      var out = [];
      var rootEl = el;
      function walk(n) {
        if (!n) return;
        if (n.nodeType === 3) {
          out.push(n.nodeValue || n.textContent || '');
          return;
        }
        if (n.nodeType !== 1) return;
        var tag = (n.tagName || '').toUpperCase();
        if (tag === 'MJX-CONTAINER' || tag === 'MJX-ASSISTIVE-MML' || tag === 'SCRIPT' || tag === 'STYLE') return;
        if (n !== rootEl) {
          if (tag === 'DETAILS') return;
          if ((rootEl.tagName || '').toUpperCase() === 'LI' && (tag === 'UL' || tag === 'OL')) return;
          if (n.classList && (n.classList.contains('marginbox-footer') || n.classList.contains('wb-annot-layer'))) return;
        }
        var ch = n.childNodes || n.children || [];
        for (var i = 0; i < ch.length; i++) walk(ch[i]);
      }
      walk(el);
      var txt = normText(out.join(' '));
      if (!txt && el.textContent) {
        txt = normText(el.textContent);
      }
      return txt;
    }

    function normAlnumWords(s) {
      return normText(s).replace(/[^\w\u00c0-\u024f]+/g, ' ').replace(/\s+/g, ' ').trim();
    }

    function getEnclosingBox(el) {
      var cur = el ? el.parentElement : null;
      while (cur) {
        if (cur.tagName === 'DETAILS' && cur.classList &&
            (cur.classList.contains('marginbox') || cur.classList.contains('tcolorbox') || cur.classList.contains('vbox'))) {
          return cur;
        }
        cur = cur.parentElement;
      }
      return null;
    }

    function boxSummaryNorm(det) {
      if (!det || !det.querySelector) return '';
      var s = det.querySelector(':scope > summary');
      return s ? normText(extractCleanProse(s) || s.textContent) : '';
    }

    function resolveContainerTarget(wb) {
      if (!wb || !wb.jtype) return null;
      if (wb.jtype === 'top') return { kind: 'top', el: document.body, flashEl: document.body };

      var wanted = normText(wb.jtitle);
      var wantedWords = normAlnumWords(wb.jtitle);
      var wantedIdx = wb.jidx || 1;
      var wantedAnc = normText(wb.janc);

      if (wb.jtype === 'h') {
        if (wb.jid) {
          var byId = document.getElementById(wb.jid);
          if (byId) {
            var pb = getEnclosingBox(byId);
            if (!wantedAnc || !pb || boxSummaryNorm(pb) === wantedAnc || normAlnumWords(boxSummaryNorm(pb)) === normAlnumWords(wantedAnc)) {
              return { kind: 'h', el: byId, flashEl: byId };
            }
          }
        }
        var headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
        var exactH = [];
        var prefixH = [];
        for (var i = 0; i < headings.length; i++) {
          var hEl = headings[i];
          var hClean = normText(extractCleanProse(hEl));
          var hCleanWords = normAlnumWords(hClean);
          var hFull = normText(hEl.textContent);
          var isExact = (hFull === wanted) || (wantedWords && hCleanWords === wantedWords);
          var isPrefix = !isExact && wantedWords && wantedWords.length >= 8 && hCleanWords.indexOf(wantedWords.slice(0, 18)) === 0;
          if (isExact || isPrefix) {
            var hBox = getEnclosingBox(hEl);
            var ancOk = !wantedAnc || (hBox && boxSummaryNorm(hBox) === wantedAnc);
            (isExact ? exactH : prefixH).push({ el: hEl, ancOk: ancOk });
          }
        }
        var hCandidates = exactH.length > 0 ? exactH : prefixH;
        if (hCandidates.length > 0) {
          var filteredH = hCandidates.filter(function(c) { return c.ancOk; });
          var poolH = filteredH.length > 0 ? filteredH : hCandidates;
          var pickH = poolH[Math.min(poolH.length - 1, Math.max(0, wantedIdx - 1))];
          return { kind: 'h', el: pickH.el, flashEl: pickH.el };
        }
        if (wb.jid) {
          var fallbackId = document.getElementById(wb.jid);
          if (fallbackId) return { kind: 'h', el: fallbackId, flashEl: fallbackId };
        }
      }

      if (wb.jtype === 'box') {
        if (wb.jid) {
          var exactBox = document.getElementById(wb.jid);
          if (exactBox) {
            var sumNorm = boxSummaryNorm(exactBox);
            var pbExact = getEnclosingBox(exactBox);
            var ancMatches = !wantedAnc || !pbExact || boxSummaryNorm(pbExact) === wantedAnc;
            if ((!wanted || sumNorm === wanted) && ancMatches) {
              var sEl = exactBox.querySelector(':scope > summary');
              return { kind: 'box', el: exactBox, flashEl: sEl || exactBox };
            }
          }
        }
        var boxes = document.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox');
        var bCandidates = [];
        for (var j = 0; j < boxes.length; j++) {
          var bx = boxes[j];
          if (boxSummaryNorm(bx) === wanted) {
            var pb2 = getEnclosingBox(bx);
            var ancOkB = !wantedAnc || (pb2 && boxSummaryNorm(pb2) === wantedAnc);
            bCandidates.push({ el: bx, ancOk: ancOkB });
          }
        }
        if (bCandidates.length > 0) {
          var filteredB = bCandidates.filter(function(c) { return c.ancOk; });
          var poolB = filteredB.length > 0 ? filteredB : bCandidates;
          var pickB = poolB[Math.min(poolB.length - 1, Math.max(0, wantedIdx - 1))];
          var fs = pickB.el.querySelector(':scope > summary');
          return { kind: 'box', el: pickB.el, flashEl: fs || pickB.el };
        }
      }

      return null;
    }

    function matchesItemType(el, jitem) {
      if (!el || !el.tagName) return false;
      var tag = el.tagName.toUpperCase();
      if (jitem === 'p') return tag === 'P' || tag === 'LI';
      if (jitem === 'code') return tag === 'PRE';
      if (jitem === 'tbl') return tag === 'TABLE';
      if (jitem === 'html') return !!(el.classList && el.classList.contains('wb-html-card'));
      if (jitem === 'diag') {
        return tag === 'FIGURE' || (tag === 'IMG' && (el.getAttribute('src') || '').indexOf('data:image/svg+xml') === 0);
      }
      return false;
    }

    function collectSublistsFromLi(liEl, jitem, visitFn) {
      if (!liEl || !liEl.children) return;
      for (var k = 0; k < liEl.children.length; k++) {
        var chTag = (liEl.children[k].tagName || '').toUpperCase();
        if (chTag === 'UL' || chTag === 'OL') {
          visitFn(liEl.children[k]);
        }
      }
    }

    function collectScopeItems(containerInfo, jitem) {
      var out = [];
      if (!containerInfo) return out;

      function walkChildrenCollecting(node) {
        if (!node || !node.children) return;
        for (var i = 0; i < node.children.length; i++) {
          var c = node.children[i];
          var tag = (c.tagName || '').toUpperCase();
          if (tag === 'DETAILS') continue;
          if (c.classList && (c.classList.contains('marginbox-footer') || c.classList.contains('wb-graph-workspace') || c.classList.contains('floating-toolbar'))) continue;
          if (matchesItemType(c, jitem)) {
            out.push(c);
          }
          if (tag === 'LI') {
            collectSublistsFromLi(c, jitem, walkChildrenCollecting);
          } else if (tag !== 'PRE' && tag !== 'TABLE') {
            walkChildrenCollecting(c);
          }
        }
      }

      if (containerInfo.kind === 'box') {
        var bodyDiv = getBoxBody(containerInfo.el) || containerInfo.el;
        walkChildrenCollecting(bodyDiv);
        return out;
      }

      if (containerInfo.kind === 'h') {
        var hEl = containerInfo.el;
        var hLvl = parseInt((hEl.tagName || 'H6').replace(/[^0-9]/g, ''), 10) || 6;
        var scopeParent = getEnclosingBox(hEl);
        var scopeRoot = scopeParent ? (getBoxBody(scopeParent) || scopeParent) : document.body;
        var started = false;
        var stopped = false;

        function walkAfterHeading(node) {
          if (stopped || !node || !node.children) return;
          for (var i = 0; i < node.children.length; i++) {
            if (stopped) return;
            var c = node.children[i];
            if (c === hEl) {
              started = true;
              continue;
            }
            var tag = (c.tagName || '').toUpperCase();
            if (tag === 'DETAILS') continue;
            if (c.classList && (c.classList.contains('marginbox-footer') || c.classList.contains('wb-graph-workspace') || c.classList.contains('floating-toolbar'))) continue;
            if (started) {
              if (/^H[1-6]$/.test(tag)) {
                var lvl = parseInt(tag.slice(1), 10) || 6;
                if (lvl <= hLvl) {
                  stopped = true;
                  return;
                }
              }
              if (matchesItemType(c, jitem)) {
                out.push(c);
              }
              if (tag === 'LI') {
                collectSublistsFromLi(c, jitem, walkAfterHeading);
              } else if (tag !== 'PRE' && tag !== 'TABLE') {
                walkAfterHeading(c);
              }
            } else {
              walkAfterHeading(c);
            }
          }
        }
        walkAfterHeading(scopeRoot);
        return out;
      }

      return out;
    }

    function resolveItemInsideContainer(containerInfo, wb) {
      if (!wb || !wb.jitem || !containerInfo || containerInfo.kind === 'top') return null;
      var candidates = collectScopeItems(containerInfo, wb.jitem);
      if (!candidates || !candidates.length) return null;

      var snipNorm = normAlnumWords(wb.jsnip);
      var snipWords = snipNorm ? snipNorm.split(' ').filter(function(w) { return w.length >= 3; }) : [];
      var wantedLidx = wb.jlidx || 0;

      var bestEl = null;
      var bestScore = -1;

      for (var i = 0; i < candidates.length; i++) {
        var cand = candidates[i];
        var candNorm = normAlnumWords(extractCleanProse(cand));
        var score = 0;

        if (snipNorm && candNorm) {
          if (candNorm === snipNorm) {
            score += 180;
          } else if (snipNorm.length >= 8 && (candNorm.indexOf(snipNorm) !== -1 || snipNorm.indexOf(candNorm) !== -1)) {
            score += 130;
          } else if (snipWords.length > 0) {
            var hits = 0;
            for (var w = 0; w < snipWords.length; w++) {
              if (candNorm.indexOf(snipWords[w]) !== -1) hits++;
            }
            score += Math.round((hits / snipWords.length) * 85);
          }
        }

        if (wantedLidx > 0) {
          var dist = Math.abs((i + 1) - wantedLidx);
          score += Math.max(0, 36 - dist * 6);
        }

        if (score > bestScore) {
          bestScore = score;
          bestEl = cand;
        }
      }

      if (bestEl && (bestScore >= 24 || (!snipNorm && wantedLidx > 0))) {
        return { kind: 'item', el: bestEl, flashEl: bestEl, isLeaf: true };
      }
      return null;
    }

    function resolveWhiteboardTarget(wb) {
      var containerTarget = resolveContainerTarget(wb);
      if (!containerTarget) return null;
      if (wb && wb.jitem) {
        var exactItem = resolveItemInsideContainer(containerTarget, wb);
        if (exactItem) return exactItem;
      }
      return containerTarget;
    }

    function flashElement(el) {
      if (!el || !el.classList) return;
      el.classList.remove('wb-jump-flash');
      void el.offsetWidth;
      el.classList.add('wb-jump-flash');
      setTimeout(function() {
        el.classList.remove('wb-jump-flash');
      }, 1900);
    }

    function jumpToNote(wb) {
      if (!isInlineBoxMode() && boxModalStack.length > 0) {
        closeBoxModal();
      }
      var target = resolveWhiteboardTarget(wb);
      if (!target) return false;

      if (target.kind === 'top') {
        if (graphMode === 'full') setGraphOpen(false);
        setTimeout(function() {
          window.scrollTo({ top: 0, behavior: 'smooth' });
        }, 30);
        return true;
      }

      var boxAncestors = [];
      var cur = target.el;
      while (cur) {
        if (cur.tagName === 'DETAILS' && cur.classList &&
            (cur.classList.contains('marginbox') || cur.classList.contains('tcolorbox') || cur.classList.contains('vbox'))) {
          boxAncestors.unshift(cur);
        }
        cur = cur.parentElement;
      }

      if (graphMode === 'full') {
        setGraphOpen(false);
      }

      var scrollTarget = target.flashEl || target.el;
      if (!isInlineBoxMode() && boxAncestors.length > 0 && boxModalBackdrop && boxModalBody) {
        var outerCard = boxAncestors[0];
        setTimeout(function() {
          if (outerCard && outerCard.getBoundingClientRect) {
            var bar = document.getElementById('floatingToolbar');
            var barH = bar ? (bar.offsetHeight || 0) : 0;
            var oy = Math.max(0, (window.scrollY || window.pageYOffset || 0) + outerCard.getBoundingClientRect().top - barH - 16);
            window.scrollTo({ top: oy, behavior: 'smooth' });
          }
          openBoxModalChain(boxAncestors);
          setTimeout(function() {
            if (target.kind === 'box' && scrollTarget && scrollTarget.tagName === 'SUMMARY') {
              boxModalBody.scrollTop = 0;
            } else if (scrollTarget && scrollTarget.getBoundingClientRect && boxModalBody.getBoundingClientRect) {
              var mRect = boxModalBody.getBoundingClientRect();
              var sRect = scrollTarget.getBoundingClientRect();
              var nextTop = Math.max(0, (boxModalBody.scrollTop || 0) + (sRect.top - mRect.top) - 24);
              if (boxModalBody.scrollTo) boxModalBody.scrollTo({ top: nextTop, behavior: 'smooth' });
              else boxModalBody.scrollTop = nextTop;
              flashElement(scrollTarget);
            }
          }, 35);
        }, 45);
        return true;
      }

      for (var i = 0; i < boxAncestors.length; i++) {
        boxAncestors[i].open = true;
      }
      syncAllLayerSizes();

      setTimeout(function() {
        syncAllLayerSizes();
        if (scrollTarget && scrollTarget.getBoundingClientRect) {
          var bar = document.getElementById('floatingToolbar');
          var barH = bar ? (bar.offsetHeight || 0) : 0;
          var extraPad = target.isLeaf ? Math.min(110, Math.max(24, Math.round(((window.innerHeight || 720) - barH) * 0.16))) : 16;
          var topY = Math.max(0, (window.scrollY || window.pageYOffset || 0) + scrollTarget.getBoundingClientRect().top - barH - extraPad);
          window.scrollTo({ top: topY, behavior: 'smooth' });
          flashElement(scrollTarget);
        }
      }, 45);
      return true;
    }

    function ensureMarkmapReady() {
      var payload = parsePayload();
      if (!payload || !payload.root) return false;
      if (!window.markmap || !window.markmap.Markmap) return false;
      ensureKatexStyles(payload);

      if (!mm) {
        activeTree = cloneWithDepth(payload.root, 0, currentDepth);
        var defaultColorFn = window.markmap.defaultColorFn;
        var opts = {
          maxWidth: 340,
          duration: 240,
          paddingX: 10,
          spacingHorizontal: 92,
          spacingVertical: 6,
          autoFit: false,
          style: function(id) {
            return '.' + id + ' { --markmap-circle-open-bg: #0f172a; --markmap-text-color: #f5eedc; --markmap-code-bg: rgba(245,238,220,0.14); --markmap-code-color: #fde68a; --markmap-a-color: #93c5fd; --markmap-a-hover-color: #bfdbfe; color: #f5eedc; }\n' +
              '.' + id + ' .markmap-foreign, .' + id + ' .markmap-foreign > div, .' + id + ' .wb-mm-node { color: #f5eedc !important; }';
          },
          color: function(node) {
            if (node && node.payload && node.payload.wb && node.payload.wb.color) {
              return node.payload.wb.color;
            }
            return defaultColorFn ? defaultColorFn(node) : '#60a5fa';
          }
        };
        mm = window.markmap.Markmap.create(svgEl, opts, activeTree);
        if (!renderHookInstalled && mm && mm.renderData) {
          var origRender = mm.renderData.bind(mm);
          mm.renderData = function(originData) {
            origRender(originData);
            decorateNodes();
            setTimeout(decorateNodes, 10);
          };
          renderHookInstalled = true;
        }
        setTimeout(function() {
          if (mm) mm.fit();
          decorateNodes();
        }, 40);
      }
      return true;
    }

    function setGraphMode(mode) {
      var isSmall = (window.innerWidth || 1200) < 900;
      graphMode = (!isSmall && mode === 'split') ? 'split' : 'full';
      document.body.classList.remove('wb-graph-full', 'wb-graph-split');
      document.body.classList.add(graphMode === 'split' ? 'wb-graph-split' : 'wb-graph-full');
      if (btnFull) btnFull.classList.toggle('is-active', graphMode === 'full');
      if (btnSplit) btnSplit.classList.toggle('is-active', graphMode === 'split');
      syncTopBarBodyOffset();
      syncAllLayerSizes();
      if (mm) {
        setTimeout(function() { mm.fit(); }, 50);
      }
    }

    function setGraphOpen(open) {
      if (open) {
        if (typeof window.__wbTocClose === 'function') window.__wbTocClose();
        syncTopBarBodyOffset();
        document.body.classList.add('wb-graph-open');
        setGraphMode(graphMode);
        btnToggleGraph.classList.add('is-active');
        if (parsePayload() && window.markmap && window.markmap.Markmap) {
          if (ensureMarkmapReady() && mm) {
            setTimeout(function() {
              mm.fit();
              decorateNodes();
            }, 50);
          }
        } else {
          if (selLabelEl) selLabelEl.textContent = 'Loading Tree View...';
          ensureAssetsReadyAsync(true).then(function(ok) {
            if (!document.body.classList.contains('wb-graph-open')) return;
            if (ok && ensureMarkmapReady() && mm) {
              if (selLabelEl) selLabelEl.textContent = 'Click any node or its ↗ button to jump to notes';
              setTimeout(function() {
                mm.fit();
                decorateNodes();
              }, 50);
            } else if (!ok && selLabelEl) {
              selLabelEl.textContent = 'Offline / CDN Error — turn on Wi-Fi, Ethernet, or Mobile Data and click Reload';
            }
          });
        }
      } else {
        document.body.classList.remove('wb-graph-open', 'wb-graph-full', 'wb-graph-split');
        btnToggleGraph.classList.remove('is-active');
        syncAllLayerSizes();
      }
    }

    window.__wbGraphClose = function() {
      setGraphOpen(false);
    };
    window.__wbGraphRefreshTheme = function() {
      if (mm && mm.updateStyle) {
        mm.updateStyle();
      }
    };

    function applyDepth(depthVal) {
      currentDepth = parseInt(depthVal || '0', 10) || 0;
      depthBtns.forEach(function(b) {
        var d = parseInt(b.getAttribute('data-depth') || '0', 10) || 0;
        b.classList.toggle('is-active', d === currentDepth);
      });
      var payload = parsePayload();
      if (!payload || !payload.root || !ensureMarkmapReady() || !mm) return;
      activeTree = cloneWithDepth(payload.root, 0, currentDepth);
      selectedNode = null;
      updateSelectionUi(null);
      mm.setData(activeTree);
      setTimeout(function() {
        mm.fit();
        if (searchInput && searchInput.value.trim()) {
          runSearch(searchInput.value);
        } else {
          decorateNodes();
        }
      }, 60);
    }

    function updateMatchCounterUi() {
      var total = searchMatches.length;
      var cur = (total > 0 && searchIndex >= 0) ? (searchIndex + 1) : 0;
      if (matchCountEl) matchCountEl.textContent = cur + ' / ' + total;
      if (btnMatchPrev) btnMatchPrev.disabled = (total === 0);
      if (btnMatchNext) btnMatchNext.disabled = (total === 0);
    }

    function focusSearchMatch(idx) {
      if (!searchMatches.length || !mm) {
        updateMatchCounterUi();
        decorateNodes();
        return;
      }
      searchIndex = ((idx % searchMatches.length) + searchMatches.length) % searchMatches.length;
      var node = searchMatches[searchIndex];
      updateMatchCounterUi();
      updateSelectionUi(node);
      setTimeout(function() {
        var found = mm.findElement ? mm.findElement(node) : null;
        if (found && found.data && svgEl && svgEl.getBoundingClientRect && window.d3 && window.d3.zoomIdentity && mm.zoom && mm.svg && mm.transition) {
          var rect = svgEl.getBoundingClientRect();
          var vw = rect.width || 800;
          var vh = rect.height || 500;
          var spH = (mm.options && mm.options.spacingHorizontal) || 92;
          var nodeW = Math.max(80, (found.data.ySize || 160) - spH);
          var nodeH = Math.max(24, found.data.xSize || 32);
          var cx = (found.data.y || 0) + nodeW / 2;
          var cy = found.data.x || 0;
          var targetK = Math.min(1.85, (vw * 0.72) / nodeW, (vh * 0.65) / nodeH);
          targetK = Math.max(1.15, Math.min(1.85, targetK));
          if (nodeW * targetK > vw * 0.88) {
            targetK = Math.max(0.75, (vw * 0.82) / nodeW);
          }
          var tx = (vw / 2) - cx * targetK;
          var ty = (vh / 2) - cy * targetK;
          var nextTransform = window.d3.zoomIdentity.translate(tx, ty).scale(targetK);
          mm.transition(mm.svg).call(mm.zoom.transform, nextTransform);
          return;
        }
        if (mm.ensureView) {
          mm.ensureView(node, { top: 48, bottom: 48, left: 64, right: 64 });
        }
      }, 60);
    }

    function runSearch(rawQuery) {
      var q = normText(rawQuery);
      searchMatches = [];
      searchIndex = -1;
      if (!q || !mm || !mm.state || !mm.state.data) {
        updateMatchCounterUi();
        decorateNodes();
        return;
      }
      var unfoldedAny = false;
      function walk(node, ancestors) {
        var text = normText(node.payload && node.payload.wb && node.payload.wb.text ? node.payload.wb.text : node.content);
        if (text.indexOf(q) !== -1) {
          searchMatches.push(node);
          for (var i = 0; i < ancestors.length; i++) {
            if (ancestors[i].payload && ancestors[i].payload.fold) {
              ancestors[i].payload.fold = 0;
              unfoldedAny = true;
            }
          }
        }
        var ch = node.children || [];
        if (ch.length) {
          var nextAnc = ancestors.concat([node]);
          for (var j = 0; j < ch.length; j++) walk(ch[j], nextAnc);
        }
      }
      walk(mm.state.data, []);
      if (unfoldedAny && mm.renderData) {
        mm.renderData();
      }
      if (searchMatches.length > 0) {
        focusSearchMatch(0);
      } else {
        updateMatchCounterUi();
        decorateNodes();
      }
    }

    function exportGraphSvg() {
      if (!mm || !svgEl) return;
      try {
        var bgCol = '#0f172a';
        var fgCol = '#f5eedc';

        var gNode = mm.g && mm.g.node ? mm.g.node() : svgEl.querySelector('g');
        var bbox = gNode && gNode.getBBox ? gNode.getBBox() : { x: -400, y: -300, width: 800, height: 600 };
        var pad = 40;
        var vx = Math.floor(bbox.x - pad);
        var vy = Math.floor(bbox.y - pad);
        var vw = Math.max(200, Math.ceil(bbox.width + pad * 2));
        var vh = Math.max(150, Math.ceil(bbox.height + pad * 2));

        var clone = svgEl.cloneNode(true);
        clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
        clone.setAttribute('xmlns:xhtml', 'http://www.w3.org/1999/xhtml');
        clone.setAttribute('viewBox', vx + ' ' + vy + ' ' + vw + ' ' + vh);
        clone.setAttribute('width', String(vw));
        clone.setAttribute('height', String(vh));

        // Reset zoom pan transform on root <g> so viewBox fits full mindmap cleanly
        var cloneG = clone.querySelector('g');
        if (cloneG) cloneG.removeAttribute('transform');

        clone.querySelectorAll('.wb-mm-jump').forEach(function(btn) { btn.remove(); });
        clone.querySelectorAll('.wb-mm-selected, .wb-mm-match, .wb-mm-current-match').forEach(function(el) {
          el.classList.remove('wb-mm-selected', 'wb-mm-match', 'wb-mm-current-match');
        });

        var bgRect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        bgRect.setAttribute('x', String(vx));
        bgRect.setAttribute('y', String(vy));
        bgRect.setAttribute('width', String(vw));
        bgRect.setAttribute('height', String(vh));
        bgRect.setAttribute('fill', bgCol);
        clone.insertBefore(bgRect, clone.firstChild);

        var extraStyle = document.createElementNS('http://www.w3.org/2000/svg', 'style');
        var katexStyleEl = document.getElementById('wbMarkmapKatex');
        extraStyle.textContent =
          (mm.getStyleContent ? mm.getStyleContent() : '') +
          '\nsvg.markmap, svg { --markmap-circle-open-bg: ' + bgCol + '; --markmap-text-color: ' + fgCol + '; color: ' + fgCol + '; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }\n' +
          '.markmap-foreign, .markmap-foreign > div, .wb-mm-node { color: ' + fgCol + ' !important; }\n' +
          (katexStyleEl ? katexStyleEl.textContent : '');
        clone.insertBefore(extraStyle, bgRect.nextSibling);

        var xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + new XMLSerializer().serializeToString(clone);
        var blob = new Blob([xml], { type: 'image/svg+xml;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        var baseName = (document.title || 'notes').replace(/[\\/:*?"<>|]+/g, '-').trim() || 'notes';
        var a = document.createElement('a');
        a.href = url;
        a.download = baseName + '-graph.svg';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function() { URL.revokeObjectURL(url); }, 10000);
      } catch (err) {
        alert('Failed to export SVG: ' + err);
      }
    }

    function openGraphNewTab() {
      try {
        var payload = parsePayload();
        if (!payload || !payload.root) return;
        var d3Src = (vendorBundleCache && vendorBundleCache.d3) || (document.getElementById('wbD3Vendor') || {}).textContent || '';
        var mmSrc = (vendorBundleCache && vendorBundleCache.mm) || (document.getElementById('wbMarkmapVendor') || {}).textContent || '';
        var cdnMode = dataNode.getAttribute('data-wb-assets') === 'cdn';
        var cdnBase = (dataNode.getAttribute('data-wb-cdn-base') || 'https://cdn.jsdelivr.net/gh/Thunderock7777/ai-ready-markdown-to-pdf@main').replace(/\/+$/, '');
        var payloadJson = JSON.stringify({ root: payload.root }).replace(/<\//g, '<\\/');
        var katexCss = (payload && payload.katexCss) ? payload.katexCss : '';
        var title = escapeHtmlStr((document.title || 'Notes') + ' - Tree View');

        var katexTag = katexCss ? katexCss : '';
        var headExtra = cdnMode && !katexCss
          ? ('<link rel="stylesheet" href="' + cdnBase + '/config/markmap/vendor/katex/katex.min.css" />')
          : '';
        var vendorScripts = (d3Src && mmSrc)
          ? ('<script>' + d3Src + '<' + '/script>\n<script>' + mmSrc + '<' + '/script>')
          : ('<script src="' + cdnBase + '/config/markmap/vendor/d3.min.js"><' + '/script>\n<script src="' + cdnBase + '/config/markmap/vendor/markmap-view.min.js"><' + '/script>');

        var htmlParts = [
          '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">',
          '<meta name="viewport" content="width=device-width,initial-scale=1">',
          '<title>' + title + '</title>',
          headExtra,
          '<style>',
          'html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}',
          'body{display:flex;flex-direction:column;background:#0f172a;color:#f5eedc;--markmap-circle-open-bg:#0f172a;--markmap-text-color:#f5eedc;}',
          '.bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;padding:8px 14px;border-bottom:1px solid rgba(148,163,184,0.25);background:#1e293b;color:#f5eedc;}',
          '.bar button{padding:4px 10px;border-radius:5px;border:1px solid rgba(245,238,220,0.3);background:#0f172a;color:#f5eedc;cursor:pointer;}',
          '#mm{flex:1 1 auto;width:100%;height:100%;display:block;}',
          '#mm.markmap .markmap-foreign,#mm.markmap .markmap-foreign>div,#mm.markmap .wb-mm-node{color:#f5eedc!important;}.wb-mm-jump{display:none;}',
          katexTag,
          '</style></head><body>',
          '<div class="bar"><strong>' + title + '</strong><button id="bFit">Fit</button><button id="bIn">+</button><button id="bOut">−</button></div>',
          '<svg id="mm"></svg>',
          '<script type="application/json" id="d">' + payloadJson + '<' + '/script>',
          vendorScripts,
          '<script>(function(){var p=JSON.parse(document.getElementById("d").textContent);function c(n,d,m){var o={content:n.content,children:[],payload:n.payload?JSON.parse(JSON.stringify(n.payload)):{}};var ch=n.children||[];o.payload.fold=(m>0&&d>=m&&ch.length>0)?1:0;for(var i=0;i<ch.length;i++)o.children.push(c(ch[i],d+1,m));return o;}var df=window.markmap.defaultColorFn;var m=window.markmap.Markmap.create(document.getElementById("mm"),{maxWidth:320,paddingX:10,spacingHorizontal:78,style:function(id){return "."+id+"{--markmap-circle-open-bg:#0f172a;--markmap-text-color:#f5eedc;color:#f5eedc;}."+id+" .markmap-foreign>div{color:#f5eedc!important;}";},color:function(n){return(n.payload&&n.payload.wb&&n.payload.wb.color)||df(n);}},c(p.root,0,1));document.getElementById("bFit").onclick=function(){m.fit();};document.getElementById("bIn").onclick=function(){m.rescale(1.25);};document.getElementById("bOut").onclick=function(){m.rescale(0.8);};})();<' + '/script>',
          '</body></html>'
        ];
        var blob = new Blob([htmlParts.join('\n')], { type: 'text/html;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        window.open(url, '_blank');
        setTimeout(function() { URL.revokeObjectURL(url); }, 60000);
      } catch (err) {
        alert('Unable to open Tree View in a new tab: ' + err);
      }
    }

    // Delegated click handler on #wbGraphSvg for selection and dedicated ↗ jump buttons
    svgEl.addEventListener('click', function(e) {
      var jumpBtn = e.target && e.target.closest ? e.target.closest('.wb-mm-jump') : null;
      if (jumpBtn) {
        e.preventDefault();
        e.stopPropagation();
        var jGroup = jumpBtn.closest('g.markmap-node');
        if (jGroup && window.d3) {
          var jd = window.d3.select(jGroup).datum();
          if (jd && jd.data) {
            updateSelectionUi(jd.data);
            if (jd.data.payload && jd.data.payload.wb) {
              jumpToNote(jd.data.payload.wb);
            }
          }
        }
        return;
      }

      if (e.target && e.target.closest && e.target.closest('a')) return;
      var nodeSpan = e.target && e.target.closest ? e.target.closest('.wb-mm-node') : null;
      var gEl = nodeSpan && nodeSpan.closest ? nodeSpan.closest('g.markmap-node') : null;
      if (gEl && window.d3) {
        var nd = window.d3.select(gEl).datum();
        if (nd && nd.data) {
          updateSelectionUi(nd.data);
        }
      }
    });

    btnToggleGraph.addEventListener('click', function() {
      setGraphOpen(!document.body.classList.contains('wb-graph-open'));
    });
    if (btnClose) btnClose.addEventListener('click', function() { setGraphOpen(false); });
    if (btnFull) btnFull.addEventListener('click', function() { setGraphMode('full'); });
    if (btnSplit) btnSplit.addEventListener('click', function() { setGraphMode('split'); });
    window.addEventListener('resize', function() {
      if ((window.innerWidth || 1200) < 900 && graphMode === 'split' && document.body.classList.contains('wb-graph-open')) {
        setGraphMode('full');
      }
    });

    // VS Code-style draggable vertical sash for Split View (default 60/40: 40vw Graph / 60vw Doc)
    (function initSplitResizer() {
      var splitter = document.getElementById('wbGraphSplitter');
      var SPLIT_KEY = 'wb-graph-split-pct';
      var defaultPct = 40;
      var savedPct = defaultPct;
      try {
        var raw = parseFloat(localStorage.getItem(SPLIT_KEY));
        if (!isNaN(raw) && raw >= 20 && raw <= 80) savedPct = raw;
      } catch (e) {}

      function applySplitWidth(pct, persist) {
        var clamped = Math.max(20, Math.min(80, pct));
        if (document.documentElement && document.documentElement.style && document.documentElement.style.setProperty) {
          document.documentElement.style.setProperty('--wb-split-w', clamped.toFixed(1) + 'vw');
        }
        if (persist) {
          try { localStorage.setItem(SPLIT_KEY, String(Math.round(clamped * 10) / 10)); } catch (e) {}
        }
      }
      applySplitWidth(savedPct, false);

      if (!splitter) return;
      splitter.addEventListener('dblclick', function(e) {
        e.preventDefault();
        applySplitWidth(defaultPct, true);
        syncTopBarBodyOffset();
        syncAllLayerSizes();
        if (mm) setTimeout(function() { mm.fit(); }, 30);
      });

      splitter.addEventListener('pointerdown', function(e) {
        if (!document.body.classList.contains('wb-graph-split')) return;
        e.preventDefault();
        splitter.classList.add('is-dragging');
        document.body.classList.add('wb-is-resizing');
        var lastPct = savedPct;
        function onMove(ev) {
          var vw = window.innerWidth || 1280;
          if (vw <= 0) return;
          lastPct = Math.max(20, Math.min(80, (ev.clientX / vw) * 100));
          applySplitWidth(lastPct, false);
        }
        function onUp() {
          window.removeEventListener('pointermove', onMove);
          window.removeEventListener('pointerup', onUp);
          window.removeEventListener('pointercancel', onUp);
          splitter.classList.remove('is-dragging');
          document.body.classList.remove('wb-is-resizing');
          savedPct = lastPct;
          applySplitWidth(lastPct, true);
          syncTopBarBodyOffset();
          syncAllLayerSizes();
          if (mm) setTimeout(function() { mm.fit(); }, 30);
        }
        window.addEventListener('pointermove', onMove);
        window.addEventListener('pointerup', onUp);
        window.addEventListener('pointercancel', onUp);
      });
    })();
    if (btnFit) btnFit.addEventListener('click', function() { if (mm) mm.fit(); });
    if (btnZoomIn) btnZoomIn.addEventListener('click', function() { if (mm) mm.rescale(1.25); });
    if (btnZoomOut) btnZoomOut.addEventListener('click', function() { if (mm) mm.rescale(0.8); });
    if (btnExportSvg) btnExportSvg.addEventListener('click', exportGraphSvg);
    if (btnNewTab) btnNewTab.addEventListener('click', openGraphNewTab);
    if (btnJumpSelected) {
      btnJumpSelected.addEventListener('click', function() {
        if (selectedNode && selectedNode.payload && selectedNode.payload.wb) {
          jumpToNote(selectedNode.payload.wb);
        }
      });
    }

    depthBtns.forEach(function(b) {
      b.addEventListener('click', function() {
        applyDepth(b.getAttribute('data-depth'));
      });
    });

    if (searchInput) {
      searchInput.addEventListener('input', function() {
        runSearch(searchInput.value);
      });
      searchInput.addEventListener('keydown', function(e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          if (searchMatches.length > 0) {
            focusSearchMatch(e.shiftKey ? (searchIndex - 1) : (searchIndex + 1));
          } else {
            runSearch(searchInput.value);
          }
        } else if (e.key === 'Escape') {
          e.stopPropagation();
          if (searchInput.value) {
            searchInput.value = '';
            runSearch('');
          } else {
            setGraphOpen(false);
          }
        }
      });
    }
    if (btnSearchClear) {
      btnSearchClear.addEventListener('click', function() {
        if (searchInput) searchInput.value = '';
        runSearch('');
      });
    }
    if (btnMatchPrev) {
      btnMatchPrev.addEventListener('click', function() {
        focusSearchMatch(searchIndex - 1);
      });
    }
    if (btnMatchNext) {
      btnMatchNext.addEventListener('click', function() {
        focusSearchMatch(searchIndex + 1);
      });
    }

    // 7. PDF-Style Table of Contents Sidebar Drawer (built from structural tree)
    (function initTocSidebar() {
      var btnToggleToc = document.getElementById('btnToggleToc');
      var tocDrawer = document.getElementById('wbTocDrawer');
      var tocListEl = document.getElementById('wbTocList');
      if (!btnToggleToc || !tocDrawer || !tocListEl) return;

      var btnTocClose = document.getElementById('btnTocClose');
      var btnTocExpand = document.getElementById('btnTocExpandAll');
      var btnTocCollapse = document.getElementById('btnTocCollapseAll');
      var tocFilterInput = document.getElementById('wbTocFilter');
      var btnTocFilterClear = document.getElementById('btnTocFilterClear');

      var tocTree = null;
      var tocBuilt = false;
      var activeRowEl = null;

      function extractTocNodes(mmNode) {
        if (!mmNode) return [];
        var wb = mmNode.payload && mmNode.payload.wb;
        var children = [];
        var rawChildren = Array.isArray(mmNode.children) ? mmNode.children : [];
        for (var i = 0; i < rawChildren.length; i++) {
          children = children.concat(extractTocNodes(rawChildren[i]));
        }
        if (wb && wb.jtype === 'top') {
          return children;
        }
        if (wb && !wb.jitem && (wb.jtype === 'h' || wb.jtype === 'box')) {
          var cleanHtml = String(mmNode.content || '').replace(/<button[^>]*class="wb-mm-jump"[^>]*>[\s\S]*?<\/button>/gi, '');
          return [{
            wb: wb,
            html: cleanHtml || escapeHtmlStr(wb.jtitle || wb.text || 'Untitled'),
            text: wb.jtitle || wb.text || '',
            children: children
          }];
        }
        return [];
      }

      function buildTocDom(nodes, depth, expandAllFlag, queryLower) {
        var frag = document.createDocumentFragment ? document.createDocumentFragment() : document.createElement('div');
        var anyVisible = false;

        for (var i = 0; i < nodes.length; i++) {
          var item = nodes[i];
          var childResult = item.children.length ? buildTocDom(item.children, depth + 1, expandAllFlag, queryLower) : { frag: null, matched: false };
          var selfMatches = !queryLower || (normText(item.text).indexOf(queryLower) !== -1);
          if (queryLower && !selfMatches && !childResult.matched) {
            continue;
          }
          anyVisible = true;

          var wrap = document.createElement('div');
          wrap.className = 'wb-toc-node';

          var row = document.createElement('div');
          row.className = 'wb-toc-row ' + (item.wb.jtype === 'h' ? 'is-heading' : 'is-box');
          row.style.paddingLeft = (6 + depth * 14) + 'px';
          row.setAttribute('role', 'treeitem');

          var hasKids = !!(childResult.frag && item.children.length > 0 && (!queryLower || childResult.matched));
          var expanded = queryLower ? !!childResult.matched : !!expandAllFlag;

          var caret = document.createElement('button');
          caret.type = 'button';
          caret.className = 'wb-toc-caret' + (hasKids ? '' : ' is-spacer');
          caret.textContent = hasKids ? (expanded ? '▾' : '▸') : '•';
          caret.title = hasKids ? 'Expand / Collapse' : '';
          row.appendChild(caret);

          if (item.wb.jtype === 'box') {
            var dot = document.createElement('span');
            dot.className = 'wb-toc-dot';
            if (item.wb.color) dot.style.background = item.wb.color;
            row.appendChild(dot);
          }

          var label = document.createElement('span');
          label.className = 'wb-toc-label';
          label.innerHTML = item.html;
          row.appendChild(label);
          wrap.appendChild(row);

          var kidsBox = null;
          if (hasKids && childResult.frag) {
            kidsBox = document.createElement('div');
            kidsBox.className = 'wb-toc-children' + (expanded ? '' : ' is-collapsed');
            kidsBox.appendChild(childResult.frag);
            wrap.appendChild(kidsBox);

            (function(kb, cbBtn) {
              cbBtn.addEventListener('click', function(ev) {
                ev.stopPropagation();
                var nowCollapsed = kb.classList.toggle('is-collapsed');
                cbBtn.textContent = nowCollapsed ? '▸' : '▾';
              });
            })(kidsBox, caret);
          }

          (function(rEl, wbTarget) {
            rEl.addEventListener('click', function() {
              if (activeRowEl && activeRowEl.classList) activeRowEl.classList.remove('is-active');
              activeRowEl = rEl;
              rEl.classList.add('is-active');
              jumpToNote(wbTarget);
              if ((window.innerWidth || 1200) < 900) {
                setTocOpen(false);
              }
            });
          })(row, item.wb);

          frag.appendChild(wrap);
        }

        return { frag: frag, matched: anyVisible };
      }

      function renderToc(expandAllFlag) {
        var payload = parsePayload();
        if (!payload || !payload.root) return;
        ensureKatexStyles(payload);
        if (!tocTree) tocTree = extractTocNodes(payload.root);
        var q = tocFilterInput ? normText(tocFilterInput.value) : '';
        tocListEl.innerHTML = '';
        activeRowEl = null;
        var built = buildTocDom(tocTree, 0, !!expandAllFlag, q);
        if (built && built.frag) {
          tocListEl.appendChild(built.frag);
        }
        tocBuilt = true;
      }

      function setTocOpen(open) {
        if (open) {
          if (document.body.classList.contains('wb-graph-open')) {
            setGraphOpen(false);
          }
          syncTopBarBodyOffset();
          document.body.classList.add('wb-toc-open');
          btnToggleToc.classList.add('is-active');
          if (!tocBuilt) {
            if (parsePayload()) {
              renderToc(false);
              syncAllLayerSizes();
            } else {
              ensureAssetsReadyAsync(false).then(function() {
                if (!document.body.classList.contains('wb-toc-open')) return;
                renderToc(false);
                syncAllLayerSizes();
              });
            }
          } else {
            syncAllLayerSizes();
          }
        } else {
          document.body.classList.remove('wb-toc-open');
          btnToggleToc.classList.remove('is-active');
          syncAllLayerSizes();
        }
      }

      window.__wbTocClose = function() {
        setTocOpen(false);
      };

      btnToggleToc.addEventListener('click', function() {
        setTocOpen(!document.body.classList.contains('wb-toc-open'));
      });
      if (btnTocClose) btnTocClose.addEventListener('click', function() { setTocOpen(false); });
      if (btnTocExpand) btnTocExpand.addEventListener('click', function() { renderToc(true); });
      if (btnTocCollapse) btnTocCollapse.addEventListener('click', function() { renderToc(false); });
      if (tocFilterInput) {
        tocFilterInput.addEventListener('input', function() {
          renderToc(false);
        });
        tocFilterInput.addEventListener('keydown', function(e) {
          if (e.key === 'Escape') {
            e.stopPropagation();
            if (tocFilterInput.value) {
              tocFilterInput.value = '';
              renderToc(false);
            } else {
              setTocOpen(false);
            }
          }
        });
      }
      if (btnTocFilterClear) {
        btnTocFilterClear.addEventListener('click', function() {
          if (tocFilterInput) tocFilterInput.value = '';
          renderToc(false);
        });
      }
    })();
  })();
})();
