// Entry points called by the glue, and the render loop.

///|
let applied_focus : Ref[String] = Ref("")

///|
let guide_visible : Ref[Bool] = Ref(false)

///|
let scrolled_pick : Ref[String] = Ref("")

///|
let deferred_input : Array[(String, Json)] = []

///|
/// A key that types a character rather than running a command.
fn printable(desc : String) -> Bool {
  let parts = desc.split("-").map(p => p.to_owned()).collect()
  let key = parts.last().unwrap_or("")
  // "cmd--" splits into an empty last part; it is a shortcut, not text.
  if key == "" {
    return false
  }
  for i in 0..<(parts.length() - 1) {
    if parts[i] != "shift" {
      return false
    }
  }
  key.length() == 1 || key == "space"
}

///|
/// Replay input that arrived while a file loaded.
fn replay_deferred() -> Unit {
  while reader.loading is None && deferred_input.length() > 0 {
    let (kind, args) = deferred_input.remove(0)
    ignore(handle_event(kind, args))
  }
}

///|
let scrolled_tab : Ref[String] = Ref("")

///|
fn narrow_layout() -> Bool {
  js_viewport_width() <= 900.0
}

///|
let was_narrow : Ref[Bool] = Ref(false)

///|
/// Called once the page loads, with the server session.
pub fn boot(config : String) -> Unit {
  was_narrow.val = narrow_layout()
  reader.sidebar = !was_narrow.val
  reader.wrap = was_narrow.val
  let parsed = @json.parse(config) catch { _ => Json::null() }
  match parsed {
    { "workspace": summary, "control_socket": String(socket), .. } => {
      reader.workspace.apply(summary)
      reader.control_socket = socket
      if parsed is { "label": String(label), .. } {
        reader.label = label
      }
      for w in reader.workspace.warnings {
        js_log(w)
      }
      // Show the first file unless the user already opened something meanwhile.
      match reader.workspace.first {
        Some(path) =>
          ensure(path, _ => {
            if reader.selected is None {
              open(path, None, true)
            } else if !reader.tabs.contains(path) {
              // The user opened something first; keep the first file as the first tab.
              reader.tabs.insert(0, path)
            }
          })
        None => reader.focus = "body"
      }
    }
    _ => say("サーバーの設定を読めません")
  }
  after_event()
}

///|
/// Selected text for the clipboard; `cut` also deletes it.
pub fn copy_text(cut : Bool) -> String {
  guard current_editor() is Some(ed) else { return "" }
  let text = ed.selected_text()
  if cut && ed.has_selection() && ed.backspace(Char) {
    document_changed()
    after_event()
  }
  text
}

///|
pub fn has_unsaved() -> Bool {
  !reader.quitting &&
  reader.workspace.documents.iter().any(d => is_dirty(d.path))
}

///|
fn event_text(args : Json, key : String) -> String {
  json_text(args, key).unwrap_or("")
}

