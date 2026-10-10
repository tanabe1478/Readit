// Wiring-only tests, NOT a browser/IME or MoonBit editor substitute.
// Run: node --experimental-vm-modules --test tests/unit/input.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

async function setup() {
  class Target {
    listeners = new Map();
    value = '';
    id = 'editor-input';
    classList = { add() {}, remove() {} };
    addEventListener(type, fn) {
      const list = this.listeners.get(type) ?? [];
      list.push(fn); this.listeners.set(type, list);
    }
    fire(type, fields = {}) {
      const e = { key: 'Unidentified', code: '', keyCode: 229, cancelable: true,
        defaultPrevented: false, preventDefault() { if (this.cancelable) this.defaultPrevented = true; },
        stopPropagation() {}, ...fields };
      for (const fn of this.listeners.get(type) ?? []) fn(e);
      return e;
    }
  }
  const input = new Target(), window = new Target(), document = new Target();
  document.activeElement = input;
  const events = [];
  const context = vm.createContext({ window, document });
  const deps = {
    './bridge.js': { $: () => input, token: '', wasm: {}, send: (kind, args) => { events.push([kind, { ...args }]); return true; } },
    './hit.js': { editorHit() {} }, './dom.js': { placeInput() {} }, './server.js': { leaving() {} },
  };
  const mod = new vm.SourceTextModule(await fs.readFile(new URL('../../www/glue/input.js', import.meta.url), 'utf8'), { context });
  await mod.link(async (name) => {
    const exports = deps[name];
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    }, { context });
  });
  await mod.evaluate(); mod.namespace.wire();
  return { input, window, events };
}

for (const [inputType, desc] of [['deleteContentBackward', 'backspace'], ['deleteContentForward', 'delete']]) {
  test(`229 + ${inputType} forwards one editor deletion from an empty input`, async () => {
    const { input, window, events } = await setup();
    window.fire('keydown');
    const e = input.fire('beforeinput', { inputType });
    assert.equal(e.defaultPrevented, true);
    assert.deepEqual(events, [['key', { desc, target: 'editor' }]]);
    assert.equal(input.value, '');
  });
  test(`${inputType} noncancelable notification is not doubled by input`, async () => {
    const { input, events } = await setup();
    input.fire('beforeinput', { inputType, cancelable: false });
    input.fire('input', { inputType });
    assert.deepEqual(events, [['key', { desc, target: 'editor' }]]);
  });
}
test('composition deletion belongs to the IME, not the document', async () => {
  const { input, events } = await setup();
  input.fire('compositionstart');
  assert.equal(input.fire('beforeinput', { inputType: 'deleteContentBackward' }).defaultPrevented, false);
  input.fire('compositionend', { data: '日本語' });
  assert.deepEqual(events, [['text', { text: '日本語' }]]);
});
test('isComposing deletion and unrelated beforeinput remain native', async () => {
  const { input, events } = await setup();
  input.fire('beforeinput', { inputType: 'deleteContentBackward', isComposing: true });
  input.fire('beforeinput', { inputType: 'insertText', data: 'a' });
  input.value = 'a'; input.fire('input', { inputType: 'insertText' });
  assert.deepEqual(events, [['text', { text: 'a' }]]);
});
test('desktop Backspace is consumed on keydown without a native edit', async () => {
  const { window, events } = await setup();
  assert.equal(window.fire('keydown', { key: 'Backspace', keyCode: 8 }).defaultPrevented, true);
  assert.deepEqual(events, [['key', { desc: 'backspace', target: 'editor' }]]);
});
