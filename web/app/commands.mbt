// Command palette, pickers and dialog confirmation.

///|
let commands : Array[(String, String, String)] = [
  ("new", "新規ファイル", "⌘N / ⌃N"),
  ("folder", "新規フォルダ", ""),
  ("open", "ファイルを開く", "⌘O"),
  ("open-folder", "フォルダを開く", "⌘K ⌘O"),
  ("save", "保存", "⌘S"),
  ("save-all", "すべて保存", "⌥⌘S"),
  ("save-as", "名前を付けて保存", "⇧⌘S"),
  ("close", "タブを閉じる", "⌘W / ⌃W"),
  ("close-all", "すべてのタブを閉じる", "⌘K ⌘W"),
  ("reopen", "閉じたタブを開く", "⇧⌘T / ⌃⇧T"),
  ("rename", "ファイルの名前を変更", "F2 / Explorer"),
  ("delete", "ファイルを削除（復元可能）", "⌘⌫ / Explorer"),
  ("restore", "削除したファイルを復元", "⇧⌘⌫ / Explorer"),
  ("find", "ファイル内検索", "⌘F"),
  ("replace", "ファイル内置換", "⌥⌘F"),
  ("find-all", "プロジェクト内検索", "⇧⌘F"),
  ("goto", "行へ移動", "⌃G"),
  ("definition", "定義へ移動", "F12 / ⌘クリック"),
  ("peek-definition", "定義を確認", "⌥F12"),
  ("type-definition", "型定義へ移動", "⌘F12"),
  ("implementation", "実装へ移動", "⇧⌘F12"),
  ("references", "使用箇所を検索", "⇧F12"),
  ("symbols", "ファイル内のシンボルへ移動", "⇧⌘O"),
  ("hover", "型とドキュメントを表示", "⌘K ⌘I"),
  ("pin-code", "現在のコードを横に固定", "⌘K ⌘P"),
  ("unpin-code", "固定したコードを閉じる", ""),
  ("definition-hover", "定義ホバープレビューを表示", ""),
  ("wrap", "折返し切替", "⌥Z"),
  ("sidebar", "ファイルツリー表示切替", "⌘B"),
  ("compare", "変更前と比較", "⌥⌘D"),
  ("reload", "ディスクから再読込", "⌘R"),
  ("reveal", "Finderで表示", ""),
  ("next-tab", "次のタブ", "⌃Tab / ⌥⌘→"),
  ("previous-tab", "前のタブ", "⌃⇧Tab / ⌥⌘←"),
  ("back", "戻る", "⌃− / ⌥←"),
  ("forward", "進む", "⌃⇧− / ⌥→"),
  ("zoom-in", "拡大", "⌘+"),
  ("zoom-out", "縮小", "⌘−"),
  ("reset-zoom", "倍率を戻す", "⌘0"),
  ("help", "ショートカット一覧", ""),
  ("quit", "Readitを終了", "⌘Q / ⌃Q"),
]

///|
fn picks() -> Array[Pick] {
  let q = @core.lower(@core.trim(reader.query))
  match reader.dialog {
    Some(Navigation) =>
      reader.nav_targets
      .mapi((i, t) => (i, t))
      .filter(pair => {
        let (_, t) = pair
        @core.contains(@core.lower("\{t.name} \{t.detail} \{t.path}"), q)
      })
      .map(pair => {
        let (i, t) = pair
        {
          label: if t.name == "" {
            "\{target_path(t)}:\{t.line + 1}:\{t.character + 1}"
          } else {
            t.name
          },
          detail: t.detail,
          path: None,
          line: None,
          command: None,
          target: Some(i),
        }
      })
    Some(Quick) => reader.quick_picks
    Some(Commands) =>
      commands
      .filter(c => {
        let (id, name, _) = c
        q == "" || @core.contains(name, q) || @core.contains(id, q)
      })
      .map(c => {
        let (id, name, key) = c
        {
          label: name,
          detail: key,
          path: None,
          line: None,
          command: Some(id),
          target: None,
        }
      })
    Some(WorkspaceSearch) => if q == "" { [] } else { reader.workspace_picks }
    _ => []
  }
}

