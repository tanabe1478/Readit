// Browser glue for the MoonBit wasm-gc app. The app owns all state; this file
// only touches the DOM, talks to the local server and runs Tree-sitter.
import { Parser, Language, Query } from './vendor/tree-sitter.js';

const token = document.querySelector('meta[name="readit-token"]').content;
const $ = (id) => document.getElementById(id);
let exports = null;

const send = (kind, data) => {
  if (!exports) return false;
  try {
    return !!exports.on_event(kind, JSON.stringify(data ?? {}));
  } catch (error) {
    console.error('Readit event failed', kind, error);
    showFatal(error);
    return false;
  }
};

function showFatal(error) {
  const box = $('fatal');
  if (!box) return;
  box.style.display = 'block';
  box.textContent = 'Readitで内部エラーが発生しました。再読み込みしてください。\n' + (error && error.stack || error);
}

// ---- DOM ----

const html = new Map();
function setHtml(id, value) {
  if (html.get(id) === value) return;
  const el = $(id);
  if (!el) return;
  html.set(id, value);
  el.innerHTML = value;
}

function codeLine(view, line) {
  return document.querySelector(`.lines[data-view="${view}"] .row[data-line="${line}"] .code`);
}

// Text nodes of a rendered line, excluding the caret and end-of-line markers.
function lineNodes(code) {
  const nodes = [];
  const walk = document.createTreeWalker(code, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.parentElement.closest('.eol') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
  });
  for (let n = walk.nextNode(); n; n = walk.nextNode()) nodes.push(n);
  return nodes;
}

function locate(nodes, offset) {
  let at = 0;
  for (const n of nodes) {
    if (offset <= at + n.length) return [n, offset - at];
    at += n.length;
  }
  const last = nodes[nodes.length - 1];
  return last ? [last, last.length] : null;
}

function lineLength(nodes) {
  return nodes.reduce((a, n) => a + n.length, 0);
}

function rectOf(nodes, start, end) {
  const a = locate(nodes, start), b = locate(nodes, end);
  if (!a || !b) return null;
  const range = document.createRange();
  range.setStart(a[0], a[1]);
  range.setEnd(b[0], b[1]);
  const rects = range.getClientRects();
  if (rects.length) {
    let r = rects[0];
    let left = r.left, top = r.top, right = r.right, bottom = r.bottom;
    for (const x of rects) { left = Math.min(left, x.left); top = Math.min(top, x.top); right = Math.max(right, x.right); bottom = Math.max(bottom, x.bottom); }
    return { left, top, width: right - left, height: bottom - top };
  }
  const r = range.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

// Box of [start, end) on a line; a collapsed range gives a zero-width box.
function rangeRect(view, line, start, end) {
  const code = codeLine(view, line);
  if (!code) return '';
  const nodes = lineNodes(code);
  const len = lineLength(nodes);
  let r;
  if (start === end) {
    if (start < len) {
      r = rectOf(nodes, start, start + 1);
      if (r) r = { left: r.left, top: r.top, width: Math.max(r.width, 1), height: r.height };
    } else if (len > 0) {
      r = rectOf(nodes, len - 1, len);
      if (r) r = { left: r.left + r.width, top: r.top, width: 1, height: r.height };
    }
    if (!r) {
      const b = code.getBoundingClientRect();
      r = { left: b.left, top: b.top, width: 1, height: b.height };
    }
  } else {
    r = rectOf(nodes, Math.min(start, len), Math.min(end, len));
  }
  if (!r) return '';
  return [r.left, r.top, r.width, r.height].map((v) => v.toFixed(1)).join(',');
}

function caretFromPoint(x, y) {
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    return p ? [p.offsetNode, p.offset] : null;
  }
  const r = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
  return r ? [r.startContainer, r.startOffset] : null;
}

