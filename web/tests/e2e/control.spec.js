// MCP control requests, ported from the native ui.rs control tests.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { test, expect, control, ok, lineText, repo, makeProject, startServer, openFolders } from './fixture.js';

test.describe('reveal, read and user context', () => {
  test.use({ files: { 'sample.py': 'first = 1\nsecond = first + 1\n' } });
  test('control reveals ranges, reads unsaved buffers and respects user context', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    const result = await ok(s, 'readit_open', { workspace: root, path: 'sample.py', line: 2, column: 10, end_line: 2, end_column: 15 });
    expect(result.selection.text).toBe('first');
    expect(result.cursor.line).toBe(2);
    expect((await control(s, 'readit_open', { workspace: '/wrong-project', path: 'sample.py' })).error).toBeTruthy();
    const passwd = await control(s, 'readit_read', { workspace: root, path: '/etc/passwd' });
    expect(passwd.error).toBe('path is not a workspace file or a definition returned by this editor');
    // The user edits; the control API sees the unsaved text.
    await page.keyboard.press('End');
    await page.keyboard.press('Backspace');
    await page.keyboard.type('2');
    const read = await ok(s, 'readit_read', { workspace: root, path: 'sample.py', start_line: 2, line_count: 1 });
    expect(read.text).toBe('second = first + 2');
    expect(read.unsaved).toBe(true);
    await page.keyboard.press('Meta+p');
    expect((await control(s, 'readit_open', { workspace: root, path: 'sample.py' })).error).toMatch(/dialog/);
    await expect(page.locator('#overlay')).toBeVisible();
    expect(fs.readFileSync(path.join(readit.project, 'sample.py'), 'utf8')).toBe('first = 1\nsecond = first + 1\n');
  });
});

test.describe('files the listing left out', () => {
  test.use({ files: { 'listed.py': 'listed = 1\n' } });
  test('control lists project files created after opening and still refuses unsafe paths', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    // Files past the listing cap take the same path as files created after opening.
    fs.mkdirSync(path.join(readit.project, 'later'));
    fs.writeFileSync(path.join(readit.project, 'later/added.py'), 'added = 2\n');
    fs.writeFileSync(path.join(readit.project, 'later/tour.py'), 'toured = 3\n');
    fs.writeFileSync(path.join(readit.project, '.env.local'), 'SECRET=1\n');
    fs.symlinkSync(path.join(readit.project, 'listed.py'), path.join(readit.project, 'link.py'));
    // The tree loaded the root before `later/` existed; the control API still reads it.
    await expect(page.locator('.tree-row[data-tree="later"]')).toHaveCount(0);
    const read = await ok(s, 'readit_read', { workspace: root, path: 'later/added.py' });
    expect(read.text).toBe('added = 2\n');
    expect((await ok(s, 'readit_files', { workspace: root, filter: 'later/' })).files.map((f) => f.path)).toEqual(['later/added.py', 'later/tour.py']);
    await ok(s, 'readit_guide_load', {
      workspace: root, id: 'later-tour', event_sequence: 0,
      steps: [{ id: 's1', title: '後から作ったファイル', body: '起動後に作ったファイルもツアーに使えます。', path: 'later/tour.py', line: 1, column: 1, expected_text: 'toured = 3' }],
    });
    expect((await ok(s, 'readit_state')).selection.text).toBe('toured = 3');
    // Opening it reloads the stale root and opens `later/` in the tree.
    await page.waitForFunction(() => window.readitIdle());
    await expect(page.locator('.tree-row[data-tree="later/tour.py"]')).toBeVisible();
    const refused = 'path is not a workspace file or a definition returned by this editor';
    for (const p of ['.env.local', 'link.py', '../outside.py', 'later', 'missing.py', '.git/config']) {
      expect((await control(s, 'readit_read', { workspace: root, path: p })).error, p).toBe(refused);
    }
    expect((await ok(s, 'readit_files', { workspace: root, filter: 'env' })).total).toBe(0);
  });
});

