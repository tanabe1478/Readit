//! Local LSP client. All positions on the wire are UTF-16, as negotiated at initialize.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};
use url::Url;

type Result<T> = std::result::Result<T, String>;
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Position {
    pub line: u32,
    pub character: u32,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Target {
    pub path: PathBuf,
    pub start: Position,
    pub end: Position,
    pub name: String,
    pub detail: String,
    pub preview: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Query {
    Definition,
    TypeDefinition,
    Implementation,
    References,
    Symbols,
    Hover,
}
impl Query {
    pub fn title(self) -> &'static str {
        match self {
            Self::Definition => "定義",
            Self::TypeDefinition => "型定義",
            Self::Implementation => "実装",
            Self::References => "使用箇所",
            Self::Symbols => "ファイル内のシンボル",
            Self::Hover => "型とドキュメント",
        }
    }
    fn method(self) -> &'static str {
        match self {
            Self::Definition => "textDocument/definition",
            Self::TypeDefinition => "textDocument/typeDefinition",
            Self::Implementation => "textDocument/implementation",
            Self::References => "textDocument/references",
            Self::Symbols => "textDocument/documentSymbol",
            Self::Hover => "textDocument/hover",
        }
    }
    fn capability(self) -> &'static str {
        match self {
            Self::Definition => "definitionProvider",
            Self::TypeDefinition => "typeDefinitionProvider",
            Self::Implementation => "implementationProvider",
            Self::References => "referencesProvider",
            Self::Symbols => "documentSymbolProvider",
            Self::Hover => "hoverProvider",
        }
    }
}
#[derive(Clone)]
pub struct Snapshot {
    pub root: PathBuf,
    pub path: PathBuf,
    pub position: Position,
    /// Current unsaved content, including other open files in this project.
    pub documents: Vec<(PathBuf, String)>,
}
#[derive(Debug, Default)]
pub struct Answer {
    pub targets: Vec<Target>,
    pub information: String,
    pub server: String,
}

