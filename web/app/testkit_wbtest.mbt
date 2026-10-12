// A headless Readit for unit tests on the JS target. The browser double in
// ffi_js.mbt stands in for the page, and `serve` plays the server from an
// in-memory project. Tests press buttons with `act`, call MCP tools with
// `mcp` and read the rendered regions with `fake_html`.

///|
let root : String = "/proj"

///|
/// The simulated project on disk, by relative path.
let disk : Map[String, String] = Map([])

///|
/// Bodies the app sent back for control calls that arrived as events.
let control_replies : Array[Json] = []

///|
/// Put every field of the one Reader back to its initial value.
fn reset_reader() -> Unit {
  reader.pinned = None
  reader.guide = None
  reader.tour = None
  reader.overview_visible = false
  reader.overview_tab = false
  reader.guide_events.clear()
  reader.guide_sequence = 0
  reader.control_targets = []
  reader.control_target_root = ""
  reader.pointer = None
  reader.pointer_timer = None
  reader.pointer_serial = 0
  reader.popup = None
  reader.nav_serial = 0
  reader.nav_busy = false
  reader.nav_visible = false
  reader.nav_title = ""
  reader.nav_targets = []
  reader.nav_information = ""
  reader.nav_snapshot = None
  reader.external.clear()
  reader.workspace.root = ""
  reader.workspace.git = false
  reader.workspace.known_files.clear()
  reader.workspace.listed.clear()
  reader.workspace.loading.clear()
  reader.workspace.first = None
  reader.workspace.changed = Map([])
  reader.workspace.documents.clear()
  reader.workspace.warnings = []
  reader.tabs.clear()
  reader.selected = None
  reader.untitled.clear()
  reader.closed.clear()
  reader.tour_tabs.clear()
  reader.dialog = None
  reader.pending = None
  reader.save_source = None
  reader.saving_all = false
  reader.rename_source = None
  reader.pick_index = 0
  reader.query = ""
  reader.replacement = ""
  reader.expanded.clear()
  reader.tree_target = None
  reader.sidebar = true
  reader.sidebar_width = 245.0
  reader.sidebar_drag = None
  reader.wrap = false
  reader.font_size = 14.0
  reader.compare = false
  reader.diff_rows = []
  reader.message = default_status
  reader.history.clear()
  reader.history_index = 0
  reader.focus = "editor"
  reader.search_open = false
  reader.search_query = ""
  reader.search_case = false
  reader.search_regex = false
  reader.search_index = 0
  reader.search_matches = []
  reader.search_error = ""
  reader.search_key = ""
  reader.workspace_picks = []
  reader.quick_picks = []
  reader.quick_serial = 0
  reader.workspace_search_serial = 0
  reader.workspace_search_timer = None
  reader.menu = None
  reader.context_menu = None
  reader.mouse_selecting = false
  reader.mouse_x = 0.0
  reader.mouse_y = 0.0
  reader.chord = None
  reader.disk_cache.clear()
  reader.disk_refresh = 0.0
  reader.control_socket = ""
  reader.label = ""
  reader.connected = false
  reader.superseded = false
  reader.quitting = false
  reader.loading = None
  reader.guide_height = 0.0
  reader.guide_height_key = ""
  reader.context_open = false
  runtime.rpcs.clear()
  runtime.timers.clear()
  deferred_input.clear()
  guide_opening.val = false
  guide_visible.val = false
  applied_focus.val = ""
  reader_reveal.val = None
  restore_scroll_to.val = None
}

///|
/// Start Readit on a project made of these files, showing the first in
/// reading order, as the server does.
fn fresh(files : Map[String, String]) -> Unit {
  fake_reset()
  disk.clear()
  for name, text in files {
    disk[name] = text
  }
  control_replies.clear()
  reset_reader()
  let names = disk.keys().collect()
  @core.sort_reading_order(names)
  let first : Json = match names.get(0) {
    Some(n) => Json::string(n)
    None => Json::null()
  }
  let config : Json = {
    "workspace": {
      "root": root,
      "git": false,
      "first": first,
      "changed": [],
      "warnings": [],
    },
    "control_socket": "/sock",
  }
  boot(config.stringify())
  serve()
}

