// Callbacks for asynchronous work. JavaScript holds only integer ids.

///|
priv struct Runtime {
  rpcs : Map[Int, (Result[Json, String]) -> Unit]
  timers : Map[Int, () -> Unit]
  mut next : Int
}

///|
let runtime : Runtime = { rpcs: Map([]), timers: Map([]), next: 0, }

///|
/// Call the local server API.
fn rpc(op : String, args : Json, done : (Result[Json, String]) -> Unit) -> Unit {
  runtime.next += 1
  let id = runtime.next
  runtime.rpcs[id] = done
  js_rpc(id, op, args.stringify())
}

///|
/// Completion of an API call, from the glue.
pub fn rpc_done(id : Int, ok : Bool, body : String) -> Unit {
  guard runtime.rpcs.get(id) is Some(done) else { return }
  runtime.rpcs.remove(id)
  if !ok {
    done(Err(body))
    return
  }
  let parsed = @json.parse(body) catch { _ => Json::null() }
  match parsed {
    { "ok": True, "result": result, .. } => done(Ok(result))
    { "ok": False, "error": String(message), .. } => done(Err(message))
    _ => done(Err("サーバーの応答を読めません"))
  }
  after_event()
}

///|
/// Run `f` after `ms` milliseconds. Returns an id for `cancel_timer`.
fn after(ms : Int, f : () -> Unit) -> Int {
  runtime.next += 1
  let id = runtime.next
  runtime.timers[id] = f
  js_set_timer(id, ms)
  id
}

///|
fn cancel_timer(id : Int) -> Unit {
  if runtime.timers.contains(id) {
    runtime.timers.remove(id)
    js_clear_timer(id)
  }
}

///|
pub fn timer_fired(id : Int) -> Unit {
  guard runtime.timers.get(id) is Some(f) else { return }
  runtime.timers.remove(id)
  f()
  after_event()
}

///|
/// Parse "a,b,c,d" as doubles.
fn numbers(text : String) -> Array[Double] {
  if text == "" {
    return []
  }
  text
  .split(",")
  .map(part => {
    let parsed = @json.parse(part) catch { _ => Json::null() }
    match parsed {
      Number(n, ..) => n
      _ => 0.0
    }
  })
  .collect()
}

///|
priv struct Rect {
  left : Double
  top : Double
  width : Double
  height : Double
} derive(Eq)

///|
fn Rect::parse(text : String) -> Rect? {
  match numbers(text) {
    [left, top, width, height] => Some({ left, top, width, height, })
    _ => None
  }
}

///|
fn Rect::right(self : Rect) -> Double {
  self.left + self.width
}

///|
fn Rect::bottom(self : Rect) -> Double {
  self.top + self.height
}

///|
fn Rect::contains(self : Rect, x : Double, y : Double) -> Bool {
  x >= self.left && x < self.right() && y >= self.top && y < self.bottom()
}

///|
fn Rect::union(self : Rect, other : Rect) -> Rect {
  let left = self.left.min(other.left)
  let top = self.top.min(other.top)
  let right = self.right().max(other.right())
  let bottom = self.bottom().max(other.bottom())
  { left, top, width: right - left, height: bottom - top, }
}

///|
fn px(value : Double) -> String {
  "\{value.round().to_int()}px"
}
