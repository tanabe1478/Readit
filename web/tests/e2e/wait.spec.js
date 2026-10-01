// Questions from guide bubbles reach an AI session without the user announcing them:
// tools/readit_wait.py (Claude Code runs it in the background) and the pi extension's loop.
import { spawn } from 'node:child_process';
import path from 'node:path';
import { test, expect, ok, repo } from './fixture.js';
import { ReaditWatcher, formatPrompt } from '../../../integrations/pi/watcher.ts';

const waitScript = path.join(repo, 'tools/readit_wait.py');
test.use({ files: { 'sample.py': 'one = 1\ntwo = 2\n' } });

async function loadTour(socket) {
  const state = await ok(socket, 'readit_state');
  const step = (id, line, text) => ({ id, title: id, body: '解説', path: 'sample.py', line, column: 1, expected_text: text });
  await ok(socket, 'readit_guide_load', { workspace: state.workspace, id: 'tour', event_sequence: state.guide_event_sequence,
    steps: [step('one', 1, 'one = 1'), step('two', 2, 'two = 2')] });
}

async function ask(page, text) {
  await page.locator('button[data-act="guide-ask"]').click();
  await page.locator('#guide-question').fill(text);
  await page.locator('button[data-act="guide-send"]').click();
}

test('readit_wait.py returns the question and, when the guide ends, ended', async ({ page, readit }) => {
  await loadTour(readit.socketPath);
  const run = (args) => new Promise((resolve) => {
    const child = spawn('python3', [waitScript, '--socket', readit.socketPath, '--interval', '0.1', ...args]);
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('exit', () => resolve(JSON.parse(out.trim())));
  });
  const waiting = run(['--stop-when-idle']);
  await page.locator('button[data-act="guide-next"]').click();
  await ask(page, 'なぜ2なの？');
  const result = await waiting;
  expect(result.status).toBe('question');
  expect(result.event.question).toBe('なぜ2なの？');
  expect(result.tour_id).toBe('tour');
  expect(formatPrompt(result)).toContain(`question_sequence ${result.event.sequence}`);
  const ended = run(['--stop-when-idle', '--after', String(result.latest_sequence)]);
  await ok(readit.socketPath, 'readit_guide_clear', { workspace: result.workspace });
  expect((await ended).status).toBe('ended');
});

test('the pi watcher delivers each question once and keeps waiting', async ({ page, readit }) => {
  const delivered = [];
  const watcher = new ReaditWatcher({ python: 'python3', script: waitScript, socket: readit.socketPath,
    deliver: (prompt) => delivered.push(prompt), notify: () => {} });
  watcher.start();
  try {
    await expect.poll(() => watcher.active).toBe(true);
    // Give the waiter a moment to read the current sequence before the tour starts.
    await page.waitForTimeout(1500);
    await loadTour(readit.socketPath);
    await ask(page, '最初の質問');
    await expect.poll(() => delivered.length, { timeout: 10000 }).toBe(1);
    expect(delivered[0]).toContain('Question: 最初の質問');
    await ok(readit.socketPath, 'readit_guide_revise', { workspace: (await ok(readit.socketPath, 'readit_state')).workspace,
      id: 'tour', event_sequence: (await ok(readit.socketPath, 'readit_state')).guide_event_sequence,
      question_sequence: JSON.parse(delivered[0].split('\n').at(-1)).event.sequence, answer: '回答です', steps: [
        { id: 'two', title: 'two', body: '解説', path: 'sample.py', line: 2, column: 1, expected_text: 'two = 2' }] });
    await ask(page, '二つめの質問');
    await expect.poll(() => delivered.length, { timeout: 10000 }).toBe(2);
    expect(delivered[1]).toContain('Question: 二つめの質問');
    await page.waitForTimeout(1500);
    expect(delivered.length).toBe(2);
  } finally {
    watcher.stop();
  }
});

test('a recorded prediction does not wake readit_wait.py; a question still does', async ({ page, readit }) => {
  const state = await ok(readit.socketPath, 'readit_state');
  await ok(readit.socketPath, 'readit_guide_load', { workspace: state.workspace, id: 'tour', event_sequence: state.guide_event_sequence,
    steps: [{ id: 'guess', kind: 'prediction', prompt: 'どうなる？', title: 'guess', body: '解説', path: 'sample.py', line: 1, column: 1, expected_text: 'one = 1' },
      { id: 'two', title: 'two', body: '解説', path: 'sample.py', line: 2, column: 1, expected_text: 'two = 2' }] });
  const child = spawn('python3', [waitScript, '--socket', readit.socketPath, '--interval', '0.1', '--stop-when-idle']);
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const exited = new Promise((resolve) => child.on('exit', resolve));
  try {
    await page.waitForTimeout(800);
    await page.locator('#guide-prediction').fill('1のまま');
    await page.locator('button[data-act="prediction-record"]').click();
    await expect.poll(async () => (await ok(readit.socketPath, 'readit_state')).guide_tour.predictions.length).toBe(1);
    await page.waitForTimeout(1000);
    expect(child.exitCode).toBeNull();
    await page.locator('button[data-act="guide-next"]').click();
    await ask(page, '予測の後の質問');
    await exited;
    const result = JSON.parse(out.trim());
    expect(result.status).toBe('question');
    expect(result.event.question).toBe('予測の後の質問');
  } finally {
    child.kill();
  }
});