///|
/// Answer every server call the app has queued, until it asks nothing more.
fn serve() -> Unit {
  for _ in 0..<64 {
    let taken = @json.parse(fake_take_rpcs()) catch { _ => return }
    guard taken is Array(calls) && calls.length() > 0 else { return }
    for call in calls {
      guard call
        is { "id": Number(id, ..), "op": String(op), "body": String(body), .. } else {
        continue
      }
      let args = @json.parse(body) catch { _ => Json::null() }
      let reply : Json = match answer(op, args) {
        Ok(result) => { "ok": true, "result": result }
        Err(error) => { "ok": false, "error": error }
      }
      rpc_done(id.to_int(), true, reply.stringify())
    }
  }
}

///|
/// The server's answer to one call, from the in-memory project.
fn answer(op : String, args : Json) -> Result[Json, String] {
  let text = (key : String) => json_text(args, key).unwrap_or("")
  let paths = () => {
    match json_field(args, "paths") {
      Some(Array(items)) =>
        items.filter_map(item => {
          match item {
            String(s) => Some(s)
            _ => None
          }
        })
      _ => []
    }
  }
  match op {
    "file.read" =>
      match disk.get(text("path")) {
        Some(t) => Ok({ "text": t, "before": t })
        None => Err("ファイルではありません")
      }
    "file.check" =>
      Ok({
        "files": Json::array(
          paths().filter(p => disk.contains(p)).map(Json::string),
        ),
      })
    "file.disk" =>
      match disk.get(text("path")) {
        Some(t) => Ok({ "text": t })
        None => Err("external definition is not a supported text file")
      }
    "file.disk_many" => {
      let out : Map[String, Json] = Map([])
      for p in paths() {
        out[p] = match disk.get(p) {
          Some(t) => Json::string(t)
          None => Json::null()
        }
      }
      Ok(Json::object(out))
    }
    "dir.list" => {
      let path = text("path")
      let prefix = if path == "" { "" } else { path + "/" }
      let dirs : Map[String, Bool] = Map([])
      let names = []
      for p in disk.keys() {
        if !@core.starts_with(p, prefix) {
          continue
        }
        let rest = @core.slice(p, prefix.length(), p.length())
        let slash = @core.find_from(rest, "/", 0)
        let name = if slash < 0 { rest } else { @core.slice(rest, 0, slash) }
        if !dirs.contains(name) {
          dirs[name] = slash >= 0
          names.push(name)
        }
      }
      @core.sort_strings(names)
      Ok({
        "path": path,
        "entries": Json::array(
          names.map(n => {
            ({ "name": n, "dir": dirs.get(n).unwrap_or(false) } : Json)
          }),
        ),
      })
    }
    "file.save" => {
      let p = text("path")
      if disk.get(p) == Some(text("disk")) {
        disk[p] = text("text")
        Ok({ "saved": true })
      } else {
        Err(
          "外部でファイルが変更されました。上書きせず、再読込してください",
        )
      }
    }
    "files.find" | "files.list" => {
      let wanted = @core.lower(
        text(if op == "files.find" { "query" } else { "filter" }),
      )
      let names = disk
        .keys()
        .collect()
        .filter(n => @core.contains(@core.lower(n), wanted))
      @core.sort_reading_order(names)
      Ok({
        "files": Json::array(names.map(Json::string)),
        "total": names.length(),
      })
    }
    "control.reply" => {
      control_replies.push(args)
      Ok(Json::null())
    }
    "reveal" => Ok({ "revealed": false })
    _ => Err("test server: unsupported \{op}")
  }
}

///|
/// Press a button or menu item (a data-act in the page).
fn act(action : String, arg? : String = "") -> Unit {
  on_event("act", ({ "act": action, "arg": arg } : Json).stringify()) |> ignore
  serve()
}

