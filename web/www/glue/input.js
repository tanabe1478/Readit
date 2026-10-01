// Browser input wiring: keys, text/IME, clipboard, mouse, focus, scroll, and
// the server's control stream. Everything is forwarded to the app as events.
import { $, token, send, wasm } from './bridge.js';
import { editorHit } from './hit.js';
import { leaving } from './server.js';

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
    case 'guide-prediction': return 'guide-prediction';
  }
  if (el.closest && el.closest('#sidebar')) return 'explorer';
  if (el.closest && el.closest('#overlay')) return 'dialog';
  return 'body';
}

const focusNames = { editor: 'editor', 'dialog-query': 'query', 'dialog-replacement': 'query', 'search-input': 'search',
  'guide-question': 'guide-question', 'guide-prediction': 'guide-prediction', explorer: 'explorer', dialog: 'dialog', body: 'body' };

let lastPointer = { x: 0, y: 0, over: null };
let composing = false;
let selecting = false;

export function wire() {
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
  input.addEventListener('copy', (e) => { e.preventDefault(); e.clipboardData.setData('text/plain', wasm.exports.copy_text(false)); });
  input.addEventListener('cut', (e) => { e.preventDefault(); e.clipboardData.setData('text/plain', wasm.exports.copy_text(true)); });
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
    if (leaving() && wasm.exports && wasm.exports.has_unsaved()) { e.preventDefault(); e.returnValue = ''; }
  });
}

export function connectEvents() {
  const source = new EventSource('/api/events?token=' + encodeURIComponent(token));
  source.onopen = () => send('stream', { state: 'open' });
  source.addEventListener('control', (e) => send('control', JSON.parse(e.data)));
  source.addEventListener('superseded', () => { send('stream', { state: 'superseded' }); source.close(); });
  source.onerror = () => send('stream', { state: 'error' });
}
