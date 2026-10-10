// HTML for each region. The glue replaces a region only when its HTML changes.

///|
/// A nonempty `disabled` disables the button and explains why.
fn button(
  act : String,
  label : String,
  arg? : String = "",
  extra? : String = "",
  disabled? : String = "",
) -> String {
  let data = if arg == "" { "" } else { " data-arg=\"\{e(arg)}\"" }
  let off = if disabled == "" {
    ""
  } else {
    " disabled title=\"\{e(disabled)}\""
  }
  "<button class=\"btn\{extra}\" data-act=\"\{act}\"\{data}\{off}>\{e(label)}</button>"
}

///|
fn caption(text : String) -> String {
  "<span class=\"caption\">\{e(text)}</span>"
}

///|
let menus : Array[(String, Array[(String, String)])] = [
  (
    "Readit",
    [
      ("help", "キーボードショートカット"),
      ("-", ""),
      ("quit", "Readitを終了"),
    ],
  ),
  (
    "ファイル",
    [
      ("new", "新規ファイル"),
      ("folder", "新規フォルダ"),
      ("open", "ファイルを開く…"),
      ("open-folder", "フォルダを開く…"),
      ("-", ""),
      ("save", "保存"),
      ("save-all", "すべて保存"),
      ("save-as", "名前を付けて保存…"),
      ("rename", "名前を変更…"),
      ("delete", "ファイルを削除…"),
      ("restore", "削除したファイルを復元"),
      ("-", ""),
      ("close", "タブを閉じる"),
      ("close-all", "すべてのタブを閉じる"),
      ("reopen", "閉じたタブを開く"),
      ("reload", "再読込…"),
      ("reveal", "Finderで表示"),
    ],
  ),
  (
    "編集",
    [
      ("undo", "元に戻す"),
      ("redo", "やり直す"),
      ("-", ""),
      ("cut", "切り取り"),
      ("copy", "コピー"),
      ("paste", "貼り付け"),
      ("select-all", "すべて選択"),
      ("-", ""),
      ("find", "検索"),
      ("replace", "置換…"),
    ],
  ),
  (
    "表示",
    [
      ("sidebar", "エクスプローラー"),
      ("wrap", "折返し"),
      ("compare", "差分比較"),
      ("zoom-in", "拡大"),
      ("zoom-out", "縮小"),
      ("reset-zoom", "倍率を戻す"),
    ],
  ),
  (
    "移動",
    [
      ("definition", "定義へ移動"),
      ("peek-definition", "定義を確認…"),
      ("type-definition", "型定義へ移動"),
      ("implementation", "実装へ移動"),
      ("references", "使用箇所を検索…"),
      ("symbols", "ファイル内のシンボル…"),
      ("hover", "型とドキュメント"),
      ("-", ""),
      ("quick-open", "ファイルへ移動…"),
      ("goto", "行へ移動…"),
      ("find-all", "プロジェクト内を検索…"),
      ("next-tab", "次のタブ"),
      ("previous-tab", "前のタブ"),
      ("back", "戻る"),
      ("forward", "進む"),
      ("commands", "コマンドパレット…"),
    ],
  ),
]

///|
fn shortcut_of(command : String) -> String {
  for c in commands {
    if c.0 == command {
      return c.2
    }
  }
  match command {
    "undo" => "⌘Z"
    "redo" => "⇧⌘Z"
    "cut" => "⌘X"
    "copy" => "⌘C"
    "paste" => "⌘V"
    "select-all" => "⌘A"
    "quick-open" => "⌘P"
    "commands" => "⇧⌘P"
    _ => ""
  }
}

///|
fn render_topbar() -> String {
  let out = StringBuilder()
  out.write_string(
    "<button class=\"btn mobile-only\" data-act=\"sidebar\" aria-label=\"ファイルツリー\" aria-expanded=\"false\">☰</button>",
  )
  out.write_string("<div class=\"menubar\">")
  for m in menus {
    let (name, _) = m
    let open = if reader.menu == Some(name) { " open" } else { "" }
    out.write_string(
      "<button class=\"menu-title\{open}\" data-act=\"menu\" data-arg=\"\{e(name)}\">\{e(name)}</button>",
    )
  }
  out.write_string("</div>")
  out.write_string(
    "<div class=\"brand\"><span class=\"logo\">readit</span>\{if reader.label == "" { "" } else { "<span class=\"label\">\{e(reader.label)}</span>" }}\{caption(reader.workspace.name())}</div>",
  )
  out.write_string("<div class=\"top-actions\">")
  if reader.tour is Some(t) && t.overview is Some(_) {
    out.write_string(button("overview", "概観に戻る"))
  }
  out.write_string(
    button(
      "quick-open",
      if narrow_layout() {
        "開く"
      } else {
        "ファイルを開く…  ⌘P"
      },
    ),
  )
  out.write_string(button("open-folder", "フォルダを開く"))
  out.write_string("</div>")
  out.to_string()
}

