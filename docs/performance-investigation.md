# Readit 性能調査 — 2026-09-12

## 初回調査時の結論

GPUIの採用だけで低遅延になるわけではない。最適化なしの開発ビルドと、UIスレッドで行うコピー・ツリー構築を先に切り分ける。今回、主因や改善率を実測で確定してはいない。製品コードは変更していない。

## 確認した事実

- `scripts/package_macos.py` は `target/debug/readit` をアプリへコピーする。Cargoのdev設定は `debug=0`（デバッグ情報の無効化）だけで、最適化レベルの指定はない。現時点で `target/release/readit` は存在しない。
- `Reader::update_pointer` は250msのタイマーより前に `sync_buffers` と全ドキュメントの本文のcloneを実行する。さらに `Snapshot` 自体をcloneして保持する。同じ確定済みシンボルなら戻るが、別シンボルを横切る操作でコピーが発生し得る。
- `sync_buffers` は開いた全バッファの本文を毎回String化してドキュメントへ代入する。
- `Reader::explorer` は再構築のたびに `tree_entries` を作り、折り畳み後の全エントリを `children` に渡す。ビューポート内の行だけを作る仮想リストにはなっていない。
- MCPの受信確認は30ms間隔。何も届かない場合に明示的なnotifyはないため、これを33FPSでの再描画と解釈してはいけない。
- 実行中のReadit Guideは1プロセス。psの取得時点でCPU 0.6%、RSS 217024 KiB。sampleのphysical footprintは300.0M、ピーク354.8M（RSSとは異なる指標）。
- 10秒と20秒のsampleは主にイベント待ち。スクロールを送った区間でも画面移動の確認が不十分なため、操作中の性能を代表するデータにはしない。CPUサンプルの件数はフレーム時間やFPSではない。

計測生データは `artifacts/performance/readit-sample.txt` と `readit-scroll-sample.txt` に保存。端末・プロセス情報を含むローカル調査用データ。

## 利用可能な計測方法

### Instruments（最初の原因調査）

手元のXcodeでTime Profiler、CPU Profiler、Animation Hitches、Metal System Trace、Allocationsのテンプレートが利用可能と確認した。Time ProfilerでUIスレッドのCPU処理、Allocationsで文字列複製、Metal System TraceでGPU提出・実行を切り分ける。Animation Hitchesの情報だけでGPUIの全フレームを計測できるとは仮定しない。

https://developer.apple.com/documentation/xcode/improving-app-responsiveness

### Tracy / profiling（継続的な開発時計測）

利用中のGPUI 0.2.2には `#[profiling::function]` がWindow::drawとpresentにあり、present末尾に `profiling::finish_frame!()` がある。解決済みのprofiling 1.0.18は `profile-with-tracy` を提供する。Readit側のfeatureから同じ依存のバックエンドを有効化し、クライアントを起動する方法が候補。現時点では有効化・接続を行っていない。

Readit側にも `render`、`explorer`、`pointer_symbol`、`update_pointer`、`sync_buffers`、`activate_guide` のスコープを付ける。記録するのは時間、ファイル数、コピー総バイト数など。本文や質問内容をトレースに入れない。描画間隔、CPU側draw時間、GPU時間、入力から表示までの遅延を区別する。アイドル時は再描画がないため単純な平均FPSを健康度にしない。

Zed本体はsamplyとTracyを案内している。ただし現在のZed mainにある `gpui::profiler` とReaditが固定している0.2.2は違う。Zedのプロファイラ画面をそのまま呼べるわけではない。

https://github.com/zed-industries/zed/blob/main/docs/src/performance.md
https://github.com/zed-industries/zed/blob/main/crates/gpui/src/profiler.rs
https://github.com/mstange/samply

## 次の比較手順

1. シンボル情報を保持した最適化ビルドを用意し、同じソース・同じファイル数・同じ開いたタブ・同じガイドでdev版と比較する。
2. アイドル、本文スクロール、ツリースクロール、シンボルを横切るホバー、吹き出し移動、章切替を別の区間として記録する。ウォームアップ後に複数回測る。
3. CPU側フレーム処理時間のp50/p95/p99、長いフレームの数、操作の所要時間、割当量を見る。60Hzの16.7ms、120Hzの8.3msは目安であり、CPU処理に全予算を使ってよいわけではない。
4. 全文コピーの遅延実行・変更バッファのみの同期・ツリーのキャッシュ/仮想化を一つずつ適用し、同じ操作で改善を検証する。
5. 計測は開発用featureでオンにし、通常利用時の追加負荷を抑える。自動アップロードや常駐外部監視は不要。

