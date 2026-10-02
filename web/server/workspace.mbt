// Project files on disk. The browser keeps open buffers; this side lists,
// reads and changes files with the same checks as the native editor.

///|
let max_bytes : Int = 256 * 1024

///|
/// Cap of the server-side file index used by quick open and project search.
/// The browser never receives the whole index; folders load as they open.
let max_files : Int = 50000

///|
pub struct Workspace {
  root : String
  git : Bool
  /// Every listed file, built on first use and dropped when files change.
  mut index : Array[String]?
  /// The index in lowercase, for quick open.
  mut lowered : Array[String]?
  changed : Map[String, Unit]
  warnings : Array[String]
  mut session : Json
}

///|
fn node_fail(e : NodeError) -> Unit raise Failure {
  fail(e.message())
}

///|
fn git_output(root : String, args : Array[String]) -> String raise Failure {
  let result = run("git", ["-C", root, ..args]) catch {
    e => {
      node_fail(e)
      return ""
    }
  }
  if result.status == 0 {
    result.stdout
  } else {
    fail(@core.trim(result.stderr))
  }
}

///|
/// Paths Git already considers changed, read once so the tree needs no file content.
fn changed_paths(root : String) -> Map[String, Unit] {
  let changed : Map[String, Unit] = Map([])
  let bytes = git_output(root, [
    "status", "--porcelain", "-z", "--untracked-files=all",
  ]) catch {
    _ => return changed
  }
  let records = bytes.split("\u{0}").map(r => r.to_owned()).collect()
  let mut i = 0
  while i < records.length() {
    let record = records[i]
    i += 1
    if record.length() < 4 {
      continue
    }
    // A rename or copy is followed by its source path in a separate record.
    if record[0] == 'R' || record[0] == 'C' {
      i += 1
    }
    if decode_utf8(@core.slice(record, 3, record.length())) is Some(path) {
      changed[path] = ()
    }
  }
  changed
}

///|
/// Split a relative path into normal components, or None if any is unsafe.
fn components(relative : String) -> Array[String]? {
  if relative == "" || @core.starts_with(relative, "/") {
    return None
  }
  let parts = relative.split("/").map(p => p.to_owned()).collect()
  for part in parts {
    if part == "" || part == "." || part == ".." {
      return None
    }
  }
  Some(parts)
}

///|
fn is_inside(root : String, path : String) -> Bool {
  path == root ||
  @core.starts_with(
    path,
    if @core.ends_with(root, "/") {
      root
    } else {
      root + "/"
    },
  )
}

///|
/// A path inside the root that is not reached through a symbolic link.
pub fn safe_path(root : String, relative : String) -> String raise Failure {
  guard components(relative) is Some(parts) else {
    fail("リポジトリ内の相対パスが必要です")
  }
  let path = path_join(root, relative)
  let canonical = realpath(path) catch {
    e => {
      fail("\{relative}: \{e.message()}")
      ""
    }
  }
  if !is_inside(root, canonical) {
    fail("外部へのリンクを除外: \{relative}")
  }
  let mut current = root
  for part in parts {
    current = path_join(current, part)
    match lstat_kind(current) {
      "symlink" => fail("シンボリックリンクを除外: \{relative}")
      "" => fail("\{relative}: not found")
      _ => ()
    }
  }
  path
}

///|
fn skipped(relative : String) -> Bool {
  for part in relative.split("/") {
    let name = part.to_owned()
    match name {
      ".git"
      | ".readit"
      | "node_modules"
      | "target"
      | "dist"
      | "build"
      | ".venv"
      | "vendor"
      | "artifacts"
      | "__pycache__" => return true
      _ => if @core.starts_with(name, ".env") { return true }
    }
  }
  match @core.base_name(relative) {
    "Cargo.lock" | "package-lock.json" | "pnpm-lock.yaml" | "yarn.lock" => true
    _ => false
  }
}

///|
fn join_relative(parent : String, name : String) -> String {
  if parent == "" {
    name
  } else {
    parent + "/" + name
  }
}

///|
fn walk(
  root : String,
  at : String,
  paths : Array[String],
  warnings : Array[String],
  depth : Int,
) -> Unit raise Failure {
  if depth > 12 || paths.length() >= max_files {
    return
  }
  let entries = read_dir(path_join(root, at)) catch {
    e => {
      node_fail(e)
      []
    }
  }
  entries.sort_by((a, b) => @core.lex_compare(a.0, b.0))
  for entry in entries {
    let (name, kind) = entry
    let rel = join_relative(at, name)
    if skipped(rel) {
      continue
    }
    match kind {
      "symlink" => warnings.push("リンクを除外: \{rel}")
      "dir" =>
        // A repository inside the folder lists what Git lists, so its
        // ignored build output does not crowd out the sources.
        if lstat_kind(path_join(root, rel + "/.git")) == "" ||
          !git_listing(root, rel, paths, warnings) {
          walk(root, rel, paths, warnings, depth + 1)
        }
      "file" => paths.push(rel)
      _ => ()
    }
    if paths.length() >= max_files {
      warnings.push("最大\{max_files}ファイルまで読み込みました")
      break
    }
  }
}

