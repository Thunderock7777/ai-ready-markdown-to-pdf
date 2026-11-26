// build-graph.js
// Transforms normalized standard Markdown (from graph-markdown-extractor.lua)
// into a compact gzipped Markmap payload JSON ({ v: 2, gz, stats }) and, when
// an offline vendor output path is provided, writes a gzipped { d3, mm, katexCss }
// bundle decoded lazily in browser via DecompressionStream('gzip').
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const inputMdPath = process.argv[2];
const outputJsonPath = process.argv[3];
const vendorJsonPath = process.argv[4] || '';

if (!inputMdPath || !outputJsonPath) {
  console.error('Usage: node build-graph.js <graph.md> <output_payload.json> [output_vendor.json]');
  process.exit(1);
}

const { Transformer } = require(path.join(__dirname, 'node_modules', 'markmap-lib'));

function decodeHtmlEntities(str) {
  return String(str || '')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function stripTags(html) {
  return decodeHtmlEntities(String(html || '').replace(/<[^>]*>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function extractJumpMetadata(node) {
  if (!node || typeof node !== 'object') return;
  const content = String(node.content || '');
  const spanOpenMatch = content.match(/^<span\b([^>]*)>/i);
  let wb = null;

  if (spanOpenMatch) {
    const attrsStr = spanOpenMatch[1];
    const readAttr = (name) => {
      const m = attrsStr.match(new RegExp(name + '="([^"]*)"', 'i'));
      return m ? decodeHtmlEntities(m[1]) : '';
    };
    const jtype = readAttr('data-wb-jtype');
    const jid = readAttr('data-wb-jid');
    const jtitle = readAttr('data-wb-jtitle');
    const jidx = parseInt(readAttr('data-wb-jidx') || '0', 10) || 0;
    const janc = readAttr('data-wb-janc');
    const jitem = readAttr('data-wb-jitem');
    const jsnip = readAttr('data-wb-jsnip');
    const jlidx = parseInt(readAttr('data-wb-jlidx') || '0', 10) || 0;
    const color = readAttr('data-wb-color');

    if (jtype) {
      wb = {
        jtype,
        jid,
        jtitle,
        jidx,
        janc,
        jitem,
        jsnip,
        jlidx,
        color,
        text: stripTags(content)
      };
      node.content = content;
    }
  } else if (content) {
    wb = {
      jtype: '',
      jid: '',
      jtitle: '',
      jidx: 0,
      color: '',
      text: stripTags(content)
    };
  }

  if (wb) {
    node.payload = node.payload || {};
    node.payload.wb = wb;
  }

  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      extractJumpMetadata(child);
    }
  }
}

const CORE_OFFLINE_FONTS = new Set([
  'KaTeX_AMS-Regular.woff2',
  'KaTeX_Main-Bold.woff2',
  'KaTeX_Main-Italic.woff2',
  'KaTeX_Main-Regular.woff2',
  'KaTeX_Math-Italic.woff2',
  'KaTeX_Size1-Regular.woff2',
  'KaTeX_Size2-Regular.woff2'
]);

function buildOfflineKatexCss() {
  const vendorCss = path.join(__dirname, 'vendor', 'katex', 'katex.min.css');
  let cssPath = vendorCss;
  let fontBaseDir = path.join(__dirname, 'vendor', 'katex');

  if (!fs.existsSync(cssPath)) {
    try {
      const katexDir = path.dirname(require.resolve('katex/package.json', {
        paths: [path.join(__dirname, 'node_modules')]
      }));
      cssPath = path.join(katexDir, 'dist', 'katex.min.css');
      fontBaseDir = path.join(katexDir, 'dist');
    } catch (e) {
      return '';
    }
  }

  if (!fs.existsSync(cssPath)) return '';
  let css = fs.readFileSync(cssPath, 'utf8');

  css = css.replace(/@font-face\{([^}]+)\}/g, (full, body) => {
    const woff2Match = body.match(/url\((fonts\/([^)]+\.woff2))\)/);
    if (!woff2Match) return '';
    if (!CORE_OFFLINE_FONTS.has(woff2Match[2])) return '';
    const relFont = woff2Match[1].replace(/\//g, path.sep);
    const fontPath = path.join(fontBaseDir, relFont);
    if (!fs.existsSync(fontPath)) return '';
    const b64 = fs.readFileSync(fontPath).toString('base64');
    const srcIdx = body.indexOf('src:');
    if (srcIdx === -1) return full;
    const prefix = body.slice(0, srcIdx);
    return `@font-face{${prefix}src:url(data:font/woff2;base64,${b64}) format("woff2")}`;
  });
  return css;
}

function resolveVendorAsset(relVendor, relNodeModules) {
  const vp = path.join(__dirname, 'vendor', relVendor);
  if (fs.existsSync(vp)) return fs.readFileSync(vp, 'utf8');
  const np = path.join(__dirname, 'node_modules', relNodeModules);
  if (fs.existsSync(np)) return fs.readFileSync(np, 'utf8');
  return '';
}

function writeOfflineVendorBundle(outPath, includeKatexCss) {
  const bundle = {
    d3: resolveVendorAsset('d3.min.js', path.join('d3', 'dist', 'd3.min.js')),
    mm: resolveVendorAsset('markmap-view.min.js', path.join('markmap-view', 'dist', 'browser', 'index.js')),
    katexCss: includeKatexCss ? buildOfflineKatexCss() : ''
  };
  if (!bundle.d3 || !bundle.mm) return;
  const gzB64 = zlib.gzipSync(Buffer.from(JSON.stringify(bundle), 'utf8'), { level: 9 }).toString('base64');
  fs.writeFileSync(outPath, JSON.stringify({ v: 1, gz: gzB64 }), 'utf8');
}

const mdText = fs.readFileSync(inputMdPath, 'utf8');
const transformer = new Transformer();
const { root, features } = transformer.transform(mdText);

extractJumpMetadata(root);

const rootJson = JSON.stringify(root);
const gzB64 = zlib.gzipSync(Buffer.from(rootJson, 'utf8'), { level: 9 }).toString('base64');
const hasKatex = Boolean(features && features.katex);

const payload = {
  v: 2,
  gz: gzB64,
  stats: {
    hasKatex,
    rawBytes: Buffer.byteLength(rootJson, 'utf8'),
    gzBytes: gzB64.length,
    generatedAt: new Date().toISOString()
  }
};

// Escape "</" so embedding inside HTML <script type="application/json"> cannot close tag early
const safeJson = JSON.stringify(payload).replace(/<\//g, '<\\/');
fs.writeFileSync(outputJsonPath, safeJson, 'utf8');

if (vendorJsonPath) {
  writeOfflineVendorBundle(vendorJsonPath, hasKatex);
}
