# Readit Web

Readit を MoonBit で書き直したブラウザ版です。画面は MoonBit を wasm-gc にコンパイルして動かし、ファイル・Git・言語サーバー・MCP の制御ソケットは、同じく MoonBit を JS にコンパイルしたローカルサーバー（Node.js）が担当します。サーバーは `127.0.0.1` だけで待ち受けます。

機能はネイティブ版（リポジトリ直下の Rust / GPUI 版）と同じです。MCP の操作と `tools/readit_mcp.py` もそのまま使えます。

## 起動

必要なもの: MoonBit（`moon`、mise の `http:moonbit` 0.10.14 で確認）、Node.js 24、npm。LSP を使う場合は、ネイティブ版と同じ `python3 scripts/setup_lsp.py` で `tools/lsp` を用意します。

```sh
cd web
npm install
npm run build          # wasm-gc と JS をビルドし、www/ に配置
npm start -- /absolute/path/to/repository
```

`npm start` は既定のブラウザで `http://127.0.0.1:7420/` を開きます。引数なしなら `demo/` を開きます。主なオプション:

| オプション | 内容 |
| --- | --- |
| `--port N` | 待受ポート。`0` で空いているポートを使う |
| `--control-socket PATH` | MCP 用の Unix socket。親ディレクトリは権限 700 |
| `--no-open` | ブラウザを開かない |
| `--label NAME` | 画面の名前。タブのタイトルとヘッダーに出る |
| `--exit-with-stdin` | 標準入力が閉じたら終了する。起動した側のプロセスと一緒に止めるため |

`moon` が PATH にない場合、ビルドは `mise where http:moonbit@0.10.14` から探します。`MOON` 環境変数でも指定できます。

## ネイティブの Moon が動かない環境でのビルド

Android のように Linux 用 `moon` / `moonc` を実行できない場合は、公式の
JavaScript コンパイラ API による別経路を使えます。Node.js 24 以上と、通常の
ブラウザ部品・MoonBit 文法が準備されたこの checkout が必要です。
コンパイラと標準ライブラリは **独立した私的ディレクトリ** に置きます。
既存の Node、Android Pi、認証設定や sandbox は変更しません。

現在この経路で検査する組合せは、`@moonbit/moonc-worker` の npm 固定版
`0.1.202609203`（package 内の版は `0.1.202609203+7d59c7ec9`）と、
`moonbitlang/core` `0.10.14+7d59c7ec9` です。入手済みの公式 SDK を明示します。
スクリプトは依存をダウンロード・インストールせず、バージョンが違えば停止します。

```sh
cd web
PRIVATE_BUILD=/absolute/path/to/private/build-root
npm run build:js -- \
  --compiler "$PRIVATE_BUILD/compiler-js/node_modules/@moonbit/moonc-worker/moonc-web.cjs" \
  --stdlib "$PRIVATE_BUILD/toolchain/lib/core" \
  --out "$PRIVATE_BUILD/staged-release-1"
# 最適化なしの debug ビルドは --debug を追加。--out は毎回新しい場所にする。
```

出力は `--out` 以下の `web/www/` と `web/dist/server.js` です。Wasm とサーバー JS、
その時点の HTML / CSS / glue / vendor / 文法を一緒にステージします。
`build.json` はコンパイラ・ソース入力・全配信ファイルの SHA-256、診断、検証範囲を記録します。
`complete: true` はビルドと構文・Wasm モジュール検査の完了であり、ブラウザ動作確認の意味ではありません。
入力がビルド中に変わると停止します。既存ステージ、live の `www/` / `dist/` は上書きしません。
サーバーの開始・再読込み・Preview の表示・公開も自動では行いません。

この経路は Readit と上記標準ライブラリの production 依存、import の別名、target / debug 条件、
app の exports / JS String Builtins を扱います。SDK に Moon の暗黙 prelude / skip-tests 設定が
ないため、仮想ファイルの明示 `using` と、構文木で検査した inline test の空白化で補います。
元のソースや SDK ファイルは書き換えず、行と UTF-16 の位置を保ちます。
未知の依存・条件や不完全な test の構文解析は停止します。汎用の Moon package manager でも、
`moon test` の代替でもありません。警告は `compiler.log` / `build.json` に残ります。

```sh
# repository root: Node / glue / build-helper の回帰テスト
node --experimental-vm-modules --test tests/node/*.test.mjs web/tests/unit/*.test.mjs

# 対応する host ブラウザ上で候補を検証（live 配信ファイルは交換しない）
cd web
READIT_TEST_WEB_ROOT="$PRIVATE_BUILD/staged-release-1/web" \
  npm run test:e2e -- tests/e2e/guide-toggle.spec.js
```

Android 上の Playwright browser launch は非対応です。Node テストやビルド成功を、
Chromium / WebKit の real-Wasm E2E や実機の指・IME 操作の成功として扱いません。
候補のブラウザ確認と、現在のガイド・質問・未保存編集・入力・ダイアログの確認が済むまでは、
ユーザーの画面を再読込みしたり候補を公開したりしません。

## スマホ・タブレット表示

幅900 CSS px以下では編集領域を全幅にし、ファイルツリーを左上の ☰ から
開くドロワーに切り替えます。ファイルを選ぶと自動で閉じます。初期表示では
コードを折り返します（表示メニューから切替可能）。ファイルを開くだけでは
ソフトキーボードを出さず、本文をタップした時に編集入力へフォーカスします。

メニューとダイアログは画面内でスクロールでき、閉じるボタンで操作できます。
ナビゲーションバーは横にスワイプでき、固定したコードは編集領域の下に並びます。
検索・IME入力欄も画面内に収め、キーボード表示時のviewport変更に追従します。
キーボードで高さが狭くなる時はメニュー行・編集ナビゲーションを畳み、本文領域を確保します。
広い画面では従来のサイドバーと横並びの固定コード表示を維持します。