test.describe('repositories inside a plain folder', () => {
  test('a repository inside a folder lists what Git lists', async ({ page }) => {
    const project = makeProject({
      'notes.md': '# notes\n',
      'app/.gitignore': 'out/\n',
      'app/src/main.py': 'main = 1\n',
      'app/out/generated.py': 'generated = 1\n',
      'loose/out/kept.py': 'kept = 1\n',
    });
    execFileSync('git', ['-C', path.join(project, 'app'), 'init', '-q'], {
      env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }, stdio: 'ignore' });
    const server = await startServer(project);
    try {
      await page.goto(server.url);
      await page.waitForFunction(() => window.readitReady === true && window.readitIdle());
      const root = (await ok(server.socketPath, 'readit_state')).workspace;
      const files = (await ok(server.socketPath, 'readit_files', { workspace: root })).files.map((f) => f.path).sort();
      // Ignored output inside the repository is left out; folders outside it are walked as before.
      expect(files).toEqual(['app/.gitignore', 'app/src/main.py', 'loose/out/kept.py', 'notes.md']);
      // The tree applies the same rules folder by folder.
      await openFolders(page, 'app', 'loose');
      await expect(page.locator('.tree-row[data-tree="app/src"]')).toBeVisible();
      await expect(page.locator('.tree-row[data-tree="app/out"]')).toHaveCount(0);
      await expect(page.locator('.tree-row[data-tree="loose/out"]')).toBeVisible();
    } finally {
      server.stop();
      fs.rmSync(project, { recursive: true, force: true });
    }
  });
});

test.describe('folders load when opened', () => {
  test.use({ files: {
    'README.md': '# top\n',
    'deep/a/b/c/target.py': 'target = 1\n',
    'deep/a/sibling.py': 'sibling = 1\n',
    'wide/one.py': 'one = 1\n',
  } });
  test('the tree starts closed, loads opened folders and reveals files opened elsewhere', async ({ page }) => {
    // Only the top folder is listed at first.
    await expect(page.locator('.tree-row')).toHaveCount(3);
    await expect(page.locator('.tree-row[data-tree="deep/a"]')).toHaveCount(0);
    await openFolders(page, 'deep');
    await expect(page.locator('.tree-row[data-tree="deep/a"]')).toBeVisible();
    await expect(page.locator('.tree-row[data-tree="deep/a/sibling.py"]')).toHaveCount(0);
    // Quick open searches the whole project, not just the folders opened so far.
    await page.keyboard.press('Meta+p');
    await page.keyboard.type('target');
    await page.waitForFunction(() => window.readitIdle());
    await expect(page.locator('.pick').first()).toContainText('deep/a/b/c/target.py');
    await page.keyboard.press('Enter');
    await expect(page.locator('.tab.selected')).toContainText('target.py');
    await page.waitForFunction(() => window.readitIdle());
    // Opening a file opens the folders above it, like an editor revealing the active file.
    await expect(page.locator('.tree-row[data-tree="deep/a/b/c/target.py"]')).toBeVisible();
    await expect(page.locator('.tree-row[data-tree="deep/a/sibling.py"]')).toBeVisible();
    await expect(page.locator('.tree-row[data-tree="wide/one.py"]')).toHaveCount(0);
  });
});

test.describe('pinning', () => {
  test.use({ files: { 'main.py': 'value = 1\n', 'related.py': 'def related():\n    return 2\n' } });
  test('pin preserves navigation and tracks unsaved changes', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    await ok(s, 'readit_open', { workspace: root, path: 'main.py' });
    const before = await ok(s, 'readit_state');
    const pinned = await ok(s, 'readit_pin', { workspace: root, path: 'related.py', line: 1 });
    expect(pinned.active_path).toBe(before.active_path);
    expect(pinned.cursor).toEqual(before.cursor);
    await expect(page.locator('#pinned')).toBeVisible();
    expect(await lineText(page, 1, 'pinned')).toBe('    return 2');
    expect((await control(s, 'readit_pin', { workspace: root, path: '/etc/passwd', line: 1 })).error).toBeTruthy();
    await page.keyboard.press('Meta+a');
    await page.keyboard.type('value = 3\n');
    await ok(s, 'readit_pin', { workspace: root, path: 'main.py', line: 1 });
    expect(await lineText(page, 0, 'pinned')).toBe('value = 3');
    await page.keyboard.press('Meta+a');
    await page.keyboard.type('value = 4\n');
    expect((await ok(s, 'readit_state')).pinned.source_changed).toBe(true);
    await expect(page.locator('#pinned-head')).toContainText('本文に変更あり');
    expect(await lineText(page, 0, 'pinned')).toBe('value = 3');
    await ok(s, 'readit_pin', { workspace: root, path: 'main.py', line: 1 });
    expect((await ok(s, 'readit_state')).pinned.source_changed).toBe(false);
    await ok(s, 'readit_unpin', { workspace: root });
    await expect(page.locator('#pinned')).toBeHidden();
    expect(await lineText(page, 0)).toBe('value = 4');
    expect(fs.readFileSync(path.join(readit.project, 'main.py'), 'utf8')).toBe('value = 1\n');
  });
});

