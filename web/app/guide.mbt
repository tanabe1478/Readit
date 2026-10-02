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
  let absolute = reader.workspace.absolute(value)
  let key = control_key(value)
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
/// A control path relative to the root when it lies inside, else absolute.
fn control_key(value : String) -> String {
  let root = reader.workspace.root
  let absolute = reader.workspace.absolute(value)
  if @core.starts_with(absolute, root + "/") {
    @core.slice(absolute, root.length() + 1, absolute.length())
  } else {
    absolute
  }
}

///|
fn control_text(path : String) -> String raise Failure {
  match known_text(path) {
    Some(t) => t
    None => fail("external definition is not a supported text file")
  }
}

///|
/// The source range one anchor names, checked against current text.
fn anchor_range(
  args : Json,
  path : String,
  expected : String,
) -> (String, Int, Int) raise Failure {
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
  (source, start, end)
}

///|
/// Validate one step against current text. Texts must already be loaded.
/// Step kinds belong to prepared tours; a single guide_show bubble has none.
fn prepare_guide(args : Json, in_tour? : Bool = true) -> Guide raise Failure {
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
  let (source, start, end) = anchor_range(args, path, expected)
  let kind = match json_field(args, "kind") {
    None => "explanation"
    Some(_) if !in_tour => fail("step kinds are supported in prepared tours only")
    Some(String("explanation" | "hypothesis" | "prediction" | "verification" as k)) =>
      k
    Some(_) =>
      fail("kind must be explanation, hypothesis, prediction or verification")
  }
  let prompt = match json_field(args, "prompt") {
    None =>
      if kind == "prediction" {
        fail("prediction steps require prompt")
      } else {
        None
      }
    Some(_) if kind != "prediction" => fail("prompt is for prediction steps only")
    Some(_) => Some(field("prompt", 2000))
  }
  let verifies = match json_field(args, "verifies") {
    None =>
      if kind == "verification" {
        fail("verification steps require verifies")
      } else {
        None
      }
    Some(_) if kind != "verification" =>
      fail("verifies is for verification steps only")
    Some(_) => Some(field("verifies", 128))
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
    kind,
    prompt,
    verifies,
    prediction_error: None,
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
  step_raw_paths(args).filter_map(p => {
    let key = control_path(p) catch { _ => return None }
    Some(key)
  })
}

///|
/// Paths of steps and evidence as the request wrote them.
fn step_raw_paths(args : Json) -> Array[String] {
  let out = []
  let add = (value : Json) => {
    if json_text(value, "path") is Some(p) {
      out.push(p)
    }
  }
  match json_field(args, "steps") {
    Some(Array(steps)) =>
      for s in steps {
        add(s)
      }
    _ => add(args)
  }
  match json_field(args, "overview") {
    Some(Object({ "claims": Array(claims), .. })) =>
      for c in claims {
        if json_field(c, "evidence") is Some(Array(items)) {
          for ev in items {
            add(ev)
          }
        }
      }
    _ => ()
  }
  out
}

///|
/// A verification step must follow the prediction it answers.
fn check_step_links(steps : Array[Guide]) -> Unit raise Failure {
  for i, step in steps {
    guard step.verifies is Some(target) else { continue }
    let mut found = -1
    for j, other in steps {
      if other.id == target {
        found = j
        break
      }
    }
    if found < 0 {
      fail("verifies must name a step in this tour")
    }
    if found >= i {
      fail("verifies must name an earlier step")
    }
    if steps[found].kind != "prediction" {
      fail("verifies must name a prediction step")
    }
  }
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
    if k != "title" &&
      k != "summary" &&
      k != "relationships" &&
      k != "chapters" &&
      k != "reader_context" &&
      k != "claims" {
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
  let reader_context = match o.get("reader_context") {
    None => None
    Some(value) => Some(parse_reader_context(value))
  }
  let claims = match o.get("claims") {
    None => None
    Some(value) => Some(parse_claims(value))
  }
  { title, summary, relationships, chapters: parsed, reader_context, claims }
}

///|
fn parse_reader_context(value : Json) -> ReaderContext raise Failure {
  guard value is Object(o) else { fail("reader_context must be an object") }
  for k in o.keys() {
    if k != "known" && k != "focus" {
      fail("unknown field `\{k}` in reader_context")
    }
  }
  let list = (key : String, max : Int) => {
    let items = match o.get(key) {
      None => []
      Some(Array(items)) => items
      Some(_) => fail("reader_context.\{key} must be an array")
    }
    if items.length() > max {
      fail("reader_context.\{key} allows at most \{max} items")
    }
    items.map(item => {
      match item {
        String(t) if chars_within(t, 200) => t
        _ => fail("reader_context.\{key} items must contain 1..200 characters")
      }
    })
  }
  { known: list("known", 16), focus: list("focus", 8) }
}

///|
/// Claims and their evidence, each checked against current source.
fn parse_claims(value : Json) -> Array[Claim] raise Failure {
  guard value is Array(items) else { fail("claims must be an array") }
  if items.length() > 8 {
    fail("overview allows at most 8 claims")
  }
  let ids : Map[String, Unit] = Map([])
  let claims = []
  for item in items {
    guard item is Object(o) else { fail("claim must be an object") }
    for k in o.keys() {
      if k != "id" && k != "statement" && k != "confidence" && k != "evidence" {
        fail("unknown field `\{k}` in claim")
      }
    }
    let id = match json_text(item, "id") {
      Some(t) if chars_within(t, 128) => t
      _ => fail("claim id must contain 1..128 characters")
    }
    if ids.contains(id) {
      fail("claim ids must be unique")
    }
    ids[id] = ()
    let statement = match json_text(item, "statement") {
      Some(t) if chars_within(t, 1000) => t
      _ => fail("claim statement must contain 1..1000 characters")
    }
    let confidence = match json_text(item, "confidence") {
      Some("source_confirmed" | "inferred" as c) => c
      _ => fail("claim confidence must be source_confirmed or inferred")
    }
    let evidence = match o.get("evidence") {
      Some(Array(list)) if list.length() >= 1 && list.length() <= 8 => list
      _ => fail("each claim needs 1..8 evidence anchors")
    }
    claims.push({
      id,
      statement,
      confidence,
      evidence: evidence.map(parse_evidence),
    })
  }
  claims
}

///|
fn parse_evidence(value : Json) -> Evidence raise Failure {
  guard value is Object(o) else { fail("evidence must be an object") }
  for k in o.keys() {
    if k != "label" &&
      k != "path" &&
      k != "line" &&
      k != "column" &&
      k != "expected_text" {
      fail("unknown field `\{k}` in evidence")
    }
  }
  let label = match json_text(value, "label") {
    Some(t) if chars_within(t, 100) => t
    _ => fail("evidence label must contain 1..100 characters")
  }
  let expected = match json_text(value, "expected_text") {
    Some(t) if chars_within(t, 16000) => t
    _ => fail("evidence expected_text must contain 1..16000 characters")
  }
  guard json_text(value, "path") is Some(raw) else {
    fail("evidence path is required")
  }
  let path = control_path(raw)
  // Definitions outside the project resolve to absolute paths.
  if @core.starts_with(path, "/") {
    fail("evidence path must be a workspace file")
  }
  let (source, start, end) = anchor_range(value, path, expected)
  { label, path, source, start, end }
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
/// Chapter jumps pass `gate=false`: the reader may skip ahead from the
/// overview, but Next on a prediction step waits for their answer.
fn guide_step(direction : Int, gate? : Bool = true) -> Unit {
  validate_guide()
  guard reader.tour is Some(tour) else {
    guide_response("next")
    return
  }
  if reader.guide is Some(g) && g.question_open {
    return
  }
  if gate && direction > 0 && reader.guide is Some(g) && prediction_pending(tour, g) {
    g.prediction_error = Some(
      "予測を記録するか「わからない」を選ぶと次へ進めます。",
    )
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
  let paths = tour.steps.map(g => g.path)
  if tour.overview is Some({ claims: Some(claims), .. }) {
    for c in claims {
      for ev in c.evidence {
        paths.push(ev.path)
      }
    }
  }
  load_texts(paths, () => ())
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
  guide_step(start - tour.index, gate=false)
}

///|
fn tour_prediction(tour : Tour, step_id : String) -> Prediction? {
  for p in tour.predictions {
    if p.step_id == step_id {
      return Some(p)
    }
  }
  None
}

///|
/// Next waits on a prediction step until the reader commits to an answer.
fn prediction_pending(tour : Tour, guide : Guide) -> Bool {
  guide.kind == "prediction" && tour_prediction(tour, guide.id) is None
}

///|
/// Record the reader's prediction locally. No AI is asked to respond.
fn record_prediction(unknown : Bool) -> Unit {
  validate_guide()
  guard reader.tour is Some(tour) && reader.guide is Some(guide) else { return }
  if !prediction_pending(tour, guide) ||
    tour.steps[tour.index].id != guide.id {
    return
  }
  let answer = if unknown {
    None
  } else {
    let text = @core.trim(js_get_value("guide-prediction"))
    if text == "" || @core.char_count(text) > 2000 {
      guide.prediction_error = Some(
        "予測を1〜2,000文字で入力するか、「わからない」を選んでください。",
      )
      return
    }
    Some(text)
  }
  let status = if unknown { "unknown" } else { "answered" }
  tour.predictions.push({ step_id: guide.id, status, answer })
  guide.prediction_error = None
  guide_event({
    "id": guide.id,
    "action": "prediction",
    "tour_id": tour.id,
    "status": status,
    "answer": match answer {
      Some(a) => Json::string(a)
      None => Json::null()
    },
    "workspace": guide.root,
    "path": reader.workspace.absolute(guide.path),
  })
  focus_editor()
}

///|
/// Evidence is numbered across all claims, in display order.
fn evidence_at(overview : Overview, index : Int) -> Evidence? {
  guard overview.claims is Some(claims) else { return None }
  let mut k = 0
  for c in claims {
    for ev in c.evidence {
      if k == index {
        return Some(ev)
      }
      k += 1
    }
  }
  None
}

///|
fn evidence_stale(ev : Evidence) -> Bool {
  match known_text(ev.path) {
    Some(text) => text != ev.source
    None => reader.disk_cache.contains(ev.path)
  }
}

///|
/// Show a claim's evidence as a detour: the tour position, visited history and
/// chapter progress stay as they are, and the overview tab remains.
fn open_evidence(arg : String) -> Unit {
  guard @core.parse_natural(arg) is Some(index) else { return }
  guard reader.tour is Some(tour) &&
    tour.overview is Some(overview) &&
    evidence_at(overview, index) is Some(ev) else {
    return
  }
  if dialog_open() {
    return
  }
  let root = tour.steps[0].root
  load_texts([ev.path], () => {
    let text = control_text(ev.path) catch { _ => "\u{0}" }
    if reader.workspace.root != root || text != ev.source {
      say("ソースが変更されています。このガイドを更新してください。")
      return
    }
    open_range(ev.path, ev.source, ev.start, ev.end, true, () => ())
  })
}
