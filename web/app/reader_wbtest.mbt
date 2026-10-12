// Editing, files and the reading tools, through the same events the page
// sends and the same calls the MCP server makes.

///|
let project : Map[String, String] = {
  "README.md": "# Readme\n",
  "src/sample.py": "one = 1\ntwo = 2\nthree = 3\n",
  "src/store.py": "class Store:\n    cache = {}\n",
}

///|
fn editor_text() -> String {
  current_editor().unwrap().text
}

///|
test "typing marks the tab dirty, save writes through the server, undo keeps the trail" {
  fresh(project)
  assert_eq(reader.selected, Some("README.md"))
  act("open", arg="src/sample.py")
  assert_eq(reader.selected, Some("src/sample.py"))
  type_text("x")
  assert_true(is_dirty("src/sample.py"))
  press_key("cmd-s")
  assert_eq(disk.get("src/sample.py"), Some("xone = 1\ntwo = 2\nthree = 3\n"))
  assert_false(is_dirty("src/sample.py"))
  press_key("cmd-z")
  assert_eq(editor_text(), "one = 1\ntwo = 2\nthree = 3\n")
  assert_true(is_dirty("src/sample.py"))
  press_key("cmd-shift-z")
  assert_false(is_dirty("src/sample.py"))
}

///|
test "a save that would overwrite an external change is refused" {
  fresh(project)
  type_text("x")
  disk["README.md"] = "# Changed elsewhere\n"
  press_key("cmd-s")
  assert_true(status_text().contains("外部でファイルが変更"))
  assert_true(is_dirty("README.md"))
  assert_eq(disk.get("README.md"), Some("# Changed elsewhere\n"))
}

///|
test "closing a dirty tab asks first; discarding keeps the disk as it was" {
  fresh(project)
  type_text("x")
  press_key("cmd-w")
  assert_true(reader.pending is Some(_))
  assert_true(reader.tabs.contains("README.md"))
  assert_true(
    fake_html("dialog-body").contains("保存") ||
    fake_html("dialog-shell").contains("保存"),
  )
  // The MCP side sees the dialog and must wait.
  assert_eq(json_field(state(), "dialog_open"), Some(true))
  assert_true(mcp("readit_open", args({ "path": "src/store.py" })) is Err(_))
  act("confirm-discard")
  assert_false(reader.tabs.contains("README.md"))
  assert_eq(disk.get("README.md"), Some("# Readme\n"))
  assert_true(reader.pending is None)
}

///|
test "quick open filters project files and opens the pick" {
  fresh(project)
  press_key("cmd-p")
  assert_true(reader.dialog == Some(Quick))
  on_event(
    "input",
    ({ "id": "dialog-query", "value": "store" } : Json).stringify(),
  )
  |> ignore
  serve()
  assert_eq(reader.quick_picks.length(), 1)
  act("accept-dialog")
  assert_eq(reader.selected, Some("src/store.py"))
  assert_true(reader.dialog is None)
}

///|
test "the tree lists a folder when it opens and reveals files opened elsewhere" {
  fresh(project)
  let tree = fake_html("tree-scroll")
  assert_true(tree.contains("src"))
  assert_false(tree.contains("sample.py"))
  act("tree", arg="src")
  assert_true(fake_html("tree-scroll").contains("sample.py"))
  act("tree", arg="src")
  assert_false(fake_html("tree-scroll").contains("sample.py"))
  // Opening a file from the model side expands its folder again.
  assert_true(
    mcp("readit_open", args({ "path": "src/store.py", "line": 2 })) is Ok(_),
  )
  assert_true(fake_html("tree-scroll").contains("store.py"))
}

///|
test "readit_read sees unsaved text and numbers lines on request" {
  fresh(project)
  act("open", arg="src/sample.py")
  type_text("x")
  let page = mcp(
    "readit_read",
    args({
      "path": "src/sample.py",
      "start_line": 1,
      "line_count": 2,
      "numbered": true,
    }),
  ).unwrap()
  assert_eq(json_text(page, "text"), Some("1| xone = 1\n2| two = 2"))
  assert_eq(json_field(page, "unsaved"), Some(true))
  assert_eq(json_int(page, "total_lines"), Some(4))
  assert_true(
    mcp("readit_read", args({ "path": "src/sample.py", "start_line": 9 }))
    is Err(_),
  )
  assert_true(mcp("readit_read", args({ "path": "../outside.py" })) is Err(_))
}

///|
test "readit_open selects a range, history returns, and pins show a snapshot" {
  fresh(project)
  let opened = mcp(
    "readit_open",
    args({
      "path": "src/store.py",
      "line": 2,
      "column": 5,
      "end_line": 2,
      "end_column": 15,
    }),
  ).unwrap()
  assert_eq(
    json_text(json_field(opened, "selection").unwrap(), "text"),
    Some("cache = {}"),
  )
  assert_eq(json_text(opened, "active_path"), Some("/proj/src/store.py"))
  assert_true(mcp("readit_history", args({ "direction": "back" })) is Ok(_))
  assert_eq(reader.selected, Some("README.md"))
  assert_true(mcp("readit_history", args({ "direction": "forward" })) is Ok(_))
  assert_eq(reader.selected, Some("src/store.py"))
  let pinned = mcp("readit_pin", args({ "path": "src/sample.py", "line": 2 })).unwrap()
  assert_eq(
    json_text(json_field(pinned, "pinned").unwrap(), "path"),
    Some("/proj/src/sample.py"),
  )
  assert_true(fake_html("pinned-head").contains("sample.py"))
  assert_eq(reader.selected, Some("src/store.py"))
  assert_true(mcp("readit_unpin", args({})) is Ok(_))
  assert_true(reader.pinned is None)
}

///|
test "readit_view and readit_files answer without moving the editor" {
  fresh(project)
  let view = json_field(
    mcp("readit_view", args({ "wrap": true, "file_tree": false })).unwrap(),
    "view",
  ).unwrap()
  assert_eq(json_field(view, "wrap"), Some(true))
  assert_eq(json_field(view, "file_tree"), Some(false))
  let files = mcp("readit_files", args({ "filter": "src/" })).unwrap()
  assert_eq(json_int(files, "total"), Some(2))
  assert_eq(reader.selected, Some("README.md"))
  // A call for another workspace is refused before anything runs.
  assert_true(
    mcp("readit_view", { "workspace": "/elsewhere", "wrap": true }) is Err(_),
  )
}
