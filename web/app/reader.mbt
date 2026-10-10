// Opening, saving, closing and navigating files.

///|
fn current() -> Document? {
  match reader.selected {
    Some(path) => reader.workspace.document(path)
    None => None
  }
}

///|
fn current_editor() -> @editor.Editor? {
  match current() {
    Some(d) => Some(d.editor)
    None => None
  }
}

///|
fn is_dirty(path : String) -> Bool {
  reader.untitled.contains(path) ||
  (match reader.workspace.document(path) {
    Some(d) => d.dirty()
    None => false
  })
}

///|
fn cursor_position() -> @core.Position {
  match current_editor() {
    Some(e) => e.position()
    None => { line: 0, character: 0, }
  }
}

///|
fn say(message : String) -> Unit {
  reader.message = message
}

///|
fn rebuild_diff() -> Unit {
  reader.diff_rows = match current() {
    Some(d) => @core.diff_rows(d.before.unwrap_or(""), d.text(), true)
    None => []
  }
}

///|
fn new_document(path : String, text : String, before : String?) -> Document {
  let editor = @editor.Editor::new(text)
  { path, disk: text, before, editor, scroll_top: 0.0, }
}

///|
/// Read a project file on first use. Calls `done` synchronously when loaded.
fn ensure(path : String, done : (Result[Unit, String]) -> Unit) -> Unit {
  if reader.workspace.index_of(path) is Some(_) {
    done(Ok(()))
    return
  }
  let root = reader.workspace.root
  reader.loading = Some(path)
  rpc("file.read", { "root": root, "path": path }, result => {
    reader.loading = None
    if reader.workspace.root != root {
      done(Err("プロジェクトが切り替わりました"))
      replay_deferred()
      return
    }
    match result {
      Err(e) => done(Err(e))
      Ok(value) => {
        let text = match value {
          Object(o) =>
            match o.get("text") {
              Some(String(t)) => t
              _ => ""
            }
          _ => ""
        }
        let before = match value {
          Object(o) =>
            match o.get("before") {
              Some(String(b)) => Some(b)
              _ => None
            }
          _ => None
        }
        if reader.workspace.index_of(path) is None {
          reader.workspace.documents.push(new_document(path, text, before))
        }
        reader.workspace.known_files[path] = ()
        done(Ok(()))
      }
    }
    replay_deferred()
  })
}

///|
/// Show a file, optionally at a line, and record it in history.
fn open(
  path : String,
  line : Int?,
  record : Bool,
  then? : () -> Unit = () => (),
) -> Unit {
  reader.overview_visible = false
  clear_pointer()
  ensure(path, result => {
    match result {
      Err(error) => {
        say("開けません: \{error}")
        return
      }
      Ok(_) => ()
    }
    if record && reader.selected is Some(active) {
      let pos = cursor_position()
      if reader.history.get(reader.history_index) is Some(last) &&
        last.path == active {
        last.line = pos.line
        last.column = pos.character
      }
    }
    if current() is Some(d) {
      d.scroll_top = js_scroll_top("editor-scroll")
    }
    if !reader.tabs.contains(path) {
      reader.tabs.push(path)
    }
    if !guide_opening.val && reader.tour_tabs.search(path) is Some(i) {
      // The reader chose this file; its tab now outlives the tour's steps.
      reader.tour_tabs.remove(i) |> ignore
    }
    reader.selected = Some(path)
    if narrow_layout() {
      reader.sidebar = false
    }
    reader.tree_target = Some(path)
    reveal_in_tree(path)
    reader.compare = false
    reader.search_key = ""
    guard reader.workspace.document(path) is Some(doc) else { return }
    doc.editor.set_read_only(reader.external.contains(path))
    match line {
      Some(l) => {
        let target = l.clamp(min=0, max=(doc.editor.line_count() - 1).max(0))
        doc.editor.set_cursor(doc.editor.line_start(target))
        request_reveal(target, 0)
      }
      None => restore_scroll(doc.scroll_top)
    }
    focus_document()
    if record {
      while reader.history.length() > reader.history_index + 1 {
        reader.history.pop() |> ignore
      }
      let pos = doc.editor.position()
      let same = match reader.history.last() {
        Some(last) => last.path == path && Some(last.line) == line
        None => false
      }
      if !same {
        reader.history.push({ path, line: pos.line, column: pos.character, })
      }
      reader.history_index = (reader.history.length() - 1).max(0)
    }
    then()
  })
}

