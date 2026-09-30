// Language server navigation: definitions, references, hover previews, pinning.

///|
fn target_path(t : Target) -> String {
  let root = reader.workspace.root + "/"
  if @core.starts_with(t.path, root) {
    @core.slice(t.path, root.length(), t.path.length())
  } else {
    t.path
  }
}

///|
fn snapshot_at(path : String, line : Int, character : Int) -> Snapshot {
  let documents = reader.workspace.documents
    .filter(d => !reader.untitled.contains(d.path))
    .map(d => (reader.workspace.absolute(d.path), d.text()))
  {
    root: reader.workspace.root,
    path: reader.workspace.absolute(path),
    line,
    character,
    documents,
  }
}

///|
/// Every text the snapshot saw is unchanged, in the same project.
fn snapshot_current(s : Snapshot) -> Bool {
  if reader.workspace.root != s.root {
    return false
  }
  for pair in s.documents {
    let (path, text) = pair
    let mut found = false
    for d in reader.workspace.documents {
      if reader.workspace.absolute(d.path) == path {
        found = d.text() == text
        break
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
fn snapshot_json(query : @lsp.Query, s : Snapshot) -> Json {
  {
    "root": s.root,
    "query": query.name(),
    "path": s.path,
    "line": s.line,
    "character": s.character,
    "documents": Json::array(
      s.documents.map(pair => {
        Json::array([Json::string(pair.0), Json::string(pair.1)])
      }),
    ),
  }
}

///|
fn parse_answer(value : Json) -> (Array[Target], String, String) {
  match value {
    {
      "targets": Array(items),
      "information": String(info),
      "server": String(server),
      ..
    } => (items.filter_map(Target::parse), info, server)
    _ => ([], "", "")
  }
}

///|
fn analyze(query : @lsp.Query, jump : Bool, at : @core.Position?) -> Unit {
  clear_pointer()
  if reader.nav_busy {
    say(
      "解析中です。結果パネルの×で表示をキャンセルできます",
    )
    return
  }
  guard reader.selected is Some(path) else { return }
  if reader.untitled.contains(path) {
    say(
      "言語を判定するため、先に拡張子を付けて保存してください",
    )
    return
  }
  guard current_editor() is Some(editor) else { return }
  let position = match at {
    Some(p) => p
    None => editor.position()
  }
  let snapshot = snapshot_at(path, position.line, position.character)
  reader.nav_serial += 1
  let serial = reader.nav_serial
  reader.nav_busy = true
  reader.nav_visible = true
  reader.nav_targets = []
  reader.nav_snapshot = None
  reader.nav_title = "\{query.title()} · \{path}:\{position.line + 1}"
  reader.nav_information = "言語サーバーで解析しています…（初回は起動に少し時間がかかります）"
  if query == Symbols {
    show(Navigation, "")
  }
  say(reader.nav_information)
  rpc("lsp.query", snapshot_json(query, snapshot), result => {
    if serial != reader.nav_serial {
      return
    }
    reader.nav_busy = false
    if !snapshot_current(snapshot) ||
      reader.selected.map(p => reader.workspace.absolute(p)) !=
      Some(snapshot.path) {
      reader.nav_information = "解析中にコードまたは表示ファイルが変わったため、結果を破棄しました。再度実行してください"
      say(reader.nav_information)
      return
    }
    match result {
      Err(e) => {
        reader.nav_information = e
        say(e)
      }
      Ok(value) => {
        let (targets, information, server) = parse_answer(value)
        reader.nav_targets = targets
        reader.nav_snapshot = Some(snapshot)
        reader.nav_information = if query == Hover {
          if information == "" {
            "この位置には型・説明情報がありません"
          } else {
            information
          }
        } else if targets.length() == 0 {
          "\{query.title()}が見つかりませんでした · \{server}"
        } else {
          "\{targets.length()}件 · \{server} · 未保存の編集を含む解析結果（使用箇所は宣言を含む）"
        }
        say(
          if query == Hover {
            "型・ドキュメントを取得しました · \{server}"
          } else {
            reader.nav_information
          },
        )
        if query == Hover {
          show(Information, "")
        } else if jump && targets.length() == 1 {
          jump_target(0)
        } else if query != Symbols && targets.length() > 0 {
          show(Navigation, "")
        }
      }
    }
  })
}

///|
fn jump_target(index : Int) -> Unit {
  if reader.nav_snapshot is Some(s) && !snapshot_current(s) {
    say(
      "コードが変わっています。定義・使用箇所を再解析してください",
    )
    return
  }
  guard reader.nav_targets.get(index) is Some(target) else { return }
  rpc("file.external", { "root": reader.workspace.root, "path": target.path }, result => {
    match result {
      Err(e) => say(e)
      Ok({ "relative": String(relative), .. }) =>
        ensure(relative, loaded => {
          match loaded {
            Err(e) => say(e)
            Ok(_) => finish_jump(relative, target)
          }
        })
      Ok({ "path": String(path), "text": String(text), .. }) => {
        if reader.workspace.index_of(path) is None {
          reader.workspace.documents.push(new_document(path, text, Some(text)))
        }
        reader.external[path] = ()
        finish_jump(path, target)
      }
      Ok(_) => say("定義ファイルを開けません")
    }
  })
}

///|
fn finish_jump(key : String, target : Target) -> Unit {
  reader.dialog = None
  open(key, None, true, then=() => {
    if current_editor() is Some(e) {
      let at = @core.offset_of(e.text, {
        line: target.line,
        character: target.character,
      })
      e.set_cursor(at)
      request_reveal(e.line_of(at), 2)
      focus_editor()
      if reader.history.get(reader.history_index) is Some(last) {
        let p = e.position()
        last.line = p.line
        last.column = p.character
      }
    }
    say(
      "\{target_path(target)}:\{target.line + 1}:\{target.character + 1} · ⌃−で元の場所へ戻る",
    )
  })
}

///|
fn clear_pointer() -> Unit {
  if reader.pointer is Some(_) || reader.pointer_timer is Some(_) {
    reader.pointer_serial += 1
    if reader.pointer_timer is Some(t) {
      cancel_timer(t)
    }
    reader.pointer_timer = None
    reader.pointer = None
    reader.popup = None
  }
}

///|
/// The mouse is over a symbol glyph of the main editor at (line, column).
fn update_pointer(
  line : Int,
  column : Int,
  x : Double,
  y : Double,
  definition : Bool,
) -> Unit {
  if reader.popup is Some(p) && p.contains(x, y) {
    return
  }
  if reader.compare ||
    reader.dialog is Some(_) ||
    reader.pending is Some(_) ||
    reader.nav_busy ||
    reader.overview_visible {
    clear_pointer()
    return
  }
  guard reader.selected is Some(path) &&
    !reader.untitled.contains(path) &&
    @core.language_id(path) is Some(_) else {
    clear_pointer()
    return
  }
  guard current_editor() is Some(editor) && column >= 0 else {
    clear_pointer()
    return
  }
  let offset = editor.offset_at(line, column)
  guard @core.symbol_range(editor.text, offset) is Some((start, end)) else {
    clear_pointer()
    return
  }
  let line_start = editor.line_start(line)
  let rect = match
    Rect::parse(
      js_range_rect("editor", line, start - line_start, end - line_start),
    ) {
    Some(r) => r
    None => {
      clear_pointer()
      return
    }
  }
  if reader.pointer is Some(p) &&
    p.path == path &&
    p.start == start &&
    p.end == end &&
    p.definition == definition &&
    p.rect == rect {
    return
  }
  clear_pointer()
  let position = @core.position_at(editor.text, offset)
  let snapshot = snapshot_at(path, position.line, position.character)
  reader.pointer_serial += 1
  let serial = reader.pointer_serial
  reader.pointer = Some({
    path,
    start,
    end,
    rect,
    definition,
    targets: [],
    information: "",
    snapshot,
  })
  reader.pointer_timer = Some(
    after(250, () => {
      reader.pointer_timer = None
      if reader.pointer_serial != serial {
        return
      }
      let finish = (targets : Array[Target]) => {
        rpc("lsp.query", snapshot_json(Hover, snapshot), hover => {
          if reader.pointer_serial != serial {
            return
          }
          let information = match hover {
            Ok(value) => parse_answer(value).1
            Err(_) => ""
          }
          if !snapshot_current(snapshot) ||
            reader.selected.map(p => reader.workspace.absolute(p)) !=
            Some(snapshot.path) ||
            reader.compare ||
            reader.dialog is Some(_) ||
            reader.pending is Some(_) {
            clear_pointer()
            return
          }
          if reader.pointer is Some(p) {
            p.targets = targets
            p.information = information
          }
        })
      }
      if definition {
        rpc("lsp.query", snapshot_json(Definition, snapshot), answer => {
          if reader.pointer_serial != serial {
            return
          }
          let targets = match answer {
            Ok(value) => parse_answer(value).0
            Err(_) => []
          }
          finish(targets)
        })
      } else {
        finish([])
      }
    }),
  )
}

///|
fn jump_pointer() -> Unit {
  guard reader.pointer is Some(preview) else { return }
  clear_pointer()
  if !snapshot_current(preview.snapshot) {
    return
  }
  reader.nav_targets = preview.targets
  reader.nav_snapshot = Some(preview.snapshot)
  reader.nav_title = "定義"
  if reader.nav_targets.length() == 1 {
    jump_target(0)
  } else if reader.nav_targets.length() > 0 {
    show(Navigation, "")
  }
}

///|
/// Command palette: open the ⌘ hover preview at the cursor.
fn definition_hover_here() -> Unit {
  guard current_editor() is Some(editor) else { return }
  guard @core.symbol_range(editor.text, editor.head) is Some(_) else { return }
  reader.dialog = None
  focus_editor()
  let p = editor.position()
  match
    Rect::parse(js_range_rect("editor", p.line, p.character, p.character + 1)) {
    Some(r) =>
      update_pointer(p.line, p.character, r.left + 1.0, r.top + 1.0, true)
    None => ()
  }
}

///|
/// Current text of a path: loaded buffers first, then the cache of disk reads.
fn known_text(path : String) -> String? {
  match reader.workspace.document(path) {
    Some(d) => Some(d.text())
    None =>
      match reader.disk_cache.get(path) {
        Some(value) => value
        None => None
      }
  }
}

///|
/// Refresh the disk cache for paths that are not loaded, then continue.
fn load_texts(paths : Array[String], done : () -> Unit) -> Unit {
  let missing = []
  for p in paths {
    if reader.workspace.index_of(p) is None && !missing.contains(p) {
      missing.push(p)
    }
  }
  if missing.length() == 0 {
    done()
    return
  }
  let root = reader.workspace.root
  rpc(
    "file.disk_many",
    { "root": root, "paths": Json::array(missing.map(Json::string)) },
    result => {
      if reader.workspace.root == root {
        match result {
          Ok(Object(values)) =>
            for p in missing {
              reader.disk_cache[p] = match values.get(p) {
                Some(String(t)) => Some(t)
                _ => None
              }
            }
          _ =>
            for p in missing {
              reader.disk_cache[p] = None
            }
        }
      }
      done()
    },
  )
}

///|
fn pin_code(path : String, line : Int) -> Result[Unit, String] {
  guard known_text(path) is Some(source) else {
    return Err("external definition is not a supported text file")
  }
  let _ = @core.offset_at(source, line, 1) catch {
    Failure(m) => return Err(@core.failure_text(m))
  }
  let editor = @editor.Editor::new(source)
  editor.set_read_only(true)
  editor.set_cursor(editor.line_start(line - 1))
  reader.pinned = Some({
    root: reader.workspace.root,
    path,
    source,
    line,
    editor,
    scroll_top: -1.0,
  })
  Ok(())
}

///|
fn pin_current() -> Unit {
  guard reader.selected is Some(path) else { return }
  if pin_code(path, cursor_position().line + 1) is Err(e) {
    say(e)
  }
}

///|
fn pinned_changed() -> Bool {
  match reader.pinned {
    Some(p) =>
      match known_text(p.path) {
        Some(text) => text != p.source
        None => true
      }
    None => false
  }
}