// Line and UTF-16 column under a point, plus the column of the glyph actually
// under it (-1 over blank space or gutters).
function hitTest(view, x, y) {
  const lines = document.querySelector(`.lines[data-view="${view}"]`);
  if (!lines) return null;
  const rows = lines.querySelectorAll('.row');
  if (!rows.length) return null;
  let row = null;
  for (const r of rows) {
    const b = r.getBoundingClientRect();
    if (y >= b.top && y < b.bottom) { row = r; break; }
  }
  let clampedEnd = false;
  if (!row) {
    const first = rows[0].getBoundingClientRect();
    row = y < first.top ? rows[0] : rows[rows.length - 1];
    clampedEnd = y >= first.top;
  }
  const line = Number(row.dataset.line);
  const code = row.querySelector('.code');
  const nodes = lineNodes(code);
  const len = lineLength(nodes);
  const cb = code.getBoundingClientRect();
  let col;
  if (clampedEnd) col = len;
  else if (x <= cb.left) col = 0;
  else {
    col = len;
    const hit = caretFromPoint(x, Math.min(Math.max(y, cb.top + 1), cb.bottom - 1));
    if (hit && code.contains(hit[0])) {
      // The hit may name an element (the caret marker) rather than a text node,
      // so count the characters from the line start to it.
      // WebKit can report an offset past the node's end; clamp it.
      const node = hit[0];
      const limit = node.nodeType === Node.TEXT_NODE ? node.length : node.childNodes.length;
      try {
        const range = document.createRange();
        range.setStart(code, 0);
        range.setEnd(node, Math.min(hit[1], limit));
        col = Math.min(len, range.toString().length);
      } catch (_) {
        col = len;
      }
    }
  }
  let glyph = -1;
  for (const c of [col, col - 1]) {
    if (c < 0 || c >= len) continue;
    const r = rectOf(nodes, c, c + 1);
    if (r && x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height) { glyph = c; break; }
  }
  return { line, col, glyph };
}

function scrollContainer(view) {
  return view === 'pinned' ? $('pinned-scroll') : $('editor-scroll');
}

function revealLine(view, line, mode, lh) {
  const box = scrollContainer(view);
  if (!box) return;
  const row = document.querySelector(`.lines[data-view="${view}"] .row[data-line="${line}"]`);
  const y = row ? row.offsetTop : line * lh;
  const h = row ? row.offsetHeight : lh;
  const top = box.scrollTop, height = box.clientHeight;
  let target = top;
  if (mode === 1) target = Math.max(0, y - lh);
  else if (mode === 2) target = Math.max(0, y - height / 2 + h);
  else if (y < top) target = y;
  else if (y + h > top + height) target = y + h + lh - height;
  if (target !== top) box.scrollTop = target;
}

function placeInput() {
  const input = $('editor-input');
  const caret = document.querySelector('#editor-content .caret');
  if (!input) return;
  if (!caret) { input.style.left = '-1000px'; return; }
  const r = caret.getBoundingClientRect();
  input.style.left = r.left + 'px';
  input.style.top = r.top + 'px';
  input.style.height = r.height + 'px';
}

