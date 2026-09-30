///|
test "typing merges into one undo step and redo restores it" {
  let e = @editor.Editor::new("")
  for c in ["a", "b", "c"] {
    ignore(e.insert(c))
  }
  assert_eq(e.text, "abc")
  assert_true(e.undo())
  assert_eq(e.text, "")
  assert_true(e.redo())
  assert_eq(e.text, "abc")
  assert_eq(e.head, 3)
}

///|
test "newline keeps indentation and crlf endings are stepped over" {
  let e = @editor.Editor::new("    x = 1")
  e.set_cursor(9)
  ignore(e.newline())
  assert_eq(e.text, "    x = 1\n    ")
  let crlf = @editor.Editor::new("ab\r\ncd")
  crlf.set_cursor(2)
  crlf.move_cursor(Right)
  assert_eq(crlf.head, 4)
  crlf.move_cursor(Left)
  assert_eq(crlf.head, 2)
  assert_eq(crlf.line_end(0), 2)
  assert_eq(crlf.line_text(0), "ab")
}

///|
test "vertical movement keeps the goal column" {
  let e = @editor.Editor::new("long line\nx\nanother")
  e.set_cursor(7)
  e.move_cursor(Down)
  assert_eq(e.head, 11)
  e.move_cursor(Down)
  assert_eq(e.position(), { line: 2, character: 7, })
  e.move_cursor(Up, selecting=true)
  assert_eq(e.selection(), (11, 19))
}

///|
test "indent and outdent selected lines" {
  let e = @editor.Editor::new("a\nb\nc")
  e.select(0, 3)
  ignore(e.indent())
  assert_eq(e.text, "    a\n    b\nc")
  ignore(e.outdent())
  assert_eq(e.text, "a\nb\nc")
  assert_true(e.undo())
  assert_eq(e.text, "    a\n    b\nc")
  let tabs = @editor.Editor::new("\tfoo\n\tbar")
  assert_eq(tabs.indent_unit, "\t")
  let two = @editor.Editor::new("if x:\n  y\n  z")
  assert_eq(two.indent_unit, "  ")
}

///|
test "word deletion and smart home" {
  let e = @editor.Editor::new("  value = other")
  e.set_cursor(15)
  ignore(e.backspace(Word))
  assert_eq(e.text, "  value = ")
  e.move_cursor(LineStart)
  assert_eq(e.head, 2)
  e.move_cursor(LineStart)
  assert_eq(e.head, 0)
  e.set_cursor(2)
  ignore(e.delete_forward(Word))
  assert_eq(e.text, "   = ")
}

///|
test "surrogate pairs are one character" {
  let e = @editor.Editor::new("a😀b")
  e.set_cursor(1)
  e.move_cursor(Right)
  assert_eq(e.head, 3)
  ignore(e.backspace(Char))
  assert_eq(e.text, "ab")
  let pair = @editor.Editor::new("a😀b")
  pair.set_cursor(2)
  assert_eq(pair.head, 1)
}

///|
test "read only buffers reject edits but allow selection" {
  let e = @editor.Editor::new("keep")
  e.set_read_only(true)
  assert_false(e.insert("x"))
  e.select_all()
  assert_eq(e.selected_text(), "keep")
  assert_false(e.backspace(Char))
  assert_eq(e.text, "keep")
}

///|
test "select word and line" {
  let e = @editor.Editor::new("first(foo.bar)\nnext")
  e.select_word_at(11)
  assert_eq(e.selected_text(), "bar")
  e.select_line(0)
  assert_eq(e.selected_text(), "first(foo.bar)\n")
}
