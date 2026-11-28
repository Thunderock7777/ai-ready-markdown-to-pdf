'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');

const CDN_BASE_URL = 'https://cdn.jsdelivr.net/gh/Thunderock7777/ai-ready-markdown-to-pdf@main';
const DEFAULT_REPO_CONFIG_URL = 'https://raw.githubusercontent.com/Thunderock7777/ai-ready-markdown-to-pdf/main/config';
const MATHJAX_URL = 'https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg-full.js';
const SUPPORTED_EXTENSIONS = new Set(['.md', '.markdown', '.txt']);
const CORE_CONFIG_FILES = [
  'markdown-normalizer.lua',
  'code-fence-runner.lua',
  'custom.tex',
  'html-collapsible-boxes.lua',
  'latex.css',
  'wb-viewer.js',
];
const OPTIONAL_CONFIG_FILES = [
  'tex-to-html-preprocessor.lua',
  'graph-markdown-extractor.lua',
  'markmap/build-graph.js',
  'markmap/vendor/d3.min.js',
  'markmap/vendor/markmap-view.min.js',
  'markmap/vendor/katex/katex.min.css',
];

/**
 * Checks whether a document declares `page-layout: whiteboard_html`
 * inside a fenced ```yaml block.
 * @param {string} text
 * @returns {boolean}
 */
function hasWhiteboardHtmlLayout(text) {
  if (typeof text !== 'string' || !text) return false;
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let fenceLen = 0;
  let inYaml = false;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!inYaml) {
      const openMatch = line.match(/^\s*(`{3,})\s*yaml(?:\s|$)/i);
      if (openMatch) {
        fenceLen = openMatch[1].length;
        inYaml = true;
      }
    } else {
      const closeMatch = line.match(/^\s*(`{3,})\s*$/);
      if (closeMatch && closeMatch[1].length >= fenceLen) {
        inYaml = false;
        fenceLen = 0;
        continue;
      }
      if (/^\s*page-layout\s*:\s*["']?whiteboard_html["']?\s*(?:#.*)?$/i.test(line)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Downloads `setup.bat` from the public repo (if not already present beside `configDir`)
 * and launches it in an interactive VS Code Terminal.
 * @param {vscode.ExtensionContext} context
 * @param {string | null} [configDir]
 * @returns {Promise<void>}
 */
async function downloadAndRunSetup(context, configDir) {
  const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
  const repoConfigUrl = (cfg.get('repoBaseUrl') || DEFAULT_REPO_CONFIG_URL).trim().replace(/\/+$/, '');
  const repoBaseUrl = repoConfigUrl.replace(/\/config$/i, '');

  const localRoot = configDir ? path.dirname(configDir) : '';
  const storageRoot = context && context.globalStorageUri && context.globalStorageUri.fsPath;
  const targetRoot = (localRoot && fs.existsSync(path.join(localRoot, 'setup.bat')))
    ? localRoot
    : (storageRoot || localRoot || os.tmpdir());
  const setupBatPath = path.join(targetRoot, 'setup.bat');

  if (!fs.existsSync(setupBatPath)) {
    fs.mkdirSync(targetRoot, { recursive: true });
    await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: 'Whiteboard HTML: Downloading setup.bat from GitHub…',
        cancellable: false,
      },
      async () => {
        const content = await fetchText(`${repoBaseUrl}/setup.bat`);
        fs.writeFileSync(setupBatPath, content, 'utf8');
      }
    );
  }

  const term = vscode.window.createTerminal({
    name: 'Whiteboard HTML Setup',
    cwd: targetRoot,
  });
  term.show(true);
  if (process.platform === 'win32') {
    term.sendText(`cmd /c "${setupBatPath}"`, true);
  } else {
    term.sendText(`"${setupBatPath}"`, true);
  }
}

/**
 * Checks whether a directory contains the core Lua filter set.
 * @param {string} dirPath
 * @returns {boolean}
 */
function isValidConfigDir(dirPath) {
  if (!dirPath) return false;
  return (
    fs.existsSync(path.join(dirPath, 'markdown-normalizer.lua')) &&
    fs.existsSync(path.join(dirPath, 'html-collapsible-boxes.lua'))
  );
}

/**
 * Fetches a URL as UTF-8 text via Node `https`, following up to 5 redirects.
 * @param {string} url
 * @param {number} [redirectsLeft]
 * @returns {Promise<string>}
 */
function fetchText(url, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: { 'User-Agent': 'whiteboard-html-preview' } }, (res) => {
      const code = res.statusCode || 0;
      if (code >= 300 && code < 400 && res.headers.location && redirectsLeft > 0) {
        res.resume();
        const nextUrl = new URL(res.headers.location, url).toString();
        fetchText(nextUrl, redirectsLeft - 1).then(resolve, reject);
        return;
      }
      if (code !== 200) {
        res.resume();
        reject(new Error(`HTTP ${code} for ${url}`));
        return;
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    });
    req.setTimeout(15000, () => {
      req.destroy(new Error(`Timeout fetching ${url}`));
    });
    req.on('error', reject);
  });
}

/**
 * Downloads `config/` files from the configured public GitHub repo into `targetDir`.
 * @param {string} targetDir
 * @param {string} baseUrl
 * @returns {Promise<string>}
 */
async function downloadConfigFromRepo(targetDir, baseUrl) {
  const cleanBase = String(baseUrl || DEFAULT_REPO_CONFIG_URL).replace(/\/+$/, '');
  fs.mkdirSync(targetDir, { recursive: true });

  for (const rel of CORE_CONFIG_FILES) {
    const content = await fetchText(`${cleanBase}/${rel}`);
    const dest = path.join(targetDir, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, content, 'utf8');
  }

  for (const rel of OPTIONAL_CONFIG_FILES) {
    try {
      const content = await fetchText(`${cleanBase}/${rel}`);
      const dest = path.join(targetDir, rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, content, 'utf8');
    } catch (_) {}
  }

  return targetDir;
}

/**
 * Resolves the `config/` directory from setting, workspace, ancestor dirs,
 * extension bundle, globalStorage cache, or public GitHub repo download.
 * @param {vscode.Uri} docUri
 * @param {vscode.ExtensionContext} context
 * @returns {Promise<string | null>}
 */