`tests/e2e/mobile.spec.js` は360×682（縦）・800×400（横）で、タッチ操作、
ドロワー、メニュー、検索、ダイアログ、IME入力位置、固定コードを確認します。
Chromium / WebKitの自動テストに加え、Android実機のWebViewで表示確認しています。

## AI から操作する

ネイティブ版と同じ手順です。制御 socket を付けて起動し、MCP クライアントには `tools/readit_mcp.py` を登録します。

```sh
npm start -- /path/to/repository --control-socket ~/.readit/control.sock
python3 ../tools/readit_mcp.py --socket ~/.readit/control.sock
```

AI のセッションごとに専用の Readit を使う場合は、`python3 ../tools/readit_mcp.py --launch` だけを登録します。最初のツール呼び出しで Readit を起動して画面を開き、セッションの終了とともに止めます（[docs/mcp.md](../docs/mcp.md#セッションごとにreaditを起動する)）。

要求はブラウザで開いている画面が処理します。画面を閉じている間は「Readit is not open in a browser」を返します。複数のタブで開いた場合は、最後に開いたタブが応答します。

## 構成

| パッケージ | ターゲット | 役割 |
| --- | --- | --- |
| `core` | 全て | UTF-16 座標、差分、ファイルツリー、シンボル範囲、読む順番 |
| `editor` | 全て | 編集モデル（選択、Undo/Redo、カーソル移動、インデント） |
| `lsp` | 全て | LSP 応答の解釈、`file://` URI、メッセージの区切り |
| `app` | wasm-gc | 画面の状態と描画、キー操作、MCP 操作の処理、読解ガイド |
| `server` | js | HTTP、ファイル操作、Git、言語サーバー、制御 socket の中継 |

`www/glue/` は、wasm からは触れないブラウザの機能をつなぐ薄い JS です。状態は持たず、すべて `app` 側が持ちます。

| ファイル | 役割 |
| --- | --- |
| `main.js` | 起動。wasm-gc を JS String Builtins 付きで読み込む |
| `bridge.js` | wasm の関数の保持と、アプリへのイベント送信 |
| `dom.js` | 領域の HTML 更新、スクロール、IME 用入力欄の位置合わせ |
| `hit.js` | 画面上の位置と行・列の相互変換 |
| `input.js` | キー・マウス・フォーカス・スクロールの配線、制御ストリーム |
| `server.js` | API 呼び出し、タイマー、クリップボード、正規表現 |
| `highlight.js` | Tree-sitter（web-tree-sitter）による構文ハイライト |

## ネイティブ版との違い

- ブラウザが予約しているキーは奪えない場合があります。代替キーを用意しています: ⌃W（タブを閉じる）、⌃N（新規ファイル）、⌃⇧T（閉じたタブを開く）、⌃Q（終了）、⌥⌘←/→（タブ切替）。
- macOS のメニューバーの代わりに、画面上部にメニューがあります。
- ファイル／フォルダを開くダイアログは、macOS では `osascript` でネイティブのダイアログを表示します。他の OS ではパスを入力します。
- 終了（⌃Q）はサーバーを停止します。ブラウザのタブは閉じられないことがあります。
- 未保存の変更がある状態でタブを閉じようとすると、ブラウザが確認を出します。

## セキュリティ

- 待受は `127.0.0.1` のみです。Host ヘッダーが loopback 以外の要求は拒否します（DNS rebinding 対策）。
- ページには起動ごとのトークンが埋め込まれ、API はこのトークンなしでは応答しません。他のサイトのページから API を呼べないようにするためです。
- Content-Security-Policy で、同一オリジン以外の読み込みを禁止しています。
- ファイル操作の検査（シンボリックリンクの除外、外部で変更されたファイルへの上書き拒否、予約領域の保護）はネイティブ版と同じです。

## テスト

```sh
moon test                      # core / editor / lsp の単体テスト
npm run test:e2e               # Playwright（Chromium と WebKit）
READIT_TEST_JAVA=1 npm run test:e2e   # Java の LSP テストも実行
```

E2E テストは一時ディレクトリにプロジェクトを作り、実際のサーバーと wasm の画面を操作します。ネイティブ版の `src/ui.rs` と `src/ui_e2e_tests.rs` にある制御・ガイドのテストを、同じ手順で移植しています。LSP のテストは `tools/lsp` が無い場合は飛ばします。

確認したブラウザ: Playwright の Chromium と WebKit 26.6（Safari 26 相当）。Firefox は未確認です。wasm-gc と JS String Builtins に対応したブラウザが必要です。

## 第三者の部品

ブラウザに配信するもの:

- web-tree-sitter 0.25.10（MIT）
- Tree-sitter 文法（すべて MIT）: python 0.25.0、rust 0.24.0、javascript 0.25.0、typescript 0.23.2、json 0.24.8、go 0.25.0、java 0.23.5、html 0.23.2、css 0.25.0、bash 0.25.1、c 0.24.1、cpp 0.23.4、ruby 0.23.1、toml 0.7.0、yaml 0.7.1
- tree-sitter-markdown 0.5.3（MIT）。npm に wasm が無いため、ビルド時に GitHub のリリースから取得し、SHA-256 を検証します。
- tree-sitter-moonbit（Apache-2.0、コミット `5435c30`）。wasm が公開されていないため、ビルドした結果を `third-party/tree-sitter-moonbit/` に置いています。作り直しは `node scripts/build-moonbit-grammar.mjs` です。

テストだけで使うもの: @playwright/test 1.63.0（Apache-2.0）。
