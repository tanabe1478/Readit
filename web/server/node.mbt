// Node.js bindings. Every binding catches JavaScript exceptions and returns a
// string: a value, or "\u{0}" followed by the error message.

///|
#external
pub type JsHandle

///|
suberror NodeError {
  NodeError(String)
}

///|
fn NodeError::message(self : NodeError) -> String {
  match self {
    NodeError(m) => m
  }
}

///|
/// Raise the error carried by an FFI result string.
fn check(value : String) -> String raise NodeError {
  if value.length() > 0 && value[0] == 0 {
    raise NodeError(@core.slice(value, 1, value.length()))
  }
  value
}

///|
extern "js" fn js_init() -> Unit =
  #|() => {
  #|  if (globalThis.__readit) return;
  #|  const m = (n) => process.getBuiltinModule(n);
  #|  const fs = m('node:fs'), path = m('node:path'), cp = m('node:child_process');
  #|  const R = globalThis.__readit = { fs, path, cp, http: m('node:http'), net: m('node:net'),
  #|    os: m('node:os'), crypto: m('node:crypto'), handles: new Map(), next: 1 };
  #|  R.err = (e) => '\u0000' + (e && e.code && e.message ? e.message : String(e && e.message || e));
  #|  R.wrap = (f) => { try { const v = f(); return v === undefined ? '' : String(v); } catch (e) { return R.err(e); } };
  #|  R.keep = (v) => { const id = R.next++; R.handles.set(id, v); return id; };
  #|  R.utf8 = new TextDecoder('utf-8', { fatal: true });
  #|}

///|
fn init_node() -> Unit {
  js_init()
}

// ---- process ----

///|
extern "js" fn js_argv() -> String = "() => JSON.stringify(process.argv.slice(2))"

