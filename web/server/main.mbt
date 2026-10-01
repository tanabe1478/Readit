///|
let help : String =
  #|Readit — code reading editor (browser)
  #|
  #|readit-web [repository-directory] [--control-socket /private/directory/control.sock]
  #|           [--port 7420] [--web-root DIR] [--tools DIR] [--label NAME]
  #|           [--exit-with-stdin]
  #|readit-web --demo
  #|
  #|Serves the editor on http://127.0.0.1 only. A local MCP client can guide
  #|the visible window when --control-socket is set. --label names the window,
  #|for example after the AI session that started it. --exit-with-stdin stops the
  #|server when its standard input closes, i.e. when the process that started it ends.

///|
fn main {
  init_node()
  let args = argv()
  let mut socket = ""
  let mut directory = ""
  let mut demo = false
  let mut port = 7420
  let mut web_root = ""
  let mut tools = ""
  let mut label = ""
  let mut exit_with_stdin = false
  let mut i = 0
  let value = (name : String) => {
    i += 1
    match args.get(i) {
      Some(v) => v
      None => {
        eprint("\{name} requires a value")
        exit(2)
        ""
      }
    }
  }
  while i < args.length() {
    match args[i] {
      "--help" | "-h" => {
        eprint(help)
        return
      }
      "--control-socket" => socket = value("--control-socket")
      "--port" =>
        port = match @core.parse_natural(value("--port")) {
          Some(p) if p < 65536 => p
          _ => {
            eprint("--port requires a number")
            exit(2)
            0
          }
        }
      "--web-root" => web_root = value("--web-root")
      "--tools" => tools = value("--tools")
      "--label" => label = value("--label")
      "--exit-with-stdin" => exit_with_stdin = true
      "--demo" => demo = true
      arg =>
        if !@core.starts_with(arg, "-") && directory == "" {
          directory = arg
        } else {
          eprint("unknown argument: \{arg}")
          exit(2)
        }
    }
    i += 1
  }
  if demo && directory != "" {
    eprint("choose --demo or a repository directory")
    exit(2)
  }
  if web_root == "" {
    // web/_build/js/<mode>/build/server/server.js
    let mut dir = script_dir()
    for _ in 0..<5 {
      dir = path_dirname(dir)
    }
    web_root = dir
  }
  let repo_root = path_dirname(web_root)
  if tools == "" {
    tools = path_join(repo_root, "tools/lsp")
  }
  let demo = demo || directory == ""
  let root = if directory == "" {
    path_join(repo_root, "demo")
  } else {
    path_resolve(cwd(), directory)
  }
  let workspace = Workspace::load(root) catch {
    Failure(m) => {
      eprint("Readit: \{@core.failure_text(m)}")
      exit(1)
      return
    }
  }
  for warning in workspace.warnings {
    eprint(warning)
  }
  let server : Server = {
    web_root,
    token: random_token(),
    url: "",
    workspace: Some(workspace),
    service: Service::new(tools),
    control: None,
    control_path: socket,
    demo,
    label,
  }
  let start_http = () => {
    http_listen(
      "127.0.0.1",
      port,
      (id, op, url, headers, body) => server.handle(id, op, url, headers, body),
      ready => {
        match ready {
          Ok(actual) => {
            server.url = "http://127.0.0.1:\{actual}/"
            eprint("Readit: \{server.url}")
          }
          Err(message) => {
            eprint("Readit: \{message}")
            if server.control is Some(c) {
              c.close()
            }
            exit(1)
          }
        }
      },
    )
  }
  let stop = () => {
    server.service.shutdown()
    if server.control is Some(c) {
      c.close()
    }
  }
  on_signal(stop)
  if exit_with_stdin {
    on_stdin_end(stop)
  }
  if socket == "" {
    start_http()
    return
  }
  let control = Control::bind(socket) catch {
    Failure(m) => {
      eprint("Readit control: \{@core.failure_text(m)}")
      exit(2)
      return
    }
  }
  control.ready(result => {
    match result {
      Ok(_) => {
        server.control = Some(control)
        eprint("Readit control socket: \{socket}")
        start_http()
      }
      Err(message) => {
        eprint("Readit control: \{message}")
        exit(2)
      }
    }
  })
}
