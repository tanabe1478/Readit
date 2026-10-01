// Each AI session can launch a Readit of its own (tools/readit_mcp.py --launch),
// so two sessions guide separate windows and tours at the same time.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test, expect, makeProject, repo } from './fixture.js';

const mcpScript = path.join(repo, 'tools/readit_mcp.py');

/** A stdio MCP client driving one launched Readit. */
function session(name, project, dir) {
  const socketPath = path.join(dir, `${name}.sock`);
  const urlFile = path.join(dir, `${name}.url`);
  const child = spawn('python3', [mcpScript, '--launch', '--socket', socketPath, '--workspace', project], {
    env: { ...process.env, READIT_OPEN: `sh -c 'echo "$0" > ${urlFile}'` }, stdio: ['pipe', 'pipe', 'inherit'] });
  let buffer = '';
  const waiting = new Map();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let at;
    while ((at = buffer.indexOf('\n')) >= 0) {
      const reply = JSON.parse(buffer.slice(0, at));
      buffer = buffer.slice(at + 1);
      waiting.get(reply.id)?.(reply);
    }
  });
  let next = 1;
  const request = (method, params) => new Promise((resolve) => {
    const id = next++;
    waiting.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  return {
    child, socketPath, urlFile,
    async init() {
      await request('initialize', { protocolVersion: '2025-11-25', clientInfo: { name, version: '1' } });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    },
    async call(tool, args = {}) {
      const reply = await request('tools/call', { name: tool, arguments: args });
      if (reply.result.isError) throw new Error(`${tool}: ${reply.result.content[0].text}`);
      return reply.result.structuredContent;
    },
  };
}

async function openWhenAsked(page, urlFile) {
  await expect.poll(() => fs.existsSync(urlFile), { timeout: 15000 }).toBe(true);
  await page.goto(fs.readFileSync(urlFile, 'utf8').trim());
  await page.waitForFunction(() => window.readitReady === true);
}

const exited = (child) => new Promise((resolve) => (child.exitCode !== null ? resolve() : child.on('exit', resolve)));

test('two sessions launch separate windows with their own tours', async ({ page, context }) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rs-'));
  fs.chmodSync(dir, 0o700);
  const projectA = makeProject({ 'a.py': 'alpha = 1\n' });
  const projectB = makeProject({ 'b.py': 'beta = 2\n' });
  const a = session('claude-code', projectA, dir);
  const b = session('pi', projectB, dir);
  const pageB = await context.newPage();
  try {
    await a.init();
    await b.init();
    // The first tool call starts the server, opens a window, and waits for it.
    const stateA = a.call('readit_state');
    const stateB = b.call('readit_state');
    await openWhenAsked(page, a.urlFile);
    await openWhenAsked(pageB, b.urlFile);
    const [sa, sb] = await Promise.all([stateA, stateB]);
    expect(sa.workspace).toBe(projectA);
    expect(sb.workspace).toBe(projectB);
    expect(sa.control_socket).toBe(a.socketPath);
    await expect(page).toHaveTitle(/^\[claude-code\]/);
    await expect(pageB.locator('.brand .label')).toHaveText('pi');
    const tour = (root, file, text) => ({ workspace: root, id: `tour-${file}`, event_sequence: 0,
      steps: [{ id: 'one', title: file, body: '解説', path: file, line: 1, column: 1, expected_text: text }] });
    await a.call('readit_guide_load', tour(projectA, 'a.py', 'alpha = 1'));
    await b.call('readit_guide_load', tour(projectB, 'b.py', 'beta = 2'));
    expect((await a.call('readit_state')).guide_tour.id).toBe('tour-a.py');
    expect((await b.call('readit_state')).guide_tour.id).toBe('tour-b.py');
    // A question in one window reaches only that session.
    await pageB.locator('button[data-act="guide-ask"]').click();
    await pageB.locator('#guide-question').fill('b への質問');
    await pageB.locator('button[data-act="guide-send"]').click();
    const eventsB = await b.call('readit_guide_events', { workspace: projectB, after: 0 });
    const eventsA = await a.call('readit_guide_events', { workspace: projectA, after: 0 });
    expect(eventsB.events.some((e) => e.question === 'b への質問')).toBe(true);
    expect(eventsA.events.some((e) => e.action === 'question')).toBe(false);
    // The server stops with its session: on a normal exit, and when the session is killed.
    a.child.stdin.end();
    await exited(a.child);
    await expect.poll(() => fs.existsSync(a.socketPath)).toBe(false);
    // A clean stop leaves no log behind; a killed session keeps it for inspection.
    expect(fs.existsSync(a.socketPath.replace(/\.sock$/, '.log'))).toBe(false);
    b.child.kill('SIGKILL');
    await expect.poll(() => fs.existsSync(b.socketPath), { timeout: 10000 }).toBe(false);
    expect(fs.existsSync(b.socketPath.replace(/\.sock$/, '.log'))).toBe(true);
  } finally {
    a.child.kill();
    b.child.kill();
    for (const p of [projectA, projectB, dir]) fs.rmSync(p, { recursive: true, force: true });
  }
});

test('a closed window is reopened on the next call', async ({ page, context }) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rs-'));
  fs.chmodSync(dir, 0o700);
  const project = makeProject({ 'a.py': 'alpha = 1\n' });
  const a = session('claude-code', project, dir);
  try {
    await a.init();
    const first = a.call('readit_state');
    await openWhenAsked(page, a.urlFile);
    await first;
    fs.rmSync(a.urlFile);
    await page.close();
    const again = a.call('readit_state');
    const reopened = await context.newPage();
    await openWhenAsked(reopened, a.urlFile);
    expect((await again).workspace).toBe(project);
  } finally {
    a.child.kill();
    fs.rmSync(project, { recursive: true, force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