const dom = {
  set_html: setHtml,
  set_style: (id, prop, value) => {
    const el = $(id);
    if (!el) return;
    if (prop === 'cssText') { if (el.dataset.css !== value) { el.dataset.css = value; el.style.cssText = value; } return; }
    if (el.style[prop] !== value) el.style[prop] = value;
  },
  set_class: (id, name, on) => { const el = $(id); if (el) el.classList.toggle(name, !!on); },
  focus: (id) => { const el = $(id); if (el && document.activeElement !== el) el.focus({ preventScroll: true }); },
  has_focus: (id) => {
    const a = document.activeElement;
    if (id === '') return !a || a === document.body;
    return !!a && a.id === id;
  },
  set_value: (id, v) => { const el = $(id); if (el && el.value !== v) el.value = v; },
  get_value: (id) => { const el = $(id); return el ? el.value : ''; },
  select_input: (id) => { const el = $(id); if (el) { el.focus(); el.select(); } },
  scroll_top: (id) => { const el = $(id); return el ? el.scrollTop : 0; },
  set_scroll_top: (id, v) => { const el = $(id); if (el) el.scrollTop = v; },
  client_height: (id) => { const el = $(id); return el ? el.clientHeight : 0; },
  client_width: (id) => { const el = $(id); return el ? el.clientWidth : 0; },
  natural_height: (id) => { const el = $(id); return el ? el.scrollHeight + 2 : 0; },
  rect: (id) => {
    const el = $(id);
    if (!el || el.offsetParent === null && getComputedStyle(el).position !== 'fixed') return '';
    const r = el.getBoundingClientRect();
    return [r.left, r.top, r.width, r.height].map((v) => v.toFixed(1)).join(',');
  },
  range_rect: rangeRect,
  reveal_line: revealLine,
  place_input: placeInput,
  scroll_into_view: (id) => { const el = $(id); if (el) el.scrollIntoView({ block: 'nearest' }); },
  viewport_width: () => window.innerWidth,
  char_width: (() => {
    const cache = new Map();
    const canvas = document.createElement('canvas').getContext('2d');
    return (px) => {
      if (!cache.has(px)) { canvas.font = `${px}px ${getComputedStyle(document.documentElement).getPropertyValue('--mono')}`; cache.set(px, canvas.measureText('0000000000').width / 10); }
      return cache.get(px);
    };
  })(),
  viewport_height: () => window.innerHeight,
  set_title: (t) => { if (document.title !== t) document.title = t; },
};

// ---- server API ----

// In-flight API calls; tests wait for zero before acting.
let inflight = 0;
window.readitIdle = () => inflight === 0;

async function api(method, body) {
  inflight++;
  try { return await request(method, body); } finally { inflight--; }
}

async function request(method, body) {
  const response = await fetch('/api/' + method, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-readit-token': token },
    body,
  });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response.text();
}

const app = {
  rpc: (id, method, body) => {
    api(method, body).then(
      (text) => exports && exports.rpc_done(id, true, text),
      (error) => exports && exports.rpc_done(id, false, 'サーバーに接続できません: ' + error.message),
    );
  },
  set_timer: (id, ms) => { timers.set(id, setTimeout(() => { timers.delete(id); exports.timer_fired(id); }, ms)); },
  clear_timer: (id) => { clearTimeout(timers.get(id)); timers.delete(id); },
  now: () => Date.now(),
  log: (t) => console.info('Readit:', t),
  clipboard_write: (t) => { navigator.clipboard?.writeText(t).catch(() => {}); },
  clipboard_read: () => {
    navigator.clipboard?.readText().then((text) => send('paste', { text }), () => {});
  },
  regex_find: (text, pattern, flags) => {
    try {
      const re = new RegExp(pattern, flags);
      const out = [];
      for (const m of text.matchAll(re)) {
        if (m[0].length === 0) continue;
        out.push(m.index + ',' + (m.index + m[0].length));
        if (out.length >= 5000) break;
      }
      return out.join(';');
    } catch (error) {
      return '!' + error.message;
    }
  },
  ts_update: (key, lang, text) => highlighter.update(key, lang, text),
  ts_tokens: (key, from, to) => highlighter.tokens(key, from, to),
  ts_drop: (key) => highlighter.drop(key),
  confirm_leave: (dirty) => { leaveGuard = !!dirty; },
  close_window: () => {
    document.body.innerHTML = '<div class="closed">Readitを終了しました。このタブは閉じてかまいません。</div>';
    window.close();
  },
};
const timers = new Map();
let leaveGuard = false;

// ---- Tree-sitter ----

