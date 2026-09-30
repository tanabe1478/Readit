// Row geometry of code views. Without wrapping every row is one line tall; with
// wrapping, heights are estimated from monospace columns so only the visible
// rows need to exist in the DOM.

///|
fn js_char_width(font_px : Double) -> Double = "dom" "char_width"

///|
priv struct Layout {
  key : String
  wrap : Bool
  line_height : Double
  /// Top of each row (wrapping only), with the total height at the end.
  tops : Array[Double]
  /// Widest line in monospace columns.
  widest : Int
  count : Int
}

///|
let layouts : Map[String, Layout] = Map([])

///|
/// East Asian wide characters and emoji take two monospace cells.
fn wide(code : Int) -> Bool {
  (code >= 0x1100 && code <= 0x115F) ||
  (code >= 0x2E80 && code <= 0xA4CF) ||
  (code >= 0xAC00 && code <= 0xD7A3) ||
  (code >= 0xF900 && code <= 0xFAFF) ||
  (code >= 0xFE30 && code <= 0xFE4F) ||
  (code >= 0xFF00 && code <= 0xFF60) ||
  (code >= 0xFFE0 && code <= 0xFFE6) ||
  (code >= 0x1F300 && code <= 0x1FAFF) ||
  code >= 0x20000
}

///|
/// Display columns of text[start, end), with tabs every four columns.
fn columns(text : String, start : Int, end : Int) -> Int {
  let mut cols = 0
  let mut i = start
  while i < end {
    let unit = text[i].to_int()
    if unit == 9 {
      cols = (cols / 4 + 1) * 4
      i += 1
    } else if unit < 0x80 {
      cols += 1
      i += 1
    } else {
      let code = match text.get_char(i) {
        Some(c) => c.to_int()
        None => unit
      }
      cols += if wide(code) { 2 } else { 1 }
      i = @core.next_char(text, i)
    }
  }
  cols
}

///|
fn gutter_columns(count : Int) -> Int {
  count.to_string().length().max(3) + 2
}

///|
/// Geometry for one view's document, recomputed when the text, width or font changes.
fn layout_for(
  view : String,
  key : String,
  ed : @editor.Editor,
  wrap : Bool,
  width : Double,
) -> Layout {
  let lh = line_height()
  let id = "\{key}|\{ed.version}|\{wrap}|\{if wrap { width } else { 0.0 }}|\{reader.font_size}|\{ed.line_count()}|\{ed.text.length()}"
  if layouts.get(view) is Some(l) && l.key == id {
    return l
  }
  let count = ed.line_count()
  let tops : Array[Double] = []
  let mut widest = 0
  let ch = js_char_width(reader.font_size).max(1.0)
  let per_row = ((width - gutter_columns(count).to_double() * ch - 8.0) / ch)
    .floor()
    .to_int()
    .max(8)
  let mut y = 0.0
  for i in 0..<count {
    let cols = columns(ed.text, ed.line_start(i), ed.line_end(i))
    if cols > widest {
      widest = cols
    }
    if wrap {
      tops.push(y)
      let rows = ((cols + per_row - 1) / per_row).max(1)
      y += rows.to_double() * lh
    }
  }
  if wrap {
    tops.push(y)
  }
  let layout = { key: id, wrap, line_height: lh, tops, widest, count, }
  layouts[view] = layout
  layout
}

///|
fn Layout::top(self : Layout, line : Int) -> Double {
  if self.wrap {
    self.tops[line.clamp(min=0, max=self.tops.length() - 1)]
  } else {
    line.to_double() * self.line_height
  }
}

///|
fn Layout::height(self : Layout) -> Double {
  if self.wrap {
    self.tops[self.tops.length() - 1]
  } else {
    self.count.to_double() * self.line_height
  }
}

///|
/// The line whose row covers `y`.
fn Layout::line_at(self : Layout, y : Double) -> Int {
  if !self.wrap {
    return (y / self.line_height)
      .floor()
      .to_int()
      .clamp(min=0, max=(self.count - 1).max(0))
  }
  let mut low = 0
  let mut high = self.count - 1
  while low < high {
    let mid = (low + high + 1) / 2
    if self.tops[mid] <= y {
      low = mid
    } else {
      high = mid - 1
    }
  }
  low.max(0)
}
