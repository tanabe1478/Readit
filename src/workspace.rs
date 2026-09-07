use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Component, Path, PathBuf},
    process::Command,
};

pub type Result<T> = std::result::Result<T, String>;
const MAX_BYTES: u64 = 256 * 1024;
const MAX_FILES: usize = 400;

#[derive(Clone, Debug)]
pub struct Document {
    pub path: String,
    pub disk: String,
    pub text: String,
    pub before: Option<String>,
}

impl Document {
    pub fn role(&self) -> &'static str {
        role(&self.path)
    }
    pub fn changed(&self) -> bool {
        self.before.as_ref().is_none_or(|b| b != &self.text)
    }
    pub fn dirty(&self) -> bool {
        self.disk != self.text
    }
    pub fn replace_line(&mut self, line: usize, value: &str) -> Result<()> {
        if value.contains(['\n', '\r']) {
            return Err("この試作では1行ずつ編集してください".into());
        }
        let mut lines: Vec<&str> = self.text.split_inclusive('\n').collect();
        if lines.is_empty() {
            lines.push("");
        }
        let old = lines.get(line).ok_or("行が見つかりません")?;
        let ending = if old.ends_with("\r\n") {
            "\r\n"
        } else if old.ends_with('\n') {
            "\n"
        } else {
            ""
        };
        let replacement = format!("{value}{ending}");
        lines[line] = &replacement;
        self.text = lines.concat();
        Ok(())
    }
}

pub fn role(path: &str) -> &'static str {
    let p = path.to_lowercase();
    if p.contains("test") || p.contains("spec.") {
        "検証"
    } else if p.ends_with(".md") {
        "背景"
    } else if p.contains("type") || p.contains("schema") || p.contains("contract") {
        "契約"
    } else if p.ends_with(".toml")
        || p.ends_with(".json")
        || p.ends_with(".yaml")
        || p.ends_with(".yml")
    {
        "設定"
    } else {
        "実装"
    }
}