const grammars = {
  python: { wasm: 'python', queries: ['python'] },
  rust: { wasm: 'rust', queries: ['rust'] },
  javascript: { wasm: 'javascript', queries: ['javascript'] },
  typescript: { wasm: 'typescript', queries: ['javascript', 'typescript'] },
  tsx: { wasm: 'tsx', queries: ['javascript', 'typescript'] },
  json: { wasm: 'json', queries: ['json'] },
  go: { wasm: 'go', queries: ['go'] },
  java: { wasm: 'java', queries: ['java'] },
  html: { wasm: 'html', queries: ['html'] },
  css: { wasm: 'css', queries: ['css'] },
  bash: { wasm: 'bash', queries: ['bash'] },
  c: { wasm: 'c', queries: ['c'] },
  cpp: { wasm: 'cpp', queries: ['c', 'cpp'] },
  ruby: { wasm: 'ruby', queries: ['ruby'] },
  toml: { wasm: 'toml', queries: ['toml'] },
  yaml: { wasm: 'yaml', queries: ['yaml'] },
  markdown: { wasm: 'markdown', queries: ['markdown'], inline: 'markdown_inline' },
  markdown_inline: { wasm: 'markdown_inline', queries: ['markdown_inline'] },
};

const highlighter = {
  ready: null,
  languages: new Map(),
  docs: new Map(),
  parser: null,
  init() {
    this.ready = Parser.init({ locateFile: () => 'vendor/tree-sitter.wasm' }).then(() => { this.parser = new Parser(); });
    return this.ready;
  },
  load(lang) {
    if (this.languages.has(lang)) return this.languages.get(lang);
    const spec = grammars[lang];
    const entry = { language: null, query: null, failed: false };
    this.languages.set(lang, entry);
    (async () => {
      await this.ready;
      const language = await Language.load(`grammars/${spec.wasm}.wasm`);
      const sources = await Promise.all(spec.queries.map((q) => fetch(`grammars/${q}.scm`).then((r) => r.text())));
      entry.query = new Query(language, sources.join('\n'));
      entry.language = language;
      send('highlight', { lang });
    })().catch((error) => { entry.failed = true; console.warn('Readit highlight', lang, error); });
    return entry;
  },
  update(key, lang, text) {
    if (!grammars[lang]) { this.docs.delete(key); return true; }
    const entry = this.load(lang);
    if (!entry.language) return false;
    const doc = this.docs.get(key);
    if (doc && doc.lang === lang && doc.text === text && !doc.pendingInline) return true;
    if (doc && doc.pendingInline && doc.text === text) {
      const inline = this.parseInline(lang, text, doc.tree, null);
      if (inline !== false) { doc.inline = inline; doc.pendingInline = false; doc.cache.clear(); }
      return true;
    }
    // A slow document (large, or mid-way through a syntax error) is re-parsed
    // after the frame; the previous tree colours it until then.
    if (doc && doc.lang === lang && doc.slow) {
      doc.wanted = text;
      if (!doc.scheduled) {
        doc.scheduled = true;
        setTimeout(() => {
          doc.scheduled = false;
          if (this.docs.get(key) !== doc || doc.wanted === doc.text) return;
          this.parse(key, lang, doc.wanted, doc);
          send('highlight', { key });
        }, 0);
      }
      return true;
    }
    this.parse(key, lang, text, doc);
    return true;
  },
  parse(key, lang, text, doc) {
    const entry = this.languages.get(lang);
    const started = performance.now();
    this.parser.setLanguage(entry.language);
    let tree;
    if (doc && doc.lang === lang && doc.tree) {
      // Describe the change as one edit so parsing stays incremental.
      const old = doc.text;
      let start = 0;
      const max = Math.min(old.length, text.length);
      while (start < max && old.charCodeAt(start) === text.charCodeAt(start)) start++;
      let oldEnd = old.length, newEnd = text.length;
      while (oldEnd > start && newEnd > start && old.charCodeAt(oldEnd - 1) === text.charCodeAt(newEnd - 1)) { oldEnd--; newEnd--; }
      const point = (s, i) => { let row = 0, last = -1; for (let k = 0; k < i; k++) if (s.charCodeAt(k) === 10) { row++; last = k; } return { row, column: i - last - 1 }; };
      doc.tree.edit({ startIndex: start, oldEndIndex: oldEnd, newEndIndex: newEnd,
        startPosition: point(old, start), oldEndPosition: point(old, oldEnd), newEndPosition: point(text, newEnd) });
      tree = this.parser.parse(text, doc.tree);
      doc.tree.delete();
    } else {
      if (doc && doc.tree) doc.tree.delete();
      tree = this.parser.parse(text);
    }
    const inline = this.parseInline(lang, text, tree, doc);
    const slow = performance.now() - started > 12;
    this.docs.set(key, { lang, text, tree, cache: new Map(), inline: inline === false ? null : inline, pendingInline: inline === false, slow });
  },
  // Markdown keeps inline syntax in a second grammar over the block tree's inline nodes.
  parseInline(lang, text, tree, doc) {
    const spec = grammars[lang];
    if (!spec.inline) return null;
    if (doc && doc.inline) doc.inline.delete();
    const entry = this.load(spec.inline);
    if (!entry.language) return false;
    const ranges = [];
    const visit = (node) => {
      if (node.type === 'inline') ranges.push({ startIndex: node.startIndex, endIndex: node.endIndex, startPosition: node.startPosition, endPosition: node.endPosition });
      else for (const child of node.children) visit(child);
    };
    visit(tree.rootNode);
    if (!ranges.length) return null;
    this.parser.setLanguage(entry.language);
    const result = this.parser.parse(text, null, { includedRanges: ranges });
    this.parser.setLanguage(this.languages.get(lang).language);
    return result;
  },
  tokens(key, from, to) {
    const doc = this.docs.get(key);
    if (!doc || !doc.tree) return '';
    const entry = this.languages.get(doc.lang);
    if (!entry || !entry.query) return '';
    const cacheKey = from + ':' + to;
    if (doc.cache.has(cacheKey)) return doc.cache.get(cacheKey);
    const range = { startPosition: { row: from, column: 0 }, endPosition: { row: to, column: 0 } };
    const captures = entry.query.captures(doc.tree.rootNode, range);
    const inlineEntry = grammars[doc.lang].inline && this.languages.get(grammars[doc.lang].inline);
    if (doc.inline && inlineEntry && inlineEntry.query) captures.push(...inlineEntry.query.captures(doc.inline.rootNode, range));
    // Paint per line; a later capture on the same span wins, nested nodes override parents.
    const lines = new Map();
    for (const { name, node } of captures) {
      if (name.startsWith('_') || name === 'spell' || name === 'none') continue;
      const parts = name.split('.');
      // Markdown names its kinds under text.* (text.title, text.literal, ...).
      const cls = 't-' + ((parts[0] === 'text' || parts[0] === 'markup') && parts[1] ? parts[1] : parts[0]);
      const s = node.startPosition, e = node.endPosition;
      for (let row = Math.max(s.row, from); row <= Math.min(e.row, to - 1); row++) {
        const a = row === s.row ? s.column : 0;
        const b = row === e.row ? e.column : 100000;
        if (b <= a) continue;
        let spans = lines.get(row);
        if (!spans) lines.set(row, (spans = []));
        spans.push([a, b, cls]);
      }
    }
    const out = [];
    for (const [row, spans] of lines) {
      const bounds = new Set([0]);
      for (const [a, b] of spans) { bounds.add(a); bounds.add(Math.min(b, 100000)); }
      const sorted = [...bounds].sort((x, y) => x - y);
      let prev = null;
      for (let i = 0; i + 1 < sorted.length; i++) {
        const a = sorted[i], b = sorted[i + 1];
        let cls = null, width = Infinity;
        for (const [sa, sb, c] of spans) {
          if (sa <= a && sb >= b && sb - sa <= width) { cls = c; width = sb - sa; }
        }
        if (!cls) { prev = null; continue; }
        if (prev && prev[2] === cls && prev[1] === a) prev[1] = b;
        else { prev = [a, b, cls]; out.push([row, prev]); }
      }
    }
    const text = out.map(([row, [a, b, c]]) => `${row},${a},${Math.min(b, 1000000)},${c}`).join(';');
    doc.cache.clear();
    doc.cache.set(cacheKey, text);
    return text;
  },
  drop(key) {
    const doc = this.docs.get(key);
    if (doc && doc.tree) doc.tree.delete();
    if (doc && doc.inline) doc.inline.delete();
    this.docs.delete(key);
  },
};