test.describe('distant lines', () => {
  const text = Array.from({ length: 400 }, (_, i) => `value_${i} = ${i}\n`).join('');
  test.use({ files: { 'long.py': text } });
  test('control reveals distant lines after initial layout', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    await ok(s, 'readit_open', { workspace: root, path: 'long.py', line: 300, column: 1, end_line: 300, end_column: 10 });
    await ok(s, 'readit_pin', { workspace: root, path: 'long.py', line: 200 });
    const state = await ok(s, 'readit_state');
    expect(state.selection.viewport.start_line).toBeLessThanOrEqual(300);
    expect(state.selection.viewport.end_line).toBeGreaterThanOrEqual(300);
    expect(state.selection.text).toBe('value_299');
    await expect(page.locator('.lines[data-view="editor"] .row[data-line="299"]')).toBeInViewport();
    await expect(page.locator('.lines[data-view="pinned"] .row[data-line="199"]')).toBeInViewport();
  });
});

test.describe('guide bubbles', () => {
  test.use({ files: { 'sample.py': 'value = 42\n' } });
  test('guide checks source and tracks user responses', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    const args = { workspace: root, id: 'step-1', title: '値の代入', body: 'valueに42を代入します。', path: 'sample.py', line: 1, column: 1, expected_text: 'value = 42', event_sequence: 0 };
    await ok(s, 'readit_guide_show', args);
    expect((await ok(s, 'readit_state')).selection.text).toBe('value = 42');
    await expect(page.locator('#guide')).toBeVisible();
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('button[data-act="guide-send"]').click();
    expect((await ok(s, 'readit_state')).guide_event_sequence).toBe(0);
    await expect(page.locator('#guide')).toContainText('質問を1〜2,000文字で入力してください。');
    await page.locator('#guide-question').fill('なぜ42なのですか？');
    await page.locator('button[data-act="guide-send"]').click();
    await page.evaluate(() => document.querySelector('button[data-act="guide-send"]')?.click());
    expect((await ok(s, 'readit_state')).guide_event_sequence).toBe(1);
    expect((await control(s, 'readit_guide_show', args)).error).toMatch(/read guide events/);
    const events = await ok(s, 'readit_guide_events', { workspace: root, after: 0 });
    expect(events.events[0].action).toBe('question');
    expect(events.events[0].question).toBe('なぜ42なのですか？');
    expect(events.events[0].expected_text).toBe('value = 42');
    const answer = (n) => ({ workspace: root, id: 'step-1', question_sequence: n, body: 'このテストの例として置いた値です。' });
    expect((await control(s, 'readit_guide_answer', answer(9))).error).toBeTruthy();
    await ok(s, 'readit_guide_answer', answer(1));
    await expect(page.locator('#guide')).toContainText('このテストの例として置いた値です。');
    await page.locator('button[data-act="guide-ask"]').click();
    await page.locator('#guide-question').fill('43にしても動きますか？');
    await page.keyboard.press('Enter');
    expect((await control(s, 'readit_guide_answer', answer(1))).error).toBeTruthy();
    const second = await ok(s, 'readit_guide_events', { workspace: root, after: 1 });
    expect(second.events[0].previous_question).toBe('なぜ42なのですか？');
    await ok(s, 'readit_guide_answer', answer(2));
    await page.locator('button[data-act="guide-next"]').click();
    await expect(page.locator('#guide')).toContainText('次の解説を待っています…');
    const nextSequence = (await ok(s, 'readit_state')).guide_event_sequence;
    await page.locator('button[data-act="guide-next"]').click();
    expect((await ok(s, 'readit_state')).guide_event_sequence).toBe(nextSequence);
    expect((await ok(s, 'readit_state')).guide.pending_next).toBe(true);
    // A stale expected_text is refused; then the user edits and the guide is interrupted.
    expect((await control(s, 'readit_guide_show', { ...args, event_sequence: 3, expected_text: 'wrong' })).error).toMatch(/does not match/);
    await ok(s, 'readit_guide_show', { ...args, event_sequence: 3 });
    await page.keyboard.press('End');
    await page.keyboard.press('Backspace');
    await page.keyboard.type('3');
    const interrupted = await ok(s, 'readit_guide_events', { workspace: root, after: 3 });
    expect(interrupted.events.at(-1).action).toBe('interrupted');
    await expect(page.locator('#guide')).toBeHidden();
    const seq = (await ok(s, 'readit_state')).guide_event_sequence;
    await ok(s, 'readit_guide_show', { ...args, id: 'escape', title: '終了テスト', body: 'Escで終了', expected_text: 'value = 43', event_sequence: seq });
    await page.keyboard.press('Escape');
    const ended = await ok(s, 'readit_guide_events', { workspace: root, after: seq });
    expect(ended.events.at(-1).action).toBe('end');
    expect(fs.readFileSync(path.join(readit.project, 'sample.py'), 'utf8')).toBe('value = 42\n');
  });
});

