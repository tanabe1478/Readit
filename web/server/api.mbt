// Browser API. Each call names the workspace root it expects; a call for a
// different project is refused, like the native editor's control scope.

///|
struct Server {
  web_root : String
  token : String
  mut url : String
  mut workspace : Workspace?
  service : Service
  mut control : Control?
  control_path : String
  demo : Bool
  /// Window name shown in the title, such as the AI session that started it.
  label : String
}

///|
fn field(args : Json, key : String) -> Json? {
  match args {
    Object(o) => o.get(key)
    _ => None
  }
}

///|
fn text_arg(args : Json, key : String) -> String raise Failure {
  match field(args, key) {
    Some(String(s)) => s
    _ => fail("\{key} is required")
  }
}

///|
fn int_arg(args : Json, key : String, default : Int) -> Int {
  match field(args, key) {
    Some(Number(n, ..)) => n.to_int()
    _ => default
  }
}

///|
fn Server::scope(self : Server, args : Json) -> Workspace raise Failure {
  guard self.workspace is Some(ws) else { fail("no workspace is open") }
  if text_arg(args, "root") != ws.root {
    fail("workspace changed or does not match; reload the window")
  }
  ws
}

///|
fn Server::summary(self : Server) -> Json {
  match self.workspace {
    Some(ws) => opening(ws)
    None => Json::null()
  }
}

///|
/// The summary a newly opened project starts from, with the file to show first.
fn opening(ws : Workspace) -> Json {
  guard ws.summary() is Object(o) else { return ws.summary() }
  let out = o.copy()
  out["first"] = match ws.first_file() {
    Some(p) => Json::string(p)
    None => Json::null()
  }
  Json::object(out)
}

///|
fn strings_arg(args : Json, key : String) -> Array[String] {
  match field(args, key) {
    Some(Array(items)) =>
      items.filter_map(item => {
        match item {
          String(p) => Some(p)
          _ => None
        }
      })
    _ => []
  }
}

///|
/// Handle a synchronous call. Returns None for calls answered asynchronously.
fn Server::call(
  self : Server,
  name : String,
  args : Json,
  reply : (Result[Json, String]) -> Unit,
) -> Unit {
  let result : Result[Json?, String] = Ok(self.dispatch(name, args, reply)) catch {
    Failure(m) => Err(@core.failure_text(m))
  }
  match result {
    Ok(Some(value)) => reply(Ok(value))
    Ok(None) => ()
    Err(message) => reply(Err(message))
  }
}

