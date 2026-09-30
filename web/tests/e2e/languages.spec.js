// Definition lookups for the other language servers. Each is skipped when its
// server is not installed; Java also needs READIT_TEST_JAVA=1 (first import is slow).
import fs from 'node:fs';
import path from 'node:path';
import { test, expect, ok, repo } from './fixture.js';

const runtime = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(repo, 'tools/lsp/runtime.json'), 'utf8')); } catch { return {}; }
})();

async function definition(readit, file, line, column) {
  const s = readit.socketPath;
  const root = (await ok(s, 'readit_state')).workspace;
  await ok(s, 'readit_open', { workspace: root, path: file, line, column });
  return ok(s, 'readit_symbol', { workspace: root, kind: 'definition' });
}

test.describe('typescript', () => {
  test.skip(!fs.existsSync(path.join(repo, 'tools/lsp/node_modules/typescript-language-server')), 'TypeScript server missing');
  // Ported from tests/language_services.rs: both files are open, as in the native snapshot.
  const model = "export interface Named { name: string }\nexport class Person implements Named { name = 'Alice'; }\nexport function greet(value: Named) { return value.name; }\n";
  const code = "import { greet as hello, Named, Person } from './model';\nconst value: Named = new Person();\nconst result = hello(value);\nfunction other() { const hello = 3; return hello; }\n";
  test.use({ files: {
    'tsconfig.json': '{"compilerOptions":{"strict":true,"target":"ES2022"},"include":["*.ts"]}',
    'model.ts': model,
    'main.ts': code,
  } });
  test('resolves an aliased import to its declaration, and references stay scoped', async ({ readit }) => {
    const s = readit.socketPath;
    const root = (await ok(s, 'readit_state')).workspace;
    await ok(s, 'readit_open', { workspace: root, path: 'model.ts' });
    const answer = await definition(readit, 'main.ts', 3, 16);
    expect(answer.server).toBe('TypeScript Language Server');
    expect(answer.targets.some((t) => t.path.endsWith('model.ts') && t.line === 3)).toBe(true);
    const refs = await ok(s, 'readit_symbol', { workspace: root, kind: 'references' });
    expect(refs.targets.some((t) => t.path.endsWith('main.ts') && t.line === 4)).toBe(false);
  });
});

test.describe('rust', () => {
  test.skip(!runtime.rustAnalyzer, 'rust-analyzer missing');
  test.setTimeout(120_000);
  test.use({ files: {
    'Cargo.toml': '[package]\nname = "sample"\nversion = "0.1.0"\nedition = "2021"\n',
    'src/lib.rs': 'pub mod shop;\n\npub fn run() -> u32 {\n    shop::total(&[1, 2])\n}\n',
    'src/shop.rs': 'pub fn total(items: &[u32]) -> u32 {\n    items.iter().sum()\n}\n',
  } });
  test('finds a definition across Rust modules', async ({ readit }) => {
    const answer = await definition(readit, 'src/lib.rs', 4, 11);
    expect(answer.server).toBe('rust-analyzer');
    expect(answer.targets.map((t) => `${path.basename(t.path)}:${t.line}`)).toContain('shop.rs:1');
  });
});

test.describe('java', () => {
  test.skip(!runtime.javaLauncher || !process.env.READIT_TEST_JAVA, 'set READIT_TEST_JAVA=1 with Eclipse JDT installed');
  test.setTimeout(300_000);
  test.use({ files: {
    'src/main/java/shop/Item.java': 'package shop;\n\npublic class Item {\n    public int price() { return 1; }\n}\n',
    'src/main/java/shop/Main.java': 'package shop;\n\npublic class Main {\n    public static void main(String[] args) {\n        System.out.println(new Item().price());\n    }\n}\n',
  } });
  test('finds a definition in another Java class', async ({ readit }) => {
    const answer = await definition(readit, 'src/main/java/shop/Main.java', 5, 39);
    expect(answer.server).toBe('Eclipse JDT Language Server');
    expect(answer.targets.map((t) => `${path.basename(t.path)}:${t.line}`)).toContain('Item.java:4');
  });
});
