// Editing model for one buffer. Offsets are UTF-16 code units.

///|
priv struct Change {
  start : Int
  removed : String
  inserted : String
}

///|
priv struct Group {
  changes : Array[Change]
  before : (Int, Int)
  mut after : (Int, Int)
  kind : String
}

///|
pub struct Editor {
  mut text : String
  mut starts : Array[Int]
  mut anchor : Int
  mut head : Int
  /// Column kept while moving vertically through shorter lines.
  mut goal : Int?
  priv undo_stack : Array[Group]
  priv redo_stack : Array[Group]
  priv mut merge : Bool
  /// Incremented on every text change, for caches and stale checks.
  mut version : Int
  mut read_only : Bool
  mut indent_unit : String
}

///|
pub fn Editor::new(text : String) -> Editor {
  {
    text,
    starts: @core.line_starts(text),
    anchor: 0,
    head: 0,
    goal: None,
    undo_stack: [],
    redo_stack: [],
    merge: false,
    version: 0,
    read_only: false,
    indent_unit: detect_indent(text),
  }
}

///|
/// Replace the whole value and forget history, like loading a file.
pub fn Editor::set_value(self : Editor, text : String) -> Unit {
  self.text = text
  self.starts = @core.line_starts(text)
  self.anchor = self.anchor.clamp(min=0, max=text.length())
  self.head = self.head.clamp(min=0, max=text.length())
  self.anchor = @core.char_boundary(text, self.anchor)
  self.head = @core.char_boundary(text, self.head)
  self.goal = None
  self.undo_stack.clear()
  self.redo_stack.clear()
  self.merge = false
  self.version += 1
  self.indent_unit = detect_indent(text)
}

///|
fn detect_indent(text : String) -> String {
  let starts = @core.line_starts(text)
  let mut tabs = 0
  let mut smallest = 0
  for i, start in starts {
    if i > 400 {
      break
    }
    if start < text.length() && text[start] == '\t' {
      tabs += 1
      continue
    }
    let mut n = 0
    while start + n < text.length() && text[start + n] == ' ' {
      n += 1
    }
    let rest = start + n
    if n > 0 &&
      rest < text.length() &&
      text[rest] != '\n' &&
      text[rest] != '\r' &&
      (smallest == 0 || n < smallest) {
      smallest = n
    }
  }
  if tabs > 0 && smallest == 0 {
    "\t"
  } else if smallest >= 2 && smallest <= 8 {
    " ".repeat(smallest)
  } else {
    "    "
  }
}

///|
/// External definitions open read-only; selection still works.
pub fn Editor::set_read_only(self : Editor, value : Bool) -> Unit {
  self.read_only = value
}

///|
pub fn Editor::line_count(self : Editor) -> Int {
  self.starts.length()
}

///|
pub fn Editor::line_start(self : Editor, line : Int) -> Int {
  self.starts[line.clamp(min=0, max=self.starts.length() - 1)]
}

///|
/// End of a line before its line break.
pub fn Editor::line_end(self : Editor, line : Int) -> Int {
  @core.line_end(
    self.text,
    self.starts,
    line.clamp(min=0, max=self.starts.length() - 1),
  )
}

///|
pub fn Editor::line_text(self : Editor, line : Int) -> String {
  @core.slice(self.text, self.line_start(line), self.line_end(line))
}

///|
/// The line containing an offset.
pub fn Editor::line_of(self : Editor, offset : Int) -> Int {
  let mut low = 0
  let mut high = self.starts.length() - 1
  while low < high {
    let mid = (low + high + 1) / 2
    if self.starts[mid] <= offset {
      low = mid
    } else {
      high = mid - 1
    }
  }
  low
}

///|
/// Zero-based line and UTF-16 column of the cursor.
pub fn Editor::position(self : Editor) -> @core.Position {
  let line = self.line_of(self.head)
  { line, character: self.head - self.starts[line], }
}

///|
pub fn Editor::offset_at(self : Editor, line : Int, column : Int) -> Int {
  let l = line.clamp(min=0, max=self.starts.length() - 1)
  let start = self.starts[l]
  @core.char_boundary(
    self.text,
    (start + column).clamp(min=start, max=self.line_end(l)),
  )
}