///|
fn Server::dispatch(
  self : Server,
  name : String,
  args : Json,
  reply : (Result[Json, String]) -> Unit,
) -> Json? raise Failure {
  match name {
    "session.start" =>
      Some({
        "workspace": self.summary(),
        "demo": self.demo,
        "url": self.url,
        "control_socket": self.control_path,
        "label": self.label,
        "platform": platform(),
      })
    "workspace.open" => {
      let root = text_arg(args, "path")
      let absolute = if path_is_absolute(root) {
        root
      } else {
        path_resolve(home(), root)
      }
      let ws = Workspace::load(absolute)
      self.workspace = Some(ws)
      self.service.shutdown()
      Some(opening(ws))
    }
    "workspace.reload" => {
      let ws = self.scope(args)
      let fresh = Workspace::load(ws.root)
      self.workspace = Some(fresh)
      Some(opening(fresh))
    }
    "file.read" => {
      let ws = self.scope(args)
      let (text, before) = ws.read(text_arg(args, "path"))
      Some({
        "text": Json::string(text),
        "before": match before {
          Some(b) => Json::string(b)
          None => Json::null()
        },
      })
    }
    "dir.list" => {
      let ws = self.scope(args)
      let path = match field(args, "path") {
        Some(String(p)) => p
        _ => ""
      }
      let entries = ws
        .children(path)
        .map(c => ({ "name": c.name, "dir": c.dir } : Json))
      Some({ "path": path, "entries": Json::array(entries) })
    }
    "files.find" => {
      let ws = self.scope(args)
      let query = @core.lower(@core.trim(text_arg(args, "query")))
      let (found, total) = @core.fuzzy_paths(
        ws.files(),
        ws.lowered(),
        query,
        int_arg(args, "limit", 80),
      )
      Some({ "files": Json::array(found.map(Json::string)), "total": total })
    }
    "files.list" => {
      let ws = self.scope(args)
      let filter = match field(args, "filter") {
        Some(String(f)) => @core.lower(f)
        _ => ""
      }
      let offset = int_arg(args, "offset", 0)
      let limit = int_arg(args, "limit", 200)
      let files = ws.files().filter(p => @core.contains(@core.lower(p), filter))
      let end = (offset + limit).min(files.length())
      Some({
        "files": Json::array(
          (if offset < end { files[offset:end].to_owned() } else { [] }).map(
            Json::string,
          ),
        ),
        "total": files.length(),
      })
    }
    "file.check" => {
      let ws = self.scope(args)
      Some({
        "files": Json::array(
          ws.check(strings_arg(args, "paths")).map(Json::string),
        ),
      })
    }
    "file.save" => {
      let ws = self.scope(args)
      ws.save(
        text_arg(args, "path"),
        text_arg(args, "disk"),
        text_arg(args, "text"),
      )
      Some({ "saved": true })
    }
    "file.create" => {
      let ws = self.scope(args)
      ws.create_file(text_arg(args, "path"), text_arg(args, "text"))
      Some(ws.summary())
    }
    "dir.create" => {
      let ws = self.scope(args)
      ws.create_directory(text_arg(args, "path"))
      Some(ws.summary())
    }
    "file.rename" => {
      let ws = self.scope(args)
      ws.rename(text_arg(args, "from"), text_arg(args, "to"))
      Some(ws.summary())
    }
    "file.delete" => {
      let ws = self.scope(args)
      let documents = match field(args, "documents") {
        Some(Array(items)) =>
          items.filter_map(item => {
            match item {
              { "path": String(path), "disk": String(disk), "dirty": dirty, .. } =>
                Some({ path, disk, dirty: dirty is True, })
              _ => None
            }
          })
        _ => []
      }
      ws.delete(text_arg(args, "path"), documents)
      Some(ws.summary())
    }
    "file.restore" => {
      let ws = self.scope(args)
      let path = ws.restore_last()
      Some({
        "path": path,
        "file": stat_kind(path_join(ws.root, path)) == "file",
        "workspace": ws.summary(),
      })
    }
    "file.disk" => {
      let ws = self.scope(args)
      let path = text_arg(args, "path")
      if path_is_absolute(path) &&
        !self.service.returned_path(ws.root, path) &&
        !is_inside(ws.root, path) {
        fail(
          "path is not a workspace file or a definition returned by this editor",
        )
      }
      let relative = if is_inside(ws.root, path) && path != ws.root {
        @core.slice(path, ws.root.length() + 1, path.length())
      } else {
        path
      }
      Some({ "text": ws.disk_text(relative) })
    }
    "file.disk_many" => {
      let ws = self.scope(args)
      let out : Map[String, Json] = Map([])
      if field(args, "paths") is Some(Array(paths)) {
        for p in paths {
          guard p is String(path) else { continue }
          if path_is_absolute(path) &&
            !self.service.returned_path(ws.root, path) {
            continue
          }
          let text : Json = Json::string(ws.disk_text(path)) catch {
            _ => Json::null()
          }
          out[path] = text
        }
      }
      Some(Json::object(out))
    }
    "file.external" => {
      let ws = self.scope(args)
      let path = text_arg(args, "path")
      let canonical = realpath(path) catch {
        e => fail("定義ファイルを開けません: \{e.message()}")
      }
      if is_inside(ws.root, canonical) {
        return Some({
          "relative": @core.slice(
            canonical,
            ws.root.length() + 1,
            canonical.length(),
          ),
        })
      }
      if !self.service.returned_path(ws.root, path) &&
        !self.service.returned_path(ws.root, canonical) {
        fail("path is not a definition returned by this editor")
      }
      if stat_kind(canonical) != "file" ||
        file_size(canonical) > (1024 * 1024).to_double() {
        fail(
          "外部定義を開けません（UTF-8、1MiB以内の通常ファイルに対応）",
        )
      }
      let text = read_text(canonical) catch {
        _ => fail("外部定義はUTF-8テキストのみ閲覧できます")
      }
      Some({ "path": canonical, "text": text })
    }
    "search" => {
      let ws = self.scope(args)
      let query = text_arg(args, "query")
      let literal = match field(args, "mode") {
        Some(String("literal")) => true
        _ => false
      }
      let limit = int_arg(args, "limit", if literal { 100 } else { 200 })
      let overlays : Map[String, String] = Map([])
      if field(args, "overlays") is Some(Object(o)) {
        for k, v in o {
          if v is String(t) {
            overlays[k] = t
          }
        }
      }
      let prefix = match field(args, "prefix") {
        Some(String(p)) => p
        _ => ""
      }
      search(ws, query, literal, limit, overlays, prefix, result => reply(
        Ok(result),
      ))
      None
    }
    "lsp.query" => {
      let ws = self.scope(args)
      let query = match field(args, "query") {
        Some(String(q)) => @lsp.Query::parse(q)
        _ => None
      }
      guard query is Some(query) else { fail("invalid symbol query kind") }
      let documents = match field(args, "documents") {
        Some(Array(items)) =>
          items.filter_map(item => {
            match item {
              Array([String(p), String(t)]) => Some((p, t))
              _ => None
            }
          })
        _ => []
      }
      let snapshot : Snapshot = {
        root: ws.root,
        path: text_arg(args, "path"),
        position: {
          line: int_arg(args, "line", 0),
          character: int_arg(args, "character", 0),
        },
        documents,
      }
      self.service.query(query, snapshot, answer => {
        match answer {
          Err(e) => reply(Err(e))
          Ok(a) => reply(Ok(answer_json(a)))
        }
      })
      None
    }
    "reveal" => {
      let ws = self.scope(args)
      let path = safe_path(ws.root, text_arg(args, "path"))
      if platform() == "darwin" {
        ignore(
          run("open", ["-R", path]) catch {
            _ => { status: -1, stdout: "", stderr: "", }
          },
        )
      }
      Some({ "revealed": platform() == "darwin" })
    }
    "pick.path" => {
      let folder = field(args, "folder") is Some(True)
      Some(pick_path(folder))
    }
    "control.reply" => {
      guard self.control is Some(control) else { return Some(Json::null()) }
      let id = int_arg(args, "id", -1)
      let response : Json = match
        (field(args, "result"), field(args, "error")) {
        (_, Some(String(e))) => { "error": e }
        (Some(r), _) => { "result": r }
        _ => { "error": "editor returned no result" }
      }
      control.answer(id, response)
      Some(Json::null())
    }
    "app.quit" => {
      set_timeout(() => shutdown(self), 150) |> ignore
      Some({ "quitting": true })
    }
    _ => fail("unknown API: \{name}")
  }
}

