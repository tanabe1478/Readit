// Calls to the local server and the other imports of the "app" namespace.
import { token, send, wasm } from './bridge.js';
import { highlighter } from './highlight.js';

// In-flight API calls; tests wait for zero before acting.
let inflight = 0;
window.readitIdle = () => inflight === 0;

export async function api(method, body) {
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

export const app = {
  rpc: (id, method, body) => {
    api(method, body).then(
      (text) => wasm.exports && wasm.exports.rpc_done(id, true, text),
      (error) => wasm.exports && wasm.exports.rpc_done(id, false, 'サーバーに接続できません: ' + error.message),
    );
  },
  set_timer: (id, ms) => { timers.set(id, setTimeout(() => { timers.delete(id); wasm.exports.timer_fired(id); }, ms)); },
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
/** Whether leaving the page should ask first (unsaved edits). */
export const leaving = () => leaveGuard;
