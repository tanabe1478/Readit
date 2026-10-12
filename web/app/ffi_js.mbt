// The browser double for the JS target. Unit tests run the whole app on Node
// against these imports: they record what the page would show and queue the
// server calls and timers for the test to answer. ffi.mbt is the browser
// version with the same signatures; fake_js.mbt lets tests look inside.

///|
extern "js" fn js_set_html(id : String, html : String) = "(id, html) => { globalThis.__fake.html.set(id, html); }"

///|
extern "js" fn js_set_style(id : String, property : String, value : String) = "(id, p, v) => { globalThis.__fake.styles.set(id + '.' + p, v); }"

///|
extern "js" fn js_set_class(id : String, name : String, on : Bool) = "(id, n, on) => { const k = id + '.' + n; if (on) globalThis.__fake.classes.add(k); else globalThis.__fake.classes.delete(k); }"

///|
extern "js" fn js_focus(id : String) = "(id) => { globalThis.__fake.focused = id; }"

///|
extern "js" fn js_has_focus(id : String) -> Bool = "(id) => id === globalThis.__fake.focused"

///|
extern "js" fn js_set_value(id : String, value : String) = "(id, v) => { globalThis.__fake.values.set(id, v); }"

///|
extern "js" fn js_get_value(id : String) -> String = "(id) => globalThis.__fake.values.get(id) ?? ''"

///|
extern "js" fn js_select_input(id : String) = "(id) => { globalThis.__fake.focused = id; }"

///|
extern "js" fn js_scroll_top(id : String) -> Double = "(id) => globalThis.__fake.scroll.get(id) ?? 0"

///|
extern "js" fn js_set_scroll_top(id : String, value : Double) = "(id, v) => { globalThis.__fake.scroll.set(id, v); }"

///|
extern "js" fn js_client_height(id : String) -> Double = "(id) => globalThis.__fake.sizes.get(id + '.h') ?? 800"

///|
extern "js" fn js_client_width(id : String) -> Double = "(id) => globalThis.__fake.sizes.get(id + '.w') ?? 1000"

///|
extern "js" fn js_natural_height(id : String) -> Double = "(id) => globalThis.__fake.sizes.get(id + '.natural') ?? 240"

///|
/// Elements have a box unless a test removes it with fake_set_rect(id, "").
extern "js" fn js_rect(id : String) -> String = "(id) => { const r = globalThis.__fake.rects.get(id); return r === undefined ? '0,0,1000,800' : r; }"

///|
/// Every code range sits on a visible row 24px tall; tests may hide one view.
extern "js" fn js_range_rect(
  view : String,
  line : Int,
  start : Int,
  end : Int,
) -> String = "(view, line, start, end) => globalThis.__fake.hidden.has(view) ? '' : [300, 100 + line * 24, 8 * Math.max(1, end - start), 24].join(',')"

///|
extern "js" fn js_rows_right(view : String, first : Int, last : Int) -> Double = "() => 700"

///|
extern "js" fn js_place_input() = "() => {}"

///|
extern "js" fn js_scroll_into_view(id : String) = "() => {}"

///|
extern "js" fn js_viewport_width() -> Double = "() => globalThis.__fake.viewport[0]"

///|
extern "js" fn js_viewport_height() -> Double = "() => globalThis.__fake.viewport[1]"

///|
extern "js" fn js_set_title(text : String) = "(t) => { globalThis.__fake.title = t; }"

///|
extern "js" fn js_set_code_size(size : Double, line_height : Double) = "(s, lh) => { globalThis.__fake.code = [s, lh]; }"

///|
extern "js" fn js_rpc(id : Int, op : String, body : String) = "(id, op, body) => { globalThis.__fake.rpcs.push({ id, op, body }); }"

///|
extern "js" fn js_set_timer(id : Int, ms : Int) = "(id, ms) => { globalThis.__fake.timers.set(id, globalThis.__fake.now + ms); }"

///|
extern "js" fn js_clear_timer(id : Int) = "(id) => { globalThis.__fake.timers.delete(id); }"

///|
extern "js" fn js_now() -> Double = "() => globalThis.__fake.now"

///|
extern "js" fn js_log(text : String) = "(t) => { globalThis.__fake.logs.push(t); }"

///|
extern "js" fn js_clipboard_write(text : String) = "(t) => { globalThis.__fake.clipboard = t; }"

///|
extern "js" fn js_clipboard_read() = "() => {}"

///|
/// The same regular expression search as the browser glue.
extern "js" fn js_regex_find(
  text : String,
  pattern : String,
  flags : String,
) -> String =
  #|(text, pattern, flags) => {
  #|  try {
  #|    const re = new RegExp(pattern, flags);
  #|    const out = [];
  #|    for (const m of text.matchAll(re)) {
  #|      if (m[0].length === 0) continue;
  #|      out.push(m.index + ',' + (m.index + m[0].length));
  #|      if (out.length >= 5000) break;
  #|    }
  #|    return out.join(';');
  #|  } catch (error) {
  #|    return '!' + error.message;
  #|  }
  #|}

///|
extern "js" fn js_ts_update(
  key : String,
  language : String,
  text : String,
) -> Bool = "() => false"

///|
extern "js" fn js_ts_tokens(key : String, from : Int, to : Int) -> String = "() => ''"

///|
extern "js" fn js_ts_drop(key : String) = "() => {}"

///|
extern "js" fn js_confirm_leave(dirty : Bool) = "(d) => { globalThis.__fake.leave = !!d; }"

///|
extern "js" fn js_close_window() = "() => { globalThis.__fake.closed = true; }"

///|
extern "js" fn js_char_width(font_px : Double) -> Double = "(px) => px * 0.6"