///|
fn render_menu() -> String {
  guard reader.menu is Some(name) else { return "" }
  let mut index = 0
  for i, m in menus {
    if m.0 == name {
      index = i
    }
  }
  let (_, items) = menus[index]
  let out = StringBuilder()
  out.write_string(
    "<div class=\"menu-list\" style=\"left:\{px(12.0 + index.to_double() * 62.0)}\">",
  )
  for item in items {
    let (command, label) = item
    if command == "-" {
      out.write_string("<div class=\"menu-sep\"></div>")
    } else {
      out.write_string(
        "<div class=\"menu-item\" data-act=\"run\" data-arg=\"\{command}\"><span>\{e(label)}</span>\{caption(shortcut_of(command))}</div>",
      )
    }
  }
  out.write_string("</div>")
  out.to_string()
}

///|
fn tree_entries() -> Array[@core.TreeEntry] {
  @core.tree_entries(reader.workspace.listed, reader.expanded)
}

///|
fn tree_row_height() -> Double {
  if narrow_layout() {
    44.0
  } else {
    29.0
  }
}

///|
fn render_tree() -> String {
  let entries = tree_entries()
  let top = js_scroll_top("tree-scroll")
  let height = js_client_height("tree-scroll").max(600.0)
  let first = ((top / tree_row_height()).floor().to_int() - 10).clamp(
    min=0,
    max=entries.length(),
  )
  let last = ((top + height) / tree_row_height()).ceil().to_int() + 10
  let last = last.clamp(min=first, max=entries.length())
  let out = StringBuilder()
  out.write_string(
    "<div class=\"tree-rows\" style=\"height:\{px(entries.length().to_double() * tree_row_height())}\">",
  )
  for i in first..<last {
    let entry = entries[i]
    let folder = entry.folder
    let active = reader.tree_target == Some(entry.path)
    let badge = if is_dirty(entry.path) {
      "●"
    } else if (match reader.workspace.document(entry.path) {
        Some(d) => d.changed()
        None => reader.workspace.changed.contains(entry.path)
      }) {
      "M"
    } else {
      ""
    }
    let icon = if folder {
      if reader.expanded.contains(entry.path) {
        "⌄"
      } else {
        "›"
      }
    } else {
      match @core.language(entry.path) {
        "python" => "py"
        "rust" => "rs"
        "typescript" => "ts"
        "javascript" => "js"
        _ => "≡"
      }
    }
    out.write_string(
      "<div class=\"tree-row\{if active { " active" } else { "" }}\" data-act=\"tree\" data-arg=\"\{e(entry.path)}\" data-tree=\"\{e(entry.path)}\" title=\"\{e(reader.workspace.absolute(entry.path))}\" style=\"top:\{px(i.to_double() * tree_row_height())};padding-left:\{px(14.0 + entry.depth.to_double() * 14.0)}\"><span class=\"tree-icon\">\{icon}</span><span class=\"tree-name\">\{e(entry.name)}</span><span class=\"badge\">\{badge}</span></div>",
    )
  }
  out.write_string("</div>")
  out.to_string()
}

///|
fn render_sidebar_head() -> String {
  "<div class=\"explorer-head\">\{caption("EXPLORER")}<div class=\"row-buttons\">\{button("sidebar", "閉じる", extra=" mobile-only")}</div></div><div class=\"explorer-root\">⌄  \{e(@core.lower(reader.workspace.name()) |> upper)}</div>"
}

///|
fn upper(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    let code = c.to_int()
    out.write_char(
      if code >= 'a'.to_int() && code <= 'z'.to_int() {
        Int::unsafe_to_char(code - 32)
      } else {
        c
      },
    )
  }
  out.to_string()
}

