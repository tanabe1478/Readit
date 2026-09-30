// Start the local server and open the editor in the default browser.
// Usage: node scripts/start.mjs [repository] [--control-socket PATH] [--port N] [--no-open]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const server = path.join(web, 'dist/server.js');
if (!fs.existsSync(server) || !fs.existsSync(path.join(web, 'www/app.wasm'))) {
  console.error('ビルドされていません。npm run build を実行してください。');
  process.exit(1);
}
const args = process.argv.slice(2).filter((a) => a !== '--no-open');
const open = !process.argv.includes('--no-open');
const child = spawn(process.execPath, [server, '--web-root', web, ...args], { stdio: ['inherit', 'inherit', 'pipe'] });
child.stderr.on('data', (chunk) => {
  process.stderr.write(chunk);
  const match = /Readit: (http:\/\/127\.0\.0\.1:\d+\/)/.exec(chunk.toString());
  if (match && open) {
    const opener = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
    spawn(opener, [match[1]], { stdio: 'ignore', detached: true }).unref();
  }
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('exit', (code) => process.exit(code ?? 0));
