import { test, expect, ok } from './fixture.js';

const files = {
  'README.md': '# Mobile\n' + 'Long lines should wrap rather than push the editor off screen. '.repeat(16) + '\n',
  'src/sample.js': 'const value = 42;\n'.repeat(80),
  ['a-very-long-file-name-'.repeat(8) + '.md']: '# Long filename\n',
};
async function insideViewport(page, locator) {
  const box = await locator.boundingBox();
  const size = await page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
  expect(box).not.toBeNull();
  expect(box.x).toBeGreaterThanOrEqual(-1);
  expect(box.y).toBeGreaterThanOrEqual(-1);
  expect(box.x + box.width).toBeLessThanOrEqual(size.width + 1);
  expect(box.y + box.height).toBeLessThanOrEqual(size.height + 1);
}

test.describe('phone layout and touch interaction', () => {
  test.use({ viewport: { width: 360, height: 682 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, files });

  test('editor starts full width, wrapped, with reachable header controls', async ({ page }) => {
    await expect(page.locator('#sidebar')).toBeHidden();
    expect(await page.evaluate(() => document.activeElement.id)).not.toBe('editor-input');
    expect((await page.locator('#center').boundingBox()).width).toBe(360);
    expect((await page.locator('#editor-scroll').boundingBox()).height).toBeGreaterThan(250);
    await expect(page.locator('#editor-content .lines')).toHaveClass(/wrap/);
    for (const control of await page.locator('#topbar button:visible').all()) await insideViewport(page, control);
    await insideViewport(page, page.locator('#status'));
  });

  test('drawer overlays instead of squeezing editor; touch selects files and closes it', async ({ page }) => {
    await page.getByRole('button', { name: 'ファイルツリー', exact: true }).tap();
    await expect(page.locator('#sidebar')).toBeVisible();
    await expect(page.getByRole('button', { name: 'ファイルツリー', exact: true })).toHaveAttribute('aria-expanded', 'true');
    await insideViewport(page, page.locator('#sidebar'));
    expect((await page.locator('#center').boundingBox()).width).toBe(360);
    expect((await page.locator('.tree-row').first().boundingBox()).height).toBe(44);
    await page.locator('.tree-row[data-tree="src"]').tap();
    await page.locator('.tree-row[data-tree="src/sample.js"]').tap();
    await expect(page.locator('#sidebar')).toBeHidden();
    await expect(page.locator('#tab-selected')).toContainText('sample.js');
    await page.getByRole('button', { name: 'ファイルツリー', exact: true }).tap();
    await page.touchscreen.tap(350, 300);
    await expect(page.locator('#sidebar')).toBeHidden();
  });

  test('all menus stay on screen and long menus scroll', async ({ page }) => {
    for (const label of ['Readit', 'ファイル', '編集', '表示', '移動']) {
      await page.getByRole('button', { name: label, exact: true }).tap();
      await insideViewport(page, page.locator('#menu-layer .menu-list'));
      await page.getByRole('button', { name: label, exact: true }).tap();
    }
  });

  test('picker works by touch and has a touch close button', async ({ page }) => {
    await page.getByRole('button', { name: '開く', exact: true }).tap();
    await insideViewport(page, page.locator('#dialog'));
    await page.locator('#dialog-query').fill('a-very-long');
    await expect(page.locator('.pick-label')).toHaveCount(1);
    await expect(page.locator('.pick-label')).toContainText('a-very-long');
    await insideViewport(page, page.locator('#dialog'));
    await page.getByRole('button', { name: '閉じる', exact: true }).tap();
    await expect(page.locator('#overlay')).toBeHidden();
    expect(await page.evaluate(() => document.activeElement.id)).not.toBe('editor-input');
    await page.getByRole('button', { name: '開く', exact: true }).tap();
    await page.locator('#dialog-query').fill('sample.js');
    await expect(page.locator('.pick-label')).toHaveCount(1);
    await expect(page.locator('.pick-label')).toHaveText('src/sample.js');
    await page.locator('.pick').first().tap();
    await expect(page.locator('#tab-selected')).toContainText('sample.js');
    await expect(page.locator('#overlay')).toBeHidden();
  });

  test('search controls and IME composition input stay inside the viewport', async ({ page }) => {
    await page.getByRole('button', { name: '編集', exact: true }).tap();
    await page.locator('.menu-item[data-arg="find"]').tap();
    await insideViewport(page, page.locator('#search-bar'));
    for (const control of await page.locator('#search-controls button').all()) await insideViewport(page, control);
    await page.locator('[data-act="search-close"]').tap();
    const input = page.locator('#editor-input');
    await input.dispatchEvent('compositionstart', { data: '' });
    await insideViewport(page, input);
    await input.dispatchEvent('compositionend', { data: '' });
  });

  test('search remains usable in a keyboard-height viewport', async ({ page }) => {
    await page.getByRole('button', { name: '編集', exact: true }).tap();
    await page.locator('.menu-item[data-arg="find"]').tap();
    await page.locator('#search-input').focus();
    await page.setViewportSize({ width: 360, height: 360 });
    await insideViewport(page, page.locator('#search-bar'));
    const search = await page.locator('#search-bar').boundingBox();
    const status = await page.locator('#status').boundingBox();
    expect(search.y + search.height).toBeLessThanOrEqual(status.y);
    await page.locator('[data-act="search-close"]').tap();
    await page.locator('#editor-input').focus();
    await expect(page.getByRole('button', { name: '開く', exact: true })).toBeVisible();
    expect((await page.locator('#editor-scroll').boundingBox()).height).toBeGreaterThan(140);
    await page.setViewportSize({ width: 360, height: 682 });
    await expect(page.getByRole('button', { name: '編集', exact: true })).toBeVisible();
  });

  test('pinned code stacks below a full-width editor', async ({ page, readit }) => {
    await ok(readit.socketPath, 'readit_pin', { workspace: readit.project, path: 'src/sample.js', line: 1 });
    await expect(page.locator('#pinned')).toBeVisible();
    await insideViewport(page, page.locator('#pinned'));
    expect((await page.locator('#editor-scroll').boundingBox()).width).toBe(360);
    expect((await page.locator('#editor-scroll').boundingBox()).height).toBeGreaterThan(100);
    await page.locator('[data-act="unpin-code"]').tap();
    await expect(page.locator('#pinned')).toBeHidden();
  });

  test('landscape and desktop resizing do not clip the shell', async ({ page, readit }) => {
    await page.setViewportSize({ width: 800, height: 400 });
    await insideViewport(page, page.locator('#topbar'));
    await insideViewport(page, page.locator('#status'));
    expect((await page.locator('#editor-scroll').boundingBox()).height).toBeGreaterThan(100);
    await page.setViewportSize({ width: 1420, height: 900 });
    await ok(readit.socketPath, 'readit_view', { workspace: readit.project, file_tree: true });
    await expect(page.locator('#sidebar')).toBeVisible();
    expect(await page.locator('#sidebar').evaluate(el => getComputedStyle(el).position)).toBe('relative');
    expect((await page.locator('#center').boundingBox()).width).toBeGreaterThan(900);
    await page.setViewportSize({ width: 360, height: 682 });
    await expect(page.locator('#sidebar')).toBeHidden();
    expect((await page.locator('#center').boundingBox()).width).toBe(360);
  });
});
