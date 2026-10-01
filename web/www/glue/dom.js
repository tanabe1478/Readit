// DOM operations imported by the wasm app ("dom" namespace).
import { $ } from './bridge.js';
import { rangeRect } from './hit.js';

const html = new Map();
function setHtml(id, value) {
  if (html.get(id) === value) return;
  const el = $(id);
  if (!el) return;
  html.set(id, value);
  el.innerHTML = value;
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

export const dom = {
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