///|
pub fn argv() -> Array[String] {
  init_node()
  let parsed = @json.parse(js_argv()) catch { _ => Json::null() }
  match parsed {
    Array(items) =>
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
pub extern "js" fn eprint(text : String) -> Unit = "(s) => { process.stderr.write(s + '\n'); }"

///|
pub extern "js" fn exit(code : Int) -> Unit = "(c) => { process.exit(c); }"

///|
pub extern "js" fn env(name : String) -> String = "(n) => process.env[n] ?? ''"

///|
pub extern "js" fn platform() -> String = "() => process.platform"

///|
pub extern "js" fn pid() -> Int = "() => process.pid"

///|
pub extern "js" fn home() -> String = "() => globalThis.__readit.os.homedir()"

///|
pub extern "js" fn now_ms() -> Double = "() => Date.now()"

///|
pub extern "js" fn now_ns() -> String = "() => process.hrtime.bigint().toString() + String(Date.now())"

///|
pub extern "js" fn random_token() -> String = "() => globalThis.__readit.crypto.randomBytes(24).toString('hex')"

///|
pub extern "js" fn set_timeout(f : () -> Unit, ms : Int) -> Int = "(f, ms) => { const t = setTimeout(f, ms); return globalThis.__readit.keep(t); }"

///|
pub extern "js" fn clear_timeout(id : Int) -> Unit = "(id) => { const R = globalThis.__readit; const t = R.handles.get(id); if (t) clearTimeout(t); R.handles.delete(id); }"

///|
pub extern "js" fn on_signal(f : () -> Unit) -> Unit = "(f) => { for (const s of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(s, () => { f(); process.exit(0); }); process.on('exit', () => f()); }"

///|
/// The directory holding the running server script: web/_build/js/<mode>/build/server.
pub extern "js" fn script_dir() -> String = "() => { const p = process.argv[1] || ''; return globalThis.__readit.path.dirname(globalThis.__readit.fs.realpathSync(p)); }"

// ---- paths ----

///|
pub extern "js" fn path_resolve(base : String, rel : String) -> String = "(b, r) => globalThis.__readit.path.resolve(b, r)"

///|
pub extern "js" fn path_join(a : String, b : String) -> String = "(a, b) => globalThis.__readit.path.join(a, b)"

///|
pub extern "js" fn path_dirname(p : String) -> String = "(p) => globalThis.__readit.path.dirname(p)"

///|
pub extern "js" fn path_is_absolute(p : String) -> Bool = "(p) => globalThis.__readit.path.isAbsolute(p)"

///|
pub extern "js" fn cwd() -> String = "() => process.cwd()"

// ---- files ----

///|
extern "js" fn js_realpath(p : String) -> String = "(p) => globalThis.__readit.wrap(() => globalThis.__readit.fs.realpathSync(p))"

///|
pub fn realpath(p : String) -> String raise NodeError {
  check(js_realpath(p))
}

///|
/// "file", "dir", "symlink", "other", or "" when missing. Does not follow links.
pub extern "js" fn lstat_kind(p : String) -> String =
  #|(p) => { try { const s = globalThis.__readit.fs.lstatSync(p);
  #|  return s.isSymbolicLink() ? 'symlink' : s.isFile() ? 'file' : s.isDirectory() ? 'dir' : 'other'; } catch (e) { return ''; } }

///|
/// Like `lstat_kind` but follows links.
pub extern "js" fn stat_kind(p : String) -> String =
  #|(p) => { try { const s = globalThis.__readit.fs.statSync(p);
  #|  return s.isFile() ? 'file' : s.isDirectory() ? 'dir' : 'other'; } catch (e) { return ''; } }

///|
pub extern "js" fn file_size(p : String) -> Double = "(p) => { try { return globalThis.__readit.fs.statSync(p).size; } catch (e) { return -1; } }"

///|
/// Permission bits of a path without following links, or -1.
pub extern "js" fn lstat_mode(p : String) -> Int = "(p) => { try { return globalThis.__readit.fs.lstatSync(p).mode & 0o777; } catch (e) { return -1; } }"

///|
pub extern "js" fn inode(p : String) -> String = "(p) => { try { return String(globalThis.__readit.fs.lstatSync(p).ino); } catch (e) { return ''; } }"

///|
/// Read a UTF-8 text file: "binary" for NUL bytes, "encoding" for invalid UTF-8.
extern "js" fn js_read_text(p : String) -> String =
  #|(p) => globalThis.__readit.wrap(() => {
  #|  const R = globalThis.__readit; const b = R.fs.readFileSync(p);
  #|  if (b.includes(0)) { const e = new Error('binary'); e.code = 'BINARY'; throw e; }
  #|  try { return R.utf8.decode(b); } catch (e) { const x = new Error('encoding'); x.code = 'ENCODING'; throw x; }
  #|})

///|
pub fn read_text(p : String) -> String raise NodeError {
  check(js_read_text(p))
}

///|
/// Raw file content as Latin-1, so bytes compare exactly.
extern "js" fn js_read_bytes(p : String) -> String = "(p) => globalThis.__readit.wrap(() => globalThis.__readit.fs.readFileSync(p).toString('latin1'))"

///|
pub fn read_bytes(p : String) -> String raise NodeError {
  check(js_read_bytes(p))
}

///|
/// UTF-8 bytes of text as Latin-1.
pub extern "js" fn utf8_bytes(text : String) -> String = "(s) => Buffer.from(s, 'utf8').toString('latin1')"

///|
/// Decode Latin-1 bytes as UTF-8, or "\u{0}" when invalid.
extern "js" fn js_decode_utf8(bytes : String) -> String = "(s) => globalThis.__readit.wrap(() => globalThis.__readit.utf8.decode(Buffer.from(s, 'latin1')))"

///|
pub fn decode_utf8(bytes : String) -> String? {
  let v = js_decode_utf8(bytes)
  if v.length() > 0 && v[0] == 0 {
    None
  } else {
    Some(v)
  }
}

///|
pub extern "js" fn utf8_length(text : String) -> Int = "(s) => Buffer.byteLength(s, 'utf8')"

///|
extern "js" fn js_read_dir(p : String) -> String =
  #|(p) => globalThis.__readit.wrap(() => JSON.stringify(
  #|  globalThis.__readit.fs.readdirSync(p, { withFileTypes: true }).map(d => [d.name,
  #|    d.isSymbolicLink() ? 'symlink' : d.isFile() ? 'file' : d.isDirectory() ? 'dir' : 'other'])))

///|
/// Entry names and kinds of a directory.
pub fn read_dir(p : String) -> Array[(String, String)] raise NodeError {
  let parsed = @json.parse(check(js_read_dir(p))) catch {
    _ => raise NodeError("invalid directory listing")
  }
  guard parsed is Array(items) else { return [] }
  items.filter_map(item => {
    match item {
      Array([String(name), String(kind)]) => Some((name, kind))
      _ => None
    }
  })
}

///|
extern "js" fn js_mkdir(p : String, mode : Int) -> String = "(p, m) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.mkdirSync(p, { mode: m }); })"

///|
pub fn mkdir(p : String, mode? : Int = 0o777) -> Unit raise NodeError {
  check(js_mkdir(p, mode)) |> ignore
}

///|
extern "js" fn js_mkdir_all(p : String) -> String = "(p) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.mkdirSync(p, { recursive: true }); })"

///|
pub fn mkdir_all(p : String) -> Unit raise NodeError {
  check(js_mkdir_all(p)) |> ignore
}

///|
extern "js" fn js_rename(a : String, b : String) -> String = "(a, b) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.renameSync(a, b); })"

///|
pub fn rename(a : String, b : String) -> Unit raise NodeError {
  check(js_rename(a, b)) |> ignore
}

///|
extern "js" fn js_link(a : String, b : String) -> String = "(a, b) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.linkSync(a, b); })"

///|
pub fn hard_link(a : String, b : String) -> Unit raise NodeError {
  check(js_link(a, b)) |> ignore
}

///|
extern "js" fn js_unlink(p : String) -> String = "(p) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.unlinkSync(p); })"

///|
pub fn unlink(p : String) -> Unit raise NodeError {
  check(js_unlink(p)) |> ignore
}

///|
/// Create a new file that must not exist.
extern "js" fn js_create_new(p : String, text : String) -> String =
  #|(p, t) => globalThis.__readit.wrap(() => { const fs = globalThis.__readit.fs;
  #|  const fd = fs.openSync(p, 'wx'); try { fs.writeSync(fd, t); } finally { fs.closeSync(fd); } })

///|
pub fn create_new(p : String, text : String) -> Unit raise NodeError {
  check(js_create_new(p, text)) |> ignore
}

///|
/// Write through a private temporary file, keep permissions, fsync, rename.
extern "js" fn js_atomic_replace(p : String, text : String) -> String =
  #|(p, t) => { const R = globalThis.__readit, fs = R.fs, path = R.path;
  #|  const tmp = path.join(path.dirname(p), `.readit-${process.pid}-${process.hrtime.bigint()}.tmp`);
  #|  try { const fd = fs.openSync(tmp, 'wx');
  #|    try { try { fs.fchmodSync(fd, fs.statSync(p).mode & 0o7777); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  #|      fs.writeSync(fd, t); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  #|    fs.renameSync(tmp, p); return ''; }
  #|  catch (e) { try { fs.unlinkSync(tmp); } catch (_) {} return R.err(e); } }

///|
pub fn atomic_replace(p : String, text : String) -> Unit raise NodeError {
  check(js_atomic_replace(p, text)) |> ignore
}

///|
extern "js" fn js_chmod(p : String, mode : Int) -> String = "(p, m) => globalThis.__readit.wrap(() => { globalThis.__readit.fs.chmodSync(p, m); })"

///|
pub fn chmod(p : String, mode : Int) -> Unit raise NodeError {
  check(js_chmod(p, mode)) |> ignore
}

// ---- child processes ----

///|
/// Run a program to completion. Output is Latin-1 so NUL-separated bytes survive.
extern "js" fn js_run(program : String, args : String, cwd : String) -> String =
  #|(prog, args, cwd) => { const R = globalThis.__readit;
  #|  try { const r = R.cp.spawnSync(prog, JSON.parse(args), { cwd: cwd || undefined, maxBuffer: 64 * 1024 * 1024,
  #|      env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
  #|    if (r.error) return R.err(r.error);
  #|    return JSON.stringify({ status: r.status ?? -1, stdout: r.stdout.toString('latin1'), stderr: r.stderr.toString('utf8') });
  #|  } catch (e) { return R.err(e); } }

///|
pub(all) struct RunResult {
  status : Int
  /// Latin-1 bytes.
  stdout : String
  stderr : String
}

///|
pub fn run(
  program : String,
  args : Array[String],
  cwd? : String = "",
) -> RunResult raise NodeError {
  let encoded = Json::array(args.map(Json::string)).stringify()
  let out = check(js_run(program, encoded, cwd))
  let parsed = @json.parse(out) catch { _ => Json::null() }
  match parsed {
    { "status": Number(s, ..), "stdout": String(o), "stderr": String(e), .. } =>
      { status: s.to_int(), stdout: o, stderr: e, }
    _ => raise NodeError("invalid process result")
  }
}

///|
/// Start a long-lived process with piped stdin/stdout. Returns a handle id.
extern "js" fn js_spawn(
  program : String,
  args : String,
  cwd : String,
  on_data : (String) -> Unit,
  on_exit : (Int) -> Unit,
) -> String =
  #|(prog, args, cwd, onData, onExit) => { const R = globalThis.__readit;
  #|  try { const child = R.cp.spawn(prog, JSON.parse(args), { cwd, stdio: ['pipe', 'pipe', 'ignore'] });
  #|    let done = false; const finish = (c) => { if (!done) { done = true; onExit(c); } };
  #|    child.on('error', () => finish(-1)); child.on('exit', (c) => finish(c ?? -1));
  #|    child.stdin.on('error', () => {});
  #|    child.stdout.setEncoding('latin1'); child.stdout.on('data', (d) => onData(d));
  #|    return String(R.keep(child)); } catch (e) { return R.err(e); } }

///|
pub fn spawn(
  program : String,
  args : Array[String],
  cwd : String,
  on_data : (String) -> Unit,
  on_exit : (Int) -> Unit,
) -> Int raise NodeError {
  let encoded = Json::array(args.map(Json::string)).stringify()
  let id = check(js_spawn(program, encoded, cwd, on_data, on_exit))
  @core.parse_natural(id).unwrap_or(0)
}

///|
/// Write text to a child's stdin.
pub extern "js" fn child_write(id : Int, text : String) -> Bool =
  #|(id, t) => { const c = globalThis.__readit.handles.get(id);
  #|  if (!c || !c.stdin.writable) return false; try { c.stdin.write(t); return true; } catch (e) { return false; } }

///|
pub extern "js" fn child_kill(id : Int) -> Unit = "(id) => { const R = globalThis.__readit; const c = R.handles.get(id); if (c) { try { c.kill(); } catch (e) {} R.handles.delete(id); } }"

// ---- HTTP ----

///|
/// Listen on host:port. The handler receives a request id, method, URL,
/// headers as JSON and the body (UTF-8, at most 8 MiB).
extern "js" fn js_http_listen(
  host : String,
  port : Int,
  handler : (Int, String, String, String, String) -> Unit,
  ready : (String) -> Unit,
) -> Unit =
  #|(host, port, handler, ready) => { const R = globalThis.__readit;
  #|  const server = R.http.createServer((req, res) => {
  #|    const chunks = []; let size = 0;
  #|    req.on('data', (c) => { size += c.length; if (size > 8 * 1024 * 1024) { res.writeHead(413); res.end(); req.destroy(); } else chunks.push(c); });
  #|    req.on('end', () => { if (res.writableEnded) return; const id = R.keep(res);
  #|      res.on('close', () => { if (res.__onclose) res.__onclose(); R.handles.delete(id); });
  #|      let body = ''; try { body = R.utf8.decode(Buffer.concat(chunks)); } catch (e) { body = ''; }
  #|      handler(id, req.method, req.url, JSON.stringify(req.headers), body); });
  #|  });
  #|  server.on('error', (e) => ready('\u0000' + e.message));
  #|  server.listen(port, host, () => ready(String(server.address().port)));
  #|  R.httpServer = server; }

///|
pub fn http_listen(
  host : String,
  port : Int,
  handler : (Int, String, String, String, String) -> Unit,
  ready : (Result[Int, String]) -> Unit,
) -> Unit {
  js_http_listen(host, port, handler, result => {
    if result.length() > 0 && result[0] == 0 {
      ready(Err(@core.slice(result, 1, result.length())))
    } else {
      ready(Ok(@core.parse_natural(result).unwrap_or(0)))
    }
  })
}

///|
pub extern "js" fn http_close() -> Unit = "() => { const s = globalThis.__readit.httpServer; if (s) { s.close(); s.closeAllConnections?.(); } }"

///|
/// Send a complete response. Headers are a JSON object.
pub extern "js" fn http_respond(
  id : Int,
  status : Int,
  headers : String,
  body : String,
) -> Unit =
  #|(id, status, headers, body) => { const res = globalThis.__readit.handles.get(id); if (!res || res.writableEnded) return;
  #|  try { res.writeHead(status, JSON.parse(headers)); res.end(body); } catch (e) {} }

///|
/// Send a file from disk, or 404.
pub extern "js" fn http_send_file(
  id : Int,
  file : String,
  headers : String,
) -> Unit =
  #|(id, file, headers) => { const R = globalThis.__readit; const res = R.handles.get(id); if (!res) return;
  #|  R.fs.readFile(file, (err, data) => { if (res.writableEnded) return;
  #|    if (err) { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('not found'); return; }
  #|    res.writeHead(200, JSON.parse(headers)); res.end(data); }); }

///|
/// Start a streamed response (server-sent events). `on_close` runs when the client leaves.
pub extern "js" fn http_stream(
  id : Int,
  headers : String,
  on_close : () -> Unit,
) -> Unit =
  #|(id, headers, onClose) => { const res = globalThis.__readit.handles.get(id); if (!res) return;
  #|  res.__onclose = onClose; res.writeHead(200, JSON.parse(headers)); res.flushHeaders?.(); }

///|
pub extern "js" fn http_write(id : Int, chunk : String) -> Bool = "(id, c) => { const res = globalThis.__readit.handles.get(id); if (!res || res.writableEnded) return false; res.write(c); return true; }"

///|
pub extern "js" fn http_end(id : Int) -> Unit = "(id) => { const res = globalThis.__readit.handles.get(id); if (res && !res.writableEnded) res.end(); }"

// ---- Unix sockets ----

///|
/// Listen on a Unix socket. Each connection gets an id; `on_line` receives the
/// first line (without the newline) or "\u{0}" and a reason when it is invalid.
extern "js" fn js_unix_listen(
  file : String,
  max_bytes : Int,
  on_line : (Int, String) -> Unit,
) -> String =
  #|(file, max, onLine) => { const R = globalThis.__readit;
  #|  try { let active = 0;
  #|    const server = R.net.createServer((sock) => {
  #|      if (active >= 8) { sock.destroy(); return; } active++;
  #|      const id = R.keep(sock); let chunks = [], size = 0, done = false;
  #|      const finish = (value) => { if (done) return; done = true; sock.setTimeout(0); onLine(id, value); };
  #|      sock.setTimeout(3000, () => finish('\u0000incomplete request'));
  #|      sock.on('data', (d) => { if (done) return; const nl = d.indexOf(10);
  #|        const part = nl >= 0 ? d.subarray(0, nl) : d; size += part.length;
  #|        if (size > max) { finish('\u0000request is too large'); return; } chunks.push(part);
  #|        if (nl >= 0) { try { finish(R.utf8.decode(Buffer.concat(chunks))); } catch (e) { finish('\u0000invalid UTF-8'); } } });
  #|      sock.on('end', () => finish('\u0000incomplete request'));
  #|      sock.on('error', () => finish('\u0000connection failed'));
  #|      sock.on('close', () => { active--; R.handles.delete(id); });
  #|    });
  #|    server.listen(file); R.unixServer = server; return '';
  #|  } catch (e) { return R.err(e); } }

///|
pub fn unix_listen(
  file : String,
  max_bytes : Int,
  on_line : (Int, String) -> Unit,
) -> Unit raise NodeError {
  check(js_unix_listen(file, max_bytes, on_line)) |> ignore
}

///|
/// Wait until the socket server listens (or fails), then report.
pub extern "js" fn unix_ready(done : (String) -> Unit) -> Unit =
  #|(done) => { const s = globalThis.__readit.unixServer; if (!s) { done('\u0000not started'); return; }
  #|  if (s.listening) { done(''); return; }
  #|  s.once('listening', () => done('')); s.once('error', (e) => done('\u0000' + e.message)); }

///|
pub extern "js" fn unix_close() -> Unit = "() => { const s = globalThis.__readit.unixServer; if (s) s.close(); }"

///|
/// Reply on a connection and close it.
pub extern "js" fn socket_reply(id : Int, line : String) -> Unit = "(id, line) => { const s = globalThis.__readit.handles.get(id); if (s && !s.destroyed) { s.end(line + '\n'); } }"

///|
pub extern "js" fn socket_alive(id : Int) -> Bool = "(id) => { const s = globalThis.__readit.handles.get(id); return !!s && !s.destroyed; }"