///|
/// The ordered selection range.
pub fn Editor::selection(self : Editor) -> (Int, Int) {
  if self.anchor <= self.head {
    (self.anchor, self.head)
  } else {
    (self.head, self.anchor)
  }
}

///|
pub fn Editor::has_selection(self : Editor) -> Bool {
  self.anchor != self.head
}

///|
pub fn Editor::selected_text(self : Editor) -> String {
  let (start, end) = self.selection()
  @core.slice(self.text, start, end)
}

///|
/// Place the cursor, optionally extending the selection from its anchor.
pub fn Editor::set_cursor(
  self : Editor,
  offset : Int,
  selecting? : Bool = false,
) -> Unit {
  let at = @core.char_boundary(self.text, offset)
  self.head = at
  if !selecting {
    self.anchor = at
  }
  self.goal = None
  self.merge = false
}

///|
/// Select [anchor, head) exactly; head is where the cursor shows.
pub fn Editor::select(self : Editor, anchor : Int, head : Int) -> Unit {
  self.anchor = @core.char_boundary(self.text, anchor)
  self.head = @core.char_boundary(self.text, head)
  self.goal = None
  self.merge = false
}

///|
pub fn Editor::select_all(self : Editor) -> Unit {
  self.select(0, self.text.length())
}

///|
/// Select the identifier or the run of punctuation at `offset`.
pub fn Editor::select_word_at(self : Editor, offset : Int) -> Unit {
  match @core.symbol_range(self.text, offset) {
    Some((start, end)) => self.select(start, end)
    None =>
      match @core.symbol_range(self.text, @core.prev_char(self.text, offset)) {
        Some((start, end)) if offset > 0 => self.select(start, end)
        _ => self.set_cursor(offset)
      }
  }
}

///|
/// Select a whole line including its line break.
pub fn Editor::select_line(self : Editor, line : Int) -> Unit {
  let start = self.line_start(line)
  let end = if line + 1 < self.line_count() {
    self.line_start(line + 1)
  } else {
    self.text.length()
  }
  self.select(start, end)
}

///|
fn Editor::apply(self : Editor, change : Change) -> Unit {
  self.text = @core.slice(self.text, 0, change.start) +
    change.inserted +
    @core.slice(
      self.text,
      change.start + change.removed.length(),
      self.text.length(),
    )
  self.starts = @core.line_starts(self.text)
  self.version += 1
}

///|
fn Editor::record(
  self : Editor,
  changes : Array[Change],
  before : (Int, Int),
  after : (Int, Int),
  kind : String,
) -> Unit {
  self.redo_stack.clear()
  if self.merge && (kind == "type" || kind == "delete") {
    match self.undo_stack.last() {
      Some(last) if last.kind == kind && last.after == before => {
        for c in changes {
          last.changes.push(c)
        }
        last.after = after
        return
      }
      _ => ()
    }
  }
  self.undo_stack.push({ changes, before, after, kind, })
  if self.undo_stack.length() > 1000 {
    self.undo_stack.remove(0) |> ignore
  }
}

///|
/// Replace [start, end) with `text`, as one undoable step.
pub fn Editor::replace_range(
  self : Editor,
  start : Int,
  end : Int,
  text : String,
  kind? : String = "edit",
) -> Bool {
  if self.read_only {
    return false
  }
  let s = @core.char_boundary(
    self.text,
    start.clamp(min=0, max=self.text.length()),
  )
  let e = @core.char_boundary(
    self.text,
    end.clamp(min=s, max=self.text.length()),
  )
  let removed = @core.slice(self.text, s, e)
  if removed == text {
    return false
  }
  let before = (self.anchor, self.head)
  self.apply({ start: s, removed, inserted: text, })
  let cursor = s + text.length()
  self.anchor = cursor
  self.head = cursor
  self.goal = None
  self.record(
    [{ start: s, removed, inserted: text, }],
    before,
    (cursor, cursor),
    kind,
  )
  self.merge = kind == "type" || kind == "delete"
  true
}

///|
/// Type text over the selection. Consecutive typing is one undo step.
pub fn Editor::insert(self : Editor, text : String) -> Bool {
  let (start, end) = self.selection()
  let kind = if end == start &&
    !@core.contains(text, "\n") &&
    text.length() <= 4 {
    "type"
  } else {
    "edit"
  }
  self.replace_range(start, end, text, kind~)
}

