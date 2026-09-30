import fs from 'node:fs';
import path from 'node:path';
import { test, expect, lineText, clickText } from './fixture.js';

test.use({ files: { 'a.py': 'value = 1\nif value:\n    print(value)\n', 'b.txt': '日本語😀 text\nsecond\n' } });

test('typing, undo and redo edit the buffer without saving', async ({ page, readit }) => {
  await expect(page.locator('.tab.selected')).toContainText('a.py');
  await clickText(page, 0, '1', { after: true });
  await page.keyboard.type('23');
  expect(await lineText(page, 0)).toBe('value = 123');
  await expect(page.locator('.tab.selected .dirty')).toHaveText('●');
  await page.keyboard.press('Meta+z');
  expect(await lineText(page, 0)).toBe('value = 1');
  await page.keyboard.press('Meta+Shift+z');
  expect(await lineText(page, 0)).toBe('value = 123');
  expect(fs.readFileSync(path.join(readit.project, 'a.py'), 'utf8')).toBe('value = 1\nif value:\n    print(value)\n');
});

test('enter keeps indentation and tab indents selected lines', async ({ page }) => {
  await clickText(page, 2, 'print(value)');
  await page.keyboard.press('End');
  await page.keyboard.press('Enter');
  await page.keyboard.type('x');
  expect(await lineText(page, 3)).toBe('    x');
  await page.keyboard.press('Meta+ArrowUp');
  await page.keyboard.press('Shift+ArrowDown');
  await page.keyboard.press('Tab');
  expect(await lineText(page, 0)).toBe('    value = 1');
  expect(await lineText(page, 1)).toBe('if value:');
  await page.keyboard.press('Shift+Tab');
  expect(await lineText(page, 0)).toBe('value = 1');
});

test('save writes the file and refuses to overwrite external changes', async ({ page, readit }) => {
  const file = path.join(readit.project, 'a.py');
  await clickText(page, 0, '1', { after: true });
  await page.keyboard.type('0');
  await page.keyboard.press('Meta+s');
  await expect(page.locator('#status')).toContainText('保存しました · a.py');
  expect(fs.readFileSync(file, 'utf8').startsWith('value = 10\n')).toBe(true);
  await expect(page.locator('.tab.selected .dirty')).toHaveText('');
  fs.writeFileSync(file, 'external\n');
  await page.keyboard.type('0');
  await page.keyboard.press('Meta+s');
  await expect(page.locator('#status')).toContainText('外部でファイルが変更されました');
  expect(fs.readFileSync(file, 'utf8')).toBe('external\n');
});

test('unicode columns: surrogate pairs move as one character', async ({ page }) => {
  await page.locator('.tree-row', { hasText: 'b.txt' }).click();
  await expect(page.locator('.tab.selected')).toContainText('b.txt');
  await clickText(page, 0, '😀');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 4');
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 6');
  await page.keyboard.press('Backspace');
  expect(await lineText(page, 0)).toBe('日本語 text');
});

test('find in file highlights matches and steps through them', async ({ page }) => {
  await page.keyboard.press('Meta+f');
  await page.keyboard.type('value');
  await expect(page.locator('.match')).toHaveCount(3);
  await expect(page.locator('#search-controls')).toContainText('1 / 3');
  await page.keyboard.press('Enter');
  await expect(page.locator('#search-controls')).toContainText('2 / 3');
  await page.locator('button[data-act="search-case"]').click();
  await page.locator('#search-input').fill('VALUE');
  await expect(page.locator('#search-controls')).toContainText('一致なし');
  await page.keyboard.press('Escape');
  await expect(page.locator('#search-bar')).toBeHidden();
});

test('replace next and replace all, undoable', async ({ page }) => {
  await page.keyboard.press('Meta+Alt+f');
  await page.locator('#dialog-query').fill('value');
  await page.locator('#dialog-replacement').fill('amount');
  await page.locator('button[data-act="replace-all"]').click();
  await expect(page.locator('#dialog-body')).toContainText('3件を置換しました');
  await page.keyboard.press('Escape');
  expect(await lineText(page, 0)).toBe('amount = 1');
  expect(await lineText(page, 2)).toBe('    print(amount)');
  await page.keyboard.press('Meta+z');
  expect(await lineText(page, 0)).toBe('value = 1');
});

test('go to line, quick open and command palette', async ({ page }) => {
  await page.keyboard.press('Control+g');
  await page.keyboard.type('3:5');
  await page.keyboard.press('Enter');
  await expect(page.locator('#status')).toContainText('Ln 3, Col 5');
  await page.keyboard.press('Meta+p');
  await page.keyboard.type('bt');
  await expect(page.locator('.pick.selected')).toContainText('b.txt');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tab.selected')).toContainText('b.txt');
  await page.keyboard.press('Meta+Shift+p');
  await page.keyboard.type('折返し');
  await page.keyboard.press('Enter');
  await expect(page.locator('#status')).toContainText('Wrap');
  await expect(page.locator('.lines.wrap')).toHaveCount(1);
});