///|
fn render_tabs() -> String {
  let out = StringBuilder()
  if reader.overview_tab {
    out.write_string(
      "<div class=\"tab\{if reader.overview_visible { " selected" } else { "" }}\"\{if reader.overview_visible { " id=\"tab-selected\"" } else { "" }} data-act=\"overview\"><span>概観</span><span class=\"tab-close\" data-act=\"close-overview\">×</span></div>",
    )
  }
  for tab in reader.tabs {
    let selected = !reader.overview_visible && reader.selected == Some(tab)
    out.write_string(
      "<div class=\"tab\{if selected { " selected" } else { "" }}\"\{if selected { " id=\"tab-selected\"" } else { "" }} data-act=\"open-tab\" data-arg=\"\{e(tab)}\" data-tab=\"\{e(tab)}\" title=\"\{e(reader.workspace.absolute(tab))}\"><span>\{e(@core.base_name(tab))}</span><span class=\"dirty\">\{if is_dirty(tab) { "●" } else { "" }}</span><span class=\"tab-close\" data-act=\"close-tab\" data-arg=\"\{e(tab)}\">×</span></div>",
    )
  }
  out.to_string()
}

///|
fn render_pathbar() -> String {
  let path = reader.selected.unwrap_or("")
  let label = if path == "" {
    "ファイルを選択してください"
  } else {
    path
  }
  let actions = if path == "" {
    ""
  } else {
    button("compare", if reader.compare { "編集に戻る" } else { "差分" })
  }
  "<div class=\"full-path\">\{caption(label)}</div><div class=\"row-buttons\">\{actions}</div>"
}

///|
fn render_navbar() -> String {
  let path = reader.selected.unwrap_or("")
  let external = if reader.external.contains(path) {
    caption("外部定義 · 閲覧専用")
  } else {
    ""
  }
  button("back", "←") +
  button("forward", "→") +
  button("definition", if narrow_layout() { "定義" } else { "定義 F12" }) +
  button(
    "references",
    if narrow_layout() {
      "使用箇所"
    } else {
      "使用箇所 ⇧F12"
    },
  ) +
  button(
    "symbols",
    if narrow_layout() {
      "シンボル"
    } else {
      "シンボル ⇧⌘O"
    },
  ) +
  button("pin-code", if narrow_layout() { "固定" } else { "横に固定" }) +
  button("hover", if narrow_layout() { "説明" } else { "型・説明" }) +
  external
}

///|
fn render_search_bar() -> String {
  if !reader.search_open || reader.compare || reader.overview_visible {
    return ""
  }
  let count = reader.search_matches.length()
  let status = if reader.search_error != "" {
    "正規表現エラー"
  } else if reader.search_query == "" {
    ""
  } else if count == 0 {
    "一致なし"
  } else {
    "\{reader.search_index + 1} / \{count}"
  }
  "<span class=\"caption\">\{e(status)}</span>\{button("search-case", "Aa", extra=if reader.search_case { " on" } else { "" })}\{button("search-regex", ".*", extra=if reader.search_regex { " on" } else { "" })}\{button("search-prev", "↑")}\{button("search-next", "↓")}\{button("search-close", "×")}"
}

///|
fn render_diff() -> String {
  let out = StringBuilder()
  out.write_string(
    "<div class=\"diff\" style=\"font-size:\{px(reader.font_size)}\">",
  )
  for row in reader.diff_rows {
    let (cls, mark) = match row.kind {
      Added => ("added", "+")
      Removed => ("removed", "−")
      Context => ("", " ")
    }
    let number = (n : Int?) => {
      match n {
        Some(i) => (i + 1).to_string()
        None => ""
      }
    }
    let pad = (s : String) => " ".repeat((4 - s.length()).max(0)) + s
    let act = match row.new {
      Some(line) => " data-act=\"diff-line\" data-arg=\"\{line}\""
      None => ""
    }
    out.write_string(
      "<div class=\"diff-row \{cls}\"\{act}><span class=\"diff-num\">\{pad(number(row.old))} \{pad(number(row.new))} \{mark}</span><span class=\"diff-text\">\{e(row.text)}</span></div>",
    )
  }
  out.write_string("</div>")
  out.to_string()
}

///|
fn render_empty() -> String {
  "<div class=\"empty\"><div class=\"empty-title\">Readit</div>\{caption("⌘P ファイルを開く   ·   ⌘N 新規ファイル   ·   ⌘O ファイルを選択")}</div>"
}

