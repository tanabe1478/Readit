// Text coordinates. MoonBit strings are UTF-16, like LSP positions and the
// public MCP columns, so offsets here are UTF-16 code unit indexes.

///|
/// A zero-based line and UTF-16 character, as LSP sends it.
pub(all) struct Position {
  line : Int
  character : Int
} derive(Eq, Debug)

///|
/// Offsets where each line starts. The last line may be empty.
pub fn line_starts(text : String) -> Array[Int] {
  let starts = [0]
  for i in 0..<text.length() {
    if text[i] == '\n' {
      starts.push(i + 1)
    }
  }
  starts
}

///|
/// The end of `line` (0-based), before any `\r\n` or `\n`.
pub fn line_end(text : String, starts : Array[Int], line : Int) -> Int {
  let end = if line + 1 < starts.length() {
    starts[line + 1] - 1
  } else {
    text.length()
  }
  if end > starts[line] && text[end - 1] == '\r' {
    end - 1
  } else {
    end
  }
}

///|
/// Convert the public, one-based UTF-16 coordinates without silently clamping.
pub fn offset_at(text : String, line : Int, column : Int) -> Int raise Failure {
  if line <= 0 || column <= 0 {
    fail("line and column are one-based")
  }
  let starts = line_starts(text)
  if line > starts.length() {
    fail("line is outside the file")
  }
  let start = starts[line - 1]
  let end = line_end(text, starts, line - 1)
  let offset = start + column - 1
  if offset > end {
    fail("column is outside the line")
  }
  if offset > start && offset < end && is_low_surrogate(text[offset]) {
    fail("column splits a UTF-16 character")
  }
  offset
}

///|
fn is_low_surrogate(unit : UInt16) -> Bool {
  unit.to_int() >= 0xDC00 && unit.to_int() <= 0xDFFF
}

///|
fn is_high_surrogate(unit : UInt16) -> Bool {
  unit.to_int() >= 0xD800 && unit.to_int() <= 0xDBFF
}

///|
/// Move an offset back to a character boundary.
pub fn char_boundary(text : String, offset : Int) -> Int {
  let at = offset.clamp(min=0, max=text.length())
  if at > 0 && at < text.length() && is_low_surrogate(text[at]) {
    at - 1
  } else {
    at
  }
}

///|
/// The LSP position of an offset. Offsets inside a surrogate pair move back.
pub fn position_at(text : String, offset : Int) -> Position {
  let at = char_boundary(text, offset)
  let mut line = 0
  let mut start = 0
  for i in 0..<at {
    if text[i] == '\n' {
      line += 1
      start = i + 1
    }
  }
  { line, character: at - start, }
}

///|
/// The offset of an LSP position, clamped to the line end and the text end.
pub fn offset_of(text : String, position : Position) -> Int {
  let starts = line_starts(text)
  if position.line >= starts.length() {
    return text.length()
  }
  let start = starts[position.line]
  let end = if position.line + 1 < starts.length() {
    starts[position.line + 1] - 1
  } else {
    text.length()
  }
  char_boundary(text, (start + position.character).clamp(min=start, max=end))
}

///|
/// Lines as Rust's `str::lines` returns them: no trailing empty line, no `\r`.
pub fn lines(text : String) -> Array[String] {
  let out = []
  if text.length() == 0 {
    return out
  }
  let mut start = 0
  for i in 0..<text.length() {
    if text[i] == '\n' {
      out.push(strip_cr(text, start, i))
      start = i + 1
    }
  }
  if start < text.length() {
    out.push(strip_cr(text, start, text.length()))
  }
  out
}

///|
fn strip_cr(text : String, start : Int, end : Int) -> String {
  let stop = if end > start && text[end - 1] == '\r' { end - 1 } else { end }
  text.unsafe_substring(start~, end=stop)
}

///|
/// Split on every `\n`, keeping a trailing empty piece, like Rust's `split('\n')`.
pub fn split_newlines(text : String) -> Array[String] {
  let out = []
  let mut start = 0
  for i in 0..<text.length() {
    if text[i] == '\n' {
      out.push(text.unsafe_substring(start~, end=i))
      start = i + 1
    }
  }
  out.push(text.unsafe_substring(start~, end=text.length()))
  out
}

///|
/// Number of Unicode characters, as Rust's `chars().count()` returns.
pub fn char_count(text : String) -> Int {
  let mut n = 0
  for i in 0..<text.length() {
    if !is_low_surrogate(text[i]) {
      n += 1
    }
  }
  n
}

///|
/// The first `count` characters.
pub fn take_chars(text : String, count : Int) -> String {
  let mut n = 0
  for i in 0..<text.length() {
    if !is_low_surrogate(text[i]) {
      if n == count {
        return text.unsafe_substring(start=0, end=i)
      }
      n += 1
    }
  }
  text
}

///|
/// Whether the code unit at `offset` begins a surrogate pair.
pub fn starts_pair(text : String, offset : Int) -> Bool {
  offset + 1 < text.length() &&
  is_high_surrogate(text[offset]) &&
  is_low_surrogate(text[offset + 1])
}

///|
/// Offset of the next character boundary after `offset`.
pub fn next_char(text : String, offset : Int) -> Int {
  if offset >= text.length() {
    text.length()
  } else if starts_pair(text, offset) {
    offset + 2
  } else {
    offset + 1
  }
}

///|
/// Offset of the previous character boundary before `offset`.
pub fn prev_char(text : String, offset : Int) -> Int {
  if offset <= 0 {
    0
  } else if offset >= 2 &&
    is_low_surrogate(text[offset - 1]) &&
    is_high_surrogate(text[offset - 2]) {
    offset - 2
  } else {
    offset - 1
  }
}

