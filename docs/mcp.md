# AIからReaditを操作する

Readitは人間とAIが同じコードを見るためのエディターです。利用中のAIクライアントが説明を生成し、MCPでReaditのファイル・選択範囲・定義一覧・解説の吹き出しを操作します。

## 起動と接続

```sh
# 親ディレクトリがなければ、Readitが権限700で作成します。
./artifacts/Readit.app/Contents/MacOS/Readit --demo \
  --control-socket /tmp/readit-guide/control.sock

# このプロセスをMCPクライアントから起動します。
python3 /absolute/path/to/Readit/tools/readit_mcp.py \
  --socket /tmp/readit-guide/control.sock
```

MCPクライアントのstdio設定例（絶対パスは環境に合わせて変更）:

```json
{
  "mcpServers": {
    "readit": {
      "command": "python3",
      "args": ["/absolute/path/to/Readit/tools/readit_mcp.py", "--socket", "/tmp/readit-guide/control.sock"]
    }
  }
}
```

MCPクライアントごとの設定形式に合わせてこのcommandとargsを登録します。ReaditはAIプロバイダーに依存しません。Python 3.10以上の標準ライブラリだけで動作します。

`--control-socket`を指定しない起動では、外部操作の待受を作りません。指定時は同じユーザーがアクセスできるプライベートなUnix socketを作ります。ネットワーク用HTTPポートは開きません。
別ウィンドウには別のsocketを指定します。既存のsocketは上書きしません。クラッシュで残った場合は、そのReaditプロセスが終了していることを確認してからsocketファイルを削除してください。通常終了時には自動で削除します。

## 操作

| ツール | 用途 |
| --- | --- |
| `readit_state` | 開いているプロジェクト、タブ、カーソル、選択、可視範囲、未保存状態 |
| `readit_files` | エディターが読み込んだファイルの一覧、絞り込み、ページ送り |
| `readit_read` | 現在の本文を行範囲で取得。未保存の編集も含む |
| `readit_search` | プロジェクト全体の文字列検索。意味解析による参照とは区別 |
| `readit_open` | ファイル・行へ移動し、注目するコードを通常の選択表示で示す |
| `readit_symbol` | 現在位置の定義・使用箇所・型定義・実装・シンボル一覧・型情報 |
| `readit_history` | 移動履歴を戻る／進む |
| `readit_view` | ファイルツリー・差分・折返しを切り替える |

`readit_state`以外は、取得した`workspace`を必ず渡します。途中で人間が別のプロジェクトを開いた場合、異なるプロジェクトへの操作を拒否します。ダイアログ表示中は画面を移動する操作を拒否し、保存確認などの判断を妨げません。

座標は**1始まりの行・UTF-16列**です。範囲の末尾は含みません。例えば1行目全体を示すには、`line: 1, column: 1, end_line: 2, end_column: 1`を指定します。末尾行には存在する列を指定してください。

外部ファイルは、Readitが既に開いているファイル、または現在のプロジェクトで言語サーバーが返した定義に限りアクセスできます。任意のローカルファイルを読み出す汎用APIにはしていません。

操作結果はJSONで返り、MCPの`structuredContent`とtext contentの両方に含まれます。ツール実行エラーは`isError: true`で返ります。タイムアウト時に画面操作を無条件で繰り返さず、まず`readit_state`で結果を確認します。

## 読解を案内するskill

配布用の[readit-guide](../skills/readit-guide/SKILL.md)を同梱しています。利用するAIクライアントのskillディレクトリに配置して使えます。
「入口を表示する → 定義を辿る → 境界条件のテストを表示する」という操作を、ユーザーの質問に合わせて案内します。メモの作成やファイルの保存はこのskillの役割に含めていません。

## 実装範囲

今回のMCPは閲覧・ナビゲーション操作です。ファイル編集・保存・削除・シェル実行・AI推論のAPIは含みません。人間による通常の編集機能は引き続き使えます。
LSPの対象言語や読み込めるファイルの上限はエディター本体と共通です。対応していないシンボル解析を文字列検索で代用して成功扱いにはしません。