///|
fn focus_editor() -> Unit {
  reader.focus = "editor"
}

///|
// Reading code or closing a dialog should not summon a phone keyboard.
fn focus_document() -> Unit {
  if narrow_layout() {
    reader.focus = "body"
  } else {
    focus_editor()
  }
}

///|
fn show(dialog : Dialog, initial : String) -> Unit {
  clear_pointer()
  reader.query = initial
  reader.dialog = Some(dialog)
  reader.pick_index = 0
  reader.menu = None
  reader.context_menu = None
  reader.focus = if dialog == Information || dialog == Help {
    "dialog"
  } else {
    "query"
  }
  reader.workspace_picks = []
  // The inputs appear with the next render; fill them then.
  pending_inputs.val = [
    ("dialog-query", initial),
    ("dialog-replacement", reader.replacement),
  ]
  if dialog == WorkspaceSearch && initial != "" {
    schedule_workspace_search()
  }
  if dialog == Quick {
    reader.quick_picks = []
    find_files()
  }
}

///|
let pending_inputs : Ref[Array[(String, String)]] = Ref([])

///|
fn dismiss() -> Unit {
  guide_response("end")
  clear_pointer()
  if reader.nav_busy {
    reader.nav_serial += 1
    reader.nav_busy = false
    reader.nav_information = "解析の表示をキャンセルしました"
  }
  reader.dialog = None
  reader.pending = None
  reader.save_source = None
  reader.saving_all = false
  reader.rename_source = None
  reader.menu = None
  reader.context_menu = None
  focus_document()
}

///|
fn new_file() -> Unit {
  let mut n = 1
  while reader.workspace.index_of("Untitled-\{n}") is Some(_) {
    n += 1
  }
  let path = "Untitled-\{n}"
  reader.workspace.documents.push(new_document(path, "", None))
  reader.untitled[path] = ()
  open(path, None, true, then=() => focus_editor())
}

///|
/// Save one file. `done(true)` when it was written.
fn save_path(path : String, done : (Bool) -> Unit) -> Unit {
  if reader.external.contains(path) {
    say(
      "外部定義は閲覧専用です。名前を付けて保存するとプロジェクト内にコピーできます",
    )
    done(false)
    return
  }
  if reader.untitled.contains(path) {
    reader.save_source = Some(path)
    show(SaveAs, "")
    done(false)
    return
  }
  guard reader.workspace.document(path) is Some(doc) else {
    done(false)
    return
  }
  let text = doc.text()
  rpc(
    "file.save",
    {
      "root": reader.workspace.root,
      "path": path,
      "disk": doc.disk,
      "text": text,
    },
    result => {
      match result {
        Ok(_) => {
          doc.disk = text
          say("保存しました · \{path}")
          done(true)
        }
        Err(error) => {
          say("保存できません: \{error}")
          done(false)
        }
      }
    },
  )
}

///|
fn save() -> Unit {
  if reader.selected is Some(path) {
    save_path(path, _ => ())
  }
}

///|
/// Save dirty tabs in order, stopping at the first failure or Save As prompt.
fn save_all() -> Unit {
  reader.saving_all = true
  let paths = reader.tabs.filter(is_dirty)
  fn step(i : Int) {
    if i >= paths.length() {
      reader.saving_all = false
      say("すべてのファイルを保存しました")
      return
    }
    save_path(paths[i], ok => if ok { step(i + 1) })
  }

  step(0)
}

///|
fn save_as() -> Unit {
  guard reader.selected is Some(path) else { return }
  reader.save_source = Some(path)
  show(SaveAs, if reader.untitled.contains(path) { "" } else { path })
}