///|
/// Ask the server for files whose path matches the quick-open query. Only the
/// latest answer is shown.
fn find_files() -> Unit {
  reader.quick_serial += 1
  let serial = reader.quick_serial
  rpc(
    "files.find",
    { "root": reader.workspace.root, "query": reader.query, "limit": 80 },
    result => {
      if serial != reader.quick_serial {
        return
      }
      match result {
        Ok({ "files": Array(items), .. }) =>
          reader.quick_picks = items.filter_map(item => {
            match item {
              String(file) =>
                Some({
                  label: file,
                  detail: if is_dirty(file) {
                    "未保存"
                  } else {
                    ""
                  },
                  path: Some(file),
                  line: None,
                  command: None,
                  target: None,
                })
              _ => None
            }
          })
        Ok(_) => reader.quick_picks = []
        Err(e) => say(e)
      }
    },
  )
}

///|
/// Search the project a moment after typing stops. Loaded buffers win.
fn schedule_workspace_search() -> Unit {
  if reader.workspace_search_timer is Some(t) {
    cancel_timer(t)
  }
  reader.workspace_search_timer = Some(
    after(150, () => {
      reader.workspace_search_timer = None
      let query = @core.trim(reader.query)
      reader.workspace_search_serial += 1
      let serial = reader.workspace_search_serial
      if query == "" {
        reader.workspace_picks = []
        return
      }
      rpc(
        "search",
        {
          "root": reader.workspace.root,
          "query": query,
          "mode": "picker",
          "limit": 200,
          "overlays": overlays(),
        },
        result => {
          if serial != reader.workspace_search_serial {
            return
          }
          match result {
            Ok({ "matches": Array(items), .. }) =>
              reader.workspace_picks = items.filter_map(item => {
                match item {
                  {
                    "path": String(path),
                    "line": Number(line, ..),
                    "text": String(text),
                    ..
                  } =>
                    Some({
                      label: "\{path}:\{line.to_int()}",
                      detail: text,
                      path: Some(path),
                      line: Some(line.to_int() - 1),
                      command: None,
                      target: None,
                    })
                  _ => None
                }
              })
            Ok(_) => reader.workspace_picks = []
            Err(e) => say(e)
          }
        },
      )
    }),
  )
}

///|
/// Loaded project texts, so searches see unsaved edits.
fn overlays() -> Json {
  let out : Map[String, Json] = Map([])
  for d in reader.workspace.documents {
    if !reader.untitled.contains(d.path) && !reader.external.contains(d.path) {
      out[d.path] = Json::string(d.text())
    }
  }
  Json::object(out)
}

///|
fn accept() -> Unit {
  guard reader.dialog is Some(dialog) else { return }
  reader.query = js_get_value("dialog-query")
  let value = @core.trim(reader.query)
  match dialog {
    Quick | Commands | WorkspaceSearch | Navigation => {
      let list = picks()
      guard list.get(reader.pick_index) is Some(pick) else { return }
      reader.dialog = None
      focus_editor()
      if pick.target is Some(index) {
        jump_target(index)
      } else if pick.command is Some(command) {
        run_command(command)
      } else if pick.path is Some(path) {
        open(path, pick.line, true)
      }
    }
    Goto => {
      let parts = value.split(":").map(p => p.to_owned()).collect()
      match @core.parse_natural(parts.get(0).unwrap_or("")) {
        Some(line) => {
          let column = match parts.get(1) {
            Some(c) => @core.parse_natural(c).unwrap_or(1)
            None => 1
          }
          if current_editor() is Some(e) {
            reader.dialog = None
            let l = (line - 1).clamp(min=0, max=(e.line_count() - 1).max(0))
            e.set_cursor(e.offset_at(l, column - 1))
            request_reveal(l, 2)
            focus_editor()
          }
        }
        None => say("行番号または行:列を入力してください")
      }
    }
    NewFolder =>
      rpc("dir.create", { "root": reader.workspace.root, "path": value }, result => {
        match result {
          Ok(summary) => {
            reader.workspace.apply(summary)
            refresh_tree()
            reveal_in_tree(value)
            reader.tree_target = Some(value)
            dismiss()
          }
          Err(e) => say(e)
        }
      })
    Rename =>
      if reader.rename_source is Some(from) {
        rpc(
          "file.rename",
          { "root": reader.workspace.root, "from": from, "to": value },
          result => {
            match result {
              Ok(summary) => {
                reader.workspace.apply(summary)
                refresh_tree()
                renamed(from, value)
                dismiss()
              }
              Err(e) => say(e)
            }
          },
        )
      }
    SaveAs => save_as_accept(value)
    Replace => replace_text(false)
    OpenFolder => {
      reader.dialog = None
      opened_path(true, value)
    }
    Help | Information => dismiss()
  }
}

