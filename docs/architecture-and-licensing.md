# 構成と商用ライセンスの判断

調査日: 2026-09-07。採用方針: **GPUIを利用した独立アプリ。Readit本体は非公開で販売できる構成。**
ユーザー確認済み。既存IDEと同様のファイルツリー・タブ・コード表示を基本に、読む機能を追加する。

## 比較

| 選択肢 | 非公開の本体を配布 | 有料販売 | 実装上の特徴 | 判断 |
| --- | --- | --- | --- | --- |
| Zed全体をフォーク | 通常は不可。GPL対象の派生物に対応するソース提供が必要 | 可能 | 編集、LSP、Git、端末などを継承できるが、上流追従と改造の負担 | 今回は採用しない |
| Zedのeditor等を抽出 | GPL部分を組み込んだ派生アプリを丸ごと非公開配布する案には不適 | 可能 | 「内部だけ」でもGPLの条件はなくならない | 今回は採用しない |
| GPUI + 自作の読む機能・編集部 | 可能。各依存の条件には従う | 可能 | ネイティブ描画を利用。編集、LSP、Gitの統合は自前で必要 | 採用 |
| 権利者と別途ライセンス契約 | 契約次第 | 契約次第 | Zed側が提供するか、対象範囲・価格・権利が揃うかは未確認 | 前提にしない |

