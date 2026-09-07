use crate::commands::*;
use gpui::{prelude::*, *};
use gpui_component::input::{Input, InputEvent, InputState, Position};
use gpui_component::menu::ContextMenuExt;
use readit::{
    diff::{self, Kind, Row},
    language_service::{self as ls, Query, Service, Snapshot, Target},
    workspace::{Document, Note, Workspace},
};
use std::{
    cell::RefCell,
    collections::{BTreeSet, HashMap},
    path::PathBuf,
    rc::Rc,
    sync::{Arc, Mutex},
};

const BG: u32 = 0x10141b;
const PANEL: u32 = 0x171c25;
const BORDER: u32 = 0x293340;
const MUTED: u32 = 0x94a1b3;
const TEXT: u32 = 0xdce3ed;
const ACCENT: u32 = 0x9bd9bb;

struct Buffer {
    input: Entity<InputState>,
    path: Rc<RefCell<String>>,
    _subscriptions: Vec<Subscription>,
}
#[derive(Clone, PartialEq)]
enum Dialog {
    Quick,
    Commands,
    WorkspaceSearch,
    Goto,
    NewFolder,
    Rename,
    SaveAs,
    Replace,
    Help,
    Navigation,
    Information,
}
#[derive(Clone)]
enum Pending {
    Close(String),
    CloseAll,
    Quit,
    Switch(PathBuf, Option<String>),
    Reload,
    Delete(String),
}
#[derive(Clone)]
struct Location {
    path: String,
    line: u32,
    column: u32,
}
#[derive(Clone)]
struct Pick {
    label: String,
    detail: String,
    path: Option<String>,
    line: Option<usize>,
    command: Option<&'static str>,
    target: Option<usize>,
}

pub struct Reader {
    service: Arc<Mutex<Service>>,
    nav_serial: u64,
    nav_busy: bool,
    nav_visible: bool,
    nav_title: String,
    nav_targets: Vec<Target>,
    nav_information: String,
    nav_snapshot: Option<Snapshot>,
    external: BTreeSet<String>,
    pending_reveal: Option<(String, Position)>,
    workspace: Workspace,
    buffers: HashMap<String, Buffer>,
    tabs: Vec<String>,
    selected: Option<String>,
    untitled: BTreeSet<String>,
    closed: Vec<String>,
    focus: FocusHandle,
    explorer_focus: FocusHandle,
    note: Entity<InputState>,
    query: Entity<InputState>,
    replacement: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
    dialog: Option<Dialog>,
    pending: Option<Pending>,
    save_source: Option<String>,
    saving_all: bool,
    rename_source: Option<String>,
    pick_index: usize,
    pick_scroll: ScrollHandle,
    tree_scroll: ScrollHandle,
    tab_scroll: ScrollHandle,
    collapsed: BTreeSet<String>,
    directories: Vec<String>,
    tree_target: Option<String>,
    reading_path: bool,
    sidebar: bool,
    inspector: bool,
    wrap: bool,
    font_size: f32,
    compare: bool,
    diff_rows: Vec<Row>,
    diff_scroll: UniformListScrollHandle,
    message: String,
    history: Vec<Location>,
    history_index: usize,
}

fn button(id: &'static str, label: impl Into<SharedString>) -> Stateful<Div> {
    div()
        .id(id)
        .flex_shrink_0()
        .px_3()
        .py_2()
        .rounded_md()
        .border_1()
        .border_color(rgb(BORDER))
        .text_size(px(12.))
        .cursor_pointer()
        .hover(|s| s.bg(rgb(0x2b394a)))
        .child(label.into())
}
fn caption(text: impl Into<SharedString>) -> Div {
    div()
        .flex_shrink_0()
        .text_size(px(11.))
        .text_color(rgb(MUTED))
        .child(text.into())
}
fn language(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("");
    match ext {
        "rs" => "rust",
        "py" | "pyi" => "python",
        "js" | "mjs" | "cjs" | "jsx" => "javascript",
        "ts" | "mts" | "cts" => "typescript",
        "tsx" => "tsx",
        "json" | "jsonc" => "json",
        "md" => "markdown",
        "toml" => "toml",
        "yaml" | "yml" => "yaml",
        "html" | "htm" => "html",
        "css" => "css",
        "sh" | "bash" | "zsh" => "bash",
        "c" | "h" => "c",
        "cpp" | "hpp" | "cc" => "cpp",
        "go" => "go",
        "java" => "java",
        "rb" => "ruby",
        "swift" => "swift",
        "sql" => "sql",
        "cs" => "csharp",
        "ex" | "exs" => "elixir",
        "graphql" => "graphql",
        "proto" => "proto",
        "zig" => "zig",
        _ => "text",
    }
}
const COMMANDS: &[(&str, &str, &str)] = &[
    ("new", "新規ファイル", "⌘N"),
    ("folder", "新規フォルダ", ""),
    ("open", "ファイルを開く", "⌘O"),
    ("open-folder", "フォルダを開く", "⌘K ⌘O"),
    ("save", "保存", "⌘S"),
    ("save-all", "すべて保存", "⌥⌘S"),
    ("save-as", "名前を付けて保存", "⇧⌘S"),
    ("close", "タブを閉じる", "⌘W"),
    ("close-all", "すべてのタブを閉じる", "⌘K ⌘W"),
    ("reopen", "閉じたタブを開く", "⇧⌘T"),
    ("rename", "ファイルの名前を変更", "F2 / Explorer"),
    ("delete", "ファイルを削除（復元可能）", "⌘⌫ / Explorer"),
    ("restore", "削除したファイルを復元", "⇧⌘⌫ / Explorer"),
    ("find", "ファイル内検索", "⌘F"),
    ("replace", "ファイル内置換", "⌥⌘F"),
    ("find-all", "プロジェクト内検索", "⇧⌘F"),
    ("goto", "行へ移動", "⌃G"),
    ("definition", "定義へ移動", "F12 / ⌘クリック"),
    ("peek-definition", "定義を確認", "⌥F12"),
    ("type-definition", "型定義へ移動", "⌘F12"),
    ("implementation", "実装へ移動", "⇧⌘F12"),
    ("references", "使用箇所を検索", "⇧F12"),
    ("symbols", "ファイル内のシンボルへ移動", "⇧⌘O"),
    ("hover", "型とドキュメントを表示", "⌘K ⌘I"),
    ("wrap", "折返し切替", "⌥Z"),
    ("sidebar", "ファイルツリー表示切替", "⌘B"),
    ("inspector", "理解メモ表示切替", "⌥⌘B"),
    ("compare", "変更前と比較", "⌥⌘D"),
    ("reload", "ディスクから再読込", "⌘R"),
    ("reveal", "Finderで表示", ""),
    ("help", "ショートカット一覧", ""),
];

