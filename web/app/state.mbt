// Window state, ported from the native Reader.

///|
priv struct Document {
  mut path : String
  /// What the file held when read or last saved.
  mut disk : String
  /// Comparison baseline: HEAD in a Git root, otherwise the text when opened.
  mut before : String?
  editor : @editor.Editor
  mut scroll_top : Double
}

///|
fn Document::text(self : Document) -> String {
  self.editor.text
}

///|
fn Document::dirty(self : Document) -> Bool {
  self.disk != self.editor.text
}

///|
fn Document::changed(self : Document) -> Bool {
  match self.before {
    Some(b) => b != self.editor.text
    None => true
  }
}

///|
priv struct Workspace {
  mut root : String
  mut git : Bool
  /// Files known to exist: shown in a loaded folder, read, or checked.
  known_files : Map[String, Unit]
  /// Children of the folders loaded so far, by folder ("" is the root).
  listed : Map[String, Array[@core.TreeChild]]
  /// Folders requested and not answered yet.
  loading : Map[String, Unit]
  /// The file a newly opened project shows first.
  mut first : String?
  mut changed : Map[String, Unit]
  documents : Array[Document]
  mut warnings : Array[String]
}

///|
fn Workspace::index_of(self : Workspace, path : String) -> Int? {
  for i, d in self.documents {
    if d.path == path {
      return Some(i)
    }
  }
  None
}

///|
fn Workspace::document(self : Workspace, path : String) -> Document? {
  match self.index_of(path) {
    Some(i) => Some(self.documents[i])
    None => None
  }
}

///|
fn Workspace::known(self : Workspace, path : String) -> Bool {
  self.index_of(path) is Some(_) || self.known_files.contains(path)
}

///|
/// Whether a path is a folder shown in the tree.
fn Workspace::is_folder(self : Workspace, path : String) -> Bool {
  match self.listed.get(@core.parent_of(path)) {
    Some(children) => {
      let name = @core.base_name(path)
      children.iter().any(c => c.dir && c.name == name)
    }
    None => false
  }
}

///|
/// Update the listing from a server summary.
fn Workspace::apply(self : Workspace, summary : Json) -> Unit {
  guard summary is Object(o) else { return }
  if o.get("root") is Some(String(root)) {
    if root != self.root {
      self.known_files.clear()
      self.listed.clear()
      self.loading.clear()
    }
    self.root = root
  }
  if o.get("git") is Some(git) {
    self.git = git is True
  }
  if o.get("first") is Some(first) {
    self.first = match first {
      String(p) => Some(p)
      _ => None
    }
  }
  self.changed = Map([])
  for p in strings(o.get("changed")) {
    self.changed[p] = ()
  }
  self.warnings = strings(o.get("warnings"))
}

///|
fn strings(value : Json?) -> Array[String] {
  match value {
    Some(Array(items)) =>
      items.filter_map(v => {
        match v {
          String(s) => Some(s)
          _ => None
        }
      })
    _ => []
  }
}

///|
fn Workspace::absolute(self : Workspace, path : String) -> String {
  if @core.starts_with(path, "/") {
    path
  } else {
    self.root + "/" + path
  }
}

///|
fn Workspace::name(self : Workspace) -> String {
  @core.base_name(self.root)
}

///|
priv struct Target {
  path : String
  line : Int
  character : Int
  end_line : Int
  end_character : Int
  name : String
  detail : String
  preview : String
}

///|
fn Target::parse(value : Json) -> Target? {
  match value {
    {
      "path": String(path),
      "line": Number(line, ..),
      "character": Number(character, ..),
      "end_line": Number(end_line, ..),
      "end_character": Number(end_character, ..),
      "name": String(name),
      "detail": String(detail),
      "preview": String(preview),
      ..
    } =>
      Some({
        path,
        line: line.to_int(),
        character: character.to_int(),
        end_line: end_line.to_int(),
        end_character: end_character.to_int(),
        name,
        detail,
        preview,
      })
    _ => None
  }
}

///|
/// What an LSP query was computed from: path, position and every loaded text.
priv struct Snapshot {
  root : String
  path : String
  line : Int
  character : Int
  documents : Array[(String, String)]
}