async function resolveConfigDir(docUri, context) {
  const extensionPath = context && context.extensionPath ? context.extensionPath : '';
  const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
  const configured = (cfg.get('configPath') || '').trim();
  if (configured && isValidConfigDir(configured)) {
    return path.resolve(configured);
  }

  const folders = vscode.workspace.workspaceFolders || [];
  for (const folder of folders) {
    const candidate = path.join(folder.uri.fsPath, 'config');
    if (isValidConfigDir(candidate)) return candidate;
  }

  if (docUri && docUri.fsPath) {
    let cur = path.dirname(docUri.fsPath);
    for (let depth = 0; depth < 12; depth += 1) {
      const candidate = path.join(cur, 'config');
      if (isValidConfigDir(candidate)) return candidate;
      const parent = path.dirname(cur);
      if (!parent || parent === cur) break;
      cur = parent;
    }
  }

  if (extensionPath) {
    const bundled = path.join(extensionPath, 'config');
    if (isValidConfigDir(bundled)) return bundled;
    const sibling = path.join(path.dirname(extensionPath), 'config');
    if (isValidConfigDir(sibling)) return sibling;
  }

  const storageRoot = context && context.globalStorageUri && context.globalStorageUri.fsPath;
  if (storageRoot) {
    const cachedConfig = path.join(storageRoot, 'config');
    if (isValidConfigDir(cachedConfig)) return cachedConfig;

    const repoBaseUrl = (cfg.get('repoBaseUrl') || DEFAULT_REPO_CONFIG_URL).trim();
    if (repoBaseUrl) {
      try {
        await vscode.window.withProgress(
          {
            location: vscode.ProgressLocation.Notification,
            title: 'Whiteboard HTML: Downloading Lua filters from GitHub…',
            cancellable: false,
          },
          () => downloadConfigFromRepo(cachedConfig, repoBaseUrl)
        );
        if (isValidConfigDir(cachedConfig)) return cachedConfig;
      } catch (err) {
        vscode.window.showErrorMessage(
          `Failed to download filters from ${repoBaseUrl}: ${err && err.message ? err.message : String(err)}`
        );
      }
    }
  }

  return null;
}

/**
 * Resolves a CLI tool executable, falling back to common Windows install paths
 * when the default command name is not on PATH.
 * @param {string} configured
 * @param {string[]} fallbacks
 * @returns {string}
 */
function resolveToolPath(configured, fallbacks) {
  const cmd = (configured || '').trim();
  if (!cmd) return fallbacks[0] || '';
  if (path.isAbsolute(cmd) && fs.existsSync(cmd)) return cmd;
  const pathDirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const dir of pathDirs) {
    for (const ext of exts) {
      const candidate = path.join(dir, cmd.endsWith(ext) ? cmd : cmd + ext);
      try {
        if (fs.existsSync(candidate)) return candidate;
      } catch (_) {}
    }
  }
  for (const fb of fallbacks) {
    try {
      if (fb && fs.existsSync(fb)) return fb;
    } catch (_) {}
  }
  return cmd;
}

/**
 * Runs a child process and resolves with stdout/stderr or rejects with an Error.
 * @param {string} cmd
 * @param {string[]} args
 * @param {{ cwd?: string, env?: NodeJS.ProcessEnv, timeoutMs?: number }} [opts]
 * @returns {Promise<{ stdout: string, stderr: string }>}
 */
function execFileAsync(cmd, args, opts) {
  const options = Object.assign({ windowsHide: true, maxBuffer: 32 * 1024 * 1024 }, opts || {});
  return new Promise((resolve, reject) => {
    cp.execFile(cmd, args, options, (err, stdout, stderr) => {
      if (err) {
        const detail = (stderr || stdout || err.message || '').trim();
        const wrapped = new Error(`${path.basename(cmd)} failed: ${detail}`);
        wrapped.cause = err;
        reject(wrapped);
        return;
      }
      resolve({ stdout: String(stdout || ''), stderr: String(stderr || '') });
    });
  });
}

/**
 * Builds standalone Whiteboard HTML using the repo's Pandoc + Lua + Markmap pipeline.
 * @param {{
 *   inputPath: string,
 *   configDir: string,
 *   pandocPath?: string,
 *   texluaPath?: string,
 *   nodePath?: string
 * }} params
 * @returns {Promise<{ html: string, workDir: string }>}
 */
async function buildWhiteboardHtml(params) {
  const inputPath = params.inputPath;
  const configDir = params.configDir;
  const localAppData = process.env.LOCALAPPDATA || '';
  const pandocPath = resolveToolPath(params.pandocPath || 'pandoc', [
    path.join(localAppData, 'Pandoc', 'pandoc.exe'),
    path.join(localAppData, 'Programs', 'Quarto', 'bin', 'tools', 'pandoc.exe'),
    'C:\\Program Files\\Pandoc\\pandoc.exe',
  ]);
  const texluaPath = resolveToolPath(params.texluaPath || 'texlua', []);
  const nodePath = resolveToolPath(params.nodePath || 'node', []);

  const docDir = path.dirname(inputPath);
  const baseName = path.basename(inputPath, path.extname(inputPath));
  const repoRoot = path.dirname(configDir);
  const cacheDir = path.join(repoRoot, 'md2pdf_cache');
  const hash = crypto.createHash('sha1').update(inputPath).digest('hex').slice(0, 10);
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), `wb-preview-${hash}-`));

  const normalizerFilter = path.join(configDir, 'markdown-normalizer.lua');
  const codeFenceFilter = path.join(configDir, 'code-fence-runner.lua');
  const templatePath = path.join(configDir, 'custom.tex');
  const htmlPreprocessor = path.join(configDir, 'tex-to-html-preprocessor.lua');
  const graphMdFilter = path.join(configDir, 'graph-markdown-extractor.lua');
  const htmlBoxFilter = path.join(configDir, 'html-collapsible-boxes.lua');
  const markmapDir = path.join(configDir, 'markmap');
  const markmapBuildJs = path.join(markmapDir, 'build-graph.js');
  const markmapViewEntry = path.join(markmapDir, 'node_modules', 'markmap-view', 'dist', 'browser', 'index.js');

  const texOutput = path.join(workDir, `${baseName}.tex`);
  const htmlTex = path.join(workDir, `${baseName}_html.tex`);
  const graphMd = path.join(workDir, `${baseName}_graph.md`);
  const graphPayload = path.join(workDir, `${baseName}_graph.json`);
  const sourceMapPath = path.join(workDir, `${baseName}_source_map.json`);
  const htmlOutput = path.join(workDir, `${baseName}.html`);

  const env = Object.assign({}, process.env, {
    MD2PDF_WORKING_DIR: docDir,
    MD2PDF_CACHE_ROOT: cacheDir,
    MD2PDF_CONFIG_DIR: configDir,
    MD2PDF_GRAPH_JSON: '',
    MD2PDF_GRAPH_VENDOR: '',
    MD2PDF_MARKMAP_DIR: '',
    MD2PDF_SOURCE_MAP_JSON: sourceMapPath,
  });