///|
fn render_overview() -> String {
  guard reader.tour is Some(tour) && tour.overview is Some(overview) else {
    return ""
  }
  let stale = guide_steps_stale(tour)
  let out = StringBuilder()
  out.write_string("<div class=\"overview\">")
  out.write_string(caption("全体像 → 章の概要 → 実際のコード"))
  out.write_string(
    "<h1>\{e(overview.title)}</h1><p class=\"summary\">\{e(overview.summary)}</p>",
  )
  if stale {
    out.write_string(
      "<div class=\"stale\">コードに変更があります。外部AIに概観とガイドの更新を依頼してください。</div>",
    )
  }
  out.write_string(
    "<div class=\"card\"><b>構成と処理の流れ</b><div class=\"relations\">\{e(overview.relationships)}</div></div><b>読む章</b>",
  )
  for i, chapter in overview.chapters {
    let (start, end) = chapter_bounds(tour, overview, i)
    let mut seen = 0
    for j in start..<end {
      if tour.seen.contains(tour.steps[j].id) {
        seen += 1
      }
    }
    let current = tour.index >= start &&
      tour.index < end &&
      tour.seen.length() > 0
    let number = if i + 1 < 10 { "0\{i + 1}" } else { (i + 1).to_string() }
    out.write_string(
      "<div class=\"card chapter\{if current { " current" } else { "" }}\"><div class=\"chapter-head\"><b>\{number}  \{e(chapter.title)}</b>\{caption("\{seen} / \{end - start} 箇所を表示済み\{if current { " · 現在の章" } else { "" }}")}</div><div>\{e(chapter.summary)}</div>",
    )
    let labels = []
    for j in start..<end {
      let label = tour.steps[j].path
      if !labels.contains(label) {
        labels.push(label)
      }
    }
    @core.sort_strings(labels)
    for label in labels {
      out.write_string("<div class=\"file-label\">\{e(label)}</div>")
    }
    if !stale {
      out.write_string(
        button("chapter", "コードを読む →", arg=i.to_string()),
      )
    }
    out.write_string("</div>")
  }
  if overview.claims is Some(claims) && claims.length() > 0 {
    out.write_string("<b>今回の重要なポイント</b>")
    let mut k = 0
    for claim in claims {
      let (badge, label) = if claim.confidence == "source_confirmed" {
        ("confirmed", "コード上で確認")
      } else {
        ("inferred", "推論")
      }
      out.write_string(
        "<div class=\"card claim\"><span class=\"badge \{badge}\">\{label}</span><div>\{e(claim.statement)}</div>\{caption("根拠")}",
      )
      for ev in claim.evidence {
        let line = @core.position_at(ev.source, ev.start).line + 1
        let changed = if evidence_stale(ev) { " · 変更あり" } else { "" }
        out.write_string(
          "<button class=\"evidence\" data-act=\"evidence\" data-arg=\"\{k}\">→ \{e(ev.path)}:\{line}  \{e(ev.label)}\{changed}</button>",
        )
        k += 1
      }
      out.write_string("</div>")
    }
  }
  if overview.reader_context is Some(context) &&
    (context.known.length() > 0 || context.focus.length() > 0) {
    let open = reader.context_open
    out.write_string(
      "<div class=\"card context\"><button class=\"context-toggle\" data-act=\"toggle-context\">\{if open { "▾" } else { "▸" }} 今回の前提</button>",
    )
    if open {
      out.write_string(
        caption(
          "この解説が前提にしたことと、今回の焦点です。違っていればAIに伝えてください。",
        ),
      )
      for
        section in [
          ("知っている前提", context.known),
          ("今回見るもの", context.focus),
        ] {
        let (title, items) = section
        if items.length() > 0 {
          out.write_string("<b>\{title}</b><ul>")
          for item in items {
            out.write_string("<li>\{e(item)}</li>")
          }
          out.write_string("</ul>")
        }
      }
    }
    out.write_string("</div>")
  }
  out.write_string(
    caption(
      "解説は外部AIが事前に作成します。章の移動は待機なしで利用できます。",
    ),
  )
  out.write_string("</div>")
  out.to_string()
}

///|
fn render_pinned_head() -> String {
  guard reader.pinned is Some(p) else { return "" }
  let full = if @core.starts_with(p.path, "/") {
    p.path
  } else {
    p.root + "/" + p.path
  }
  "<div class=\"pinned-title\">\{caption("固定したコード · 閲覧専用")}\{button("unpin-code", "×")}</div><div class=\"pinned-path\">\{caption(full)}</div><div class=\"pinned-state\">\{caption(if pinned_changed() { "本文に変更あり · 固定時の内容を表示中" } else { "固定時の内容を表示中" })}\{button("refresh-pinned", "更新")}</div>"
}