///|
fn answer_json(a : Answer) -> Json {
  {
    "server": a.server,
    "information": a.information,
    "targets": Json::array(
      a.targets.map(t => {
        "path": t.path,
        "line": t.start.line,
        "character": t.start.character,
        "end_line": t.end.line,
        "end_character": t.end.character,
        "name": t.name,
        "detail": t.detail,
        "preview": t.preview,
      }),
    ),
  }
}

///|
/// Workspace text search. The picker is case-insensitive and lists lines;
/// the literal mode reports every occurrence with its UTF-16 column.
fn search(
  ws : Workspace,
  query : String,
  literal : Bool,
  limit : Int,
  overlays : Map[String, String],
  prefix : String,
  done : (Json) -> Unit,
) -> Unit {
  let matches = []
  let mut more = false
  if query == "" {
    done({ "matches": [], "truncated": false })
    return
  }
  let needle = if literal { query } else { @core.lower(query) }
  ws.scan(overlays, (path, text) => {
    if prefix != "" && !@core.starts_with(path, prefix) {
      return true
    }
    for index, line in @core.lines(text) {
      if literal {
        for column in @core.find_all(line, needle) {
          if matches.length() == limit {
            more = true
            return false
          }
          matches.push(
            (
              {
                "path": path,
                "line": index + 1,
                "column": column + 1,
                "text": @core.take_chars(line, 500),
              } : Json),
          )
        }
      } else if @core.contains(@core.lower(line), needle) {
        matches.push({
          "path": path,
          "line": index + 1,
          "column": 1,
          "text": @core.trim(line),
        })
        if matches.length() == limit {
          more = true
          return false
        }
      }
    }
    true
  }, () => done({ "matches": Json::array(matches), "truncated": more }))
}

///|
/// Ask the operating system for a path. macOS shows its native chooser.
fn pick_path(folder : Bool) -> Json {
  // Tests cannot click a native chooser; they name the chosen path instead.
  let forced = env("READIT_TEST_PICK")
  if forced != "" {
    return { "path": forced }
  }
  if platform() != "darwin" {
    return { "unsupported": true }
  }
  let script = if folder {
    "POSIX path of (choose folder with prompt \"フォルダを開く\")"
  } else {
    "POSIX path of (choose file with prompt \"ファイルを開く\")"
  }
  let result = run("osascript", ["-e", script]) catch {
    _ => return { "unsupported": true }
  }
  if result.status != 0 {
    return { "cancelled": true }
  }
  let path = @core.trim(decode_utf8(result.stdout).unwrap_or(""))
  let path = if folder && @core.ends_with(path, "/") && path.length() > 1 {
    @core.slice(path, 0, path.length() - 1)
  } else {
    path
  }
  { "path": path }
}

///|
fn shutdown(server : Server) -> Unit {
  server.service.shutdown()
  if server.control is Some(c) {
    c.close()
  }
  http_close()
  exit(0)
}
