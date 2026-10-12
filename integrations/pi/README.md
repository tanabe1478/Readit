# Readit for pi

pi から Readit を使うためのパッケージです。次の 3 つをまとめて提供します。

- Readit の MCP サーバー（`tools/readit_mcp.py`）の接続。ツールは直接呼べる形（`exposure: "direct"`）で登録します
- readit-guide skill（`skills/readit-guide` へのリンク）
- ガイドの吹き出しから送られた質問を、セッションへユーザーメッセージとして届ける機能。エージェントが作業中なら、作業の後に届けます（`deliverAs: "followUp"`）

## インストール

```sh
pi install /absolute/path/to/Readit/integrations/pi
```

pi のセッションごとに専用の Readit を使います。最初に Readit のツールを使ったときに、pi を起動したフォルダを開いた画面がブラウザに開き、セッションの終了とともに止まります（`readit_mcp.py --launch`）。画面のヘッダーには `pi` と出ます。Claude Code など他のセッションの画面やツアーとは混ざりません。

手で起動した Readit を使いたい場合は、その socket を `READIT_SOCKET` に設定します（例: `READIT_SOCKET=~/.readit/control.sock`）。この場合は起動せず、その画面につなぎます。Python は `READIT_PYTHON`（既定はWindowsで`python`、それ以外で`python3`）で変えられます。

## 使い方

セッションを開始すると、フッターに「Readit: 質問を待機中」と表示され、待機が始まります。`/readit-watch off` で止め、`/readit-watch on` で再開します。`READIT_WATCH=0` を設定すると自動では始めません。

## テスト

`web/tests/e2e/pi.spec.js` が、この拡張を pi の SDK セッションに読み込み、faux プロバイダー（台本どおりに応答し、どこにも接続しないモデル）で MCP ツールの呼び出しと質問の配信を確認します。`cd web && npx playwright test pi.spec` で実行します。

待機は `tools/readit_wait.py` を子プロセスとして動かします。Readit が起動していない間は静かに再試行し、セッションの終了とともに止まります。`~/.pi/agent/mcp.json` に `readit` という名前のサーバーがある場合は、そちらが優先されます。