///|
/// Paths Git tracks or would track under `at`, relative to `root`.
fn git_files(
  root : String,
  at : String,
  warnings : Array[String],
) -> Array[String] raise Failure {
  let bytes = git_output(path_join(root, at), [
    "ls-files", "-z", "--cached", "--others", "--exclude-standard",
  ])
  let out = []
  for piece in bytes.split("\u{0}") {
    let raw = piece.to_owned()
    if raw == "" {
      continue
    }
    match decode_utf8(raw) {
      Some(path) => out.push(join_relative(at, path))
      None => warnings.push("UTF-8でないファイル名を除外")
    }
  }
  out
}

///|
/// List a repository found while walking a folder. False when Git cannot.
fn git_listing(
  root : String,
  at : String,
  paths : Array[String],
  warnings : Array[String],
) -> Bool {
  let found = git_files(root, at, warnings) catch { _ => return false }
  for p in found {
    if paths.length() >= max_files {
      break
    }
    paths.push(p)
  }
  true
}

///|
pub fn Workspace::load(root : String) -> Workspace raise Failure {
  let root = realpath(root) catch {
    e => {
      node_fail(e)
      ""
    }
  }
  if stat_kind(root) != "dir" {
    fail("フォルダを指定してください")
  }
  let warnings = []
  let git_root = git_output(root, ["rev-parse", "--show-toplevel"]) catch {
    _ => ""
  }
  let git_root = match decode_utf8(git_root) {
    Some(p) => @core.trim(p)
    None => ""
  }
  let git = git_root != "" &&
    (realpath(git_root) catch { _ => git_root }) == root
  if git_root != "" && !git {
    warnings.push(
      "Git差分はリポジトリのルートを指定した場合のみ表示します",
    )
  }
  let changed = if git { changed_paths(root) } else { Map([]) }
  let session_file = path_join(root, ".readit/session.json")
  let session = if lstat_kind(session_file) != "" {
    let loaded : Result[Json, String] = try {
      let p = safe_path(root, ".readit/session.json")
      let text = read_text(p) catch {
        e => {
          node_fail(e)
          ""
        }
      }
      Ok(@json.parse(text))
    } catch {
      Failure(m) => Err(@core.failure_text(m))
      e => Err("\{e}")
    }
    match loaded {
      Ok(v) => v
      Err(m) => {
        warnings.push("記録を読み込めません: \{m}")
        empty_session()
      }
    }
  } else {
    empty_session()
  }
  { root, git, index: None, lowered: None, changed, warnings, session, }
}

///|
/// Every file the project lists, in reading order. Built on first use: opening
/// a project costs only its top folder.
pub fn Workspace::files(self : Workspace) -> Array[String] {
  if self.index is Some(files) {
    return files
  }
  let paths = if self.git {
    git_files(self.root, "", self.warnings) catch {
      e => {
        self.warnings.push("Gitの一覧を読めません: \{e}")
        []
      }
    }
  } else {
    let out = []
    walk(self.root, "", out, self.warnings, 0) catch {
      e => self.warnings.push("一覧を読めません: \{e}")
    }
    out
  }
  let kept = paths.filter(p => !skipped(p))
  @core.sort_strings(kept)
  let unique = []
  for p in kept {
    if unique.last() != Some(p) {
      unique.push(p)
    }
  }
  @core.sort_reading_order(unique)
  let files = if unique.length() > max_files {
    self.warnings.push(
      "\{unique.length()}ファイル中、先頭\{max_files}件を検索対象にしました",
    )
    unique[0:max_files].to_owned()
  } else {
    unique
  }
  // Git lists paths deleted in the working tree; they cannot be edited.
  let files = files.filter(p => lstat_kind(path_join(self.root, p)) == "file")
  self.index = Some(files)
  files
}

///|
/// Forget the index after files are created, moved or deleted.
fn Workspace::invalidate(self : Workspace) -> Unit {
  self.index = None
  self.lowered = None
}

