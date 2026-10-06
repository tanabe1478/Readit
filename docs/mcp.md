# AIからReaditを操作する

Readitは人間とAIが同じコードを見るためのエディターです。利用中のAIクライアントが説明を生成し、MCPでReaditのファイル・選択範囲・定義一覧・解説の吹き出しを操作します。

## 起動と接続

```sh
# 親ディレクトリがなければ、Readitが権限700で作成します。
cd /absolute/path/to/Readit/web
npm start -- /absolute/path/to/repository \
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

`--control-socket`を指定しない起動では、外部操作の待受を作りません。指定時は同じユーザーがアクセスできるプライベートなUnix socketを作ります。
Web版の画面用のHTTPは `127.0.0.1` だけで待ち受け、起動ごとのトークンとHostヘッダーの確認で、他のサイトのページからの操作を拒否します。要求はブラウザで開いている画面が処理し、画面を開いていない間は「Readit is not open in a browser」を返します。
旧版（ネイティブ版）は `./artifacts/Readit.app/Contents/MacOS/Readit --control-socket ...` で同じように接続できます。
別のReaditには別のsocketを指定します。既存のsocketは上書きしません。クラッシュで残った場合は、そのReaditプロセスが終了していることを確認してからsocketファイルを削除してください。通常終了時には自動で削除します。

## セッションごとにReaditを起動する

`readit_mcp.py` に `--launch` を付けると、そのMCPサーバー（＝AIのセッション）専用のReaditを起動します。複数のセッションが、それぞれ別の画面・ツアー・質問を同時に扱えます。

```sh
# Claude Code（user スコープ。どのプロジェクトでも、そのプロジェクトのフォルダで開く）
claude mcp add --transport stdio --scope user readit -- \
  python3 /absolute/path/to/Readit/tools/readit_mcp.py --launch
