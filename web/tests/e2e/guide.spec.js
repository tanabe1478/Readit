// Prepared tours, overviews and bubble placement, ported from ui.rs and ui_e2e_tests.rs.
import fs from 'node:fs';
import path from 'node:path';
import { test, expect, control, ok } from './fixture.js';

const step = (id, line, text, file = 'sample.py') => ({ id, title: id, body: '解説', path: file, line, column: 1, expected_text: text });

test.describe('prepared tour', () => {
  test.use({ files: { 'sample.py': 'one = 1\ntwo = 2\nthree = 3\n' } });
  test('prepared tour navigates offline and revises unread steps atomically', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    const steps = [step('one', 1, 'one = 1'), step('two', 2, 'two = 2'), step('three', 3, 'three = 3')];
    const load = (steps) => ({ workspace: root, id: 'tour', event_sequence: 0, steps });
    const invalid = structuredClone(steps);
    invalid[2].expected_text = 'stale';
    expect((await control(s, 'readit_guide_load', load(invalid))).error).toBeTruthy();
    expect((await ok(s, 'readit_state')).guide_tour).toBeNull();
    await ok(s, 'readit_guide_load', load(steps));
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('2/3');
    let state = await ok(s, 'readit_state');
    expect(state.guide.id).toBe('two');
    expect(state.guide.pending_next).toBe(false);
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('#guide-question').fill('なぜ2なの？');
    await page.locator('button[data-act="guide-send"]').click();
    const question = (await ok(s, 'readit_state')).guide_event_sequence;
    // Pending generation does not prevent reading history.
    await page.locator('button[data-act="guide-back"]').click();
    expect((await ok(s, 'readit_state')).guide.id).toBe('one');
    const revise = (sequence, steps) => ({ workspace: root, id: 'tour', event_sequence: sequence, question_sequence: question, answer: '2はこの例で代入した値です。', steps });
    const replacement = [step('revised', 3, 'three = 3')];
    expect((await control(s, 'readit_guide_revise', revise(question, replacement))).error).toMatch(/navigation changed/);
    const badReplacement = structuredClone(replacement);
    badReplacement[0].expected_text = 'stale';
    const current = (await ok(s, 'readit_state')).guide_event_sequence;
    expect((await control(s, 'readit_guide_revise', revise(current, badReplacement))).error).toBeTruthy();
    expect((await ok(s, 'readit_state')).guide_tour.steps[2].id).toBe('three');
    await ok(s, 'readit_guide_revise', revise(current, replacement));
    expect((await ok(s, 'readit_state')).guide_tour.index).toBe(0);
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('2はこの例で代入した値です。');
    await page.locator('button[data-act="guide-next"]').click();
    expect((await ok(s, 'readit_state')).guide.id).toBe('revised');
    await expect(page.locator('button[data-act="guide-next"]')).toHaveText('完了');
    await page.locator('button[data-act="guide-next"]').click();
    state = await ok(s, 'readit_state');
    expect(state.guide).toBeNull();
    expect(state.guide_tour).toBeNull();
    expect((await control(s, 'readit_guide_revise', revise(state.guide_event_sequence, replacement))).error).toBeTruthy();
  });
});