///|
/// Insert a line break keeping the current line's indentation.
pub fn Editor::newline(self : Editor) -> Bool {
  let (start, _) = self.selection()
  let line = self.line_of(start)
  let line_start = self.line_start(line)
  let mut n = 0
  while line_start + n < start &&
        (self.text[line_start + n] == ' ' || self.text[line_start + n] == '\t') {
    n += 1
  }
  let indent = @core.slice(self.text, line_start, line_start + n)
  let (s, e) = self.selection()
  self.replace_range(s, e, "\n" + indent)
}

///|
pub(all) enum Amount {
  Char
  Word
  Line
}

///|
/// ⌫: delete the selection, or a character, word or line before the cursor.
pub fn Editor::backspace(self : Editor, by : Amount) -> Bool {
  if self.has_selection() {
    let (s, e) = self.selection()
    return self.replace_range(s, e, "")
  }
  let at = self.head
  let from = match by {
    Char => @core.prev_char(self.text, at)
    Word => @core.word_left(self.text, at)
    Line => {
      let line_start = self.line_start(self.line_of(at))
      if line_start == at {
        @core.prev_char(self.text, at)
      } else {
        line_start
      }
    }
  }
  if from == at {
    return false
  }
  self.replace_range(from, at, "", kind="delete")
}

///|
/// ⌦: delete the selection, or a character, word or line after the cursor.
pub fn Editor::delete_forward(self : Editor, by : Amount) -> Bool {
  if self.has_selection() {
    let (s, e) = self.selection()
    return self.replace_range(s, e, "")
  }
  let at = self.head
  let to = match by {
    Char =>
      if at < self.text.length() &&
        self.text[at] == '\r' &&
        at + 1 < self.text.length() &&
        self.text[at + 1] == '\n' {
        at + 2
      } else {
        @core.next_char(self.text, at)
      }
    Word => @core.word_right(self.text, at)
    Line => {
      let end = self.line_end(self.line_of(at))
      if end == at {
        @core.next_char(self.text, at)
      } else {
        end
      }
    }
  }
  if to == at {
    return false
  }
  let changed = self.replace_range(at, to, "", kind="delete")
  self.anchor = at
  self.head = at
  changed
}

///|
pub(all) enum Motion {
  Left
  Right
  WordLeft
  WordRight
  LineStart
  LineEnd
  Up
  Down
  DocStart
  DocEnd
  PageUp(Int)
  PageDown(Int)
}

///|
/// Move the cursor, extending the selection when `selecting` is set.
pub fn Editor::move_cursor(
  self : Editor,
  motion : Motion,
  selecting? : Bool = false,
) -> Unit {
  let (start, end) = self.selection()
  let collapse = self.has_selection() && !selecting
  let target = match motion {
    Left => if collapse { start } else { self.step_left(self.head) }
    Right => if collapse { end } else { self.step_right(self.head) }
    WordLeft => @core.word_left(self.text, self.head)
    WordRight => @core.word_right(self.text, self.head)
    LineStart => self.smart_home(self.head)
    LineEnd => self.line_end(self.line_of(self.head))
    Up => return self.vertical(-1, selecting)
    Down => return self.vertical(1, selecting)
    PageUp(n) => return self.vertical(-n.clamp(min=1, max=100000), selecting)
    PageDown(n) => return self.vertical(n.clamp(min=1, max=100000), selecting)
    DocStart => 0
    DocEnd => self.text.length()
  }
  self.head = target
  if !selecting {
    self.anchor = target
  }
  self.goal = None
  self.merge = false
}

///|
fn Editor::step_left(self : Editor, at : Int) -> Int {
  let p = @core.prev_char(self.text, at)
  // Step over \r\n as one line break.
  if p > 0 && self.text[p] == '\n' && self.text[p - 1] == '\r' {
    p - 1
  } else {
    p
  }
}

///|
fn Editor::step_right(self : Editor, at : Int) -> Int {
  if at < self.text.length() &&
    self.text[at] == '\r' &&
    at + 1 < self.text.length() &&
    self.text[at + 1] == '\n' {
    at + 2
  } else {
    @core.next_char(self.text, at)
  }
}