// ---- input ----

const shifted = { '{': '[', '}': ']', '_': '-', '+': '=', ')': '0', '!': '1' };
const codeKeys = { Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Semicolon: ';', Quote: "'", Comma: ',', Period: '.', Slash: '/', Backslash: '\\', Backquote: '`' };
const named = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Enter: 'enter', Escape: 'escape',
  Backspace: 'backspace', Delete: 'delete', Tab: 'tab', Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown', ' ': 'space' };

function keyDescriptor(e) {
  let key;
  if (named[e.key]) key = named[e.key];
  else if (/^F\d{1,2}$/.test(e.key)) key = e.key.toLowerCase();
  else if (e.code.startsWith('Key')) key = e.code.slice(3).toLowerCase();
  else if (e.code.startsWith('Digit')) key = e.code.slice(5);
  else if (e.altKey && codeKeys[e.code]) key = codeKeys[e.code];
  else key = e.key.length === 1 ? (shifted[e.key] ?? e.key.toLowerCase()) : e.key.toLowerCase();
  const mods = [];
  if (e.ctrlKey) mods.push('ctrl');
  if (e.metaKey) mods.push('cmd');
  if (e.altKey) mods.push('alt');
  if (e.shiftKey) mods.push('shift');
  return [...mods, key].join('-');
}

