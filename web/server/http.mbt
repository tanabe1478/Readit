// HTTP on the loopback interface. The page carries a per-run token that every
// API call must send back, so other sites in the browser cannot drive it.

///|
fn content_type(path : String) -> String {
  match @core.extension(path) {
    "html" => "text/html; charset=utf-8"
    "js" | "mjs" => "text/javascript; charset=utf-8"
    "css" => "text/css; charset=utf-8"
    "wasm" => "application/wasm"
    "json" => "application/json; charset=utf-8"
    "scm" => "text/plain; charset=utf-8"
    "svg" => "image/svg+xml"
    _ => "application/octet-stream"
  }
}

///|
fn security_headers(kind : String) -> Json {
  {
    "content-type": kind,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "cross-origin-opener-policy": "same-origin",
    "content-security-policy": "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'",
  }
}

///|
/// A static asset path: letters, digits, `-_.`, and folders, never `..`.
fn static_path(url_path : String) -> String? {
  let rel = @core.slice(url_path, 1, url_path.length())
  if rel == "" || @core.contains(rel, "..") {
    return None
  }
  for c in rel {
    let ok = @core.is_word_char(c) ||
      c == '/' ||
      c == '-' ||
      c == '_' ||
      c == '.'
    if !ok || c.to_int() >= 0x80 {
      return None
    }
  }
  Some(rel)
}

///|
fn header(headers : Json, name : String) -> String {
  match field(headers, name) {
    Some(String(v)) => v
    _ => ""
  }
}

///|
/// Accept only loopback host names, which blocks DNS rebinding.
fn loopback_host(host : String) -> Bool {
  let name = if @core.starts_with(host, "[") {
    let end = @core.find_from(host, "]", 0)
    if end < 0 {
      host
    } else {
      @core.slice(host, 0, end + 1)
    }
  } else {
    let colon = @core.find_from(host, ":", 0)
    if colon < 0 {
      host
    } else {
      @core.slice(host, 0, colon)
    }
  }
  name == "127.0.0.1" || name == "localhost" || name == "[::1]"
}

///|
fn query_param(url : String, key : String) -> String {
  let q = @core.find_from(url, "?", 0)
  if q < 0 {
    return ""
  }
  for part in @core.slice(url, q + 1, url.length()).split("&") {
    let piece = part.to_owned()
    if @core.starts_with(piece, key + "=") {
      return @core.slice(piece, key.length() + 1, piece.length())
    }
  }
  ""
}

///|
fn url_path(url : String) -> String {
  let q = @core.find_from(url, "?", 0)
  if q < 0 {
    url
  } else {
    @core.slice(url, 0, q)
  }
}

///|
fn respond_json(id : Int, status : Int, body : Json) -> Unit {
  http_respond(
    id,
    status,
    security_headers("application/json; charset=utf-8").stringify(),
    body.stringify(),
  )
}

///|
fn Server::handle(
  self : Server,
  id : Int,
  op : String,
  url : String,
  headers_text : String,
  body : String,
) -> Unit {
  let headers = @json.parse(headers_text) catch { _ => Json::null() }
  if !loopback_host(header(headers, "host")) {
    respond_json(id, 421, { "error": "Readit accepts loopback host names only" })
    return
  }
  let path = url_path(url)
  if path == "/api/events" {
    if query_param(url, "token") != self.token {
      respond_json(id, 403, { "error": "invalid token" })
      return
    }
    attach_window(id)
    return
  }
  if @core.starts_with(path, "/api/") {
    if op != "POST" || header(headers, "x-readit-token") != self.token {
      respond_json(id, 403, { "error": "invalid token" })
      return
    }
    let name = @core.slice(path, 5, path.length())
    let args = @json.parse(body) catch { _ => Json::object(Map([])) }
    self.call(name, args, result => {
      match result {
        Ok(value) => respond_json(id, 200, { "ok": true, "result": value })
        Err(message) => respond_json(id, 200, { "ok": false, "error": message })
      }
    })
    return
  }
  if op != "GET" {
    respond_json(id, 405, { "error": "method not allowed" })
    return
  }
  let www = path_join(self.web_root, "www")
  if path == "/" || path == "/index.html" {
    let page = read_text(path_join(www, "index.html")) catch {
      _ => {
        respond_json(id, 500, {
          "error": "index.html is missing; run npm run build",
        })
        return
      }
    }
    http_respond(
      id,
      200,
      security_headers("text/html; charset=utf-8").stringify(),
      @core.replace_all(page, "__READIT_TOKEN__", self.token),
    )
    return
  }
  guard static_path(path) is Some(rel) else {
    respond_json(id, 404, { "error": "not found" })
    return
  }
  http_send_file(
    id,
    path_join(www, rel),
    security_headers(content_type(rel)).stringify(),
  )
}

///|
/// The newest window answers control requests; an older one is told to stand by.
fn attach_window(id : Int) -> Unit {
  if window.stream is Some(old) {
    ignore(http_write(old, "event: superseded\ndata: {}\n\n"))
    http_end(old)
  }
  window.generation += 1
  let generation = window.generation
  http_stream(
    id,
    (
      {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      } : Json).stringify(),
    () => if window.generation == generation { window.stream = None },
  )
  window.stream = Some(id)
  ignore(http_write(id, ": connected\n\n"))
  fn keepalive() {
    if window.generation == generation && window.stream is Some(s) {
      ignore(http_write(s, ": ping\n\n"))
      set_timeout(() => keepalive(), 15000) |> ignore
    }
  }

  set_timeout(() => keepalive(), 15000) |> ignore
}