test.describe('overview', () => {
  test.use({ files: { 'sample.py': 'one = 1\ntwo = 2\n', 'other.py': 'other = 3\n' } });
  test('overview preserves tour across detours and validates chapters', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    const steps = [
      { id: 'one', title: '代入', body: '最初の値', path: 'sample.py', line: 1, column: 1, expected_text: 'one = 1' },
      { id: 'two', title: '次の値', body: '次の代入', path: 'sample.py', line: 2, column: 1, expected_text: 'two = 2' },
    ];
    const overview = { title: '値の定義', summary: '二つの値を読む', relationships: 'sample.py → 値の定義', chapters: [
      { title: '最初', summary: '最初の代入を確認', start_step: 'one' },
      { title: '次', summary: '次の代入を確認', start_step: 'two' },
    ] };
    const load = (overview) => ({ workspace: root, id: 'overview-tour', event_sequence: 0, steps, overview });
    const missing = structuredClone(overview);
    missing.chapters[1].start_step = 'missing';
    expect((await control(s, 'readit_guide_load', load(missing))).error).toBeTruthy();
    expect((await ok(s, 'readit_state')).guide_tour).toBeNull();
    const unordered = structuredClone(overview);
    unordered.chapters[0].start_step = 'two';
    expect((await control(s, 'readit_guide_load', load(unordered))).error).toMatch(/partition/);
    await ok(s, 'readit_guide_load', load(overview));
    await expect(page.locator('#overview')).toBeVisible();
    await expect(page.locator('#overview')).toContainText('値の定義');
    await expect(page.locator('.tab', { hasText: '概観' })).toBeVisible();
    // Jump directly into the second chapter.
    await page.locator('button[data-act="chapter"][data-arg="1"]').click();
    let state = await ok(s, 'readit_state');
    expect(state.overview_visible).toBe(false);
    expect(state.guide.id).toBe('two');
    expect(state.guide_tour.seen_steps).toEqual(['two']);
    // A detour pauses the guide but keeps the tour.
    await page.locator('.tree-row', { hasText: 'other.py' }).click();
    await expect(page.locator('.tab.selected')).toContainText('other.py');
    state = await ok(s, 'readit_state');
    expect(state.guide).toBeNull();
    expect(state.guide_tour).not.toBeNull();
    await page.locator('button[data-act="overview"]').first().click();
    await expect(page.locator('#overview')).toBeVisible();
    await page.locator('button[data-act="chapter"][data-arg="1"]').click();
    expect((await ok(s, 'readit_state')).guide.id).toBe('two');
    // Completing the tour keeps its overview.
    await page.locator('button[data-act="guide-next"]').click();
    state = await ok(s, 'readit_state');
    expect(state.guide).toBeNull();
    expect(state.guide_tour).not.toBeNull();
    await page.locator('#topbar button[data-act="overview"]').click();
    await page.locator('button[data-act="chapter"][data-arg="0"]').click();
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('#guide-question').fill('この値は？');
    await page.locator('button[data-act="guide-send"]').click();
    const seq = (await ok(s, 'readit_state')).guide_event_sequence;
    const revise = { workspace: root, id: 'overview-tour', event_sequence: seq, question_sequence: seq, answer: '最初の値です', steps: [] };
    expect((await control(s, 'readit_guide_revise', revise)).error).toMatch(/overview/);
    revise.overview = (await ok(s, 'readit_state')).guide_tour.overview;
    await ok(s, 'readit_guide_revise', revise);
    await expect(page.locator('#guide')).toContainText('最初の値です');
    // A stale target cannot replace the visible overview.
    await page.keyboard.press('Meta+a');
    await page.keyboard.type('changed');
    await page.locator('#topbar button[data-act="overview"]').click();
    await expect(page.locator('#overview')).toContainText('コードに変更があります');
    await expect(page.locator('button[data-act="chapter"]')).toHaveCount(0);
    await ok(s, 'readit_guide_clear', { workspace: root });
    state = await ok(s, 'readit_state');
    expect(state.guide_tour).toBeNull();
    expect(state.overview_visible).toBe(false);
  });
});

