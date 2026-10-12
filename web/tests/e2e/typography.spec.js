// Typography and spacing rules (docs/typography.md): tokens only, line heights
// and bar heights on the 8px grid, no italics, code zoom independent of the UI.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test, expect } from './fixture.js';

const css = fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../www/style.css'), 'utf8');

/** Rules outside the :root token blocks, with comments removed. */
function componentRules() {
  return css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/:root\s*\{[^}]*\}/g, '');
}

test.describe('style sheet', () => {
  test('sizes, line heights and spacing come from tokens', () => {
    const rules = componentRules();
    const decls = /(?:^|[;{\s])(font-size|line-height|font|padding(?:-[a-z]+)?|gap|margin(?:-[a-z]+)?)\s*:\s*([^;}]*)/g;
    const offenders = [];
    for (const [, prop, value] of rules.matchAll(decls)) {
      // Allowed literals: 0, 1px hairlines and ch units (code columns).
      const literals = value.replace(/var\([^)]*\)|calc\([^)]*\)/g, ' ').split(/[\s/]+/)
        .filter((t) => /^-?\d*\.?\d+(px|em|rem|%)?$/.test(t) && t !== '0' && t !== '1px');
      if (literals.length) offenders.push(`${prop}: ${value.trim()}`);
    }
    expect(offenders).toEqual([]);
  });

  test('no italics, bold is 600 except the logo', () => {
    const rules = componentRules();
    expect(rules).not.toMatch(/font-style\s*:\s*(italic|oblique)/);
    const bold = [...rules.matchAll(/([^{}]+)\{[^}]*font-weight\s*:\s*(700|bold)[^}]*\}/g)].map((m) => m[1].trim());
    expect(bold).toEqual(['.logo']);
  });
});

test.describe('rendered page', () => {
  test.use({ files: { 'src/app.py': '# a comment\nvalue = 1  # trailing\n'.repeat(4) } });

  test('bars and rows sit on the 8px grid', async ({ page }) => {
    const heights = await page.evaluate(() => Object.fromEntries(
      ['#topbar', '#tabs', '#pathbar', '#navbar', '#status', '.tree-row', '.explorer-head'].map((s) => [s, document.querySelector(s)?.getBoundingClientRect().height]),
    ));
    expect(heights).toEqual({ '#topbar': 48, '#tabs': 40, '#pathbar': 40, '#navbar': 32, '#status': 32, '.tree-row': 32, '.explorer-head': 48 });
    const fonts = await page.evaluate(() => {
      const get = (s, p) => getComputedStyle(document.querySelector(s))[p];
      return { body: get('body', 'lineHeight'), tree: get('.tree-name', 'lineHeight'), comment: get('.t-comment', 'fontStyle'), caption: get('.caption', 'fontVariantNumeric') };
    });
    expect(fonts).toEqual({ body: '20px', tree: '16px', comment: 'normal', caption: 'tabular-nums' });
  });

  test('zoom moves the code line height along the grid and leaves the UI alone', async ({ page }) => {
    const code = () => page.evaluate(() => {
      const lines = document.querySelector('.lines[data-view="editor"]');
      const s = getComputedStyle(lines);
      return { size: s.fontSize, lh: s.lineHeight, row: document.querySelector('.lines .row').getBoundingClientRect().height, data: Number(lines.dataset.lh), ui: getComputedStyle(document.querySelector('.tree-name')).fontSize };
    });
    expect(await code()).toEqual({ size: '14px', lh: '24px', row: 24, data: 24, ui: '12px' });
    for (let i = 0; i < 4; i++) await page.keyboard.press('Meta+=');
    expect(await code()).toEqual({ size: '18px', lh: '28px', row: 28, data: 28, ui: '12px' });
    await page.keyboard.press('Meta+0');
    expect((await code()).lh).toBe('24px');
  });
});