///|
priv struct Guide {
  id : String
  root : String
  path : String
  source : String
  start : Int
  end : Int
  title : String
  body : String
  /// explanation, hypothesis, prediction or verification.
  kind : String
  /// The question a prediction step asks the reader.
  prompt : String?
  /// The earlier prediction step a verification step answers.
  verifies : String?
  mut prediction_error : String?
  mut question_open : Bool
  mut pending_question : Int?
  mut question : String?
  mut answer : String?
  mut question_error : String?
  mut pending_next : Double?
  /// Manual position after dragging, in viewport pixels.
  mut position : (Double, Double)?
  mut drag : (Double, Double, Double, Double)?
}

///|
fn Guide::copy(self : Guide) -> Guide {
  { ..self, }
}

///|
priv struct Chapter {
  title : String
  summary : String
  start_step : String
}

///|
/// Source text backing a claim, checked like a step's expected_text.
priv struct Evidence {
  label : String
  path : String
  source : String
  start : Int
  end : Int
}

///|
priv struct Claim {
  id : String
  statement : String
  /// source_confirmed or inferred.
  confidence : String
  evidence : Array[Evidence]
}

///|
/// What the explanation assumes the reader knows. Kept in memory only.
priv struct ReaderContext {
  known : Array[String]
  focus : Array[String]
}

///|
priv struct Overview {
  title : String
  summary : String
  relationships : String
  chapters : Array[Chapter]
  reader_context : ReaderContext?
  claims : Array[Claim]?
}

///|
fn Overview::to_json(self : Overview) -> Json {
  let out : Map[String, Json] = {
    "title": self.title,
    "summary": self.summary,
    "relationships": self.relationships,
    "chapters": Json::array(
      self.chapters.map(c => {
        "title": c.title,
        "summary": c.summary,
        "start_step": c.start_step,
      }),
    ),
  }
  if self.reader_context is Some(c) {
    out["reader_context"] = {
      "known": Json::array(c.known.map(Json::string)),
      "focus": Json::array(c.focus.map(Json::string)),
    }
  }
  if self.claims is Some(claims) {
    out["claims"] = Json::array(
      claims.map(c => {
        "id": c.id,
        "statement": c.statement,
        "confidence": c.confidence,
        "evidence": Json::array(
          c.evidence.map(ev => {
            let at = @core.position_at(ev.source, ev.start)
            {
              "label": ev.label,
              "path": ev.path,
              "line": Json::number((at.line + 1).to_double()),
              "column": Json::number((at.character + 1).to_double()),
              "expected_text": @core.slice(ev.source, ev.start, ev.end),
            }
          }),
        ),
      }),
    )
  }
  Json::object(out)
}

///|
/// The reader's own prediction, recorded before reading on. Never graded.
priv struct Prediction {
  step_id : String
  /// answered or unknown.
  status : String
  answer : String?
}

///|
priv struct Tour {
  id : String
  mut steps : Array[Guide]
  mut index : Int
  mut visited : Int
  mut overview : Overview?
  seen : Array[String]
  predictions : Array[Prediction]
}

///|
priv struct Pinned {
  root : String
  path : String
  source : String
  line : Int
  editor : @editor.Editor
  mut scroll_top : Double
}

///|
priv enum Dialog {
  Quick
  Commands
  WorkspaceSearch
  Goto
  NewFolder
  Rename
  SaveAs
  Replace
  Help
  Navigation
  Information
  OpenFolder
} derive(Eq)

///|
priv enum Pending {
  Close(String)
  CloseAll
  Quit
  Switch(String, String?)
  Reload
  Delete(String)
}

///|
priv struct Location {
  mut path : String
  mut line : Int
  mut column : Int
}

///|
priv struct Pick {
  label : String
  detail : String
  path : String?
  line : Int?
  command : String?
  target : Int?
}

///|
priv struct PointerPreview {
  path : String
  start : Int
  end : Int
  rect : Rect
  definition : Bool
  mut targets : Array[Target]
  mut information : String
  snapshot : Snapshot
}

///|
priv struct ContextMenu {
  x : Double
  y : Double
}