impl Reader {
    pub fn new(
        workspace: Workspace,
        _demo: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let initial = workspace.documents.first().map(|d| d.path.clone());
        let directories = workspace.directories();
        let query = cx.new(|cx| InputState::new(window, cx).placeholder("入力…"));
        let note = cx.new(|cx| InputState::new(window, cx).placeholder("選択したコードへの疑問…"));
        let replacement = cx.new(|cx| InputState::new(window, cx).placeholder("置換後の文字列"));
        let subscriptions = vec![cx.subscribe(&query, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.pick_index = 0;
                cx.notify();
            }
        })];
        let mut this = Self {
            service: Arc::new(Mutex::new(Service::default())),
            nav_serial: 0,
            nav_busy: false,
            nav_visible: false,
            nav_title: String::new(),
            nav_targets: Vec::new(),
            nav_information: String::new(),
            nav_snapshot: None,
            external: BTreeSet::new(),
            pending_reveal: None,
            workspace,
            directories,
            buffers: HashMap::new(),
            tabs: vec![],
            selected: None,
            untitled: BTreeSet::new(),
            closed: vec![],
            focus: cx.focus_handle(),
            explorer_focus: cx.focus_handle(),
            query,
            note,
            replacement,
            _subscriptions: subscriptions,
            dialog: None,
            pending: None,
            save_source: None,
            saving_all: false,
            rename_source: None,
            pick_index: 0,
            pick_scroll: ScrollHandle::new(),
            tree_scroll: ScrollHandle::new(),
            tab_scroll: ScrollHandle::new(),
            collapsed: BTreeSet::new(),
            tree_target: None,
            reading_path: false,
            sidebar: true,
            inspector: true,
            wrap: false,
            font_size: 14.,
            compare: false,
            diff_rows: vec![],
            diff_scroll: UniformListScrollHandle::new(),
            message: "⌘P ファイルを開く · ⌘S 保存 · ⇧⌘P コマンド".into(),
            history: vec![],
            history_index: 0,
        };
        if let Some(path) = initial {
            this.open(&path, None, true, window, cx);
        } else {
            this.focus.focus(window);
        }
        this
    }
    fn index(&self) -> Option<usize> {
        self.selected
            .as_deref()
            .and_then(|p| self.workspace.index_of(p))
    }
    fn editor(&self) -> Option<Entity<InputState>> {
        self.selected
            .as_ref()
            .and_then(|p| self.buffers.get(p))
            .map(|b| b.input.clone())
    }
    fn dirty(&self, path: &str) -> bool {
        self.untitled.contains(path)
            || self
                .workspace
                .index_of(path)
                .is_some_and(|i| self.workspace.documents[i].dirty())
    }
    fn position(&self, cx: &App) -> Position {
        self.editor()
            .map(|e| e.read(cx).cursor_position())
            .unwrap_or(Position::new(0, 0))
    }
    fn sync_buffers(&mut self, cx: &App) {
        for (path, buffer) in &self.buffers {
            if let Some(i) = self.workspace.index_of(path) {
                self.workspace.documents[i].text = buffer.input.read(cx).value().to_string();
            }
        }
    }
    fn rebuild_diff(&mut self) {
        self.diff_rows = self
            .index()
            .map(|i| {
                let doc = &self.workspace.documents[i];
                diff::rows(doc.before.as_deref().unwrap_or(""), &doc.text, true)
            })
            .unwrap_or_default();
    }
    fn open(
        &mut self,
        path: &str,
        line: Option<usize>,
        record: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self.workspace.index_of(path) else {
            self.message = "ファイルが見つかりません".into();
            return;
        };
        if record && let Some(current) = self.selected.clone() {
            let pos = self.position(cx);
            if let Some(last) = self.history.get_mut(self.history_index) {
                if last.path == current {
                    last.line = pos.line;
                    last.column = pos.character;
                }
            }
        }
        if !self.buffers.contains_key(path) {
            let text = self.workspace.documents[index].text.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .code_editor(language(path))
                    .searchable(true)
                    .soft_wrap(self.wrap)
                    .default_value(text)
            });
            let token = Rc::new(RefCell::new(path.to_string()));
            let event_token = token.clone();
            let change = cx.subscribe(&input, move |this, input, event, cx| {
                if matches!(event, InputEvent::Change) {
                    if let Some(i) = this.workspace.index_of(&event_token.borrow()) {
                        this.workspace.documents[i].text = input.read(cx).value().to_string();
                    }
                    if this.compare {
                        this.rebuild_diff();
                    }
                    cx.notify();
                }
            });
            let selection = cx.observe(&input, |_, _, cx| cx.notify());
            self.buffers.insert(
                path.into(),
                Buffer {
                    input,
                    path: token,
                    _subscriptions: vec![change, selection],
                },
            );
        }
        if !self.tabs.iter().any(|p| p == path) {
            self.tabs.push(path.into());
        }
        self.tab_scroll
            .scroll_to_item(self.tabs.iter().position(|p| p == path).unwrap_or(0));
        self.selected = Some(path.into());
        self.tree_target = Some(path.into());
        self.compare = false;
        if let Some(editor) = self.editor() {
            editor.update(cx, |input, cx| {
                if let Some(line) = line {
                    input.set_cursor_position(
                        Position::new(
                            line.min(input.value().lines().count().saturating_sub(1)) as u32,
                            0,
                        ),
                        window,
                        cx,
                    );
                }
                input.focus(window, cx);
            });
        }
        if line.is_some() {
            self.pending_reveal = Some((path.to_string(), self.position(cx)));
        }
        if record {
            self.history.truncate(self.history_index + 1);
            if self
                .history
                .last()
                .is_none_or(|last| last.path != path || Some(last.line as usize) != line)
            {
                let pos = self.position(cx);
                self.history.push(Location {
                    path: path.into(),
                    line: pos.line,
                    column: pos.character,
                });
            }
            self.history_index = self.history.len().saturating_sub(1);
        }
        cx.notify();
    }
    fn show(&mut self, dialog: Dialog, initial: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.query.update(cx, |input, cx| {
            input.set_value(initial.to_string(), window, cx);
            input.focus(window, cx);
        });
        if matches!(dialog, Dialog::Information | Dialog::Help) {
            self.focus.focus(window);
        }
        self.dialog = Some(dialog);
        self.pick_index = 0;
        self.pick_scroll.set_offset(point(px(0.), px(0.)));
        cx.notify();
    }
    fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.nav_busy {
            self.nav_serial += 1;
            self.nav_busy = false;
            self.nav_information = "解析の表示をキャンセルしました".into();
        }
        self.dialog = None;
        self.pending = None;
        self.save_source = None;
        self.saving_all = false;
        self.rename_source = None;
        if let Some(editor) = self.editor() {
            editor.update(cx, |input, cx| input.focus(window, cx));
        } else {
            self.focus.focus(window);
        }
        cx.notify();
    }
    fn new_file(&mut self, _: &NewFile, window: &mut Window, cx: &mut Context<Self>) {
        let mut n = 1;
        while self.workspace.index_of(&format!("Untitled-{n}")).is_some() {
            n += 1;
        }
        let path = format!("Untitled-{n}");
        self.workspace.documents.push(Document {
            path: path.clone(),
            text: String::new(),
            disk: String::new(),
            before: None,
        });
        self.untitled.insert(path.clone());
        self.open(&path, None, true, window, cx);
    }
    fn save_path(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.sync_buffers(cx);
        if self.external.contains(path) {
            self.message =
                "外部定義は閲覧専用です。名前を付けて保存するとプロジェクト内にコピーできます"
                    .into();
            cx.notify();
            return false;
        }
        if self.untitled.contains(path) {
            self.save_source = Some(path.into());
            self.show(Dialog::SaveAs, "", window, cx);
            return false;
        }
        let Some(index) = self.workspace.index_of(path) else {
            return false;
        };
        match self.workspace.save(index) {
            Ok(()) => {
                self.message = format!("保存しました · {path}");
                cx.notify();
                true
            }
            Err(error) => {
                self.message = format!("保存できません: {error}");
                cx.notify();
                false
            }
        }
    }
    fn save(&mut self, _: &Save, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(path) = self.selected.clone() {
            self.save_path(&path, window, cx);
        }
    }
    fn save_all(&mut self, _: &SaveAll, window: &mut Window, cx: &mut Context<Self>) {
        self.saving_all = true;
        for path in self.tabs.clone() {
            if self.dirty(&path) && !self.save_path(&path, window, cx) {
                return;
            }
        }
        self.saving_all = false;
        self.message = "すべてのファイルを保存しました".into();
        cx.notify();
    }
    fn save_as(&mut self, _: &SaveAs, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(path) = self.selected.clone() {
            self.save_source = Some(path.clone());
            self.show(
                Dialog::SaveAs,
                if self.untitled.contains(&path) {
                    ""
                } else {
                    &path
                },
                window,
                cx,
            );
        }
    }
    fn affected(&self, pending: &Pending) -> Vec<String> {
        match pending {
            Pending::Close(p) => vec![p.clone()],
            Pending::Delete(p) => self
                .workspace
                .documents
                .iter()
                .filter(|d| d.path == *p || d.path.starts_with(&format!("{p}/")))
                .map(|d| d.path.clone())
                .collect(),
            _ => self
                .workspace
                .documents
                .iter()
                .filter(|d| self.dirty(&d.path))
                .map(|d| d.path.clone())
                .collect(),
        }
    }
    fn begin(&mut self, pending: Pending, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_buffers(cx);
        let confirm = matches!(pending, Pending::Delete(_))
            || self.affected(&pending).iter().any(|p| self.dirty(p));
        self.pending = Some(pending);
        self.dialog = None;
        if confirm {
            self.focus.focus(window);
            cx.notify();
        } else {
            self.finish_pending(window, cx);
        }
    }
    fn resolve_pending(&mut self, save: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pending) = self.pending.clone() else {
            return;
        };
        if save {
            for path in self.affected(&pending) {
                if self.dirty(&path) && !self.save_path(&path, window, cx) {
                    return;
                }
            }
        } else {
            for path in self.affected(&pending) {
                if let Some(i) = self.workspace.index_of(&path) {
                    let original = self.workspace.documents[i].disk.clone();
                    self.workspace.documents[i].text = original.clone();
                    if let Some(buffer) = self.buffers.get(&path) {
                        buffer
                            .input
                            .update(cx, |input, cx| input.set_value(original, window, cx));
                    }
                }
            }
        }
        self.finish_pending(window, cx);
    }
    fn close_now(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let pos = self.tabs.iter().position(|p| p == path).unwrap_or(0);
        self.tabs.retain(|p| p != path);
        self.buffers.remove(path);
        if self.untitled.remove(path) {
            if let Some(i) = self.workspace.index_of(path) {
                self.workspace.documents.remove(i);
            }
        } else {
            self.closed.push(path.into());
        }
        if self.selected.as_deref() == Some(path) {
            self.selected = None;
            if let Some(next) = self
                .tabs
                .get(pos.min(self.tabs.len().saturating_sub(1)))
                .cloned()
            {
                self.open(&next, None, false, window, cx);
            } else {
                self.focus.focus(window);
                self.compare = false;
            }
        }
        cx.notify();
    }
    fn finish_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        match pending {
            Pending::Close(path) => self.close_now(&path, window, cx),
            Pending::CloseAll => {
                for path in self.tabs.clone() {
                    self.close_now(&path, window, cx);
                }
            }
            Pending::Quit => cx.quit(),
            Pending::Delete(path) => match self.workspace.delete_file(&path) {
                Ok(()) => {
                    for tab in self.tabs.clone() {
                        if tab == path || tab.starts_with(&format!("{path}/")) {
                            self.close_now(&tab, window, cx);
                        }
                    }
                    self.tree_target = None;
                    self.directories = self.workspace.directories();
                    self.message =
                        "削除しました。メニューの「削除したファイルを復元」で戻せます".into();
                }
                Err(e) => self.message = e,
            },
            Pending::Switch(root, file) => self.load_workspace(root, file, window, cx),
            Pending::Reload => {
                let tabs = self.tabs.clone();
                let selected = self.selected.clone();
                let positions: HashMap<_, _> = self
                    .buffers
                    .iter()
                    .map(|(p, b)| (p.clone(), b.input.read(cx).cursor_position()))
                    .collect();
                self.load_workspace(self.workspace.root.clone(), None, window, cx);
                for path in self.tabs.clone() {
                    self.close_now(&path, window, cx);
                }
                self.closed.clear();
                for path in tabs {
                    if self.workspace.index_of(&path).is_some() {
                        self.open(&path, None, false, window, cx);
                        if let Some(pos) = positions.get(&path) {
                            if let Some(editor) = self.editor() {
                                editor.update(cx, |input, cx| {
                                    let line =
                                        pos.line
                                            .min(input.value().lines().count().saturating_sub(1)
                                                as u32);
                                    input.set_cursor_position(
                                        Position::new(line, pos.character),
                                        window,
                                        cx,
                                    );
                                });
                            }
                        }
                    }
                }
                if let Some(path) = selected {
                    if self.workspace.index_of(&path).is_some() {
                        self.open(&path, None, true, window, cx);
                    }
                }
            }
        }
        cx.notify();
    }
    fn load_workspace(
        &mut self,
        root: PathBuf,
        file: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match Workspace::load(&root) {
            Ok(mut workspace) => {
                if let Some(path) = &file {
                    if let Err(e) = workspace.add_existing(path) {
                        self.message = e;
                        return;
                    }
                }
                let first = file.or_else(|| workspace.documents.first().map(|d| d.path.clone()));
                self.nav_serial += 1;
                self.nav_busy = false;
                self.nav_visible = false;
                self.nav_targets.clear();
                self.nav_snapshot = None;
                self.external.clear();
                self.service = Arc::new(Mutex::new(Service::default()));
                self.workspace = workspace;
                self.directories = self.workspace.directories();
                self.buffers.clear();
                self.tabs.clear();
                self.selected = None;
                self.untitled.clear();
                self.closed.clear();
                self.history.clear();
                self.history_index = 0;
                self.collapsed.clear();
                self.tree_target = None;
                self.compare = false;
                if let Some(path) = first {
                    self.open(&path, None, true, window, cx);
                }
                self.message = format!(
                    "{} · {}件のファイル",
                    self.workspace.root.display(),
                    self.workspace.documents.len()
                );
            }
            Err(e) => self.message = e,
        }
    }
    fn pick_path(&mut self, folder: bool, window: &mut Window, cx: &mut Context<Self>) {
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: !folder,
            directories: folder,
            multiple: false,
            prompt: Some(
                if folder {
                    "フォルダを開く"
                } else {
                    "ファイルを開く"
                }
                .into(),
            ),
        });
        cx.spawn_in(window, async move |this, cx| {
            let result = receiver.await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(Ok(Some(paths))) if !paths.is_empty() => {
                    let path = match paths[0].canonicalize() {
                        Ok(p) => p,
                        Err(e) => {
                            this.message = e.to_string();
                            cx.notify();
                            return;
                        }
                    };
                    if folder {
                        this.begin(Pending::Switch(path, None), window, cx);
                    } else if let Ok(relative) = path.strip_prefix(&this.workspace.root) {
                        let relative = relative.to_string_lossy().into_owned();
                        match this.workspace.add_existing(&relative) {
                            Ok(()) => this.open(&relative, None, true, window, cx),
                            Err(e) => {
                                this.message = e;
                                cx.notify();
                            }
                        }
                    } else if let (Some(parent), Some(name)) = (path.parent(), path.file_name()) {
                        this.begin(
                            Pending::Switch(
                                parent.to_path_buf(),
                                Some(name.to_string_lossy().into_owned()),
                            ),
                            window,
                            cx,
                        );
                    }
                }
                Ok(Err(e)) => {
                    this.message = e.to_string();
                    cx.notify();
                }
                _ => {}
            });
        })
        .detach();
    }
    fn picks(&self, cx: &App) -> Vec<Pick> {
        let q = self.query.read(cx).value().trim().to_lowercase();
        match self.dialog {
            Some(Dialog::Navigation) => self
                .nav_targets
                .iter()
                .enumerate()
                .filter(|(_, t)| {
                    format!("{} {} {}", t.name, t.detail, t.path.display())
                        .to_lowercase()
                        .contains(&q)
                })
                .map(|(i, t)| Pick {
                    label: if t.name.is_empty() {
                        format!(
                            "{}:{}:{}",
                            self.target_path(t),
                            t.start.line + 1,
                            t.start.character + 1
                        )
                    } else {
                        t.name.clone()
                    },
                    detail: t.detail.clone(),
                    path: None,
                    line: None,
                    command: None,
                    target: Some(i),
                })
                .collect(),
            Some(Dialog::Quick) => {
                let mut picks = self
                    .workspace
                    .documents
                    .iter()
                    .filter_map(|d| {
                        let path = d.path.to_lowercase();
                        let mut rest = path.as_str();
                        for c in q.chars() {
                            let at = rest.find(c)?;
                            rest = &rest[at + c.len_utf8()..];
                        }
                        Some(Pick {
                            label: d.path.clone(),
                            detail: if self.dirty(&d.path) { "未保存" } else { "" }.into(),
                            path: Some(d.path.clone()),
                            line: None,
                            command: None,
                            target: None,
                        })
                    })
                    .collect::<Vec<_>>();
                picks.sort_by_key(|p| (!p.label.to_lowercase().contains(&q), p.label.len()));
                picks.truncate(80);
                picks
            }
            Some(Dialog::Commands) => COMMANDS
                .iter()
                .filter(|(id, name, _)| q.is_empty() || name.contains(&q) || id.contains(&q))
                .map(|(id, name, key)| Pick {
                    label: name.to_string(),
                    detail: key.to_string(),
                    path: None,
                    line: None,
                    command: Some(*id),
                    target: None,
                })
                .collect(),
            Some(Dialog::WorkspaceSearch) if !q.is_empty() => self
                .workspace
                .documents
                .iter()
                .flat_map(|doc| {
                    let q = q.clone();
                    doc.text
                        .lines()
                        .enumerate()
                        .filter(move |(_, line)| line.to_lowercase().contains(&q))
                        .map(move |(line, text)| Pick {
                            label: format!("{}:{}", doc.path, line + 1),
                            detail: text.trim().to_string(),
                            path: Some(doc.path.clone()),
                            line: Some(line),
                            command: None,
                            target: None,
                        })
                })
                .take(200)
                .collect(),
            _ => vec![],
        }
    }
    fn accept(&mut self, _: &PickerAccept, window: &mut Window, cx: &mut Context<Self>) {
        let Some(dialog) = self.dialog.clone() else {
            return;
        };
        let value = self.query.read(cx).value().trim().to_string();
        match dialog {
            Dialog::Quick | Dialog::Commands | Dialog::WorkspaceSearch | Dialog::Navigation => {
                if let Some(pick) = self.picks(cx).get(self.pick_index).cloned() {
                    self.dialog = None;
                    if let Some(index) = pick.target {
                        self.jump_target(index, window, cx);
                    } else if let Some(command) = pick.command {
                        self.run_command(command, window, cx);
                    } else if let Some(path) = pick.path {
                        self.open(&path, pick.line, true, window, cx);
                    }
                }
            }
            Dialog::Goto => {
                let mut parts = value.split(':');
                if let Ok(line) = parts.next().unwrap_or("").parse::<usize>() {
                    let col = parts
                        .next()
                        .and_then(|s| s.parse::<usize>().ok())
                        .unwrap_or(1);
                    if let Some(editor) = self.editor() {
                        self.dialog = None;
                        editor.update(cx, |input, cx| {
                            input.set_cursor_position(
                                Position::new(
                                    line.saturating_sub(1)
                                        .min(input.value().lines().count().saturating_sub(1))
                                        as u32,
                                    col.saturating_sub(1) as u32,
                                ),
                                window,
                                cx,
                            )
                        });
                    }
                } else {
                    self.message = "行番号または行:列を入力してください".into();
                }
            }
            Dialog::NewFolder => match self.workspace.create_directory(&value) {
                Ok(()) => {
                    self.directories = self.workspace.directories();
                    self.tree_target = Some(value);
                    self.dismiss(window, cx);
                }
                Err(e) => self.message = e,
            },
            Dialog::Rename => {
                if let Some(from) = self.rename_source.clone() {
                    match self.workspace.rename_file(&from, &value) {
                        Ok(()) => {
                            let remap = |p: &str| -> String {
                                if p == from {
                                    value.clone()
                                } else if let Some(suffix) = p.strip_prefix(&format!("{from}/")) {
                                    format!("{value}/{suffix}")
                                } else {
                                    p.into()
                                }
                            };
                            for old in self.buffers.keys().cloned().collect::<Vec<_>>() {
                                let new = remap(&old);
                                if new != old {
                                    let buffer = self.buffers.remove(&old).unwrap();
                                    *buffer.path.borrow_mut() = new.clone();
                                    if language(&old) != language(&new) {
                                        buffer.input.update(cx, |input, cx| {
                                            let pos = input.cursor_position();
                                            let text = input.value();
                                            input.set_highlighter(language(&new), cx);
                                            input.set_value(text, window, cx);
                                            input.set_cursor_position(pos, window, cx);
                                        });
                                    }
                                    self.buffers.insert(new, buffer);
                                }
                            }
                            for tab in &mut self.tabs {
                                *tab = remap(tab);
                            }
                            for path in &mut self.closed {
                                *path = remap(path);
                            }
                            for loc in &mut self.history {
                                loc.path = remap(&loc.path);
                            }
                            self.collapsed = self.collapsed.iter().map(|p| remap(p)).collect();
                            self.selected = self.selected.as_ref().map(|p| remap(p));
                            self.tree_target = Some(value);
                            self.directories = self.workspace.directories();
                            self.dismiss(window, cx);
                        }
                        Err(e) => self.message = e,
                    }
                }
            }
            Dialog::SaveAs => {
                self.sync_buffers(cx);
                if let Some(source) = self.save_source.clone() {
                    if let Some(index) = self.workspace.index_of(&source) {
                        let text = self.workspace.documents[index].text.clone();
                        match self.workspace.create_file(&value, &text) {
                            Ok(()) => {
                                if self.untitled.remove(&source) {
                                    if let Some(i) = self.workspace.index_of(&source) {
                                        self.workspace.documents.remove(i);
                                    }
                                } else if let Some(i) = self.workspace.index_of(&source) {
                                    self.workspace.documents[i].text =
                                        self.workspace.documents[i].disk.clone();
                                }
                                for tab in &mut self.tabs {
                                    if *tab == source {
                                        *tab = value.clone();
                                    }
                                }
                                if let Some(buffer) = self.buffers.remove(&source) {
                                    *buffer.path.borrow_mut() = value.clone();
                                    if language(&source) != language(&value) {
                                        buffer.input.update(cx, |input, cx| {
                                            let pos = input.cursor_position();
                                            let text = input.value();
                                            input.set_highlighter(language(&value), cx);
                                            input.set_value(text, window, cx);
                                            input.set_cursor_position(pos, window, cx);
                                        });
                                    }
                                    self.buffers.insert(value.clone(), buffer);
                                }
                                if let Some(Pending::Close(path)) = &mut self.pending {
                                    if *path == source {
                                        *path = value.clone();
                                    }
                                }
                                self.dialog = None;
                                self.save_source = None;
                                self.directories = self.workspace.directories();
                                self.open(&value, None, true, window, cx);
                                self.message = format!("保存しました · {value}");
                                if self.pending.is_some() {
                                    self.resolve_pending(true, window, cx);
                                } else if self.saving_all {
                                    self.save_all(&SaveAll, window, cx);
                                }
                            }
                            Err(e) => self.message = e,
                        }
                    }
                }
            }
            Dialog::Replace => self.replace_text(false, window, cx),
            Dialog::Help | Dialog::Information => self.dismiss(window, cx),
        }
        cx.notify();
    }
    fn replace_text(&mut self, all: bool, window: &mut Window, cx: &mut Context<Self>) {
        let query = self.query.read(cx).value().to_string();
        let replacement = self.replacement.read(cx).value().to_string();
        if query.is_empty() {
            self.message = "置換する文字列を入力してください".into();
            cx.notify();
            return;
        }
        if let Some(editor) = self.editor() {
            let input = editor.read(cx);
            let text = input.value().to_string();
            if all {
                let count = text.matches(&query).count();
                let replaced = text.replace(&query, &replacement);
                if count > 0 {
                    editor.update(cx, |input, cx| {
                        input.replace_text_in_range(
                            Some(0..text.encode_utf16().count()),
                            &replaced,
                            window,
                            cx,
                        )
                    });
                }
                self.message = format!("{count}件を置換しました · ⌘Zで元に戻す");
            } else {
                let cursor = input.cursor();
                let start = text[cursor..]
                    .find(&query)
                    .map(|p| p + cursor)
                    .or_else(|| text.find(&query));
                if let Some(start) = start {
                    let range = text[..start].encode_utf16().count()
                        ..text[..start + query.len()].encode_utf16().count();
                    editor.update(cx, |input, cx| {
                        input.replace_text_in_range(Some(range), &replacement, window, cx)
                    });
                    self.message = "1件を置換しました · ⌘Zで元に戻す".into();
                } else {
                    self.message = "一致する文字列がありません".into();
                }
            }
        }
        cx.notify();
    }
    fn file_target(&self) -> Option<String> {
        self.tree_target.clone().or_else(|| self.selected.clone())
    }
    fn run_command(&mut self, command: &str, window: &mut Window, cx: &mut Context<Self>) {
        match command {
            "new" => self.new_file(&NewFile, window, cx),
            "folder" => self.show(Dialog::NewFolder, "", window, cx),
            "open" => self.pick_path(false, window, cx),
            "open-folder" => self.pick_path(true, window, cx),
            "save" => self.save(&Save, window, cx),
            "save-all" => self.save_all(&SaveAll, window, cx),
            "save-as" => self.save_as(&SaveAs, window, cx),
            "close" => self.close_tab(&CloseTab, window, cx),
            "close-all" => self.begin(Pending::CloseAll, window, cx),
            "reopen" => self.reopen(&ReopenTab, window, cx),
            "rename" => {
                if let Some(path) = self.file_target().filter(|p| !self.external.contains(p)) {
                    if self.untitled.contains(&path) {
                        self.save_as(&SaveAs, window, cx);
                    } else {
                        self.rename_source = Some(path.clone());
                        self.show(Dialog::Rename, &path, window, cx);
                    }
                }
            }
            "delete" => {
                if let Some(path) = self.file_target().filter(|p| !self.external.contains(p)) {
                    if self.untitled.contains(&path) {
                        self.close_tab(&CloseTab, window, cx);
                    } else {
                        self.begin(Pending::Delete(path), window, cx);
                    }
                }
            }
            "restore" => match self.workspace.restore_last_deleted() {
                Ok(path) => {
                    self.directories = self.workspace.directories();
                    if self.workspace.index_of(&path).is_some() {
                        self.open(&path, None, true, window, cx);
                    }
                    self.tree_target = Some(path);
                    self.message = "削除した項目を復元しました".into();
                }
                Err(e) => self.message = e,
            },
            "find" => self.find(&Find, window, cx),
            "replace" => self.show(Dialog::Replace, "", window, cx),
            "find-all" => self.show(Dialog::WorkspaceSearch, "", window, cx),
            "goto" => self.show(Dialog::Goto, "", window, cx),
            "definition" => self.analyze(Query::Definition, true, window, cx),
            "peek-definition" => self.analyze(Query::Definition, false, window, cx),
            "type-definition" => self.analyze(Query::TypeDefinition, true, window, cx),
            "implementation" => self.analyze(Query::Implementation, true, window, cx),
            "references" => self.analyze(Query::References, false, window, cx),
            "symbols" => self.analyze(Query::Symbols, false, window, cx),
            "hover" => self.analyze(Query::Hover, false, window, cx),
            "wrap" => self.toggle_wrap(&ToggleWrap, window, cx),
            "sidebar" => self.sidebar = !self.sidebar,
            "inspector" => self.inspector = !self.inspector,
            "compare" => self.toggle_compare(&Compare, window, cx),
            "reload" => self.begin(Pending::Reload, window, cx),
            "reveal" => {
                if let Some(path) = &self.selected {
                    if !self.untitled.contains(path) {
                        cx.reveal_path(&self.workspace.root.join(path));
                    }
                }
            }
            "help" => self.show(Dialog::Help, "", window, cx),
            _ => {}
        }
        cx.notify();
    }
    fn target_path(&self, target: &Target) -> String {
        target
            .path
            .strip_prefix(&self.workspace.root)
            .unwrap_or(&target.path)
            .to_string_lossy()
            .into_owned()
    }
    fn snapshot_current(&self, snapshot: &Snapshot) -> bool {
        self.workspace.root == snapshot.root
            && snapshot.documents.iter().all(|(path, text)| {
                self.workspace
                    .documents
                    .iter()
                    .find(|d| self.workspace.root.join(&d.path) == *path)
                    .is_some_and(|d| d.text == *text)
            })
    }
    fn analyze(&mut self, query: Query, jump: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.nav_busy {
            self.message = "解析中です。結果パネルの×で表示をキャンセルできます".into();
            cx.notify();
            return;
        }
        self.sync_buffers(cx);
        let Some(path) = self.selected.clone() else {
            return;
        };
        if self.untitled.contains(&path) {
            self.message = "言語を判定するため、先に拡張子を付けて保存してください".into();
            cx.notify();
            return;
        }
        let Some(editor) = self.editor() else {
            return;
        };
        let position = ls::position_at(editor.read(cx).value().as_str(), editor.read(cx).cursor());
        let snapshot = Snapshot {
            root: self.workspace.root.clone(),
            path: self.workspace.root.join(&path),
            position,
            documents: self
                .workspace
                .documents
                .iter()
                .filter(|d| !self.untitled.contains(&d.path))
                .map(|d| (self.workspace.root.join(&d.path), d.text.clone()))
                .collect(),
        };
        self.nav_serial += 1;
        let serial = self.nav_serial;
        self.nav_busy = true;
        self.nav_visible = true;
        self.nav_targets.clear();
        self.nav_snapshot = None;
        self.nav_title = format!("{} · {}:{}", query.title(), path, position.line + 1);
        self.nav_information =
            "言語サーバーで解析しています…（初回は起動に少し時間がかかります）".into();
        if query == Query::Symbols {
            self.show(Dialog::Navigation, "", window, cx);
        }
        self.message = self.nav_information.clone();
        cx.notify();
        let service = self.service.clone();
        let request = snapshot.clone();
        let (sender, receiver) = futures_channel::oneshot::channel();
        std::thread::spawn(move || {
            let answer = service
                .lock()
                .map_err(|_| "言語サーバーの状態を取得できません".to_string())
                .and_then(|mut s| s.query(query, request));
            let _ = sender.send(answer);
        });
        cx.spawn_in(window,async move |this,cx| {
            let answer=receiver.await.unwrap_or_else(|_|Err("解析処理が終了しました".into()));
            let _=this.update_in(cx,|this,window,cx| {
                if serial!=this.nav_serial {return;}
                this.nav_busy=false;
                this.sync_buffers(cx);
                if !this.snapshot_current(&snapshot) || this.selected.as_ref().map(|p|this.workspace.root.join(p))!=Some(snapshot.path.clone()) {
                    this.nav_information="解析中にコードまたは表示ファイルが変わったため、結果を破棄しました。再度実行してください".into();
                    this.message=this.nav_information.clone();cx.notify();return;
                }
                match answer {
                    Err(e)=>{this.nav_information=e.clone();this.message=e;}
                    Ok(answer)=>{
                        this.nav_targets=answer.targets;
                        this.nav_snapshot=Some(snapshot);
                        this.nav_information=if query==Query::Hover {
                            if answer.information.is_empty() {"この位置には型・説明情報がありません".into()} else {answer.information}
                        } else if this.nav_targets.is_empty() {format!("{}が見つかりませんでした · {}",query.title(),answer.server)}
                        else {format!("{}件 · {} · 未保存の編集を含む解析結果（使用箇所は宣言を含む）",this.nav_targets.len(),answer.server)};
                        this.message=if query==Query::Hover {format!("型・ドキュメントを取得しました · {}",answer.server)} else {this.nav_information.clone()};
                        if query==Query::Hover {this.show(Dialog::Information,"",window,cx);}
                        else if jump && this.nav_targets.len()==1 {this.jump_target(0,window,cx);}
                        else if query!=Query::Symbols && !this.nav_targets.is_empty() {this.show(Dialog::Navigation,"",window,cx);}
                    }
                }
                cx.notify();
            });
        }).detach();
    }
    fn jump_target(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_buffers(cx);
        if self
            .nav_snapshot
            .as_ref()
            .is_some_and(|s| !self.snapshot_current(s))
        {
            self.message = "コードが変わっています。定義・使用箇所を再解析してください".into();
            cx.notify();
            return;
        }
        let Some(target) = self.nav_targets.get(index).cloned() else {
            return;
        };
        let path = match target.path.canonicalize() {
            Ok(path) => path,
            Err(e) => {
                self.message = format!("定義ファイルを開けません: {e}");
                cx.notify();
                return;
            }
        };
        let key = if let Ok(relative) = path.strip_prefix(&self.workspace.root) {
            let key = relative.to_string_lossy().into_owned();
            if let Err(e) = self.workspace.add_existing(&key) {
                self.message = e;
                cx.notify();
                return;
            }
            key
        } else {
            let key = path.to_string_lossy().into_owned();
            if self.workspace.index_of(&key).is_none() {
                if !std::fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() <= 1024 * 1024) {
                    self.message =
                        "外部定義を開けません（UTF-8、1MiB以内の通常ファイルに対応）".into();
                    cx.notify();
                    return;
                }
                let text = match std::fs::read_to_string(&path) {
                    Ok(t) if !t.contains('\0') => t,
                    _ => {
                        self.message = "外部定義はUTF-8テキストのみ閲覧できます".into();
                        cx.notify();
                        return;
                    }
                };
                self.workspace.documents.push(Document {
                    path: key.clone(),
                    disk: text.clone(),
                    text: text.clone(),
                    before: Some(text),
                });
            }
            self.external.insert(key.clone());
            key
        };
        self.dialog = None;
        self.open(&key, None, true, window, cx);
        if let Some(editor) = self.editor() {
            editor.update(cx, |input, cx| {
                let text = input.value();
                let at = ls::byte_offset(text.as_str(), target.start);
                // GPUI Component uses character columns; LSP uses UTF-16 columns.
                let before = &text[..at];
                let column = before.rsplit('\n').next().unwrap_or("").chars().count() as u32;
                let line = before.bytes().filter(|b| *b == b'\n').count() as u32;
                input.set_cursor_position(Position::new(line, column), window, cx);
                input.focus(window, cx);
            });
        }
        self.pending_reveal = Some((key.clone(), self.position(cx)));
        if let Some(last) = self.history.get_mut(self.history_index) {
            let p = self.buffers[&key].input.read(cx).cursor_position();
            last.line = p.line;
            last.column = p.character;
        }
        self.message = format!(
            "{}:{}:{} · ⌃−で元の場所へ戻る",
            self.target_path(&target),
            target.start.line + 1,
            target.start.character + 1
        );
        cx.notify();
    }
    fn navigation_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        div()
            .h(px(194.))
            .flex_shrink_0()
            .flex()
            .flex_col()
            .bg(rgb(PANEL))
            .border_t_1()
            .border_color(rgb(BORDER))
            .child(
                div()
                    .h(px(34.))
                    .px_4()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .flex()
                            .gap_3()
                            .child(self.nav_title.clone())
                            .child(caption(if self.nav_busy {
                                "解析中…".into()
                            } else {
                                format!("{}件", self.nav_targets.len())
                            })),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(button("filter-navigation", "一覧・絞り込み").on_click(
                                cx.listener(|this, _, w, cx| {
                                    this.show(Dialog::Navigation, "", w, cx)
                                }),
                            ))
                            .child(button("close-navigation", "×").on_click(cx.listener(
                                |this, _, _, cx| {
                                    this.nav_serial += 1;
                                    this.nav_busy = false;
                                    this.nav_visible = false;
                                    cx.notify();
                                },
                            ))),
                    ),
            )
            .child(
                div()
                    .id("navigation-results")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px_4()
                    .when(self.nav_targets.is_empty(), |list| {
                        list.child(div().py_3().child(self.nav_information.clone()))
                    })
                    .children(self.nav_targets.iter().enumerate().map(|(i, t)| {
                        let label = if t.name.is_empty() {
                            format!(
                                "{}:{}:{}",
                                self.target_path(t),
                                t.start.line + 1,
                                t.start.character + 1
                            )
                        } else {
                            format!("{} · {}:{}", t.name, self.target_path(t), t.start.line + 1)
                        };
                        div()
                            .id(("navigation-result", i))
                            .py_2()
                            .border_b_1()
                            .border_color(rgb(BORDER))
                            .cursor_pointer()
                            .hover(|s| s.bg(rgb(0x233040)))
                            .on_click(cx.listener(move |this, _, w, cx| this.jump_target(i, w, cx)))
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(rgb(ACCENT))
                                    .child(label),
                            )
                            .child(caption(t.detail.clone()))
                    })),
            )
            .into_any_element()
    }
    pub fn request_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.begin(Pending::Quit, window, cx);
    }
    fn close_tab(&mut self, _: &CloseTab, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(path) = self.selected.clone() {
            self.begin(Pending::Close(path), window, cx);
        }
    }
    fn reopen(&mut self, _: &ReopenTab, window: &mut Window, cx: &mut Context<Self>) {
        while let Some(path) = self.closed.pop() {
            if self.workspace.index_of(&path).is_some() {
                self.open(&path, None, true, window, cx);
                break;
            }
        }
    }
    fn cycle(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.tabs.is_empty() {
            return;
        }
        let i = self
            .selected
            .as_ref()
            .and_then(|p| self.tabs.iter().position(|s| s == p))
            .unwrap_or(0);
        let next = if forward {
            (i + 1) % self.tabs.len()
        } else {
            (i + self.tabs.len() - 1) % self.tabs.len()
        };
        self.open(&self.tabs[next].clone(), None, true, window, cx);
    }
    fn navigate(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.history.is_empty() {
            return;
        }
        let pos = self.position(cx);
        if let Some(current) = self.history.get_mut(self.history_index) {
            current.line = pos.line;
            current.column = pos.character;
        }
        self.history_index = if forward {
            (self.history_index + 1).min(self.history.len() - 1)
        } else {
            self.history_index.saturating_sub(1)
        };
        let loc = self.history[self.history_index].clone();
        self.open(&loc.path, Some(loc.line as usize), false, window, cx);
        if let Some(editor) = self.editor() {
            editor.update(cx, |input, cx| {
                input.set_cursor_position(Position::new(loc.line, loc.column), window, cx)
            });
        }
    }
    fn find(&mut self, _: &Find, window: &mut Window, cx: &mut Context<Self>) {
        self.compare = false;
        if let Some(editor) = self.editor() {
            editor.update(cx, |input, cx| input.focus(window, cx));
            window.dispatch_action(Box::new(gpui_component::input::Search), cx);
        }
        cx.notify();
    }
    fn toggle_wrap(&mut self, _: &ToggleWrap, window: &mut Window, cx: &mut Context<Self>) {
        self.wrap = !self.wrap;
        for buffer in self.buffers.values() {
            buffer
                .input
                .update(cx, |input, cx| input.set_soft_wrap(self.wrap, window, cx));
        }
        cx.notify();
    }
    fn toggle_compare(&mut self, _: &Compare, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_buffers(cx);
        self.compare = !self.compare;
        self.rebuild_diff();
        if !self.compare {
            if let Some(editor) = self.editor() {
                editor.update(cx, |input, cx| input.focus(window, cx));
            }
        }
        cx.notify();
    }
    fn add_note(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.index() else {
            return;
        };
        let text = self.note.read(cx).value().to_string();
        if text.trim().is_empty() {
            return;
        }
        let line = self.position(cx).line as usize;
        let doc = &self.workspace.documents[index];
        self.workspace.session.notes.push(Note {
            path: doc.path.clone(),
            line: line + 1,
            quote: doc.text.lines().nth(line).unwrap_or("").into(),
            text,
        });
        self.message = match self.workspace.persist() {
            Ok(()) => "コードの引用と疑問を保存しました".into(),
            Err(e) => e,
        };
        self.note
            .update(cx, |input, cx| input.set_value("", window, cx));
        cx.notify();
    }
    fn tree_entries(&self) -> Vec<readit::tree::Entry> {
        let paths = self
            .workspace
            .documents
            .iter()
            .filter(|d| !self.untitled.contains(&d.path) && !self.external.contains(&d.path))
            .map(|d| d.path.clone())
            .collect::<Vec<_>>();
        readit::tree::entries_with_directories(&paths, &self.directories, &self.collapsed)
    }
    fn tree_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if !self.explorer_focus.is_focused(window) {
            return;
        }
        let entries = self.tree_entries();
        if entries.is_empty() {
            return;
        }
        let index = self
            .tree_target
            .as_ref()
            .and_then(|p| entries.iter().position(|e| &e.path == p))
            .unwrap_or(0);
        match event.keystroke.key.as_str() {
            "up" | "down" => {
                let i = if event.keystroke.key == "up" {
                    index.saturating_sub(1)
                } else {
                    (index + 1).min(entries.len() - 1)
                };
                self.tree_target = Some(entries[i].path.clone());
            }
            "left" => {
                let target = &entries[index];
                if target.file.is_none() {
                    self.collapsed.insert(target.path.clone());
                } else if let Some((parent, _)) = target.path.rsplit_once('/') {
                    self.tree_target = Some(parent.into());
                }
            }
            "right" => {
                let target = &entries[index];
                if target.file.is_none() {
                    self.collapsed.remove(&target.path);
                }
            }
            "enter" => {
                let target = &entries[index];
                if target.file.is_some() {
                    self.open(&target.path, None, true, window, cx);
                } else if !self.collapsed.remove(&target.path) {
                    self.collapsed.insert(target.path.clone());
                }
            }
            _ => return,
        }
        if let Some(target) = &self.tree_target {
            if let Some(i) = self.tree_entries().iter().position(|e| &e.path == target) {
                self.tree_scroll.scroll_to_item(i);
            }
        }
        cx.stop_propagation();
        cx.notify();
    }
    fn explorer(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        let root = self
            .workspace
            .root
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let entries = self.tree_entries();
        div()
            .id("explorer")
            .key_context("Explorer")
            .track_focus(&self.explorer_focus)
            .on_key_down(cx.listener(Self::tree_key))
            .w(px(245.))
            .h_full()
            .flex_shrink_0()
            .bg(rgb(PANEL))
            .border_r_1()
            .border_color(rgb(BORDER))
            .flex()
            .flex_col()
            .child(
                div()
                    .px_4()
                    .py_3()
                    .flex_shrink_0()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(caption(if self.reading_path {
                        "READING PATH"
                    } else {
                        "EXPLORER"
                    }))
                    .child(
                        div()
                            .flex()
                            .gap_1()
                            .child(button("new-file", "+").on_click(
                                cx.listener(|this, _, w, cx| this.new_file(&NewFile, w, cx)),
                            ))
                            .child(button("new-folder", "+ ▱").on_click(cx.listener(
                                |this, _, w, cx| this.show(Dialog::NewFolder, "", w, cx),
                            ))),
                    ),
            )
            .child(
                div()
                    .px_4()
                    .py_2()
                    .flex_shrink_0()
                    .text_size(px(12.))
                    .child(format!("⌄  {}", root.to_uppercase())),
            )
            .child(
                div()
                    .id("tree-scroll")
                    .track_scroll(&self.tree_scroll)
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .when(!self.reading_path, |tree| {
                        tree.children(entries.into_iter().enumerate().map(|(i, entry)| {
                            let path = entry.path.clone();
                            let right_path = path.clone();
                            let menu_focus = self.explorer_focus.clone();
                            let folder = entry.file.is_none();
                            let active = self.tree_target.as_deref() == Some(path.as_str());
                            let badge = if self.dirty(&path) {
                                "●"
                            } else if self
                                .workspace
                                .index_of(&path)
                                .is_some_and(|i| self.workspace.documents[i].changed())
                            {
                                "M"
                            } else {
                                ""
                            };
                            let icon = if folder {
                                if self.collapsed.contains(&path) {
                                    "›"
                                } else {
                                    "⌄"
                                }
                            } else {
                                match language(&path) {
                                    "python" => "py",
                                    "rust" => "rs",
                                    "typescript" => "ts",
                                    "javascript" => "js",
                                    _ => "≡",
                                }
                            };
                            div()
                                .id(("tree-row", i))
                                .h(px(29.))
                                .pl(px(14. + entry.depth as f32 * 14.))
                                .pr_3()
                                .flex()
                                .gap_2()
                                .items_center()
                                .cursor_pointer()
                                .bg(rgb(if active { 0x29394a } else { PANEL }))
                                .hover(|s| s.bg(rgb(0x233040)))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.tree_target = Some(path.clone());
                                    if folder {
                                        this.explorer_focus.focus(window);
                                        if !this.collapsed.remove(&path) {
                                            this.collapsed.insert(path.clone());
                                        }
                                    } else {
                                        this.open(&path, None, true, window, cx);
                                    }
                                    cx.notify();
                                }))
                                .on_mouse_down(
                                    MouseButton::Right,
                                    cx.listener(move |this, _, window, cx| {
                                        this.tree_target = Some(right_path.clone());
                                        if this.workspace.index_of(&right_path).is_some() {
                                            this.open(&right_path, None, true, window, cx);
                                        }
                                        this.explorer_focus.focus(window);
                                        cx.notify();
                                    }),
                                )
                                .child(
                                    div()
                                        .w(px(18.))
                                        .flex_shrink_0()
                                        .text_size(px(10.))
                                        .text_color(rgb(0x8fb4d4))
                                        .child(icon),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .overflow_hidden()
                                        .text_size(px(12.))
                                        .child(entry.name),
                                )
                                .child(
                                    div()
                                        .text_color(rgb(ACCENT))
                                        .text_size(px(11.))
                                        .child(badge),
                                )
                                .context_menu(move |menu, _, _| {
                                    menu.action_context(menu_focus.clone())
                                        .menu("新規ファイル", Box::new(NewFile))
                                        .menu("新規フォルダ", Box::new(NewFolder))
                                        .separator()
                                        .menu("名前を変更…", Box::new(RenameFile))
                                        .menu("削除…", Box::new(DeleteFile))
                                })
                        }))
                    })
                    .when(self.reading_path, |tree| {
                        tree.children(
                            self.workspace
                                .documents
                                .iter()
                                .filter(|d| !self.external.contains(&d.path))
                                .enumerate()
                                .map(|(i, doc)| {
                                    let path = doc.path.clone();
                                    div()
                                        .id(("route", i))
                                        .p_3()
                                        .mx_2()
                                        .my_1()
                                        .rounded_md()
                                        .cursor_pointer()
                                        .hover(|s| s.bg(rgb(0x233a32)))
                                        .on_click(cx.listener(move |this, _, w, cx| {
                                            this.open(&path, None, true, w, cx)
                                        }))
                                        .child(caption(format!("{:02} · {}", i + 1, doc.role())))
                                        .child(doc.path.clone())
                                }),
                        )
                    }),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .p_3()
                    .border_t_1()
                    .border_color(rgb(BORDER))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(button("rename", "名前変更").on_click(
                                cx.listener(|this, _, w, cx| this.run_command("rename", w, cx)),
                            ))
                            .child(button("delete", "削除…").on_click(
                                cx.listener(|this, _, w, cx| this.run_command("delete", w, cx)),
                            )),
                    )
                    .child(
                        button(
                            "reading",
                            if self.reading_path {
                                "ファイルツリーに戻る"
                            } else {
                                "読む順番を表示"
                            },
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.reading_path = !this.reading_path;
                            cx.notify();
                        })),
                    ),
            )
    }
    fn tab_strip(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        div()
            .id("tabs")
            .track_scroll(&self.tab_scroll)
            .h(px(40.))
            .flex_shrink_0()
            .flex()
            .overflow_x_scroll()
            .bg(rgb(PANEL))
            .border_b_1()
            .border_color(rgb(BORDER))
            .children(self.tabs.iter().enumerate().map(|(i, path)| {
                let name = path.rsplit('/').next().unwrap_or(path).to_string();
                let open_path = path.clone();
                let close_path = path.clone();
                let middle_path = path.clone();
                let selected = self.selected.as_ref() == Some(path);
                div()
                    .id(("tab", i))
                    .h_full()
                    .flex_shrink_0()
                    .min_w(px(130.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .pl_3()
                    .pr_1()
                    .border_r_1()
                    .border_color(rgb(BORDER))
                    .border_t_2()
                    .border_color(rgb(if selected { 0x81afd5 } else { PANEL }))
                    .bg(rgb(if selected { BG } else { PANEL }))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open(&open_path, None, true, window, cx)
                    }))
                    .on_mouse_down(
                        MouseButton::Middle,
                        cx.listener(move |this, _, w, cx| {
                            cx.stop_propagation();
                            this.begin(Pending::Close(middle_path.clone()), w, cx);
                        }),
                    )
                    .child(div().text_size(px(12.)).child(name))
                    .child(
                        div()
                            .w(px(8.))
                            .text_size(px(10.))
                            .text_color(rgb(ACCENT))
                            .child(if self.dirty(path) { "●" } else { "" }),
                    )
                    .child(
                        div()
                            .id(("close", i))
                            .size(px(26.))
                            .rounded_sm()
                            .flex()
                            .justify_center()
                            .items_center()
                            .hover(|s| s.bg(rgb(0x3a4655)))
                            .child("×")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                cx.stop_propagation();
                                this.begin(Pending::Close(close_path.clone()), window, cx);
                            })),
                    )
            }))
    }
    fn inspector(&self, cx: &mut Context<Self>) -> Stateful<Div> {
        let index = self.index();
        let line = self.position(cx).line as usize;
        let reviewed = index.is_some_and(|i| self.workspace.reviewed(i));
        div()
            .id("inspector")
            .w(px(295.))
            .h_full()
            .flex_shrink_0()
            .p_4()
            .bg(rgb(PANEL))
            .border_l_1()
            .border_color(rgb(BORDER))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_4()
            .child(caption("UNDERSTANDING · ⌥⌘B"))
            .child(div().flex_shrink_0().text_lg().child("何がわかった？"))
            .child(caption("コードを読み、根拠と疑問を記録する。"))
            .child(
                button(
                    "reviewed",
                    if reviewed {
                        "✓ 理解済み · 取り消す"
                    } else {
                        "このファイルを理解済みにする"
                    },
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(i) = this.index() {
                        let doc = &this.workspace.documents[i];
                        if this.workspace.reviewed(i) {
                            this.workspace.session.reviewed.remove(&doc.path);
                        } else {
                            this.workspace
                                .session
                                .reviewed
                                .insert(doc.path.clone(), doc.text.clone());
                        }
                        this.message = match this.workspace.persist() {
                            Ok(()) => "理解の記録を保存しました".into(),
                            Err(e) => e,
                        };
                        cx.notify();
                    }
                })),
            )
            .child(caption(format!("疑問を残す · L{}", line + 1)))
            .child(div().flex_shrink_0().child(Input::new(&self.note)))
            .child(
                button("note", "＋ コードと一緒に記録")
                    .on_click(cx.listener(|this, _, w, cx| this.add_note(w, cx))),
            )
            .children(
                self.workspace
                    .session
                    .notes
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| self.selected.as_ref() == Some(&n.path))
                    .map(|(i, note)| {
                        let path = note.path.clone();
                        let line = note.line.saturating_sub(1);
                        let stale = index.is_none_or(|i| {
                            self.workspace.documents[i].text.lines().nth(line)
                                != Some(note.quote.as_str())
                        });
                        div()
                            .id(("note-card", i))
                            .flex_shrink_0()
                            .p_3()
                            .rounded_md()
                            .border_1()
                            .border_color(rgb(BORDER))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.open(&path, Some(line), true, window, cx)
                            }))
                            .child(caption(format!(
                                "L{}{}",
                                note.line,
                                if stale {
                                    " · 引用が変化しています"
                                } else {
                                    ""
                                }
                            )))
                            .child(div().my_2().text_size(px(12.)).child(note.text.clone()))
                            .child(caption(note.quote.clone()))
                    }),
            )
            .child(
                div()
                    .mt_4()
                    .flex_shrink_0()
                    .border_t_1()
                    .border_color(rgb(BORDER))
                    .pt_4()
                    .child(caption("AI説明生成は未接続です。")),
            )
    }
    fn overlay(&self, cx: &mut Context<Self>) -> AnyElement {
        let panel = div()
            .w(px(640.))
            .max_h(px(590.))
            .mt(px(72.))
            .rounded_lg()
            .bg(rgb(PANEL))
            .border_1()
            .border_color(rgb(0x46566a))
            .shadow_lg()
            .flex()
            .flex_col()
            .overflow_hidden();
        if let Some(dialog) = &self.dialog {
            let title = match dialog {
                Dialog::Quick => "ファイルを開く · ⌘P",
                Dialog::Commands => "コマンドパレット · ⇧⌘P",
                Dialog::WorkspaceSearch => "プロジェクト内検索 · 最大200件",
                Dialog::Goto => "行へ移動 · 行番号 または 行:列",
                Dialog::NewFolder => "新規フォルダ · プロジェクト内の相対パス",
                Dialog::Rename => "名前を変更 · プロジェクト内の相対パス",
                Dialog::SaveAs => "名前を付けて保存 · プロジェクト内の相対パス",
                Dialog::Replace => "ファイル内置換 · 文字列の完全一致",
                Dialog::Help => "キーボードショートカット",
                Dialog::Navigation => &self.nav_title,
                Dialog::Information => "型とドキュメント",
            };
            let title = if *dialog == Dialog::SaveAs {
                format!("{} · {}", self.save_source.as_deref().unwrap_or(""), title)
            } else {
                title.to_string()
            };
            let picks = self.picks(cx);
            let is_picker = matches!(
                dialog,
                Dialog::Quick | Dialog::Commands | Dialog::WorkspaceSearch | Dialog::Navigation
            );
            panel.id("dialog").key_context("Picker")
                .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                    if this.query.update(cx, |input,cx| input.marked_text_range(window,cx).is_some()) { return; }
                    match event.keystroke.key.as_str() {
                        "escape" => this.dismiss(window, cx),
                        "enter" if !matches!(this.dialog, Some(Dialog::Replace)) => this.accept(&PickerAccept, window, cx),
                        "up" | "down" if matches!(this.dialog, Some(Dialog::Quick | Dialog::Commands | Dialog::WorkspaceSearch | Dialog::Navigation)) => {
                            let len = this.picks(cx).len(); this.pick_index = if event.keystroke.key == "up" { this.pick_index.saturating_sub(1) } else { (this.pick_index + 1).min(len.saturating_sub(1)) }; this.pick_scroll.scroll_to_item(this.pick_index); cx.notify();
                        }
                        _ => return,
                    }
                    cx.stop_propagation();
                }))
                .child(div().p_4().flex_shrink_0().flex().justify_between().child(title).child(caption("Esc 閉じる")))
                .when(!matches!(dialog, Dialog::Help | Dialog::Information), |panel| panel.child(div().px_4().pb_3().flex_shrink_0().child(Input::new(&self.query))))
                .when(is_picker, |panel| panel.child(div().id("picks").track_scroll(&self.pick_scroll).max_h(px(if *dialog == Dialog::Navigation { 230. } else { 390. })).overflow_y_scroll().min_h_0()
                    .when(picks.is_empty(), |list| list.child(div().p_4().child(caption("一致する項目がありません"))))
                    .children(picks.iter().enumerate().map(|(i, pick)| {
                        div().id(("pick", i)).px_4().py_3().cursor_pointer().bg(rgb(if i == self.pick_index { 0x293d53 } else { PANEL })).hover(|s| s.bg(rgb(0x263749)))
                            .on_click(cx.listener(move |this, _, window, cx| { this.pick_index = i; this.accept(&PickerAccept, window, cx); }))
                            .child(div().text_size(px(13.)).child(pick.label.clone()))
                            .child(caption(pick.detail.clone()))
                    }))))
                .when(*dialog == Dialog::Navigation, |panel| {
                    if let Some(target) = picks.get(self.pick_index).and_then(|p|p.target).and_then(|i|self.nav_targets.get(i)) {
                        panel.child(div().id("definition-preview").max_h(px(170.)).overflow_y_scroll().px_4().py_3().border_t_1().border_color(rgb(BORDER)).bg(rgb(BG)).font_family("Menlo").text_size(px(12.))
                            .child(caption("プレビュー · Enterで移動 · ⌃−で戻る"))
                            .children(target.preview.lines().map(|line| div().child(line.to_string()))))
                    } else {panel}
                })
                .when(*dialog == Dialog::Information, |panel| panel.child(div().id("type-information").max_h(px(390.)).overflow_y_scroll().p_4().font_family("Menlo").text_size(px(13.)).children(self.nav_information.lines().map(|line| div().child(if line.is_empty() { " " } else { line }.to_string())))))
                .when(*dialog == Dialog::Replace, |panel| panel.child(div().px_4().pb_3().flex_shrink_0().child(Input::new(&self.replacement)))
                    .child(div().px_4().pb_4().flex_shrink_0().flex().gap_2()
                        .child(button("replace-next", "次を置換").on_click(cx.listener(|this, _, window, cx| this.replace_text(false, window, cx))))
                        .child(button("replace-all", "すべて置換").on_click(cx.listener(|this, _, window, cx| this.replace_text(true, window, cx))))))
                .when(*dialog == Dialog::Help, |panel| panel.child(div().id("help-list").max_h(px(390.)).overflow_y_scroll().min_h_0().p_4()
                    .children(COMMANDS.iter().map(|(_, name, key)| div().py_1().flex().justify_between().child(name.to_string()).child(caption(key.to_string()))))
                    .child(caption("本文: ⌘Z / ⇧⌘Z Undo/Redo · ⌘C/X/V · Tab/⇧Tab インデント · ⌥←/→ 単語移動 · ⇧矢印 範囲選択"))))
                .when(matches!(dialog, Dialog::Goto | Dialog::NewFolder | Dialog::Rename | Dialog::SaveAs), |panel| panel.child(div().px_4().pb_4().flex_shrink_0().flex().gap_2()
                    .child(button("accept-dialog", "確定").on_click(cx.listener(|this, _, w, cx| this.accept(&PickerAccept, w, cx))))
                    .child(button("cancel-dialog", "キャンセル").on_click(cx.listener(|this, _, w, cx| this.dismiss(w, cx))))))
                .child(div().px_4().py_2().flex_shrink_0().border_t_1().border_color(rgb(BORDER)).child(caption(self.message.clone())))
                .into_any_element()
        } else if let Some(pending) = &self.pending {
            let deletion = matches!(pending, Pending::Delete(_));
            let paths = if let Pending::Delete(p) = pending {
                p.clone()
            } else {
                self.affected(pending).join("\n")
            };
            panel.child(div().p_5().flex().flex_col().gap_4()
                .child(if deletion { "選択した項目を削除しますか？" } else { "変更を保存しますか？" })
                .child(caption(paths))
                .child(caption(if deletion { "フォルダの場合は中身も移動します。削除した項目は.readit/trashに保管され、メニューから復元できます。" } else { "保存しない場合、この操作の対象となる未保存の変更を破棄します。" }))
                .child(div().flex().gap_2()
                    .child(button("confirm-save", if deletion { "保存して削除" } else { "保存" }).on_click(cx.listener(|this, _, w, cx| this.resolve_pending(true, w, cx))))
                    .child(button("confirm-discard", if deletion { "保存せず削除" } else { "保存しない" }).on_click(cx.listener(|this, _, w, cx| this.resolve_pending(false, w, cx))))
                    .child(button("confirm-cancel", "キャンセル").on_click(cx.listener(|this, _, w, cx| this.dismiss(w, cx))))))
                .into_any_element()
        } else {
            div().into_any_element()
        }
    }
}