///|
/// The index in lowercase, in the same order.
pub fn Workspace::lowered(self : Workspace) -> Array[String] {
  let files = self.files()
  match self.lowered {
    Some(l) => l
    None => {
      let l = files.map(@core.lower)
      self.lowered = Some(l)
      l
    }
  }
}

///|
/// Direct children of a folder, without skipped names, links or what Git
/// ignores there. `relative` is "" for the root.
pub fn Workspace::children(
  self : Workspace,
  relative : String,
) -> Array[@core.TreeChild] raise Failure {
  let dir = if relative == "" {
    self.root
  } else {
    safe_path(self.root, relative)
  }
  if stat_kind(dir) != "dir" {
    fail("フォルダではありません")
  }
  let entries = read_dir(dir) catch {
    e => {
      node_fail(e)
      []
    }
  }
  let out : Array[@core.TreeChild] = []
  for entry in entries {
    let (name, kind) = entry
    if skipped(join_relative(relative, name)) {
      continue
    }
    match kind {
      "dir" => out.push({ name, dir: true, })
      "file" => out.push({ name, dir: false, })
      _ => ()
    }
  }
  let ignored = git_ignored(dir, out.map(c => c.name))
  out.filter(c => !ignored.contains(c.name))
}

///|
/// Names in `dir` that Git ignores. Git finds the repository from `dir`, so a
/// repository nested in a plain folder applies its own rules. Tracked files are
/// never reported. Outside a repository nothing is ignored.
fn git_ignored(dir : String, names : Array[String]) -> Map[String, Unit] {
  let out : Map[String, Unit] = Map([])
  if names.length() == 0 {
    return out
  }
  // -z needs --stdin, which `run` cannot feed. One name per line instead; Git
  // still quotes names with a newline, quote or backslash, and those are shown.
  let result = run(
    "git",
    ["-C", dir, "-c", "core.quotepath=off", "check-ignore", "--", ..names],
  ) catch {
    _ => return out
  }
  // 0: some ignored, 1: none ignored, anything else: not a repository.
  if result.status != 0 {
    return out
  }
  for piece in result.stdout.split("\n") {
    match decode_utf8(piece.to_owned()) {
      Some(name) if name != "" => out[name] = ()
      _ => ()
    }
  }
  out
}

///|
/// The file to show first: the earliest file in reading order among the
/// shallowest files. Folders are read level by level, so a large project is
/// not walked when its top folder already has files.
pub fn Workspace::first_file(self : Workspace) -> String? {
  let mut level = [""]
  let mut visited = 0
  for depth = 0; depth < 4 && level.length() > 0; depth = depth + 1 {
    let files = []
    let next = []
    for folder in level {
      visited += 1
      if visited > 200 {
        break
      }
      let children = self.children(folder) catch { _ => [] }
      for c in children {
        let path = join_relative(folder, c.name)
        if c.dir {
          next.push(path)
        } else {
          files.push(path)
        }
      }
    }
    if files.length() > 0 {
      @core.sort_reading_order(files)
      return files.get(0)
    }
    @core.sort_strings(next)
    level = next
  }
  None
}

///|
fn empty_session() -> Json {
  { "reviewed": {}, "notes": [] }
}

///|
fn Workspace::track(self : Workspace, relative : String) -> Unit {
  guard self.index is Some(files) else { return }
  if !files.contains(relative) {
    files.push(relative)
    @core.sort_reading_order(files)
    self.lowered = None
  }
}

///|
/// The paths that name regular project files the listing would show: inside
/// the root, not through a link, not in a skipped folder.
pub fn Workspace::check(
  self : Workspace,
  paths : Array[String],
) -> Array[String] {
  paths.filter(relative => {
    if skipped(relative) {
      return false
    }
    let full = safe_path(self.root, relative) catch { _ => return false }
    stat_kind(full) == "file"
  })
}

///|
fn Workspace::destination(
  self : Workspace,
  relative : String,
) -> String raise Failure {
  let reserved = match components(relative) {
    Some(parts) => parts[0] == ".git" || parts[0] == ".readit"
    None => true
  }
  if @core.trim(relative) == "" || reserved {
    fail(
      "プロジェクト内の相対パスを指定してください（.git/.readitは予約領域です）",
    )
  }
  let parent = @core.parent_of(relative)
  if parent != "" {
    safe_path(self.root, parent) |> ignore
  }
  let full = path_join(self.root, relative)
  if lstat_kind(full) != "" {
    fail("同じ名前のファイルまたはフォルダが存在します")
  }
  full
}

///|
pub fn Workspace::create_file(
  self : Workspace,
  relative : String,
  text : String,
) -> Unit raise Failure {
  let path = self.destination(relative)
  create_new(path, text) catch {
    e => node_fail(e)
  }
  self.track(relative)
}

