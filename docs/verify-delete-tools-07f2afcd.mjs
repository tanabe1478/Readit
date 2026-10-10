// Run ONCE with pi-browser run. Public fixture only. No real IME/finger claim.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const fixture = path.join(repo, '.verify-preview-07f2afcd');
const file = path.join(fixture, 'verify-delete-tools.txt');
const receiptFile = path.join(repo, '.verify-runtime-07f2afcd/delete-tools-receipt.json');
const initial = Buffer.from('日本語ABC\n', 'utf8');
const final = Buffer.from('C\n', 'utf8');

export default async ({ page }) => {
  // Exclusive receipt prevents unsafe repeat even after interruption.
  const receipt = { status: 'running', stage: 'preflight', events: [], startedAt: new Date().toISOString() };
  fs.writeFileSync(receiptFile, JSON.stringify(receipt, null, 2), { flag: 'wx', mode: 0o600 });
  const record = (stage, details = {}) => {
    receipt.stage = stage; receipt.events.push({ stage, at: new Date().toISOString(), ...details });
    fs.writeFileSync(receiptFile, JSON.stringify(receipt, null, 2), { mode: 0o600 });
  };
  const assert = (value, message) => { if (!value) throw Error(message); };
  const dirty = () => page.evaluate(async () => {
    const { wasm } = await import('/glue/bridge.js');
    return !!wasm.exports.has_unsaved(); // Do not return token/other bridge state.
  });
  const text = () => page.evaluate(() => {
    const code = document.querySelector('#editor-content .row[data-line="0"] .code');
    if (!code) return null;
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT,
      { acceptNode: n => n.parentElement.closest('.eol') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
    let result = ''; for (let n = walker.nextNode(); n; n = walker.nextNode()) result += n.data;
    return result; // Only our selected public file.
  });
  const diskIs = expected => fs.readFileSync(file).equals(expected);
  const key = (input, name, shift = false) => input.evaluate((el, [name, shift]) => {
    const code = name === 'Home' ? 36 : 39;
    const event = new KeyboardEvent('keydown', { key: name, code: name, keyCode: code,
      shiftKey: shift, bubbles: true, cancelable: true });
    el.dispatchEvent(event);
    return event.defaultPrevented;
  }, [name, shift]);
  const deletion = (input, inputType) => input.evaluate((el, inputType) => {
    el.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Unidentified', code: '', keyCode: 229, bubbles: true, cancelable: true,
    }));
    const event = new InputEvent('beforeinput', { inputType, cancelable: true, bubbles: true, composed: true });
    el.dispatchEvent(event);
    return { inputType: event.inputType, isInputEvent: event instanceof InputEvent, prevented: event.defaultPrevented };
  }, inputType);
  try {
    assert(page.url() === 'http://127.0.0.1:42843/', 'STOP: unexpected preview URL');
    await page.waitForFunction(() => window.readitReady === true && window.readitIdle(), { timeout: 10000 });
    const before = await dirty(); record('clean-preflight', { dirty: before });
    assert(!before, 'STOP: unsaved edits present');
    record('create-fixture-pending');
    fs.writeFileSync(file, initial, { flag: 'wx', mode: 0o600 });
    record('fixture-created', { initialHex: initial.toString('hex') });
    assert(!await dirty(), 'STOP: became dirty before reload');
    record('reload-pending');
    await page.reload({ timeout: 10000 }); // Once, only after clean check.
    await page.waitForFunction(() => window.readitReady === true && window.readitIdle(), { timeout: 10000 });
    record('reloaded');
    record('open-drawer-pending');
    await page.locator('#topbar [data-act="sidebar"]').click({ timeout: 5000 });
    record('select-public-file-pending');
    await page.locator('.tree-row[data-tree="verify-delete-tools.txt"]').click({ timeout: 5000 });
    await page.waitForFunction(() => window.readitIdle(), { timeout: 10000 });
    assert(await page.locator('#tab-selected').textContent().then(t => t.includes('verify-delete-tools.txt')), 'Wrong selected file');
    assert(await text() === '日本語ABC', 'Initial public document mismatch');
    assert(diskIs(initial), 'Initial disk mismatch');
    record('file-opened', { dirty: await dirty() });
    const input = page.locator('#editor-input');
    await input.focus();
    record('backward-caret-pending');
    assert(await key(input, 'Home'), 'Home not consumed');
    for (let i = 0; i < 4; i++) assert(await key(input, 'ArrowRight'), 'Right not consumed');
    for (const step of [
      { stage: 'backward', inputType: 'deleteContentBackward', expected: '日本語BC' },
      { stage: 'forward', inputType: 'deleteContentForward', expected: '日本語C' },
      { stage: 'selection', inputType: 'deleteContentBackward', expected: 'C', select: true },
    ]) {
      record(step.stage + '-pending');
      if (step.select) {
        assert(await key(input, 'Home'), 'Selection Home not consumed');
        for (let i = 0; i < 3; i++) assert(await key(input, 'ArrowRight', true), 'Selection Right not consumed');
      }
      const event = await deletion(input, step.inputType);
      assert(event.isInputEvent && event.inputType === step.inputType && event.prevented, 'Deletion event not consumed');
      await page.waitForFunction(() => window.readitIdle(), { timeout: 10000 });
      const observed = await text(), unsaved = await dirty();
      assert(observed === step.expected, step.stage + ' document mismatch: ' + observed);
      assert(unsaved, step.stage + ' did not mark dirty');
      assert(diskIs(initial), step.stage + ' changed disk before save');
      record(step.stage + '-verified', { event, observed, dirty: unsaved, diskUnchanged: true });
    }
    record('save-menu-pending');
    await page.locator('#topbar .menu-title[data-arg="ファイル"]').click({ timeout: 5000 });
    record('save-pending');
    await page.locator('.menu-item[data-arg="save"]').click({ timeout: 5000 }); // Exactly once.
    for (let i = 0; i < 100 && !diskIs(final); i++) await new Promise(r => setTimeout(r, 100));
    assert(diskIs(final), 'Saved UTF-8 bytes mismatch');
    await page.waitForFunction(async () => {
      const { wasm } = await import('/glue/bridge.js');
      return window.readitIdle() && !wasm.exports.has_unsaved();
    }, { timeout: 10000 });
    assert(await text() === 'C', 'Final rendered text mismatch');
    assert(!await dirty(), 'Final dirty state');
    record('save-verified', { finalHex: fs.readFileSync(file).toString('hex'), dirty: false });
    receipt.status = 'success'; record('complete');
    console.log(JSON.stringify({ status: receipt.status, stage: receipt.stage, finalHex: '430a', dirty: false }));
  } catch (error) {
    receipt.status = 'failed'; receipt.error = String(error.message || error);
    record(receipt.stage + '-failed');
    console.log(JSON.stringify({ status: receipt.status, stage: receipt.stage, error: receipt.error }));
    throw error; // STOP, do not rerun this script.
  }
};