///|
fn event_number(args : Json, key : String) -> Double {
  match json_field(args, key) {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
fn event_flag(args : Json, key : String) -> Bool {
  json_field(args, key) is Some(True)
}

///|
/// Every browser event arrives here. True means "handled; prevent the default".
pub fn on_event(kind : String, payload : String) -> Bool {
  let args = @json.parse(payload) catch { _ => Json::null() }
  let handled = handle_event(kind, args)
  after_event()
  handled
}

///|
fn handle_event(kind : String, args : Json) -> Bool {
  // While a file is being read, input waits so it applies to that file, as in
  // the native editor where opening is synchronous. Plain characters still
  // reach the hidden input and are queued as text.
  if reader.loading is Some(_) {
    match kind {
      "text" | "paste" => {
        deferred_input.push((kind, args))
        return true
      }
      "key" if !printable(event_text(args, "desc")) => {
        deferred_input.push((kind, args))
        return true
      }
      _ => ()
    }
  }
  match kind {
    "key" => on_key(event_text(args, "desc"), event_text(args, "target"))
    "text" => {
      if current_editor() is Some(ed) && reader.focus == "editor" {
        let text = event_text(args, "text")
        if text != "" && ed.insert(text) {
          document_changed()
          request_reveal(ed.line_of(ed.head), 0)
        }
      }
      true
    }
    "paste" => {
      if current_editor() is Some(ed) {
        let text = event_text(args, "text")
        if text != "" && ed.insert(text) {
          document_changed()
          request_reveal(ed.line_of(ed.head), 0)
        }
      }
      true
    }
    "act" => {
      on_action(event_text(args, "act"), event_text(args, "arg"))
      true
    }
    "context" => {
      let path = event_text(args, "path")
      reader.tree_target = Some(path)
      if reader.workspace.index_of(path) is Some(_) {
        open(path, None, true)
      }
      reader.focus = "explorer"
      reader.context_menu = Some({
        x: event_number(args, "x"),
        y: event_number(args, "y"),
      })
      true
    }
    "editor-down" => {
      editor_mouse_down(args)
      true
    }
    "editor-move" => {
      editor_mouse_move(args)
      false
    }
    "mouse-move" => {
      mouse_move(args)
      false
    }
    "mouse-up" => {
      mouse_up(args)
      false
    }
    "drag-start" => {
      drag_start(args)
      true
    }
    "scroll" => {
      if reader.popup is Some(p) &&
        p.contains(reader.mouse_x, reader.mouse_y) &&
        event_text(args, "id") == "pointer" {
        return false
      }
      if event_text(args, "id") == "editor-scroll" {
        clear_pointer()
        if current() is Some(d) {
          d.scroll_top = js_scroll_top("editor-scroll")
        }
      }
      if event_text(args, "id") == "pinned-scroll" && reader.pinned is Some(p) {
        p.scroll_top = js_scroll_top("pinned-scroll")
      }
      false
    }
    "input" => {
      match event_text(args, "id") {
        "dialog-query" => {
          reader.query = event_text(args, "value")
          reader.pick_index = 0
          if reader.dialog == Some(WorkspaceSearch) {
            schedule_workspace_search()
          } else if reader.dialog == Some(Quick) {
            find_files()
          }
        }
        "search-input" => {
          reader.search_query = event_text(args, "value")
          reader.search_index = 0
          refresh_search()
          if reader.search_matches.length() > 0 && current_editor() is Some(ed) {
            let (s, _) = ed.selection()
            let mut index = 0
            for i, m in reader.search_matches {
              if m.0 >= s {
                index = i
                break
              }
            }
            reader.search_index = index
            let (ms, me) = reader.search_matches[index]
            ed.select(ms, me)
            request_reveal(ed.line_of(ms), 2)
          }
        }
        "dialog-replacement" => reader.replacement = event_text(args, "value")
        _ => ()
      }
      false
    }
    "focus" => {
      let target = event_text(args, "target")
      if target != "" {
        reader.focus = target
        applied_focus.val = target
      }
      false
    }
    "modifiers" => {
      if event_flag(args, "meta") {
        if event_flag(args, "over") {
          let line = event_number(args, "line").to_int()
          let col = event_number(args, "glyph").to_int()
          if col >= 0 {
            update_pointer(line, col, reader.mouse_x, reader.mouse_y, true)
          }
        }
      } else {
        clear_pointer()
      }
      false
    }
    "resize" => {
      let narrow = narrow_layout()
      if narrow && !was_narrow.val {
        reader.sidebar = false
      }
      was_narrow.val = narrow
      false
    }
    "window-focus" => {
      if reader.overview_visible {
        refresh_disk_cache()
      }
      false
    }
    "highlight" => false
    "control" => {
      let id = event_number(args, "id").to_int()
      let op = event_text(args, "method")
      let arguments = json_field(args, "arguments").unwrap_or(
        Json::object(Map([])),
      )
      control_call(op, arguments, result => {
        let body : Json = match result {
          Ok(value) => { "id": num(id), "result": value }
          Err(e) => { "id": num(id), "error": e }
        }
        rpc("control.reply", body, _ => ())
      })
      true
    }
    "stream" => {
      match event_text(args, "state") {
        "open" => {
          reader.connected = true
          reader.superseded = false
        }
        "superseded" => {
          reader.connected = false
          reader.superseded = true
        }
        _ => reader.connected = false
      }
      false
    }
    _ => false
  }
}

///|
fn on_action(act : String, arg : String) -> Unit {
  if act != "menu" {
    reader.menu = None
  }
  if act != "tree" {
    reader.context_menu = None
  }
  match act {
    "menu" =>
      reader.menu = if reader.menu == Some(arg) { None } else { Some(arg) }
    "close-menus" => {
      reader.menu = None
      reader.context_menu = None
    }
    "run" => run_key_command(arg)
    "quick-open" => show(Quick, "")
    "commands" => show(Commands, "")
    "tree" => {
      reader.context_menu = None
      reader.tree_target = Some(arg)
      if reader.workspace.is_folder(arg) {
        reader.focus = "explorer"
        if reader.expanded.contains(arg) {
          reader.expanded.remove(arg)
        } else {
          reader.expanded[arg] = ()
        }
      } else {
        open(arg, None, true)
      }
    }
    "open" => open(arg, None, true)
    "open-tab" => open(arg, None, true)
    "close-tab" => begin(Close(arg))
    "overview" => show_overview()
    "close-overview" => {
      reader.overview_tab = false
      reader.overview_visible = false
      focus_editor()
    }
    "diff-line" =>
      if reader.selected is Some(path) && @core.parse_natural(arg) is Some(line) {
        open(path, Some(line), true)
      }
    "jump" => if @core.parse_natural(arg) is Some(i) { jump_target(i) }
    "pick" =>
      if @core.parse_natural(arg) is Some(i) {
        reader.pick_index = i
        accept()
      }
    "navigation" => show(Navigation, "")
    "close-nav" => {
      reader.nav_serial += 1
      reader.nav_busy = false
      reader.nav_visible = false
    }
    "confirm-save" => resolve_pending(true)
    "confirm-discard" => resolve_pending(false)
    "confirm-cancel" | "cancel-dialog" => dismiss()
    "accept-dialog" => accept()
    "replace-next" => replace_text(false)
    "replace-all" => replace_text(true)
    "search-case" => {
      reader.search_case = !reader.search_case
      reader.search_key = ""
    }
    "search-regex" => {
      reader.search_regex = !reader.search_regex
      reader.search_key = ""
    }
    "search-next" => search_step(true)
    "search-prev" => search_step(false)
    "search-close" => {
      reader.search_open = false
      focus_document()
    }
    "refresh-pinned" =>
      if reader.pinned is Some(p) {
        let path = p.path
        let line = p.line
        load_texts([path], () => if pin_code(path, line) is Err(e) { say(e) })
      }
    "chapter" => if @core.parse_natural(arg) is Some(i) { open_chapter(i) }
    "guide-back" => guide_step(-1)
    "guide-next" => guide_step(1)
    "guide-ask" => open_guide_question()
    "guide-send" => submit_guide_question()
    "guide-cancel" => cancel_guide_question()
    "guide-end" => guide_response("end")
    "prediction-record" => record_prediction(false)
    "prediction-unknown" => record_prediction(true)
    "evidence" => open_evidence(arg)
    "toggle-context" => reader.context_open = !reader.context_open
    "pointer-jump" => jump_pointer()
    "overlay" => ()
    _ => run_key_command(act)
  }
}

///|
fn editor_mouse_down(args : Json) -> Unit {
  reader.menu = None
  reader.context_menu = None
  guard current_editor() is Some(ed) else { return }
  let line = event_number(args, "line").to_int()
  let col = event_number(args, "col").to_int()
  let offset = ed.offset_at(line, col)
  if event_flag(args, "meta") {
    // ⌘-click navigates on release, keeping the cursor where it is.
    return
  }
  reader.focus = "editor"
  match event_number(args, "detail").to_int() {
    2 => ed.select_word_at(offset)
    3 => ed.select_line(line)
    _ => ed.set_cursor(offset, selecting=event_flag(args, "shift"))
  }
  reader.mouse_selecting = true
  clear_pointer()
}

///|
fn editor_mouse_move(args : Json) -> Unit {
  reader.mouse_x = event_number(args, "x")
  reader.mouse_y = event_number(args, "y")
  guard current_editor() is Some(ed) else { return }
  let line = event_number(args, "line").to_int()
  let col = event_number(args, "col").to_int()
  if reader.mouse_selecting && event_number(args, "buttons").to_int() == 1 {
    ed.set_cursor(ed.offset_at(line, col), selecting=true)
    return
  }
  if event_number(args, "buttons").to_int() != 0 {
    clear_pointer()
    return
  }
  let glyph = event_number(args, "glyph").to_int()
  if glyph < 0 {
    if !(reader.popup is Some(p) && p.contains(reader.mouse_x, reader.mouse_y)) {
      clear_pointer()
    }
    return
  }
  update_pointer(
    line,
    glyph,
    reader.mouse_x,
    reader.mouse_y,
    event_flag(args, "meta"),
  )
}

///|
fn mouse_move(args : Json) -> Unit {
  let x = event_number(args, "x")
  let y = event_number(args, "y")
  reader.mouse_x = x
  reader.mouse_y = y
  let pressed = event_number(args, "buttons").to_int() == 1
  if reader.guide is Some(guide) && guide.drag is Some((sx, sy, ox, oy)) {
    if pressed {
      guide.position = Some((ox + x - sx, oy + y - sy))
      clear_pointer()
      return
    }
    guide.drag = None
  }
  if reader.sidebar_drag is Some((start, width)) {
    if pressed {
      let limit = (js_viewport_width() - 320.0).clamp(min=180.0, max=700.0)
      reader.sidebar_width = (width + x - start).clamp(min=180.0, max=limit)
      clear_pointer()
      return
    }
    reader.sidebar_drag = None
  }
  if pressed {
    clear_pointer()
  } else if !event_flag(args, "editor") &&
    !(reader.popup is Some(p) && p.contains(x, y)) {
    clear_pointer()
  }
}

///|
fn mouse_up(args : Json) -> Unit {
  reader.sidebar_drag = None
  if reader.guide is Some(g) {
    g.drag = None
  }
  let was_selecting = reader.mouse_selecting
  reader.mouse_selecting = false
  if event_flag(args, "meta") &&
    event_flag(args, "editor") &&
    !reader.compare &&
    !was_selecting {
    if reader.pointer is Some(p) && p.targets.length() > 0 && p.definition {
      jump_pointer()
      return
    }
    guard current_editor() is Some(ed) else { return }
    let line = event_number(args, "line").to_int()
    let glyph = event_number(args, "glyph").to_int()
    if glyph >= 0 {
      let offset = ed.offset_at(line, glyph)
      if @core.symbol_range(ed.text, offset) is Some(_) {
        analyze(Definition, true, Some(@core.position_at(ed.text, offset)))
      }
    }
  }
}

///|
fn drag_start(args : Json) -> Unit {
  let x = event_number(args, "x")
  let y = event_number(args, "y")
  match event_text(args, "kind") {
    "sidebar" => reader.sidebar_drag = Some((x, reader.sidebar_width))
    "guide" => {
      clear_pointer()
      if reader.guide is Some(guide) {
        let origin = match Rect::parse(js_rect("guide")) {
          Some(r) => (r.left, r.top)
          None => (x, y)
        }
        guide.position = Some(origin)
        guide.drag = Some((x, y, origin.0, origin.1))
      }
    }
    _ => ()
  }
}

///|
/// Redraw after any event.
fn after_event() -> Unit {
  render()
}

///|
fn show_region(id : String, visible : Bool) -> Unit {
  js_set_style(id, "display", if visible { "" } else { "none" })
}

///|
fn render() -> Unit {
  validate_guide()
  if reader.pinned is Some(p) && p.root != reader.workspace.root {
    reader.pinned = None
  }
  refresh_search()
  ensure_tree()
  let overlay = dialog_open()
  js_set_title(
    {
      let name = if reader.workspace.root == "" {
        "Readit"
      } else {
        "\{reader.workspace.name()} — Readit"
      }
      if reader.label == "" {
        name
      } else {
        "[\{reader.label}] \{name}"
      }
    },
  )
  js_set_html("topbar", render_topbar())
  js_set_html("menu-layer", render_menu())
  show_region("sidebar", reader.sidebar)
  js_set_class("app", "sidebar-open", reader.sidebar)
  js_set_style("sidebar", "width", px(reader.sidebar_width))
  js_set_html("sidebar-head", render_sidebar_head())
  js_set_html("tree-scroll", render_tree())
  js_set_html("tabs", render_tabs())
  // Main column: overview, or path bar + navigation bar + editor/diff.
  show_region("overview", reader.overview_visible)
  show_region("file-column", !reader.overview_visible)
  if reader.overview_visible {
    js_set_html("overview", render_overview())
    if js_now() - reader.disk_refresh > 3000.0 {
      refresh_disk_cache()
    }
  }
  js_set_html("pathbar", render_pathbar())
  js_set_html("navbar", render_navbar())
  let editor = current_editor()
  let editing = editor is Some(_) && !reader.compare
  show_region("editor-scroll", editing)
  show_region("diff-scroll", reader.compare && editor is Some(_))
  show_region("empty-state", editor is None)
  show_region(
    "search-bar",
    reader.search_open && editing && !reader.overview_visible,
  )
  js_set_html("search-controls", render_search_bar())
  js_set_class(
    "editor-area",
    "read-only",
    match reader.selected {
      Some(p) => reader.external.contains(p)
      None => false
    },
  )
  if reader.compare && editor is Some(_) {
    js_set_html("diff-scroll", render_diff())
  }
  if editor is None {
    js_set_html("empty-state", render_empty())
  }
  match (editor, reader.selected) {
    (Some(ed), Some(path)) if !reader.compare && !reader.overview_visible => {
      let layout = layout_for(
        "editor",
        path,
        ed,
        reader.wrap,
        js_client_width("editor-scroll"),
      )
      let target = editor_scroll_target(layout)
      let link = match reader.pointer {
        Some(p) if p.definition && p.targets.length() > 0 =>
          Some((p.start, p.end))
        _ => None
      }
      js_set_html(
        "editor-content",
        code_rows(
          {
            view: "editor",
            key: path,
            language: @core.language(path),
            editor: ed,
            caret: true,
            matches: if reader.search_open {
              reader.search_matches
            } else {
              []
            },
            current_match: reader.search_index,
            link,
            numbers: true,
            wrap: reader.wrap,
            scroll_top: target,
            height: js_client_height("editor-scroll"),
          },
          layout,
        ),
      )
      if target != js_scroll_top("editor-scroll") {
        js_set_scroll_top("editor-scroll", target)
      }
    }
    _ => ()
  }
  // Pinned code, read-only beside the editor.
  let pinned_visible = reader.pinned is Some(_) && !reader.overview_visible
  show_region("pinned", pinned_visible)
  if reader.pinned is Some(p) && pinned_visible {
    js_set_html("pinned-head", render_pinned_head())
    let lh = line_height()
    let initial = p.scroll_top < 0.0
    if initial {
      p.scroll_top = ((p.line - 1).to_double() * lh - 2.0 * lh).max(0.0)
    }
    js_set_html(
      "pinned-content",
      code_rows(
        {
          view: "pinned",
          key: "pinned:" + p.path,
          language: @core.language(p.path),
          editor: p.editor,
          caret: false,
          matches: [],
          current_match: -1,
          link: None,
          numbers: true,
          wrap: false,
          scroll_top: if initial {
            p.scroll_top
          } else {
            js_scroll_top("pinned-scroll")
          },
          height: js_client_height("pinned-scroll"),
        },
        layout_for("pinned", "pinned:" + p.path, p.editor, false, 0.0),
      ),
    )
    if initial {
      js_set_scroll_top("pinned-scroll", p.scroll_top)
    }
  }
  show_region("navpanel", reader.nav_visible)
  if reader.nav_visible {
    js_set_html("navpanel", render_navpanel())
  }
  js_set_html("status", render_status())
  // Floating layers.
  let pointer = if !overlay && !reader.overview_visible && reader.guide is None {
    render_pointer()
  } else {
    reader.popup = None
    ""
  }
  js_set_html("pointer-layer", pointer)
  match render_guide() {
    Some(view) => {
      show_region("guide", true)
      js_set_html("guide-main", view.main)
      js_set_html("guide-predict", view.predict)
      js_set_html("guide-form", view.form)
      js_set_html("guide-after", view.after)
      js_set_style("guide", "cssText", view.style)
      guide_visible.val = true
      let height = js_natural_height("guide")
      if height > 0.0 &&
        (
          reader.guide_height_key != view.key ||
          (reader.guide_height - height).abs() > 1.0
        ) {
        let changed_key = reader.guide_height_key != view.key
        reader.guide_height_key = view.key
        reader.guide_height = height
        if changed_key {
          after(0, () => ()) |> ignore
        }
      }
    }
    None => {
      show_region("guide", false)
      if guide_visible.val {
        js_set_html("guide-form", "")
      }
      // A hidden bubble keeps the prediction being typed; an ended one does not.
      if reader.guide is None {
        js_set_html("guide-predict", "")
      }
      guide_visible.val = false
    }
  }
  show_region("overlay", overlay)
  if reader.dialog is Some(_) {
    js_set_html("dialog-shell", render_dialog_shell())
    for pair in pending_inputs.val {
      js_set_value(pair.0, pair.1)
    }
    if pending_inputs.val.length() > 0 {
      pending_inputs.val = []
      js_select_input("dialog-query")
    }
  } else {
    js_set_html("dialog-shell", "")
  }
  js_set_html("dialog-body", render_dialog_body())
  // Bring the chosen pick or tab into view only when the choice changes, so
  // scrolling the list by hand is not undone by the next redraw.
  let pick_key = match reader.dialog {
    Some(d) if is_picker(d) => "\{reader.query}|\{reader.pick_index}"
    _ => ""
  }
  if pick_key != "" && pick_key != scrolled_pick.val {
    js_scroll_into_view("pick-\{reader.pick_index}")
  }
  scrolled_pick.val = pick_key
  let tab_key = if reader.overview_visible {
    "overview"
  } else {
    reader.selected.unwrap_or("")
  }
  if tab_key != scrolled_tab.val {
    js_scroll_into_view("tab-selected")
    scrolled_tab.val = tab_key
  }
  js_set_html("context-layer", render_context_menu())
  apply_focus()
  if reader.focus == "editor" {
    js_place_input()
  }
  js_confirm_leave(has_unsaved())
}

///|
/// Move keyboard focus when the state asks for a different element.
fn apply_focus() -> Unit {
  let id = match reader.focus {
    "editor" =>
      if current_editor() is Some(_) &&
        !reader.compare &&
        !reader.overview_visible {
        "editor-input"
      } else {
        "app"
      }
    "query" => "dialog-query"
    "search" => "search-input"
    "guide-question" => "guide-question"
    "guide-prediction" => "guide-prediction"
    "explorer" => "sidebar"
    "dialog" => "dialog"
    _ => "app"
  }
  if applied_focus.val != reader.focus || !js_has_focus(id) {
    if applied_focus.val != reader.focus || js_has_focus("") {
      js_focus(id)
    }
    applied_focus.val = reader.focus
  }
}