## 計測機能の使い方

`performance` featureを付けるとGPUIの`draw` / `present`とReaditの処理を同じローカルJSONLへ記録できる。GPUIが依存する`profiling`のtracingバックエンドを使うため、GPUI自体のフォークは不要。通常ビルドには追加の収集器を含めない。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cargo build --release --features performance --offline
READIT_PERF=/tmp/readit-release.jsonl READIT_PERF_SECONDS=60 target/release/readit /path/to/repository
python3 scripts/perf_report.py /tmp/readit-release.jsonl
```

開発版は `cargo build --features performance --offline` と `target/debug/readit` で同様に測る。同じリポジトリ、同じファイル/行、同じウィンドウ寸法を使う。READIT_PERFの出力先は既存ファイルを上書きしない。秒数は1〜600、既定120秒。収集終了後もアプリは利用できる。通常終了前に計測時間＋1秒が経過すると完了フッターを出力する。強制終了したログはフッターがなく、レポートで未完了と分かる。

UIスレッドでのファイル書込みを避けるため、8192件の上限付きキューから別スレッドへ送る。満杯なら待たずに捨て、フッターにdropped件数を記録する。本文、質問、tracingの属性値は収集しない。収集器自体の軽微な負荷はあるため、比較の両側で同じfeatureを使う。

レポートのdrawはGPUIのCPU側描画準備時間、presentはCPU側の提出処理時間。GPU完了時間や入力→表示の遅延を直接表すものではない。ネストした処理時間は重複するため加算しない。描画がない待機時間を低FPSと判定しない。GPUの調査にはInstrumentsのMetal System Traceを併用する。

パッケージは `python3 scripts/package_macos.py` がrelease版を選ぶ。開発版を明示的に試す場合だけ `--profile debug` を指定する。アドホック署名であり商用配布用の公証ではない。


## 実装後の測定（同日）

piの400ファイル、同じファイルの行100/592への30回の移動、1ステップのガイド読み込みと20回の概観切替で確認した。各版で開いたタブは2枚。全計測窓の参考集計は以下。ウォームアップ除外や多数回の独立試行を行った厳密なベンチマークではなく、起動・待機中の再描画も含む。実描画回数はフレームの統合などで異なる。外部操作ツールの待ち時間はこれらのCPU scopeに含まない。

| ビルド | draw中央値 | draw p95 | フレーム数 | >16.7ms |
|---|---:|---:|---:|---:|
| 開発版 | 76.138 ms | 109.309 ms | 93 | 93 |
| 最適化のみ | 14.057 ms | 34.266 ms | 158 | 48 |
| 最適化＋ツリー仮想化＋階層構築改善 | 4.960 ms | 7.238 ms | 205 | 2 |

最終版のp99は10.873ms、最大49.151ms。遅い描画が完全になくなったわけではない。全てログ完了・ドロップ0。記録は `artifacts/performance/{debug-baseline,release-baseline,release-final}.jsonl`。中間の仮想化のみの記録は追加の手動スクロールも含むため、表の厳密比較対象にはしない。

実施した改善:

- パッケージのデフォルトをreleaseへ変更（最適化＋シンボル情報）。
- ツリーをGPUIのuniform_listにし、画面内の行だけ構築。キーボードでの項目へのスクロールも対応。
- 階層構築でディレクトリごとに全項目を走査する処理を廃止し、親→子の索引を一度作って辿る。
- `performance` feature、時間制限・上限付きのローカル収集器、分位値集計スクリプトを追加。

ホバーの全文コピーは依然として改善候補だが、今回の操作列ではホバー試行数が少なく、主因と断定できないため変更していない。今後はホバー・吹き出しドラッグを独立した操作区間で測り、入力→表示の遅延とGPU処理はInstrumentsで確認する。
