// Starts a Readit server on a copy of a project and opens it in the page.
import { test as base, expect } from '@playwright/test';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const repo = path.dirname(web);

export function makeProject(files, { git = false } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'readit-e2e-')));
  for (const [name, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
    fs.writeFileSync(path.join(dir, name), text);
  }
  if (git) {
    const run = (...args) => execFileSync('git', ['-C', dir, ...args], {
      env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }, stdio: 'ignore' });
    run('init', '-q');
    run('add', '.');
    run('-c', 'user.name=Readit Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'baseline');
  }
  return dir;
}

export function demoProject() {
  const files = {};
  const walk = (dir, prefix = '') => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === '__pycache__') continue;
      const rel = prefix + entry.name;
      if (entry.isDirectory()) walk(path.join(dir, entry.name), rel + '/');
      else files[rel] = fs.readFileSync(path.join(dir, entry.name), 'utf8');
    }
  };
  walk(path.join(repo, 'demo'));
  return makeProject(files);
}

export async function startServer(project, { socket = true, env = {} } = {}) {
  let socketPath = '';
  let socketDir = '';
  if (socket) {
    socketDir = fs.mkdtempSync(path.join(os.tmpdir(), 'readit-sock-'));
    fs.chmodSync(socketDir, 0o700);
    socketPath = path.join(socketDir, 'control.sock');
  }
  const args = [path.join(web, 'dist/server.js'), '--web-root', web, '--port', '0', project];
  if (socket) args.push('--control-socket', socketPath);
  const child = spawn(process.execPath, args, { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, ...env } });
  let log = '';
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start:\n' + log)), 15000);
    child.stderr.on('data', (d) => {
      log += d;
      const m = /Readit: (http:\/\/127\.0\.0\.1:\d+\/)/.exec(log);
      if (m) { clearTimeout(timer); resolve(m[1]); }
    });
    child.on('exit', (code) => reject(new Error(`server exited ${code}:\n${log}`)));
  });
  return {
    url, socketPath, child, project,
    log: () => log,
    stop: () => { child.kill(); if (socketDir) fs.rmSync(socketDir, { recursive: true, force: true }); },
  };
}

/** One request on the control socket, like tools/readit_mcp.py sends. */
export function control(socketPath, method, args = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(socketPath);
    let data = '';
    sock.on('connect', () => sock.write(JSON.stringify({ method, arguments: args }) + '\n'));
    sock.on('data', (d) => { data += d; });
    sock.on('end', () => {
      try {
        const reply = JSON.parse(data);
        resolve(reply);
      } catch (e) { reject(new Error('bad reply: ' + data)); }
    });
    sock.on('error', reject);
  });
}

export async function ok(socketPath, method, args) {
  const reply = await control(socketPath, method, args);
  if (reply.error) throw new Error(`${method}: ${reply.error}`);
  return reply.result;
}

export const test = base.extend({
  // Override per test with test.use({ files: {...} }) or leave for the demo.
  files: [null, { option: true }],
  git: [false, { option: true }],
  serverEnv: [{}, { option: true }],
  readit: [async ({ page, files, git, serverEnv }, use) => {
    const project = files ? makeProject(files, { git }) : demoProject();
    const server = await startServer(project, { env: serverEnv });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(server.url);
    await page.waitForFunction(() => window.readitReady === true && window.readitIdle());
    await use({ ...server, errors });
    expect(errors, 'page errors').toEqual([]);
    server.stop();
    fs.rmSync(project, { recursive: true, force: true });
  }, { auto: true }],
});
export { expect };

/** Box of a substring on a rendered editor line (0-based line). */
export async function textBox(page, line, needle, view = 'editor') {
  return page.evaluate(([line, needle, view]) => {
    const code = document.querySelector(`.lines[data-view="${view}"] .row[data-line="${line}"] .code`);
    if (!code) return null;
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
    const nodes = []; for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
    const text = nodes.map((n) => n.data).join('');
    const index = text.indexOf(needle);
    if (index < 0) return null;
    let at = 0;
    const find = (offset) => { for (const n of nodes) { if (offset <= at + n.length) return [n, offset - at]; at += n.length; } };
    at = 0; const [a, ao] = find(index); at = 0; const [b, bo] = find(index + needle.length);
    const r = document.createRange(); r.setStart(a, ao); r.setEnd(b, bo);
    const box = r.getBoundingClientRect();
    return { x: box.left, y: box.top, width: box.width, height: box.height };
  }, [line, needle, view]);
}

export async function lineText(page, line, view = 'editor') {
  return page.evaluate(([line, view]) => {
    const code = document.querySelector(`.lines[data-view="${view}"] .row[data-line="${line}"] .code`);
    if (!code) return null;
    let text = '';
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT, { acceptNode: (n) => n.parentElement.closest('.eol') ? 2 : 1 });
    for (let n = walker.nextNode(); n; n = walker.nextNode()) text += n.data;
    return text;
  }, [line, view]);
}

/** Click inside a substring: at its start, or just after it with `after`. */
export async function clickText(page, line, needle, { after = false, view = 'editor', modifiers } = {}) {
  let box = null;
  for (let i = 0; i < 50 && !box; i++) {
    box = await textBox(page, line, needle, view);
    if (!box) await page.waitForTimeout(100);
  }
  if (!box) throw new Error(`"${needle}" is not rendered on line ${line}`);
  const x = after ? box.x + box.width - 1 : box.x + 1;
  await page.mouse.click(x, box.y + box.height / 2, { modifiers });
}
