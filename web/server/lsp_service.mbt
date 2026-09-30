// Local LSP client. All positions on the wire are UTF-16, as negotiated at initialize.

///|
struct Client {
  handle : Int
  language : String
  name : String
  root_uri : String
  mut capabilities : Json
  documents : Map[String, (Int, String)]
  pending : Map[Int, (Result[Json, String]) -> Unit]
  mut next_id : Int
  mut warming_up : Bool
  mut alive : Bool
  mut ready : Bool
  waiting : Array[(Result[Unit, String]) -> Unit]
}

///|
struct Snapshot {
  root : String
  path : String
  position : @core.Position
  /// Current unsaved content, including other open files in this project.
  documents : Array[(String, String)]
}

///|
struct Answer {
  targets : Array[@lsp.Target]
  information : String
  server : String
}

///|
struct Service {
  mut root : String
  clients : Map[String, Client]
  mut busy : Bool
  queue : Array[() -> Unit]
  tools : String
  /// Files language servers pointed at; the browser may open only these outside the project.
  returned : Map[String, Unit]
}

///|
fn Service::new(tools : String) -> Service {
  {
    root: "",
    clients: Map([]),
    busy: false,
    queue: [],
    tools,
    returned: Map([]),
  }
}

///|
fn Client::write(self : Client, message : Json) -> Bool {
  let body = message.stringify()
  child_write(
    self.handle,
    "Content-Length: \{utf8_length(body)}\r\n\r\n" + body,
  )
}

///|
fn Client::notify(self : Client, op : String, params : Json) -> Unit {
  ignore(self.write({ "jsonrpc": "2.0", "method": op, "params": params }))
}

///|
fn Client::request(
  self : Client,
  op : String,
  params : Json,
  timeout_ms : Int,
  done : (Result[Json, String]) -> Unit,
) -> Unit {
  if !self.alive {
    done(Err("言語サーバーが終了しました"))
    return
  }
  self.next_id += 1
  let id = self.next_id
  self.pending[id] = done
  if !self.write({ "jsonrpc": "2.0", "id": id, "method": op, "params": params }) {
    self.pending.remove(id)
    done(Err("言語サーバーへ送信できません"))
    return
  }
  set_timeout(
    () => {
      if self.pending.get(id) is Some(callback) {
        self.pending.remove(id)
        self.notify("$/cancelRequest", { "id": id })
        callback(
          Err(
            "解析が時間内に完了しませんでした。再度実行できます",
          ),
        )
      }
    },
    timeout_ms,
  )
  |> ignore
}

///|
fn Client::receive(self : Client, message : Json) -> Unit {
  guard message is Object(o) else { return }
  match (o.get("method"), o.get("id")) {
    (Some(String(op)), Some(id)) => {
      let result : Json? = match op {
        "workspace/configuration" => {
          let items = match o.get("params") {
            Some(Object(p)) =>
              match p.get("items") {
                Some(Array(items)) => items
                _ => []
              }
            _ => []
          }
          Some(
            Json::array(
              items.map(i => {
                match i {
                  Object(item) =>
                    match item.get("section") {
                      Some(String(section)) => @lsp.configuration(section)
                      _ => @lsp.configuration("")
                    }
                  _ => @lsp.configuration("")
                }
              }),
            ),
          )
        }
        "workspace/workspaceFolders" =>
          Some([{ "uri": self.root_uri, "name": "Readit" }])
        "client/registerCapability"
        | "client/unregisterCapability"
        | "window/workDoneProgress/create" => Some(Json::null())
        "workspace/applyEdit" =>
          Some({
            "applied": false,
            "failureReason": "Readit navigation never applies server edits",
          })
        _ => None
      }
      let response : Json = match result {
        Some(r) => { "jsonrpc": "2.0", "id": id, "result": r }
        None =>
          {
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32601, "message": "Unsupported client request" },
          }
      }
      ignore(self.write(response))
    }
    (None, Some(Number(n, ..))) => {
      let id = n.to_int()
      guard self.pending.get(id) is Some(callback) else { return }
      self.pending.remove(id)
      match o.get("error") {
        Some(Object(e)) => {
          let text = match e.get("message") {
            Some(String(m)) => m
            _ => "解析エラー"
          }
          callback(Err("\{self.name}: \{text}"))
        }
        _ => callback(Ok(o.get("result").unwrap_or(Json::null())))
      }
    }
    _ => ()
  }
}

