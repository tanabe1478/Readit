// Host-only real wasm regressions. Do not run against an existing phone Preview.
import fs from 'node:fs';
import path from 'node:path';
import { test, expect, ok } from './fixture.js';

const lines = Array.from({ length: 700 }, (_, index) => {
  const width = index % 5 === 0 ? 18 : index % 3 === 0 ? 6 : 1;
  return `value_${index + 1} = "${'long wrapped source '.repeat(width)}"`;
});
const source = lines.join('\n') + '\n';

async function visibleBounds(page) {
  // Independent DOM oracle, not the production helper or scrollTop / line-height.
  return page.evaluate(() => {
    const scroll = document.getElementById('editor-scroll');
    const box = scroll.getBoundingClientRect();
    const viewport = window.visualViewport;
    const top = Math.max(box.top + scroll.clientTop, viewport?.offsetTop ?? 0);
    const bottom = Math.min(
      box.top + scroll.clientTop + scroll.clientHeight,
      (viewport?.offsetTop ?? 0) + (viewport?.height ?? window.innerHeight)
    );
    const visible = [];
    for (const row of scroll.querySelectorAll('.lines[data-view="editor"] .row[data-line]')) {
      const rect = row.getBoundingClientRect();
      if (rect.height > 0 && rect.bottom > top && rect.top < bottom) {
        visible.push(Number(row.dataset.line) + 1);
      }
    }
    if (visible.length === 0) {
      return null;
    }
    return { start_line: Math.min(...visible), end_line: Math.max(...visible) };
  });
}

async function assertBounds(page, socket) {
  await expect.poll(async () => {
    const state = await ok(socket, 'readit_state');
    const expected = await visibleBounds(page);
    return expected !== null &&
      state.selection.viewport?.start_line === expected.start_line &&
      state.selection.viewport?.end_line === expected.end_line;
  }).toBe(true);
}

const cases = [
  { name: 'desktop nonwrap', width: 1420, height: 900, wrap: false },
  { name: 'desktop wrap', width: 1420, height: 900, wrap: true },
  { name: 'mobile wrap', width: 360, height: 682, wrap: true },
  { name: 'keyboard-height mobile wrap', width: 360, height: 355, wrap: true }
];

for (const config of cases) {
  test.describe(config.name, () => {
    test.use({
      files: { 'long.js': source },
      viewport: { width: config.width, height: config.height }
    });

    test('long-file guide stays anchored, exposes questions and preserves reading focus', async ({
      page,
      readit
    }) => {
      const socket = readit.socketPath;
      let state = await ok(socket, 'readit_state');
      const workspace = state.workspace;
      await ok(socket, 'readit_view', { workspace, wrap: config.wrap });
      const steps = [523, 620].map((line, index) => {
        return {
          id: `step-${index}`,
          title: `Read ${line}`,
          body: '実DOMの可視行を使い、同じガイドの質問を受け取ります。',
          path: 'long.js',
          line,
          column: 1,
          expected_text: `value_${line}`
        };
      });
      await ok(socket, 'readit_guide_load', {
        workspace,
        id: 'viewport-tour',
        event_sequence: state.guide_event_sequence,
        steps,
        overview: {
          title: 'Long source',
          summary: '可変高さの行を読む。',
          relationships: 'DOM rows → viewport → guide anchor',
          chapters: steps.map((step, index) => {
            return { title: `Chapter ${index}`, summary: 'ソースへ進む。', start_step: step.id };
          })
        }
      });
      await page.locator('button[data-act="chapter"][data-arg="0"]').click();
      await expect(page.locator('#guide')).toBeVisible();
      await expect(page.locator('button[data-act="guide-ask"]')).toBeVisible();
      await assertBounds(page, socket);
      state = await ok(socket, 'readit_state');
      expect(state.guide.id).toBe('step-0');
      expect(state.selection.start_line).toBe(523);
      expect(state.selection.viewport.start_line).toBeLessThanOrEqual(523);
      expect(state.selection.viewport.end_line).toBeGreaterThanOrEqual(523);
      expect(state.selection.text).toBe('value_523');
      const active = await page.evaluate(() => {
        return document.activeElement?.id;
      });
      expect(active).toBe(config.width <= 900 ? 'app' : 'editor-input');

      // Next/back work locally without generating a replacement tour.
      await page.locator('button[data-act="guide-next"]').click();
      await expect(page.locator('#guide')).toBeVisible();
      await assertBounds(page, socket);
      expect((await ok(socket, 'readit_state')).guide.id).toBe('step-1');
      await page.locator('button[data-act="guide-back"]').click();
      await expect(page.locator('#guide')).toBeVisible();
      await assertBounds(page, socket);
      expect((await ok(socket, 'readit_state')).guide.id).toBe('step-0');

      // Resizing models keyboard-height layout, not native IME/finger evidence.
      if (config.width <= 900) {
        await page.setViewportSize({ width: 360, height: config.height === 355 ? 682 : 355 });
        await assertBounds(page, socket);
        await expect(page.locator('#guide')).toBeVisible();
        expect(await page.evaluate(() => {
          return document.activeElement?.id;
        })).not.toBe('editor-input');
      }
      await page.locator('button[data-act="guide-ask"]').click();
      await page.locator('#guide-question').fill('合成連携検証: 可視行の根拠は？');
      await page.locator('button[data-act="guide-send"]').click();
      state = await ok(socket, 'readit_state');
      const events = await ok(socket, 'readit_guide_events', { workspace, after: 0 });
      const question = events.events.find(event => {
        return event.action === 'question';
      });
      expect(question).toBeTruthy();
      await ok(socket, 'readit_guide_answer', {
        workspace,
        id: 'step-0',
        question_sequence: question.sequence,
        body: '実DOMの行矩形とスクロール領域の交差です。'
      });
      await expect(page.locator('#guide')).toContainText('実DOMの行矩形');
      state = await ok(socket, 'readit_state');
      expect(state.guide_tour.id).toBe('viewport-tour');
      expect(state.guide.id).toBe('step-0');
      expect(state.view.wrap).toBe(config.wrap);
      // DOM bounds must not simply include every rendered/overscan row or force
      // the bubble visible after the reader has scrolled its source away.
      await page.evaluate(() => {
        document.getElementById('editor-scroll').scrollTop = 0;
      });
      await assertBounds(page, socket);
      await expect(page.locator('#guide')).toBeHidden();
      state = await ok(socket, 'readit_state');
      expect(state.selection.viewport.start_line).toBe(1);
      expect(state.selection.viewport.end_line).toBeLessThan(523);
      expect(state.guide.id).toBe('step-0');
      expect(state.guide_tour.id).toBe('viewport-tour');
      expect(state.tabs.every(tab => {
        return tab.dirty === false;
      })).toBe(true);
      expect(fs.readFileSync(path.join(readit.project, 'long.js'), 'utf8')).toBe(source);
    });
  });
}