impl Render for Reader {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // A newly opened editor needs one layout before it can reveal a distant line.
        if let Some((path, position)) = self.pending_reveal.take() {
            let reader = cx.entity().downgrade();
            window.on_next_frame(move |window, cx| {
                let _ = reader.update(cx, |this, cx| {
                    if this.selected.as_ref() == Some(&path) && this.position(cx) == position {
                        if let Some(editor) = this.editor() {
                            editor.update(cx, |input, cx| {
                                input.set_cursor_position(position, window, cx)
                            });
                        }
                    }
                });
            });
        }
        let path = self.selected.clone().unwrap_or_default();
        let editor = self.editor();
        let position = self.position(cx);
        let overlay = self.dialog.is_some() || self.pending.is_some();
        div().size_full().relative().key_context("Readit").track_focus(&self.focus).flex().flex_col().bg(rgb(BG)).text_color(rgb(TEXT)).font_family(".SystemUIFont").text_size(px(13.))
            .on_action(cx.listener(|this, _: &Definition, w, cx| this.analyze(Query::Definition,true,w,cx)))
            .on_action(cx.listener(|this, _: &PeekDefinition, w, cx| this.analyze(Query::Definition,false,w,cx)))
            .on_action(cx.listener(|this, _: &TypeDefinition, w, cx| this.analyze(Query::TypeDefinition,true,w,cx)))
            .on_action(cx.listener(|this, _: &Implementation, w, cx| this.analyze(Query::Implementation,true,w,cx)))
            .on_action(cx.listener(|this, _: &References, w, cx| this.analyze(Query::References,false,w,cx)))
            .on_action(cx.listener(|this, _: &DocumentSymbols, w, cx| this.analyze(Query::Symbols,false,w,cx)))
            .on_action(cx.listener(|this, _: &HoverInfo, w, cx| this.analyze(Query::Hover,false,w,cx)))
            .on_action(cx.listener(Self::new_file)).on_action(cx.listener(Self::save)).on_action(cx.listener(Self::save_all)).on_action(cx.listener(Self::save_as))
            .on_action(cx.listener(Self::close_tab)).on_action(cx.listener(Self::reopen)).on_action(cx.listener(Self::find)).on_action(cx.listener(Self::toggle_wrap)).on_action(cx.listener(Self::toggle_compare))
            .on_action(cx.listener(|this, _: &Quit, w, cx| this.request_quit(w, cx)))
            .on_action(cx.listener(|this, _: &CloseAll, w, cx| this.begin(Pending::CloseAll, w, cx)))
            .on_action(cx.listener(|this, _: &NewFolder, w, cx| this.show(Dialog::NewFolder, "", w, cx)))
            .on_action(cx.listener(|this, _: &OpenFile, w, cx| this.pick_path(false, w, cx)))
            .on_action(cx.listener(|this, _: &OpenFolder, w, cx| this.pick_path(true, w, cx)))
            .on_action(cx.listener(|this, _: &QuickOpen, w, cx| this.show(Dialog::Quick, "", w, cx)))
            .on_action(cx.listener(|this, _: &CommandPalette, w, cx| this.show(Dialog::Commands, "", w, cx)))
            .on_action(cx.listener(|this, _: &FindInFiles, w, cx| this.show(Dialog::WorkspaceSearch, "", w, cx)))
            .on_action(cx.listener(|this, _: &GoToLine, w, cx| this.show(Dialog::Goto, "", w, cx)))
            .on_action(cx.listener(|this, _: &Replace, w, cx| this.show(Dialog::Replace, "", w, cx)))
            .on_action(cx.listener(|this, _: &RenameFile, w, cx| this.run_command("rename", w, cx)))
            .on_action(cx.listener(|this, _: &DeleteFile, w, cx| this.run_command("delete", w, cx)))
            .on_action(cx.listener(|this, _: &RestoreDeleted, w, cx| this.run_command("restore", w, cx)))
            .on_action(cx.listener(|this, _: &Reload, w, cx| this.begin(Pending::Reload, w, cx)))
            .on_action(cx.listener(|this, _: &Help, w, cx| this.show(Dialog::Help, "", w, cx)))
            .on_action(cx.listener(|this, _: &Escape, w, cx| this.dismiss(w, cx)))
            .on_action(cx.listener(|this, _: &ToggleSidebar, _, cx| { this.sidebar = !this.sidebar; cx.notify(); }))
            .on_action(cx.listener(|this, _: &ToggleInspector, _, cx| { this.inspector = !this.inspector; cx.notify(); }))
            .on_action(cx.listener(|this, _: &FocusExplorer, w, cx| { this.sidebar = true; this.explorer_focus.focus(w); cx.notify(); }))
            .on_action(cx.listener(|this, _: &NextTab, w, cx| this.cycle(true, w, cx)))
            .on_action(cx.listener(|this, _: &PreviousTab, w, cx| this.cycle(false, w, cx)))
            .on_action(cx.listener(|this, _: &Back, w, cx| this.navigate(false, w, cx)))
            .on_action(cx.listener(|this, _: &Forward, w, cx| this.navigate(true, w, cx)))
            .on_action(cx.listener(|this, _: &ZoomIn, _, cx| { this.font_size = (this.font_size + 1.).min(28.); cx.notify(); }))
            .on_action(cx.listener(|this, _: &ZoomOut, _, cx| { this.font_size = (this.font_size - 1.).max(10.); cx.notify(); }))
            .on_action(cx.listener(|this, _: &ResetZoom, _, cx| { this.font_size = 14.; cx.notify(); }))
            .child(div().h(px(48.)).flex_shrink_0().px_4().flex().gap_4().items_center().justify_between().border_b_1().border_color(rgb(BORDER))
                .child(div().flex().gap_3().items_center().child(div().text_lg().font_weight(FontWeight::BOLD).text_color(rgb(ACCENT)).child("readit"))
                    .child(caption(self.workspace.root.file_name().unwrap_or_default().to_string_lossy().into_owned())))
                .child(button("quick-open", "ファイルを開く…  ⌘P").on_click(cx.listener(|this, _, w, cx| this.show(Dialog::Quick, "", w, cx))))
                .child(div().flex().gap_2()
                    .child(button("open-folder", "フォルダを開く").on_click(cx.listener(|this, _, w, cx| this.pick_path(true, w, cx))))
                    .child(button("commands", "コマンド  ⇧⌘P").on_click(cx.listener(|this, _, w, cx| this.show(Dialog::Commands, "", w, cx))))))
            .child(div().flex_1().min_h_0().flex()
                .when(self.sidebar, |row| row.child(self.explorer(cx)))
                .child(div().flex_1().min_w_0().h_full().flex().flex_col()
                    .child(self.tab_strip(cx))
                    .child(div().h(px(38.)).px_4().flex_shrink_0().flex().items_center().justify_between().border_b_1().border_color(rgb(BORDER))
                        .child(caption(if path.is_empty() { "ファイルを選択してください".into() } else if self.external.contains(&path) { format!("外部定義 › {}",std::path::Path::new(&path).file_name().unwrap_or_default().to_string_lossy()) } else { path.clone() }))
                        .child(div().flex().gap_2().when(!path.is_empty(), |bar| bar
                            .child(button("save", "保存  ⌘S").on_click(cx.listener(|this, _, w, cx| this.save(&Save, w, cx))))
                            .child(button("compare", if self.compare { "編集に戻る" } else { "差分" }).on_click(cx.listener(|this, _, w, cx| this.toggle_compare(&Compare, w, cx)))))))
                    .child(div().h(px(33.)).px_3().flex_shrink_0().flex().gap_2().items_center().border_b_1().border_color(rgb(BORDER))
                        .child(button("nav-back", "←").on_click(cx.listener(|this,_,w,cx| this.navigate(false,w,cx))))
                        .child(button("nav-forward", "→").on_click(cx.listener(|this,_,w,cx| this.navigate(true,w,cx))))
                        .child(button("nav-definition", "定義 F12").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Definition,true,w,cx))))
                        .child(button("nav-references", "使用箇所 ⇧F12").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::References,false,w,cx))))
                        .child(button("nav-symbols", "シンボル ⇧⌘O").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Symbols,false,w,cx))))
                        .child(button("nav-hover", "型・説明").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Hover,false,w,cx))))
                        .when(self.external.contains(&path), |bar|bar.child(caption("外部定義 · 閲覧専用"))))
                    .child(div().flex_1().min_h_0().min_w_0().overflow_hidden()
                        .on_mouse_up(MouseButton::Left,cx.listener(|this,event: &MouseUpEvent,w,cx| { if event.modifiers.secondary() && !this.compare { this.analyze(Query::Definition,true,w,cx); } }))
                        .when(!self.compare, |area| {
                            if let Some(editor) = &editor { area.child(Input::new(editor).disabled(self.external.contains(&path)).h_full().appearance(false).bordered(false).focus_bordered(false).font_family("Menlo").text_size(px(self.font_size))) }
                            else { area.child(div().size_full().flex().flex_col().gap_4().items_center().justify_center().child(div().text_2xl().child("Readit"))
                                .child(caption("⌘P ファイルを開く   ·   ⌘N 新規ファイル   ·   ⌘O ファイルを選択"))) }
                        })
                        .when(self.compare, |area| area.child(uniform_list("diff", self.diff_rows.len(), cx.processor(|this, range: std::ops::Range<usize>, _, cx| {
                            range.map(|i| {
                                let row = this.diff_rows[i].clone(); let path = this.selected.clone();
                                let color = match row.kind { Kind::Added => ACCENT, Kind::Removed => 0xeba9b4, _ => TEXT };
                                div().id(("diff-row", i)).h(px(25.)).flex().items_center().bg(rgb(match row.kind { Kind::Added => 0x183029, Kind::Removed => 0x321f29, _ => BG }))
                                    .on_click(cx.listener(move |this, _, w, cx| { if let (Some(path), Some(line)) = (&path, row.new) { this.open(path, Some(line), true, w, cx); } }))
                                    .child(div().w(px(100.)).flex_shrink_0().text_size(px(11.)).text_color(rgb(MUTED)).child(format!("{:>4} {:>4} {}", row.old.map(|i| (i+1).to_string()).unwrap_or_default(), row.new.map(|i| (i+1).to_string()).unwrap_or_default(), match row.kind { Kind::Added => "+", Kind::Removed => "−", _ => " " })))
                                    .child(div().font_family("Menlo").whitespace_nowrap().text_size(px(this.font_size)).text_color(rgb(color)).child(row.text))
                            }).collect::<Vec<_>>()
                        })).track_scroll(self.diff_scroll.clone()).h_full())))
                )
                .when(self.inspector, |row| row.child(self.inspector(cx))))
            .when(self.nav_visible, |root| root.child(self.navigation_panel(cx)))
            .child(div().h(px(29.)).flex_shrink_0().px_3().flex().items_center().justify_between().bg(rgb(PANEL)).border_t_1().border_color(rgb(BORDER))
                .child(caption(self.message.clone()))
                .child(caption(format!("Ln {}, Col {}  ·  {}  ·  UTF-8  ·  {}", position.line + 1, position.character + 1, language(&path), if self.wrap { "Wrap" } else { "No wrap" }))))
            .when(overlay, |root| root.child(div().absolute().inset_0().bg(rgba(0x00000070)).flex().items_start().justify_center()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(self.overlay(cx))))
    }
}