///|
/// Rewrite every open path after a file or folder rename.
fn renamed(from : String, to : String) -> Unit {
  for d in reader.workspace.documents {
    let next = @core.remap_path(d.path, from, to)
    if next != d.path {
      js_ts_drop(d.path)
      d.path = next
    }
  }
  for i, tab in reader.tabs {
    reader.tabs[i] = @core.remap_path(tab, from, to)
  }
  for i, p in reader.closed {
    reader.closed[i] = @core.remap_path(p, from, to)
  }
  for loc in reader.history {
    loc.path = @core.remap_path(loc.path, from, to)
  }
  let expanded = reader.expanded.keys().collect()
  reader.expanded.clear()
  for p in expanded {
    reader.expanded[@core.remap_path(p, from, to)] = ()
  }
  let known = reader.workspace.known_files.keys().collect()
  reader.workspace.known_files.clear()
  for p in known {
    reader.workspace.known_files[@core.remap_path(p, from, to)] = ()
  }
  reader.selected = match reader.selected {
    Some(p) => Some(@core.remap_path(p, from, to))
    None => None
  }
  reader.tree_target = Some(to)
  reveal_in_tree(to)
}

///|
fn save_as_accept(value : String) -> Unit {
  guard reader.save_source is Some(source) else { return }
  guard reader.workspace.document(source) is Some(doc) else { return }
  let text = doc.text()
  rpc(
    "file.create",
    { "root": reader.workspace.root, "path": value, "text": text },
    result => {
      match result {
        Err(e) => say(e)
        Ok(summary) => {
          reader.workspace.apply(summary)
          refresh_tree()
          reader.workspace.known_files[value] = ()
          if reader.untitled.contains(source) {
            reader.untitled.remove(source)
            doc.path = value
            doc.disk = text
            doc.before = if reader.workspace.git { None } else { Some(text) }
          } else {
            // The original keeps its saved content; the edits move to the new file.
            let copy = new_document(
              value,
              text,
              if reader.workspace.git {
                None
              } else {
                Some(text)
              },
            )
            let cursor = doc.editor.head
            doc.editor.set_value(doc.disk)
            copy.editor.set_cursor(cursor)
            reader.workspace.documents.push(copy)
          }
          for i, tab in reader.tabs {
            if tab == source {
              reader.tabs[i] = value
            }
          }
          js_ts_drop(source)
          match reader.pending {
            Some(Close(path)) if path == source =>
              reader.pending = Some(Close(value))
            _ => ()
          }
          reader.dialog = None
          reader.save_source = None
          open(value, None, true)
          say("保存しました · \{value}")
          if reader.pending is Some(_) {
            resolve_pending(true)
          } else if reader.saving_all {
            save_all()
          }
        }
      }
    },
  )
}