```

- 起動するのは最初のツール呼び出しのときです。`web/dist/server.js` を空いているポートで起動し、ブラウザでタブを開き、画面が応答するまで最大20秒待ちます。ツールを使わないセッションでは何も起動しません。
- 開くフォルダは `--workspace`、指定がなければMCPサーバーの作業ディレクトリです。最初のツール呼び出しが `readit_open_folder` なら、そのフォルダで起動します。
- socketは `--socket` で指定できます。指定がなければ `~/.readit/sessions/<名前>-<pid>-<乱数>.sock` を作ります（ログは同じ名前の `.log`）。`readit_state` の結果に `control_socket` として入るので、`readit_wait.py --socket` にそのまま渡せます。
- 画面の名前は `--label`、指定がなければMCPクライアントが名乗った名前（`clientInfo.name`）です。タブのタイトルとヘッダーに出るので、どのセッションの画面か見分けられます。
- タブを閉じた後にツールを呼ぶと、タブを開き直します。
- セッションが終わると（標準入力が閉じる、SIGTERM、SIGHUP）Readitを止めます。MCPサーバーが強制終了された場合も、Readitは標準入力の切断を検知して止まります（サーバーの `--exit-with-stdin`）。ガイドはメモリ内にあるので、セッションの終了とともに消えます。
- ブラウザを開くコマンドは `READIT_OPEN`（既定は macOS で `open`、他は `xdg-open`）、Node.js は `READIT_NODE`（既定は `node`）で変えられます。

`--launch` を付けない場合は従来どおり、`--socket` のReaditに接続します。手で起動した1つの画面を複数のセッションで共有すると、質問はすべてのセッションに届き、ツアーは後から登録した側で置き換わります。

## 操作

| ツール | 用途 |
| --- | --- |
| `readit_state` | 開いているプロジェクト、タブ、カーソル、選択、可視範囲、未保存状態 |
| `readit_open_folder` | 別のフォルダを今の画面で開く（IDEの「フォルダを開く」） |
| `readit_files` | プロジェクトのファイル一覧、絞り込み、ページ送り。ツリーで開いていないフォルダも含む |
| `readit_read` | 現在の本文を行範囲で取得。未保存の編集も含む |
| `readit_search` | プロジェクト全体の文字列検索。意味解析による参照とは区別 |
| `readit_open` | ファイル・行へ移動し、注目するコードを通常の選択表示で示す |
| `readit_symbol` | 現在位置の定義・使用箇所・型定義・実装・シンボル一覧・型情報 |
| `readit_history` | 移動履歴を戻る／進む |
| `readit_view` | ファイルツリー・差分・折返しを切り替える |

`readit_state`と`readit_open_folder`以外は、取得した`workspace`を必ず渡します。途中で人間が別のプロジェクトを開いた場合、異なるプロジェクトへの操作を拒否します。ダイアログ表示中は画面を移動する操作を拒否し、保存確認などの判断を妨げません。

座標は**1始まりの行・UTF-16列**です。範囲の末尾は含みません。例えば1行目全体を示すには、`line: 1, column: 1, end_line: 2, end_column: 1`を指定します。末尾行には存在する列を指定してください。

外部ファイルは、Readitが既に開いているファイル、または現在のプロジェクトで言語サーバーが返した定義に限りアクセスできます。任意のローカルファイルを読み出す汎用APIにはしていません。

操作結果はJSONで返り、MCPの`structuredContent`とtext contentの両方に含まれます。ツール実行エラーは`isError: true`で返ります。タイムアウト時に画面操作を無条件で繰り返さず、まず`readit_state`で結果を確認します。

## 別のフォルダを開く

`readit_open_folder(path)` は、IDEでフォルダを今のウィンドウに開き直すのと同じく、画面のプロジェクトを `path` に置き換えます。読みたいコードが、開いているフォルダの外（隣のリポジトリやworktreeなど）にあるときに使います。

- `path` は絶対パス、またはMCPサーバーの作業ディレクトリからの相対パスです。`readit_mcp.py` が実在するフォルダか確かめ、シンボリックリンクを解決してから渡します。
- 結果は切替後の `readit_state` と同じ形です。以降のツールには新しい `workspace` を渡します。古い `workspace` を渡した操作は拒否します。
- 既に開いているフォルダを指定した場合は何も変えずに状態を返します。
- タブ・移動履歴・固定欄・ガイドとツアーは切替とともに閉じます。
- 未保存の編集がある場合は、画面に通常の保存確認を出してエラーを返します。保存するか破棄するかは人間が決めます。確認が閉じた後に `readit_state` で切替の結果を確かめます。ダイアログ表示中は切替を拒否します。
- `--launch` でまだReaditを起動していなければ、`--workspace` ではなくこのフォルダで起動します。

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

## 質問をAIへ自動で届ける

吹き出しから質問を送った後に、チャットで「質問を送った」と伝える必要はありません。`tools/readit_wait.py` が質問を待ち、届いたら JSON を1行出力して終了します。Python 3.10 以上の標準ライブラリだけで動作します。

```sh
python3 /absolute/path/to/Readit/tools/readit_wait.py --stop-when-idle
```

`status` は `question`（質問）、`next`（単発の吹き出しの「次へ」）、`ended`（ガイドが無くなった。`--stop-when-idle` 指定時）、`truncated`（取りこぼし）、`timeout` のいずれかです。続けて待つときは、出力の `latest_sequence` を `--after` に渡します。socket は `--socket`、`READIT_SOCKET`、`~/.readit/control.sock` の順に決まります。

- Claude Code: readit-guide skill の手順で、エージェントがこのコマンドをバックグラウンドで実行します。終了するとエージェントが再開して回答し、また待機します。
- pi: `integrations/pi` のパッケージが、セッションの間このコマンドを動かし、質問をユーザーメッセージとして届けます。MCP サーバーと skill も同じパッケージで入ります。詳しくは [integrations/pi/README.md](../integrations/pi/README.md) を参照してください。

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

## 根拠・前提・予測で読む

概観とステップには、任意のフィールドを追加できます。省略すれば従来どおり動きます。

概観（`overview`）:

- `claims`: 重要な主張。最大8件。各要素は `id`（概観内で一意）、`statement`（最大1,000文字）、`confidence`（`source_confirmed` または `inferred`）、`evidence`（1〜8件）。
- `evidence` の各要素は `label`（最大100文字）、`path`、`line`、`column`、`expected_text`。座標と一致の規則はステップと同じで、プロジェクト内のファイルに限ります。
- `reader_context`: `known`（説明を省いた前提、最大16件）と `focus`（今回の焦点、最大8件）。各要素は最大200文字。メモリ内だけで保持し、ファイルには書きません。

```json
"claims": [{
  "id": "session-owner",
  "statement": "Sessionが会話状態の主要な所有者になっている",
  "confidence": "source_confirmed",
  "evidence": [{"label": "Sessionのstate保持", "path": "src/session.rs", "line": 42, "column": 1, "expected_text": "..."}]
}],
"reader_context": {"known": ["async/await"], "focus": ["Sessionの所有権"]}
```

概観では主張を「コード上で確認」「推論」の印付きで表示し、前提は折りたたんだ「今回の前提」に出します。根拠をクリックすると、概観タブを残したままそのコードを選択します。ツアーの `index`、`visited_through`、`seen_steps` は変わりません。根拠のファイルが登録時から変わっていれば（ステップと同じ判定）、移動せず「ソースが変更されています。このガイドを更新してください。」と表示します。根拠は `readit_guide_load` と `readit_guide_revise` のたびに全件検証し、1件でも不一致なら何も置き換えません。

ステップの `kind`（省略時は `explanation`）:

| kind | 必須の追加フィールド | 表示 |
| --- | --- | --- |
| `explanation` | なし | 従来どおり |
| `hypothesis` | なし | 「仮説」の印。本文の真偽はReaditは判定しない |
| `prediction` | `prompt`（最大2,000文字） | 問いと入力欄。「予測を記録」または「わからない」を選ぶまで「次へ」は押せない |
| `verification` | `verifies`（それより前の `prediction` ステップのID） | 記録した予測（または「わからない」）を本文の前に表示 |

`prompt` は `prediction` 以外に、`verifies` は `verification` 以外に付けられません。予測のステップでも「戻る」、概観、章への移動、ファイルの移動は制限しません。章から先へ飛んだ場合、検証のステップには「予測は記録されていません。」と表示します。正誤の判定や採点はしません。`kind` は `readit_guide_load` / `readit_guide_revise` のステップ専用で、`readit_guide_show` では拒否します。

予測は `readit_state.guide_tour.predictions` に、ステップ順の配列で入ります（予測が無ければ空配列）。各要素は `step_id`、`status`（`answered` / `unknown`）、`answer`（`unknown` では `null`）です。`guide_tour.steps` と `guide` にも `kind` が入ります。記録すると `readit_guide_events` に `action: "prediction"` のイベント（`id`、`tour_id`、`status`、`answer`）が追加され、連番が進みます。`readit_wait.py` はこのイベントでは終了しません。予測はAIに答え合わせを求めるものではないためです。

`readit_guide_revise` は既読部分の予測を保持します。予測は表示中のステップでしか記録できないので、置き換わる未読部分に予測はありません。ガイドのclear、プロジェクトの切替、アプリの再起動で予測は消えます。

旧版（ネイティブ版）はこの拡張に対応していません。`claims` や `reader_context` を含む概観は登録時にエラーになり、ステップの `kind`・`prompt`・`verifies` は無視されて通常の説明として表示されます。

