///|
/// Letters and digits in identifiers. MoonBit's core has no Unicode letter
/// table, so non-ASCII characters count unless they are spaces, punctuation or
/// symbols from the common blocks (CJK punctuation, arrows, box drawing, emoji).
pub fn is_word_char(c : Char) -> Bool {
  let code = c.to_int()
  if code < 0x80 {
    return (code >= '0'.to_int() && code <= '9'.to_int()) ||
      (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int())
  }
  !(code <= 0xBF ||
  code == 0xD7 ||
  code == 0xF7 ||
  (code >= 0x2000 && code <= 0x2BFF) ||
  (code >= 0x3000 && code <= 0x303F) ||
  (code >= 0xFE10 && code <= 0xFE6F) ||
  (code >= 0xFF00 && code <= 0xFF0F) ||
  (code >= 0xFF1A && code <= 0xFF20) ||
  (code >= 0xFF3B && code <= 0xFF40) ||
  (code >= 0xFF5B && code <= 0xFF65) ||
  (code >= 0xFFF0 && code <= 0xFFFF) ||
  (code >= 0x1F000 && code <= 0x1FAFF) ||
  (code >= 0xE000 && code <= 0xF8FF))
}

///|
pub fn is_symbol_char(c : Char) -> Bool {
  c == '_' || is_word_char(c)
}

///|
/// The identifier containing the character at `offset`, as [start, end).
pub fn symbol_range(text : String, offset : Int) -> (Int, Int)? {
  if offset < 0 ||
    offset >= text.length() ||
    char_boundary(text, offset) != offset {
    return None
  }
  guard char_at(text, offset) is Some(c) && is_symbol_char(c) else {
    return None
  }
  let mut start = offset
  while start > 0 {
    let previous = prev_char(text, start)
    guard char_at(text, previous) is Some(p) && is_symbol_char(p) else { break }
    start = previous
  }
  let mut end = offset
  while end < text.length() {
    guard char_at(text, end) is Some(n) && is_symbol_char(n) else { break }
    end = next_char(text, end)
  }
  Some((start, end))
}

///|
/// The start of the word before `offset`, for ⌥← and ⌥⌫.
pub fn word_left(text : String, offset : Int) -> Int {
  let mut at = offset
  while at > 0 {
    let p = prev_char(text, at)
    guard char_at(text, p) is Some(c) && (c == ' ' || c == '\t') else { break }
    at = p
  }
  if at > 0 {
    let p = prev_char(text, at)
    let kind = char_kind(char_at(text, p))
    while at > 0 {
      let q = prev_char(text, at)
      if char_kind(char_at(text, q)) != kind || kind == 3 {
        break
      }
      at = q
    }
    if at == offset {
      at = p
    }
  }
  at
}

///|
/// The end of the word after `offset`, for ⌥→ and ⌥⌦.
pub fn word_right(text : String, offset : Int) -> Int {
  let mut at = offset
  while at < text.length() {
    guard char_at(text, at) is Some(c) && (c == ' ' || c == '\t') else { break }
    at = next_char(text, at)
  }
  if at < text.length() {
    let kind = char_kind(char_at(text, at))
    let first = at
    while at < text.length() {
      if char_kind(char_at(text, at)) != kind || kind == 3 {
        break
      }
      at = next_char(text, at)
    }
    if at == first {
      at = next_char(text, at)
    }
  }
  at
}

///|
/// 0 identifier, 1 punctuation, 2 space, 3 newline.
fn char_kind(c : Char?) -> Int {
  match c {
    Some('\n') | Some('\r') => 3
    Some(' ') | Some('\t') => 2
    Some(ch) => if is_symbol_char(ch) { 0 } else { 1 }
    None => 3
  }
}