GPLは商用利用・有料販売を禁止しない。配布先にはGPLが認める改変・再配布の権利も渡す。
公開GitHubリポジトリを作ることだけが義務の満たし方ではないが、購入者へ対応するソースを
提供して再配布も認める必要があるため、ソースを秘密に保つ事業設計には合わない。
単なる社内での変更と第三者への配布は区別する。根拠はGPLv3の§4–6、§10。
[Zedに同梱されたGPLv3](https://github.com/zed-industries/zed/blob/main/LICENSE-GPL)

## 「エンジン」の境界

| コンポーネント | 確認した表示 | 本プロジェクトでの扱い |
| --- | --- | --- |
| GPUI | Apache-2.0 | 0.2.2を固定して利用 |
| editor | GPL-3.0-or-later | 利用しない |
| language | GPL-3.0-or-later | 利用しない |
| text | GPL-3.0-or-later | 利用しない |
| multi_buffer | GPL-3.0-or-later | 利用しない |

直接確認した一次資料:
[GPUIの公開パッケージ](https://docs.rs/crate/gpui/0.2.2/source/Cargo.toml)、
[editor](https://github.com/zed-industries/zed/blob/main/crates/editor/Cargo.toml)、
[language](https://github.com/zed-industries/zed/blob/main/crates/language/Cargo.toml)、
[text](https://github.com/zed-industries/zed/blob/main/crates/text/Cargo.toml)、
[multi_buffer](https://github.com/zed-industries/zed/blob/main/crates/multi_buffer/Cargo.toml)。
mainの内容は変わりうる。今後コードを導入する際は対象commitとファイル単位で再確認する。

**GPUIはUIフレームワークであり、完成したエディタエンジンではない。**
GPUIだけを採用しても、ZedのLSP連携、テキスト編集、複数ファイル抜粋表示が自動で付いてくるわけではない。
GPUIはpre-1.0で破壊的変更がありうるため、バージョンとlockfileを固定する。
[GPUI 0.2.2公式ドキュメント](https://docs.rs/gpui/0.2.2/gpui/)

## 非公開で販売する際の条件

Apache-2.0は、自作アプリ全体のソース公開を要求しない。利用部分についてライセンス文を渡し、
改変ファイルに変更の表示を行い、必要な著作権・帰属表示と該当するNOTICEを保持する。
商標の使用権は自動では付与されない。Readitという独自名を使い、Zedのロゴや配信基盤は引き継がない。
[Apache-2.0 §4、§6](https://www.apache.org/licenses/LICENSE-2.0)

編集部はApache-2.0の`gpui-component 0.5.1`に置き換えた。
同じGPUI 0.2.2を使う版を固定し、Tree-sitter言語grammarを有効化している。
`gpui-component-assets 0.5.1`のアイコンも利用し、Lucide/Featherの条件を記録した。
出典とライセンス文は`THIRD_PARTY_NOTICES.md`と`third-party/`に収録。
Readitオリジナル部分にOSSライセンスを設定してはいない。

GPUI本体のライセンスだけで、全同梱物の確認が完了するわけではない。
製品版では実際のtarget/featuresを固定し、推移的依存、フォント、アイコン、構文grammar、
language server、実行バイナリのライセンスを棚卸しする。MPL等のファイル単位の義務がある場合は
該当部分について対応する。GPL部分を別プロセスにすれば必ず非公開にできるとは仮定しない。
配布形態を確定した段階で法務レビューを行う。

### 今回の依存メタデータの確認

`cargo metadata --offline --format-version 1 --filter-platform aarch64-apple-darwin`で得た
解決グラフの依存569件を`dependency-inventory.tsv`に記録した（ビルド用を含む）。
宣言ライセンスにGPL/AGPL/LGPLは見つからなかった。
`tree-sitter-graphql 0.1.0`はSPDX欄が未指定だが`license-file = "LICENSE"`があり、同梱のMIT本文を確認・保存した。
MPL-2.0は`cbindgen 0.28.0`（GPUIのビルド用）と`option-ext 0.2.0`
（font-kitの推移的依存）の2件。これはライセンス宣言の棚卸しであり、
ソースファイルや同梱資産を含む最終配布物の完全監査ではない。

MPLはファイル単位の条件であり、独自コードを含むアプリ全体の公開を要求するものではない。
`option-ext`等の対象コードについては配布時にソースの入手先を案内するなど、MPLの条件に対応する。
[Mozilla公式FAQ Q8・Q11](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)

## アーキテクチャ

```text
GPUI desktop shell
  ├─ Explorer / tabs / editor surface                 基本のIDE操作
  ├─ reading route / evidence / questions / experiment 読むための機能
  └─ Readit core                                      UIから分離
       ├─ workspace & Git snapshots
       ├─ diff / anchors / reading state
       ├─ parser & language-service adapters           今後
       ├─ evidence-grounded explanation adapter        今後
       └─ isolated experiment runner                   今後
```

読みの記録は`path + revision/content + line/range + quote`に紐づける。
行番号だけではAIの追加変更でずれるため、内容変更を検出して未確認に戻す。
試作は全文一致による理解済み判定と、行の引用一致による疑問の陳腐化表示を実装した。
安定したシンボルID、前後文脈、ASTによるアンカーの移動は次段階。

Gitはシェル文字列を組み立てず、ローカルの`git`に個別引数を渡す。
試作はHEAD対作業内容。最終製品ではAI作業開始時のsnapshotからの変更集合を第一級にする。

## 採用の代償と確認条件

GPUI採用により描画は流用できる一方、編集品質（IME、選択、Undo、巨大ファイル）、
LSP統合、アクセシビリティ、配布・更新を独自に仕上げる必要がある。
0.2では複数行編集、選択、Undo/Redo、Tree-sitter色分け、検索、ファイル操作を追加した。
0.3ではLSPの定義・参照・型情報・シンボル等をローカル言語サーバーと連携した。
補完・診断、マルチカーソル、分割表示、大規模ファイル、クラッシュ復旧は未対応。

最初の製品判断は「GPUIで画面が出たか」ではなく、実際のAI変更を読む時間と理解の正確さが
従来のIDEより改善するかで行う。改善が見られない場合は読む機能の設計を見直す。


### 0.3の言語サービス

LSPのメッセージ転送、文書同期、位置変換、結果表示はReadit側の独自実装。
Pyright 1.1.413（MIT）、TypeScript Language Server 6.0.0（Apache-2.0）、
TypeScript 5.9.3（Apache-2.0）をReadit専用のnpmディレクトリで固定して利用する。
rust-analyzerは利用者のRustツールチェーンから起動する（MIT OR Apache-2.0）。
パッケージのライセンス文とTypeScriptのThirdPartyNoticeText、Pyrightのtypeshedライセンスを
`third-party/`へ記録した。最終配布時にはサーバー内のバンドル済み推移的依存も確認する。
現在の.appは言語サーバーを独立配布する製品パッケージではなく、開発用リポジトリを参照する。

LSP仕様: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
Pyright: https://github.com/microsoft/pyright
TypeScript Language Server: https://github.com/typescript-language-server/typescript-language-server
rust-analyzer: https://rust-analyzer.github.io/
