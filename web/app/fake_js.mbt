// What tests may read and set on the browser double (ffi_js.mbt).

///|
/// A fresh page: nothing rendered, no server calls, the clock at a fixed time.
pub extern "js" fn fake_reset() -> Unit =
  #|() => {
  #|  globalThis.__fake = {
  #|    html: new Map(), styles: new Map(), classes: new Set(), focused: '', values: new Map(),
  #|    scroll: new Map(), sizes: new Map(), rects: new Map(), hidden: new Set(), viewport: [1420, 900],
  #|    title: '', code: [0, 0], rpcs: [], timers: new Map(), now: 1700000000000, logs: [],
  #|    clipboard: '', leave: false, closed: false,
  #|  };
  #|}

///|
pub extern "js" fn fake_html(id : String) -> String = "(id) => globalThis.__fake.html.get(id) ?? ''"

///|
pub extern "js" fn fake_style(id : String, property : String) -> String = "(id, p) => globalThis.__fake.styles.get(id + '.' + p) ?? ''"

///|
pub extern "js" fn fake_has_class(id : String, name : String) -> Bool = "(id, n) => globalThis.__fake.classes.has(id + '.' + n)"

///|
pub extern "js" fn fake_focused() -> String = "() => globalThis.__fake.focused"

///|
pub extern "js" fn fake_title() -> String = "() => globalThis.__fake.title"

///|
/// Type into an input or textarea, as the reader would.
pub extern "js" fn fake_set_value(id : String, value : String) -> Unit = "(id, v) => { globalThis.__fake.values.set(id, v); }"

///|
pub extern "js" fn fake_value(id : String) -> String = "(id) => globalThis.__fake.values.get(id) ?? ''"

///|
pub extern "js" fn fake_set_viewport(width : Double, height : Double) -> Unit = "(w, h) => { globalThis.__fake.viewport = [w, h]; }"

///|
/// The box of an element as "left,top,width,height"; "" hides it.
pub extern "js" fn fake_set_rect(id : String, rect : String) -> Unit = "(id, r) => { globalThis.__fake.rects.set(id, r); }"

///|
pub extern "js" fn fake_set_size(
  id : String,
  width : Double,
  height : Double,
) -> Unit = "(id, w, h) => { const F = globalThis.__fake; F.sizes.set(id + '.w', w); F.sizes.set(id + '.h', h); }"

///|
/// Scroll a code view's rows out of sight, or back.
pub extern "js" fn fake_hide_rows(view : String, hidden : Bool) -> Unit = "(v, h) => { if (h) globalThis.__fake.hidden.add(v); else globalThis.__fake.hidden.delete(v); }"

///|
/// The server calls made since the last take, as a JSON array of {id, op, body}.
pub extern "js" fn fake_take_rpcs() -> String = "() => { const F = globalThis.__fake; const out = JSON.stringify(F.rpcs); F.rpcs = []; return out; }"

///|
/// Move the clock and return the timers that came due, as a JSON array of ids.
pub extern "js" fn fake_advance(ms : Double) -> String =
  #|(ms) => {
  #|  const F = globalThis.__fake;
  #|  F.now += ms;
  #|  const due = [...F.timers].filter(([, at]) => at <= F.now).map(([id]) => id).sort((a, b) => a - b);
  #|  for (const id of due) F.timers.delete(id);
  #|  return JSON.stringify(due);
  #|}

///|
pub extern "js" fn fake_logs() -> String = "() => JSON.stringify(globalThis.__fake.logs)"

///|
pub extern "js" fn fake_clipboard() -> String = "() => globalThis.__fake.clipboard"