test.describe('unread files', () => {
  test.use({ files: { 'a-open.py': 'opened = 1\n', 'z-unread.py': 'target = 2\n' } });
  test('overview reports unread files as current until they actually change', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    const steps = [
      { id: 'one', title: '入口', body: '開いているファイル', path: 'a-open.py', line: 1, column: 1, expected_text: 'opened = 1' },
      { id: 'two', title: '対象', body: 'まだ読んでいないファイル', path: 'z-unread.py', line: 1, column: 1, expected_text: 'target = 2' },
    ];
    const overview = { title: '未読', summary: '開いていないファイルを読む', relationships: 'a-open.py → z-unread.py', chapters: [
      { title: '入口', summary: '最初の値', start_step: 'one' }, { title: '対象', summary: '次の値', start_step: 'two' }] };
    await ok(s, 'readit_guide_load', { workspace: root, id: 'unread-tour', event_sequence: 0, steps, overview });
    const tabs = (await ok(s, 'readit_state')).tabs.map((t) => path.basename(t.path));
    expect(tabs).not.toContain('z-unread.py');
    await expect(page.locator('#overview')).not.toContainText('コードに変更があります');
    fs.writeFileSync(path.join(readit.project, 'z-unread.py'), 'target = 99\n');
    // The overview re-reads unopened files on focus and every few seconds.
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await expect(page.locator('#overview')).toContainText('コードに変更があります', { timeout: 8000 });
  });
});

test.describe('bubble placement', () => {
  const source = Array.from({ length: 160 }, (_, i) => `value_${i + 1} = ${i + 1}\n`).join('');
  test.use({ files: { 'sample.py': source }, viewport: { width: 1400, height: 1000 } });

  async function bubble(page) {
    await expect(page.locator('#guide')).toBeVisible();
    await page.waitForTimeout(50);
    return page.locator('#guide').boundingBox();
  }
  async function dragTo(page, x, y) {
    const handle = await page.locator('.guide-handle').boundingBox();
    const origin = await bubble(page);
    const start = { x: handle.x + handle.width / 2, y: handle.y + handle.height / 2 };
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    await page.mouse.move(start.x + x - origin.x, start.y + y - origin.y, { steps: 4 });
    await page.mouse.up();
  }
  async function wheel(page, dy) {
    await page.mouse.move(1250, 650);
    await page.mouse.wheel(0, dy);
    await page.waitForTimeout(150);
  }

  test('guide scroll then drag to bottom', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    await ok(s, 'readit_guide_load', { workspace: root, id: 'scroll-drag', event_sequence: 0, steps: [{
      id: 'one', path: 'sample.py', line: 40, column: 1, expected_text: 'value_40 = 40\nvalue_41 = 41\nvalue_42 = 42',
      title: 'Read these three assignments', body: 'Each line binds a value.\n\nScroll the source, then drag this explanation.' }] });
    const initial = await bubble(page);
    expect(initial.height).toBeLessThan(400);
    // The annotation sits near the top with the bubble below it.
    const anchor = await page.locator('.lines[data-view="editor"] .row[data-line="39"]').boundingBox();
    expect(initial.y).toBeGreaterThanOrEqual(anchor.y);
    // Scroll before touching the bubble: the automatic guide follows its code.
    // (Upward, so the three annotated lines stay in view.)
    await wheel(page, -150);
    const scrolled = await bubble(page);
    expect(scrolled.y).not.toBeCloseTo(initial.y, 0);
    const viewportBefore = (await ok(s, 'readit_state')).selection.viewport;
    await dragTo(page, 650, 30);
    const pinned = await bubble(page);
    expect(Math.abs(pinned.y - 30)).toBeLessThan(3);
    await wheel(page, 100);
    const afterScroll = await bubble(page);
    const viewportAfter = (await ok(s, 'readit_state')).selection.viewport;
    expect(viewportAfter).not.toEqual(viewportBefore);
    expect(afterScroll.y).toBeCloseTo(pinned.y, 0);
    expect(afterScroll.x).toBeCloseTo(pinned.x, 0);
    const destination = 1000 - afterScroll.height - 30;
    await dragTo(page, 650, destination);
    const moved = await bubble(page);
    expect(Math.abs(moved.y - destination)).toBeLessThan(3);
    expect(moved.y + moved.height).toBeLessThanOrEqual(1000);
    const state = await ok(s, 'readit_state');
    expect(state.selection.text).toBe('value_40 = 40\nvalue_41 = 41\nvalue_42 = 42');
    expect(state.tabs.every((t) => t.dirty === false)).toBe(true);
    expect(fs.readFileSync(path.join(readit.project, 'sample.py'), 'utf8')).toBe(source);
  });
});