///|
fn restore_deleted() -> Unit {
  rpc("file.restore", { "root": reader.workspace.root }, result => {
    match result {
      Ok({ "path": String(path), "file": file, "workspace": summary, .. }) => {
        reader.workspace.apply(summary)
        refresh_tree()
        if file is True {
          reader.workspace.known_files[path] = ()
        }
        reveal_in_tree(path)
        if reader.workspace.known(path) {
          open(path, None, true)
        }
        reader.tree_target = Some(path)
        say("削除した項目を復元しました")
      }
      Ok(_) => ()
      Err(e) => say(e)
    }
  })
}

///|
fn run_command(command : String) -> Unit {
  reader.menu = None
  reader.context_menu = None
  match command {
    "new" => new_file()
    "folder" => show(NewFolder, "")
    "open" => pick_path(false)
    "open-folder" => pick_path(true)
    "save" => save()
    "save-all" => save_all()
    "save-as" => save_as()
    "close" => close_tab()
    "close-all" => begin(CloseAll)
    "reopen" => reopen_tab()
    "rename" =>
      match file_target() {
        Some(path) if !reader.external.contains(path) =>
          if reader.untitled.contains(path) {
            save_as()
          } else {
            reader.rename_source = Some(path)
            show(Rename, path)
          }
        _ => ()
      }
    "delete" =>
      match file_target() {
        Some(path) if !reader.external.contains(path) =>
          if reader.untitled.contains(path) {
            close_tab()
          } else {
            begin(Delete(path))
          }
        _ => ()
      }
    "restore" => restore_deleted()
    "find" => open_search()
    "replace" => show(Replace, "")
    "find-all" => show(WorkspaceSearch, "")
    "goto" => show(Goto, "")
    "definition" => analyze(Definition, true, None)
    "peek-definition" => analyze(Definition, false, None)
    "type-definition" => analyze(TypeDefinition, true, None)
    "implementation" => analyze(Implementation, true, None)
    "references" => analyze(References, false, None)
    "symbols" => analyze(Symbols, false, None)
    "hover" => analyze(Hover, false, None)
    "pin-code" => pin_current()
    "unpin-code" => reader.pinned = None
    "definition-hover" => definition_hover_here()
    "wrap" => toggle_wrap()
    "sidebar" => reader.sidebar = !reader.sidebar
    "compare" => toggle_compare()
    "reload" => begin(Reload)
    "reveal" =>
      match reader.selected {
        Some(path) if !reader.untitled.contains(path) &&
          !reader.external.contains(path) =>
          rpc("reveal", { "root": reader.workspace.root, "path": path }, result => {
            match result {
              Ok({ "revealed": False, .. }) =>
                say("Finderでの表示はmacOSのみ対応です")
              Ok(_) => ()
              Err(e) => say(e)
            }
          })
        _ => ()
      }
    "help" => show(Help, "")
    "next-tab" => cycle(true)
    "previous-tab" => cycle(false)
    "back" => navigate(false)
    "forward" => navigate(true)
    "zoom-in" => reader.font_size = (reader.font_size + 1.0).min(28.0)
    "zoom-out" => reader.font_size = (reader.font_size - 1.0).max(10.0)
    "reset-zoom" => reader.font_size = 14.0
    "quit" => begin(Quit)
    "toggle-reading" => reader.reading_path = !reader.reading_path
    "focus-explorer" => {
      reader.sidebar = true
      reader.focus = "explorer"
    }
    "undo" => if current_editor() is Some(e) && e.undo() { document_changed() }
    "redo" => if current_editor() is Some(e) && e.redo() { document_changed() }
    "select-all" =>
      if current_editor() is Some(e) {
        e.select_all()
        focus_editor()
      }
    "copy" =>
      if current_editor() is Some(e) {
        js_clipboard_write(e.selected_text())
      }
    // The browser asks once for clipboard access; the text arrives as a paste event.
    "paste" => {
      focus_editor()
      js_clipboard_read()
    }
    "cut" =>
      if current_editor() is Some(e) && e.has_selection() && !e.read_only {
        js_clipboard_write(e.selected_text())
        ignore(e.backspace(Char))
        document_changed()
      }
    "overview" => show_overview()
    _ => ()
  }
}
