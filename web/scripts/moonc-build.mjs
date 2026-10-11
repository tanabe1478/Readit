// Native-free, offline MoonBit build into a new private staging directory.
// Does not install dependencies, start a server, open Preview, or publish assets.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';
import { execFileSync } from 'node:child_process';
import {
  matchesCondition, parseManifest, preludeSource, productionSource, rememberInput, tokenize
} from './moonc-build-support.mjs';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sdkVersion = '0.1.202609203+7d59c7ec9';
const coreVersion = '0.10.14+7d59c7ec9';
const options = new Map();
let mode = 'release';
for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (arg === '--debug') {
    mode = 'debug';
  } else if (arg === '--help') {
    console.log('node scripts/moonc-build.mjs --compiler MOONC_WEB_CJS --stdlib CORE_DIR --out NEW_STAGE [--debug]');
    process.exit(0);
  } else if (['--compiler', '--stdlib', '--out'].includes(arg) &&
      process.argv[index + 1] && !process.argv[index + 1].startsWith('--')) {
    if (options.has(arg)) throw new Error(`Duplicate option: ${arg}`);
    options.set(arg, path.resolve(process.argv[++index]));
  } else {
    throw new Error(`Unknown or incomplete option: ${arg}`);
  }
}
for (const option of ['--compiler', '--stdlib', '--out']) {
  if (!options.has(option)) throw new Error(`${option} is required; use --help`);
}
const compilerPath = fs.realpathSync(options.get('--compiler'));
const stdlib = fs.realpathSync(options.get('--stdlib'));
const compilerPackage = JSON.parse(fs.readFileSync(
  path.join(path.dirname(compilerPath), 'package.json'), 'utf8'
));
if (compilerPackage.name !== '@moonbit/moonc-worker' || compilerPackage.version !== sdkVersion) {
  throw new Error(`This build path requires @moonbit/moonc-worker@${sdkVersion}`);
}
const moduleInfo = tokenize(fs.readFileSync(path.join(stdlib, 'moon.mod'), 'utf8'));
function moduleField(name) {
  const index = moduleInfo.findIndex(token => token.value === name);
  if (moduleInfo[index + 1]?.value !== '=' || moduleInfo[index + 2]?.kind !== 'string') {
    throw new Error(`Missing core module ${name}`);
  }
  return moduleInfo[index + 2].value;
}
if (moduleField('name') !== 'moonbitlang/core' || moduleField('version') !== coreVersion) {
  throw new Error(`This build path requires moonbitlang/core ${coreVersion}`);
}
const requestedOut = options.get('--out');
fs.mkdirSync(path.dirname(requestedOut), { recursive: true });
const out = path.join(fs.realpathSync(path.dirname(requestedOut)), path.basename(requestedOut));
function inside(parent, child) {
  return child === parent || child.startsWith(parent + path.sep);
}
if (inside(fs.realpathSync(web), out) || inside(stdlib, out) ||
    inside(path.dirname(compilerPath), out) || fs.existsSync(out)) {
  throw new Error('--out must be a new staging directory outside web/ and the toolchain');
}
fs.mkdirSync(out, { mode: 0o700 });
const log = path.join(out, 'compiler.log');
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const inputs = new Map();
function readInput(file, key) {
  const bytes = fs.readFileSync(file);
  rememberInput(inputs, file, key, sha256(bytes));
  return bytes.toString('utf8');
}
readInput(compilerPath, 'compiler/moonc-web.cjs');
readInput(path.join(stdlib, 'moon.mod'), 'stdlib/moon.mod');
readInput(path.join(web, 'moon.mod'), 'web/moon.mod');
for (const name of ['moonc-build.mjs', 'moonc-build-support.mjs', 'moonc-worker.mjs']) {
  readInput(path.join(web, 'scripts', name), `web/scripts/${name}`);
}
const { Parser, Language } = await import(path.join(web, 'node_modules/web-tree-sitter/tree-sitter.js'));
const parserWasm = path.join(web, 'node_modules/web-tree-sitter/tree-sitter.wasm');
await Parser.init({ locateFile: () => parserWasm });
const parser = new Parser();
const grammar = path.join(web, 'www/grammars/moonbit.wasm');
parser.setLanguage(await Language.load(grammar));
for (const [file, key] of [
  [parserWasm, 'parser/tree-sitter.wasm'], [grammar, 'parser/moonbit.wasm']
]) {
  rememberInput(inputs, file, key, sha256(fs.readFileSync(file)));
}
const diagnostics = [];
function compile(method, params) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./moonc-worker.mjs', import.meta.url), {
      workerData: { compiler: compilerPath, method, params }, stdout: true, stderr: true
    });
    let settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      worker.terminate();
      if (error) reject(error);
      else resolve(result);
    };
    const timer = setTimeout(() => finish(new Error('Compiler worker timed out')), 120000);
    for (const stream of [worker.stdout, worker.stderr]) {
      stream.on('data', bytes => fs.appendFileSync(log, bytes, { mode: 0o600 }));
    }
    worker.once('message', message => {
      finish(message.error ? new Error(message.error) : null, message.result);
    });
    worker.once('error', error => finish(error));
    worker.once('exit', code => finish(new Error(`Compiler worker exited before reply: ${code}`)));
  });
}
function packageDir(pkg) {
  if (pkg.startsWith('moonbitlang/core/')) {
    return path.join(stdlib, pkg.slice('moonbitlang/core/'.length));
  }
  if (/^readit\/web\/(core|editor|lsp|app|server)$/.test(pkg)) {
    return path.join(web, pkg.slice('readit/web/'.length));
  }
  throw new Error(`Unsupported dependency: ${pkg}`);
}
const buildResults = [];
for (const [target, main, output] of [
  ['wasm-gc', 'readit/web/app', 'www/app.wasm'],
  ['js', 'readit/web/server', 'dist/server.js']
]) {
  const cache = new Map();
  const active = new Set();
  const dirs = new Map();
  const sources = {};
  async function build(pkg) {
    if (cache.has(pkg)) return cache.get(pkg);
    if (active.has(pkg)) throw new Error(`Dependency cycle: ${pkg}`);
    active.add(pkg);
    const dir = packageDir(pkg);
    dirs.set(pkg, dir);
    const prefix = pkg.startsWith('moonbitlang/core/')
      ? 'stdlib/' + pkg.slice('moonbitlang/core/'.length)
      : 'web/' + pkg.slice('readit/web/'.length);
    const manifest = parseManifest(readInput(path.join(dir, 'moon.pkg'), `${prefix}/moon.pkg`));
    if (manifest.supported && !manifest.supported.includes(target)) {
      throw new Error(`${pkg} does not support ${target}`);
    }
    const miFiles = [];
    for (const dep of manifest.imports) {
      miFiles.push([`${dep.pkg}:${dep.alias}`, (await build(dep.pkg)).mi]);
    }
    const isStd = pkg.startsWith('moonbitlang/core/');
    const useStd = !['moonbitlang/core/abort', 'moonbitlang/core/builtin'].includes(pkg);
    const stdMiFiles = [];
    const direct = new Set(manifest.imports.map(dep => dep.pkg));
    if (useStd) {
      stdMiFiles.push(['moonbitlang/core/builtin:builtin', (await build('moonbitlang/core/builtin')).mi]);
      direct.add('moonbitlang/core/builtin');
      if (!isStd) {
        stdMiFiles.push(['moonbitlang/core/prelude:prelude', (await build('moonbitlang/core/prelude')).mi]);
        direct.add('moonbitlang/core/prelude');
      }
    }
    const mbtFiles = fs.readdirSync(dir).sort().filter(name => {
      if (!name.endsWith('.mbt') || /_(wb)?test\.mbt$/.test(name)) return false;
      const rule = manifest.rules.get(name);
      return !rule || matchesCondition(rule, target, mode);
    }).map(name => {
      const text = readInput(path.join(dir, name), `${prefix}/${name}`);
      sources[path.join(dir, name)] = text;
      return [name, productionSource(text, parser)];
    });
    if (!mbtFiles.length) throw new Error(`No production source: ${pkg}`);
    if (useStd) {
      const alias = isStd ? 'builtin' : 'prelude';
      const api = readInput(path.join(stdlib, alias, 'pkg.generated.mbti'), `stdlib/${alias}/pkg.generated.mbti`);
      const prelude = preludeSource(api, mbtFiles.map(([, text]) => text), alias);
      if (prelude) mbtFiles.push(['__readit_implicit_prelude.mbt', prelude]);
    }
    const result = await compile('buildPackage', {
      mbtFiles, miFiles, stdMiFiles,
      indirectImportMiFiles: [...cache].filter(([name]) => !direct.has(name)).map(([name, value]) => {
        return [name, value.mi];
      }),
      target, pkg, pkgSources: [...dirs].map(([name, directory]) => `${name}:${directory}`),
      isMain: manifest.executable, errorFormat: 'human',
      enableValueTracing: false, noOpt: mode === 'debug'
    });
    fs.appendFileSync(log, `\n${target} ${pkg}\n${result.diagnostics.join('')}`, { mode: 0o600 });
    diagnostics.push(...result.diagnostics.map(text => ({ target, pkg, text })));
    if (!result.mi || !result.core) {
      throw new Error(`Compile failed: ${pkg} (${target}); inspect ${log}`);
    }
    cache.set(pkg, result);
    active.delete(pkg);
    console.log(`compiled ${target} ${pkg} (${result.diagnostics.length} diagnostics)`);
    return result;
  }
  await build(main);
  const manifestText = fs.readFileSync(path.join(packageDir(main), 'moon.pkg'), 'utf8');
  const exports = target === 'wasm-gc' ? JSON.parse(
    '[' + /"exports"\s*:\s*\[([^\]]*)\]/.exec(manifestText)[1].replace(/,\s*$/, '') + ']'
  ) : [];
  if (target === 'wasm-gc' && (!/"use-js-builtin-string"\s*:\s*true/.test(manifestText) ||
      !/"imported-string-constants"\s*:\s*"_"/.test(manifestText))) {
    throw new Error('Unsupported app string link settings');
  }
  const linked = await compile('linkCore', {
    coreFiles: [...cache.values()].map(result => result.core), main,
    pkgSources: [...dirs].map(([pkg, dir]) => `${pkg}:${dir}`), target,
    useJsBuiltinString: target === 'wasm-gc', importedStringConstants: '_',
    exportedFunctions: exports, outputFormat: 'wasm', testMode: false,
    debug: mode === 'debug', noOpt: mode === 'debug', sourceMap: false, sources,
    stopOnMain: false
  });
  if (target === 'wasm-gc') {
    const module = await WebAssembly.compile(linked.result, {
      builtins: ['js-string'], importedStringConstants: '_'
    });
    const actual = WebAssembly.Module.exports(module).map(value => value.name).sort();
    if (JSON.stringify(actual) !== JSON.stringify([...exports].sort())) {
      throw new Error('Unexpected Wasm exports');
    }
  }
  const file = path.join(out, 'web', output);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, linked.result, { mode: 0o600 });
  buildResults.push({ target, output, bytes: linked.result.length, packages: cache.size });
}
parser.delete();
// Preserve the server's module mode without copying npm dependencies into staging.
fs.writeFileSync(path.join(out, 'web/package.json'), '{"private":true,"type":"module"}\n', {
  mode: 0o600
});
execFileSync(process.execPath, ['--check', path.join(out, 'web/dist/server.js')], {
  stdio: ['ignore', 'pipe', 'pipe']
});
function copyAssets(from, to) {
  fs.mkdirSync(to, { recursive: true, mode: 0o700 });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    if (entry.name === 'app.wasm') continue;
    const source = path.join(from, entry.name);
    const destination = path.join(to, entry.name);
    if (entry.isDirectory()) {
      copyAssets(source, destination);
    } else if (entry.isFile()) {
      const bytes = fs.readFileSync(source);
      const key = 'web/www/' + path.relative(path.join(web, 'www'), source);
      rememberInput(inputs, source, key, sha256(bytes));
      fs.writeFileSync(destination, bytes, { mode: 0o600 });
    } else {
      throw new Error(`Non-regular browser asset: ${source}`);
    }
  }
}
copyAssets(path.join(web, 'www'), path.join(out, 'web/www'));
// Detect concurrent source changes before marking the staged bundle complete.
for (const [file, input] of inputs) {
  if (sha256(fs.readFileSync(file)) !== input.sha256) {
    throw new Error(`Input changed during build: ${input.path}`);
  }
}
const artifacts = [];
function hashFiles(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) hashFiles(file);
    else artifacts.push({ path: path.relative(out, file), sha256: sha256(fs.readFileSync(file)) });
  }
}
hashFiles(path.join(out, 'web'));
fs.writeFileSync(path.join(out, 'build.json'), JSON.stringify({
  format: 1, complete: true, mode, node: process.version,
  compiler: compilerPackage.version, core: coreVersion,
  results: buildResults, inputs: [...inputs.values()], artifacts, diagnostics,
  verification: { wasmModule: true, serverSyntax: true, browser: false, moonTests: false }
}, null, 2) + '\n', { mode: 0o600 });
console.log(`Readit staged (${mode}): ${out}/web; not published or browser-tested`);