// Auto-trust all executable fences in preview (skip interactive stdin prompts).
  env.MD2PDF_CONFIRM_EXEC = '0';
  delete env.MD2PDF_CONFIRM_PYTHON;
  delete env.MD2PDF_CONFIRM_C;
  delete env.MD2PDF_CONFIRM_CPP;
  delete env.MD2PDF_CONFIRM_JAVA;
  try {
    await execFileAsync(
      pandocPath,
      [
        inputPath,
        '-f',
        'markdown-yaml_metadata_block-simple_tables-raw_tex',
        '--lua-filter',
        normalizerFilter,
        '--lua-filter',
        codeFenceFilter,
        '--wrap=none',
        '--template',
        templatePath,
        '-o',
        texOutput,
      ],
      { cwd: docDir, env }
    );

    const texContent = fs.readFileSync(texOutput, 'utf8');
    if (!texContent.includes('WHITEBOARD_HTML_LAYOUT')) {
      throw new Error('Document did not resolve to WHITEBOARD_HTML_LAYOUT.');
    }

    let preprocessed = false;
    if (fs.existsSync(htmlPreprocessor)) {
      try {
        await execFileAsync(texluaPath, [htmlPreprocessor, texOutput, htmlTex, cacheDir], { cwd: docDir, env });
        preprocessed = fs.existsSync(htmlTex);
      } catch (_) {
        preprocessed = false;
      }
    }
    if (!preprocessed) {
      fs.copyFileSync(texOutput, htmlTex);
    }

    if (fs.existsSync(graphMdFilter) && fs.existsSync(markmapBuildJs) && fs.existsSync(markmapViewEntry)) {
      try {
        await execFileAsync(
          pandocPath,
          [
            inputPath,
            '-f',
            'markdown-yaml_metadata_block-simple_tables-raw_tex',
            '--lua-filter',
            normalizerFilter,
            '--lua-filter',
            graphMdFilter,
            '-t',
            'html',
            '-o',
            graphMd,
          ],
          { cwd: docDir, env }
        );
        if (fs.existsSync(graphMd)) {
          await execFileAsync(nodePath, [markmapBuildJs, graphMd, graphPayload], { cwd: docDir, env });
          if (fs.existsSync(graphPayload)) {
            env.MD2PDF_GRAPH_JSON = graphPayload;
            env.MD2PDF_MARKMAP_DIR = markmapDir;
          }
        }
      } catch (_) {
        // Tree View is optional if node/markmap fails; main preview still renders.
      }
    }

    await execFileAsync(
      pandocPath,
      [
        htmlTex,
        '-f',
        'latex',
        '-t',
        'html5',
        `--mathjax=${MATHJAX_URL}`,
        '--standalone',
        '--lua-filter',
        htmlBoxFilter,
        '-o',
        htmlOutput,
      ],
      { cwd: docDir, env }
    );

    let sourceMap = { anchors: [], boxes: [] };
    if (fs.existsSync(sourceMapPath)) {
      try {
        sourceMap = JSON.parse(fs.readFileSync(sourceMapPath, 'utf8'));
      } catch (_) {}
    }

    return {
      html: fs.readFileSync(htmlOutput, 'utf8'),
      sourceMap,
      workDir,
    };
  } finally {
    try {
      fs.rmSync(workDir, { recursive: true, force: true });
    } catch (_) {}
  }
}

/**
 * Rewrites generated HTML so CSS, viewer JS, Markmap vendor files, and local images
 * load via `webview.asWebviewUri(...)` with a compatible CSP header, and injects
 * the VS Code refresh + bidirectional scroll-sync script.
 * @param {string} html
 * @param {{
 *   webview: vscode.Webview,
 *   configDir: string,
 *   docDir: string,
 *   scrollSync?: boolean,
 *   initialTopLine?: number,
 *   totalLines?: number,
 *   sourceHeadings?: Array<{ line: number, text: string }>
 * }} opts
 * @returns {string}
 */
