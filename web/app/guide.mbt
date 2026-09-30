// Source-anchored explanations and prepared tours driven over MCP.

///|
fn chars_within(text : String, max : Int) -> Bool {
  @core.trim(text) != "" && @core.char_count(text) <= max
}

///|
fn json_text(args : Json, key : String) -> String? {
  match args {
    Object(o) =>
      match o.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
fn json_int(args : Json, key : String) -> Int? {
  match args {
    Object(o) =>
      match o.get(key) {
        Some(Number(n, ..)) if n >= 0.0 && n == n.floor() => Some(n.to_int())
        _ => None
      }
    _ => None
  }
}

///|
fn json_field(args : Json, key : String) -> Json? {
  match args {
    Object(o) => o.get(key)
    _ => None
  }
}

///|
/// Resolve a control path: a project file, or a definition this editor returned.
fn control_path(value : String) -> String raise Failure {
  let root = reader.workspace.root
  let absolute = if @core.starts_with(value, "/") {
    value
  } else {
    root + "/" + value
  }
  let key = if @core.starts_with(absolute, root + "/") {
    @core.slice(absolute, root.length() + 1, absolute.length())
  } else {
    absolute
  }
  if reader.workspace.known(key) {
    return key
  }
  if reader.control_target_root == root &&
    reader.control_targets.iter().any(t => t.path == absolute) {
    return absolute
  }
  fail("path is not a workspace file or a definition returned by this editor")
}

///|
fn control_text(path : String) -> String raise Failure {
  match known_text(path) {
    Some(t) => t
    None => fail("external definition is not a supported text file")
  }
}

///|
/// Validate one step against current text. Texts must already be loaded.
fn prepare_guide(args : Json) -> Guide raise Failure {
  let field = (name : String, max : Int) => {
    match json_text(args, name) {
      None => fail("\{name} is required")
      Some(t) =>
        if chars_within(t, max) {
          t
        } else {
          fail("\{name} must contain 1..\{max} characters")
        }
    }
  }
  let id = field("id", 128)
  let title = field("title", 100)
  let body = field("body", 2000)
  let expected = field("expected_text", 16000)
  guard json_text(args, "path") is Some(raw) else { fail("path is required") }
  let path = control_path(raw)
  let source = control_text(path)
  guard json_int(args, "line") is Some(line) else { fail("line is required") }
  guard json_int(args, "column") is Some(column) else {
    fail("column is required")
  }
  let start = @core.offset_at(source, line, column)
  let end = start + expected.length()
  if end > source.length() || @core.slice(source, start, end) != expected {
    fail("source changed or expected_text does not match")
  }
  {
    id,
    root: reader.workspace.root,
    path,
    source,
    start,
    end,
    title,
    body,
    question_open: false,
    pending_question: None,
    question: None,
    answer: None,
    question_error: None,
    pending_next: None,
    position: None,
    drag: None,
  }
}

///|
fn step_paths(args : Json) -> Array[String] {
  let out = []
  let add = (value : Json) => {
    if json_text(value, "path") is Some(p) {
      let key = control_path(p) catch { _ => return }
      out.push(key)
    }
  }
  match json_field(args, "steps") {
    Some(Array(steps)) =>
      for s in steps {
        add(s)
      }
    _ => add(args)
  }
  out
}

///|
fn prepare_steps(args : Json, allow_empty : Bool) -> Array[Guide] raise Failure {
  guard json_field(args, "steps") is Some(Array(steps)) else {
    fail("steps must be an array")
  }
  if steps.length() > 32 || (!allow_empty && steps.length() == 0) {
    fail("provide 1..32 steps")
  }
  let prepared = []
  for s in steps {
    prepared.push(prepare_guide(s))
  }
  let ids : Map[String, Unit] = Map([])
  for step in prepared {
    if ids.contains(step.id) {
      fail("step ids must be unique")
    }
    ids[step.id] = ()
  }
  prepared
}

///|
fn parse_overview(value : Json, steps : Array[Guide]) -> Overview raise Failure {
  guard value is Object(o) else { fail("overview must be an object") }
  for k in o.keys() {
    if k != "title" && k != "summary" && k != "relationships" && k != "chapters" {
      fail("unknown field `\{k}` in overview")
    }
  }
  let title = json_text(value, "title").unwrap_or("")
  let summary = json_text(value, "summary").unwrap_or("")
  let relationships = json_text(value, "relationships").unwrap_or("")
  let chapters = match o.get("chapters") {
    Some(Array(items)) => items
    _ => []
  }
  if !chars_within(title, 100) ||
    !chars_within(summary, 2000) ||
    !chars_within(relationships, 4000) ||
    chapters.length() == 0 ||
    chapters.length() > 16 {
    fail(
      "overview requires title (100), summary (2000), relationships (4000), and 1..16 chapters",
    )
  }
  let parsed = []
  let mut previous = -1
  for chapter in chapters {
    guard chapter is Object(c) else { fail("invalid chapter text") }
    for k in c.keys() {
      if k != "title" && k != "summary" && k != "start_step" {
        fail("unknown field `\{k}` in chapter")
      }
    }
    let ct = json_text(chapter, "title").unwrap_or("")
    let cs = json_text(chapter, "summary").unwrap_or("")
    if !chars_within(ct, 100) || !chars_within(cs, 1000) {
      fail("invalid chapter text")
    }
    let start = json_text(chapter, "start_step").unwrap_or("")
    let mut index = -1
    for i, g in steps {
      if g.id == start {
        index = i
        break
      }
    }
    if index < 0 {
      fail("chapter start_step must name an existing step")
    }
    if (previous < 0 && index != 0) || (previous >= 0 && index <= previous) {
      fail(
        "chapters must partition all steps in reading order, starting at the first step",
      )
    }
    previous = index
    parsed.push({ title: ct, summary: cs, start_step: start, })
  }
  { title, summary, relationships, chapters: parsed, }
}

///|
fn guide_event(event : Map[String, Json]) -> Unit {
  reader.guide_sequence += 1
  event["sequence"] = Json::number(reader.guide_sequence.to_double())
  reader.guide_events.push(Json::object(event))
  if reader.guide_events.length() > 128 {
    reader.guide_events.remove(0) |> ignore
  }
}

///|
/// Open a file, select [start, end) and scroll it into view.
fn open_range(
  path : String,
  text : String,
  start : Int,
  end : Int,
  top : Bool,
  then : () -> Unit,
) -> Unit {
  if !reader.workspace.known(path) {
    reader.workspace.documents.push(new_document(path, text, Some(text)))
    reader.external[path] = ()
  }
  let line = @core.position_at(text, start).line
  open(path, Some(line), true, then=() => {
    if current_editor() is Some(e) && reader.selected == Some(path) {
      // The cursor sits at the start, like the native select_to(start).
      e.select(end, start)
      request_reveal(line, if top { 1 } else { 2 })
      focus_editor()
    }
    then()
  })
}

///|
fn activate_guide(guide : Guide, then : (Result[Unit, String]) -> Unit) -> Unit {
  if reader.dialog is Some(_) || reader.pending is Some(_) {
    then(Err("finish the editor dialog first"))
    return
  }
  let text = control_text(guide.path) catch { _ => "\u{0}" }
  if reader.workspace.root != guide.root || text != guide.source {
    then(Err("source changed; regenerate the guide before navigating"))
    return
  }
  let previous = reader.guide
  reader.guide = None
  open_range(guide.path, guide.source, guide.start, guide.end, true, () => {
    if reader.selected != Some(guide.path) {
      reader.guide = previous
      then(Err("editor could not open the file"))
      return
    }
    reader.overview_visible = false
    reader.compare = false
    clear_pointer()
    reader.guide = Some(guide)
    js_set_value("guide-question", "")
    then(Ok(()))
  })
}

///|
fn guide_step(direction : Int) -> Unit {
  validate_guide()
  guard reader.tour is Some(tour) else {
    guide_response("next")
    return
  }
  if reader.guide is Some(g) && g.question_open {
    return
  }
  let next = tour.index + direction
  if next < 0 {
    return
  }
  if next >= tour.steps.length() {
    guide_response("end")
    return
  }
  let target = tour.steps[next].copy()
  let previous = reader.guide
  load_texts([target.path], () => {
    activate_guide(target, result => {
      match result {
        Err(error) => {
          say(error)
          if reader.guide is Some(g) {
            g.question_error = Some(error)
          }
        }
        Ok(_) => {
          guard reader.tour is Some(tour) else { return }
          if previous is Some(p) {
            tour.steps[tour.index] = p
          }
          tour.index = next
          tour.visited = tour.visited.max(tour.index)
          let id = tour.steps[tour.index].id
          if !tour.seen.contains(id) {
            tour.seen.push(id)
          }
          guide_event({
            "action": "step",
            "tour_id": tour.id,
            "index": Json::number(tour.index.to_double()),
            "id": id,
          })
        }
      }
    })
  })
}

///|
fn guide_response(action : String) -> Unit {
  if action == "next" &&
    (match reader.guide {
      Some(g) =>
        g.pending_next is Some(_) ||
        g.pending_question is Some(_) ||
        g.question_open
      None => false
    }) {
    return
  }
  let retain = action != "cleared" &&
    (match reader.tour {
      Some(t) =>
        t.overview is Some(_) && t.steps[0].root == reader.workspace.root
      None => false
    })
  if action != "next" && !retain {
    reader.tour = None
    reader.overview_visible = false
    reader.overview_tab = false
  }
  if retain && reader.tour is Some(tour) && reader.guide is Some(guide) {
    tour.steps[tour.index] = guide.copy()
  }
  guard reader.guide is Some(guide) else { return }
  reader.guide = None
  guide_event({
    "id": guide.id,
    "action": action,
    "workspace": guide.root,
    "path": reader.workspace.absolute(guide.path),
  })
  if action == "next" {
    guide.pending_next = Some(js_now())
    guide.drag = None
    reader.guide = Some(guide)
    after(10000, () => ()) |> ignore
  }
}

///|
fn open_guide_question() -> Unit {
  guard reader.guide is Some(guide) else { return }
  if guide.pending_question is Some(_) || guide.pending_next is Some(_) {
    return
  }
  guide.question_open = true
  guide.question_error = None
  reader.focus = "guide-question"
}

///|
fn submit_guide_question() -> Unit {
  validate_guide()
  guard reader.guide is Some(guide) else { return }
  if !guide.question_open || guide.pending_question is Some(_) {
    return
  }
  let question = @core.trim(js_get_value("guide-question"))
  if question == "" || @core.char_count(question) > 2000 {
    guide.question_error = Some(
      "質問を1〜2,000文字で入力してください。",
    )
    return
  }
  let start = @core.position_at(guide.source, guide.start)
  let end = @core.position_at(guide.source, guide.end)
  let optional = (value : String?) => {
    match value {
      Some(v) => Json::string(v)
      None => Json::null()
    }
  }
  guide_event({
    "id": guide.id,
    "action": "question",
    "question": question,
    "workspace": guide.root,
    "path": reader.workspace.absolute(guide.path),
    "line": Json::number((start.line + 1).to_double()),
    "column": Json::number((start.character + 1).to_double()),
    "end_line": Json::number((end.line + 1).to_double()),
    "end_column": Json::number((end.character + 1).to_double()),
    "expected_text": @core.slice(guide.source, guide.start, guide.end),
    "title": guide.title,
    "explanation": guide.body,
    "previous_question": optional(guide.question),
    "previous_answer": optional(guide.answer),
  })
  guide.pending_question = Some(reader.guide_sequence)
  guide.question = Some(question)
  guide.answer = None
  guide.question_open = false
  guide.question_error = None
  focus_editor()
}

///|
fn cancel_guide_question() -> Unit {
  if reader.guide is Some(guide) {
    guide.question_open = false
    guide.question_error = None
  }
  focus_editor()
}

///|
fn validate_guide() -> Unit {
  if reader.tour is Some(t) && t.steps[0].root != reader.workspace.root {
    reader.tour = None
    reader.overview_visible = false
    reader.overview_tab = false
  }
  let invalid = match reader.guide {
    Some(guide) =>
      reader.workspace.root != guide.root ||
      reader.selected != Some(guide.path) ||
      (match current_editor() {
        Some(e) => e.text != guide.source
        None => true
      })
    None => false
  }
  if invalid {
    guide_response("interrupted")
  }
}

///|
fn show_overview() -> Unit {
  if reader.dialog is Some(_) || reader.pending is Some(_) {
    return
  }
  if reader.tour is Some(t) && t.overview is Some(_) {
    reader.overview_visible = true
    reader.overview_tab = true
    clear_pointer()
    reader.focus = "body"
    refresh_disk_cache()
  }
}

///|
/// Re-read unopened step files so the overview notices external edits.
fn refresh_disk_cache() -> Unit {
  guard reader.tour is Some(tour) else { return }
  reader.disk_refresh = js_now()
  load_texts(tour.steps.map(g => g.path), () => ())
}

///|
/// A step is stale when its file no longer holds the text the guide was built from.
/// A file the project has not read yet is not stale; it is simply unopened.
fn guide_steps_stale(tour : Tour) -> Bool {
  tour.steps
  .iter()
  .any(g => {
    match known_text(g.path) {
      Some(text) => text != g.source
      None => reader.disk_cache.contains(g.path)
    }
  })
}

///|
fn chapter_bounds(tour : Tour, overview : Overview, i : Int) -> (Int, Int) {
  let find = (id : String) => {
    let mut at = -1
    for j, g in tour.steps {
      if g.id == id {
        at = j
        break
      }
    }
    at
  }
  let start = find(overview.chapters[i].start_step)
  let end = match overview.chapters.get(i + 1) {
    Some(c) => find(c.start_step)
    None => tour.steps.length()
  }
  (start, if end < 0 { tour.steps.length() } else { end })
}

///|
fn open_chapter(i : Int) -> Unit {
  guard reader.tour is Some(tour) && tour.overview is Some(overview) else {
    return
  }
  let (start, _) = chapter_bounds(tour, overview, i)
  guide_step(start - tour.index)
}
