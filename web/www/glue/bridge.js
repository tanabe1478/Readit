// Shared by the glue modules: the wasm exports and a way to send it events.
export const token = document.querySelector('meta[name="readit-token"]').content;
export const $ = (id) => document.getElementById(id);
/** Filled in by main.js once the module is instantiated. */
export const wasm = { exports: null };

export const send = (kind, data) => {
  if (!wasm.exports) return false;
  try {
    return !!wasm.exports.on_event(kind, JSON.stringify(data ?? {}));
  } catch (error) {
    console.error('Readit event failed', kind, error);
    showFatal(error);
    return false;
  }
};

export function showFatal(error) {
  const box = $('fatal');
  if (!box) return;
  box.style.display = 'block';
  box.textContent = 'Readitで内部エラーが発生しました。再読み込みしてください。\n' + (error && error.stack || error);
}