function focusTarget(el) {
  if (!el || el === document.body) return 'body';
  switch (el.id) {
    case 'editor-input': return 'editor';
    case 'dialog-query': return 'dialog-query';
    case 'dialog-replacement': return 'dialog-replacement';
    case 'search-input': return 'search-input';
    case 'guide-question': return 'guide-question';
  }
  if (el.closest && el.closest('#sidebar')) return 'explorer';
  if (el.closest && el.closest('#overlay')) return 'dialog';
  return 'body';
}

const focusNames = { editor: 'editor', 'dialog-query': 'query', 'dialog-replacement': 'query', 'search-input': 'search',
  'guide-question': 'guide-question', explorer: 'explorer', dialog: 'dialog', body: 'body' };

let lastPointer = { x: 0, y: 0, over: null };
let composing = false;

function editorHit(x, y, clamp = false) {
  const area = $('editor-scroll');
  if (!area || area.style.display === 'none') return null;
  const b = area.getBoundingClientRect();
  if (clamp) {
    // A drag selection keeps following the pointer outside the editor.
    x = Math.min(Math.max(x, b.left + 1), b.left + area.clientWidth - 2);
    y = Math.min(Math.max(y, b.top + 1), b.top + area.clientHeight - 2);
  }
  if (x < b.left || x >= b.left + area.clientWidth || y < b.top || y >= b.top + area.clientHeight) return null;
  return hitTest('editor', x, y);
}

let selecting = false;