test.describe('MCP stdio relay', () => {
  test.use({ files: { 'sample.py': 'x = 1\n' } });
  test('tools/readit_mcp.py drives the browser editor unchanged', async ({ readit }) => {
    const mcp = spawn('python3', [path.join(repo, 'tools/readit_mcp.py'), '--socket', readit.socketPath]);
    let buffer = '';
    const replies = [];
    const waiters = [];
    mcp.stdout.on('data', (d) => {
      buffer += d;
      let i;
      while ((i = buffer.indexOf('\n')) >= 0) {
        const message = JSON.parse(buffer.slice(0, i));
        buffer = buffer.slice(i + 1);
        (waiters.shift() ?? ((m) => replies.push(m)))(message);
      }
    });
    let id = 0;
    const rpc = (method, params) => new Promise((resolve) => {
      waiters.push(resolve);
      mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) + '\n');
    });
    await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } });
    mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    const listed = await rpc('tools/list', {});
    expect(listed.result.tools.map((t) => t.name)).toContain('readit_guide_load');
    const state = await rpc('tools/call', { name: 'readit_state', arguments: {} });
    expect(state.result.isError).toBe(false);
    expect(state.result.structuredContent.active_path).toBe(path.join(readit.project, 'sample.py'));
    const read = await rpc('tools/call', { name: 'readit_read', arguments: { workspace: state.result.structuredContent.workspace, path: 'sample.py' } });
    expect(read.result.structuredContent.text).toBe('x = 1\n');
    mcp.stdin.end();
  });
});

test.describe('without a browser window', () => {
  test.use({ files: { 'a.py': 'a = 1\n' } });
  test('requests fail clearly when no window is attached', async ({ page, readit }) => {
    await page.goto('about:blank');
    await expect.poll(async () => (await control(readit.socketPath, 'readit_state')).error).toMatch(/not open in a browser/);
  });
});

test.describe('wrapped rows', () => {
  const long = 'x = "' + 'あいう'.repeat(80) + '"\n';
  const text = long + Array.from({ length: 400 }, (_, i) => `value_${i} = ${i}\n`).join('');
  test.use({ files: { 'wrap.py': text } });
  test('wrapping renders a window of rows and still reveals distant lines', async ({ page, readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    await ok(s, 'readit_view', { workspace: root, wrap: true });
    await expect(page.locator('.lines.wrap')).toHaveCount(1);
    const first = await page.locator('.lines[data-view="editor"] .row[data-line="0"]').boundingBox();
    const lh = await page.locator('.lines[data-view="editor"]').evaluate((el) => Number(el.dataset.lh));
    expect(first.height).toBeGreaterThan(lh * 1.5);
    // Clicking on the second visual row of the wrapped line lands inside that line.
    await page.mouse.click(first.x + 200, first.y + first.height - lh / 2);
    const cursor = (await ok(s, 'readit_state')).cursor;
    expect(cursor.line).toBe(1);
    expect(cursor.column).toBeGreaterThan(40);
    expect(await page.locator('.lines[data-view="editor"] .row').count()).toBeLessThan(200);
    const opened = await ok(s, 'readit_open', { workspace: root, path: 'wrap.py', line: 350, column: 1, end_line: 350, end_column: 10 });
    expect(opened.selection.text).toBe('value_348');
    await expect(page.locator('.lines[data-view="editor"] .row[data-line="349"]')).toBeInViewport();
    const state = await ok(s, 'readit_state');
    expect(state.selection.viewport.start_line).toBeLessThanOrEqual(350);
    expect(state.selection.viewport.end_line).toBeGreaterThanOrEqual(350);
  });
});