///|
fn affected(pending : Pending) -> Array[String] {
  match pending {
    Close(p) => [p]
    Delete(p) =>
      reader.workspace.documents
      .filter(d => @core.within(d.path, p))
      .map(d => d.path)
    _ =>
      reader.workspace.documents.filter(d => is_dirty(d.path)).map(d => d.path)
  }
}

///|
/// Ask about unsaved changes (and always about deletion) before an action.
fn begin(pending : Pending) -> Unit {
  let confirm = pending is Delete(_) || affected(pending).iter().any(is_dirty)
  reader.pending = Some(pending)
  reader.dialog = None
  reader.menu = None
  reader.context_menu = None
  if confirm {
    reader.focus = "dialog"
  } else {
    finish_pending()
  }
}

///|
fn resolve_pending(save : Bool) -> Unit {
  guard reader.pending is Some(pending) else { return }
  let paths = affected(pending)
  if save {
    let dirty = paths.filter(is_dirty)
    fn step(i : Int) {
      if i >= dirty.length() {
        finish_pending()
        return
      }
      save_path(dirty[i], ok => if ok { step(i + 1) })
    }

    step(0)
  } else {
    for path in paths {
      if reader.workspace.document(path) is Some(doc) {
        let cursor = doc.editor.head
        doc.editor.set_value(doc.disk)
        doc.editor.set_cursor(cursor)
      }
    }
    finish_pending()
  }
}

///|
fn close_now(path : String) -> Unit {
  let position = reader.tabs.search(path).unwrap_or(0)
  let kept = reader.tabs.filter(p => p != path)
  reader.tabs.clear()
  for p in kept {
    reader.tabs.push(p)
  }
  if reader.untitled.contains(path) {
    reader.untitled.remove(path)
    if reader.workspace.index_of(path) is Some(i) {
      reader.workspace.documents.remove(i) |> ignore
    }
  } else {
    reader.closed.push(path)
  }
  js_ts_drop(path)
  if reader.selected == Some(path) {
    reader.selected = None
    if reader.tabs.length() > 0 {
      let next = reader.tabs[position.min(reader.tabs.length() - 1)]
      open(next, None, false)
    } else {
      reader.focus = "body"
      reader.compare = false
    }
  }
}

///|
fn finish_pending() -> Unit {
  guard reader.pending is Some(pending) else { return }
  reader.pending = None
  match pending {
    Close(path) => close_now(path)
    CloseAll =>
      for path in reader.tabs.copy() {
        close_now(path)
      }
    Quit => quit_now()
    Delete(path) => {
      let documents = reader.workspace.documents
        .filter(d => @core.within(d.path, path))
        .map(d => {
          ({ "path": d.path, "disk": d.disk, "dirty": d.dirty() } : Json)
        })
      rpc(
        "file.delete",
        {
          "root": reader.workspace.root,
          "path": path,
          "documents": Json::array(documents),
        },
        result => {
          match result {
            Ok(summary) => {
              reader.workspace.apply(summary)
              refresh_tree()
              for p in reader.workspace.known_files.keys().collect() {
                if @core.within(p, path) {
                  reader.workspace.known_files.remove(p)
                }
              }
              for tab in reader.tabs.copy() {
                if @core.within(tab, path) {
                  close_now(tab)
                }
              }
              let kept = reader.workspace.documents.filter(d => {
                !@core.within(d.path, path)
              })
              reader.workspace.documents.clear()
              for d in kept {
                reader.workspace.documents.push(d)
              }
              reader.tree_target = None
              say(
                "削除しました。メニューの「削除したファイルを復元」で戻せます",
              )
            }
            Err(e) => say(e)
          }
        },
      )
    }
    Switch(root, file) => load_workspace(root, file, _ => ())
    Reload => reload_workspace()
  }
}

///|
fn quit_now() -> Unit {
  reader.quitting = true
  js_confirm_leave(false)
  rpc("app.quit", {}, _ => js_close_window())
}