///|
fn render_navpanel() -> String {
  let out = StringBuilder()
  let count = if reader.nav_busy {
    "解析中…"
  } else {
    "\{reader.nav_targets.length()}件"
  }
  out.write_string(
    "<div class=\"nav-head\"><div class=\"row-buttons\"><span>\{e(reader.nav_title)}</span>\{caption(count)}</div><div class=\"row-buttons\">\{button("navigation", "一覧・絞り込み")}\{button("close-nav", "×")}</div></div><div class=\"nav-results\" id=\"nav-results\">",
  )
  if reader.nav_targets.length() == 0 {
    out.write_string(
      "<div class=\"nav-info\">\{e(reader.nav_information)}</div>",
    )
  }
  for i, t in reader.nav_targets {
    let label = if t.name == "" {
      "\{target_path(t)}:\{t.line + 1}:\{t.character + 1}"
    } else {
      "\{t.name} · \{target_path(t)}:\{t.line + 1}"
    }
    out.write_string(
      "<div class=\"nav-result\" data-act=\"jump\" data-arg=\"\{i}\"><div class=\"nav-label\">\{e(label)}</div>\{caption(t.detail)}</div>",
    )
  }
  out.write_string("</div>")
  out.to_string()
}

///|
fn render_status() -> String {
  let path = reader.selected.unwrap_or("")
  let p = cursor_position()
  let control = if reader.superseded {
    " · 別のタブで開かれています"
  } else if reader.control_socket != "" && reader.connected {
    " · MCP接続待受中"
  } else {
    ""
  }
  let message = match reader.loading {
    Some(path) => "\{path} を読み込んでいます…"
    None => reader.message
  }
  let detail = if narrow_layout() {
    "\{p.line + 1}:\{p.character + 1} · \{@core.language(path)}\{control}"
  } else {
    "Ln \{p.line + 1}, Col \{p.character + 1}  ·  \{@core.language(path)}  ·  UTF-8  ·  \{if reader.wrap { "Wrap" } else { "No wrap" }}\{control}"
  }
  "\{caption(if narrow_layout() && message == default_status { "" } else { message })}\{caption(detail)}"
}

///|
fn dialog_title(dialog : Dialog) -> String {
  let title = match dialog {
    Quick => "ファイルを開く · ⌘P"
    Commands => "コマンドパレット · ⇧⌘P"
    WorkspaceSearch => "プロジェクト内検索 · 最大200件"
    Goto => "行へ移動 · 行番号 または 行:列"
    NewFolder => "新規フォルダ · プロジェクト内の相対パス"
    Rename => "名前を変更 · プロジェクト内の相対パス"
    SaveAs => "名前を付けて保存 · プロジェクト内の相対パス"
    Replace => "ファイル内置換 · 文字列の完全一致"
    Help => "キーボードショートカット"
    Navigation => reader.nav_title
    Information => "型とドキュメント"
    OpenFolder => "フォルダを開く · 絶対パス"
  }
  if dialog == SaveAs {
    "\{reader.save_source.unwrap_or("")} · \{title}"
  } else {
    title
  }
}

///|
fn is_picker(dialog : Dialog) -> Bool {
  match dialog {
    Quick | Commands | WorkspaceSearch | Navigation => true
    _ => false
  }
}

///|
/// The part of the dialog that must survive typing: title and inputs.
fn render_dialog_shell() -> String {
  guard reader.dialog is Some(dialog) else { return "" }
  let input = match dialog {
    Help | Information => ""
    _ =>
      "<input id=\"dialog-query\" class=\"input\" placeholder=\"入力…\" autocomplete=\"off\" spellcheck=\"false\">"
  }
  let replacement = if dialog == Replace {
    "<input id=\"dialog-replacement\" class=\"input\" placeholder=\"置換後の文字列\" autocomplete=\"off\" spellcheck=\"false\">"
  } else {
    ""
  }
  let close = if narrow_layout() {
    button("cancel-dialog", "閉じる")
  } else {
    caption("Esc 閉じる")
  }
  "<div class=\"dialog-title\"><span>\{e(dialog_title(dialog))}</span>\{close}</div><div class=\"dialog-inputs\">\{input}\{replacement}</div>"
}

