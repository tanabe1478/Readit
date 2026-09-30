// Language server navigation. Uses the pinned servers in tools/lsp (scripts/setup_lsp.py).
import fs from 'node:fs';
import path from 'node:path';
import { test, expect, ok, control, clickText, textBox, lineText, repo } from './fixture.js';

const pyright = path.join(repo, 'tools/lsp/node_modules/pyright/langserver.index.js');
test.skip(!fs.existsSync(pyright), 'Pyright is not installed; run python3 scripts/setup_lsp.py');

const files = {
  'shop/model.py': 'class Item:\n    """商品"""\n    def __init__(self, price: int):\n        self.price = price\n',
  'shop/total.py': 'from shop.model import Item\n\n\ndef total(items: list[Item]) -> int:\n    return sum(i.price for i in items)\n\n\nresult = total([Item(1), Item(2)])\n',
};
test.use({ files });

async function openTotal(page) {
  await page.locator('.tree-row', { hasText: 'total.py' }).click();
  await expect(page.locator('.tab.selected')).toContainText('total.py');
}

test('F12 jumps to the definition and history returns', async ({ page }) => {
  await openTotal(page);
  await clickText(page, 7, 'Item', { after: false });
  await page.keyboard.press('F12');
  await expect(page.locator('.tab.selected')).toContainText('model.py', { timeout: 30000 });
  await expect(page.locator('#status')).toContainText('shop/model.py:1:7');
  await page.keyboard.press('Control+-');
  await expect(page.locator('.tab.selected')).toContainText('total.py');
  await expect(page.locator('#status')).toContainText('Ln 8');
  await page.keyboard.press('Control+Shift+-');
  await expect(page.locator('.tab.selected')).toContainText('model.py');
});

test('references list stays open and navigates each result', async ({ page }) => {
  await openTotal(page);
  await clickText(page, 3, 'total');
  await page.keyboard.press('Shift+F12');
  await expect(page.locator('#dialog-shell')).toContainText('使用箇所', { timeout: 30000 });
  await expect(page.locator('.pick')).toHaveCount(2);
  await expect(page.locator('.definition-preview')).toContainText('def total');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(page.locator('#status')).toContainText('Ln 8, Col 10');
  await expect(page.locator('#navpanel')).toBeVisible();
  await expect(page.locator('.nav-result')).toHaveCount(2);
  await page.locator('.nav-result').first().click();
  await expect(page.locator('#status')).toContainText('Ln 4, Col 5');
  await page.locator('button[data-act="close-nav"]').click();
  await expect(page.locator('#navpanel')).toBeHidden();
});

test('document symbols filter and hover information', async ({ page }) => {
  await openTotal(page);
  await page.keyboard.press('Meta+Shift+o');
  await expect(page.locator('.pick-label', { hasText: /^total$/ })).toHaveCount(1, { timeout: 30000 });
  await expect(page.locator('.pick-label', { hasText: /^result$/ })).toHaveCount(1);
  await page.keyboard.type('result =');
  await expect(page.locator('.pick')).toHaveCount(1);
  await page.keyboard.press('Enter');
  await expect(page.locator('#status')).toContainText('Ln 8, Col 1');
  await clickText(page, 3, 'total');
  await page.keyboard.press('Meta+k');
  await page.keyboard.press('Meta+i');
  await expect(page.locator('.type-information')).toContainText('def total', { timeout: 30000 });
  await page.keyboard.press('Escape');
  await expect(page.locator('#overlay')).toBeHidden();
});

test('command hover previews the definition and command click jumps', async ({ page }) => {
  await openTotal(page);
  const box = await textBox(page, 7, 'Item');
  await page.mouse.move(box.x + 3, box.y + box.height / 2);
  await expect(page.locator('.pointer-info')).toContainText('class Item', { timeout: 30000 });
  const cursorBefore = await page.locator('#status').innerText();
  await page.keyboard.down('Meta');
  await expect(page.locator('.pointer-code')).toContainText('class Item', { timeout: 30000 });
  await expect(page.locator('.link-underline')).toHaveCount(1);
  expect(await page.locator('#status').innerText()).toBe(cursorBefore);
  await page.keyboard.up('Meta');
  await expect(page.locator('.pointer-code')).toHaveCount(0);
  await page.keyboard.down('Meta');
  await expect(page.locator('.pointer-code')).toContainText('class Item', { timeout: 30000 });
  await page.mouse.click(box.x + 3, box.y + box.height / 2);
  await page.keyboard.up('Meta');
  await expect(page.locator('.tab.selected')).toContainText('model.py');
});

test('results computed from older text are discarded', async ({ page }) => {
  await openTotal(page);
  await clickText(page, 7, 'Item');
  await page.keyboard.press('Shift+F12');
  // Edit before the server answers; the answer must not move the editor.
  await page.keyboard.press('End');
  await page.keyboard.type(' ');
  await expect(page.locator('#navpanel')).toContainText(/結果を破棄しました|解析中/, { timeout: 30000 });
  await expect(page.locator('#navpanel')).toContainText('結果を破棄しました', { timeout: 30000 });
  await expect(page.locator('#overlay')).toBeHidden();
});

test('external definitions open read-only and MCP may open returned paths', async ({ page, readit }) => {
  const s = readit.socketPath;
  const root = (await ok(s, 'readit_state')).workspace;
  await ok(s, 'readit_open', { workspace: root, path: 'shop/total.py', line: 5, column: 12 });
  const symbol = await ok(s, 'readit_symbol', { workspace: root, kind: 'definition' });
  const target = symbol.targets.find((t) => t.path.endsWith('builtins.pyi'));
  expect(target, JSON.stringify(symbol)).toBeTruthy();
  const opened = await ok(s, 'readit_open', { workspace: root, path: target.path, line: target.line, column: target.column });
  expect(opened.active_path).toBe(target.path);
  expect(opened.tabs.find((t) => t.path === target.path).read_only).toBe(true);
  await expect(page.locator('#navbar')).toContainText('外部定義 · 閲覧専用');
  const before = await lineText(page, target.line - 1);
  await page.keyboard.type('zz');
  expect(await lineText(page, target.line - 1)).toBe(before);
  // A path the server never returned stays out of reach.
  expect((await control(s, 'readit_open', { workspace: root, path: path.join(path.dirname(target.path), 'os/__init__.pyi') })).error).toBeTruthy();
});