test('closing a dirty tab asks before discarding', async ({ page, readit }) => {
  await clickText(page, 0, '1', { after: true });
  await page.keyboard.type('9');
  await page.locator('.tab.selected .tab-close').click();
  await expect(page.locator('#dialog-body')).toContainText('変更を保存しますか？');
  await page.locator('button[data-act="confirm-cancel"]').click();
  await expect(page.locator('.tab.selected')).toContainText('a.py');
  await page.locator('.tab.selected .tab-close').click();
  await page.locator('button[data-act="confirm-discard"]').click();
  await expect(page.locator('#tabs')).not.toContainText('a.py');
  expect(fs.readFileSync(path.join(readit.project, 'a.py'), 'utf8').startsWith('value = 1\n')).toBe(true);
  // Reopen restores the saved text, not the discarded edit.
  await page.keyboard.press('Control+Shift+t');
  await expect(page.locator('.tab.selected')).toContainText('a.py');
  expect(await lineText(page, 0)).toBe('value = 1');
});

test('text input from an IME commit and paste go through the hidden input', async ({ page }) => {
  await clickText(page, 0, '1', { after: true });
  await page.keyboard.insertText('日本');
  expect(await lineText(page, 0)).toBe('value = 1日本');
  await page.evaluate(() => {
    const input = document.getElementById('editor-input');
    const data = new DataTransfer();
    data.setData('text/plain', '\nnext');
    input.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
  });
  expect(await lineText(page, 1)).toBe('next');
});

test.describe('long documents', () => {
  const text = Array.from({ length: 300 }, (_, i) => `line_${i} = ${i}\n`).join('');
  const many = Object.fromEntries(Array.from({ length: 14 }, (_, i) => [`file_${String(i).padStart(2, '0')}.py`, `x = ${i}\n`]));
  test.use({ files: { 'long.py': text, ...many } });

  test('dragging past the bottom edge keeps selecting and scrolling', async ({ page }) => {
    await page.locator('.tree-row', { hasText: 'long.py' }).click();
    await expect(page.locator('.tab.selected')).toContainText('long.py');
    await clickText(page, 2, 'line_2');
    const area = await page.locator('#editor-scroll').boundingBox();
    await page.mouse.down();
    await page.mouse.move(area.x + 200, area.y + area.height + 40, { steps: 3 });
    // Each tick scrolls by the distance past the edge; wait for well over a screen.
    await expect.poll(() => page.locator('#editor-scroll').evaluate((el) => el.scrollTop)).toBeGreaterThan(900);
    await page.mouse.up();
    const status = await page.locator('#status').innerText();
    const line = Number(/Ln (\d+)/.exec(status)[1]);
    // One screen is about 32 lines; the selection end must follow the scroll.
    expect(line).toBeGreaterThan(60);
  });

  test('scrolling the pick list by hand is not undone, and the selected tab stays visible', async ({ page }) => {
    for (let i = 0; i < 14; i++) {
      await page.locator('.tree-row', { hasText: `file_${String(i).padStart(2, '0')}.py` }).click();
    }
    await expect(page.locator('#tab-selected')).toContainText('file_13.py');
    await expect(page.locator('#tab-selected')).toBeInViewport();
    await page.keyboard.press('Meta+p');
    await page.mouse.move(700, 300);
    await page.mouse.wheel(0, 400);
    await expect.poll(() => page.locator('#picks').evaluate((el) => el.scrollTop)).toBeGreaterThan(100);
    await page.waitForTimeout(200);
    expect(await page.locator('#picks').evaluate((el) => el.scrollTop)).toBeGreaterThan(100);
  });
});

test('double click selects a word even though the input sits at the caret', async ({ page }) => {
  const box = await (async () => { for (;;) { const b = await import('./fixture.js').then((m) => m.textBox(page, 2, 'print')); if (b) return b; await page.waitForTimeout(50); } })();
  await page.mouse.dblclick(box.x + 5, box.y + box.height / 2);
  await page.keyboard.type('show');
  expect(await lineText(page, 2)).toBe('    show(value)');
});

test('the Edit menu pastes from the clipboard', async ({ page, context, browserName }) => {
  test.skip(browserName !== 'chromium', 'clipboard permissions can only be granted in Chromium');
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.evaluate(() => navigator.clipboard.writeText('pasted'));
  await clickText(page, 0, 'value', { after: false });
  await page.locator('.menu-title', { hasText: '編集' }).click();
  await page.locator('.menu-item', { hasText: '貼り付け' }).click();
  await expect.poll(() => lineText(page, 0)).toBe('pastedvalue = 1');
});

test('clicking where the caret already is keeps that column', async ({ page }) => {
  await clickText(page, 0, 'value');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 1');
  await clickText(page, 0, 'value');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 1');
  await clickText(page, 0, '= 1');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 7');
  await clickText(page, 0, '= 1');
  await expect(page.locator('#status')).toContainText('Ln 1, Col 7');
});