fn order(path: &str) -> u8 {
    match role(path) {
        "背景" => 0,
        "契約" => 1,
        "実装" => 2,
        "検証" => 3,
        _ => 4,
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Note {
    pub path: String,
    pub line: usize,
    pub quote: String,
    pub text: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Session {
    // Store exact content, so a changed file never inherits a reviewed badge.
    pub reviewed: BTreeMap<String, String>,
    pub notes: Vec<Note>,
}

pub struct Workspace {
    pub root: PathBuf,
    pub documents: Vec<Document>,
    pub session: Session,
    pub warnings: Vec<String>,
    pub git: bool,
}

fn git_output(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn safe_path(root: &Path, relative: &str) -> Result<PathBuf> {
    let rel = Path::new(relative);
    if rel.as_os_str().is_empty() || rel.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err("リポジトリ内の相対パスが必要です".into());
    }
    let path = root.join(rel);
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("{relative}: {e}"))?;
    if !canonical.starts_with(root) {
        return Err(format!("外部へのリンクを除外: {relative}"));
    }
    let mut current = root.to_path_buf();
    for component in rel.components() {
        current.push(component);
        if fs::symlink_metadata(&current)
            .map_err(|e| e.to_string())?
            .file_type()
            .is_symlink()
        {
            return Err(format!("シンボリックリンクを除外: {relative}"));
        }
    }
    Ok(path)
}

fn skipped(path: &Path) -> bool {
    path.components().any(|c| {
        let name = c.as_os_str().to_string_lossy();
        matches!(
            name.as_ref(),
            ".git"
                | ".readit"
                | "node_modules"
                | "target"
                | "dist"
                | "build"
                | ".venv"
                | "vendor"
                | "artifacts"
                | "__pycache__"
        ) || name.starts_with(".env")
    }) || matches!(
        path.file_name().and_then(|s| s.to_str()),
        Some("Cargo.lock" | "package-lock.json" | "pnpm-lock.yaml" | "yarn.lock")
    )
}

fn walk(
    root: &Path,
    at: &Path,
    paths: &mut Vec<String>,
    warnings: &mut Vec<String>,
    depth: usize,
) -> Result<()> {
    if depth > 12 || paths.len() >= MAX_FILES {
        return Ok(());
    }
    let mut entries: Vec<_> = fs::read_dir(at)
        .map_err(|e| e.to_string())?
        .collect::<std::io::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let path = entry.path();
        let rel = path.strip_prefix(root).map_err(|e| e.to_string())?;
        if skipped(rel) {
            continue;
        }
        let ty = entry.file_type().map_err(|e| e.to_string())?;
        if ty.is_symlink() {
            warnings.push(format!("リンクを除外: {}", rel.display()));
            continue;
        }
        if ty.is_dir() {
            walk(root, &path, paths, warnings, depth + 1)?;
        } else if ty.is_file() {
            paths.push(rel.to_string_lossy().into_owned());
        }
        if paths.len() >= MAX_FILES {
            warnings.push("最大400ファイルまで読み込みました".into());
            break;
        }
    }
    Ok(())
}

impl Workspace {
    pub fn index_of(&self, path: &str) -> Option<usize> {
        self.documents.iter().position(|d| d.path == path)
    }

    fn destination(&self, relative: &str) -> Result<PathBuf> {
        let path = Path::new(relative);
        if relative.trim().is_empty()
            || path
                .components()
                .any(|p| !matches!(p, Component::Normal(_)))
            || path
                .components()
                .next()
                .is_some_and(|p| matches!(p.as_os_str().to_str(), Some(".git" | ".readit")))
        {
            return Err(
                "プロジェクト内の相対パスを指定してください（.git/.readitは予約領域です）".into(),
            );
        }
        let parent = path.parent().unwrap_or(Path::new(""));
        if !parent.as_os_str().is_empty() {
            safe_path(&self.root, &parent.to_string_lossy())?;
        }
        let full = self.root.join(path);
        if fs::symlink_metadata(&full).is_ok() {
            return Err("同じ名前のファイルまたはフォルダが存在します".into());
        }
        Ok(full)
    }

    pub fn create_file(&mut self, relative: &str, text: &str) -> Result<()> {
        use std::io::Write;
        let path = self.destination(relative)?;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        self.documents.push(Document {
            path: relative.into(),
            disk: text.into(),
            text: text.into(),
            before: if self.git { None } else { Some(text.into()) },
        });
        Ok(())
    }

    pub fn create_directory(&self, relative: &str) -> Result<()> {
        fs::create_dir(self.destination(relative)?).map_err(|e| e.to_string())
    }

    pub fn rename_file(&mut self, from: &str, to: &str) -> Result<()> {
        let src = safe_path(&self.root, from)?;
        if matches!(from.split('/').next(), Some(".git" | ".readit")) {
            return Err("予約領域は変更できません".into());
        }
        let dest = self.destination(to)?;
        if to.starts_with(&format!("{from}/")) {
            return Err("フォルダを自身の中に移動できません".into());
        }
        if src.is_dir() {
            fs::rename(&src, &dest).map_err(|e| e.to_string())?;
        } else {
            // Link first so an existing destination can never be overwritten.
            fs::hard_link(&src, &dest).map_err(|e| e.to_string())?;
            if let Err(error) = fs::remove_file(src) {
                let _ = fs::remove_file(dest);
                return Err(error.to_string());
            }
        }
        let remap = |p: &str| -> String {
            if p == from {
                to.into()
            } else if let Some(suffix) = p.strip_prefix(&format!("{from}/")) {
                format!("{to}/{suffix}")
            } else {
                p.into()
            }
        };
        for doc in &mut self.documents {
            doc.path = remap(&doc.path);
        }
        for note in &mut self.session.notes {
            note.path = remap(&note.path);
        }
        self.session.reviewed = std::mem::take(&mut self.session.reviewed)
            .into_iter()
            .map(|(p, v)| (remap(&p), v))
            .collect();
        if let Err(e) = self.persist() {
            self.warnings.push(format!("名前変更後の記録保存: {e}"));
        }
        Ok(())
    }

    pub fn delete_file(&mut self, relative: &str) -> Result<()> {
        if matches!(relative.split('/').next(), Some(".git" | ".readit")) {
            return Err("予約領域は削除できません".into());
        }
        let src = safe_path(&self.root, relative)?;
        for doc in self
            .documents
            .iter()
            .filter(|d| d.path == relative || d.path.starts_with(&format!("{relative}/")))
        {
            if doc.dirty() {
                return Err("未保存の変更があります。先に保存してください".into());
            }
            if fs::read(safe_path(&self.root, &doc.path)?).map_err(|e| e.to_string())?
                != doc.disk.as_bytes()
            {
                return Err(format!(
                    "外部で変更されています。再読込後に削除してください: {}",
                    doc.path
                ));
            }
        }
        self.persist()?;
        let trash = self.root.join(".readit/trash");
        if !trash.exists() {
            fs::create_dir(&trash).map_err(|e| e.to_string())?;
        }
        safe_path(&self.root, ".readit/trash")?;
        let id = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        let dir = trash.join(format!("{id:030}"));
        fs::create_dir(&dir).map_err(|e| e.to_string())?;
        fs::write(dir.join("path.json"), serde_json::to_vec(relative).unwrap())
            .map_err(|e| e.to_string())?;
        fs::rename(src, dir.join("content")).map_err(|e| e.to_string())?;
        self.documents
            .retain(|d| d.path != relative && !d.path.starts_with(&format!("{relative}/")));
        Ok(())
    }

    pub fn restore_last_deleted(&mut self) -> Result<String> {
        let trash = safe_path(&self.root, ".readit/trash")?;
        let mut items = fs::read_dir(trash)
            .map_err(|e| e.to_string())?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .collect::<Vec<_>>();
        items.sort();
        for item in items.into_iter().rev() {
            let relative_item = item
                .strip_prefix(&self.root)
                .map_err(|e| e.to_string())?
                .to_string_lossy();
            let source = match safe_path(&self.root, &format!("{relative_item}/content")) {
                Ok(p) => p,
                Err(_) => continue,
            };
            let meta = safe_path(&self.root, &format!("{relative_item}/path.json"))?;
            let path: String = serde_json::from_slice(&fs::read(meta).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            let dest = self.destination(&path)?;
            if source.is_dir() {
                fs::rename(&source, &dest).map_err(|e| e.to_string())?;
                let mut paths = Vec::new();
                walk(&self.root, &dest, &mut paths, &mut self.warnings, 0)?;
                for p in paths {
                    if let Err(e) = self.add_existing(&p) {
                        self.warnings.push(e);
                    }
                }
            } else {
                fs::hard_link(&source, &dest).map_err(|e| e.to_string())?;
                if let Err(e) = fs::remove_file(source) {
                    let _ = fs::remove_file(dest);
                    return Err(e.to_string());
                }
                self.add_existing(&path)?;
            }
            return Ok(path);
        }
        Err("復元できるファイルがありません".into())
    }

    pub fn add_existing(&mut self, relative: &str) -> Result<()> {
        if self.index_of(relative).is_some() {
            return Ok(());
        }
        let path = safe_path(&self.root, relative)?;
        if fs::metadata(&path).map_err(|e| e.to_string())?.len() > MAX_BYTES {
            return Err("ファイルが大きすぎます（上限256KiB）".into());
        }
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
        if text.contains('\0') {
            return Err("バイナリファイルは編集できません".into());
        }
        let before = if self.git {
            git_output(&self.root, &["show", &format!("HEAD:{relative}")])
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
        } else {
            Some(text.clone())
        };
        self.documents.push(Document {
            path: relative.into(),
            disk: text.clone(),
            text,
            before,
        });
        Ok(())
    }

    pub fn directories(&self) -> Vec<String> {
        fn visit(root: &Path, at: &Path, depth: usize, out: &mut Vec<String>) {
            if depth > 12 || out.len() >= 2000 {
                return;
            }
            let Ok(entries) = fs::read_dir(at) else {
                return;
            };
            for e in entries.flatten() {
                let path = e.path();
                let Ok(rel) = path.strip_prefix(root) else {
                    continue;
                };
                if skipped(rel) || !e.file_type().is_ok_and(|t| t.is_dir()) {
                    continue;
                }
                out.push(rel.to_string_lossy().into_owned());
                visit(root, &path, depth + 1, out);
            }
        }
        let mut out = Vec::new();
        visit(&self.root, &self.root, 0, &mut out);
        out
    }

    pub fn load(root: &Path) -> Result<Self> {
        let root = root.canonicalize().map_err(|e| e.to_string())?;
        if !root.is_dir() {
            return Err("フォルダを指定してください".into());
        }
        let mut warnings = Vec::new();
        let git_root = git_output(&root, &["rev-parse", "--show-toplevel"])
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .map(|s| PathBuf::from(s.trim()));
        let git = git_root.as_ref().is_some_and(|p| p == &root);
        if git_root.is_some() && !git {
            warnings.push("Git差分はリポジトリのルートを指定した場合のみ表示します".into());
        }
        let mut paths = if git {
            let bytes = git_output(
                &root,
                &[
                    "ls-files",
                    "-z",
                    "--cached",
                    "--others",
                    "--exclude-standard",
                ],
            )?;
            bytes
                .split(|b| *b == 0)
                .filter(|s| !s.is_empty())
                .filter_map(|s| match String::from_utf8(s.to_vec()) {
                    Ok(path) => Some(path),
                    Err(_) => {
                        warnings.push("UTF-8でないファイル名を除外".into());
                        None
                    }
                })
                .collect::<Vec<_>>()
        } else {
            let mut paths = Vec::new();
            walk(&root, &root, &mut paths, &mut warnings, 0)?;
            paths
        };
        paths.retain(|p| !skipped(Path::new(p)));
        paths.sort();
        paths.dedup();
        paths.sort_by_key(|p| (order(p), p.clone()));
        if paths.len() > MAX_FILES {
            warnings.push(format!("{}ファイル中、先頭400件を表示", paths.len()));
            paths.truncate(MAX_FILES);
        }
        let has_head = git && git_output(&root, &["rev-parse", "--verify", "HEAD"]).is_ok();
        let mut documents = Vec::new();
        for relative in paths {
            // HEAD is the baseline; deleted paths are reported but not edited by this prototype.
            let before = if has_head {
                git_output(&root, &["show", &format!("HEAD:{relative}")])
                    .ok()
                    .filter(|b| b.len() <= MAX_BYTES as usize && !b.contains(&0))
                    .and_then(|b| String::from_utf8(b).ok())
            } else {
                None
            };
            if !root.join(&relative).exists() {
                if before.is_some() {
                    warnings.push(format!("削除済み（この試作では閲覧対象外）: {relative}"));
                }
                continue;
            }
            let path = match safe_path(&root, &relative) {
                Ok(p) => p,
                Err(e) => {
                    warnings.push(e);
                    continue;
                }
            };
            let metadata = fs::metadata(&path).map_err(|e| e.to_string())?;
            if !metadata.is_file() {
                continue;
            }
            if metadata.len() > MAX_BYTES {
                warnings.push(format!("256KiB超を除外: {relative}"));
                continue;
            }
            let bytes = fs::read(path).map_err(|e| e.to_string())?;
            if bytes.contains(&0) {
                warnings.push(format!("バイナリを除外: {relative}"));
                continue;
            }
            let text = match String::from_utf8(bytes) {
                Ok(s) => s,
                Err(_) => {
                    warnings.push(format!("UTF-8以外を除外: {relative}"));
                    continue;
                }
            };
            let before = if git { before } else { Some(text.clone()) };
            documents.push(Document {
                path: relative,
                disk: text.clone(),
                text,
                before,
            });
        }
        let session_path = root.join(".readit/session.json");
        let session = if session_path.exists() {
            match safe_path(&root, ".readit/session.json").and_then(|p| {
                let data = fs::read(p).map_err(|e| e.to_string())?;
                serde_json::from_slice(&data).map_err(|e| e.to_string())
            }) {
                Ok(s) => s,
                Err(e) => {
                    warnings.push(format!("記録を読み込めません: {e}"));
                    Session::default()
                }
            }
        } else {
            Session::default()
        };
        Ok(Self {
            root,
            documents,
            session,
            warnings,
            git,
        })
    }

    pub fn reviewed(&self, index: usize) -> bool {
        let doc = &self.documents[index];
        self.session.reviewed.get(&doc.path) == Some(&doc.text)
    }

    pub fn persist(&self) -> Result<()> {
        let dir = self.root.join(".readit");
        if !dir.exists() {
            fs::create_dir(&dir).map_err(|e| e.to_string())?;
        }
        safe_path(&self.root, ".readit")?;
        let target = dir.join("session.json");
        if target.exists() {
            safe_path(&self.root, ".readit/session.json")?;
        }
        let data = serde_json::to_vec_pretty(&self.session).map_err(|e| e.to_string())?;
        atomic_replace(&target, &data)
    }

    pub fn save(&mut self, index: usize) -> Result<()> {
        let doc = self
            .documents
            .get(index)
            .ok_or("ファイルが見つかりません")?;
        let path = safe_path(&self.root, &doc.path)?;
        if fs::read(&path).map_err(|e| e.to_string())? != doc.disk.as_bytes() {
            return Err("外部でファイルが変更されました。上書きせず、再読込してください".into());
        }
        atomic_replace(&path, doc.text.as_bytes())?;
        self.documents[index].disk = self.documents[index].text.clone();
        Ok(())
    }

    pub fn references(&self, token: &str) -> Vec<(usize, usize, String)> {
        if token.chars().count() < 2 {
            return Vec::new();
        }
        self.documents
            .iter()
            .enumerate()
            .flat_map(|(index, doc)| {
                doc.text
                    .lines()
                    .enumerate()
                    .filter_map(move |(line, text)| {
                        text.split(|c: char| !c.is_alphanumeric() && c != '_')
                            .any(|word| word == token)
                            .then(|| (index, line, text.trim().to_owned()))
                    })
            })
            .take(60)
            .collect()
    }
}

fn atomic_replace(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let tmp = path.with_file_name(format!(".readit-{}-{nonce}.tmp", std::process::id()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        if let Ok(meta) = fs::metadata(path) {
            file.set_permissions(meta.permissions())
                .map_err(|e| e.to_string())?;
        }
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&tmp, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp() -> PathBuf {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let p = std::env::temp_dir().join(format!(
            "readit-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&p).unwrap();
        p
    }
    #[test]
    fn file_lifecycle_keeps_unsaved_edits_and_notes_without_overwriting() {
        let root = temp();
        let mut ws = Workspace::load(&root).unwrap();
        ws.create_directory("日本語").unwrap();
        ws.create_file("日本語/a.rs", "original\n").unwrap();
        ws.create_file("taken.rs", "keep").unwrap();
        assert!(ws.create_file("taken.rs", "replace").is_err());
        assert!(ws.create_file("../escape.rs", "x").is_err());
        assert!(ws.create_directory(".readit").is_err());
        ws.documents[0].text = "edited\n".into();
        ws.session.notes.push(Note {
            path: "日本語/a.rs".into(),
            line: 1,
            quote: "original".into(),
            text: "question".into(),
        });
        assert!(ws.rename_file("日本語/a.rs", "taken.rs").is_err());
        ws.rename_file("日本語/a.rs", "日本語/b.rs").unwrap();
        assert_eq!(ws.documents[0].text, "edited\n");
        assert_eq!(ws.session.notes[0].path, "日本語/b.rs");
        assert!(!root.join("日本語/a.rs").exists());
        assert!(ws.delete_file("日本語/b.rs").is_err());
        ws.save(0).unwrap();
        ws.delete_file("日本語/b.rs").unwrap();
        assert!(!root.join("日本語/b.rs").exists());
        ws.create_file("日本語/b.rs", "do not clobber").unwrap();
        assert!(ws.restore_last_deleted().is_err());
        assert_eq!(
            fs::read_to_string(root.join("日本語/b.rs")).unwrap(),
            "do not clobber"
        );
        ws.rename_file("日本語/b.rs", "日本語/c.rs").unwrap();
        assert_eq!(ws.restore_last_deleted().unwrap(), "日本語/b.rs");
        assert_eq!(
            fs::read_to_string(root.join("日本語/b.rs")).unwrap(),
            "edited\n"
        );
        assert_eq!(fs::read_to_string(root.join("taken.rs")).unwrap(), "keep");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn directory_lifecycle_preserves_children_and_refuses_external_changes() {
        let root = temp();
        let mut ws = Workspace::load(&root).unwrap();
        ws.create_directory("src").unwrap();
        ws.create_directory("src/empty").unwrap();
        ws.create_file("src/a.rs", "before").unwrap();
        ws.create_file("src-other.rs", "other").unwrap();
        assert!(ws.rename_file("src", "src/child").is_err());
        ws.rename_file("src", "lib").unwrap();
        assert_eq!(ws.documents[0].path, "lib/a.rs");
        assert_eq!(ws.documents[1].path, "src-other.rs");
        assert!(ws.directories().contains(&"lib/empty".into()));
        fs::write(root.join("lib/a.rs"), "external").unwrap();
        assert!(ws.delete_file("lib").is_err());
        fs::write(root.join("lib/a.rs"), "before").unwrap();
        fs::write(root.join("lib/binary.bin"), b"a\0b").unwrap();
        ws.delete_file("lib").unwrap();
        assert_eq!(ws.documents.len(), 1);
        assert_eq!(ws.restore_last_deleted().unwrap(), "lib");
        assert_eq!(fs::read(root.join("lib/binary.bin")).unwrap(), b"a\0b");
        assert!(root.join("lib/empty").is_dir());
        assert!(ws.index_of("lib/a.rs").is_some());
        assert!(ws.index_of("src-other.rs").is_some());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn line_edits_preserve_unicode_endings_and_missing_final_newline() {
        let mut d = Document {
            path: "a".into(),
            disk: "".into(),
            text: "日本語\r\nnext".into(),
            before: None,
        };
        d.replace_line(0, "🦀").unwrap();
        assert_eq!(d.text, "🦀\r\nnext");
        d.replace_line(1, "最後").unwrap();
        assert_eq!(d.text, "🦀\r\n最後");
        assert!(d.replace_line(2, "x").is_err());
        assert!(d.replace_line(0, "a\nb").is_err());
    }
    #[test]
    fn refuses_external_changes_and_invalidates_review() {
        let root = temp();
        fs::write(root.join("a.rs"), "original\n").unwrap();
        let mut ws = Workspace::load(&root).unwrap();
        ws.session
            .reviewed
            .insert("a.rs".into(), "original\n".into());
        assert!(ws.reviewed(0));
        ws.documents[0].replace_line(0, "edited").unwrap();
        assert!(!ws.reviewed(0));
        fs::write(root.join("a.rs"), "external\n").unwrap();
        assert!(ws.save(0).is_err());
        assert_eq!(fs::read_to_string(root.join("a.rs")).unwrap(), "external\n");
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn sessions_survive_reload_and_references_match_tokens() {
        let root = temp();
        fs::write(root.join("a.rs"), "fn read() {}\nfn reader() {}\n").unwrap();
        let mut ws = Workspace::load(&root).unwrap();
        assert_eq!(ws.references("read").len(), 1);
        ws.session.notes.push(Note {
            path: "a.rs".into(),
            line: 1,
            quote: "fn read() {}".into(),
            text: "なぜ？".into(),
        });
        ws.persist().unwrap();
        let loaded = Workspace::load(&root).unwrap();
        assert_eq!(loaded.session.notes[0].text, "なぜ？");
        assert_eq!(loaded.documents.len(), 1);
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn git_baseline_includes_staged_and_unstaged_edits_and_can_save() {
        let root = temp();
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        git(&["init", "-q"]);
        fs::write(root.join("日本語 file.rs"), "before\n").unwrap();
        fs::write(root.join(".gitignore"), "ignored.rs\n").unwrap();
        git(&["add", "."]);
        git(&[
            "-c",
            "user.name=Readit Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "baseline",
        ]);
        fs::write(root.join("日本語 file.rs"), "staged\n").unwrap();
        git(&["add", "."]);
        fs::write(root.join("日本語 file.rs"), "working\n").unwrap();
        fs::write(root.join("ignored.rs"), "ignored").unwrap();
        fs::write(root.join("new.rs"), "new\n").unwrap();
        let mut ws = Workspace::load(&root).unwrap();
        assert!(ws.git);
        assert!(!ws.documents.iter().any(|d| d.path == "ignored.rs"));
        assert!(
            ws.documents
                .iter()
                .find(|d| d.path == "new.rs")
                .unwrap()
                .before
                .is_none()
        );
        let i = ws
            .documents
            .iter()
            .position(|d| d.path == "日本語 file.rs")
            .unwrap();
        assert_eq!(ws.documents[i].before.as_deref(), Some("before\n"));
        assert_eq!(ws.documents[i].text, "working\n");
        ws.documents[i].replace_line(0, "experiment").unwrap();
        ws.save(i).unwrap();
        assert_eq!(
            fs::read_to_string(root.join("日本語 file.rs")).unwrap(),
            "experiment\n"
        );
        assert!(!ws.documents[i].dirty());
        assert_eq!(
            git_output(&root, &["show", ":日本語 file.rs"]).unwrap(),
            b"staged\n"
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn excludes_symlinks_and_prevents_traversal() {
        let root = temp();
        let outside = temp();
        fs::write(outside.join("secret"), "secret").unwrap();
        std::os::unix::fs::symlink(outside.join("secret"), root.join("link")).unwrap();
        assert!(safe_path(&root, "../secret").is_err());
        assert!(Workspace::load(&root).unwrap().documents.is_empty());
        std::os::unix::fs::symlink(&outside, root.join(".readit")).unwrap();
        assert!(Workspace::load(&root).unwrap().persist().is_err());
        fs::remove_dir_all(root).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }
}