function wire() {
  window.addEventListener('keydown', (e) => {
    if (['Meta', 'Shift', 'Alt', 'Control'].includes(e.key)) {
      if (e.key === 'Meta') send('modifiers', { meta: true, over: !!lastPointer.over, line: lastPointer.over?.line ?? 0, glyph: lastPointer.over?.glyph ?? -1 });
      return;
    }
    if (e.isComposing || composing || e.keyCode === 229) return;
    const target = focusTarget(document.activeElement);
    if (send('key', { desc: keyDescriptor(e), target })) { e.preventDefault(); e.stopPropagation(); }
  }, true);
  window.addEventListener('keyup', (e) => { if (e.key === 'Meta') send('modifiers', { meta: false }); }, true);

  const input = $('editor-input');
  input.addEventListener('compositionstart', () => { composing = true; input.classList.add('composing'); });
  input.addEventListener('compositionend', (e) => {
    composing = false; input.classList.remove('composing');
    const text = e.data || input.value; input.value = '';
    if (text) send('text', { text });
  });
  input.addEventListener('input', (e) => {
    if (composing || e.isComposing) return;
    const text = input.value; input.value = '';
    if (text) send('text', { text });
  });
  input.addEventListener('copy', (e) => { e.preventDefault(); e.clipboardData.setData('text/plain', exports.copy_text(false)); });
  input.addEventListener('cut', (e) => { e.preventDefault(); e.clipboardData.setData('text/plain', exports.copy_text(true)); });
  input.addEventListener('paste', (e) => { e.preventDefault(); send('paste', { text: e.clipboardData.getData('text/plain') }); });

  for (const id of ['dialog-query', 'dialog-replacement', 'search-input', 'guide-question']) {
    document.addEventListener('input', (e) => { if (e.target.id === id) send('input', { id, value: e.target.value }); });
  }
  document.addEventListener('focusin', (e) => send('focus', { target: focusNames[focusTarget(e.target)] ?? 'body' }));

  // Clicks are matched by action rather than element: a redraw between press and
  // release replaces the element, which would swallow a native click.
  let pressed = null;
  window.addEventListener('mousedown', (e) => {
    const actor = e.button === 0 && e.target.closest('[data-act]');
    pressed = actor ? { act: actor.dataset.act, arg: actor.dataset.arg ?? '' } : null;
    if (!e.target.closest('.menu-list') && !e.target.closest('.menu-title')) send('act', { act: 'close-menus' });
    const drag = e.target.closest('[data-drag]');
    if (drag && e.button === 0) { send('drag-start', { kind: drag.dataset.drag, x: e.clientX, y: e.clientY }); e.preventDefault(); return; }
    if (e.target.closest('#sidebar-resize') && e.button === 0) { send('drag-start', { kind: 'sidebar', x: e.clientX, y: e.clientY }); e.preventDefault(); return; }
    if (e.button === 1 && e.target.closest('[data-tab]')) { e.preventDefault(); send('act', { act: 'close-tab', arg: e.target.closest('[data-tab]').dataset.tab }); return; }
    // Decide before sending: the event re-renders rows and detaches e.target.
    selecting = e.button === 0 && !!e.target.closest('#editor-content') && !e.metaKey;
    if (e.button === 0 && e.target.closest('#editor-content')) {
      const hit = editorHit(e.clientX, e.clientY);
      if (hit) {
        e.preventDefault();
        $('editor-input').focus({ preventScroll: true });
        send('editor-down', { ...hit, detail: e.detail, shift: e.shiftKey, meta: e.metaKey, alt: e.altKey, x: e.clientX, y: e.clientY });
      }
    }
  }, true);

  let moveFrame = 0, moveEvent = null;
  const flushMove = () => {
    moveFrame = 0;
    const ev = moveEvent;
    if (!ev) return;
    moveEvent = null;
    const dragging = selecting && ev.buttons === 1;
    const hit = dragging ? editorHit(ev.clientX, ev.clientY, true)
      : ev.target.closest && ev.target.closest('#editor-content') ? editorHit(ev.clientX, ev.clientY) : null;
    lastPointer = { x: ev.clientX, y: ev.clientY, over: dragging ? null : hit };
    if (hit) send('editor-move', { ...hit, x: ev.clientX, y: ev.clientY, buttons: ev.buttons, meta: ev.metaKey });
    send('mouse-move', { x: ev.clientX, y: ev.clientY, buttons: ev.buttons, editor: !!hit });
  };
  // While drag-selecting past the editor's top or bottom edge, keep scrolling.
  let edgeTimer = 0;
  const edgeScroll = () => {
    const area = $('editor-scroll');
    if (!selecting || !moveEvent && !lastDrag) { edgeTimer = 0; return; }
    const ev = moveEvent || lastDrag;
    const b = area.getBoundingClientRect();
    const dy = ev.clientY < b.top ? ev.clientY - b.top : ev.clientY > b.bottom ? ev.clientY - b.bottom : 0;
    if (dy === 0) { edgeTimer = 0; return; }
    area.scrollTop += Math.max(-60, Math.min(60, dy));
    // Rows for the new scroll position render on the scroll event; hit-test after it.
    requestAnimationFrame(() => { if (selecting) { moveEvent = ev; flushMove(); } });
    edgeTimer = setTimeout(edgeScroll, 30);
  };
  let lastDrag = null;
  window.addEventListener('mousemove', (e) => {
    moveEvent = e;
    if (selecting && e.buttons === 1) { lastDrag = e; if (!edgeTimer) edgeTimer = setTimeout(edgeScroll, 30); }
    if (!moveFrame) moveFrame = requestAnimationFrame(flushMove);
  }, true);
  window.addEventListener('mouseup', () => { selecting = false; lastDrag = null; clearTimeout(edgeTimer); edgeTimer = 0; }, true);
  window.addEventListener('mouseup', (e) => {
    // Apply the last move before the release, so a quick drop lands where it was dragged.
    if (moveFrame) { cancelAnimationFrame(moveFrame); flushMove(); }
    const hit = editorHit(e.clientX, e.clientY);
    send('mouse-up', { x: e.clientX, y: e.clientY, meta: e.metaKey, editor: !!hit, line: hit?.line ?? 0, glyph: hit?.glyph ?? -1 });
  }, true);
  window.addEventListener('mouseup', (e) => {
    const was = pressed;
    pressed = null;
    if (!was || e.button !== 0) return;
    const under = document.elementFromPoint(e.clientX, e.clientY);
    const el = under && under.closest('[data-act]');
    if (el && el.dataset.act === was.act && (el.dataset.arg ?? '') === was.arg) {
      send('act', { act: was.act, arg: was.arg, x: e.clientX, y: e.clientY, meta: e.metaKey });
    }
  });
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-act]');
    if (!el) return;
    e.preventDefault();
    // Pointer clicks were handled on release; this path is keyboard activation.
    if (e.detail !== 0) return;
    send('act', { act: el.dataset.act, arg: el.dataset.arg ?? '', x: 0, y: 0, meta: false });
  });
  document.addEventListener('contextmenu', (e) => {
    const row = e.target.closest('[data-tree]');
    if (!row) return;
    e.preventDefault();
    send('context', { path: row.dataset.tree, x: e.clientX, y: e.clientY });
  });
  const frames = new Map();
  document.addEventListener('scroll', (e) => {
    const id = e.target.id;
    if (!id || frames.has(id)) return;
    frames.set(id, requestAnimationFrame(() => { frames.delete(id); send('scroll', { id }); }));
  }, true);
  window.addEventListener('resize', () => send('resize', {}));
  window.addEventListener('focus', () => send('window-focus', {}));
  window.addEventListener('beforeunload', (e) => {
    if (leaveGuard && exports && exports.has_unsaved()) { e.preventDefault(); e.returnValue = ''; }
  });
}