pub fn language_id(path: &Path) -> Option<&'static str> {
    match path.extension()?.to_str()? {
        "py" | "pyi" => Some("python"),
        "rs" => Some("rust"),
        "java" => Some("java"),
        "ts" | "mts" | "cts" => Some("typescript"),
        "tsx" => Some("typescriptreact"),
        "js" | "mjs" | "cjs" => Some("javascript"),
        "jsx" => Some("javascriptreact"),
        _ => None,
    }
}
fn family(language: &str) -> &str {
    if matches!(language, "python" | "rust" | "java") {
        language
    } else {
        "typescript"
    }
}
pub fn uri(path: &Path) -> Result<String> {
    Url::from_file_path(path)
        .map(|u| u.to_string())
        .map_err(|_| "絶対ファイルパスが必要です".into())
}
fn file_path(value: &Value) -> Option<PathBuf> {
    Url::parse(value.as_str()?).ok()?.to_file_path().ok()
}
/// Convert a UTF-8 byte offset to an LSP UTF-16 position without splitting a character.
pub fn position_at(text: &str, offset: usize) -> Position {
    let mut at = offset.min(text.len());
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    let before = &text[..at];
    Position {
        line: before.bytes().filter(|b| *b == b'\n').count() as u32,
        character: before
            .rsplit('\n')
            .next()
            .unwrap_or("")
            .encode_utf16()
            .count() as u32,
    }
}
pub fn byte_offset(text: &str, position: Position) -> usize {
    let mut start = 0;
    for _ in 0..position.line {
        match text[start..].find('\n') {
            Some(n) => start += n + 1,
            None => return text.len(),
        }
    }
    let line = text[start..].split('\n').next().unwrap_or("");
    let mut units = 0;
    for (byte, c) in line.char_indices() {
        if units + c.len_utf16() > position.character as usize {
            return start + byte;
        }
        units += c.len_utf16();
    }
    start + line.len()
}
fn range(value: &Value) -> Option<(Position, Position)> {
    Some((
        serde_json::from_value(value.get("start")?.clone()).ok()?,
        serde_json::from_value(value.get("end")?.clone()).ok()?,
    ))
}
pub fn targets(value: &Value) -> Vec<Target> {
    let items: Vec<_> = if let Some(items) = value.as_array() {
        items.iter().collect()
    } else if value.is_object() {
        vec![value]
    } else {
        vec![]
    };
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter_map(|item| {
            let path = file_path(item.get("uri").or_else(|| item.get("targetUri"))?)?;
            let (start, end) = range(
                item.get("range")
                    .or_else(|| item.get("targetSelectionRange"))
                    .or_else(|| item.get("targetRange"))?,
            )?;
            if !seen.insert((path.clone(), start.line, start.character)) {
                return None;
            }
            Some(Target {
                path,
                start,
                end,
                name: String::new(),
                detail: String::new(),
                preview: String::new(),
            })
        })
        .collect()
}
fn symbol_kind(kind: u64) -> &'static str {
    match kind {
        2 => "module",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        23 => "struct",
        _ => "symbol",
    }
}
pub fn symbols(value: &Value, document: &Path) -> Vec<Target> {
    fn visit(items: &Value, document: &Path, parent: &str, out: &mut Vec<Target>, depth: usize) {
        if depth > 32 {
            return;
        }
        for item in items.as_array().into_iter().flatten() {
            let name = item["name"].as_str().unwrap_or("?");
            let qualified = if parent.is_empty() {
                name.into()
            } else {
                format!("{parent} › {name}")
            };
            let target = if item.get("location").is_some() {
                targets(&item["location"]).into_iter().next()
            } else {
                range(item.get("selectionRange").unwrap_or(&item["range"])).map(|(start, end)| {
                    Target {
                        path: document.into(),
                        start,
                        end,
                        name: String::new(),
                        detail: String::new(),
                        preview: String::new(),
                    }
                })
            };
            if let Some(mut target) = target {
                target.name = qualified.clone();
                target.detail = format!(
                    "{}  {}",
                    symbol_kind(item["kind"].as_u64().unwrap_or(0)),
                    item["detail"].as_str().unwrap_or("")
                );
                out.push(target);
            }
            visit(&item["children"], document, &qualified, out, depth + 1);
        }
    }
    let mut out = Vec::new();
    visit(value, document, "", &mut out, 0);
    out
}
pub fn hover_text(value: &Value) -> String {
    fn content(value: &Value) -> String {
        match value {
            Value::String(s) => s.clone(),
            Value::Array(v) => v
                .iter()
                .map(content)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n\n"),
            Value::Object(_) => value["value"].as_str().unwrap_or("").into(),
            _ => String::new(),
        }
    }
    content(&value["contents"])
}
fn write_message(writer: &mut impl Write, message: &Value) -> Result<()> {
    let body = serde_json::to_vec(message).map_err(|e| e.to_string())?;
    write!(writer, "Content-Length: {}\r\n\r\n", body.len()).map_err(|e| e.to_string())?;
    writer
        .write_all(&body)
        .and_then(|_| writer.flush())
        .map_err(|e| e.to_string())
}
fn read_message(reader: &mut impl BufRead) -> Result<Value> {
    let mut length = None;
    let mut headers = 0;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            return Err("言語サーバーが終了しました".into());
        }
        headers += line.len();
        if headers > 8192 {
            return Err("LSPヘッダーが大きすぎます".into());
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            if key.eq_ignore_ascii_case("Content-Length") {
                length = value.trim().parse::<usize>().ok();
            }
        }
    }
    let length = length
        .filter(|n| *n <= 16 * 1024 * 1024)
        .ok_or("不正なLSPメッセージ長です")?;
    let mut data = vec![0; length];
    reader.read_exact(&mut data).map_err(|e| e.to_string())?;
    serde_json::from_slice(&data).map_err(|e| e.to_string())
}
fn settings() -> Value {
    json!({"python":{"analysis":{"autoSearchPaths":true,"useLibraryCodeForTypes":true,"diagnosticMode":"openFilesOnly","typeCheckingMode":"basic"}},
        "rust-analyzer":{"checkOnSave":false,"check":{"enable":false},"cargo":{"buildScripts":{"enable":false}},"procMacro":{"enable":false}},
        // Reading only: no build on save, no formatter, no code generation.
        "java":{"autobuild":{"enabled":false},"maven":{"downloadSources":true},"import":{"gradle":{"enabled":true},"maven":{"enabled":true}},
            "references":{"includeDecompiledSources":true},"signatureHelp":{"enabled":false},"implementationsCodeLens":{"enabled":false},
            "errors":{"incompleteClasspath":{"severity":"ignore"}}}})
}
fn configuration(section: &str) -> Value {
    let mut result = settings();
    for part in section.split('.').filter(|s| !s.is_empty()) {
        result = result.get(part).cloned().unwrap_or(Value::Null);
    }
    result
}
fn tools_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tools/lsp")
}
fn runtime() -> Value {
    std::fs::read(tools_dir().join("runtime.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null)
}
/// Where Eclipse JDT keeps its own project model; the opened repository is never written to.
fn java_data_dir(root: &Path) -> PathBuf {
    let mut name = String::new();
    for part in root.to_string_lossy().chars() {
        name.push(if part.is_alphanumeric() { part } else { '-' });
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".readit/jdtls").join(name)
}
fn java_command(config: &Value, root: &Path) -> Result<(Command, String)> {
    let java = std::env::var("READIT_JAVA")
        .ok()
        .or_else(|| config["java"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "java".into());
    let launcher = config["javaLauncher"]
        .as_str()
        .ok_or("Java言語サーバー未導入です。Readitで python3 scripts/setup_lsp.py を実行してください")?;
    let configuration = config["javaConfiguration"]
        .as_str()
        .ok_or("Java言語サーバーの設定が見つかりません。scripts/setup_lsp.pyを再実行してください")?;
    let data = java_data_dir(root);
    std::fs::create_dir_all(&data).map_err(|e| e.to_string())?;
    let mut command = Command::new(java);
    command.args([
        "-Declipse.application=org.eclipse.jdt.ls.core.id1",
        "-Dosgi.bundles.defaultStartLevel=4",
        "-Declipse.product=org.eclipse.jdt.ls.core.product",
        "-Dlog.level=ERROR",
        "-Xmx2G",
        "--add-modules=ALL-SYSTEM",
        "--add-opens",
        "java.base/java.util=ALL-UNNAMED",
        "--add-opens",
        "java.base/java.lang=ALL-UNNAMED",
        "-jar",
    ]);
    command.arg(launcher);
    command.arg("-configuration").arg(configuration);
    command.arg("-data").arg(data);
    Ok((command, "Eclipse JDT Language Server".into()))
}
fn server_command(language: &str, root: &Path) -> Result<(Command, String)> {
    let config = runtime();
    if language == "java" {
        return java_command(&config, root);
    }
    if language == "rust" {
        let path = std::env::var("READIT_RUST_ANALYZER")
            .ok()
            .or_else(|| config["rustAnalyzer"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "rust-analyzer".into());
        return Ok((Command::new(path), "rust-analyzer".into()));
    }
    let node = std::env::var("READIT_NODE")
        .ok()
        .or_else(|| config["node"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "node".into());
    let (name, script) = if language == "python" {
        ("Pyright", "node_modules/pyright/langserver.index.js")
    } else {
        (
            "TypeScript Language Server",
            "node_modules/typescript-language-server/lib/cli.mjs",
        )
    };
    let script = tools_dir().join(script);
    if !script.is_file() {
        return Err(
            "言語サーバー未導入です。Readitで python3 scripts/setup_lsp.py を実行してください"
                .into(),
        );
    }
    let mut cmd = Command::new(node);
    cmd.arg(script).arg("--stdio");
    Ok((cmd, name.into()))
}
struct Client {
    child: Child,
    input: Arc<Mutex<ChildStdin>>,
    responses: mpsc::Receiver<Result<Value>>,
    next_id: u64,
    capabilities: Value,
    documents: HashMap<String, (i64, String)>,
    name: String,
    warming_up: bool,
}
impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.notify("exit", Value::Null);
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Client {
    fn start(language: &str, root: &Path) -> Result<Self> {
        let (mut command, name) = server_command(language, root)?;
        let mut child = command
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                format!("{name}を起動できません: {e}。scripts/setup_lsp.pyで設定を確認してください")
            })?;
        let input = Arc::new(Mutex::new(child.stdin.take().unwrap()));
        let stdout = child.stdout.take().unwrap();
        let (sender, responses) = mpsc::channel();
        let writer = input.clone();
        let root_uri = uri(root)?;
        let reader_root = root_uri.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_message(&mut reader) {
                    Ok(message) => {
                        if let (Some(method), Some(id)) =
                            (message["method"].as_str(), message.get("id"))
                        {
                            let result = match method {
                                "workspace/configuration" => Some(Value::Array(
                                    message["params"]["items"]
                                        .as_array()
                                        .into_iter()
                                        .flatten()
                                        .map(|i| configuration(i["section"].as_str().unwrap_or("")))
                                        .collect(),
                                )),
                                "workspace/workspaceFolders" => {
                                    Some(json!([{"uri":reader_root,"name":"Readit"}]))
                                }
                                "client/registerCapability"
                                | "client/unregisterCapability"
                                | "window/workDoneProgress/create" => Some(Value::Null),
                                "workspace/applyEdit" => Some(
                                    json!({"applied":false,"failureReason":"Readit navigation never applies server edits"}),
                                ),
                                _ => None,
                            };
                            let response = if let Some(result) = result {
                                json!({"jsonrpc":"2.0","id":id,"result":result})
                            } else {
                                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Unsupported client request"}})
                            };
                            if let Ok(mut writer) = writer.lock() {
                                let _ = write_message(&mut *writer, &response);
                            }
                        } else if message.get("id").is_some() {
                            if sender.send(Ok(message)).is_err() {
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        let _ = sender.send(Err(e));
                        break;
                    }
                }
            }
        });
        let mut client = Self {
            child,
            input,
            responses,
            next_id: 0,
            capabilities: Value::Null,
            documents: HashMap::new(),
            name,
            warming_up: true,
        };
        let options = if language == "rust" {
            configuration("rust-analyzer")
        } else if language == "java" {
            // Eclipse JDT takes its settings at initialize; class file contents stay off
            // because this editor opens plain files only.
            json!({"workspaceFolders":[root_uri],"settings":settings(),
                "extendedClientCapabilities":{"classFileContentsSupport":false,"progressReportProvider":false,"advancedExtractRefactoringSupport":false,"resolveAdditionalTextEditsSupport":false}})
        } else if language == "typescript" {
            json!({"hostInfo":"readit","tsserver":{"path":tools_dir().join("node_modules/typescript/lib/tsserver.js")},"preferences":{"includePackageJsonAutoImports":"off"}})
        } else {
            json!({})
        };
        let result=client.request("initialize",json!({"processId":std::process::id(),"clientInfo":{"name":"Readit","version":"0.3.0"},"rootUri":root_uri,"workspaceFolders":[{"uri":root_uri,"name":root.file_name().unwrap_or_default().to_string_lossy()}],
            "capabilities":{"general":{"positionEncodings":["utf-16"]},"workspace":{"configuration":true,"workspaceFolders":true},"textDocument":{"definition":{"linkSupport":true},"typeDefinition":{"linkSupport":true},"implementation":{"linkSupport":true},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true},"hover":{"contentFormat":["plaintext","markdown"]},"synchronization":{"dynamicRegistration":false}}},"initializationOptions":options}),Duration::from_secs(30))?;
        client.capabilities = result["capabilities"].clone();
        if client.capabilities["positionEncoding"]
            .as_str()
            .is_some_and(|s| s != "utf-16")
        {
            return Err("UTF-16以外の言語サーバーには未対応です".into());
        }
        client.notify("initialized", json!({}))?;
        client.notify(
            "workspace/didChangeConfiguration",
            json!({"settings":settings()}),
        )?;
        Ok(client)
    }
    fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        write_message(
            &mut *self.input.lock().map_err(|_| "LSP接続ロックエラー")?,
            &json!({"jsonrpc":"2.0","method":method,"params":params}),
        )
    }
    fn request(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        write_message(
            &mut *self.input.lock().map_err(|_| "LSP接続ロックエラー")?,
            &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
        )?;
        let deadline = Instant::now() + timeout;
        loop {
            let response = match self
                .responses
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                Ok(r) => r?,
                Err(_) => {
                    let _ = self.notify("$/cancelRequest", json!({"id":id}));
                    return Err("解析が時間内に完了しませんでした。再度実行できます".into());
                }
            };
            if response["id"].as_u64() != Some(id) {
                continue;
            }
            if let Some(error) = response.get("error") {
                return Err(format!(
                    "{}: {}",
                    self.name,
                    error["message"].as_str().unwrap_or("解析エラー")
                ));
            }
            return Ok(response["result"].clone());
        }
    }
    fn sync(&mut self, snapshot: &Snapshot, language: &str) -> Result<()> {
        let docs: Vec<_> = snapshot
            .documents
            .iter()
            .filter(|(p, _)| language_id(p).is_some_and(|l| family(l) == language))
            .collect();
        let mut current = HashSet::new();
        for (path, text) in docs {
            let uri = uri(path)?;
            current.insert(uri.clone());
            let previous = self.documents.get(&uri);
            if previous.is_some_and(|(_, t)| t == text) {
                continue;
            }
            let version = previous.map_or(1, |(v, _)| v + 1);
            if previous.is_some() {
                self.notify("textDocument/didChange",json!({"textDocument":{"uri":uri,"version":version},"contentChanges":[{"text":text}]}))?;
            } else {
                self.notify("textDocument/didOpen",json!({"textDocument":{"uri":uri,"languageId":language_id(path),"version":version,"text":text}}))?;
            }
            self.documents.insert(uri, (version, text.clone()));
        }
        for uri in self
            .documents
            .keys()
            .filter(|u| !current.contains(*u))
            .cloned()
            .collect::<Vec<_>>()
        {
            self.notify("textDocument/didClose", json!({"textDocument":{"uri":uri}}))?;
            self.documents.remove(&uri);
        }
        Ok(())
    }
}
#[derive(Default)]
pub struct Service {
    root: PathBuf,
    clients: HashMap<String, Client>,
}
impl Service {
    pub fn query(&mut self, query: Query, snapshot: Snapshot) -> Result<Answer> {
        let language = family(
            language_id(&snapshot.path)
                .ok_or("この言語の解析は未対応です（Python・JS/TS・Rust・Javaに対応）")?,
        )
        .to_string();
        if self.root != snapshot.root {
            self.clients.clear();
            self.root = snapshot.root.clone();
        }
        if self
            .clients
            .get_mut(&language)
            .is_some_and(|c| c.child.try_wait().ok().flatten().is_some())
        {
            self.clients.remove(&language);
        }
        if !self.clients.contains_key(&language) {
            self.clients
                .insert(language.clone(), Client::start(&language, &snapshot.root)?);
        }
        let client = self.clients.get_mut(&language).unwrap();
        if !client
            .capabilities
            .get(query.capability())
            .is_some_and(|v| v == &Value::Bool(true) || v.is_object())
        {
            return Err(format!(
                "{}は「{}」を提供していません",
                client.name,
                query.title()
            ));
        }
        client.sync(&snapshot, &language)?;
        let mut params =
            json!({"textDocument":{"uri":uri(&snapshot.path)?},"position":snapshot.position});
        if query == Query::References {
            params["context"] = json!({"includeDeclaration":true});
        }
        let mut result = client.request(query.method(), params.clone(), Duration::from_secs(20))?;
        if matches!(language.as_str(), "rust" | "java") && client.warming_up {
            let deadline = Instant::now()
                + if language == "java" {
                    Duration::from_secs(180)
                } else {
                    Duration::from_secs(5)
                };
            while (result.is_null() || result.as_array().is_some_and(|v| v.is_empty()))
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(250));
                result = client.request(query.method(), params.clone(), Duration::from_secs(20))?;
            }
        }
        client.warming_up = false;
        let mut found = if query == Query::Symbols {
            symbols(&result, &snapshot.path)
        } else {
            targets(&result)
        };
        found.truncate(2000);
        let mut contents: HashMap<PathBuf, String> = snapshot.documents.iter().cloned().collect();
        for target in &mut found {
            if !contents.contains_key(&target.path)
                && std::fs::metadata(&target.path)
                    .is_ok_and(|m| m.is_file() && m.len() <= 1024 * 1024)
            {
                if let Ok(text) = std::fs::read_to_string(&target.path) {
                    contents.insert(target.path.clone(), text);
                }
            }
            if let Some(text) = contents.get(&target.path) {
                let line: String = text
                    .lines()
                    .nth(target.start.line as usize)
                    .unwrap_or("")
                    .trim()
                    .chars()
                    .take(180)
                    .collect();
                if !target.detail.is_empty() {
                    target.detail.push_str(" · ");
                }
                target.detail.push_str(&line);
                let start = target.start.line.saturating_sub(2) as usize;
                target.preview = text
                    .lines()
                    .enumerate()
                    .skip(start)
                    .take(9)
                    .map(|(i, line)| {
                        format!(
                            "{:>4} {}",
                            i + 1,
                            line.chars().take(180).collect::<String>()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
            }
        }
        Ok(Answer {
            targets: found,
            information: if query == Query::Hover {
                hover_text(&result)
            } else {
                String::new()
            },
            server: client.name.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_counts_utf8_bytes_and_handles_multiple_messages() {
        let message = json!({"id":1,"result":"日本語🦀"});
        let mut bytes = Vec::new();
        write_message(&mut bytes, &message).unwrap();
        write_message(&mut bytes, &Value::Null).unwrap();
        let mut reader = std::io::Cursor::new(bytes);
        assert_eq!(read_message(&mut reader).unwrap(), message);
        assert_eq!(read_message(&mut reader).unwrap(), Value::Null);
        assert!(
            read_message(&mut std::io::Cursor::new(
                b"Content-Length: 999999999\r\n\r\n"
            ))
            .is_err()
        );
    }
    #[test]
    fn unicode_positions_roundtrip() {
        let text = "α🦀x\r\n日本語 value";
        for (byte, _) in text
            .char_indices()
            .chain(std::iter::once((text.len(), ' ')))
        {
            assert_eq!(byte_offset(text, position_at(text, byte)), byte);
        }
        assert_eq!(
            position_at(text, 6),
            Position {
                line: 0,
                character: 3
            }
        );
    }
    #[test]
    fn supports_location_links_and_hierarchical_symbols() {
        let selection = json!({"start":{"line":4,"character":3},"end":{"line":4,"character":7}});
        let target = json!({"targetUri":"file:///tmp/%E6%97%A5%20a.py","targetSelectionRange":selection,"targetRange":{"start":{"line":0,"character":0},"end":{"line":5,"character":0}}});
        let result = targets(&json!([target.clone(), target]));
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].start.line, 4);
        assert_eq!(result[0].path, PathBuf::from("/tmp/日 a.py"));
        assert!(targets(&json!({"uri":"https://example.com/code","range":selection})).is_empty());
        let result = symbols(
            &json!([{"name":"Outer","kind":5,"selectionRange":selection,"children":[{"name":"inner","kind":6,"selectionRange":selection}]}]),
            Path::new("/tmp/a.py"),
        );
        assert_eq!(result[1].name, "Outer › inner");
    }
}
