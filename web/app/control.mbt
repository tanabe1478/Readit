// Requests relayed from the MCP control socket.

///|
fn opt_string(value : String?) -> Json {
  match value {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn opt_int(value : Int?) -> Json {
  match value {
    Some(v) => Json::number(v.to_double())
    None => Json::null()
  }
}

///|
fn num(n : Int) -> Json {
  Json::number(n.to_double())
}

///|
/// Visible first and last lines of the main editor, one-based.
fn viewport_lines() -> (Int, Int)? {
  guard current_editor() is Some(e) else { return None }
  if reader.compare || reader.overview_visible {
    return None
  }
  let top = js_scroll_top("editor-scroll")
  let height = js_client_height("editor-scroll")
  if height <= 0.0 {
    return None
  }
  let lh = line_height()
  let first = (top / lh)
    .floor()
    .to_int()
    .clamp(min=0, max=(e.line_count() - 1).max(0))
  let last = ((top + height) / lh)
    .ceil()
    .to_int()
    .clamp(min=first, max=(e.line_count() - 1).max(0))
  Some((first + 1, last + 1))
}

///|
fn control_state() -> Json {
  validate_guide()
  let selection = match current_editor() {
    None => Json::null()
    Some(e) => {
      let (start, end) = e.selection()
      let s = @core.position_at(e.text, start)
      let t = @core.position_at(e.text, end)
      let selected = @core.slice(e.text, start, end)
      {
        "start_line": num(s.line + 1),
        "start_column": num(s.character + 1),
        "end_line": num(t.line + 1),
        "end_column": num(t.character + 1),
        "text": @core.take_chars(selected, 16000),
        "truncated": @core.char_count(selected) > 16000,
        "viewport": match viewport_lines() {
          Some((a, b)) => { "start_line": num(a), "end_line": num(b) }
          None => Json::null()
        },
      }
    }
  }
  let pos = cursor_position()
  let root = reader.workspace.root
  {
    "workspace": root,
    "active_path": opt_string(
      reader.selected.map(p => reader.workspace.absolute(p)),
    ),
    "cursor": { "line": num(pos.line + 1), "column": num(pos.character + 1) },
    "selection": selection,
    "tabs": Json::array(
      reader.tabs.map(p => {
        "path": reader.workspace.absolute(p),
        "dirty": match reader.workspace.document(p) {
          Some(d) => Json::boolean(d.dirty())
          None => Json::boolean(false)
        },
        "read_only": reader.external.contains(p),
      }),
    ),
    "view": {
      "diff": reader.compare,
      "file_tree": reader.sidebar,
      "file_tree_width": Json::number(reader.sidebar_width),
      "wrap": reader.wrap,
    },
    "pinned": match reader.pinned {
      Some(p) =>
        {
          "path": if @core.starts_with(p.path, "/") {
            p.path
          } else {
            p.root + "/" + p.path
          },
          "line": num(p.line),
          "source_changed": pinned_changed(),
          "read_only": true,
        }
      None => Json::null()
    },
    "guide": match reader.guide {
      Some(g) =>
        {
          "id": g.id,
          "title": g.title,
          "kind": g.kind,
          "question_open": g.question_open,
          "question": opt_string(g.question),
          "pending_question": opt_int(g.pending_question),
          "answer": opt_string(g.answer),
          "pending_next": g.pending_next is Some(_),
        }
      None => Json::null()
    },
    "guide_event_sequence": num(reader.guide_sequence),
    "overview_visible": reader.overview_visible,
    "guide_tour": match reader.tour {
      Some(t) =>
        {
          "id": t.id,
          "index": num(t.index),
          "total": num(t.steps.length()),
          "visited_through": num(t.visited),
          "overview": match t.overview {
            Some(o) => o.to_json()
            None => Json::null()
          },
          "seen_steps": Json::array(sorted(t.seen).map(Json::string)),
          "steps": Json::array(
            t.steps.map(g => { "id": g.id, "title": g.title, "kind": g.kind }),
          ),
          "predictions": Json::array(
            t.steps
            .filter_map(g => tour_prediction(t, g.id))
            .map(p => {
              "step_id": p.step_id,
              "status": p.status,
              "answer": opt_string(p.answer),
            }),
          ),
        }
      None => Json::null()
    },
    "busy": reader.nav_busy,
    "dialog_open": reader.dialog is Some(_) || reader.pending is Some(_),
  }
}

///|
fn sorted(values : Array[String]) -> Array[String] {
  let copy = values.copy()
  @core.sort_strings(copy)
  copy
}

///|
fn dialog_open() -> Bool {
  reader.dialog is Some(_) || reader.pending is Some(_)
}

///|
/// A positive integer argument, or the default when absent.
fn positive(args : Json, key : String, default : Int) -> Int raise Failure {
  match json_field(args, key) {
    None => default
    Some(Number(n, ..)) if n > 0.0 && n == n.floor() => n.to_int()
    Some(_) => fail("\{key} must be a positive integer")
  }
}

///|
/// Handle one control request and reply once, possibly after async work.
fn control_call(
  op : String,
  args : Json,
  reply : (Result[Json, String]) -> Unit,
) -> Unit {
  if op == "readit_state" {
    reply(Ok(control_state()))
    return
  }
  if json_text(args, "workspace") != Some(reader.workspace.root) {
    reply(Err("workspace changed or does not match; call readit_state first"))
    return
  }
  // Load unopened texts the request refers to, then run it synchronously.
  let paths = match op {
    "readit_read" | "readit_open" | "readit_pin" =>
      match json_text(args, "path") {
        Some(p) => {
          let key = control_path(p) catch { _ => "" }
          if key == "" {
            []
          } else {
            [key]
          }
        }
        None => []
      }
    "readit_guide_show" | "readit_guide_load" | "readit_guide_revise" => {
      let own = step_paths(args)
      if reader.tour is Some(t) {
        for g in t.steps {
          own.push(g.path)
        }
      }
      own
    }
    _ => []
  }
  load_texts(paths, () => {
    let result : Result[Json, String] = try
      control_sync(op, args, reply)
    catch {
      Failure(m) => Err(@core.failure_text(m))
    } noraise {
      value => value
    }
    match result {
      Ok(Null) => ()
      other => reply(other)
    }
  })
}

///|
/// Returns Ok(null) when the reply is sent later.
fn control_sync(
  op : String,
  args : Json,
  reply : (Result[Json, String]) -> Unit,
) -> Result[Json, String] raise Failure {
  match op {
    "readit_pin" => {
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      let path = control_path(json_text(args, "path").unwrap_or(""))
      match pin_code(path, positive(args, "line", 1)) {
        Ok(_) => Ok(control_state())
        Err(e) => Err(e)
      }
    }
    "readit_unpin" => {
      reader.pinned = None
      Ok(control_state())
    }
    "readit_guide_events" => {
      validate_guide()
      guard json_int(args, "after") is Some(after) else {
        fail("after is required")
      }
      let events = reader.guide_events.filter(e => {
        match e {
          { "sequence": Number(s, ..), .. } => s.to_int() > after
          _ => false
        }
      })
      let first = match reader.guide_events.get(0) {
        Some({ "sequence": Number(s, ..), .. }) => s.to_int()
        _ => 0
      }
      Ok({
        "events": Json::array(events),
        "latest_sequence": num(reader.guide_sequence),
        "truncated": reader.guide_events.length() > 0 && after + 1 < first,
      })
    }
    "readit_guide_load" => {
      validate_guide()
      if json_int(args, "event_sequence") != Some(reader.guide_sequence) {
        fail("read guide events before loading")
      }
      let id = match json_text(args, "id") {
        Some(i) if i != "" && i.length() <= 128 => i
        _ => fail("id required")
      }
      let steps = prepare_steps(args, false)
      check_step_links(steps)
      let overview = match json_field(args, "overview") {
        Some(v) => Some(parse_overview(v, steps))
        None => None
      }
      activate_guide(steps[0].copy(), result => {
        match result {
          Err(e) => reply(Err(e))
          Ok(_) => {
            let show = overview is Some(_)
            reader.tour = Some({
              id,
              steps,
              index: 0,
              visited: 0,
              overview,
              seen: [],
              predictions: [],
            })
            reader.overview_visible = show
            reader.overview_tab = show
            if show {
              reader.focus = "body"
            } else if reader.tour is Some(t) {
              t.seen.push(t.steps[0].id)
            }
            reply(Ok(control_state()))
          }
        }
      })
      Ok(Json::null())
    }
    "readit_guide_revise" => {
      validate_guide()
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      if json_int(args, "event_sequence") != Some(reader.guide_sequence) {
        fail("navigation changed; read state and regenerate the unread steps")
      }
      let steps = prepare_steps(args, true)
      guard reader.tour is Some(tour) else { fail("tour ended") }
      if json_text(args, "id") != Some(tour.id) {
        fail("tour changed")
      }
      guard json_int(args, "question_sequence") is Some(question) else {
        fail("question_sequence required")
      }
      let answer = match json_text(args, "answer") {
        Some(a) if chars_within(a, 4000) => a
        _ => fail("answer required, max 4000 characters")
      }
      let updated = tour.steps.map(g => g.copy())
      if reader.guide is Some(g) {
        updated[tour.index] = g.copy()
      }
      let mut target = -1
      for i, g in updated {
        if g.pending_question == Some(question) {
          target = i
          break
        }
      }
      if target < 0 {
        fail("question no longer pending")
      }
      if control_text(updated[target].path) != updated[target].source {
        fail("question source changed")
      }
      let prefix = tour.visited + 1
      if prefix + steps.length() > 32 {
        fail("tour exceeds 32 steps")
      }
      let ids : Map[String, Unit] = Map([])
      for g in updated[0:prefix] {
        ids[g.id] = ()
      }
      for step in steps {
        if ids.contains(step.id) {
          fail("step id duplicates retained history")
        }
        ids[step.id] = ()
      }
      updated[target].answer = Some(answer)
      updated[target].pending_question = None
      let kept = updated[0:prefix].to_owned()
      for s in steps {
        kept.push(s)
      }
      check_step_links(kept)
      let overview = match json_field(args, "overview") {
        Some(value) => Some(parse_overview(value, kept))
        None =>
          if tour.overview is Some(_) {
            fail("include updated overview when revising a chaptered tour")
          } else {
            None
          }
      }
      if reader.guide is Some(_) {
        reader.guide = Some(kept[tour.index])
      }
      let seen = tour.seen.filter(id => kept.iter().any(g => g.id == id))
      tour.seen.clear()
      for id in seen {
        tour.seen.push(id)
      }
      // Predictions belong to displayed steps, which the revision keeps.
      let predictions = tour.predictions.filter(p => {
        kept.iter().any(g => g.id == p.step_id)
      })
      tour.predictions.clear()
      for p in predictions {
        tour.predictions.push(p)
      }
      tour.steps = kept
      tour.overview = overview
      Ok(control_state())
    }
    "readit_guide_show" => {
      validate_guide()
      guard json_int(args, "event_sequence") is Some(sequence) else {
        fail("event_sequence is required")
      }
      if sequence != reader.guide_sequence {
        fail("user responded or moved; read guide events before continuing")
      }
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      let guide = prepare_guide(args, in_tour=false)
      activate_guide(guide, result => {
        match result {
          Err(e) => reply(Err(e))
          Ok(_) => {
            reader.tour = None
            reader.overview_visible = false
            reader.overview_tab = false
            reply(Ok(control_state()))
          }
        }
      })
      Ok(Json::null())
    }
    "readit_guide_answer" => {
      validate_guide()
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      guard reader.guide is Some(guide) else {
        fail("guide ended or source changed")
      }
      guard json_int(args, "question_sequence") is Some(sequence) else {
        fail("question_sequence is required")
      }
      if json_text(args, "id") != Some(guide.id) ||
        guide.pending_question != Some(sequence) {
        fail("question is no longer pending; read guide events")
      }
      guard json_text(args, "body") is Some(answer) else {
        fail("body is required")
      }
      if !chars_within(answer, 4000) {
        fail("answer must contain 1..4000 characters")
      }
      guide.answer = Some(answer)
      guide.pending_question = None
      js_set_value("guide-question", "")
      Ok(control_state())
    }
    "readit_guide_clear" => {
      guide_response("cleared")
      Ok(control_state())
    }
    "readit_files" => {
      let filter = @core.lower(json_text(args, "filter").unwrap_or(""))
      let offset = json_int(args, "offset").unwrap_or(0)
      let limit = positive(args, "limit", 200).min(500)
      let files = reader.workspace.files.filter(path => {
        !reader.external.contains(path) &&
        !reader.untitled.contains(path) &&
        @core.contains(@core.lower(path), filter)
      })
      let page = []
      for i in offset..<(offset + limit).min(files.length()) {
        let path = files[i]
        page.push(
          (
            {
              "path": path,
              "dirty": is_dirty(path),
              "language": @core.language(path),
            } : Json),
        )
      }
      Ok({
        "total": num(files.length()),
        "files": Json::array(page),
        "next_offset": if offset + limit < files.length() {
          num(offset + limit)
        } else {
          Json::null()
        },
      })
    }
    "readit_read" => {
      let path = control_path(json_text(args, "path").unwrap_or(""))
      let text = control_text(path)
      let start = positive(args, "start_line", 1)
      let count = positive(args, "line_count", 120).min(400)
      let lines = @core.split_newlines(text)
      if start > lines.length() {
        fail("start_line is outside the file")
      }
      let end = (start - 1 + count).min(lines.length())
      let content = lines[start - 1:end].to_owned().join("\n")
      if content.length() > 200_000 {
        fail("requested lines are too large; request fewer lines")
      }
      Ok({
        "path": reader.workspace.absolute(path),
        "start_line": num(start),
        "end_line": num(end),
        "total_lines": num(lines.length()),
        "text": content,
        "unsaved": match reader.workspace.document(path) {
          Some(d) => Json::boolean(d.dirty())
          None => Json::boolean(false)
        },
      })
    }
    "readit_search" => {
      let query = match json_text(args, "query") {
        Some(q) if q != "" => q
        _ => fail("query must not be empty")
      }
      let limit = positive(args, "limit", 100).min(300)
      rpc(
        "search",
        {
          "root": reader.workspace.root,
          "query": query,
          "mode": "literal",
          "limit": num(limit),
          "overlays": overlays(),
        },
        result => {
          match result {
            Ok({ "matches": matches, "truncated": truncated, .. }) =>
              reply(
                Ok({
                  "matches": matches,
                  "truncated": truncated,
                  "kind": "literal text search",
                }),
              )
            Ok(_) => reply(Err("search failed"))
            Err(e) => reply(Err(e))
          }
        },
      )
      Ok(Json::null())
    }
    "readit_open" => {
      if dialog_open() {
        fail("finish or dismiss the current editor dialog first")
      }
      let path = control_path(json_text(args, "path").unwrap_or(""))
      let text = control_text(path)
      let line = positive(args, "line", 1)
      let column = positive(args, "column", 1)
      let start = @core.offset_at(text, line, column)
      let end_line = positive(args, "end_line", line)
      let end_column = positive(args, "end_column", column)
      let end = @core.offset_at(text, end_line, end_column)
      if end < start {
        fail("selection end must follow its start")
      }
      open_range(path, text, start, end, false, () => {
        if reader.selected == Some(path) {
          reply(Ok(control_state()))
        } else {
          reply(Err("editor could not open the file"))
        }
      })
      Ok(Json::null())
    }
    "readit_history" => {
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      let forward = match json_text(args, "direction") {
        Some("back") => false
        Some("forward") => true
        _ => fail("direction must be back or forward")
      }
      navigate(forward)
      after(0, () => reply(Ok(control_state()))) |> ignore
      Ok(Json::null())
    }
    "readit_view" => {
      if dialog_open() {
        fail("finish the editor dialog first")
      }
      for key in ["diff", "file_tree", "wrap", "overview"] {
        match json_field(args, key) {
          None | Some(True) | Some(False) => ()
          Some(_) => fail("\{key} must be boolean")
        }
      }
      if json_field(args, "overview") is Some(value) {
        let on = value is True
        let loaded = match reader.tour {
          Some(t) => t.overview is Some(_)
          None => false
        }
        if on && !loaded {
          fail("no overview loaded")
        }
        if on {
          show_overview()
        } else {
          reader.overview_visible = false
        }
      }
      if json_field(args, "file_tree") is Some(v) {
        reader.sidebar = v is True
      }
      if json_field(args, "wrap") is Some(v) && reader.wrap != (v is True) {
        toggle_wrap()
      }
      if json_field(args, "diff") is Some(v) && reader.compare != (v is True) {
        toggle_compare()
      }
      clear_pointer()
      Ok(control_state())
    }
    "readit_symbol" => {
      control_symbol(args, reply)
      Ok(Json::null())
    }
    _ => fail("unknown editor operation")
  }
}

///|
fn control_symbol(args : Json, reply : (Result[Json, String]) -> Unit) -> Unit {
  if dialog_open() || reader.nav_busy {
    reply(Err("editor has an active dialog or navigation request"))
    return
  }
  let query = match json_text(args, "kind") {
    Some(k) => @lsp.Query::parse(k)
    None => None
  }
  guard query is Some(query) else {
    reply(Err("invalid symbol query kind"))
    return
  }
  guard reader.selected is Some(path) else {
    reply(Err("open a file first"))
    return
  }
  if reader.untitled.contains(path) {
    reply(Err("save the file with an extension first"))
    return
  }
  guard current_editor() is Some(editor) else {
    reply(Err("no active editor"))
    return
  }
  let position = editor.position()
  let snapshot = snapshot_at(path, position.line, position.character)
  let show = match json_field(args, "show") {
    Some(False) => false
    _ => true
  }
  let serial = reader.nav_serial
  rpc("lsp.query", snapshot_json(query, snapshot), result => {
    match result {
      Err(e) => reply(Err(e))
      Ok(value) => {
        let current = match current_editor() {
          Some(e) => Some(e.position())
          None => None
        }
        if !snapshot_current(snapshot) ||
          reader.selected.map(p => reader.workspace.absolute(p)) !=
          Some(snapshot.path) ||
          current != Some(position) ||
          reader.nav_serial != serial ||
          dialog_open() {
          reply(Err("editor changed during analysis; read its state again"))
          return
        }
        let (targets, information, server) = parse_answer(value)
        reader.control_target_root = reader.workspace.root
        reader.control_targets = targets
        let out : Json = {
          "server": server,
          "targets": Json::array(
            targets.map(t => {
              "path": t.path,
              "line": num(t.line + 1),
              "column": num(t.character + 1),
              "end_line": num(t.end_line + 1),
              "end_column": num(t.end_character + 1),
              "name": t.name,
              "preview": t.preview,
            }),
          ),
          "information": information,
        }
        if show {
          reader.nav_title = query.title()
          reader.nav_targets = targets
          reader.nav_information = if information == "" {
            "\{targets.length()}件 · \{server}"
          } else {
            information
          }
          reader.nav_snapshot = Some(snapshot)
          reader.nav_visible = true
        }
        reply(Ok(out))
      }
    }
  })
}