MCP stdioは[公式transport仕様](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)に従う改行区切りJSON-RPCです。initialize、initialized、ping、tools/list、tools/callを実装しています。MCPプロセスとGUI間はアプリ内のUnix socket APIです。

## 一連の解説をまとめて登録する

通常の読解ガイドには `readit_guide_load` を使います。AIが関連コードを読んで一連の説明を生成し、`workspace`, `id`（ツアーID）, `event_sequence`, `steps` を送ります。`steps` は1〜32件で、各要素に `id`, `title`, `body`, `path`, `line`, `column`, `expected_text` が必要です。座標は1始まり・UTF-16列。すべてのソース一致を確認してから一括で登録するので、途中のステップが不正な場合は現在の解説を置き換えません。

Readit内の「次へ・戻る」は用意済みの説明を即座に表示します。最後は「完了」です。AIが応答を終えても操作できます。`step` イベントは移動通知であり、AIに次の解説の生成を要求するものではありません。`readit_state.guide_tour` の `index`, `visited_through` は0始まりで、`total` とステップID・タイトルの一覧も返します。訪問済みの説明とQ&Aは前後移動しても保持します。次のコードが編集されていた場合は古い解説へ移動せず、再生成が必要である旨を表示します。

質問には、回答と未読部分の説明を生成して `readit_guide_revise` を送ります。引数は `workspace`, `id`（ツアーID）, `event_sequence`, `question_sequence`, `answer`（最大4,000文字）, `steps` です。`steps` は `visited_through` より後の未読部分すべてを置き換えます。空配列なら既読部分を最後にします。既読部分・現在位置を維持し、質問元に回答を付け、未読部分を一括で差し替えます。再生成中も既存のステップを読めます。

生成中にユーザーが移動した場合は古い `event_sequence` を拒否するため、状態を読み直して未読部分を調整してください。終了したガイドや古い質問に対する回答も拒否します。新しい質問への回答・再生成は外部AIが必要ですが、用意済みの解説の閲覧には継続接続は不要です。

吹き出しは本文に応じた高さになり、収まらない場合だけ全体をスクロールします。ステップ切り替え時は注釈対象をエディター上部へ配置し、その下に説明用の空間を作ります。見出しをドラッグして手動配置もできます。

## 単発のコードに紐づく吹き出し


`readit_guide_show` は対象コードを選択し、その近くに解説と「次へ・質問・終了」を表示します。`expected_text` に現在のコードをそのまま渡し、`event_sequence` には状態の `guide_event_sequence` を指定してください。説明はプレーンテキストで最大2,000文字です。

`readit_guide_events(workspace, after)` でボタンへの反応を取得します。非破壊の連番方式で直近128件を保持します。`latest_sequence` を次回の `after` と `event_sequence` に使います。`next` なら次の箇所、`question` なら質問文とコード・元の説明・直前の質問と回答を受け取ります。`readit_guide_answer` に `workspace`、ステップの `id`、質問イベントの連番を `question_sequence`、回答を `body` として渡します。ガイドの位置は保ったまま回答し、「次へ」でのみ先へ進みます。`end` / `interrupted` / `cleared` または `truncated: true` では案内を止めてください。Escでも終了します。`readit_guide_clear` で吹き出しを消せます。

ファイル移動・本文編集で古い吹き出しを無効化し、画面外へのスクロールでは一時的に隠します。LLMの呼び出しは外部クライアントが担当します。MCP側からLLMを自動起動する機能ではなく、接続先がガイド中にイベントをポーリングして次の説明を送る方式です。音声は未実装です。


`readit_guide_show` の呼び出し例（workspaceとevent_sequenceは現在の状態で置き換えます）:

```json
{
  "workspace": "/absolute/path/to/Readit/demo",
  "id": "subtotal-1",
  "title": "割引後の小計",
  "body": "商品価格の合計から割引額を引き、0円を下限にします。",
  "path": "src/checkout.py",
  "line": 13,
  "column": 5,
  "expected_text": "subtotal = max(0, sum(prices) - discount)",
  "event_sequence": 0
}
```


