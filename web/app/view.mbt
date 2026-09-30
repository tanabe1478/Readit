// Code views: the main editor, the pinned panel and small previews.

///|
fn line_height() -> Double {
  (reader.font_size * 1.6).round()
}

///|
fn e(text : String) -> String {
  @core.escape_html(text)
}

///|
/// Highlight spans for rendered lines, keyed by line.
fn tokens_for(
  key : String,
  first : Int,
  last : Int,
) -> Map[Int, Array[(Int, Int, String)]] {
  let out : Map[Int, Array[(Int, Int, String)]] = Map([])
  let encoded = js_ts_tokens(key, first, last)
  if encoded == "" {
    return out
  }
  for item in encoded.split(";") {
    let parts = item.split(",").map(p => p.to_owned()).collect()
    guard parts is [l, s, en, cls] else { continue }
    guard @core.parse_natural(l) is Some(line) &&
      @core.parse_natural(s) is Some(start) &&
      @core.parse_natural(en) is Some(end) else {
      continue
    }
    match out.get(line) {
      Some(list) => list.push((start, end, cls))
      None => out[line] = [(start, end, cls)]
    }
  }
  out
}

///|
/// One line of code as HTML: syntax spans, marks (selection, matches) and caret.
fn line_html(
  text : String,
  tokens : Array[(Int, Int, String)],
  marks : Array[(Int, Int, String)],
  caret : Int?,
) -> String {
  let len = text.length()
  let bounds : Array[Int] = [0, len]
  for t in tokens {
    bounds.push(t.0.clamp(min=0, max=len))
    bounds.push(t.1.clamp(min=0, max=len))
  }
  for m in marks {
    bounds.push(m.0.clamp(min=0, max=len))
    bounds.push(m.1.clamp(min=0, max=len))
  }
  if caret is Some(c) {
    bounds.push(c.clamp(min=0, max=len))
  }
  bounds.sort()
  let out = StringBuilder()
  let mut previous = -1
  for b in bounds {
    if b == previous {
      continue
    }
    if previous >= 0 && b > previous {
      let classes = []
      for t in tokens {
        if t.0 <= previous && t.1 >= b {
          classes.push(t.2)
          break
        }
      }
      for m in marks {
        if m.0 <= previous && m.1 >= b {
          classes.push(m.2)
        }
      }
      let piece = e(@core.slice(text, previous, b))
      if classes.length() == 0 {
        out.write_string(piece)
      } else {
        out.write_string("<span class=\"\{classes.join(" ")}\">\{piece}</span>")
      }
    }
    if caret == Some(b) {
      out.write_string("<span class=\"caret\"></span>")
    }
    previous = b
  }
  out.to_string()
}

///|
priv struct CodeOptions {
  view : String
  key : String
  language : String
  editor : @editor.Editor
  caret : Bool
  matches : Array[(Int, Int)]
  current_match : Int
  link : (Int, Int)?
  numbers : Bool
  wrap : Bool
  scroll_top : Double
  height : Double
}

