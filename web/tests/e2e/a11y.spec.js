// Accessibility: axe finds nothing to report on the main screens, controls
// have names, and keyboard focus is visible.
import AxeBuilder from '@axe-core/playwright';
import { test, expect, ok } from './fixture.js';

test.use({ files: { 'sample.py': 'one = 1\ntwo = 2\n', 'store.py': 'class Store:\n    cache = {}\n' } });

async function audit(page, label) {
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'best-practice']).analyze();
  const summary = results.violations.map((v) => `${v.id}: ${v.help} (${v.nodes.map((n) => n.target.join(' ')).join(', ')})`);
  expect(summary, label).toEqual([]);
}

test('the editor, a dialog, the overview and a guide bubble have no axe violations', async ({ page, readit }) => {
  await audit(page, 'editor');
  await page.keyboard.press('Meta+p');
  await expect(page.locator('#dialog-query')).toBeVisible();
  await audit(page, 'quick open');
  await page.keyboard.press('Escape');
  await page.locator('#editor-input').focus();
  await page.keyboard.type('x');
  await page.keyboard.press('Meta+w');
  await expect(page.locator('button[data-act="confirm-discard"]')).toBeVisible();
  await audit(page, 'confirm dialog');
  await page.locator('button[data-act="confirm-cancel"]').click();
  const s = await ok(readit.socketPath, 'readit_state');
  await ok(readit.socketPath, 'readit_guide_load', {
    workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence,
    steps: [
      { id: 'one', title: '最初の値', body: 'one の解説', path: 'sample.py', line: 1, column: 1, expected_text: 'one = 1' },
      { id: 'two', title: '次の値', body: 'two の解説', path: 'sample.py', line: 2, column: 1, expected_text: 'two = 2', kind: 'prediction', prompt: 'two は？' },
    ],
    overview: { title: '値の定義', summary: '二つの値', relationships: 'sample.py', chapters: [{ title: '最初', summary: '代入', start_step: 'one' }] },
  });
  await expect(page.locator('#overview')).toBeVisible();
  await audit(page, 'overview');
  await page.locator('button[data-act="chapter"][data-arg="0"]').click();
  await expect(page.locator('#guide')).toBeVisible();
  await audit(page, 'guide bubble');
  await page.locator('button[data-act="guide-next"]').click();
  await expect(page.locator('#guide-prediction')).toBeVisible();
  await audit(page, 'prediction step');
});

test('symbol-only controls have names and keyboard focus is visible', async ({ page }) => {
  await page.keyboard.press('Meta+f');
  for (const act of ['search-prev', 'search-next', 'search-close', 'search-case', 'search-regex']) {
    await expect(page.locator(`button[data-act="${act}"]`)).toHaveAttribute('aria-label', /.+/);
  }
  const close = page.locator('.tab.selected .tab-close');
  await expect(close).toHaveAttribute('aria-label', /sample\.py を閉じる/);
  await expect(close).toHaveJSProperty('tagName', 'BUTTON');
  // Tab moves focus to a visible ring; the mouse does not draw one.
  await close.focus();
  await expect(close).toBeFocused();
  const ring = await close.evaluate((el) => getComputedStyle(el).outlineStyle);
  expect(['solid', 'auto']).toContain(ring);
});