///|
fn reset_for_workspace() -> Unit {
  reader.nav_serial += 1
  reader.nav_busy = false
  reader.nav_visible = false
  reader.nav_targets = []
  reader.nav_snapshot = None
  reader.external.clear()
  for tab in reader.tabs {
    js_ts_drop(tab)
  }
  reader.workspace.documents.clear()
  reader.tabs.clear()
  reader.selected = None
  reader.untitled.clear()
  reader.closed.clear()
  reader.history.clear()
  reader.history_index = 0
  reader.expanded.clear()
  reader.workspace.listed.clear()
  reader.workspace.loading.clear()
  reader.workspace.known_files.clear()
  reader.quick_picks = []
  reader.tree_target = None
  reader.compare = false
  reader.disk_cache.clear()
}

///|
/// Read files of a project without touching the open editor state.
fn fetch_files(
  root : String,
  paths : Array[String],
  done : (Map[String, (String, String?)]) -> Unit,
) -> Unit {
  let out : Map[String, (String, String?)] = Map([])
  fn step(i : Int) {
    if i >= paths.length() {
      done(out)
      return
    }
    rpc("file.read", { "root": root, "path": paths[i] }, result => {
      match result {
        Ok({ "text": String(text), "before": before, .. }) =>
          out[paths[i]] = (
            text,
            match before {
              String(b) => Some(b)
              _ => None
            },
          )
        _ => ()
      }
      step(i + 1)
    })
  }

  step(0)
}

///|
/// Switch projects. Everything is read first and applied at once, so input
/// arriving meanwhile acts on a consistent (old) state.
/// `done` runs once the new project is shown, or with the reason it was not.
fn load_workspace(
  root : String,
  file : String?,
  done : (Result[Unit, String]) -> Unit,
) -> Unit {
  rpc("workspace.open", { "path": root }, result => {
    match result {
      Err(e) => {
        say(e)
        done(Err(e))
      }
      Ok(summary) => {
        let first = match file {
          Some(f) => Some(f)
          None => json_text(summary, "first")
        }
        let new_root = json_text(summary, "root").unwrap_or(root)
        fetch_files(new_root, first.map(p => [p]).unwrap_or([]), texts => {
          reset_for_workspace()
          reader.workspace.apply(summary)
          if first is Some(path) && texts.get(path) is Some((text, before)) {
            reader.workspace.documents.push(new_document(path, text, before))
            open(path, None, true)
          }
          say(reader.workspace.root)
          done(Ok(()))
        })
      }
    }
  })
}

///|
/// Reload the listing and every open tab from disk, keeping cursors. As with a
/// switch, the new state is applied in one step once every file is read.
fn reload_workspace() -> Unit {
  let tabs = reader.tabs.copy()
  let selected = reader.selected
  let positions : Map[String, @core.Position] = Map([])
  for d in reader.workspace.documents {
    positions[d.path] = d.editor.position()
  }
  let root = reader.workspace.root
  rpc("workspace.reload", { "root": root }, result => {
    match result {
      Err(e) => say(e)
      Ok(summary) => {
        // Tabs whose files are gone fail to read and are dropped.
        let known = tabs.filter(p => {
          !reader.untitled.contains(p) && !reader.external.contains(p)
        })
        fetch_files(root, known, texts => {
          if reader.workspace.root != root {
            return
          }
          reset_for_workspace()
          reader.workspace.apply(summary)
          for path in known {
            guard texts.get(path) is Some((text, before)) else { continue }
            let doc = new_document(path, text, before)
            if positions.get(path) is Some(pos) {
              let line = pos.line.min(doc.editor.line_count() - 1)
              doc.editor.set_cursor(doc.editor.offset_at(line, pos.character))
            }
            reader.workspace.documents.push(doc)
            reader.tabs.push(path)
          }
          match selected {
            Some(path) if reader.workspace.known(path) => open(path, None, true)
            _ => ()
          }
        })
      }
    }
  })
}

///|
/// Ask the server for a native chooser; fall back to typing a path.
fn pick_path(folder : Bool) -> Unit {
  rpc("pick.path", { "folder": folder }, result => {
    match result {
      Ok({ "path": String(path), .. }) => opened_path(folder, path)
      Ok({ "unsupported": True, .. }) => show(OpenFolder, reader.workspace.root)
      Ok(_) => ()
      Err(e) => say(e)
    }
  })
}

