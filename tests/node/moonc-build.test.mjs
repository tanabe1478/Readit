import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  matchesCondition, parseManifest, preludeSource, productionSource, rememberInput, tokenize
} from '../../web/scripts/moonc-build-support.mjs';

const manifest = `
import {
  "readit/web/core",
  "moonbitlang/core/internal/strconv" @internal/strconv,
}
// import { "do/not-load" }
import { "moonbitlang/core/bench" } for "test"
import { "moonbitlang/core/quickcheck" } for "wbtest"
supported_targets = "js"
options(targets: {
  "debug.mbt": ["debug"],
  "release.mbt": ["not", "debug"],
  "native.mbt": ["native", "llvm"],
})
pkgtype(kind: "executable")
warnings = "-implicit_impl_as_method"
`;

test('manifest keeps runtime aliases, excludes test-only imports and recognizes executable', () => {
  const parsed = parseManifest(manifest);
  assert.deepEqual(parsed.imports, [
    { pkg: 'readit/web/core', alias: 'core' },
    { pkg: 'moonbitlang/core/internal/strconv', alias: 'internal/strconv' }
  ]);
  assert.deepEqual(parsed.supported, ['js']);
  assert.equal(parsed.executable, true);
  assert.equal(parsed.rules.size, 3);
});

test('repeated input reads cannot conceal a change between app and server compilation', () => {
  const inputs = new Map();
  rememberInput(inputs, '/fixture/core.mbt', 'core.mbt', 'first-hash');
  rememberInput(inputs, '/fixture/core.mbt', 'core.mbt', 'first-hash');
  assert.throws(() => rememberInput(inputs, '/fixture/core.mbt', 'core.mbt', 'changed-hash'),
    /Input changed between build reads/);
  assert.equal(inputs.get('/fixture/core.mbt').sha256, 'first-hash');
});

test('manifest tokenizer does not treat slashes inside strings as comments', () => {
  assert.deepEqual(tokenize('url = "https://example.invalid/core" /* ignored */').map(t => t.value),
    ['url', '=', 'https://example.invalid/core']);
});

test('release and debug rules, including multi-target negation, are distinct', () => {
  const parsed = parseManifest(manifest);
  assert.equal(matchesCondition(parsed.rules.get('debug.mbt'), 'wasm-gc', 'release'), false);
  assert.equal(matchesCondition(parsed.rules.get('debug.mbt'), 'wasm-gc', 'debug'), true);
  assert.equal(matchesCondition(parsed.rules.get('release.mbt'), 'wasm-gc', 'release'), true);
  assert.equal(matchesCondition(['not', 'native', 'llvm'], 'wasm-gc', 'release'), true);
  assert.equal(matchesCondition(['not', 'native', 'llvm'], 'native', 'release'), false);
  assert.equal(matchesCondition(['and', 'js', 'release'], 'js', 'release'), true);
  assert.equal(matchesCondition(['and', 'js', 'release'], 'js', 'debug'), false);
});

test('unsupported conditions and manifests fail instead of compiling the wrong sources', () => {
  assert.throws(() => matchesCondition(['or', 'js', 'unknown'], 'js', 'release'));
  assert.throws(() => matchesCondition(['not'], 'js', 'release'));
  assert.throws(() => parseManifest('import { "bad/package" } for "other"'));
  assert.throws(() => parseManifest('import { "one/core", "two/core" }'));
  assert.throws(() => parseManifest('pkgtype(kind: "library")'));
  assert.throws(() => parseManifest('options(targets: { "x.mbt": [1] })'));
});

const api = `
package "moonbitlang/core/builtin"
type Array[T]
pub(open) trait Eq { }
pub fn[A : Eq] compare(A, A) -> Int
pub fn[T] Array::map(Self[T], (T) -> T) -> Self[T]
pub fn Bytes::view(Bytes) -> BytesView
pub fn inspect(Int) -> Unit
pub let null : Int
`;

test('virtual prelude imports types and open traits, not method-owner names as values', () => {
  const result = preludeSource(api, ['fn demo(x : Array[Int]) -> Unit { compare(x, x); inspect(x) }'], 'builtin');
  assert.match(result, /type Array/);
  assert.match(result, /compare/);
  assert.match(result, /inspect/);
  assert.doesNotMatch(result, /Bytes|, Array|type Eq/);
  assert.match(preludeSource(api, ['struct Item {} derive(Eq)'], 'builtin'), /trait Eq/);
});

test('local definitions, explicit using and declared aliases shadow implicit names', () => {
  const result = preludeSource(api, [
    'using @builtin {type Array}',
    '#alias(inspect, deprecated="prefer debug_inspect")\npub fn debug_inspect() -> Unit {}',
    'fn compare(x : Int, y : Int) -> Int { x - y }',
    'fn use() -> Int { null }'
  ], 'builtin');
  assert.equal(result, 'using @builtin {null}\n');
});

