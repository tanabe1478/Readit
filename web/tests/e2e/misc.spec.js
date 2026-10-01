import fs from 'node:fs';
import path from 'node:path';
import { test, expect, clickText, lineText, ok } from './fixture.js';

test.use({ files: { 'docs/guide.md': '# Guide\nsearch me\n', 'src/app.py': 'import os\nNEEDLE = 1\n', 'tests/test_app.py': 'NEEDLE\n' } });

test('project search includes unsaved edits and opens the line', async ({ page }) => {
  await expect(page.locator('.tab.selected')).toContainText('guide.md');
  await clickText(page, 1, 'me', { after: true });
  await page.keyboard.type(' NEEDLE');
  await page.keyboard.press('Meta+Shift+f');
  await page.keyboard.type('needle');
  await expect(page.locator('.pick')).toHaveCount(3);
  await expect(page.locator('.pick').first()).toContainText('docs/guide.md:2');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tab.selected')).toContainText('app.py');
  await expect(page.locator('#status')).toContainText('Ln 2');
});

test('save all writes every dirty tab', async ({ page, readit }) => {
  await clickText(page, 0, 'Guide', { after: true });
  await page.keyboard.type('!');
  await page.locator('.tree-row[data-tree="src/app.py"]').click();
  await clickText(page, 0, 'os', { after: true });
  await page.keyboard.type('.path');
  await page.keyboard.press('Meta+Alt+s');
  await expect(page.locator('#status')).toContainText('すべてのファイルを保存しました');
  expect(fs.readFileSync(path.join(readit.project, 'docs/guide.md'), 'utf8')).toBe('# Guide!\nsearch me\n');
  expect(fs.readFileSync(path.join(readit.project, 'src/app.py'), 'utf8')).toBe('import os.path\nNEEDLE = 1\n');
});

test('reading path lists opened files with their provisional roles', async ({ page }) => {
  await page.locator('.tree-row[data-tree="tests/test_app.py"]').click();
  await page.locator('.tree-row[data-tree="src/app.py"]').click();
  await page.locator('button[data-act="toggle-reading"]').click();
  await expect(page.locator('.route')).toHaveCount(3);
  // Opened order, labelled by the file-name heuristic, as in the native app.
  await expect(page.locator('.route').nth(0)).toContainText('01 · 背景docs/guide.md');
  await expect(page.locator('.route').nth(1)).toContainText('02 · 検証tests/test_app.py');
  await expect(page.locator('.route').nth(2)).toContainText('03 · 実装src/app.py');
  await page.locator('button[data-act="toggle-reading"]').click();
  await expect(page.locator('.tree-row').first()).toBeVisible();
});

test('menus, zoom, help and sidebar resizing', async ({ page, readit }) => {
  await page.locator('.menu-title', { hasText: '表示' }).click();
  await page.locator('.menu-item', { hasText: '拡大' }).click();
  const size = await page.locator('.lines').evaluate((el) => getComputedStyle(el).fontSize);
  expect(size).toBe('15px');
  await page.keyboard.press('Meta+0');
  expect(await page.locator('.lines').evaluate((el) => getComputedStyle(el).fontSize)).toBe('14px');
  await page.locator('.menu-title', { hasText: 'Readit' }).click();
  await page.locator('.menu-item', { hasText: 'キーボードショートカット' }).click();
  await expect(page.locator('.help-list')).toContainText('定義へ移動');
  await page.keyboard.press('Escape');
  const handle = await page.locator('#sidebar-resize').boundingBox();
  await page.mouse.move(handle.x + 2, handle.y + 200);
  await page.mouse.down();
  await page.mouse.move(handle.x + 102, handle.y + 200, { steps: 5 });
  await page.mouse.up();
  const width = (await ok(readit.socketPath, 'readit_state')).view.file_tree_width;
  expect(width).toBeGreaterThan(330);
  expect(width).toBeLessThan(360);
});

test('without git the diff compares with the text when opened', async ({ page }) => {
  await clickText(page, 1, 'search', { after: false });
  await page.keyboard.type('please ');
  await page.locator('button[data-act="compare"]').click();
  await expect(page.locator('.diff-row.removed')).toHaveText(/search me/);
  await expect(page.locator('.diff-row.added')).toHaveText(/please search me/);
  await page.locator('button[data-act="compare"]').click();
  await expect(page.locator('#editor-scroll')).toBeVisible();
});

test('tab cycling, close all and reopen', async ({ page }) => {
  await page.locator('.tree-row[data-tree="src/app.py"]').click();
  await page.locator('.tree-row[data-tree="tests/test_app.py"]').click();
  await page.keyboard.press('Control+Tab');
  await expect(page.locator('.tab.selected')).toContainText('guide.md');
  await page.keyboard.press('Control+Shift+Tab');
  await expect(page.locator('.tab.selected')).toContainText('test_app.py');
  await page.keyboard.press('Meta+Alt+ArrowLeft');
  await expect(page.locator('.tab.selected')).toContainText('app.py');
  await page.keyboard.press('Meta+k');
  await page.keyboard.press('Meta+w');
  await expect(page.locator('.tab')).toHaveCount(0);
  await expect(page.locator('#empty-state')).toContainText('⌘P ファイルを開く');
  await page.keyboard.press('Control+Shift+t');
  await expect(page.locator('.tab')).toHaveCount(1);
});

test('quit stops the server after confirming unsaved edits', async ({ page, readit }) => {
  await clickText(page, 0, 'Guide', { after: true });
  await page.keyboard.type('?');
  await page.keyboard.press('Control+q');
  await expect(page.locator('#dialog-body')).toContainText('変更を保存しますか？');
  await page.locator('button[data-act="confirm-discard"]').click();
  await expect(page.locator('.closed')).toContainText('Readitを終了しました');
  await expect.poll(() => readit.child.exitCode).toBe(0);
  expect(fs.readFileSync(path.join(readit.project, 'docs/guide.md'), 'utf8')).toBe('# Guide\nsearch me\n');
});

test.describe('MoonBit highlighting', () => {
  test.use({ files: { 'main.mbt': '///|\npub fn greet(name : String) -> String {\n  "hello \\{name}"\n}\n' } });
  test('.mbt files are highlighted with the MoonBit grammar', async ({ page }) => {
    await expect(page.locator('.tab.selected')).toContainText('main.mbt');
    await expect(page.locator('#status')).toContainText('moonbit');
    await expect(page.locator('.row[data-line="0"] .t-comment')).toHaveText('///|');
    await expect(page.locator('.row[data-line="1"] .t-keyword').first()).toHaveText('pub');
    await expect(page.locator('.row[data-line="1"] .t-function')).toHaveText('greet');
    await expect(page.locator('.row[data-line="1"] .t-type').first()).toHaveText('String');
  });
});