///|
fn opened_path(folder : Bool, path : String) -> Unit {
  let root = reader.workspace.root
  if folder {
    begin(Switch(path, None))
  } else if @core.starts_with(path, root + "/") {
    let relative = @core.slice(path, root.length() + 1, path.length())
    open(relative, None, true)
  } else {
    begin(Switch(@core.parent_of(path), Some(@core.base_name(path))))
  }
}

///|
fn close_tab() -> Unit {
  if reader.overview_visible {
    reader.overview_visible = false
    reader.overview_tab = false
    focus_editor()
    return
  }
  if reader.selected is Some(path) {
    begin(Close(path))
  }
}

///|
fn reopen_tab() -> Unit {
  while reader.closed.pop() is Some(path) {
    if reader.workspace.known(path) {
      open(path, None, true)
      break
    }
  }
}

///|
fn cycle(forward : Bool) -> Unit {
  if reader.tabs.length() == 0 {
    return
  }
  let offset = if reader.overview_tab { 1 } else { 0 }
  let count = reader.tabs.length() + offset
  let index = if reader.overview_visible {
    0
  } else {
    let i = match reader.selected {
      Some(p) => reader.tabs.search(p).unwrap_or(0)
      None => 0
    }
    i + offset
  }
  let next = if forward {
    (index + 1) % count
  } else {
    (index + count - 1) % count
  }
  if reader.overview_tab && next == 0 {
    show_overview()
  } else {
    open(reader.tabs[next - offset], None, true)
  }
}

///|
fn navigate(forward : Bool) -> Unit {
  if reader.history.length() == 0 {
    return
  }
  let pos = cursor_position()
  if reader.history.get(reader.history_index) is Some(here) {
    here.line = pos.line
    here.column = pos.character
  }
  reader.history_index = if forward {
    (reader.history_index + 1).min(reader.history.length() - 1)
  } else {
    (reader.history_index - 1).max(0)
  }
  let loc = reader.history[reader.history_index]
  let line = loc.line
  let column = loc.column
  open(loc.path, Some(line), false, then=() => {
    if current_editor() is Some(e) {
      e.set_cursor(e.offset_at(line, column))
      request_reveal(line, 0)
    }
  })
}

///|
fn toggle_wrap() -> Unit {
  reader.wrap = !reader.wrap
}

///|
fn toggle_compare() -> Unit {
  reader.compare = !reader.compare
  rebuild_diff()
  if !reader.compare {
    focus_editor()
  }
}

///|
fn file_target() -> String? {
  match reader.tree_target {
    Some(t) => Some(t)
    None => reader.selected
  }
}

///|
fn replace_text(all : Bool) -> Unit {
  let query = js_get_value("dialog-query")
  let replacement = js_get_value("dialog-replacement")
  reader.query = query
  reader.replacement = replacement
  if query == "" {
    say("置換する文字列を入力してください")
    return
  }
  guard current_editor() is Some(editor) else { return }
  let text = editor.text
  if all {
    let count = @core.find_all(text, query).length()
    if count > 0 {
      ignore(
        editor.replace_range(
          0,
          text.length(),
          @core.replace_all(text, query, replacement),
        ),
      )
    }
    say("\{count}件を置換しました · ⌘Zで元に戻す")
  } else {
    let cursor = editor.head
    let found = @core.find_from(text, query, cursor)
    let start = if found >= 0 { found } else { @core.find_from(text, query, 0) }
    if start >= 0 {
      ignore(editor.replace_range(start, start + query.length(), replacement))
      say("1件を置換しました · ⌘Zで元に戻す")
    } else {
      say("一致する文字列がありません")
    }
  }
  document_changed()
}

///|
/// A buffer's text changed: drop previews, refresh the diff.
fn document_changed() -> Unit {
  clear_pointer()
  reader.search_key = ""
  if reader.compare {
    rebuild_diff()
  }
}