「質問」で入力欄を開き、「送信」で1〜2,000文字の質問を送ります。空欄は送信しません。送信後は質問と回答待ち表示を残し、回答後は「追加で質問」できます。回答は最大4,000文字です。質問イベントには `question`、`expected_text`、行・列、`explanation`、`previous_question`、`previous_answer` が含まれます。終了解除やソース変更後、または別の質問への回答は拒否します。入力中のキャンセルでは送信せず元の説明へ戻ります。

従来の固定補足を返す `detail` イベントは `question` に置き換えました。クライアントは質問を処理して `readit_guide_answer` を呼ぶ必要があります。LLMが接続されていない場合、回答は自動生成されません。


## 関連コードを横に固定

`readit_pin(workspace, path, line)` は指定したファイルを右側に固定します。主エディターのファイルやカーソルは移動しません。`line` は1始まりで、省略時は1です。読み込んだプロジェクトのファイルと、LSPで返された外部定義に対応します。

固定欄は未保存の編集も含む、固定時点の読み取り専用表示です。元の本文が変わると変更ありと表示し、「更新」または再度 `readit_pin` で取り直します。固定できるのは1ファイルで、次の固定で置き換わります。`readit_unpin(workspace)` または×で閉じます。プロジェクトを切り替えると解除します。状態は `readit_state` の `pinned` で取得できます。

手動では本文上の「横に固定」または ⌘K → ⌘P を使います。まず定義を固定してから呼び出し元に戻ると、両方を見比べられます。

吹き出しは注釈対象の可視範囲全体を避けて配置し、見出しをドラッグすると移動できます。移動位置は現在のステップで保持し、次のステップでは自動配置に戻ります。「次へ」は解説を消さずに待機表示に切り替え、二重送信を防ぎます。10秒応答がない場合はAI側での再開を案内します。`readit_state.guide.pending_next` が待機状態を表します。この表示はAIとの常時接続を保証するものではありません。

## 概観からコードへ読む

`readit_guide_load` に任意の `overview` を追加すると、最初にネイティブの「概観」タブを表示する。目的、構成と処理の流れ、各章の概要・対象ファイルを確認してから、章の「コードを読む」で登録済みステップへ移動できる。ヘッダーと吹き出しの「概観」で戻る。タブは×／⌘Wで閉じ、タブ切替ショートカットでも移動できる。

```json
{
  "title": "会話の保存と再開",
  "summary": "履歴を開くことと、実行を再開することの違いを読む。",
  "relationships": "SessionRepo → Session → Branch / Entry\n保存済み状態 → Harness → resume",
  "chapters": [
    {"title": "履歴の構造", "summary": "Entryと分岐の関係を確認する。", "start_step": "entry"},
    {"title": "実行の再開", "summary": "保存した状態を実行へ戻す境界を確認する。", "start_step": "resume"}
  ]
}
```

上のオブジェクトを `overview` に渡す。`start_step` は同時に渡す `steps` 内の実在するIDで、最初の章は先頭ステップから始まり、以降はステップ順で指定する。最大16章。titleは100文字、summaryは全体2000／各章1000文字、relationshipsは4000文字。全てプレーンテキスト。任意HTML・スクリプトは実行しない。

`readit_state` は `overview_visible` と `guide_tour.overview`、`seen_steps` を返す。表示済み数は理解度の判定ではない。`readit_view` の `overview: true` で再表示できる。章へ飛ぶと `visited_through` はそこまで進むため、質問後の再生成では未表示の中間ステップも含めて既存の前半を保持する。章付きガイドの `readit_guide_revise` には、保持する前半と更新する後半に対応した完全な `overview` も必須。検証失敗時はガイド・回答・概観を全て維持する。

概観は寄り道や終了後も同じウィンドウ内に残り、コードが変わった場合は更新を促す。ガイドを明示的にclearするか、プロジェクトを切り替えると破棄する。現時点ではメモリ内の保持であり、アプリ再起動を跨ぐ永続化や図の自動解析は行わない。
