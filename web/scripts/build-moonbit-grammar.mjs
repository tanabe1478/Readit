// Rebuild third-party/tree-sitter-moonbit from a pinned grammar commit.
// The grammar is not published with wasm, and building it needs the Tree-sitter
// CLI plus wasi-sdk (about 100 MB, downloaded by the CLI), so the result is
// kept in the repository and `npm run build` only copies it.
// Usage: node scripts/build-moonbit-grammar.mjs
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPOSITORY = 'https://github.com/moonbitlang/tree-sitter-moonbit';
const COMMIT = '5435c307c6cf2ef0d508a99047b06f35a4308444';
const CLI = 'tree-sitter-cli@0.26.13';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = path.join(web, 'third-party/tree-sitter-moonbit');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'tree-sitter-moonbit-'));
const run = (cmd, args, cwd) => execFileSync(cmd, args, { cwd, stdio: 'inherit' });
try {
  run('git', ['clone', '--quiet', REPOSITORY, 'grammar'], work);
  const grammar = path.join(work, 'grammar');
  run('git', ['checkout', '--quiet', COMMIT], grammar);
  run('npx', ['--yes', CLI, 'build', '--wasm', '-o', path.join(target, 'moonbit.wasm')], grammar);
  fs.copyFileSync(path.join(grammar, 'queries/highlights.scm'), path.join(target, 'highlights.scm'));
  fs.copyFileSync(path.join(grammar, 'LICENSE'), path.join(target, 'LICENSE'));
  console.log(`tree-sitter-moonbit ${COMMIT.slice(0, 7)} -> ${path.relative(web, target)}`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
