// Boot: load the wasm-gc app with JS String Builtins, wire input, start.
import { wasm, showFatal } from './bridge.js';
import { dom } from './dom.js';
import { app, api } from './server.js';
import { highlighter } from './highlight.js';
import { wire, connectEvents } from './input.js';

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
    wasm.exports = await loadWasm();
    wire();
    const session = await api('session.start', '{}');
    const parsed = JSON.parse(session);
    if (!parsed.ok) throw new Error(parsed.error);
    wasm.exports.boot(JSON.stringify(parsed.result));
    connectEvents();
    window.readitReady = true;
  } catch (error) {
    showFatal(error);
    throw error;
  }
}

main();
