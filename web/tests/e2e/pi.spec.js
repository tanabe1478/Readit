// The pi extension end to end: a scripted (faux) model drives Readit through the
// MCP tools, and every guide button is pressed in the browser. No real model or
// network is used. pi-random.spec.js repeats the buttons in random order.
import { fauxAssistantMessage } from '@earendil-works/pi-ai';
import { test, expect } from './fixture.js';
import { startPi, tool, call, lastResult, delivered, step, state } from './pi-harness.js';

test.use({ files: { 'sample.py': 'one = 1\ntwo = 2\nthree = 3\n', 'store.py': 'class Store:\n    cache = {}\n' } });
test.setTimeout(120_000);

const unread = [step('guess', 2, 'two = 2', { kind: 'prediction', prompt: 'two は何になる？' }), step('three', 3, 'three = 3')];
const evidence = { label: 'キャッシュの保持', path: 'store.py', line: 2, column: 5, expected_text: 'cache = {}' };
/** The tour the scripted model registers, anchored to the state it just read. */
const tour = (s) => ({
  workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence,
  steps: [step('one', 1, 'one = 1'), ...unread],
  overview: {
    title: '値の定義', summary: '三つの値を読む', relationships: 'sample.py → store.py',
    claims: [{ id: 'store-owns', statement: 'Store がキャッシュを持つ', confidence: 'source_confirmed', evidence: [evidence] }],
    chapters: [{ title: '最初', summary: '最初の代入', start_step: 'one' }, { title: '残り', summary: '予測と確認', start_step: 'guess' }],
  },
});

async function loadTour(pi, page) {
  await pi.turn('sample.py の読み方を案内して', [
    call('state', {}),
    (context) => call('guide_load', tour(lastResult(context))),
    fauxAssistantMessage('ガイドを登録しました'),
  ]);
  expect(pi.toolCalls()).toEqual([tool('state'), tool('guide_load')]);
  await expect(page.locator('#overview')).toContainText('値の定義');
}

test('the model loads a tour through the MCP tools; overview, chapter and evidence buttons work', async ({ page, readit }) => {
  const pi = await startPi(readit);
  try {
    await loadTour(pi, page);
    expect((await state(readit)).guide_tour.id).toBe('tour');
    // A chapter opens its first bubble.
    await page.locator('button[data-act="chapter"][data-arg="1"]').click();
    await expect(page.locator('#guide')).toContainText('two は何になる？');
    expect((await state(readit)).guide.id).toBe('guess');
    // The overview button returns to the overview and keeps the tour.
    await page.locator('#topbar button[data-act="overview"]').click();
    await expect(page.locator('#overview')).toBeVisible();
    // Evidence opens the cited code as a detour; the tour stays.
    await page.locator('#overview .evidence').first().click();
    await expect(page.locator('.tab.selected')).toContainText('store.py');
    expect((await state(readit)).selection.text).toBe('cache = {}');
    expect((await state(readit)).guide_tour.id).toBe('tour');
    await page.locator('#topbar button[data-act="overview"]').click();
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await expect(page.locator('#guide')).toContainText('one の解説');
    // None of this asked the model anything.
    expect(pi.faux.state.callCount).toBe(3);
  } finally {
    await pi.stop();
  }
});

test('next, back, prediction and end run in Readit without waking the model', async ({ page, readit }) => {
  const pi = await startPi(readit);
  try {
    await loadTour(pi, page);
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await expect(page.locator('#guide')).toContainText('one の解説');
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('two は何になる？');
    // A prediction step disables Next until the reader answers.
    const next = page.locator('button[data-act="guide-next"]');
    await expect(next).toBeDisabled();
    await expect(next).toHaveAttribute('title', /予測を記録するか/);
    await page.locator('#guide-prediction').fill('2 になる');
    await page.locator('button[data-act="prediction-record"]').click();
    await expect.poll(async () => (await state(readit)).guide_tour.predictions.length).toBe(1);
    await expect(next).toBeEnabled();
    await next.click();
    await expect(page.locator('#guide')).toContainText('three の解説');
    await page.locator('button[data-act="guide-back"]').click();
    await expect(page.locator('#guide')).toContainText('two は何になる？');
    expect((await state(readit)).guide_tour.index).toBe(1);
    // End closes the bubble; a tour with an overview stays reachable from the overview button.
    await page.locator('button[data-act="guide-end"]').click();
    await expect(page.locator('#guide')).toBeHidden();
    const after = await state(readit);
    expect(after.guide).toBeNull();
    expect(after.guide_tour.id).toBe('tour');
    await page.locator('#topbar button[data-act="overview"]').click();
    await expect(page.locator('#overview')).toContainText('値の定義');
    expect(pi.faux.state.callCount).toBe(3);
    expect(pi.userTexts()).toHaveLength(1);
  } finally {
    await pi.stop();
  }
});

