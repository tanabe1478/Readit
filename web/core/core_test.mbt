///|
fn raises(f : () -> Unit raise) -> Bool {
  try f() catch {
    _ => true
  } noraise {
    _ => false
  }
}

///|
test "coordinates handle crlf, emoji and eof" {
  let text = "a😀\r\n次\n"
  assert_eq(@core.offset_at(text, 1, 2), 1)
  assert_true(raises(() => ignore(@core.offset_at(text, 1, 3))))
  assert_eq(@core.offset_at(text, 1, 4), 3)
  assert_eq(@core.offset_at(text, 2, 1), 5)
  assert_eq(@core.offset_at(text, 3, 1), 7)
  assert_true(raises(() => ignore(@core.offset_at(text, 0, 1))))
  assert_true(raises(() => ignore(@core.offset_at(text, 4, 1))))
  assert_true(raises(() => ignore(@core.offset_at(text, 1, 5))))
}

///|
test "unicode positions roundtrip" {
  let text = "α🦀x\r\n日本語 value"
  let mut at = 0
  while at <= text.length() {
    assert_eq(@core.offset_of(text, @core.position_at(text, at)), at)
    if at == text.length() {
      break
    }
    at = @core.next_char(text, at)
  }
  // Inside the surrogate pair moves back to the character start.
  assert_eq(@core.position_at(text, 2), { line: 0, character: 1, })
  assert_eq(@core.position_at(text, 4), { line: 0, character: 4, })
  assert_eq(@core.position_at(text, 7), { line: 1, character: 1, })
}

///|
test "lines follow rust semantics" {
  assert_eq(@core.lines("a\r\nb\n"), ["a", "b"])
  assert_eq(@core.lines(""), [])
  assert_eq(@core.lines("\n"), [""])
  assert_eq(@core.split_newlines("a\nb\n"), ["a", "b", ""])
}

///|
test "inserted lines keep evidence line numbers correct" {
  let r = @core.diff_rows("a\nb\n", "a\nnew\nb\n", true)
  assert_eq(r[1].kind, Added)
  assert_eq(r[1].new, Some(1))
  assert_eq(r[2].old, Some(1))
  assert_eq(r[2].new, Some(2))
}

///|
test "removed lines have no edit target" {
  let r = @core.diff_rows("a\nb\n", "b\n", true)
  assert_eq(r[0].kind, Removed)
  assert_eq(r[0].new, None)
  assert_eq(r[1].new, Some(0))
}

///|
test "empty directories are visible and collapsible" {
  let dirs = ["src", "src/empty"]
  assert_eq(@core.tree_entries([], dirs, Map([])).length(), 2)
  assert_eq(@core.tree_entries([], dirs, Map([("src", ())])).length(), 1)
}

///|
test "preserves hierarchy, sorts folders first and collapses descendants" {
  let paths = ["z.rs", "src/nested/b.rs", "src/a.rs", "README.md"]
  let open = @core.tree_entries(paths, [], Map([]))
  assert_eq(open.map(e => e.path), [
    "src", "src/nested", "src/nested/b.rs", "src/a.rs", "README.md", "z.rs",
  ])
  assert_eq(open[2].depth, 2)
  assert_eq(open[2].file, Some(1))
  let closed = @core.tree_entries(paths, [], Map([("src", ())]))
  assert_eq(closed.length(), 3)
  assert_eq(closed[0].file, None)
}

///|
test "identifies the pointed symbol" {
  let s = "first(foo.bar, second)"
  assert_eq(@core.symbol_range(s, 11), Some((10, 13)))
  assert_eq(@core.symbol_range(s, 15), Some((15, 21)))
  assert_eq(@core.symbol_range(s, 9), None)
  assert_eq(@core.symbol_range(s, 14), None)
  assert_eq(@core.symbol_range(s, s.length()), None)
}

///|
test "unicode symbols use utf16 offsets" {
  let s = "😀 商品_total(x)"
  let start = 3
  let end = 11
  assert_eq(@core.symbol_range(s, start + 1), Some((start, end)))
  assert_eq(@core.symbol_range(s, 1), None)
  assert_eq(@core.symbol_range(s, 0), None)
}

///|
test "lex compare is code point order" {
  let values = ["z.rs", "src", "README.md", "abc", "ab", "b"]
  @core.sort_strings(values)
  assert_eq(values, ["README.md", "ab", "abc", "b", "src", "z.rs"])
  assert_eq(@core.lex_compare("a", "a"), 0)
}

///|
test "word movement" {
  let s = "let foo_bar = x.y;"
  assert_eq(@core.word_right(s, 0), 3)
  assert_eq(@core.word_right(s, 3), 11)
  assert_eq(@core.word_left(s, 11), 4)
  assert_eq(@core.word_left(s, 4), 0)
  assert_eq(@core.word_right(s, 11), 13)
}

///|
test "roles and reading order" {
  let paths = [
    "src/tests/a_test.py", "README.md", "src/types.ts", "src/main.rs", "Cargo.toml",
  ]
  @core.sort_reading_order(paths)
  assert_eq(paths, [
    "README.md", "src/types.ts", "src/main.rs", "src/tests/a_test.py", "Cargo.toml",
  ])
  assert_eq(@core.language("x/y.tsx"), "tsx")
  assert_eq(@core.language_id("a.java"), Some("java"))
}

///|
test "remap and within" {
  assert_eq(@core.remap_path("src/a.rs", "src", "lib"), "lib/a.rs")
  assert_eq(@core.remap_path("src-other.rs", "src", "lib"), "src-other.rs")
  assert_true(@core.within("src/a", "src"))
  assert_false(@core.within("srcx", "src"))
}

///|
test "text helpers" {
  assert_eq(@core.replace_all("a-b-c", "-", "+"), "a+b+c")
  assert_eq(@core.find_all("aaaa", "aa"), [0, 2])
  assert_eq(@core.trim("  x \n"), "x")
  assert_eq(@core.take_chars("日本😀語", 3), "日本😀")
  assert_eq(@core.char_count("日本😀語"), 4)
  assert_eq(
    @core.escape_html("<a href=\"x\">&"),
    "&lt;a href=&quot;x&quot;&gt;&amp;",
  )
  assert_eq(@core.lower("ABCÄ"), "abcä")
}
