// Host-only real-wasm regressions, never run against the user's phone Preview.
import fs from 'node:fs';
import path from 'node:path';
import { test, expect, ok } from './fixture.js';

const source = Array.from({ length: 700 }, (_, index) => {
  return `value_${index + 1} = ${index + 1}`;
}).join('\n') + '\n';
const explanation = Array.from({ length: 60 }, (_, index) => {
  return `説明 ${index + 1}: コードと解説を交互に詳しく読みます。`;
}).join('\n');

async function loadTour(socket, prediction = false) {
  const state = await ok(socket, 'readit_state');
  const workspace = state.workspace;
  await ok(socket, 'readit_guide_load', {
    workspace,
    id: 'toggle-tour',
    event_sequence: state.guide_event_sequence,
    steps: [
      {
        id: 'first',
        title: '全文を読んでコードへ戻る',
        body: explanation,
        path: 'long.js',
        line: 523,
        column: 1,
        expected_text: 'value_523',
        ...(prediction ? { kind: 'prediction', prompt: '自分の予測を記録する。' } : {})
      },
      {
        id: 'second',
        title: '次の全文',
        body: explanation,
        path: 'long.js',
        line: 620,
        column: 1,
        expected_text: 'value_620',
        ...(prediction ? { kind: 'verification', verifies: 'first' } : {})
      }
    ]
  });
  return workspace;
}

async function scrollExplanation(page) {
  await page.evaluate(() => {
    document.getElementById('guide').scrollTop = 250;
  });
  await expect.poll(async () => {
    return page.locator('#guide').evaluate(element => {
      return element.scrollTop;
    });
  }).toBeGreaterThan(150);
  return page.locator('#guide').evaluate(element => {
    return element.scrollTop;
  });
}

async function hideExplanation(page) {
  await page.locator('button[data-act="guide-code"]').click();
  await expect(page.locator('#guide')).toBeHidden();
  await expect(page.locator('#guide-return')).toBeVisible();
}

async function resumeExplanation(page) {
  await page.locator('#guide-return').click();
  await expect(page.locator('#guide')).toBeVisible();
  await expect(page.locator('#guide-return')).toBeHidden();
  const switchBox = await page.locator('button[data-act="guide-code"]').boundingBox();
  expect(switchBox.y).toBeGreaterThanOrEqual(0);
  expect(switchBox.y + switchBox.height).toBeLessThanOrEqual(page.viewportSize().height);
}

const cases = [
  { name: 'desktop', width: 1420, height: 900 },
  { name: 'mobile portrait', width: 360, height: 682 },
  { name: 'mobile landscape', width: 800, height: 400 },
  { name: 'keyboard-height mobile', width: 360, height: 355 }
];

