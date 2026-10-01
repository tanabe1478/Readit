// Build the MoonBit app (wasm-gc) and server (JS), and gather browser assets.
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mode = process.argv.includes('--debug') ? 'debug' : 'release';

function findMoon() {
  if (process.env.MOON) return process.env.MOON;
  const tryRun = (cmd, args) => {
    try { return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; }
  };
  if (tryRun('moon', ['version'])) return 'moon';
  for (const spec of ['http:moonbit@0.10.14', 'http:moonbit']) {
    const where = tryRun('mise', ['where', spec]);
    if (where && fs.existsSync(path.join(where, 'bin/moon'))) return path.join(where, 'bin/moon');
  }
  throw new Error('moon が見つかりません。MoonBit を入れるか MOON 環境変数で指定してください');
}

const moon = findMoon();
const env = { ...process.env, PATH: path.dirname(moon) + path.delimiter + process.env.PATH };
const flags = mode === 'release' ? ['--release'] : [];
for (const target of ['wasm-gc', 'js']) {
  execFileSync(moon, ['build', '--target', target, ...flags], { cwd: web, stdio: 'inherit', env });
}

const www = path.join(web, 'www');
const copy = (from, to) => {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(from, to);
};
copy(path.join(web, `_build/wasm-gc/${mode}/build/app/app.wasm`), path.join(www, 'app.wasm'));
// The launcher runs the server from a fixed path, whichever mode was built last.
copy(path.join(web, `_build/js/${mode}/build/server/server.js`), path.join(web, 'dist/server.js'));

const modules = path.join(web, 'node_modules');
if (!fs.existsSync(path.join(modules, 'web-tree-sitter'))) {
  throw new Error('npm install を先に実行してください（web-tree-sitter が見つかりません）');
}
copy(path.join(modules, 'web-tree-sitter/tree-sitter.js'), path.join(www, 'vendor/tree-sitter.js'));
copy(path.join(modules, 'web-tree-sitter/tree-sitter.wasm'), path.join(www, 'vendor/tree-sitter.wasm'));

// grammar name -> [package, wasm file, highlights query]
const grammars = {
  python: ['tree-sitter-python', 'tree-sitter-python.wasm'],
  rust: ['tree-sitter-rust', 'tree-sitter-rust.wasm'],
  javascript: ['tree-sitter-javascript', 'tree-sitter-javascript.wasm'],
  typescript: ['tree-sitter-typescript', 'tree-sitter-typescript.wasm'],
  tsx: ['tree-sitter-typescript', 'tree-sitter-tsx.wasm', null],
  json: ['tree-sitter-json', 'tree-sitter-json.wasm'],
  go: ['tree-sitter-go', 'tree-sitter-go.wasm'],
  java: ['tree-sitter-java', 'tree-sitter-java.wasm'],
  html: ['tree-sitter-html', 'tree-sitter-html.wasm'],
  css: ['tree-sitter-css', 'tree-sitter-css.wasm'],
  bash: ['tree-sitter-bash', 'tree-sitter-bash.wasm'],
  c: ['tree-sitter-c', 'tree-sitter-c.wasm'],
  cpp: ['tree-sitter-cpp', 'tree-sitter-cpp.wasm'],
  ruby: ['tree-sitter-ruby', 'tree-sitter-ruby.wasm'],
  toml: ['@tree-sitter-grammars/tree-sitter-toml', 'tree-sitter-toml.wasm'],
  yaml: ['@tree-sitter-grammars/tree-sitter-yaml', 'tree-sitter-yaml.wasm'],
};
for (const [name, [pkg, wasm, query]] of Object.entries(grammars)) {
  const dir = path.join(modules, pkg);
  copy(path.join(dir, wasm), path.join(www, 'grammars', `${name}.wasm`));
  if (query !== null) copy(path.join(dir, 'queries/highlights.scm'), path.join(www, 'grammars', `${name}.scm`));
}
// Markdown is not published to npm with wasm; fetch the pinned release and verify it.
const markdown = 'https://github.com/tree-sitter-grammars/tree-sitter-markdown/releases/download/v0.5.3/';
const pinned = {
  'tree-sitter-markdown.wasm': 'dd9fc12ac2804d7c7da787e4774125b32e4fb3c244e5e7031a77cb7dd8036020',
  'tree-sitter-markdown_inline.wasm': 'd47e5c43683c39b645ced8720ab90c3b3f467e715d3426b29ef3f69984d88c15',
  'tree-sitter-markdown.tar.gz': '22e40c51810e64c6bf073f0147f3abc167473206789e6dcbed4ba198ff3ca119',
};
const cache = path.join(web, '.cache/tree-sitter-markdown-0.5.3');
fs.mkdirSync(cache, { recursive: true });
for (const [name, sha] of Object.entries(pinned)) {
  const file = path.join(cache, name);
  if (!fs.existsSync(file)) {
    const response = await fetch(markdown + name);
    if (!response.ok) throw new Error(`${name}: ${response.status}`);
    fs.writeFileSync(file, Buffer.from(await response.arrayBuffer()));
  }
  const digest = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  if (digest !== sha) {
    fs.rmSync(file);
    throw new Error(`${name}: checksum mismatch ${digest}`);
  }
}
const source = path.join(cache, 'source');
if (!fs.existsSync(source)) {
  fs.mkdirSync(source);
  execFileSync('tar', ['xzf', path.join(cache, 'tree-sitter-markdown.tar.gz'), '-C', source]);
}
copy(path.join(cache, 'tree-sitter-markdown.wasm'), path.join(www, 'grammars/markdown.wasm'));
copy(path.join(cache, 'tree-sitter-markdown_inline.wasm'), path.join(www, 'grammars/markdown_inline.wasm'));
copy(path.join(source, 'tree-sitter-markdown/queries/highlights.scm'), path.join(www, 'grammars/markdown.scm'));
copy(path.join(source, 'tree-sitter-markdown-inline/queries/highlights.scm'), path.join(www, 'grammars/markdown_inline.scm'));
// MoonBit is built from a pinned commit by scripts/build-moonbit-grammar.mjs.
const moonbit = path.join(web, 'third-party/tree-sitter-moonbit');
copy(path.join(moonbit, 'moonbit.wasm'), path.join(www, 'grammars/moonbit.wasm'));
copy(path.join(moonbit, 'highlights.scm'), path.join(www, 'grammars/moonbit.scm'));
console.log(`Readit web: built (${mode})`);
