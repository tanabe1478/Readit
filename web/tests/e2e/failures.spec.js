// How Readit fails: files it will not read, and a server that went away.
// Each failure is explained in the status bar and nothing is lost.
import { test, expect, openFolders } from './fixture.js';

test.describe('files the editor refuses', () => {
  test.use({ files: {
    'ok.py': 'x = 1\n',
    'big.txt': 'a'.repeat(256 * 1024 + 1),
    'bin.dat': Buffer.from([0x61, 0x62, 0x00, 0x63]),
    'latin.txt': Buffer.from([0x63, 0x61, 0x66, 0xe9]),
    'nested/also.py': 'y = 2\n',
  } });

  test('large, binary and non-UTF-8 files are explained and leave the editor as it was', async ({ page }) => {
    const status = page.locator('#status');
    await page.locator('.tree-row[data-tree="ok.py"]').click();
    await expect(page.locator('.tab.selected')).toContainText('ok.py');
    for (const [name, reason] of [['big.txt', '大きすぎます'], ['bin.dat', 'バイナリ'], ['latin.txt', 'UTF-8以外']]) {
      await page.locator(`.tree-row[data-tree="${name}"]`).click();
      await expect(status).toContainText(reason);
      await expect(page.locator('.tab.selected')).toContainText('ok.py');
      await expect(page.locator('.tab')).toHaveCount(1);
    }
    // A readable file still opens afterwards.
    await openFolders(page, 'nested');
    await page.locator('.tree-row[data-tree="nested/also.py"]').click();
    await expect(page.locator('.tab.selected')).toContainText('also.py');
  });
});

test.describe('the server goes away', () => {
  test.use({ files: { 'a.py': 'a = 1\n', 'b.py': 'b = 2\n' } });

  test('a lost server is reported, edits stay in the page, and a save says why it failed', async ({ page, readit }) => {
    const status = page.locator('#status');
    await expect(status).toContainText('MCP接続待受中');
    await page.locator('#editor-input').focus();
    await page.keyboard.type('# note\n');
    readit.child.kill();
    await expect(status).not.toContainText('MCP接続待受中');
    // Opening another file needs the server; the failure is explained.
    await page.locator('.tree-row[data-tree="b.py"]').click();
    await expect(status).toContainText('サーバーに接続できません');
    await expect(page.locator('.tab.selected')).toContainText('a.py');
    // The unsaved edit is still in the editor and still marked.
    await expect(page.locator('.lines[data-view="editor"] .row').first()).toContainText('# note');
    await expect(page.locator('.tab.selected .dirty')).toHaveText('●');
    await page.keyboard.press('Meta+s');
    await expect(status).toContainText('サーバーに接続できません');
    await expect(page.locator('.tab.selected .dirty')).toHaveText('●');
  });
});