test('the question button delivers the question to the session and the answer returns to the bubble', async ({ page, readit }) => {
  const pi = await startPi(readit);
  try {
    await loadTour(pi, page);
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await expect(page.locator('#guide')).toContainText('one の解説');
    // Cancel closes the form without sending.
    await page.locator('button[data-act="guide-ask"]').click();
    await expect(page.locator('#guide-question')).toBeVisible();
    await page.locator('button[data-act="guide-cancel"]').click();
    await expect(page.locator('#guide-question')).toBeHidden();
    // The script for the model's reaction: read the state, then revise the tour with an answer.
    pi.faux.setResponses([
      call('state', {}),
      (context) => {
        const s = lastResult(context);
        const question = delivered(context);
        return call('guide_revise', {
          workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence, question_sequence: question.event.sequence,
          answer: `${question.event.question} への答え: 最初の値です`, steps: unread, overview: s.guide_tour.overview,
        });
      },
      fauxAssistantMessage('答えました'),
    ]);
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('#guide-question').fill('なぜ 1 なの？');
    await page.locator('button[data-act="guide-send"]').click();
    await expect(page.locator('#guide')).toContainText('なぜ 1 なの？');
    // The watcher hands the question to the session as a user message, and the scripted model answers.
    await pi.settled(2);
    const prompt = pi.userTexts()[1];
    expect(prompt).toContain('Readit: the user asked a question in a guide bubble.');
    expect(prompt).toContain('Question: なぜ 1 なの？');
    expect(prompt).toContain('prepared tour "tour"');
    await expect(page.locator('#guide')).toContainText('なぜ 1 なの？ への答え: 最初の値です');
    expect(pi.toolCalls().slice(2)).toEqual([tool('state'), tool('guide_revise')]);
    const after = await state(readit);
    expect(after.guide.pending_question).toBeNull();
    expect(after.guide.id).toBe('one');
    // Reopening the same step from the overview keeps the answer, and a question
    // that is still pending survives the round trip until the model answers it.
    await page.locator('#topbar button[data-act="overview"]').click();
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await expect(page.locator('#guide')).toContainText('なぜ 1 なの？ への答え: 最初の値です');
    pi.faux.setResponses([
      call('state', {}),
      (context) => {
        const s = lastResult(context);
        const question = delivered(context);
        return call('guide_revise', {
          workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence, question_sequence: question.event.sequence,
          answer: '二つめの答え', steps: unread, overview: s.guide_tour.overview,
        });
      },
      fauxAssistantMessage('答えました'),
    ]);
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('#guide-question').fill('もう一つ');
    await page.locator('button[data-act="guide-send"]').click();
    await page.locator('#topbar button[data-act="overview"]').click();
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await expect(page.locator('#guide')).toContainText('もう一つ');
    await pi.settled(3);
    await expect(page.locator('#guide')).toContainText('二つめの答え');
    expect((await state(readit)).guide.pending_question).toBeNull();
    // The revised route is still there and Next moves along it locally.
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('two は何になる？');
  } finally {
    await pi.stop();
  }
});

test('on a single explanation, Next asks the model for the following bubble', async ({ page, readit }) => {
  const pi = await startPi(readit);
  try {
    const show = (id, line, expected) => (context) => {
      const s = lastResult(context);
      return call('guide_show', { workspace: s.workspace, id, title: id, body: `${id} の解説`, path: 'sample.py', line, column: 1, expected_text: expected, event_sequence: s.guide_event_sequence });
    };
    await pi.turn('1行目を説明して', [call('state', {}), show('first', 1, 'one = 1'), fauxAssistantMessage('表示しました')]);
    await expect(page.locator('#guide')).toContainText('first の解説');
    pi.faux.setResponses([call('state', {}), show('second', 2, 'two = 2'), fauxAssistantMessage('続けました')]);
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('次の解説を待っています');
    await pi.settled(2);
    expect(pi.userTexts()[1]).toContain('Readit: the user pressed Next on a guide bubble');
    await expect(page.locator('#guide')).toContainText('second の解説');
    expect((await state(readit)).selection.text).toBe('two = 2');
    await page.locator('button[data-act="guide-end"]').click();
    await expect(page.locator('#guide')).toBeHidden();
    expect((await state(readit)).guide).toBeNull();
  } finally {
    await pi.stop();
  }
});