///|
/// Rows for the visible part of a code view (every row when wrapping).
fn code_rows(o : CodeOptions, layout : Layout) -> String {
  let ed = o.editor
  let lh = line_height()
  let count = ed.line_count()
  let first = (layout.line_at(o.scroll_top) - 20).clamp(min=0, max=count - 1)
  let last = (layout.line_at(o.scroll_top + o.height.max(400.0)) + 20).clamp(
    min=0,
    max=count - 1,
  )
  // Matches are ordered; start at the first one that can touch the rendered lines.
  let first_offset = ed.line_start(first)
  let mut match_from = 0
  let mut high = o.matches.length()
  while match_from < high {
    let mid = (match_from + high) / 2
    if o.matches[mid].1 <= first_offset {
      match_from = mid + 1
    } else {
      high = mid
    }
  }
  if js_ts_update(o.key, o.language, ed.text) {
    ()
  }
  let tokens = tokens_for(o.key, first, last + 1)
  let (sel_start, sel_end) = ed.selection()
  let caret_line = ed.line_of(ed.head)
  let out = StringBuilder()
  for i in first..<=last {
    let start = ed.line_start(i)
    let end = ed.line_end(i)
    let text = @core.slice(ed.text, start, end)
    let marks = []
    if sel_start < sel_end && sel_start <= end && sel_end >= start {
      let s = (sel_start - start).max(0)
      let t = (sel_end - start).min(text.length())
      if t > s {
        marks.push((s, t, "sel"))
      }
    }
    for mi in match_from..<o.matches.length() {
      let (ms, me) = o.matches[mi]
      if ms > end {
        break
      }
      if me > start {
        marks.push(
          (
            (ms - start).max(0),
            (me - start).min(text.length()),
            if mi == o.current_match {
              "match current"
            } else {
              "match"
            },
          ),
        )
      }
    }
    if o.link is Some((ls, le)) && ls >= start && ls <= end {
      marks.push((ls - start, (le - start).min(text.length()), "link"))
    }
    let caret = if o.caret && i == caret_line {
      Some(ed.head - start)
    } else {
      None
    }
    let eol = if sel_start < sel_end &&
      sel_start <= end &&
      sel_end > end &&
      i + 1 < count {
      "<span class=\"sel eol\"> </span>"
    } else {
      ""
    }
    let active = if o.caret && i == caret_line && sel_start == sel_end {
      " active"
    } else {
      ""
    }
    let style = if o.wrap { "" } else { " style=\"top:\{px(layout.top(i))}\"" }
    let gutter = if o.numbers {
      "<span class=\"gut\">\{i + 1}</span>"
    } else {
      ""
    }
    out.write_string(
      "<div class=\"row\{active}\" data-line=\"\{i}\"\{style}>\{gutter}<span class=\"code\">\{line_html(text, tokens.get(i).unwrap_or([]), marks, caret)}\{eol}</span></div>",
    )
  }
  let digits = gutter_columns(count) - 2
  let rows = if o.wrap {
    // Spacers stand in for rows outside the window, at their estimated heights.
    "<div style=\"height:\{px(layout.top(first))}\"></div>\{out.to_string()}<div style=\"height:\{px(layout.height() - layout.top(last + 1))}\"></div>"
  } else {
    out.to_string()
  }
  let size = if o.wrap {
    ""
  } else {
    "height:\{px(layout.height())};min-width:calc(\{layout.widest + gutter_columns(count) + 4}ch + 8px);"
  }
  "<div class=\"lines\{if o.wrap { " wrap" } else { "" }}\{if o.numbers { "" } else { " bare" }}\" data-view=\"\{o.view}\" data-lh=\"\{lh}\" style=\"\{size}--gutter:\{digits + 2}ch;--lh:\{px(lh)};font-size:\{px(reader.font_size)}\">\{rows}</div>"
}

///|
/// Plain highlighted snippet (hover and navigation previews).
fn snippet_html(key : String, language : String, text : String) -> String {
  let ed = @editor.Editor::new(text)
  let _ = js_ts_update(key, language, text)
  let tokens = tokens_for(key, 0, ed.line_count())
  let out = StringBuilder()
  for i in 0..<ed.line_count() {
    let line = ed.line_text(i)
    out.write_string(
      "<div class=\"snippet-line\">\{line_html(line, tokens.get(i).unwrap_or([]), [], None)}</div>",
    )
  }
  out.to_string()
}

///|
/// Scroll the main editor to a line after the next render.
fn request_reveal(line : Int, mode : Int) -> Unit {
  reader_reveal.val = Some((line, mode))
}

///|
let reader_reveal : Ref[(Int, Int)?] = Ref(None)

///|
let restore_scroll_to : Ref[Double?] = Ref(None)

///|
fn restore_scroll(top : Double) -> Unit {
  restore_scroll_to.val = Some(top)
}

