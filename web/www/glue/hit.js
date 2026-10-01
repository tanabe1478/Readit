// Screen positions to line/column and back, for rendered code views.
import { $ } from './bridge.js';

export function codeLine(view, line) {
  return document.querySelector(`.lines[data-view="${view}"] .row[data-line="${line}"] .code`);
}

// Text nodes of a rendered line, excluding the caret and end-of-line markers.
export function lineNodes(code) {
  const nodes = [];
  const walk = document.createTreeWalker(code, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.parentElement.closest('.eol') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
  });
  for (let n = walk.nextNode(); n; n = walk.nextNode()) nodes.push(n);
  return nodes;
}

export function locate(nodes, offset) {
  let at = 0;
  for (const n of nodes) {
    if (offset <= at + n.length) return [n, offset - at];
    at += n.length;
  }
  const last = nodes[nodes.length - 1];
  return last ? [last, last.length] : null;
}

export function lineLength(nodes) {
  return nodes.reduce((a, n) => a + n.length, 0);
}

export function rectOf(nodes, start, end) {
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
export function rangeRect(view, line, start, end) {
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

export function caretFromPoint(x, y) {
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    return p ? [p.offsetNode, p.offset] : null;
  }
  const r = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
  return r ? [r.startContainer, r.startOffset] : null;
}

// Line and UTF-16 column under a point, plus the column of the glyph actually
// under it (-1 over blank space or gutters).
export function hitTest(view, x, y) {
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

export function editorHit(x, y, clamp = false) {
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