for (const config of cases) {
  test.describe(config.name, () => {
    test.use({
      files: { 'long.js': source, 'other.js': 'const other = true;\n' },
      viewport: { width: config.width, height: config.height }
    });

    test.afterEach(async ({ readit }) => {
      const state = await ok(readit.socketPath, 'readit_state');
      expect(state.tabs.every(tab => {
        return !tab.dirty;
      })).toBe(true);
      expect(fs.readFileSync(path.join(readit.project, 'long.js'), 'utf8')).toBe(source);
      expect(fs.readFileSync(path.join(readit.project, 'other.js'), 'utf8'))
        .toBe('const other = true;\n');
    });

    test('full text, reading point and code position survive repeated switches', async ({
      page,
      readit
    }) => {
      const workspace = await loadTour(readit.socketPath);
      await expect(page.locator('#guide')).toBeVisible();
      await expect(page.locator('.guide-body')).toHaveText(explanation);
      const readingPoint = await scrollExplanation(page);
      const before = await ok(readit.socketPath, 'readit_state');
      const codePoint = await page.locator('#editor-scroll').evaluate(element => {
        return element.scrollTop;
      });
      await hideExplanation(page);
      const hidden = await ok(readit.socketPath, 'readit_state');
      expect(hidden.guide).toEqual({ ...before.guide, code_view: true });
      expect(hidden.guide_tour).toEqual(before.guide_tour);
      expect(hidden.guide_event_sequence).toBe(before.guide_event_sequence);
      expect(hidden.selection).toEqual(before.selection);
      expect(await page.locator('#editor-scroll').evaluate(element => {
        return element.scrollTop;
      })).toBe(codePoint);

      // Inspect code away from the anchor, including a simulated height change.
      await page.locator('#editor-scroll').evaluate(element => {
        element.scrollTop = 0;
      });
      await page.setViewportSize({
        width: config.width,
        height: config.height === 355 ? 682 : 355
      });
      await expect(page.locator('#guide-return')).toBeVisible();
      const returnBox = await page.locator('#guide-return').boundingBox();
      expect(returnBox.height).toBeGreaterThanOrEqual(44);
      expect(returnBox.x).toBeGreaterThanOrEqual(0);
      expect(returnBox.y).toBeGreaterThanOrEqual(0);
      expect(returnBox.x + returnBox.width).toBeLessThanOrEqual(page.viewportSize().width);
      expect(returnBox.y + returnBox.height).toBeLessThanOrEqual(page.viewportSize().height);
      const viewed = await ok(readit.socketPath, 'readit_state');
      expect(viewed.selection.viewport.start_line).toBe(1);
      await resumeExplanation(page);
      await expect.poll(async () => {
        return page.locator('#guide').evaluate(element => {
          return element.scrollTop;
        });
      }).toBeCloseTo(readingPoint, 0);
      expect(await page.locator('#editor-scroll').evaluate(element => {
        return element.scrollTop;
      })).toBe(0);
      const resumed = await ok(readit.socketPath, 'readit_state');
      expect(resumed.guide.code_view).toBe(false);
      expect(resumed.guide_event_sequence).toBe(before.guide_event_sequence);
      expect(resumed.selection).toEqual(viewed.selection);
      expect(await page.evaluate(() => {
        return document.activeElement.id;
      })).toBe('app');

      // Keyboard activation follows the same path; it is not an end/next event.
      await page.locator('button[data-act="guide-code"]').focus();
      await page.keyboard.press('Enter');
      await expect(page.locator('#guide')).toBeHidden();
      await resumeExplanation(page);
      const events = await ok(readit.socketPath, 'readit_guide_events', {
        workspace,
        after: before.guide_event_sequence
      });
      expect(events.events).toEqual([]);
      // Invoke local navigation without scrolling the explanation to its footer.
      await page.locator('button[data-act="guide-next"]').evaluate(button => {
        button.click();
      });
      await expect.poll(async () => {
        return (await ok(readit.socketPath, 'readit_state')).guide.id;
      }).toBe('second');
      await expect(page.locator('#guide')).toBeVisible();
      expect(await page.locator('#guide').evaluate(element => {
        return element.scrollTop;
      })).toBe(0);
      await page.locator('button[data-act="guide-back"]').evaluate(button => {
        button.click();
      });
      await expect.poll(async () => {
        return (await ok(readit.socketPath, 'readit_state')).guide.id;
      }).toBe('first');
      await expect.poll(async () => {
        return page.locator('#guide').evaluate(element => {
          return element.scrollTop;
        });
      }).toBeCloseTo(readingPoint, 0);
    });

    test('draft and pending Q&A stay intact, an answer never forces code view open', async ({
      page,
      readit
    }) => {
      const workspace = await loadTour(readit.socketPath);
      await page.locator('button[data-act="guide-ask"]').click();
      await page.locator('#guide-question').fill('合成テスト: なぜこのコードなの？');
      const draft = await page.locator('#guide-question').elementHandle();
      const before = await ok(readit.socketPath, 'readit_state');
      await hideExplanation(page);
      await page.setViewportSize({ width: config.width, height: 400 });
      await resumeExplanation(page);
      expect(await draft.evaluate(element => {
        return element === document.getElementById('guide-question');
      })).toBe(true);
      await expect(page.locator('#guide-question')).toHaveValue('合成テスト: なぜこのコードなの？');
      expect((await ok(readit.socketPath, 'readit_state')).guide_event_sequence)
        .toBe(before.guide_event_sequence);
      await page.locator('button[data-act="guide-send"]').click();
      const pending = await ok(readit.socketPath, 'readit_state');
      expect(pending.guide.pending_question).not.toBeNull();
      await hideExplanation(page);
      const events = await ok(readit.socketPath, 'readit_guide_events', { workspace, after: 0 });
      const questions = events.events.filter(event => {
        return event.action === 'question';
      });
      expect(questions).toHaveLength(1);
      await ok(readit.socketPath, 'readit_guide_answer', {
        workspace,
        id: 'first',
        question_sequence: questions[0].sequence,
        body: '合成テストの回答: 元のガイドで説明します。'
      });
      await expect(page.locator('#guide')).toBeHidden();
      await expect(page.locator('#guide-return')).toBeVisible();
      const answered = await ok(readit.socketPath, 'readit_state');
      expect(answered.guide.code_view).toBe(true);
      expect(answered.guide.pending_question).toBeNull();
      expect(answered.guide_tour.id).toBe('toggle-tour');
      expect(answered.guide_tour.index).toBe(0);
      await resumeExplanation(page);
      await expect(page.locator('.guide-question-text')).toContainText('なぜこのコードなの？');
      await expect(page.locator('.guide-answer')).toContainText('元のガイドで説明します。');
      const finalEvents = await ok(readit.socketPath, 'readit_guide_events', {
        workspace,
        after: 0
      });
      expect(finalEvents.events.filter(event => {
        return event.action === 'question';
      })).toHaveLength(1);
    });

    test('prediction draft and its Next gate survive code view', async ({ page, readit }) => {
      await loadTour(readit.socketPath, true);
      await page.locator('#guide-prediction').fill('合成予測: 値は523。');
      const before = await ok(readit.socketPath, 'readit_state');
      await hideExplanation(page);
      await resumeExplanation(page);
      await expect(page.locator('#guide-prediction')).toHaveValue('合成予測: 値は523。');
      await expect(page.locator('button[data-act="guide-next"]')).toBeDisabled();
      const after = await ok(readit.socketPath, 'readit_state');
      expect(after.guide_tour.predictions).toEqual([]);
      expect(after.guide_event_sequence).toBe(before.guide_event_sequence);
      await page.locator('button[data-act="prediction-record"]').click();
      await expect(page.locator('button[data-act="guide-next"]')).toBeEnabled();
    });

    test('clear and interruption remove the return control without resurrecting a guide', async ({
      page,
      readit
    }) => {
      const workspace = await loadTour(readit.socketPath);
      await hideExplanation(page);
      await ok(readit.socketPath, 'readit_guide_clear', { workspace });
      await expect(page.locator('#guide-return')).toBeHidden();
      await expect(page.locator('#guide')).toBeHidden();
      expect((await ok(readit.socketPath, 'readit_state')).guide).toBeNull();
      await loadTour(readit.socketPath);
      await expect(page.locator('#guide')).toBeVisible();
      expect((await ok(readit.socketPath, 'readit_state')).guide.code_view).toBe(false);
      await hideExplanation(page);
      await ok(readit.socketPath, 'readit_open', { workspace, path: 'other.js', line: 1 });
      await expect(page.locator('#guide-return')).toBeHidden();
      expect((await ok(readit.socketPath, 'readit_state')).guide).toBeNull();
      await ok(readit.socketPath, 'readit_open', { workspace, path: 'long.js', line: 523 });
      await expect(page.locator('#guide-return')).toBeHidden();
      await expect(page.locator('#guide')).toBeHidden();
    });
  });
}
