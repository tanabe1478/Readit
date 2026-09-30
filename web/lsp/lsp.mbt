// LSP result parsing. Positions on the wire are UTF-16, as negotiated at initialize.

///|
pub(all) struct Target {
  path : String
  start : @core.Position
  end : @core.Position
  mut name : String
  mut detail : String
  mut preview : String
} derive(Debug)

///|
pub(all) enum Query {
  Definition
  TypeDefinition
  Implementation
  References
  Symbols
  Hover
} derive(Eq, Debug)

///|
pub fn Query::title(self : Query) -> String {
  match self {
    Definition => "定義"
    TypeDefinition => "型定義"
    Implementation => "実装"
    References => "使用箇所"
    Symbols => "ファイル内のシンボル"
    Hover => "型とドキュメント"
  }
}

///|
pub fn Query::method_name(self : Query) -> String {
  match self {
    Definition => "textDocument/definition"
    TypeDefinition => "textDocument/typeDefinition"
    Implementation => "textDocument/implementation"
    References => "textDocument/references"
    Symbols => "textDocument/documentSymbol"
    Hover => "textDocument/hover"
  }
}

///|
pub fn Query::capability(self : Query) -> String {
  match self {
    Definition => "definitionProvider"
    TypeDefinition => "typeDefinitionProvider"
    Implementation => "implementationProvider"
    References => "referencesProvider"
    Symbols => "documentSymbolProvider"
    Hover => "hoverProvider"
  }
}

///|
pub fn Query::name(self : Query) -> String {
  match self {
    Definition => "definition"
    TypeDefinition => "type_definition"
    Implementation => "implementation"
    References => "references"
    Symbols => "symbols"
    Hover => "hover"
  }
}

///|
pub fn Query::parse(name : String) -> Query? {
  match name {
    "definition" => Some(Definition)
    "type_definition" => Some(TypeDefinition)
    "implementation" => Some(Implementation)
    "references" => Some(References)
    "symbols" => Some(Symbols)
    "hover" => Some(Hover)
    _ => None
  }
}