///|
pub fn Workspace::create_directory(
  self : Workspace,
  relative : String,
) -> Unit raise Failure {
  let path = self.destination(relative)
  mkdir(path) catch {
    e => node_fail(e)
  }
}

///|
pub fn Workspace::rename(
  self : Workspace,
  from : String,
  to : String,
) -> Unit raise Failure {
  let src = safe_path(self.root, from)
  let first = match components(from) {
    Some(parts) => parts[0]
    None => ""
  }
  if first == ".git" || first == ".readit" {
    fail("予約領域は変更できません")
  }
  let dest = self.destination(to)
  if @core.starts_with(to, from + "/") {
    fail("フォルダを自身の中に移動できません")
  }
  if stat_kind(src) == "dir" {
    rename(src, dest) catch {
      e => node_fail(e)
    }
  } else {
    // Link first so an existing destination can never be overwritten.
    hard_link(src, dest) catch {
      e => node_fail(e)
    }
    unlink(src) catch {
      e => {
        unlink(dest) catch {
          _ => ()
        }
        node_fail(e)
      }
    }
  }
  self.invalidate()
  let changed = self.changed.keys().collect()
  self.changed.clear()
  for p in changed {
    self.changed[@core.remap_path(p, from, to)] = ()
  }
  self.session = remap_session(self.session, from, to)
  self.persist() catch {
    e => self.warnings.push("名前変更後の記録保存: \{e}")
  }
}

///|
fn remap_session(session : Json, from : String, to : String) -> Json {
  guard session is Object(o) else { return session }
  let reviewed : Map[String, Json] = Map([])
  if o.get("reviewed") is Some(Object(r)) {
    for k, v in r {
      reviewed[@core.remap_path(k, from, to)] = v
    }
  }
  let notes = []
  if o.get("notes") is Some(Array(items)) {
    for note in items {
      match note {
        Object(n) => {
          let copy : Map[String, Json] = Map([])
          for k, v in n {
            copy[k] = if k == "path" && v is String(p) {
              Json::string(@core.remap_path(p, from, to))
            } else {
              v
            }
          }
          notes.push(Json::object(copy))
        }
        other => notes.push(other)
      }
    }
  }
  { "reviewed": Json::object(reviewed), "notes": Json::array(notes) }
}

///|
/// A document the browser holds for a path being deleted.
pub(all) struct HeldDocument {
  path : String
  disk : String
  dirty : Bool
}

///|
pub fn Workspace::delete(
  self : Workspace,
  relative : String,
  documents : Array[HeldDocument],
) -> Unit raise Failure {
  let first = match components(relative) {
    Some(parts) => parts[0]
    None => ""
  }
  if first == ".git" || first == ".readit" {
    fail("予約領域は削除できません")
  }
  let src = safe_path(self.root, relative)
  for doc in documents {
    if !@core.within(doc.path, relative) {
      continue
    }
    if doc.dirty {
      fail("未保存の変更があります。先に保存してください")
    }
    let held = safe_path(self.root, doc.path)
    let current = read_bytes(held) catch {
      e => {
        node_fail(e)
        ""
      }
    }
    if current != utf8_bytes(doc.disk) {
      fail(
        "外部で変更されています。再読込後に削除してください: \{doc.path}",
      )
    }
  }
  self.persist()
  let trash = path_join(self.root, ".readit/trash")
  if lstat_kind(trash) == "" {
    mkdir(trash) catch {
      e => node_fail(e)
    }
  }
  safe_path(self.root, ".readit/trash") |> ignore
  let id = now_ns()
  let padded = "0".repeat((30 - id.length()).max(0)) + id
  let dir = path_join(trash, padded)
  mkdir(dir) catch {
    e => node_fail(e)
  }
  create_new(path_join(dir, "path.json"), Json::string(relative).stringify()) catch {
    e => node_fail(e)
  }
  rename(src, path_join(dir, "content")) catch {
    e => node_fail(e)
  }
  self.invalidate()
}

