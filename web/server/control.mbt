// Local IPC for controlling the visible editor. MCP transport lives in
// tools/readit_mcp.py; this relays each request to the browser window.

///|
let max_message : Int = 262_144

///|
struct Control {
  path : String
  mut inode : String
  pending : Map[Int, (Int, Int)]
  mut next : Int
}

///|
/// The browser window that answers control requests.
struct Window {
  mut stream : Int?
  mut generation : Int
}

///|
let window : Window = { stream: None, generation: 0, }

///|
/// Push one server-sent event to the attached window.
fn push_event(name : String, data : Json) -> Bool {
  guard window.stream is Some(id) else { return false }
  http_write(id, "event: \{name}\ndata: \{data.stringify()}\n\n")
}

///|
fn Control::bind(path : String) -> Control raise Failure {
  if !path_is_absolute(path) {
    fail("control socket must be an absolute path")
  }
  let parent = path_dirname(path)
  if lstat_kind(parent) == "" {
    mkdir(parent, mode=0o700) catch {
      e => fail(e.message())
    }
  }
  if lstat_kind(parent) != "dir" || (lstat_mode(parent) & 0o077) != 0 {
    fail("control socket needs a private directory (mode 700)")
  }
  // Do not unlink an existing endpoint: it may belong to another live editor.
  if lstat_kind(path) != "" {
    fail("\{path}: address already in use")
  }
  let control = { path, inode: "", pending: Map([]), next: 0, }
  let handler = (conn : Int, line : String) => control.receive(conn, line)
  unix_listen(path, max_message, handler) catch {
    e => fail(e.message())
  }
  control
}

///|
/// Finish binding once the listener is up: private permissions, inode for cleanup.
fn Control::ready(
  self : Control,
  done : (Result[Unit, String]) -> Unit,
) -> Unit {
  unix_ready(result => {
    if result.length() > 0 && result[0] == 0 {
      done(Err("\{self.path}: \{@core.slice(result, 1, result.length())}"))
      return
    }
    chmod(self.path, 0o600) catch {
      e => {
        done(Err(e.message()))
        return
      }
    }
    self.inode = inode(self.path)
    done(Ok(()))
  })
}

///|
fn reply_error(conn : Int, message : String) -> Unit {
  socket_reply(conn, ({ "error": message } : Json).stringify())
}

///|
fn Control::receive(self : Control, conn : Int, line : String) -> Unit {
  if line.length() > 0 && line[0] == 0 {
    reply_error(conn, @core.slice(line, 1, line.length()))
    return
  }
  let call = @json.parse(line) catch {
    e => {
      reply_error(conn, "\{e}")
      return
    }
  }
  guard call is Object(o) &&
    o.get("method") is Some(String(op)) &&
    o.keys().all(k => k == "method" || k == "arguments") else {
    reply_error(conn, "invalid request: expected {\"method\", \"arguments\"}")
    return
  }
  let arguments = o.get("arguments").unwrap_or(Json::object(Map([])))
  self.next += 1
  let id = self.next
  let timer = set_timeout(
    () => {
      if self.pending.get(id) is Some((c, _)) {
        self.pending.remove(id)
        ignore(push_event("cancel", { "id": id }))
        reply_error(
          c, "editor did not respond; inspect its state before retrying",
        )
      }
    },
    55000,
  )
  self.pending[id] = (conn, timer)
  if !push_event("control", { "id": id, "method": op, "arguments": arguments }) {
    self.pending.remove(id)
    clear_timeout(timer)
    reply_error(
      conn, "Readit is not open in a browser; open the URL printed by the server",
    )
  }
}

///|
/// The window's answer to a request.
fn Control::answer(self : Control, id : Int, response : Json) -> Unit {
  guard self.pending.get(id) is Some((conn, timer)) else { return }
  self.pending.remove(id)
  clear_timeout(timer)
  if socket_alive(conn) {
    socket_reply(conn, response.stringify())
  }
}

///|
/// Remove the socket only if it is still the one this process created.
fn Control::close(self : Control) -> Unit {
  unix_close()
  if self.inode != "" && inode(self.path) == self.inode {
    unlink(self.path) catch {
      _ => ()
    }
  }
}