function fakeParser(source, { malformed = false, missing = false } = {}) {
  const start = source.indexOf('#skip');
  const end = source.indexOf('\nfn after');
  const node = {
    type: 'test_definition', startIndex: start, endIndex: end,
    text: source.slice(start, end), hasError: malformed
  };
  let deleted = false;
  return {
    parse: () => ({
      rootNode: { namedChildren: missing ? [] : [node] },
      delete: () => { deleted = true; }
    }),
    deleted: () => deleted
  };
}
const source = 'fn before() -> String { "本文" }\n#skip\ntest "inline" {\n  inspect("合成")\n}\nfn after() -> Int { 1 }\n';

test('production extraction blanks only complete inline tests and their attributes', () => {
  const parser = fakeParser(source);
  const result = productionSource(source, parser);
  assert.equal(result.length, source.length);
  assert.equal(result.split('\n').length, source.split('\n').length);
  assert.equal(result.slice(0, source.indexOf('#skip')), source.slice(0, source.indexOf('#skip')));
  assert.equal(result.slice(source.indexOf('\nfn after')), source.slice(source.indexOf('\nfn after')));
  assert.doesNotMatch(result, /合成|inspect|#skip/);
  assert.equal(parser.deleted(), true);
});

test('incomplete test parses are rejected and parser memory is released', () => {
  for (const config of [{ malformed: true }, { missing: true }]) {
    const parser = fakeParser(source, config);
    assert.throws(() => productionSource(source, parser), /Cannot safely exclude inline tests/);
    assert.equal(parser.deleted(), true);
  }
});

const buildScript = fileURLToPath(new URL('../../web/scripts/moonc-build.mjs', import.meta.url));
function guardFixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'readit-build-guards-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const compilerDir = path.join(dir, 'compiler');
  const core = path.join(dir, 'core');
  fs.mkdirSync(compilerDir);
  fs.mkdirSync(core);
  const compiler = path.join(compilerDir, 'moonc-web.cjs');
  fs.writeFileSync(compiler, 'throw new Error("guard must not execute compiler");\n');
  fs.writeFileSync(path.join(compilerDir, 'package.json'), JSON.stringify({
    name: '@moonbit/moonc-worker', version: '0.1.202609203+7d59c7ec9'
  }));
  fs.writeFileSync(path.join(core, 'moon.mod'),
    'name = "moonbitlang/core"\nversion = "0.10.14+7d59c7ec9"\n');
  const run = out => spawnSync(process.execPath, [buildScript,
    '--compiler', compiler, '--stdlib', core, '--out', out], { encoding: 'utf8' });
  return { dir, compilerDir, core, run };
}

test('build CLI rejects unknown flags and supports help without loading the SDK', () => {
  const help = spawnSync(process.execPath, [buildScript, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /--compiler/);
  const unknown = spawnSync(process.execPath, [buildScript, '--publish'], { encoding: 'utf8' });
  assert.notEqual(unknown.status, 0);
  assert.match(unknown.stderr, /Unknown or incomplete option/);
});

test('build CLI refuses an existing stage without overwriting its files', t => {
  const fixture = guardFixture(t);
  const out = path.join(fixture.dir, 'existing-stage');
  fs.mkdirSync(out);
  fs.writeFileSync(path.join(out, 'marker'), 'keep this candidate');
  const reply = fixture.run(out);
  assert.notEqual(reply.status, 0);
  assert.match(reply.stderr, /new staging directory/);
  assert.equal(fs.readFileSync(path.join(out, 'marker'), 'utf8'), 'keep this candidate');
  assert.deepEqual(fs.readdirSync(out), ['marker']);
});

test('build CLI cannot stage outputs into the compiler or standard library', t => {
  const fixture = guardFixture(t);
  for (const parent of [fixture.compilerDir, fixture.core]) {
    const out = path.join(parent, 'forbidden-output');
    const reply = fixture.run(out);
    assert.notEqual(reply.status, 0);
    assert.match(reply.stderr, /new staging directory/);
    assert.equal(fs.existsSync(out), false);
  }
});

test('build CLI rejects an unmatched SDK before creating output', t => {
  const fixture = guardFixture(t);
  fs.writeFileSync(path.join(fixture.core, 'moon.mod'),
    'name = "moonbitlang/core"\nversion = "unknown"\n');
  const out = path.join(fixture.dir, 'must-not-exist');
  const reply = fixture.run(out);
  assert.notEqual(reply.status, 0);
  assert.match(reply.stderr, /requires moonbitlang\/core/);
  assert.equal(fs.existsSync(out), false);
});