///|
fn Client::fail_all(self : Client, reason : String) -> Unit {
  let callbacks = self.pending.values().collect()
  self.pending.clear()
  for callback in callbacks {
    callback(Err(reason))
  }
  let waiting = self.waiting.copy()
  self.waiting.clear()
  for w in waiting {
    w(Err(reason))
  }
}

///|
fn Service::runtime(self : Service) -> Json {
  let file = path_join(self.tools, "runtime.json")
  let text = read_text(file) catch { _ => return Json::null() }
  @json.parse(text) catch {
    _ => Json::null()
  }
}

///|
fn config_text(config : Json, key : String) -> String? {
  match config {
    Object(o) =>
      match o.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// An environment override, then runtime.json, then the default.
fn setting(
  env_value : String,
  configured : String?,
  default : String,
) -> String {
  if env_value != "" {
    env_value
  } else {
    match configured {
      Some(v) => v
      None => default
    }
  }
}

///|
fn non_empty(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
/// Where Eclipse JDT keeps its own project model; the opened repository is never written to.
fn java_data_dir(root : String) -> String {
  let name = StringBuilder()
  for c in root {
    name.write_char(if @core.is_word_char(c) { c } else { '-' })
  }
  let base = non_empty(home()).unwrap_or("/tmp")
  path_join(path_join(base, ".readit/jdtls"), name.to_string())
}

///|
fn Service::command(
  self : Service,
  language : String,
  root : String,
) -> (String, Array[String], String) raise Failure {
  let config = self.runtime()
  if language == "java" {
    let java = setting(env("READIT_JAVA"), config_text(config, "java"), "java")
    guard config_text(config, "javaLauncher") is Some(launcher) else {
      fail(
        "Java言語サーバー未導入です。Readitで python3 scripts/setup_lsp.py を実行してください",
      )
    }
    guard config_text(config, "javaConfiguration") is Some(configuration) else {
      fail(
        "Java言語サーバーの設定が見つかりません。scripts/setup_lsp.pyを再実行してください",
      )
    }
    let data = java_data_dir(root)
    mkdir_all(data) catch {
      e => fail(e.message())
    }
    return (
      java,
      [
        "-Declipse.application=org.eclipse.jdt.ls.core.id1", "-Dosgi.bundles.defaultStartLevel=4",
        "-Declipse.product=org.eclipse.jdt.ls.core.product", "-Dlog.level=ERROR",
        "-Xmx2G", "--add-modules=ALL-SYSTEM", "--add-opens", "java.base/java.util=ALL-UNNAMED",
        "--add-opens", "java.base/java.lang=ALL-UNNAMED", "-jar", launcher, "-configuration",
        configuration, "-data", data,
      ],
      "Eclipse JDT Language Server",
    )
  }
  if language == "rust" {
    let program = setting(
      env("READIT_RUST_ANALYZER"),
      config_text(config, "rustAnalyzer"),
      "rust-analyzer",
    )
    return (program, [], "rust-analyzer")
  }
  let node = setting(env("READIT_NODE"), config_text(config, "node"), "node")
  let (name, script) = if language == "python" {
    ("Pyright", "node_modules/pyright/langserver.index.js")
  } else {
    (
      "TypeScript Language Server", "node_modules/typescript-language-server/lib/cli.mjs",
    )
  }
  let script = path_join(self.tools, script)
  if stat_kind(script) != "file" {
    fail(
      "言語サーバー未導入です。Readitで python3 scripts/setup_lsp.py を実行してください",
    )
  }
  (node, [script, "--stdio"], name)
}

///|
fn Service::start(
  self : Service,
  language : String,
  root : String,
) -> Client raise Failure {
  let (program, args, name) = self.command(language, root)
  let root_uri = @lsp.path_to_uri(root)
  let framer = @lsp.Framer::new()
  let holder : Ref[Client?] = Ref(None)
  let on_data = (chunk : String) => {
    guard holder.val is Some(client) else { return }
    let bodies = framer.feed(chunk) catch {
      Failure(m) => {
        client.alive = false
        client.fail_all(@core.failure_text(m))
        child_kill(client.handle)
        return
      }
    }
    for body in bodies {
      let text = decode_utf8(body).unwrap_or("null")
      let message = @json.parse(text) catch { _ => continue }
      client.receive(message)
    }
  }
  let on_exit = (_code : Int) => {
    if holder.val is Some(client) {
      client.alive = false
      client.fail_all("言語サーバーが終了しました")
    }
  }
  let handle = spawn(program, args, root, on_data, on_exit) catch {
    e =>
      fail(
        "\{name}を起動できません: \{e.message()}。scripts/setup_lsp.pyで設定を確認してください",
      )
  }
  let client : Client = {
    handle,
    language,
    name,
    root_uri,
    capabilities: Json::null(),
    documents: Map([]),
    pending: Map([]),
    next_id: 0,
    warming_up: true,
    alive: true,
    ready: false,
    waiting: [],
  }
  holder.val = Some(client)
  let options : Json = if language == "rust" {
    @lsp.configuration("rust-analyzer")
  } else if language == "java" {
    // Eclipse JDT takes its settings at initialize; class file contents stay off
    // because this editor opens plain files only.
    {
      "workspaceFolders": [root_uri],
      "settings": @lsp.settings(),
      "extendedClientCapabilities": {
        "classFileContentsSupport": false,
        "progressReportProvider": false,
        "advancedExtractRefactoringSupport": false,
        "resolveAdditionalTextEditsSupport": false,
      },
    }
  } else if language == "typescript" {
    {
      "hostInfo": "readit",
      "tsserver": {
        "path": path_join(self.tools, "node_modules/typescript/lib/tsserver.js"),
      },
      "preferences": { "includePackageJsonAutoImports": "off" },
    }
  } else {
    {}
  }
  let params : Json = {
    "processId": pid(),
    "clientInfo": { "name": "Readit", "version": "0.4.0" },
    "rootUri": root_uri,
    "workspaceFolders": [{ "uri": root_uri, "name": @core.base_name(root) }],
    "capabilities": {
      "general": { "positionEncodings": ["utf-16"] },
      "workspace": { "configuration": true, "workspaceFolders": true },
      "textDocument": {
        "definition": { "linkSupport": true },
        "typeDefinition": { "linkSupport": true },
        "implementation": { "linkSupport": true },
        "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
        "hover": { "contentFormat": ["plaintext", "markdown"] },
        "synchronization": { "dynamicRegistration": false },
      },
    },
    "initializationOptions": options,
  }
  client.request("initialize", params, 30000, result => {
    let waiting = client.waiting.copy()
    client.waiting.clear()
    let outcome : Result[Unit, String] = match result {
      Err(e) => Err(e)
      Ok(value) => {
        client.capabilities = match value {
          Object(o) => o.get("capabilities").unwrap_or(Json::null())
          _ => Json::null()
        }
        let encoding = match client.capabilities {
          Object(c) =>
            match c.get("positionEncoding") {
              Some(String(s)) => s
              _ => "utf-16"
            }
          _ => "utf-16"
        }
        if encoding != "utf-16" {
          Err("UTF-16以外の言語サーバーには未対応です")
        } else {
          client.notify("initialized", {})
          client.notify("workspace/didChangeConfiguration", {
            "settings": @lsp.settings(),
          })
          client.ready = true
          Ok(())
        }
      }
    }
    if outcome is Err(_) {
      client.alive = false
      child_kill(client.handle)
    }
    for w in waiting {
      w(outcome)
    }
  })
  client
}

///|
fn Client::when_ready(
  self : Client,
  done : (Result[Unit, String]) -> Unit,
) -> Unit {
  if self.ready {
    done(Ok(()))
  } else if !self.alive {
    done(Err("言語サーバーが終了しました"))
  } else {
    self.waiting.push(done)
  }
}

///|
fn Client::sync(self : Client, snapshot : Snapshot) -> Unit {
  let current : Map[String, Unit] = Map([])
  for doc in snapshot.documents {
    let (path, text) = doc
    guard @core.language_id(path) is Some(id) &&
      @core.language_family(id) == self.language else {
      continue
    }
    let uri = @lsp.path_to_uri(path)
    current[uri] = ()
    let previous = self.documents.get(uri)
    if previous is Some((_, t)) && t == text {
      continue
    }
    let version = match previous {
      Some((v, _)) => v + 1
      None => 1
    }
    if previous is Some(_) {
      self.notify("textDocument/didChange", {
        "textDocument": { "uri": uri, "version": version },
        "contentChanges": [{ "text": text }],
      })
    } else {
      self.notify("textDocument/didOpen", {
        "textDocument": {
          "uri": uri,
          "languageId": id,
          "version": version,
          "text": text,
        },
      })
    }
    self.documents[uri] = (version, text)
  }
  let stale = self.documents.keys().filter(u => !current.contains(u)).collect()
  for uri in stale {
    self.notify("textDocument/didClose", { "textDocument": { "uri": uri } })
    self.documents.remove(uri)
  }
}

///|
fn provides(capabilities : Json, key : String) -> Bool {
  match capabilities {
    Object(o) =>
      match o.get(key) {
        Some(True) | Some(Object(_)) => true
        _ => false
      }
    _ => false
  }
}

///|
fn empty_result(value : Json) -> Bool {
  match value {
    Null => true
    Array(items) => items.length() == 0
    _ => false
  }
}

///|
/// Run one query at a time, like the native editor's service lock.
fn Service::query(
  self : Service,
  query : @lsp.Query,
  snapshot : Snapshot,
  done : (Result[Answer, String]) -> Unit,
) -> Unit {
  let job = () => {
    self.run_query(query, snapshot, result => {
      done(result)
      self.busy = false
      if self.queue.length() > 0 {
        let next = self.queue.remove(0)
        self.busy = true
        next()
      }
    })
  }
  if self.busy {
    self.queue.push(job)
  } else {
    self.busy = true
    job()
  }
}

///|
/// Stop every language server, e.g. when the project changes or on exit.
fn Service::shutdown(self : Service) -> Unit {
  for _, client in self.clients {
    client.notify("exit", Json::null())
    child_kill(client.handle)
    client.alive = false
  }
  self.clients.clear()
}

///|
fn Service::run_query(
  self : Service,
  query : @lsp.Query,
  snapshot : Snapshot,
  done : (Result[Answer, String]) -> Unit,
) -> Unit {
  guard @core.language_id(snapshot.path) is Some(id) else {
    done(
      Err(
        "この言語の解析は未対応です（Python・JS/TS・Rust・Javaに対応）",
      ),
    )
    return
  }
  let language = @core.language_family(id)
  if self.root != snapshot.root {
    self.shutdown()
    self.returned.clear()
    self.root = snapshot.root
  }
  if self.clients.get(language) is Some(c) && !c.alive {
    self.clients.remove(language)
  }
  let client = match self.clients.get(language) {
    Some(c) => c
    None => {
      let c = self.start(language, snapshot.root) catch {
        Failure(m) => {
          done(Err(@core.failure_text(m)))
          return
        }
      }
      self.clients[language] = c
      c
    }
  }
  client.when_ready(ready => {
    if ready is Err(e) {
      self.clients.remove(language)
      done(Err(e))
      return
    }
    if !provides(client.capabilities, query.capability()) {
      done(
        Err(
          "\{client.name}は「\{query.title()}」を提供していません",
        ),
      )
      return
    }
    client.sync(snapshot)
    let params : Map[String, Json] = {
      "textDocument": { "uri": @lsp.path_to_uri(snapshot.path) },
      "position": {
        "line": snapshot.position.line,
        "character": snapshot.position.character,
      },
    }
    if query == References {
      params["context"] = { "includeDeclaration": true }
    }
    let params = Json::object(params)
    let deadline = now_ms() +
      (if language == "java" { 180000.0 } else { 5000.0 })
    let warm = (language == "rust" || language == "java") && client.warming_up
    fn attempt() {
      client.request(query.method_name(), params, 20000, result => {
        match result {
          Err(e) => done(Err(e))
          Ok(value) =>
            if warm && empty_result(value) && now_ms() < deadline {
              set_timeout(() => attempt(), 250) |> ignore
            } else {
              client.warming_up = false
              done(Ok(self.finish(query, snapshot, value, client.name)))
            }
        }
      })
    }

    attempt()
  })
}

///|
fn Service::finish(
  self : Service,
  query : @lsp.Query,
  snapshot : Snapshot,
  result : Json,
  server : String,
) -> Answer {
  let found = if query == Symbols {
    @lsp.symbols(result, snapshot.path)
  } else {
    @lsp.targets(result)
  }
  let found = if found.length() > 2000 {
    found[0:2000].to_owned()
  } else {
    found
  }
  let contents : Map[String, String] = Map([])
  for doc in snapshot.documents {
    contents[doc.0] = doc.1
  }
  for target in found {
    if !contents.contains(target.path) &&
      stat_kind(target.path) == "file" &&
      file_size(target.path) <= (1024 * 1024).to_double() {
      let text = read_text(target.path) catch { _ => "\u{0}" }
      if !(text.length() > 0 && text[0] == 0) {
        contents[target.path] = text
      }
    }
    if contents.get(target.path) is Some(text) {
      @lsp.describe(target, text)
    }
    self.returned[target.path] = ()
  }
  {
    targets: found,
    information: if query == Hover {
      @lsp.hover_text(result)
    } else {
      ""
    },
    server,
  }
}

///|
/// Whether a language server returned this absolute path in the current project.
fn Service::returned_path(self : Service, root : String, path : String) -> Bool {
  self.root == root && self.returned.contains(path)
}