///|
priv struct Reader {
  mut pinned : Pinned?
  mut guide : Guide?
  mut tour : Tour?
  mut overview_visible : Bool
  mut overview_tab : Bool
  guide_events : Array[Json]
  mut guide_sequence : Int
  mut control_targets : Array[Target]
  mut control_target_root : String
  mut pointer : PointerPreview?
  mut pointer_timer : Int?
  mut pointer_serial : Int
  mut popup : Rect?
  mut nav_serial : Int
  mut nav_busy : Bool
  mut nav_visible : Bool
  mut nav_title : String
  mut nav_targets : Array[Target]
  mut nav_information : String
  mut nav_snapshot : Snapshot?
  external : Map[String, Unit]
  workspace : Workspace
  tabs : Array[String]
  mut selected : String?
  untitled : Map[String, Unit]
  closed : Array[String]
  mut dialog : Dialog?
  mut pending : Pending?
  mut save_source : String?
  mut saving_all : Bool
  mut rename_source : String?
  mut pick_index : Int
  mut query : String
  mut replacement : String
  /// Folders open in the tree. Folders start closed.
  expanded : Map[String, Unit]
  mut tree_target : String?
  mut reading_path : Bool
  mut sidebar : Bool
  mut sidebar_width : Double
  mut sidebar_drag : (Double, Double)?
  mut wrap : Bool
  mut font_size : Double
  mut compare : Bool
  mut diff_rows : Array[@core.DiffRow]
  mut message : String
  history : Array[Location]
  mut history_index : Int
  mut focus : String
  mut search_open : Bool
  mut search_query : String
  mut search_case : Bool
  mut search_regex : Bool
  mut search_index : Int
  mut search_matches : Array[(Int, Int)]
  mut search_error : String
  mut search_key : String
  mut workspace_picks : Array[Pick]
  mut quick_picks : Array[Pick]
  mut quick_serial : Int
  mut workspace_search_serial : Int
  mut workspace_search_timer : Int?
  mut menu : String?
  mut context_menu : ContextMenu?
  mut mouse_selecting : Bool
  mut mouse_x : Double
  mut mouse_y : Double
  mut chord : String?
  /// Disk text of unopened files, for stale checks without blocking rendering.
  disk_cache : Map[String, String?]
  mut disk_refresh : Double
  mut control_socket : String
  /// Window name from the server's --label.
  mut label : String
  mut connected : Bool
  mut superseded : Bool
  mut quitting : Bool
  mut loading : String?
  mut guide_height : Double
  mut guide_height_key : String
  /// The overview's reader context section is expanded.
  mut context_open : Bool
}

///|
fn empty_workspace() -> Workspace {
  {
    root: "",
    git: false,
    known_files: Map([]),
    listed: Map([]),
    loading: Map([]),
    first: None,
    changed: Map([]),
    documents: [],
    warnings: [],
  }
}

///|
let reader : Reader = {
  pinned: None,
  guide: None,
  tour: None,
  overview_visible: false,
  overview_tab: false,
  guide_events: [],
  guide_sequence: 0,
  control_targets: [],
  control_target_root: "",
  pointer: None,
  pointer_timer: None,
  pointer_serial: 0,
  popup: None,
  nav_serial: 0,
  nav_busy: false,
  nav_visible: false,
  nav_title: "",
  nav_targets: [],
  nav_information: "",
  nav_snapshot: None,
  external: Map([]),
  workspace: empty_workspace(),
  tabs: [],
  selected: None,
  untitled: Map([]),
  closed: [],
  dialog: None,
  pending: None,
  save_source: None,
  saving_all: false,
  rename_source: None,
  pick_index: 0,
  query: "",
  replacement: "",
  expanded: Map([]),
  tree_target: None,
  reading_path: false,
  sidebar: true,
  sidebar_width: 245.0,
  sidebar_drag: None,
  wrap: false,
  font_size: 14.0,
  compare: false,
  diff_rows: [],
  message: "⌘P ファイルを開く · ⌘S 保存 · ⇧⌘P コマンド",
  history: [],
  history_index: 0,
  focus: "editor",
  search_open: false,
  search_query: "",
  search_case: false,
  search_regex: false,
  search_index: 0,
  search_matches: [],
  search_error: "",
  search_key: "",
  workspace_picks: [],
  quick_picks: [],
  quick_serial: 0,
  workspace_search_serial: 0,
  workspace_search_timer: None,
  menu: None,
  context_menu: None,
  mouse_selecting: false,
  mouse_x: 0.0,
  mouse_y: 0.0,
  chord: None,
  disk_cache: Map([]),
  disk_refresh: 0.0,
  control_socket: "",
  label: "",
  connected: false,
  superseded: false,
  quitting: false,
  loading: None,
  guide_height: 0.0,
  guide_height_key: "",
  context_open: false,
}