///|
/// The scroll position the main editor should render at. Rows are rendered for
/// it first and the DOM scroll is set afterwards, so a taller document is never
/// clamped to the previous document's height.
fn editor_scroll_target(layout : Layout) -> Double {
  let current = js_scroll_top("editor-scroll")
  let base = match restore_scroll_to.val {
    Some(top) => {
      restore_scroll_to.val = None
      top
    }
    None => current
  }
  guard reader_reveal.val is Some((line, mode)) else { return base }
  reader_reveal.val = None
  let lh = line_height()
  let height = js_client_height("editor-scroll")
  let y = layout.top(line)
  let row = layout.top(line + 1) - y
  match mode {
    1 => (y - lh).max(0.0)
    2 => (y - height / 2.0 + lh).max(0.0)
    _ =>
      if y < base {
        y
      } else if y + row > base + height {
        (y + row + lh - height).max(0.0)
      } else {
        base
      }
  }
}

///|
/// Recompute in-file search matches when the query, options or text change.
fn refresh_search() -> Unit {
  guard current_editor() is Some(ed) else {
    reader.search_matches = []
    return
  }
  let key = "\{reader.selected.unwrap_or("")}\n\{ed.version}\n\{reader.search_query}\n\{reader.search_case}\n\{reader.search_regex}"
  if key == reader.search_key {
    return
  }
  reader.search_key = key
  reader.search_error = ""
  reader.search_matches = []
  if !reader.search_open || reader.search_query == "" {
    return
  }
  if reader.search_regex {
    let found = js_regex_find(
      ed.text,
      reader.search_query,
      if reader.search_case {
        "g"
      } else {
        "gi"
      },
    )
    if @core.starts_with(found, "!") {
      reader.search_error = @core.slice(found, 1, found.length())
      return
    }
    if found != "" {
      for pair in found.split(";") {
        match numbers(pair.to_owned()) {
          [s, t] => reader.search_matches.push((s.to_int(), t.to_int()))
          _ => ()
        }
      }
    }
  } else {
    let hay = if reader.search_case { ed.text } else { @core.lower(ed.text) }
    let needle = if reader.search_case {
      reader.search_query
    } else {
      @core.lower(reader.search_query)
    }
    // Lower-casing keeps UTF-16 lengths for the letters it changes.
    for at in @core.find_all(hay, needle) {
      reader.search_matches.push((at, at + needle.length()))
      if reader.search_matches.length() >= 5000 {
        break
      }
    }
  }
  if reader.search_index >= reader.search_matches.length() {
    reader.search_index = 0
  }
}

///|
fn open_search() -> Unit {
  reader.compare = false
  reader.search_open = true
  reader.focus = "search"
  if current_editor() is Some(ed) &&
    ed.has_selection() &&
    !@core.contains(ed.selected_text(), "\n") {
    reader.search_query = ed.selected_text()
    js_set_value("search-input", reader.search_query)
  }
  reader.search_key = ""
  js_select_input("search-input")
}

///|
fn search_step(forward : Bool) -> Unit {
  refresh_search()
  guard current_editor() is Some(ed) else { return }
  let n = reader.search_matches.length()
  if n == 0 {
    return
  }
  let (_, head) = ed.selection()
  let mut index = -1
  if forward {
    for i, m in reader.search_matches {
      if m.0 >= head {
        index = i
        break
      }
    }
    if index < 0 {
      index = 0
    }
  } else {
    let (start, _) = ed.selection()
    for i = n - 1; i >= 0; i = i - 1 {
      if reader.search_matches[i].1 < start + 1 &&
        reader.search_matches[i].0 < start {
        index = i
        break
      }
    }
    if index < 0 {
      index = n - 1
    }
  }
  reader.search_index = index
  let (s, t) = reader.search_matches[index]
  ed.select(s, t)
  request_reveal(ed.line_of(s), 2)
}
