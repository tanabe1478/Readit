// Tree-sitter highlighting: incremental parses, and spans for the rendered lines.
import { Parser, Language, Query } from '../vendor/tree-sitter.js';
import { send } from './bridge.js';

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
  moonbit: { wasm: 'moonbit', queries: ['moonbit'] },
  markdown_inline: { wasm: 'markdown_inline', queries: ['markdown_inline'] },
};

export const highlighter = {
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