///|
/// Restore the most recent deletion. Returns its path.
pub fn Workspace::restore_last(self : Workspace) -> String raise Failure {
  let trash = safe_path(self.root, ".readit/trash")
  let items = read_dir(trash) catch {
    e => {
      node_fail(e)
      []
    }
  }
  let names = items.map(i => i.0)
  @core.sort_strings(names)
  for i = names.length() - 1; i >= 0; i = i - 1 {
    let item = ".readit/trash/" + names[i]
    let source = safe_path(self.root, item + "/content") catch { _ => continue }
    let meta = safe_path(self.root, item + "/path.json")
    let record = read_text(meta) catch {
      e => {
        node_fail(e)
        ""
      }
    }
    let parsed = @json.parse(record) catch { _ => Json::null() }
    guard parsed is String(path) else { fail("invalid trash record") }
    let dest = self.destination(path)
    if stat_kind(source) == "dir" {
      rename(source, dest) catch {
        e => node_fail(e)
      }
      self.invalidate()
    } else {
      hard_link(source, dest) catch {
        e => node_fail(e)
      }
      unlink(source) catch {
        e => {
          unlink(dest) catch {
            _ => ()
          }
          node_fail(e)
        }
      }
      self.track(path)
    }
    return path
  }
  fail("復元できるファイルがありません")
}

///|
pub fn Workspace::persist(self : Workspace) -> Unit raise Failure {
  let dir = path_join(self.root, ".readit")
  if lstat_kind(dir) == "" {
    mkdir(dir) catch {
      e => node_fail(e)
    }
  }
  safe_path(self.root, ".readit") |> ignore
  let target = path_join(dir, "session.json")
  if lstat_kind(target) != "" {
    safe_path(self.root, ".readit/session.json") |> ignore
  }
  atomic_replace(target, self.session.stringify(indent=2)) catch {
    e => node_fail(e)
  }
}

///|
/// Read a project file for the first time: text and the Git baseline.
pub fn Workspace::read(
  self : Workspace,
  relative : String,
) -> (String, String?) raise Failure {
  let path = safe_path(self.root, relative)
  if stat_kind(path) != "file" {
    fail("ファイルではありません")
  }
  if file_size(path) > max_bytes.to_double() {
    fail("ファイルが大きすぎます（上限256KiB）")
  }
  let text = read_text(path) catch {
    NodeError("binary") =>
      fail("バイナリファイルは編集できません")
    NodeError("encoding") => fail("UTF-8以外のファイルです")
    e => {
      node_fail(e)
      ""
    }
  }
  let before = if self.git {
    let shown = run("git", ["-C", self.root, "show", "HEAD:" + relative]) catch {
      _ => { status: -1, stdout: "", stderr: "", }
    }
    let baseline = shown.stdout
    if shown.status == 0 &&
      baseline.length() <= max_bytes &&
      !@core.contains(baseline, "\u{0}") {
      decode_utf8(baseline)
    } else {
      None
    }
  } else {
    Some(text)
  }
  self.track(relative)
  (text, before)
}

///|
/// Save only when the file still holds what the editor last read or wrote.
pub fn Workspace::save(
  self : Workspace,
  relative : String,
  disk : String,
  text : String,
) -> Unit raise Failure {
  let path = safe_path(self.root, relative)
  let current = read_bytes(path) catch {
    e => {
      node_fail(e)
      ""
    }
  }
  if current != utf8_bytes(disk) {
    fail(
      "外部でファイルが変更されました。上書きせず、再読込してください",
    )
  }
  atomic_replace(path, text) catch {
    e => node_fail(e)
  }
}

///|
/// Current text of a file that has not been opened, or an error.
pub fn Workspace::disk_text(
  self : Workspace,
  relative : String,
) -> String raise Failure {
  // Absolute paths are language server results the caller already checked.
  let path = if path_is_absolute(relative) {
    relative
  } else {
    path_join(self.root, relative)
  }
  if stat_kind(path) != "file" || file_size(path) > (1024 * 1024).to_double() {
    fail("external definition is not a supported text file")
  }
  read_text(path) catch {
    e => {
      node_fail(e)
      ""
    }
  }
}

///|
/// Walk project text: unsaved buffers win; the rest is read on the fly.
/// `visit` returns false to stop early.
pub fn Workspace::scan(
  self : Workspace,
  overlays : Map[String, String],
  visit : (String, String) -> Bool,
) -> Unit {
  for path in self.files() {
    let text = match overlays.get(path) {
      Some(t) => t
      None => {
        let full = safe_path(self.root, path) catch { _ => continue }
        if file_size(full) > max_bytes.to_double() {
          continue
        }
        read_text(full) catch {
          NodeError("binary") =>
            // Rust's from_utf8 accepts NUL; read it the same way.
            decode_utf8(read_bytes(full) catch { _ => continue }).unwrap_or("")
          _ => continue
        }
      }
    }
    if !visit(path, text) {
      return
    }
  }
}

///|
pub fn Workspace::summary(self : Workspace) -> Json {
  {
    "root": self.root,
    "git": self.git,
    "changed": Json::array(self.changed.keys().map(Json::string).collect()),
    "warnings": Json::array(self.warnings.map(Json::string)),
  }
}
