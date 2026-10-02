///|
/// The provisional reading role inferred from a file name.
pub fn role(path : String) -> String {
  let p = lower(path)
  if contains(p, "test") || contains(p, "spec.") {
    "検証"
  } else if ends_with(p, ".md") {
    "背景"
  } else if contains(p, "type") ||
    contains(p, "schema") ||
    contains(p, "contract") {
    "契約"
  } else if ends_with(p, ".toml") ||
    ends_with(p, ".json") ||
    ends_with(p, ".yaml") ||
    ends_with(p, ".yml") {
    "設定"
  } else {
    "実装"
  }
}

///|
/// Reading order of a role: background, contract, implementation, verification, settings.
pub fn role_order(path : String) -> Int {
  match role(path) {
    "背景" => 0
    "契約" => 1
    "実装" => 2
    "検証" => 3
    _ => 4
  }
}

///|
/// Sort paths into reading order, then code point order.
pub fn sort_reading_order(paths : Array[String]) -> Unit {
  // Each role is worked out once; comparing would redo it for every pair.
  let keyed = paths.map(p => (role_order(p), p))
  keyed.sort_by((a, b) => {
    let d = a.0 - b.0
    if d != 0 {
      d
    } else {
      lex_compare(a.1, b.1)
    }
  })
  for i, k in keyed {
    paths[i] = k.1
  }
}

///|
/// The highlighter and display language for a path.
pub fn language(path : String) -> String {
  match extension(path) {
    "rs" => "rust"
    "py" | "pyi" => "python"
    "js" | "mjs" | "cjs" | "jsx" => "javascript"
    "ts" | "mts" | "cts" => "typescript"
    "tsx" => "tsx"
    "json" | "jsonc" => "json"
    "md" => "markdown"
    "toml" => "toml"
    "yaml" | "yml" => "yaml"
    "html" | "htm" => "html"
    "css" => "css"
    "sh" | "bash" | "zsh" => "bash"
    "c" | "h" => "c"
    "cpp" | "hpp" | "cc" => "cpp"
    "go" => "go"
    "java" => "java"
    "rb" => "ruby"
    "swift" => "swift"
    "sql" => "sql"
    "cs" => "csharp"
    "ex" | "exs" => "elixir"
    "graphql" => "graphql"
    "proto" => "proto"
    "zig" => "zig"
    "mbt" | "mbti" => "moonbit"
    _ => "text"
  }
}

///|
/// The LSP language id, when a language server handles the file.
pub fn language_id(path : String) -> String? {
  match extension(path) {
    "py" | "pyi" => Some("python")
    "rs" => Some("rust")
    "java" => Some("java")
    "ts" | "mts" | "cts" => Some("typescript")
    "tsx" => Some("typescriptreact")
    "js" | "mjs" | "cjs" => Some("javascript")
    "jsx" => Some("javascriptreact")
    _ => None
  }
}

///|
/// The language server family that handles a language id.
pub fn language_family(language_id : String) -> String {
  match language_id {
    "python" | "rust" | "java" => language_id
    _ => "typescript"
  }
}
