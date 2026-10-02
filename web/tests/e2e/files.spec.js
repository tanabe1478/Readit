import fs from 'node:fs';
import path from 'node:path';
import { test, expect, lineText, clickText, makeProject, openFolders } from './fixture.js';

test.use({
  files: { 'src/a.py': 'a = 1\n', 'src/sub/b.py': 'b = 2\n', 'README.md': '# readme\n' },
  git: true,
});

test('new file, save as and the tree listing', async ({ page, readit }) => {
  await page.keyboard.press('Control+n');
  await expect(page.locator('.tab.selected')).toContainText('Untitled-1');
  await page.keyboard.type('fresh = 3');
  await page.keyboard.press('Meta+s');
  await expect(page.locator('#dialog-shell')).toContainText('名前を付けて保存');
  await page.locator('#dialog-query').fill('src/fresh.py');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tab.selected')).toContainText('fresh.py');
  expect(fs.readFileSync(path.join(readit.project, 'src/fresh.py'), 'utf8')).toBe('fresh = 3');
  await expect(page.locator('.tree-row', { hasText: 'fresh.py' })).toBeVisible();
  // Save As never overwrites an existing file.
  await page.keyboard.press('Meta+Shift+s');
  await page.locator('#dialog-query').fill('src/a.py');
  await page.keyboard.press('Enter');
  await expect(page.locator('#dialog-body')).toContainText('同じ名前のファイルまたはフォルダが存在します');
  expect(fs.readFileSync(path.join(readit.project, 'src/a.py'), 'utf8')).toBe('a = 1\n');
});

test('new folder, rename a folder with open tabs, delete and restore', async ({ page, readit }) => {
  await openFolders(page, 'src', 'src/sub');
  await page.locator('.tree-row', { hasText: 'b.py' }).click();
  await expect(page.locator('.tab.selected')).toContainText('b.py');
  await page.keyboard.type('# edit\n');
  await page.locator('.tree-row', { hasText: 'sub' }).click({ button: 'right' });
  await page.locator('.menu-item', { hasText: '名前を変更' }).click();
  await expect(page.locator('#dialog-query')).toHaveValue('src/sub');
  await page.locator('#dialog-query').fill('src/renamed');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tree-row', { hasText: 'renamed' })).toBeVisible();
  expect(fs.existsSync(path.join(readit.project, 'src/renamed/b.py'))).toBe(true);
  await page.locator('.tab', { hasText: 'b.py' }).locator('span').first().click();
  await expect(page.locator('#pathbar')).toContainText('src/renamed/b.py');
  expect(await lineText(page, 0)).toBe('# edit');
  // Deleting refuses unsaved edits, then works after saving and can be restored.
  await page.locator('.tree-row', { hasText: 'renamed' }).click({ button: 'right' });
  await page.locator('.menu-item', { hasText: '削除' }).click();
  await expect(page.locator('#dialog-body')).toContainText('選択した項目を削除しますか？');
  await page.locator('button[data-act="confirm-save"]').click();
  await expect(page.locator('.tree-row', { hasText: 'renamed' })).toHaveCount(0);
  expect(fs.existsSync(path.join(readit.project, 'src/renamed'))).toBe(false);
  expect(fs.readdirSync(path.join(readit.project, '.readit/trash')).length).toBe(1);
  await page.keyboard.press('Meta+Shift+p');
  await page.keyboard.type('削除したファイルを復元');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tree-row', { hasText: 'renamed' })).toBeVisible();
  expect(fs.readFileSync(path.join(readit.project, 'src/renamed/b.py'), 'utf8')).toBe('# edit\nb = 2\n');
  await page.keyboard.press('Meta+Shift+p');
  await page.keyboard.type('新規フォルダ');
  await page.keyboard.press('Enter');
  await page.locator('#dialog-query').fill('empty-dir');
  await page.keyboard.press('Enter');
  await expect(page.locator('.tree-row', { hasText: 'empty-dir' })).toBeVisible();
  expect(fs.statSync(path.join(readit.project, 'empty-dir')).isDirectory()).toBe(true);
});

test('git baseline shows modified files and a line diff', async ({ page, readit }) => {
  await expect(page.locator('.tab.selected')).toContainText('README.md');
  fs.writeFileSync(path.join(readit.project, 'README.md'), '# readme\nchanged\n');
  await page.keyboard.press('Meta+r');
  await expect(page.locator('.tree-row', { hasText: 'README.md' }).locator('.badge')).toHaveText('M');
  await page.locator('.tree-row', { hasText: 'README.md' }).click();
  await page.keyboard.press('Meta+Alt+d');
  await expect(page.locator('.diff-row.added')).toHaveText(/changed/);
  await expect(page.locator('.diff-row')).toHaveCount(2);
  await page.locator('.diff-row.added').click();
  await expect(page.locator('#status')).toContainText('Ln 2');
  await expect(page.locator('#editor-scroll')).toBeVisible();
});

test('explorer keyboard navigation expands and collapses folders', async ({ page }) => {
  await page.keyboard.press('Meta+Shift+e');
  await page.keyboard.press('ArrowDown');
  await expect(page.locator('.tree-row.active')).toHaveCount(1);
  // Folders start closed and load their children when opened.
  const before = await page.locator('.tree-row').count();
  await page.locator('.tree-row', { hasText: 'src' }).first().click();
  await page.waitForFunction(() => window.readitIdle());
  const opened = await page.locator('.tree-row').count();
  expect(opened).toBeGreaterThan(before);
  await expect(page.locator('.tree-row[data-tree="src/a.py"]')).toBeVisible();
  await page.keyboard.press('ArrowLeft');
  expect(await page.locator('.tree-row').count()).toBe(before);
  await page.keyboard.press('ArrowRight');
  expect(await page.locator('.tree-row').count()).toBe(opened);
  await page.keyboard.press('Meta+b');
  await expect(page.locator('#sidebar')).toBeHidden();
  await page.keyboard.press('Meta+b');
  await expect(page.locator('#sidebar')).toBeVisible();
});

test.describe('switching folders', () => {
  const other = makeProject({ 'other.py': 'other = 1\n' });
  test.use({ serverEnv: { READIT_TEST_PICK: other } });
  test('open folder replaces the project after asking about unsaved edits', async ({ page }) => {
    await expect(page.locator('.tab.selected')).toContainText('README.md');
    await page.keyboard.type('x');
    await page.locator('button[data-act="open-folder"]').click();
    await expect(page.locator('#dialog-body')).toContainText('変更を保存しますか？');
    await page.locator('button[data-act="confirm-discard"]').click();
    await expect(page.locator('.tab.selected')).toContainText('other.py');
    await expect(page.locator('#topbar')).toContainText(path.basename(other));
  });
});