///|
/// The character starting at `offset`.
pub fn char_at(text : String, offset : Int) -> Char? {
  if offset < 0 || offset >= text.length() {
    None
  } else {
    text.get_char(offset)
  }
}

///|
/// A substring by UTF-16 offsets, clamped to the text.
pub fn slice(text : String, start : Int, end : Int) -> String {
  let s = start.clamp(min=0, max=text.length())
  let e = end.clamp(min=s, max=text.length())
  text.unsafe_substring(start=s, end=e)
}

///|
/// Find `needle` at or after `from`. Returns -1 when missing.
pub fn find_from(text : String, needle : String, from : Int) -> Int {
  if needle.length() == 0 {
    return from.clamp(min=0, max=text.length())
  }
  let limit = text.length() - needle.length()
  for i in from.clamp(min=0, max=text.length())..<=limit {
    let mut same = true
    for j in 0..<needle.length() {
      if text[i + j] != needle[j] {
        same = false
        break
      }
    }
    if same {
      return i
    }
  }
  -1
}

///|
/// All non-overlapping occurrences of `needle`.
pub fn find_all(text : String, needle : String) -> Array[Int] {
  let out = []
  if needle.length() == 0 {
    return out
  }
  let mut at = find_from(text, needle, 0)
  while at >= 0 {
    out.push(at)
    at = find_from(text, needle, at + needle.length())
  }
  out
}

///|
/// Replace every occurrence, like Rust's `str::replace`.
pub fn replace_all(
  text : String,
  needle : String,
  replacement : String,
) -> String {
  if needle.length() == 0 {
    return text
  }
  let out = StringBuilder()
  let mut last = 0
  for at in find_all(text, needle) {
    out.write_string(slice(text, last, at))
    out.write_string(replacement)
    last = at + needle.length()
  }
  out.write_string(slice(text, last, text.length()))
  out.to_string()
}

///|
pub fn contains(text : String, needle : String) -> Bool {
  find_from(text, needle, 0) >= 0
}

///|
pub fn starts_with(text : String, prefix : String) -> Bool {
  text.length() >= prefix.length() && slice(text, 0, prefix.length()) == prefix
}

///|
pub fn ends_with(text : String, suffix : String) -> Bool {
  text.length() >= suffix.length() &&
  slice(text, text.length() - suffix.length(), text.length()) == suffix
}

///|
/// Trim ASCII and Unicode whitespace at both ends.
pub fn trim(text : String) -> String {
  let mut start = 0
  let mut end = text.length()
  while start < end && is_space(text[start]) {
    start += 1
  }
  while end > start && is_space(text[end - 1]) {
    end -= 1
  }
  slice(text, start, end)
}

///|
fn is_space(unit : UInt16) -> Bool {
  let c = unit.to_int()
  c == 0x20 ||
  (c >= 0x09 && c <= 0x0D) ||
  c == 0x85 ||
  c == 0xA0 ||
  c == 0x3000 ||
  (c >= 0x2000 && c <= 0x200A) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202F ||
  c == 0x205F ||
  c == 0x1680 ||
  c == 0xFEFF
}

///|
/// Lower-case ASCII and common Latin letters for case-insensitive filters.
pub fn lower(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    let code = c.to_int()
    if code >= 'A'.to_int() && code <= 'Z'.to_int() {
      out.write_char(Int::unsafe_to_char(code + 32))
    } else if (code >= 0xC0 && code <= 0xDE && code != 0xD7) ||
      (code >= 0x391 && code <= 0x3A9) ||
      (code >= 0x410 && code <= 0x42F) {
      out.write_char(Int::unsafe_to_char(code + 32))
    } else if code >= 0xFF21 && code <= 0xFF3A {
      out.write_char(Int::unsafe_to_char(code + 32))
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Code point order, like Rust's `str` comparison. MoonBit's `String::compare`
/// orders by length first, which would misplace paths.
pub fn lex_compare(a : String, b : String) -> Int {
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    let x = code_point(a, i)
    let y = code_point(b, j)
    if x != y {
      return if x < y { -1 } else { 1 }
    }
    i = next_char(a, i)
    j = next_char(b, j)
  }
  if i < a.length() {
    1
  } else if j < b.length() {
    -1
  } else {
    0
  }
}

///|
fn code_point(text : String, offset : Int) -> Int {
  match text.get_char(offset) {
    Some(c) => c.to_int()
    None => text[offset].to_int()
  }
}

///|
/// Sort strings in code point order.
pub fn sort_strings(values : Array[String]) -> Unit {
  values.sort_by(lex_compare)
}

///|
/// Parse a non-negative decimal integer. Returns None for anything else.
pub fn parse_natural(text : String) -> Int? {
  if text.length() == 0 || text.length() > 9 {
    return None
  }
  let mut n = 0
  for i in 0..<text.length() {
    let c = text[i].to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    n = n * 10 + (c - '0'.to_int())
  }
  Some(n)
}

///|
/// Escape text for HTML element content and attribute values.
pub fn escape_html(text : String) -> String {
  let out = StringBuilder()
  for i in 0..<text.length() {
    match text[i] {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_string(text.unsafe_substring(start=i, end=i + 1))
    }
  }
  out.to_string()
}

///|
/// The message of a `fail(...)` error without its source location prefix.
pub fn failure_text(message : String) -> String {
  let marker = "FAILED: "
  let at = find_from(message, marker, 0)
  if at < 0 {
    message
  } else {
    slice(message, at + marker.length(), message.length())
  }
}