///|
/// A key, as the glue describes it ("cmd-s", "enter", "escape"...).
fn press_key(desc : String, target? : String = "editor") -> Unit {
  on_event("key", ({ "desc": desc, "target": target } : Json).stringify())
  |> ignore
  serve()
}

///|
/// Characters typed into the editor.
fn type_text(text : String) -> Unit {
  on_event("text", ({ "text": text } : Json).stringify()) |> ignore
  serve()
}

///|
/// Fire the timers due within `ms` from now, oldest first.
fn elapse(ms : Double) -> Unit {
  let due = @json.parse(fake_advance(ms)) catch { _ => return }
  guard due is Array(ids) else { return }
  for id in ids {
    if id is Number(n, ..) {
      timer_fired(n.to_int())
    }
  }
  serve()
}

///|
/// Call an MCP tool the way the control socket does and return its reply.
fn mcp(op : String, args : Json) -> Result[Json, String] {
  let out : Ref[Result[Json, String]?] = Ref(None)
  control_call(op, args, result => out.val = Some(result))
  serve()
  // Some tools reply on the next tick, after the view settled.
  for _ in 0..<4 {
    if out.val is Some(_) {
      break
    }
    elapse(0.0)
  }
  after_event()
  match out.val {
    Some(r) => r
    None => Err("the editor sent no reply")
  }
}

///|
fn state() -> Json {
  control_state()
}

///|
/// Arguments for a tool, with the workspace filled in.
fn args(fields : Map[String, Json]) -> Json {
  fields["workspace"] = Json::string(root)
  Json::object(fields)
}

///|
fn bubble_visible() -> Bool {
  fake_style("guide", "display") != "none"
}

///|
/// The guide bubble's HTML, or "" while it is hidden.
fn bubble() -> String {
  if !bubble_visible() {
    return ""
  }
  fake_html("guide-main") +
  fake_html("guide-predict") +
  fake_html("guide-form") +
  fake_html("guide-after")
}

///|
fn overview_visible() -> Bool {
  fake_style("overview", "display") != "none"
}

///|
fn status_text() -> String {
  fake_html("status")
}

///|
/// A step anchored to a line of sample.py.
fn step_json(
  id : String,
  line : Int,
  expected : String,
  kind? : String = "",
  prompt? : String = "",
  verifies? : String = "",
  path? : String = "sample.py",
) -> Json {
  let o : Map[String, Json] = {
    "id": id,
    "title": id,
    "body": "\{id} の解説",
    "path": path,
    "line": num(line),
    "column": num(1),
    "expected_text": expected,
  }
  if kind != "" {
    o["kind"] = Json::string(kind)
  }
  if prompt != "" {
    o["prompt"] = Json::string(prompt)
  }
  if verifies != "" {
    o["verifies"] = Json::string(verifies)
  }
  Json::object(o)
}

///|
/// A chaptered overview whose chapters start at these step ids.
fn overview_json(starts : Array[String]) -> Json {
  {
    "title": "値の定義",
    "summary": "値を順に読む",
    "relationships": "sample.py",
    "chapters": Json::array(
      starts.mapi((k, id) => {
        (
          {
            "title": "章\{k + 1}",
            "summary": "\{id} から",
            "start_step": id,
          } : Json)
      }),
    ),
  }
}

///|
/// Load a tour through the MCP tool, as the model does.
fn load_tour(
  steps : Array[Json],
  overview? : Json? = None,
) -> Result[Json, String] {
  let fields : Map[String, Json] = {
    "id": "tour",
    "event_sequence": num(reader.guide_sequence),
    "steps": Json::array(steps),
  }
  if overview is Some(o) {
    fields["overview"] = o
  }
  mcp("readit_guide_load", args(fields))
}

///|
/// The newest guide event of this action, if any.
fn last_event(action : String) -> Json? {
  for i = reader.guide_events.length() - 1; i >= 0; i = i - 1 {
    if json_text(reader.guide_events[i], "action") == Some(action) {
      return Some(reader.guide_events[i])
    }
  }
  None
}

///|
fn event_sequence(event : Json) -> Int {
  json_int(event, "sequence").unwrap_or(-1)
}
