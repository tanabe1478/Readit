# tree-sitter-moonbit

MoonBit の構文ハイライト用の文法です。npm にも GitHub のリリースにも wasm が無いため、ビルドした結果をここに置いています。

- 出所: https://github.com/moonbitlang/tree-sitter-moonbit
- コミット: `5435c307c6cf2ef0d508a99047b06f35a4308444`（2026-07-22）
- ビルド: `tree-sitter-cli@0.26.13` の `tree-sitter build --wasm`（wasi-sdk 29）
- ライセンス: Apache-2.0（`LICENSE`）
- `moonbit.wasm`: 文法（ABI 15）
- `highlights.scm`: ハイライト用クエリ（無変更）

作り直すときは `node scripts/build-moonbit-grammar.mjs` を実行します。