///|
fn number(value : Json?) -> Int? {
  match value {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn text_of(value : Json?) -> String? {
  match value {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn position(value : Json?) -> @core.Position? {
  match value {
    Some(Object(o)) =>
      match (number(o.get("line")), number(o.get("character"))) {
        (Some(line), Some(character)) => Some({ line, character, })
        _ => None
      }
    _ => None
  }
}

///|
fn range(value : Json?) -> (@core.Position, @core.Position)? {
  match value {
    Some(Object(o)) =>
      match (position(o.get("start")), position(o.get("end"))) {
        (Some(s), Some(e)) => Some((s, e))
        _ => None
      }
    _ => None
  }
}

///|
/// Locations and location links, deduplicated by start.
pub fn targets(value : Json) -> Array[Target] {
  let items = match value {
    Array(items) => items
    Object(_) => [value]
    _ => []
  }
  let seen : Map[String, Unit] = Map([])
  let out = []
  for item in items {
    guard item is Object(o) else { continue }
    let uri = match text_of(o.get("uri")) {
      Some(u) => Some(u)
      None => text_of(o.get("targetUri"))
    }
    guard uri is Some(u) && uri_to_path(u) is Some(path) else { continue }
    let r = match range(o.get("range")) {
      Some(r) => Some(r)
      None =>
        match range(o.get("targetSelectionRange")) {
          Some(r) => Some(r)
          None => range(o.get("targetRange"))
        }
    }
    guard r is Some((start, end)) else { continue }
    let key = "\{path}\n\{start.line}\n\{start.character}"
    if seen.contains(key) {
      continue
    }
    seen[key] = ()
    out.push({ path, start, end, name: "", detail: "", preview: "", })
  }
  out
}

///|
fn symbol_kind(kind : Int) -> String {
  match kind {
    2 => "module"
    5 => "class"
    6 => "method"
    7 => "property"
    8 => "field"
    9 => "constructor"
    10 => "enum"
    11 => "interface"
    12 => "function"
    13 => "variable"
    14 => "constant"
    23 => "struct"
    _ => "symbol"
  }
}

///|
/// Document symbols, flattened with `Outer › inner` names.
pub fn symbols(value : Json, document : String) -> Array[Target] {
  let out = []
  fn visit(items : Json?, parent : String, depth : Int) {
    if depth > 32 {
      return
    }
    guard items is Some(Array(list)) else { return }
    for item in list {
      guard item is Object(o) else { continue }
      let name = text_of(o.get("name")).unwrap_or("?")
      let qualified = if parent == "" { name } else { "\{parent} › \{name}" }
      let target = match o.get("location") {
        Some(location) => targets(location).get(0)
        None => {
          let r = match range(o.get("selectionRange")) {
            Some(r) => Some(r)
            None => range(o.get("range"))
          }
          match r {
            Some((start, end)) =>
              Some({
                path: document,
                start,
                end,
                name: "",
                detail: "",
                preview: "",
              })
            None => None
          }
        }
      }
      if target is Some(t) {
        t.name = qualified
        t.detail = "\{symbol_kind(number(o.get("kind")).unwrap_or(0))}  \{text_of(o.get("detail")).unwrap_or("")}"
        out.push(t)
      }
      visit(o.get("children"), qualified, depth + 1)
    }
  }

  visit(Some(value), "", 0)
  out
}

///|
/// Plain text of a hover result: strings, marked strings and markup content.
pub fn hover_text(value : Json) -> String {
  fn content(v : Json) -> String {
    match v {
      String(s) => s
      Array(items) => items.map(content).filter(s => s != "").join("\n\n")
      Object(o) => text_of(o.get("value")).unwrap_or("")
      _ => ""
    }
  }

  match value {
    Object(o) =>
      match o.get("contents") {
        Some(c) => content(c)
        None => ""
      }
    _ => ""
  }
}

///|
/// Settings answered for workspace/configuration. Reading only: no builds.
pub fn settings() -> Json {
  {
    "python": {
      "analysis": {
        "autoSearchPaths": true,
        "useLibraryCodeForTypes": true,
        "diagnosticMode": "openFilesOnly",
        "typeCheckingMode": "basic",
      },
    },
    "rust-analyzer": {
      "checkOnSave": false,
      "check": { "enable": false },
      "cargo": { "buildScripts": { "enable": false } },
      "procMacro": { "enable": false },
    },
    "java": {
      "autobuild": { "enabled": false },
      "maven": { "downloadSources": true },
      "import": { "gradle": { "enabled": true }, "maven": { "enabled": true } },
      "references": { "includeDecompiledSources": true },
      "signatureHelp": { "enabled": false },
      "implementationsCodeLens": { "enabled": false },
      "errors": { "incompleteClasspath": { "severity": "ignore" } },
    },
  }
}

///|
/// One dotted section of the settings, or null.
pub fn configuration(section : String) -> Json {
  let mut result = settings()
  for part in section.split(".") {
    let key = part.to_owned()
    if key == "" {
      continue
    }
    result = match result {
      Object(o) => o.get(key).unwrap_or(Json::null())
      _ => Json::null()
    }
  }
  result
}

///|
/// Detail and a numbered nine-line preview for a target, from its file text.
pub fn describe(target : Target, text : String) -> Unit {
  let lines = @core.lines(text)
  let line = lines.get(target.start.line).unwrap_or("")
  let summary = @core.take_chars(@core.trim(line), 180)
  if target.detail != "" {
    target.detail = target.detail + " · "
  }
  target.detail = target.detail + summary
  let first = if target.start.line >= 2 { target.start.line - 2 } else { 0 }
  let preview = []
  for i in first..<(first + 9).min(lines.length()) {
    let number = (i + 1).to_string()
    let padded = " ".repeat((4 - number.length()).max(0)) + number
    preview.push("\{padded} \{@core.take_chars(lines[i], 180)}")
  }
  target.preview = preview.join("\n")
}
