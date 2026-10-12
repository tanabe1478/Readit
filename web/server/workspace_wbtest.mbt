// The workspace against a real temporary folder: path safety, the limits on
// what the editor reads, and the file operations that must never lose data.

///|
fn scratch() -> String {
  init_node()
  temp_dir("readit-ws-")
}

///|
fn write(dir : String, relative : String, text : String) -> Unit raise {
  let full = path_join(dir, relative)
  mkdir_all(path_dirname(full))
  atomic_replace(full, text)
}

///|
/// The message of a failed operation, or "" when it succeeded.
fn fails(f : () -> Unit raise) -> String {
  try f() catch {
    Failure(m) => @core.failure_text(m)
    e => "\{e}"
  } noraise {
    _ => ""
  }
}

///|
test "relative paths split into safe components; tool output is skipped" {
  assert_eq(components("a/b.py"), Some(["a", "b.py"]))
  assert_eq(components("a/../b"), None)
  assert_eq(components("/abs"), None)
  assert_eq(components("a//b"), None)
  assert_eq(components("./a"), None)
  assert_eq(components(""), None)
  assert_true(skipped("node_modules/x.js"))
  assert_true(skipped("a/.env.local"))
  assert_true(skipped("package-lock.json"))
  assert_true(skipped(".readit/trash/x"))
  assert_false(skipped("src/env.py"))
  assert_false(skipped("targets/x.py"))
}

///|
test "a plain folder lists its text files in reading order" {
  let dir = scratch()
  write(dir, "README.md", "# hi\n")
  write(dir, "src/b.py", "b\n")
  write(dir, "src/a.py", "a\n")
  write(dir, "node_modules/x.js", "x")
  write(dir, ".readit/session.json", "{}")
  let ws = Workspace::load(dir)
  assert_false(ws.git)
  let expected = ["README.md", "src/a.py", "src/b.py"]
  @core.sort_reading_order(expected)
  assert_eq(ws.files(), expected)
  // Directory order; the page sorts folders first. The reserved folder is not shown.
  assert_eq(ws.children("").map(c => c.name), ["README.md", "src"])
  assert_eq(
    ws.check(["src/a.py", "node_modules/x.js", "missing.py", "../x", "src"]),
    ["src/a.py"],
  )
  remove_tree(dir)
}

///|
test "reading refuses what the editor cannot hold and explains why" {
  let dir = scratch()
  write(dir, "ok.py", "x = 1\n")
  write(dir, "big.txt", "a".repeat(256 * 1024 + 1))
  write_bytes(path_join(dir, "bin.dat"), "ab\u{0}cd")
  write_bytes(path_join(dir, "latin.txt"), "caf\u{e9}")
  mkdir_all(path_join(dir, "folder"))
  let ws = Workspace::load(dir)
  assert_eq(ws.read("ok.py"), ("x = 1\n", Some("x = 1\n")))
  assert_true(
    fails(() => ws.read("big.txt") |> ignore).contains("大きすぎます"),
  )
  assert_true(
    fails(() => ws.read("bin.dat") |> ignore).contains("バイナリ"),
  )
  assert_true(
    fails(() => ws.read("latin.txt") |> ignore).contains("UTF-8以外"),
  )
  assert_true(
    fails(() => ws.read("missing.py") |> ignore).contains("missing.py"),
  )
  assert_true(
    fails(() => ws.read("../ok.py") |> ignore).contains("相対パス"),
  )
  assert_true(
    fails(() => ws.read("folder") |> ignore).contains(
      "ファイルではありません",
    ),
  )
  remove_tree(dir)
}

///|
test "saving requires the text the editor last read" {
  let dir = scratch()
  write(dir, "f.py", "v1")
  let ws = Workspace::load(dir)
  let (text, _) = ws.read("f.py")
  atomic_replace(path_join(dir, "f.py"), "v2")
  assert_true(
    fails(() => ws.save("f.py", text, "v3") |> ignore).contains(
      "外部でファイルが変更",
    ),
  )
  assert_eq(read_text(path_join(dir, "f.py")), "v2")
  ws.save("f.py", "v2", "v3")
  assert_eq(read_text(path_join(dir, "f.py")), "v3")
  remove_tree(dir)
}

///|
test "rename never overwrites, keeps the session trail and refuses the reserved folders" {
  let dir = scratch()
  write(dir, "a.py", "A")
  write(dir, "b.py", "B")
  write(dir, "dir/c.py", "C")
  let ws = Workspace::load(dir)
  ws.session = {
    "reviewed": { "a.py": true },
    "notes": [{ "path": "a.py", "text": "n" }],
  }
  assert_true(
    fails(() => ws.rename("a.py", "b.py") |> ignore).contains("同じ名前"),
  )
  assert_eq(read_text(path_join(dir, "b.py")), "B")
  ws.rename("a.py", "z.py")
  assert_true(ws.files().contains("z.py"))
  assert_false(ws.files().contains("a.py"))
  assert_eq(json_text_of(ws.session, "reviewed"), "{\"z.py\":true}")
  assert_true(
    read_text(path_join(dir, ".readit/session.json")).contains("z.py"),
  )
  assert_true(
    fails(() => ws.rename("dir", "dir/sub") |> ignore).contains("自身の中"),
  )
  ws.rename("dir", "moved")
  assert_true(ws.files().contains("moved/c.py"))
  assert_true(fails(() => ws.rename(".readit", "x") |> ignore) != "")
  assert_true(
    fails(() => ws.create_file(".git/hook", "") |> ignore).contains("予約"),
  )
  remove_tree(dir)
}

///|
fn json_text_of(value : Json, key : String) -> String {
  match value {
    Object(o) => o.get(key).map(v => v.stringify()).unwrap_or("")
    _ => ""
  }
}

///|
test "delete moves a file to the trash and restore brings it back" {
  let dir = scratch()
  write(dir, "a.py", "A")
  write(dir, "keep.py", "K")
  let ws = Workspace::load(dir)
  let held = (disk : String, dirty : Bool) => {
    [({ path: "a.py", disk, dirty, } : HeldDocument)]
  }
  assert_true(
    fails(() => ws.delete("a.py", held("A", true)) |> ignore).contains(
      "未保存",
    ),
  )
  assert_true(
    fails(() => ws.delete("a.py", held("old", false)) |> ignore).contains(
      "外部で変更",
    ),
  )
  assert_eq(read_text(path_join(dir, "a.py")), "A")
  ws.delete("a.py", held("A", false))
  assert_eq(stat_kind(path_join(dir, "a.py")), "")
  assert_false(ws.files().contains("a.py"))
  assert_eq(ws.restore_last(), "a.py")
  assert_eq(read_text(path_join(dir, "a.py")), "A")
  assert_true(ws.files().contains("a.py"))
  assert_true(
    fails(() => ws.restore_last() |> ignore).contains("復元できる"),
  )
  assert_true(fails(() => ws.delete(".git", []) |> ignore).contains("予約"))
  remove_tree(dir)
}