///|
fn Editor::smart_home(self : Editor, at : Int) -> Int {
  let line = self.line_of(at)
  let start = self.line_start(line)
  let end = self.line_end(line)
  let mut first = start
  while first < end && (self.text[first] == ' ' || self.text[first] == '\t') {
    first += 1
  }
  if at == first {
    start
  } else {
    first
  }
}

///|
fn Editor::vertical(self : Editor, delta : Int, selecting : Bool) -> Unit {
  let line = self.line_of(self.head)
  let goal = match self.goal {
    Some(g) => g
    None => self.head - self.starts[line]
  }
  let target_line = line + delta
  let target = if target_line < 0 {
    0
  } else if target_line >= self.line_count() {
    self.text.length()
  } else {
    self.offset_at(target_line, goal)
  }
  self.head = target
  if !selecting {
    self.anchor = target
  }
  self.goal = Some(goal)
  self.merge = false
}

///|
/// Indent the selected lines, or insert one indent unit at the cursor.
pub fn Editor::indent(self : Editor) -> Bool {
  let (start, end) = self.selection()
  let first = self.line_of(start)
  let last = self.last_selected_line(start, end)
  if first == last && start == end {
    return self.replace_range(start, end, self.indent_unit)
  }
  self.edit_lines(first, last, line => self.indent_unit + line)
}

///|
/// Remove one indent unit from each selected line.
pub fn Editor::outdent(self : Editor) -> Bool {
  let (start, end) = self.selection()
  let first = self.line_of(start)
  let last = self.last_selected_line(start, end)
  let unit = self.indent_unit
  self.edit_lines(first, last, line => {
    if @core.starts_with(line, unit) {
      @core.slice(line, unit.length(), line.length())
    } else if @core.starts_with(line, "\t") {
      @core.slice(line, 1, line.length())
    } else {
      let mut n = 0
      while n < line.length() && n < unit.length() && line[n] == ' ' {
        n += 1
      }
      @core.slice(line, n, line.length())
    }
  })
}

///|
fn Editor::last_selected_line(self : Editor, start : Int, end : Int) -> Int {
  let last = self.line_of(end)
  // A selection ending at column 0 does not include that line.
  if end > start && self.line_start(last) == end {
    last - 1
  } else {
    last
  }
}

///|
fn Editor::edit_lines(
  self : Editor,
  first : Int,
  last : Int,
  f : (String) -> String,
) -> Bool {
  if self.read_only {
    return false
  }
  let from = self.line_start(first)
  let to = self.line_end(last)
  let pieces = []
  for line in first..<=last {
    let text = self.line_text(line)
    let ending = if line < last {
      @core.slice(self.text, self.line_end(line), self.line_start(line + 1))
    } else {
      ""
    }
    pieces.push(f(text) + ending)
  }
  let replacement = pieces.join("")
  let removed = @core.slice(self.text, from, to)
  if removed == replacement {
    return false
  }
  let before = (self.anchor, self.head)
  self.apply({ start: from, removed, inserted: replacement, })
  // Keep the whole block selected so repeated Tab keeps working.
  let block_end = from + replacement.length()
  self.anchor = from
  self.head = block_end
  self.goal = None
  self.record(
    [{ start: from, removed, inserted: replacement, }],
    before,
    (from, block_end),
    "edit",
  )
  self.merge = false
  true
}

///|
pub fn Editor::can_undo(self : Editor) -> Bool {
  self.undo_stack.length() > 0
}

///|
pub fn Editor::undo(self : Editor) -> Bool {
  guard self.undo_stack.pop() is Some(group) else { return false }
  for i = group.changes.length() - 1; i >= 0; i = i - 1 {
    let c = group.changes[i]
    self.apply({ start: c.start, removed: c.inserted, inserted: c.removed, })
  }
  let (a, h) = group.before
  self.anchor = a
  self.head = h
  self.goal = None
  self.merge = false
  self.redo_stack.push(group)
  true
}

///|
pub fn Editor::redo(self : Editor) -> Bool {
  guard self.redo_stack.pop() is Some(group) else { return false }
  for c in group.changes {
    self.apply(c)
  }
  let (a, h) = group.after
  self.anchor = a
  self.head = h
  self.goal = None
  self.merge = false
  self.undo_stack.push(group)
  true
}

///|
/// End the current typing group so the next keystroke undoes separately.
pub fn Editor::break_undo_group(self : Editor) -> Unit {
  self.merge = false
}