///|
fn render_dialog_body() -> String {
  if reader.pending is Some(pending) {
    let deletion = pending is Delete(_)
    let paths = match pending {
      Delete(p) => p
      _ => affected(pending).join("\n")
    }
    return "<div class=\"confirm\"><div>\{if deletion { "選択した項目を削除しますか？" } else { "変更を保存しますか？" }}</div><pre class=\"caption\">\{e(paths)}</pre>\{caption(if deletion { "フォルダの場合は中身も移動します。削除した項目は.readit/trashに保管され、メニューから復元できます。" } else { "保存しない場合、この操作の対象となる未保存の変更を破棄します。" })}<div class=\"row-buttons\">\{button("confirm-save", if deletion { "保存して削除" } else { "保存" })}\{button("confirm-discard", if deletion { "保存せず削除" } else { "保存しない" })}\{button("confirm-cancel", "キャンセル")}</div></div>"
  }
  guard reader.dialog is Some(dialog) else { return "" }
  let out = StringBuilder()
  if is_picker(dialog) {
    let list = picks()
    out.write_string(
      "<div class=\"picks\" id=\"picks\" style=\"max-height:\{if dialog == Navigation { "230px" } else { "390px" }}\">",
    )
    if list.length() == 0 {
      out.write_string(
        "<div class=\"pick\">\{caption("一致する項目がありません")}</div>",
      )
    }
    for i, pick in list {
      out.write_string(
        "<div class=\"pick\{if i == reader.pick_index { " selected" } else { "" }}\" data-act=\"pick\" data-arg=\"\{i}\" id=\"pick-\{i}\"><div class=\"pick-label\">\{e(pick.label)}</div>\{caption(pick.detail)}</div>",
      )
    }
    out.write_string("</div>")
    if dialog == Navigation {
      match list.get(reader.pick_index) {
        Some({ target: Some(index), .. }) =>
          if reader.nav_targets.get(index) is Some(target) {
            out.write_string(
              "<div class=\"definition-preview\">\{caption("プレビュー · Enterで移動 · ⌃−で戻る")}<pre>\{e(target.preview)}</pre></div>",
            )
          }
        _ => ()
      }
    }
  }
  match dialog {
    Information => {
      out.write_string("<div class=\"type-information\">")
      for line in @core.split_newlines(reader.nav_information) {
        out.write_string("<div>\{if line == "" { " " } else { e(line) }}</div>")
      }
      out.write_string("</div>")
    }
    Replace =>
      out.write_string(
        "<div class=\"row-buttons pad\">\{button("replace-next", "次を置換")}\{button("replace-all", "すべて置換")}</div>",
      )
    Help => {
      out.write_string("<div class=\"help-list\">")
      for c in commands {
        out.write_string(
          "<div class=\"help-row\"><span>\{e(c.1)}</span>\{caption(c.2)}</div>",
        )
      }
      out.write_string(
        caption(
          "本文: ⌘Z / ⇧⌘Z Undo/Redo · ⌘C/X/V · Tab/⇧Tab インデント · ⌥←/→ 単語移動 · ⇧矢印 範囲選択 · ブラウザが使うキーは⌃の代替キーで操作できます",
        ),
      )
      out.write_string("</div>")
    }
    Goto | NewFolder | Rename | SaveAs | OpenFolder =>
      out.write_string(
        "<div class=\"row-buttons pad\">\{button("accept-dialog", "確定")}\{button("cancel-dialog", "キャンセル")}</div>",
      )
    _ => ()
  }
  out.write_string(
    "<div class=\"dialog-message\">\{caption(if narrow_layout() && reader.message == default_status { "" } else { reader.message })}</div>",
  )
  out.to_string()
}

///|
fn render_context_menu() -> String {
  guard reader.context_menu is Some(menu) else { return "" }
  let items = [
    ("new", "新規ファイル"),
    ("folder", "新規フォルダ"),
    ("-", ""),
    ("rename", "名前を変更…"),
    ("delete", "削除…"),
  ]
  let out = StringBuilder()
  out.write_string(
    "<div class=\"menu-list\" style=\"left:\{px(menu.x)};top:\{px(menu.y)}\">",
  )
  for item in items {
    if item.0 == "-" {
      out.write_string("<div class=\"menu-sep\"></div>")
    } else {
      out.write_string(
        "<div class=\"menu-item\" data-act=\"run\" data-arg=\"\{item.0}\"><span>\{e(item.1)}</span></div>",
      )
    }
  }
  out.write_string("</div>")
  out.to_string()
}