function connectEvents() {
  const source = new EventSource('/api/events?token=' + encodeURIComponent(token));
  source.onopen = () => send('stream', { state: 'open' });
  source.addEventListener('control', (e) => send('control', JSON.parse(e.data)));
  source.addEventListener('superseded', () => { send('stream', { state: 'superseded' }); source.close(); });
  source.onerror = () => send('stream', { state: 'error' });
}

// ---- boot ----

async function loadWasm() {
  const options = { builtins: ['js-string'], importedStringConstants: '_' };
  const bytes = await (await fetch('app.wasm')).arrayBuffer();
  if (!WebAssembly.validate(bytes, options)) throw new Error('このブラウザはWasm GCとJS文字列組み込みに未対応です');
  const module = await WebAssembly.compile(bytes, options);
  const instance = await WebAssembly.instantiate(module, {
    dom, app,
    spectest: { print_char: (c) => console.log(String.fromCharCode(c)) },
  });
  return instance.exports;
}

async function main() {
  try {
    highlighter.init();
    exports = await loadWasm();
    wire();
    const session = await api('session.start', '{}');
    const parsed = JSON.parse(session);
    if (!parsed.ok) throw new Error(parsed.error);
    exports.boot(JSON.stringify(parsed.result));
    connectEvents();
    window.readitReady = true;
  } catch (error) {
    showFatal(error);
    throw error;
  }
}

main();