function transformHtmlForWebview(html, opts) {
  const webview = opts.webview;
  const configDir = opts.configDir;
  const docDir = opts.docDir;
  const repoRoot = path.dirname(configDir);

  const configUri = webview.asWebviewUri(vscode.Uri.file(configDir)).toString().replace(/\/+$/, '');
  const repoRootUri = webview.asWebviewUri(vscode.Uri.file(repoRoot)).toString().replace(/\/+$/, '');
  const cspSource = webview.cspSource || '';

  let out = html;

  // Point CDN links and data-wb-cdn-base at local workspace assets.
  out = out.split(`${CDN_BASE_URL}/config`).join(configUri);
  out = out.split(CDN_BASE_URL).join(repoRootUri);

  // Ensure latex.css is linked when Pandoc ran without --embed-resources or CDN mode.
  if (!out.includes('latex.css')) {
    const cssTag = `<link id="wbVsCodeCssLink" rel="stylesheet" href="${configUri}/latex.css">\n`;
    out = out.replace(/<\/head>/i, `${cssTag}</head>`);
  }

  // Ensure #wbGraphData uses local vendor assets via data-wb-cdn-base.
  out = out.replace(
    /(<script[^>]*id=["']wbGraphData["'][^>]*)(>)/i,
    (match, prefix, close) => {
      let updated = prefix;
      if (!/data-wb-assets=/i.test(updated)) {
        updated += ' data-wb-assets="cdn"';
      } else {
        updated = updated.replace(/data-wb-assets=["'][^"']*["']/i, 'data-wb-assets="cdn"');
      }
      if (!/data-wb-cdn-base=/i.test(updated)) {
        updated += ` data-wb-cdn-base="${repoRootUri}"`;
      } else {
        updated = updated.replace(/data-wb-cdn-base=["'][^"']*["']/i, `data-wb-cdn-base="${repoRootUri}"`);
      }
      return updated + close;
    }
  );

  // Rewrite relative <img src="..."> paths to webview URIs.
  out = out.replace(/(<img\b[^>]*\bsrc=["'])([^"']+)(["'])/gi, (match, prefix, srcVal, suffix) => {
    if (/^(https?:|data:|blob:|vscode-resource:|vscode-webview-resource:|#)/i.test(srcVal)) {
      return match;
    }
    const cleanRel = srcVal.split(/[?#]/)[0];
    const absImg = path.isAbsolute(cleanRel) ? cleanRel : path.resolve(docDir, cleanRel);
    if (!fs.existsSync(absImg)) return match;
    return `${prefix}${webview.asWebviewUri(vscode.Uri.file(absImg)).toString()}${suffix}`;
  });

  // Inject CSP meta tag at the start of <head> for MathJax + local scripts + KaTeX fonts.
  const cspPolicy = [
    `default-src 'none'`,
    `style-src ${cspSource} 'unsafe-inline' https://cdn.jsdelivr.net`,
    `script-src ${cspSource} 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net`,
    `font-src ${cspSource} data: https://cdn.jsdelivr.net`,
    `img-src ${cspSource} data: blob: https:`,
    `connect-src ${cspSource} https://cdn.jsdelivr.net`,
  ].join('; ');
  const cspMeta = `<meta http-equiv="Content-Security-Policy" content="${cspPolicy}">\n`;
  const previewCss = `<style id="wbVsCodePreviewCss">
:root { --wb-toolbar-h: 0px !important; }
html { scroll-behavior: auto !important; }
body { padding-top: 12px !important; }
#floatingToolbar, #wbSaveAsModal { display: none !important; }
</style>\n`;
  out = out.replace(/<head([^>]*)>/i, `<head$1>\n${cspMeta}`);
  out = out.replace(/<\/head>/i, `${previewCss}</head>`);

  const sourceData = opts.sourceAnchors || { anchors: [], boxes: [], codeSpans: [] };
  const bridgePayload = JSON.stringify({
    scrollSync: opts.scrollSync !== false,
    initialTopLine: typeof opts.initialTopLine === 'number' ? opts.initialTopLine : 0,
    totalLines: typeof opts.totalLines === 'number' ? opts.totalLines : 1,
    anchors: Array.isArray(sourceData.anchors) ? sourceData.anchors : [],
    boxes: Array.isArray(sourceData.boxes) ? sourceData.boxes : [],
    codeSpans: Array.isArray(sourceData.codeSpans) ? sourceData.codeSpans : [],
  }).replace(/</g, '\\u003c');

  const syncScript = `<script id="wbVsCodeSync">
(function() {
  var meta = ${bridgePayload};
  var api = window.__wbVsCodeApi || null;
  if (!api && typeof acquireVsCodeApi === 'function') {
    try { api = window.__wbVsCodeApi = acquireVsCodeApi(); } catch (e) {}
  }

  function syncVsCodeTheme() {
    if (!document.body || !document.documentElement) return;
    var isDark = document.body.classList.contains('vscode-dark') || document.body.classList.contains('vscode-high-contrast');
    var want = isDark ? 'latex-dark' : 'latex-light';
    var drop = isDark ? 'latex-light' : 'latex-dark';
    if (document.documentElement.classList.contains(drop)) document.documentElement.classList.remove(drop);
    if (!document.documentElement.classList.contains(want)) document.documentElement.classList.add(want);
    if (document.body.classList.contains(drop)) document.body.classList.remove(drop);
    if (!document.body.classList.contains(want)) document.body.classList.add(want);
  }

  function tagBoxIndices() {
    var dets = document.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox');
    for (var i = 0; i < dets.length; i += 1) {
      if (!dets[i].hasAttribute('data-wb-box-idx')) {
        dets[i].setAttribute('data-wb-box-idx', String(i));
      }
    }
  }

  function getActiveModalBox() {
    var backdrop = document.getElementById('wbBoxModalBackdrop');
    var modalEl = document.getElementById('wbBoxModal');
    var modalBody = document.getElementById('wbBoxModalBody');
    if (!backdrop || !backdrop.classList.contains('is-open') || !modalEl || !modalBody) return null;
    var det = modalEl.__wbActiveDet;
    if (!det) return null;
    var idx = Number(det.getAttribute('data-wb-box-idx'));
    var boxMeta = (meta.boxes && idx >= 0 && idx < meta.boxes.length) ? meta.boxes[idx] : null;
    if (!boxMeta) return null;
    return { modalBody: modalBody, boxIdx: boxMeta.boxIdx, startLine: boxMeta.startLine, endLine: boxMeta.endLine };
  }

  function cleanDomHeadingText(el) {
    var clone = el.cloneNode(true);
    var maths = clone.querySelectorAll('mjx-container, .math, script, style');
    for (var m = 0; m < maths.length; m += 1) {
      if (maths[m].parentNode) maths[m].parentNode.removeChild(maths[m]);
    }
    return String(clone.textContent || '')
      .replace(/\\\([\s\S]*?\\\)|\$[^$]+\$/g, '')
      .replace(/\\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  function buildScopedAnchors(containerEl, scopeBoxIdx, startLine, endLine, currentScroll, maxScroll) {
    var anchors = [{ line: startLine, y: 0 }];
    var isModal = !!containerEl;
    var root = containerEl || document;
    var containerTop = isModal ? containerEl.getBoundingClientRect().top : 0;

    var srcAnchors = [];
    for (var s = 0; s < (meta.anchors || []).length; s += 1) {
      var sa = meta.anchors[s];
      if (sa.line <= startLine || sa.line >= endLine) continue;
      if (sa.kind === 'box') {
        var bMeta = meta.boxes && meta.boxes[sa.boxIdx];
        if (bMeta && bMeta.parentIdx === scopeBoxIdx) srcAnchors.push(sa);
      } else if (sa.kind === 'h' && sa.boxIdx === scopeBoxIdx) {
        srcAnchors.push(sa);
      }
    }

    var els = root.querySelectorAll('h1, h2, h3, h4, h5, h6, details.marginbox, details.tcolorbox, details.vbox');
    var domBoxesByIdx = {};
    var domHeadings = [];
    for (var i = 0; i < els.length; i += 1) {
      var el = els[i];
      if (!el || el.offsetParent === null) continue;
      if (!isModal && el.closest && el.closest('#title-block-header, #floatingToolbar, #wbBoxModalBackdrop, #wbTocDrawer, #wbGraphWorkspace, #viewerCompatWarning')) {
        continue;
      }
      if (el.tagName === 'DETAILS') {
        if (el.parentElement && el.parentElement.closest && el.parentElement.closest('details.marginbox, details.tcolorbox, details.vbox')) {
          continue;
        }
        var bIdx = Number(el.getAttribute('data-wb-box-idx'));
        if (!isNaN(bIdx)) {
          var rectB = el.getBoundingClientRect();
          var yB = isModal
            ? Math.max(0, Math.min(maxScroll, currentScroll + (rectB.top - containerTop) - 8))
            : Math.max(0, Math.min(maxScroll, rectB.top + window.scrollY - 12));
          var yBottom = isModal
            ? Math.max(yB, Math.min(maxScroll, currentScroll + (rectB.bottom - containerTop) - 8))
            : Math.max(yB, Math.min(maxScroll, rectB.bottom + window.scrollY - 12));
          domBoxesByIdx[bIdx] = { top: yB, bottom: yBottom, open: !!el.open };
        }
      } else {
        if (el.closest && el.closest('details.marginbox, details.tcolorbox, details.vbox')) {
          continue;
        }
        var rectH = el.getBoundingClientRect();
        var yH = isModal
          ? Math.max(0, Math.min(maxScroll, currentScroll + (rectH.top - containerTop) - 8))
          : Math.max(0, Math.min(maxScroll, rectH.top + window.scrollY - 12));
        domHeadings.push({ y: yH, text: cleanDomHeadingText(el) });
      }
    }

    var hCursor = 0;
    for (var k = 0; k < srcAnchors.length; k += 1) {
      var item = srcAnchors[k];
      if (item.kind === 'box' && domBoxesByIdx[item.boxIdx]) {
        var boxPos = domBoxesByIdx[item.boxIdx];
        var boxSpan = meta.boxes && meta.boxes[item.boxIdx];
        if (boxPos.top >= anchors[anchors.length - 1].y && item.line > anchors[anchors.length - 1].line) {
          anchors.push({ line: item.line, y: boxPos.top });
        }
        // When a box is collapsed in the current view, scrolling past its bottom
        // must immediately jump past its entire source [startLine..endLine] span.
        if (boxSpan && !boxPos.open && boxSpan.endLine > item.line) {
          var endAnchorLine = Math.min(endLine, boxSpan.endLine + 1);
          if (boxPos.bottom >= anchors[anchors.length - 1].y && endAnchorLine > anchors[anchors.length - 1].line) {
            anchors.push({ line: endAnchorLine, y: boxPos.bottom });
          }
        }
      } else if (item.kind === 'h') {
        var targetText = item.text || '';
        for (var j = hCursor; j < domHeadings.length; j += 1) {
          var domH = domHeadings[j];
          var matched = domH.text === targetText ||
            (targetText.length >= 6 && (domH.text.indexOf(targetText) !== -1 || targetText.indexOf(domH.text) !== -1));
          if (matched) {
            if (domH.y >= anchors[anchors.length - 1].y && item.line > anchors[anchors.length - 1].line) {
              anchors.push({ line: item.line, y: domH.y });
            }
            hCursor = j + 1;
            break;
          }
        }
      }
    }

    if (anchors[anchors.length - 1].line < endLine) {
      anchors.push({ line: endLine, y: maxScroll });
    }
    return anchors;
  }

  function interpLineToY(anchors, line, startLine, endLine) {
    var clamped = Math.max(startLine, Math.min(endLine, line));
    for (var i = 0; i < anchors.length - 1; i += 1) {
      var a = anchors[i];
      var b = anchors[i + 1];
      if (clamped >= a.line && clamped <= b.line) {
        var span = Math.max(1, b.line - a.line);
        return a.y + ((clamped - a.line) / span) * (b.y - a.y);
      }
    }
    return anchors[anchors.length - 1].y;
  }

  function interpYToLine(anchors, y) {
    var clampedY = Math.max(0, y);
    for (var i = 0; i < anchors.length - 1; i += 1) {
      var a = anchors[i];
      var b = anchors[i + 1];
      if (clampedY >= a.y && clampedY <= b.y) {
        var spanY = b.y - a.y;
        if (spanY <= 0) return a.line;
        return Math.round(a.line + ((clampedY - a.y) / spanY) * (b.line - a.line));
      }
    }
    return anchors[anchors.length - 1].line;
  }

  function getCollapsedBoxRanges(containerEl) {
    var ranges = [];
    var isModal = !!containerEl;
    var root = containerEl || document;
    var containerTop = isModal ? containerEl.getBoundingClientRect().top : 0;
    var currentScroll = isModal ? containerEl.scrollTop : window.scrollY;
    var maxScroll = isModal
      ? Math.max(0, containerEl.scrollHeight - containerEl.clientHeight)
      : Math.max(0, document.documentElement.scrollHeight - window.innerHeight);

    var dets = root.querySelectorAll('details.marginbox, details.tcolorbox, details.vbox');
    for (var i = 0; i < dets.length; i += 1) {
      var det = dets[i];
      if (!det || det.offsetParent === null || det.open) continue;
      if (det.parentElement && det.parentElement.closest && det.parentElement.closest('details.marginbox, details.tcolorbox, details.vbox')) {
        continue;
      }
      var bIdx = Number(det.getAttribute('data-wb-box-idx'));
      var boxSpan = (!isNaN(bIdx) && meta.boxes) ? meta.boxes[bIdx] : null;
      if (!boxSpan) continue;
      var rect = det.getBoundingClientRect();
      var yTop = isModal
        ? Math.max(0, Math.min(maxScroll, currentScroll + (rect.top - containerTop) - 8))
        : Math.max(0, Math.min(maxScroll, rect.top + window.scrollY - 12));
      var yBottom = isModal
        ? Math.max(yTop, Math.min(maxScroll, currentScroll + (rect.bottom - containerTop) - 8))
        : Math.max(yTop, Math.min(maxScroll, rect.bottom + window.scrollY - 12));
      ranges.push({
        startLine: boxSpan.startLine,
        endLine: boxSpan.endLine,
        yTop: yTop,
        yBottom: yBottom,
      });
    }
    return ranges;
  }

  function isLineInCollapsedRanges(line, ranges) {
    for (var i = 0; i < ranges.length; i += 1) {
      if (line >= ranges[i].startLine && line <= ranges[i].endLine) return true;
    }
    return false;
  }

  function isYInCollapsedRanges(y, ranges) {
    for (var i = 0; i < ranges.length; i += 1) {
      if (y > ranges[i].yTop && y < ranges[i].yBottom) return true;
    }
    return false;
  }

  function snapOutsideCodeSpans(line) {
    var spans = meta.codeSpans || [];
    for (var i = 0; i < spans.length; i += 1) {
      var s = spans[i];
      if (line >= s.startLine && line <= s.endLine) {
        var mid = (s.startLine + s.endLine) / 2;
        return line <= mid ? Math.max(0, s.startLine - 1) : s.endLine + 1;
      }
    }
    return line;
  }

  var ignoreScrollUntil = 0;
  var scrollTimer = 0;

  function scrollToEditorLine(line, totalLines) {
    if (!meta.scrollSync) return;
    if (isLineInCollapsedRanges(line, meta.codeSpans || [])) return;
    var modal = getActiveModalBox();
    if (modal) {
      if (line < modal.startLine || line > modal.endLine) return;
      var mCollapsed = getCollapsedBoxRanges(modal.modalBody);
      if (isLineInCollapsedRanges(line, mCollapsed)) return;
      ignoreScrollUntil = Date.now() + 220;
      var maxModalScroll = Math.max(0, modal.modalBody.scrollHeight - modal.modalBody.clientHeight);
      var mAnchors = buildScopedAnchors(modal.modalBody, modal.boxIdx, modal.startLine, modal.endLine, modal.modalBody.scrollTop, maxModalScroll);
      modal.modalBody.scrollTop = interpLineToY(mAnchors, line, modal.startLine, modal.endLine);
      return;
    }

    var wCollapsed = getCollapsedBoxRanges(null);
    if (isLineInCollapsedRanges(line, wCollapsed)) return;
    ignoreScrollUntil = Date.now() + 220;
    var maxLine = Math.max(1, (totalLines || meta.totalLines || 1) - 1);
    var maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    var wAnchors = buildScopedAnchors(null, -1, 0, maxLine, window.scrollY, maxScroll);
    var y = interpLineToY(wAnchors, line, 0, maxLine);
    window.scrollTo({ top: y, behavior: 'instant' });
  }

  function emitPreviewScroll() {
    if (!meta.scrollSync || !api) return;
    if (Date.now() < ignoreScrollUntil) return;
    if (scrollTimer) return;
    scrollTimer = setTimeout(function() {
      scrollTimer = 0;
      if (Date.now() < ignoreScrollUntil) return;
      var modal = getActiveModalBox();
      var targetLine = 0;
      if (modal) {
        var mCollapsed = getCollapsedBoxRanges(modal.modalBody);
        if (isYInCollapsedRanges(modal.modalBody.scrollTop, mCollapsed)) return;
        var maxModalScroll = Math.max(0, modal.modalBody.scrollHeight - modal.modalBody.clientHeight);
        var mAnchors = buildScopedAnchors(modal.modalBody, modal.boxIdx, modal.startLine, modal.endLine, modal.modalBody.scrollTop, maxModalScroll);
        targetLine = interpYToLine(mAnchors, modal.modalBody.scrollTop);
      } else {
        var wCollapsed = getCollapsedBoxRanges(null);
        if (isYInCollapsedRanges(window.scrollY, wCollapsed)) return;
        var maxLine = Math.max(1, (meta.totalLines || 1) - 1);
        var maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        var wAnchors = buildScopedAnchors(null, -1, 0, maxLine, window.scrollY, maxScroll);
        targetLine = interpYToLine(wAnchors, window.scrollY);
      }
      targetLine = snapOutsideCodeSpans(targetLine);
      api.postMessage({ type: 'wb:previewScrolled', line: targetLine });
    }, 16);
  }

  window.addEventListener('message', function(event) {
    var msg = event && event.data;
    if (!msg) return;
    if (msg.type === 'wb:scrollTo') {
      scrollToEditorLine(msg.topLine || 0, msg.totalLines || meta.totalLines);
    }
  });

  window.addEventListener('scroll', emitPreviewScroll, { passive: true });

  function injectRefreshButton() {
    if (document.getElementById('wbVsCodeRefreshBtn') || !document.body) return;
    var btn = document.createElement('button');
    btn.id = 'wbVsCodeRefreshBtn';
    btn.type = 'button';
    btn.title = 'Refresh Whiteboard HTML Preview';
    btn.textContent = '↻ Refresh';
    btn.style.cssText = 'position:fixed;top:10px;right:14px;z-index:8700;cursor:pointer;padding:5px 11px;border-radius:999px;border:1px solid rgba(128,128,128,0.45);background:rgba(30,30,36,0.82);color:#f4f4f5;font-size:12px;font-weight:600;backdrop-filter:blur(6px);box-shadow:0 2px 8px rgba(0,0,0,0.2);';
    btn.addEventListener('click', function() {
      btn.disabled = true;
      btn.textContent = '↻ Refreshing…';
      if (api) api.postMessage({ type: 'wb:refresh' });
    });
    document.body.appendChild(btn);
  }

  function onReady() {
    tagBoxIndices();
    syncVsCodeTheme();
    injectRefreshButton();
    if (typeof MutationObserver === 'function' && document.body) {
      new MutationObserver(syncVsCodeTheme).observe(document.body, { attributes: true, attributeFilter: ['class'] });
    }
    var modalBody = document.getElementById('wbBoxModalBody');
    if (modalBody) {
      modalBody.addEventListener('scroll', emitPreviewScroll, { passive: true });
    }
    if (meta.scrollSync && meta.initialTopLine > 0) {
      setTimeout(function() {
        scrollToEditorLine(meta.initialTopLine, meta.totalLines);
      }, 60);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', onReady);
  } else {
    onReady();
  }
})();
</script>\n`;
  out = out.replace(/<\/body>/i, `${syncScript}</body>`);

  return out;
}

/**
 * Renders an error or loading page inside the Webview panel.
 * @param {string} title
 * @param {string} message
 * @returns {string}
 */
function renderStatusHtml(title, message) {
  const esc = (s) =>
    String(s || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; padding: 24px; color: #e5e7eb; background: #18181b; }
    .card { max-width: 720px; border: 1px solid #3f3f46; border-radius: 8px; padding: 16px 20px; background: #27272a; }
    h2 { margin: 0 0 8px 0; font-size: 16px; }
    pre { white-space: pre-wrap; word-break: break-word; font-size: 13px; color: #fca5a5; margin: 0; }
  </style>
</head>
<body>
  <div class="card">
    <h2>${esc(title)}</h2>
    <pre>${esc(message)}</pre>
  </div>
</body>
</html>`;
}

/** @type {Map<string, { panel: vscode.WebviewPanel, docUri: vscode.Uri, buildSeq: number, ignoreEditorScrollUntil: number, scrollTimer: NodeJS.Timeout | null }>} */
const activePanels = new Map();

/**
 * Returns the top visible 0-based line for an open editor showing `docUri`.
 * @param {vscode.Uri} docUri
 * @returns {number}
 */
function getVisibleTopLine(docUri) {
  const key = docUri.toString();
  const editors = vscode.window.visibleTextEditors || [];
  for (const ed of editors) {
    if (ed.document && ed.document.uri.toString() === key && ed.visibleRanges && ed.visibleRanges.length > 0) {
      return ed.visibleRanges[0].start.line;
    }
  }
  return 0;
}

/**
 * Opens or refreshes the side-by-side preview for a whiteboard_html document.
 * @param {vscode.TextDocument} doc
 * @param {vscode.ExtensionContext} context
 */
async function openOrUpdatePreview(doc, context) {
  if (!doc) return;
  const ext = path.extname(doc.fileName || '').toLowerCase();
  if (!SUPPORTED_EXTENSIONS.has(ext)) {
    vscode.window.showWarningMessage(
      'Whiteboard HTML Preview only supports .md, .markdown, and .txt files.'
    );
    return;
  }

  const docText = doc.getText();
  if (!hasWhiteboardHtmlLayout(docText)) {
    vscode.window.showWarningMessage(
      'Whiteboard HTML Preview only supports documents with "page-layout: whiteboard_html" in their YAML block.'
    );
    return;
  }

  const configDir = await resolveConfigDir(doc.uri, context);
  if (!configDir) {
    vscode.window.showErrorMessage(
      'Could not locate ai-ready-markdown-to-pdf config/. Set "whiteboardHtml.configPath" in VS Code settings.'
    );
    return;
  }

  const key = doc.uri.toString();
  const docDir = path.dirname(doc.uri.fsPath);
  const repoRoot = path.dirname(configDir);
  const localResourceRoots = [
    vscode.Uri.file(configDir),
    vscode.Uri.file(repoRoot),
    vscode.Uri.file(docDir),
  ];

  let entry = activePanels.get(key);
  if (!entry) {
    const panel = vscode.window.createWebviewPanel(
      'whiteboardHtmlPreview',
      `Preview: ${path.basename(doc.fileName)}`,
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots,
      }
    );
    entry = {
      panel,
      docUri: doc.uri,
      buildSeq: 0,
      ignoreEditorScrollUntil: 0,
      scrollTimer: null,
    };
    activePanels.set(key, entry);

    panel.onDidDispose(() => {
      if (entry.scrollTimer) clearTimeout(entry.scrollTimer);
      activePanels.delete(key);
    });

    panel.webview.onDidReceiveMessage(async (msg) => {
      if (!msg || !msg.type) return;
      if (msg.type === 'wb:saveHtml') {
        const defaultUri = vscode.Uri.file(path.join(docDir, msg.fileName || 'preview.html'));
        const targetUri = await vscode.window.showSaveDialog({
          defaultUri,
          filters: { 'HTML Document': ['html', 'htm'] },
        });
        if (!targetUri) return;
        await vscode.workspace.fs.writeFile(targetUri, Buffer.from(String(msg.html || ''), 'utf8'));
        vscode.window.showInformationMessage(`Saved ${path.basename(targetUri.fsPath)}`);
      } else if (msg.type === 'wb:refresh') {
        const latestDoc = await vscode.workspace.openTextDocument(entry.docUri);
        if (latestDoc.isDirty) {
          await latestDoc.save();
        }
        await openOrUpdatePreview(latestDoc, context);
      } else if (msg.type === 'wb:previewScrolled') {
        const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
        if (cfg.get('scrollSync') === false) return;
        const targetLine = Math.max(0, Number(msg.line) || 0);
        const editors = vscode.window.visibleTextEditors || [];
        const editor = editors.find((ed) => ed.document && ed.document.uri.toString() === key);
        if (!editor) return;
        const clamped = Math.min(Math.max(0, editor.document.lineCount - 1), targetLine);
        entry.ignoreEditorScrollUntil = Date.now() + 260;
        const pos = new vscode.Position(clamped, 0);
        editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.AtTop);
      }
    });
  } else if (!entry.panel.visible) {
    entry.panel.reveal(entry.panel.viewColumn, true);
  }

  const seq = ++entry.buildSeq;
  if (!entry.panel.webview.html) {
    entry.panel.webview.html = renderStatusHtml('Building Whiteboard HTML…', doc.fileName);
  }

  const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
  try {
    const { html, sourceMap } = await buildWhiteboardHtml({
      inputPath: doc.uri.fsPath,
      configDir,
      pandocPath: cfg.get('pandocPath') || 'pandoc',
      texluaPath: cfg.get('texluaPath') || 'texlua',
      nodePath: cfg.get('nodePath') || 'node',
    });
    if (!activePanels.has(key) || entry.buildSeq !== seq) return;
    entry.panel.webview.html = transformHtmlForWebview(html, {
      webview: entry.panel.webview,
      configDir,
      docDir,
      scrollSync: cfg.get('scrollSync') !== false,
      initialTopLine: getVisibleTopLine(doc.uri),
      totalLines: doc.lineCount || 1,
      sourceAnchors: sourceMap,
    });
  } catch (err) {
    if (!activePanels.has(key) || entry.buildSeq !== seq) return;
    const errMsg = err && err.message ? err.message : String(err);
    entry.panel.webview.html = renderStatusHtml('Whiteboard HTML Build Failed', errMsg);
    if (/ENOENT|not recognized|could not find|pandoc/i.test(errMsg)) {
      const choice = await vscode.window.showErrorMessage(
        'Whiteboard HTML Preview is missing a required dependency (e.g. Pandoc). Download and run setup.bat to install prerequisites?',
        'Run setup.bat'
      );
      if (choice === 'Run setup.bat') {
        await downloadAndRunSetup(context, configDir);
      }
    }
  }
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('whiteboardHtml.openPreviewToSide', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        vscode.window.showWarningMessage('Open a whiteboard_html Markdown/text document first.');
        return;
      }
      if (editor.document.isDirty) {
        await editor.document.save();
      }
      await openOrUpdatePreview(editor.document, context);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('whiteboardHtml.refreshPreview', async () => {
      const activeEd = vscode.window.activeTextEditor;
      let targetEntry = activeEd ? activePanels.get(activeEd.document.uri.toString()) : null;
      if (!targetEntry) {
        for (const entry of activePanels.values()) {
          if (entry.panel.active) {
            targetEntry = entry;
            break;
          }
        }
      }
      if (!targetEntry && activePanels.size === 1) {
        targetEntry = activePanels.values().next().value;
      }
      if (!targetEntry) {
        if (activeEd) {
          if (activeEd.document.isDirty) await activeEd.document.save();
          await openOrUpdatePreview(activeEd.document, context);
        } else {
          vscode.window.showWarningMessage('No active Whiteboard HTML preview to refresh.');
        }
        return;
      }
      const doc = await vscode.workspace.openTextDocument(targetEntry.docUri);
      if (doc.isDirty) {
        await doc.save();
      }
      await openOrUpdatePreview(doc, context);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('whiteboardHtml.updateConfigFromRepo', async () => {
      const storageRoot = context && context.globalStorageUri && context.globalStorageUri.fsPath;
      if (!storageRoot) {
        vscode.window.showErrorMessage('VS Code globalStorageUri is unavailable.');
        return;
      }
      const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
      const repoBaseUrl = (cfg.get('repoBaseUrl') || DEFAULT_REPO_CONFIG_URL).trim();
      const targetDir = path.join(storageRoot, 'config');
      try {
        await vscode.window.withProgress(
          {
            location: vscode.ProgressLocation.Notification,
            title: 'Whiteboard HTML: Updating filters from GitHub…',
            cancellable: false,
          },
          () => downloadConfigFromRepo(targetDir, repoBaseUrl)
        );
        vscode.window.showInformationMessage(`Updated Whiteboard HTML filters in ${targetDir}`);
      } catch (err) {
        vscode.window.showErrorMessage(
          `Failed to update filters: ${err && err.message ? err.message : String(err)}`
        );
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('whiteboardHtml.runSetup', async () => {
      const activeEd = vscode.window.activeTextEditor;
      const docUri = activeEd ? activeEd.document.uri : undefined;
      const configDir = await resolveConfigDir(docUri, context);
      await downloadAndRunSetup(context, configDir);
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument(async (doc) => {
      const key = doc.uri.toString();
      if (!activePanels.has(key)) return;
      if (!hasWhiteboardHtmlLayout(doc.getText())) return;
      await openOrUpdatePreview(doc, context);
    })
  );

  if (typeof vscode.window.onDidChangeTextEditorVisibleRanges === 'function') {
    context.subscriptions.push(
      vscode.window.onDidChangeTextEditorVisibleRanges((event) => {
        if (!event || !event.textEditor || !event.visibleRanges || !event.visibleRanges.length) return;
        const doc = event.textEditor.document;
        const key = doc.uri.toString();
        const entry = activePanels.get(key);
        if (!entry) return;
        const cfg = vscode.workspace.getConfiguration('whiteboardHtml');
        if (cfg.get('scrollSync') === false) return;
        if (Date.now() < entry.ignoreEditorScrollUntil) return;

        const topLine = event.visibleRanges[0].start.line;
        const totalLines = doc.lineCount || 1;
        if (entry.scrollTimer) clearTimeout(entry.scrollTimer);
        entry.scrollTimer = setTimeout(() => {
          entry.scrollTimer = null;
          if (!activePanels.has(key)) return;
          if (Date.now() < entry.ignoreEditorScrollUntil) return;
          entry.panel.webview.postMessage({
            type: 'wb:scrollTo',
            topLine,
            totalLines,
          });
        }, 40);
      })
    );
  }
}

function deactivate() {
  for (const entry of activePanels.values()) {
    try {
      entry.panel.dispose();
    } catch (_) {}
  }
  activePanels.clear();
}

module.exports = {
  activate,
  deactivate,
  hasWhiteboardHtmlLayout,
  resolveConfigDir,
  downloadConfigFromRepo,
  downloadAndRunSetup,
  buildWhiteboardHtml,
  transformHtmlForWebview,
};
