///|
test "supports location links and hierarchical symbols" {
  let selection : Json = {
    "start": { "line": 4, "character": 3 },
    "end": { "line": 4, "character": 7 },
  }
  let target : Json = {
    "targetUri": "file:///tmp/%E6%97%A5%20a.py",
    "targetSelectionRange": selection,
    "targetRange": {
      "start": { "line": 0, "character": 0 },
      "end": { "line": 5, "character": 0 },
    },
  }
  let result = @lsp.targets([target, target])
  assert_eq(result.length(), 1)
  assert_eq(result[0].start.line, 4)
  assert_eq(result[0].path, "/tmp/日 a.py")
  assert_eq(
    @lsp.targets({ "uri": "https://example.com/code", "range": selection }).length(),
    0,
  )
  let symbols = @lsp.symbols(
    [
      {
        "name": "Outer",
        "kind": 5,
        "selectionRange": selection,
        "children": [
          { "name": "inner", "kind": 6, "selectionRange": selection },
        ],
      },
    ],
    "/tmp/a.py",
  )
  assert_eq(symbols[1].name, "Outer › inner")
  assert_eq(symbols[0].detail, "class  ")
}

///|
test "uri roundtrip" {
  let path = "/Users/x/日本語 file (1).py"
  assert_eq(@lsp.uri_to_path(@lsp.path_to_uri(path)), Some(path))
  assert_eq(@lsp.path_to_uri("/a b"), "file:///a%20b")
}

///|
test "hover text joins marked strings" {
  let v : Json = {
    "contents": [{ "language": "python", "value": "def f()" }, "", "doc"],
  }
  assert_eq(@lsp.hover_text(v), "def f()\n\ndoc")
  assert_eq(
    @lsp.hover_text({ "contents": { "kind": "markdown", "value": "x" } }),
    "x",
  )
}

///|
test "framing handles split and multiple messages" {
  let f = @lsp.Framer::new()
  let first = f.feed("Content-Length: 2\r\n\r\n{}Content-Le")
  assert_eq(first, ["{}"])
  let second = f.feed("ngth: 4\r\n\r\nnull")
  assert_eq(second, ["null"])
  let bad = @lsp.Framer::new()
  let failed = try bad.feed("Content-Length: 999999999\r\n\r\n") catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(failed)
}

///|
test "configuration sections" {
  assert_eq(@lsp.configuration("rust-analyzer.check"), { "enable": false })
  assert_eq(@lsp.configuration("missing.part"), Json::null())
}

///|
test "describe adds summary and preview" {
  let t : @lsp.Target = {
    path: "/a.py",
    start: { line: 2, character: 0, },
    end: { line: 2, character: 1, },
    name: "",
    detail: "",
    preview: "",
  }
  @lsp.describe(t, "a\nb\n  c = 1\nd\n")
  assert_eq(t.detail, "c = 1")
  assert_eq(t.preview, "   1 a\n   2 b\n   3   c = 1\n   4 d")
}
