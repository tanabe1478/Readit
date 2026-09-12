use crate::commands::*;
use gpui::{prelude::*, *};
use gpui_component::input::{Input, InputEvent, InputState, Position};
use gpui_component::menu::ContextMenuExt;
use readit::{
    diff::{self, Kind, Row},
    language_service::{self as ls, Query, Service, Snapshot, Target},
    workspace::{Document, Workspace},
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

struct PointerPreview {
    path: String,
    cursor: usize,
    range: std::ops::Range<usize>,
    bounds: Bounds<Pixels>,
    definition: bool,
    targets: Vec<Target>,
    information: String,
    snapshot: Snapshot,
    code: Option<Entity<InputState>>,
}

// Keep automatic placement outside the whole annotation, not just its first line.
fn guide_placement(anchor: Bounds<Pixels>, viewport: Size<Pixels>, height: Pixels, manual: Option<Point<Pixels>>) -> (Point<Pixels>, Size<Pixels>) {
    let margin = px(12.);
    let width = px(430.).min((viewport.width - margin * 2.).max(px(1.)));
    let height = height.min((viewport.height - margin * 2.).max(px(1.)));
    let left = anchor.left().max(margin).min((viewport.width - width - margin).max(margin));
    if let Some(position) = manual {
        return (point(position.x.max(margin).min((viewport.width-width-margin).max(margin)),
            position.y.max(margin).min((viewport.height-height-margin).max(margin))), size(width,height));
    }
    let above = (anchor.top() - margin - px(8.)).max(px(0.));
    let below = (viewport.height - margin - anchor.bottom() - px(8.)).max(px(0.));
    if below >= height || below >= above {
        (point(left,anchor.bottom()+px(8.)),size(width,height.min(below)))
    } else {
        let height=height.min(above);
        (point(left,anchor.top()-px(8.)-height),size(width,height))
    }
}

#[derive(Clone)]
struct Guide {
    id: String,
    root: PathBuf,
    path: String,
    source: String,
    range: std::ops::Range<usize>,
    title: String,
    body: String,
    question_open: bool,
    pending_question: Option<u64>,
    question: Option<String>,
    answer: Option<String>,
    question_error: Option<String>,
    pending_next: Option<std::time::Instant>,
    position: Option<Point<Pixels>>,
    measured: Rc<RefCell<Option<(u64, Bounds<Pixels>)>>>,
    drag: Option<(Point<Pixels>, Point<Pixels>)>,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct OverviewChapter {
    title: String,
    summary: String,
    start_step: String,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct GuideOverview {
    title: String,
    summary: String,
    // Plain text: roles, boundaries and the principal flow, written by the external agent.
    relationships: String,
    chapters: Vec<OverviewChapter>,
}

impl GuideOverview {
    fn parse(value: &serde_json::Value, steps: &[Guide]) -> Result<Self, String> {
        let overview: Self = serde_json::from_value(value.clone()).map_err(|e|e.to_string())?;
        let valid = |s: &str, max| !s.trim().is_empty() && s.chars().count() <= max;
        if !valid(&overview.title,100) || !valid(&overview.summary,2000) || !valid(&overview.relationships,4000)
            || overview.chapters.is_empty() || overview.chapters.len()>16 {
            return Err("overview requires title (100), summary (2000), relationships (4000), and 1..16 chapters".into());
        }
        let mut previous=None;
        for chapter in &overview.chapters {
            if !valid(&chapter.title,100) || !valid(&chapter.summary,1000) {return Err("invalid chapter text".into());}
            let index=steps.iter().position(|g|g.id==chapter.start_step).ok_or("chapter start_step must name an existing step")?;
            if previous.is_none() && index!=0 || previous.is_some_and(|p|index<=p) {return Err("chapters must partition all steps in reading order, starting at the first step".into());}
            previous=Some(index);
        }
        Ok(overview)
    }
}

struct GuideTour {
    id: String,
    steps: Vec<Guide>,
    index: usize,
    visited: usize,
    overview: Option<GuideOverview>,
    seen: BTreeSet<String>,
}

struct PinnedCode {
    root: PathBuf,
    path: String,
    source: String,
    line: u64,
    input: Entity<InputState>,
}

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
    pinned: Option<PinnedCode>,
    guide: Option<Guide>,
    guide_tour: Option<GuideTour>,
    overview_visible: bool,
    overview_tab: bool,
    guide_question: Entity<InputState>,
    guide_events: Vec<serde_json::Value>,
    guide_sequence: u64,
    control: Option<readit::control::Server>,
    control_task: Option<Task<()>>,
    control_targets: Vec<Target>,
    control_target_root: PathBuf,
    service: Arc<Mutex<Service>>,
    pointer_preview: Option<PointerPreview>,
    pointer_task: Option<Task<()>>,
    pointer_serial: Arc<std::sync::atomic::AtomicU64>,
    pointer_popup_bounds: Option<Bounds<Pixels>>,
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
    tree_scroll: UniformListScrollHandle,
    tab_scroll: ScrollHandle,
    collapsed: BTreeSet<String>,
    directories: Vec<String>,
    tree_target: Option<String>,
    reading_path: bool,
    sidebar: bool,
    sidebar_width: f32,
    sidebar_drag: Option<(Pixels, f32)>,
    wrap: bool,
    font_size: f32,
    compare: bool,
    diff_rows: Vec<Row>,
    diff_scroll: UniformListScrollHandle,
    message: String,
    history: Vec<Location>,
    history_index: usize,
}

fn button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Stateful<Div> {
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
    ("pin-code", "現在のコードを横に固定", "⌘K ⌘P"),
    ("unpin-code", "固定したコードを閉じる", ""),
    ("definition-hover", "定義ホバープレビューを表示", ""),
    ("wrap", "折返し切替", "⌥Z"),
    ("sidebar", "ファイルツリー表示切替", "⌘B"),
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
        let guide_question =
            cx.new(|cx| InputState::new(window, cx).placeholder("どの点が気になりますか？"));
        let replacement = cx.new(|cx| InputState::new(window, cx).placeholder("置換後の文字列"));
        let subscriptions = vec![cx.subscribe(&query, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.pick_index = 0;
                cx.notify();
            }
        })];
        let mut this = Self {
            pinned: None,
            guide: None,
            guide_tour: None,
            overview_visible: false,
            overview_tab: false,
            guide_question,
            guide_events: vec![],
            guide_sequence: 0,
            control: None,
            control_task: None,
            control_targets: vec![],
            control_target_root: PathBuf::new(),
            service: Arc::new(Mutex::new(Service::default())),
            pointer_preview: None,
            pointer_task: None,
            pointer_serial: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            pointer_popup_bounds: None,
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
            replacement,
            _subscriptions: subscriptions,
            dialog: None,
            pending: None,
            save_source: None,
            saving_all: false,
            rename_source: None,
            pick_index: 0,
            pick_scroll: ScrollHandle::new(),
            tree_scroll: UniformListScrollHandle::new(),
            tab_scroll: ScrollHandle::new(),
            collapsed: BTreeSet::new(),
            tree_target: None,
            reading_path: false,
            sidebar: true,
            sidebar_width: 245.,
            sidebar_drag: None,
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
    #[cfg_attr(feature = "performance", profiling::function)]
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
        self.overview_visible = false;
        self.clear_pointer(cx);
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
                    this.clear_pointer(cx);
                    if let Some(i) = this.workspace.index_of(&event_token.borrow()) {
                        this.workspace.documents[i].text = input.read(cx).value().to_string();
                    }
                    if this.compare {
                        this.rebuild_diff();
                    }
                    cx.notify();
                }
            });
            let selection = cx.observe(&input, |this, input, cx| {
                if this
                    .pointer_preview
                    .as_ref()
                    .is_some_and(|p| input.read(cx).cursor() != p.cursor)
                {
                    this.clear_pointer(cx);
                }
                cx.notify();
            });
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
        self.clear_pointer(cx);
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
        self.guide_response("end", cx);
        self.clear_pointer(cx);
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
            "pin-code" => self.pin_current(window, cx),
            "unpin-code" => {
                self.pinned = None;
                cx.notify();
            }
            "definition-hover" => {
                if let Some(editor) = self.editor() {
                    let input = editor.read(cx);
                    let text = input.value();
                    if let Some(range) = readit::hover::symbol_range(&text, input.cursor()) {
                        let end =
                            range.start + text[range.start..].chars().next().unwrap().len_utf8();
                        if let Some(bounds) = input.range_to_bounds(&(range.start..end)) {
                            let point = point(bounds.left() + px(1.), bounds.top() + px(1.));
                            self.dialog = None;
                            editor.update(cx, |input, cx| input.focus(window, cx));
                            self.update_pointer(point, true, window, cx);
                        }
                    }
                }
            }
            "hover" => self.analyze(Query::Hover, false, window, cx),
            "wrap" => self.toggle_wrap(&ToggleWrap, window, cx),
            "sidebar" => self.sidebar = !self.sidebar,
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
    fn clear_pointer(&mut self, cx: &mut Context<Self>) {
        if self.pointer_preview.take().is_some() || self.pointer_task.is_some() {
            self.pointer_serial
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.pointer_task = None;
            self.pointer_popup_bounds = None;
            cx.notify();
        }
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn pointer_symbol(
        &self,
        point: Point<Pixels>,
        cx: &App,
    ) -> Option<(std::ops::Range<usize>, Bounds<Pixels>, ls::Position)> {
        let editor = self.editor()?;
        let input = editor.read(cx);
        let text = input.value();
        let offset = input.index_for_mouse_position(point);
        // The layout hit test returns the nearest insertion point. Check both adjacent
        // characters, then require actual glyph bounds so gutters/blank space never jump.
        let previous = text
            .get(..offset)?
            .char_indices()
            .next_back()
            .map(|(i, _)| i);
        for offset in std::iter::once(offset).chain(previous) {
            let Some(range) = readit::hover::symbol_range(&text, offset) else {
                continue;
            };
            let end = offset + text[offset..].chars().next()?.len_utf8();
            let Some(glyph) = input.range_to_bounds(&(offset..end)) else {
                continue;
            };
            if !glyph.contains(&point) {
                continue;
            }
            let bounds = input
                .range_to_bounds(&range)
                .filter(|b| b.contains(&point))
                .unwrap_or(glyph);
            return Some((range, bounds, ls::position_at(&text, offset)));
        }
        None
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn update_pointer(
        &mut self,
        point: Point<Pixels>,
        definition: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .pointer_popup_bounds
            .is_some_and(|b| b.contains(&point))
        {
            return;
        }
        if self.compare || self.dialog.is_some() || self.pending.is_some() || self.nav_busy {
            self.clear_pointer(cx);
            return;
        }
        let Some(path) = self.selected.clone().filter(|p| {
            !self.untitled.contains(p) && ls::language_id(&self.workspace.root.join(p)).is_some()
        }) else {
            self.clear_pointer(cx);
            return;
        };
        let Some((range, bounds, position)) = self.pointer_symbol(point, cx) else {
            self.clear_pointer(cx);
            return;
        };
        if self.pointer_preview.as_ref().is_some_and(|p| {
            p.path == path && p.range == range && p.definition == definition && p.bounds == bounds
        }) {
            return;
        }
        self.clear_pointer(cx);
        self.sync_buffers(cx);
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
        self.pointer_preview = Some(PointerPreview {
            cursor: self.editor().unwrap().read(cx).cursor(),
            path,
            range,
            bounds,
            definition,
            targets: vec![],
            information: String::new(),
            snapshot: snapshot.clone(),
            code: None,
        });
        let serial_counter = self.pointer_serial.clone();
        let serial = serial_counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let service = self.service.clone();
        self.pointer_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(250))
                .await;
            let (sender, receiver) = futures_channel::oneshot::channel();
            let request = snapshot.clone();
            std::thread::spawn(move || {
                let Ok(mut service) = service.lock() else {
                    return;
                };
                if serial_counter.load(std::sync::atomic::Ordering::Relaxed) != serial {
                    return;
                }
                let mut targets = vec![];
                if definition {
                    if let Ok(answer) = service.query(Query::Definition, request.clone()) {
                        targets = answer.targets;
                    }
                }
                if serial_counter.load(std::sync::atomic::Ordering::Relaxed) != serial {
                    return;
                }
                let information = service
                    .query(Query::Hover, request)
                    .map(|a| a.information)
                    .unwrap_or_default();
                let _ = sender.send((targets, information));
            });
            let Ok((targets, information)) = receiver.await else {
                return;
            };
            let _ = this.update_in(cx, |this, window, cx| {
                if this
                    .pointer_serial
                    .load(std::sync::atomic::Ordering::Relaxed)
                    != serial
                {
                    return;
                }
                this.sync_buffers(cx);
                if !this.snapshot_current(&snapshot)
                    || this.selected.as_ref().map(|p| this.workspace.root.join(p))
                        != Some(snapshot.path.clone())
                    || this.compare
                    || this.dialog.is_some()
                    || this.pending.is_some()
                {
                    this.clear_pointer(cx);
                    return;
                }
                let code = targets.first().map(|target| {
                    let snippet = target
                        .preview
                        .lines()
                        .map(|line| line.get(5..).unwrap_or(line))
                        .collect::<Vec<_>>()
                        .join("\n");
                    cx.new(|cx| {
                        InputState::new(window, cx)
                            .code_editor(language(&target.path.to_string_lossy()))
                            .line_number(false)
                            .soft_wrap(false)
                            .default_value(snippet)
                    })
                });
                if let Some(preview) = &mut this.pointer_preview {
                    preview.code = code;
                    preview.targets = targets;
                    preview.information = information;
                }
                cx.notify();
            });
        }));
    }

    fn jump_pointer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(preview) = self.pointer_preview.take() else {
            return;
        };
        self.clear_pointer(cx);
        self.sync_buffers(cx);
        if !self.snapshot_current(&preview.snapshot) {
            return;
        }
        self.nav_targets = preview.targets;
        self.nav_snapshot = Some(preview.snapshot);
        self.nav_title = "定義".into();
        if self.nav_targets.len() == 1 {
            self.jump_target(0, window, cx);
        } else if !self.nav_targets.is_empty() {
            self.show(Dialog::Navigation, "", window, cx);
        }
    }

    fn pointer_overlay(&mut self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        self.pointer_popup_bounds = None;
        let Some(preview) = &self.pointer_preview else {
            return div().into_any_element();
        };
        if preview.information.is_empty() && preview.targets.is_empty() {
            return div().into_any_element();
        }
        let viewport = window.viewport_size();
        let width = px(610.).min(viewport.width - px(20.));
        let left = preview
            .bounds
            .left()
            .max(px(10.))
            .min(viewport.width - width - px(10.));
        let lines = preview.information.lines().count().max(1);
        let desired = if preview.definition && !preview.targets.is_empty() {
            350.
        } else {
            (lines as f32 * 18. + 32.).clamp(70., 240.)
        };
        let height = px(desired).min(viewport.height - px(40.));
        let top = if preview.bounds.bottom() + height < viewport.height - px(20.) {
            preview.bounds.bottom()
        } else {
            (preview.bounds.top() - height).max(px(10.))
        };
        let popup = Bounds::new(point(left, top), size(width, height));
        self.pointer_popup_bounds = Some(popup);
        let has_definition = preview.definition && !preview.targets.is_empty();
        let mut content = div()
            .id("pointer-preview-content")
            .size_full()
            .overflow_y_scroll()
            .p_3()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .id("pointer-type-information")
                    .max_h(px(105.))
                    .overflow_y_scroll()
                    .flex_shrink_0()
                    .font_family("Menlo")
                    .text_size(px(12.))
                    .child(preview.information.clone()),
            );
        if has_definition {
            let target = &preview.targets[0];
            content = content
                .child(
                    div()
                        .border_t_1()
                        .border_color(rgb(BORDER))
                        .pt_2()
                        .child(caption(format!(
                            "{}:{}",
                            target.path.display(),
                            target.start.line + 1
                        ))),
                )
                .when_some(preview.code.as_ref(), |content, code| {
                    content.child(
                        div().h(px(180.)).flex_shrink_0().child(
                            Input::new(code)
                                .disabled(true)
                                .h_full()
                                .appearance(false)
                                .bordered(false)
                                .font_family("Menlo")
                                .text_size(px(12.)),
                        ),
                    )
                })
                .child(
                    button(
                        "pointer-jump",
                        if preview.targets.len() == 1 {
                            "定義へ移動  ⌘クリック".to_string()
                        } else {
                            format!("{}件の定義を表示", preview.targets.len())
                        },
                    )
                    .on_click(cx.listener(|this, _, w, cx| this.jump_pointer(w, cx))),
                );
        }
        let bounds = preview.bounds;
        div()
            .absolute()
            .inset_0()
            .when(has_definition, |root| {
                root.child(
                    div()
                        .absolute()
                        .left(bounds.left())
                        .top(bounds.top())
                        .w(bounds.size.width)
                        .h(bounds.size.height)
                        .border_b_1()
                        .border_color(rgb(0x66b5ff))
                        .cursor_pointer()
                        .on_mouse_down(MouseButton::Left, |event, _, cx| {
                            if event.modifiers.secondary() {
                                cx.stop_propagation();
                            }
                        })
                        .on_mouse_up(
                            MouseButton::Left,
                            cx.listener(|this, event: &MouseUpEvent, w, cx| {
                                if event.modifiers.secondary() {
                                    this.jump_pointer(w, cx);
                                    cx.stop_propagation();
                                }
                            }),
                        ),
                )
            })
            .child(
                div()
                    .id("pointer-preview")
                    .absolute()
                    .left(left)
                    .top(top)
                    .w(width)
                    .h(height)
                    .bg(rgb(PANEL))
                    .border_1()
                    .border_color(rgb(0x536476))
                    .rounded_md()
                    .shadow_lg()
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(content),
            )
            .into_any_element()
    }

    fn pin_code(
        &mut self,
        path: String,
        line: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        self.sync_buffers(cx);
        let source = self.control_text(&path)?;
        let offset = readit::control::offset_at(&source, line, 1)?;
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .code_editor(language(&path))
                .soft_wrap(false)
                .default_value(source.clone())
        });
        self.pinned = Some(PinnedCode {
            root: self.workspace.root.clone(),
            path,
            source,
            line,
            input: input.clone(),
        });
        let previous_focus = window.focused(cx);
        input.update(cx, |input, cx| {
            input.set_cursor_position(Position::new((line - 1) as u32, 0), window, cx);
            input.reveal_offset(offset, cx);
        });
        if let Some(focus) = previous_focus {
            focus.focus(window);
        }
        cx.notify();
        Ok(())
    }

    fn pin_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(path) = self.selected.clone() {
            if let Err(error) = self.pin_code(path, self.position(cx).line as u64 + 1, window, cx) {
                self.message = error;
                cx.notify();
            }
        }
    }

    fn pinned_changed(&self, cx: &App) -> bool {
        self.pinned.as_ref().is_some_and(|p| {
            if let Some(buffer) = self.buffers.get(&p.path) {
                buffer.input.read(cx).value().as_str() != p.source
            } else {
                self.workspace
                    .index_of(&p.path)
                    .is_some_and(|i| self.workspace.documents[i].text != p.source)
            }
        })
    }

    fn pinned_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(pinned) = &self.pinned else {
            return div().into_any_element();
        };
        let full = pinned
            .root
            .join(&pinned.path)
            .to_string_lossy()
            .into_owned();
        div()
            .w(relative(0.42))
            .min_w(px(240.))
            .h_full()
            .flex_shrink_0()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(rgb(BORDER))
            .bg(rgb(BG))
            .child(
                div()
                    .h(px(38.))
                    .flex_shrink_0()
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(caption("固定したコード · 閲覧専用"))
                    .child(
                        button("unpin-code", "×").on_click(cx.listener(|this, _, _, cx| {
                            this.pinned = None;
                            cx.notify();
                        })),
                    ),
            )
            .child(
                div()
                    .id("pinned-path")
                    .px_3()
                    .py_2()
                    .flex_shrink_0()
                    .overflow_x_scroll()
                    .child(caption(full).whitespace_nowrap()),
            )
            .child(
                div()
                    .px_3()
                    .py_2()
                    .flex_shrink_0()
                    .flex()
                    .gap_2()
                    .items_center()
                    .child(caption(if self.pinned_changed(cx) {
                        "本文に変更あり · 固定時の内容を表示中"
                    } else {
                        "固定時の内容を表示中"
                    }))
                    .child(button("refresh-pinned", "更新").on_click(cx.listener(
                        |this, _, w, cx| {
                            if let Some(p) = &this.pinned {
                                let path = p.path.clone();
                                let line = p.line;
                                if let Err(error) = this.pin_code(path, line, w, cx) {
                                    this.message = error;
                                    cx.notify();
                                }
                            }
                        },
                    ))),
            )
            .child(
                div().flex_1().min_h_0().overflow_hidden().child(
                    Input::new(&pinned.input)
                        .disabled(true)
                        .h_full()
                        .appearance(false)
                        .bordered(false)
                        .font_family("Menlo")
                        .text_size(px(self.font_size)),
                ),
            )
            .into_any_element()
    }

    fn show_overview(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.dialog.is_some() || self.pending.is_some() {return;}
        if self.guide_tour.as_ref().is_some_and(|t|t.overview.is_some()) {
            self.overview_visible=true; self.overview_tab=true;
            self.clear_pointer(cx); self.focus.focus(window); cx.notify();
        }
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn overview_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(tour)=&self.guide_tour else {return div().into_any_element();};
        let Some(overview)=&tour.overview else {return div().into_any_element();};
        let stale=tour.steps.iter().any(|g| {
            if let Some(buffer)=self.buffers.get(&g.path) {buffer.input.read(cx).value().as_str()!=g.source}
            else {self.workspace.index_of(&g.path).is_none_or(|i|self.workspace.documents[i].text!=g.source)}
        });
        div().id("reading-overview").flex_1().min_h_0().overflow_y_scroll().p_5()
            .child(div().max_w(px(900.)).flex().flex_col().gap_4()
                .child(caption("全体像 → 章の概要 → 実際のコード"))
                .child(div().text_2xl().font_weight(FontWeight::BOLD).child(overview.title.clone()))
                .child(div().text_size(px(15.)).child(overview.summary.clone()))
                .when(stale,|panel|panel.child(div().p_3().bg(rgb(0x483529)).child("コードに変更があります。外部AIに概観とガイドの更新を依頼してください。")))
                .child(div().p_4().bg(rgb(PANEL)).rounded_lg().flex().flex_col().gap_2()
                    .child(div().font_weight(FontWeight::BOLD).child("構成と処理の流れ"))
                    .children(overview.relationships.lines().map(|line|div().child(line.to_owned()))))
                .child(div().font_weight(FontWeight::BOLD).child("読む章"))
                .children(overview.chapters.iter().enumerate().map(|(i,chapter)| {
                    let start=tour.steps.iter().position(|g|g.id==chapter.start_step).unwrap();
                    let end=overview.chapters.get(i+1).and_then(|c|tour.steps.iter().position(|g|g.id==c.start_step)).unwrap_or(tour.steps.len());
                    let seen=tour.steps[start..end].iter().filter(|g|tour.seen.contains(&g.id)).count();
                    let current=tour.index>=start && tour.index<end && !tour.seen.is_empty();
                    div().id(("overview-chapter",i)).p_4().rounded_lg().border_1().border_color(rgb(if current {ACCENT}else{BORDER})).bg(rgb(PANEL)).flex().flex_col().gap_2()
                        .child(div().flex().justify_between().gap_3()
                            .child(div().font_weight(FontWeight::BOLD).child(format!("{:02}  {}",i+1,chapter.title)))
                            .child(caption(format!("{} / {} 箇所を表示済み{}",seen,end-start,if current {" · 現在の章"}else{""}))))
                        .child(chapter.summary.clone())
                        .child(caption(tour.steps[start..end].iter().map(|g|self.workspace.root.join(&g.path).to_string_lossy().into_owned()).collect::<BTreeSet<_>>().into_iter().collect::<Vec<_>>().join("\n")))
                        .when(!stale,|card|card.child(button(("chapter-open",i),"コードを読む →").on_click(cx.listener(move |this,_,w,cx| {
                            if let Some(t)=&this.guide_tour {let delta=start as i32-t.index as i32;this.guide_step(delta,w,cx);}
                        }))))
                }))
                .child(caption("解説は外部AIが事前に作成します。章の移動は待機なしで利用できます。")))
            .into_any_element()
    }

    fn prepare_guide(&self, args: &serde_json::Value) -> Result<Guide,String> {
                let field = |name: &str, max: usize| -> Result<String, String> {
                    let text = args
                        .get(name)
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| format!("{name} is required"))?;
                    if text.trim().is_empty() || text.chars().count() > max {
                        return Err(format!("{name} must contain 1..{max} characters"));
                    }
                    Ok(text.to_string())
                };
                let id = field("id", 128)?;
                let title = field("title", 100)?;
                let body = field("body", 2000)?;
                let expected = field("expected_text", 16000)?;
                let path = self.control_path(args.get("path").and_then(|v|v.as_str()).ok_or("path is required")?)?;
                let source = self.control_text(&path)?;
                let line = args.get("line").and_then(|v|v.as_u64()).ok_or("line is required")?;
                let column = args.get("column").and_then(|v|v.as_u64()).ok_or("column is required")?;
                let start = readit::control::offset_at(&source, line, column)?;
                let end = start.checked_add(expected.len()).ok_or("invalid range")?;
                if source.get(start..end) != Some(expected.as_str()) {
                    return Err("source changed or expected_text does not match".into());
                }
                Ok(Guide {
                    id,
                    root: self.workspace.root.clone(),
                    path,
                    source,
                    range: start..end,
                    title,
                    body,
                    question_open: false,
                    pending_question: None,
                    question: None,
                    answer: None,
                    question_error: None,
                    pending_next: None,
                    position: None,
                    measured: Rc::new(RefCell::new(None)),
                    drag: None,
                })
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn activate_guide(&mut self, guide: Guide, window: &mut Window, cx: &mut Context<Self>) -> Result<(),String> {
        if self.dialog.is_some() || self.pending.is_some() { return Err("finish the editor dialog first".into()); }
        if self.workspace.root!=guide.root || self.control_text(&guide.path)?!=guide.source {
            return Err("source changed; regenerate the guide before navigating".into());
        }
        let start=ls::position_at(&guide.source,guide.range.start);
        let end=ls::position_at(&guide.source,guide.range.end);
        let previous=self.guide.take();
        if let Err(error)=self.control_call(&readit::control::Call{method:"readit_open".into(),arguments:serde_json::json!({"workspace":self.workspace.root,"path":guide.path,"line":start.line+1,"column":start.character+1,"end_line":end.line+1,"end_column":end.character+1})},window,cx) {
            self.guide=previous;return Err(error);
        }
        let offset=guide.range.start;
        if let Some(editor)=self.editor() {
            window.on_next_frame(move |_,cx|editor.update(cx,|input,cx|input.reveal_at_top(offset,cx)));
        }
        self.overview_visible=false;
        self.compare=false;
        self.clear_pointer(cx);
        self.guide=Some(guide);
        self.guide_question.update(cx,|input,cx|input.set_value("",window,cx));
        cx.notify();
        Ok(())
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn guide_step(&mut self, direction: i32, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_buffers(cx);
        self.validate_guide(cx);
        let Some(tour)=self.guide_tour.as_ref() else { self.guide_response("next",cx);return; };
        if self.guide.as_ref().is_some_and(|g|g.question_open) {return;}
        let next=tour.index as i32+direction;
        if next<0 {return;}
        if next as usize>=tour.steps.len() {self.guide_response("end",cx);return;}
        let target=tour.steps[next as usize].clone();
        let previous=self.guide.clone();
        if let Err(error)=self.activate_guide(target,window,cx) {
            self.message=error.clone();
            if let Some(guide)=self.guide.as_mut(){guide.question_error=Some(error);}
            cx.notify();return;
        }
        let tour=self.guide_tour.as_mut().unwrap();
        if let Some(previous)=previous {tour.steps[tour.index]=previous;}
        tour.index=next as usize;
        tour.visited=tour.visited.max(tour.index);
        tour.seen.insert(tour.steps[tour.index].id.clone());
        self.guide_sequence+=1;
        self.guide_events.push(serde_json::json!({"sequence":self.guide_sequence,"action":"step","tour_id":tour.id,"index":tour.index,"id":tour.steps[tour.index].id}));
        if self.guide_events.len()>128 {self.guide_events.remove(0);}
        cx.notify();
    }

    fn prepare_steps(&self,args:&serde_json::Value, allow_empty:bool)->Result<Vec<Guide>,String>{
        let steps=args.get("steps").and_then(|v|v.as_array()).ok_or("steps must be an array")?;
        if steps.len()>32 || (!allow_empty && steps.is_empty()) {return Err("provide 1..32 steps".into());}
        let prepared=steps.iter().map(|s|self.prepare_guide(s)).collect::<Result<Vec<_>,_>>()?;
        let mut ids=BTreeSet::new();
        for step in &prepared {if !ids.insert(&step.id){return Err("step ids must be unique".into());}}
        Ok(prepared)
    }

    fn guide_response(&mut self, action: &str, cx: &mut Context<Self>) {
        if action == "next" && self.guide.as_ref().is_some_and(|g|
            g.pending_next.is_some() || g.pending_question.is_some() || g.question_open) {
            return;
        }
        let retain = action != "cleared" && self.guide_tour.as_ref().is_some_and(|t|t.overview.is_some() && t.steps[0].root==self.workspace.root);
        if action != "next" && !retain { self.guide_tour = None; self.overview_visible=false; self.overview_tab=false; }
        if retain { if let (Some(tour),Some(guide))=(&mut self.guide_tour,&self.guide) {tour.steps[tour.index]=guide.clone();} }
        if let Some(mut guide) = self.guide.take() {
            self.guide_sequence += 1;
            self.guide_events.push(serde_json::json!({"sequence":self.guide_sequence,
                "id":guide.id,"action":action,"workspace":guide.root,"path":guide.root.join(&guide.path)}));
            if self.guide_events.len() > 128 {
                self.guide_events.remove(0);
            }
            if action == "next" {
                guide.pending_next = Some(std::time::Instant::now());
                guide.drag = None;
                self.guide = Some(guide);
                cx.spawn(async move |this, cx| {
                    cx.background_executor().timer(std::time::Duration::from_secs(10)).await;
                    let _ = this.update(cx, |_, cx| cx.notify());
                }).detach();
            }
            cx.notify();
        }
    }

    fn open_guide_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(guide) = self.guide.as_mut() else {
            return;
        };
        if guide.pending_question.is_some() || guide.pending_next.is_some() {
            return;
        }
        guide.question_open = true;
        guide.question_error = None;
        self.guide_question
            .update(cx, |input, cx| input.focus(window, cx));
        cx.notify();
    }

    fn submit_guide_question(&mut self, cx: &mut Context<Self>) {
        self.validate_guide(cx);
        let Some(guide) = self.guide.as_mut() else {
            return;
        };
        if !guide.question_open || guide.pending_question.is_some() {
            return;
        }
        let question = self.guide_question.read(cx).value().trim().to_string();
        if question.is_empty() || question.chars().count() > 2000 {
            guide.question_error = Some("質問を1〜2,000文字で入力してください。".into());
            cx.notify();
            return;
        }
        self.guide_sequence += 1;
        let start = ls::position_at(&guide.source, guide.range.start);
        let end = ls::position_at(&guide.source, guide.range.end);
        self.guide_events.push(serde_json::json!({"sequence":self.guide_sequence,
            "id":guide.id,"action":"question","question":question,
            "workspace":guide.root,"path":guide.root.join(&guide.path),
            "line":start.line+1,"column":start.character+1,"end_line":end.line+1,"end_column":end.character+1,
            "expected_text":guide.source.get(guide.range.clone()),"title":guide.title,
            "explanation":guide.body,"previous_question":guide.question,"previous_answer":guide.answer}));
        if self.guide_events.len() > 128 {
            self.guide_events.remove(0);
        }
        guide.pending_question = Some(self.guide_sequence);
        guide.question = Some(question);
        guide.answer = None;
        guide.question_open = false;
        guide.question_error = None;
        cx.notify();
    }

    fn validate_guide(&mut self, cx: &mut Context<Self>) {
        if self.guide_tour.as_ref().is_some_and(|t|t.steps[0].root!=self.workspace.root) {
            self.guide_tour=None; self.overview_visible=false; self.overview_tab=false;
        }
        let invalid = self.guide.as_ref().is_some_and(|guide| {
            self.workspace.root != guide.root
                || self.selected.as_ref() != Some(&guide.path)
                || self
                    .editor()
                    .is_none_or(|editor| editor.read(cx).value().as_str() != guide.source)
        });
        if invalid {
            self.guide_response("interrupted", cx);
        }
    }

    #[cfg_attr(feature = "performance", profiling::function)]
    fn guide_overlay(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(guide) = &self.guide else {
            return div().into_any_element();
        };
        let Some(editor) = self.editor() else {
            return div().into_any_element();
        };
        let input = editor.read(cx);
        let anchor = input.visible_range().and_then(|visible| {
            let start = guide.range.start.max(visible.start);
            let end = guide.range.end.min(visible.end);
            if start >= end { return None; }
            let last = guide.source[start..end].char_indices().last().map(|(i,_)|start+i).unwrap_or(start);
            let first_bounds = input.range_to_bounds(&(start..start))?;
            let last_bounds = input.range_to_bounds(&(last..last))?;
            Some(Bounds::from_corners(
                point(first_bounds.left().min(last_bounds.left()), first_bounds.top().min(last_bounds.top())),
                point(first_bounds.right().max(last_bounds.right()), first_bounds.bottom().max(last_bounds.bottom())),
            ))
        });
        // A manually placed bubble belongs to the viewport, including while its
        // code is offscreen. Automatic bubbles only follow visible source.
        if anchor.is_none() && guide.position.is_none() { return div().into_any_element(); }
        let viewport = window.viewport_size();
        let anchor = anchor.unwrap_or_else(|| Bounds::new(point(px(12.),px(12.)),size(px(1.),px(1.))));
        use std::hash::{Hash, Hasher};
        let mut hash=std::collections::hash_map::DefaultHasher::new();
        (&guide.title,&guide.body,&guide.question,&guide.answer,guide.question_open,&guide.question_error,guide.pending_question.is_some(),guide.pending_next.is_some()).hash(&mut hash);
        f32::from(viewport.width).to_bits().hash(&mut hash);
        let layout_key=hash.finish();
        let measured=guide.measured.borrow().filter(|(key,_)|*key==layout_key).map(|(_,bounds)|bounds);
        let preferred_height=measured.map(|b|b.size.height).unwrap_or((viewport.height-px(200.)).max(px(80.)));
        let (origin, bubble_size)=guide_placement(anchor,viewport,preferred_height,guide.position);
        let measurement=guide.measured.clone();
        let reader=cx.entity().downgrade();
        let left = origin.x;
        let top = origin.y;
        let width = bubble_size.width;
        div()
            .absolute()
            .left(left)
            .top(top)
            .w(width)
            .p_3()
            .flex()
            .flex_col()
            .gap_2()
            .bg(rgb(PANEL))
            .border_1()
            .border_color(rgb(ACCENT))
            .rounded_lg()
            .shadow_lg()
            .id("reading-guide")
            .debug_selector(|| "reading-guide".into())
            .on_mouse_move(|event: &MouseMoveEvent, _, cx| {
                if event.pressed_button.is_none() { cx.stop_propagation(); }
            })
            .max_h(if guide.position.is_some() {
                (viewport.height-px(24.)).max(px(1.))
            } else if origin.y >= anchor.bottom() {
                (viewport.height-anchor.bottom()-px(20.)).max(px(1.))
            } else {
                (anchor.top()-px(20.)).max(px(1.))
            })
            .child(canvas(move |bounds,window,_| {
                let changed=measurement.borrow().as_ref().is_none_or(|(key,old)|*key!=layout_key || old.size!=bounds.size);
                *measurement.borrow_mut()=Some((layout_key,bounds));
                if changed {let reader=reader.clone();window.on_next_frame(move |_,cx|{let _=reader.update(cx,|_,cx|cx.notify());});}
            },|_,_,_,_|{}).absolute().inset_0())
            .overflow_y_scroll()
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
             .child(div().id("guide-drag-handle").debug_selector(|| "guide-drag-handle".into()).cursor_move().flex_shrink_0()
                .on_mouse_down(MouseButton::Left, cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                    this.clear_pointer(cx);
                    if let Some(guide) = this.guide.as_mut() {
                        let origin=guide.measured.borrow().map(|(_,bounds)|bounds.origin).unwrap_or(origin);
                        guide.position=Some(origin);
                        guide.drag = Some((event.position, origin));
                    }
                    cx.stop_propagation();
                }))
                .child(caption(format!("{}{} · ドラッグで移動", self.guide_tour.as_ref().map(|t|format!("{}/{} · ",t.index+1,t.steps.len())).unwrap_or_default(), guide.title))))
            .child(
                div()
                    .id("reading-guide-body")
                    .flex_shrink_0()
                    .child(guide.body.clone()),
            )
            .when(!guide.question_open, |bubble| bubble.when_some(guide.question_error.as_ref(), |bubble,error|bubble.child(caption(error.clone()))))
            .when_some(guide.question.as_ref(), |bubble, question| {
                bubble.child(
                    div()
                        .text_color(rgb(ACCENT))
                        .child(format!("質問: {question}")),
                )
            })
            .when_some(self.guide_tour.as_ref().and_then(|t|t.overview.as_ref().and_then(|o|o.chapters.iter().rev().find(|c|t.steps.iter().position(|g|g.id==c.start_step).is_some_and(|i|i<=t.index)))).map(|c|c.title.clone()), |bubble,title|bubble.child(caption(format!("章: {title}"))))
            .when_some(guide.pending_next, |bubble, started| {
                bubble.child(caption(if started.elapsed().as_secs() >= 10 {
                    "応答が届いていません。AI側でガイドを再開してください。"
                } else { "次の解説を待っています…" }))
            })
            .when(guide.pending_question.is_some(), |bubble| {
                bubble.child(caption("回答を待っています…"))
            })
            .when_some(guide.answer.as_ref(), |bubble, answer| {
                bubble.child(
                    div()
                        .id("guide-answer")
                        .flex_shrink_0()
                        .child(answer.clone()),
                )
            })
            .when(guide.question_open, |bubble| {
                bubble
                    .child(Input::new(&self.guide_question))
                    .when_some(guide.question_error.as_ref(), |bubble, error| {
                        bubble.child(caption(error.clone()))
                    })
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(button("guide-question-send", "送信").on_click(
                                cx.listener(|this, _, _, cx| this.submit_guide_question(cx)),
                            ))
                            .child(button("guide-question-cancel", "キャンセル").on_click(
                                cx.listener(|this, _, w, cx| {
                                    if let Some(guide) = this.guide.as_mut() {
                                        guide.question_open = false;
                                        guide.question_error = None;
                                    }
                                    if let Some(editor) = this.editor() {
                                        editor.update(cx, |input, cx| input.focus(w, cx));
                                    }
                                    cx.notify();
                                }),
                            )),
                    )
            })
            .child(
                div()
                    .flex()
                    .gap_2()
                    .when(self.guide_tour.as_ref().is_some_and(|t|t.overview.is_some()), |row|row.child(button("bubble-overview","概観").on_click(cx.listener(|this,_,w,cx|this.show_overview(w,cx)))))
                    .when(self.guide_tour.as_ref().is_some_and(|t|t.index>0), |row| row.child(
                        button("guide-back", "戻る").on_click(cx.listener(|this,_,w,cx|this.guide_step(-1,w,cx)))))
                    .child(
                        button("guide-next", if self.guide_tour.as_ref().is_some_and(|t|t.index+1==t.steps.len()) { "完了" } else if guide.pending_next.is_some() { "待機中…" } else { "次へ" }).on_click(
                            cx.listener(|this, _, w, cx| this.guide_step(1, w, cx)),
                        ),
                    )
                    .child(
                        button(
                            "guide-question",
                            if guide.question.is_some() {
                                "追加で質問"
                            } else {
                                "質問"
                            },
                        )
                        .on_click(cx.listener(|this, _, w, cx| this.open_guide_question(w, cx))),
                    )
                    .child(
                        button("guide-end", "終了")
                            .on_click(cx.listener(|this, _, _, cx| this.guide_response("end", cx))),
                    ),
            )
            .into_any_element()
    }

    pub fn attach_control(
        &mut self,
        server: readit::control::Server,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.control = Some(server);
        self.control_task = Some(cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(30))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| {
                        for _ in 0..4 {
                            let request = this
                                .control
                                .as_ref()
                                .and_then(|s| s.requests.try_recv().ok());
                            let Some(request) = request else {
                                break;
                            };
                            if !request.is_live() {
                                continue;
                            }
                            if request.call.method == "readit_symbol" {
                                this.control_symbol(request, window, cx);
                            } else {
                                let result = this.control_call(&request.call, window, cx);
                                let _ = request.reply.send(result);
                            }
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
    }
    fn control_scope(&self, arguments: &serde_json::Value) -> Result<(), String> {
        if arguments.get("workspace").and_then(|v| v.as_str()) != self.workspace.root.to_str() {
            return Err("workspace changed or does not match; call readit_state first".into());
        }
        Ok(())
    }
    fn control_path(&self, value: &str) -> Result<String, String> {
        let absolute = self.workspace.root.join(value);
        let key = absolute
            .strip_prefix(&self.workspace.root)
            .unwrap_or(&absolute)
            .to_string_lossy()
            .into_owned();
        if self.workspace.index_of(&key).is_some() {
            return Ok(key);
        }
        if self.control_target_root == self.workspace.root
            && self.control_targets.iter().any(|t| t.path == absolute)
        {
            return Ok(absolute.to_string_lossy().into_owned());
        }
        Err("path is not a workspace file or a definition returned by this editor".into())
    }
    fn control_text(&self, path: &str) -> Result<String, String> {
        if let Some(index) = self.workspace.index_of(path) {
            return Ok(self.workspace.documents[index].text.clone());
        }
        let path = self.workspace.root.join(path);
        if !path.is_file()
            || std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 1024 * 1024
        {
            return Err("external definition is not a supported text file".into());
        }
        std::fs::read_to_string(path).map_err(|e| e.to_string())
    }
    fn control_state(&mut self, cx: &mut Context<Self>) -> serde_json::Value {
        use serde_json::json;
        self.sync_buffers(cx);
        self.validate_guide(cx);
        let selection=self.editor().map(|editor| {
            let input=editor.read(cx); let text=input.value(); let range=input.selection_range();
            let start=ls::position_at(&text,range.start); let end=ls::position_at(&text,range.end);
            let viewport=input.visible_range().map(|r|json!({"start_line":ls::position_at(&text,r.start).line+1,"end_line":ls::position_at(&text,r.end.min(text.len())).line+1}));
            json!({"start_line":start.line+1,"start_column":start.character+1,"end_line":end.line+1,"end_column":end.character+1,
                "text":text.get(range.clone()).unwrap_or("").chars().take(16000).collect::<String>(),"truncated":text.get(range.clone()).unwrap_or("").chars().count()>16000,"viewport":viewport})
        });
        let pos = self.position(cx);
        json!({"workspace":self.workspace.root,"active_path":self.selected.as_ref().map(|p|self.workspace.root.join(p)),
            "cursor":{"line":pos.line+1,"column":pos.character+1},"selection":selection,
            "tabs":self.tabs.iter().map(|p|json!({"path":self.workspace.root.join(p),"dirty":self.workspace.index_of(p).is_some_and(|i|self.workspace.documents[i].dirty()),"read_only":self.external.contains(p)})).collect::<Vec<_>>(),
            "view":{"diff":self.compare,"file_tree":self.sidebar,"file_tree_width":self.sidebar_width,"wrap":self.wrap},
            "pinned":self.pinned.as_ref().map(|p|json!({"path":p.root.join(&p.path),"line":p.line,"source_changed":self.pinned_changed(cx),"read_only":true})),
            "guide":self.guide.as_ref().map(|g|json!({"id":g.id,"title":g.title,"question_open":g.question_open,"question":g.question,"pending_question":g.pending_question,"answer":g.answer,"pending_next":g.pending_next.is_some()})),"guide_event_sequence":self.guide_sequence,
            "overview_visible":self.overview_visible,
            "guide_tour":self.guide_tour.as_ref().map(|t|json!({"id":t.id,"index":t.index,"total":t.steps.len(),"visited_through":t.visited,"overview":t.overview,"seen_steps":t.seen,"steps":t.steps.iter().map(|g|json!({"id":g.id,"title":g.title})).collect::<Vec<_>>()})),
            "busy":self.nav_busy,"dialog_open":self.dialog.is_some()||self.pending.is_some()})
    }
    fn control_call(
        &mut self,
        call: &readit::control::Call,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<serde_json::Value, String> {
        use serde_json::json;
        let args = &call.arguments;
        if call.method == "readit_state" {
            return Ok(self.control_state(cx));
        }
        self.control_scope(args)?;
        self.sync_buffers(cx);
        let number = |key: &str, default: u64| -> Result<u64, String> {
            match args.get(key) {
                Some(v) => v
                    .as_u64()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| format!("{key} must be a positive integer")),
                None => Ok(default),
            }
        };
        let path_arg = || {
            args.get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "path is required".to_string())
        };
        match call.method.as_str() {
            "readit_pin" => {
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish the editor dialog first".into());
                }
                let path = self.control_path(path_arg()?)?;
                self.pin_code(path, number("line", 1)?, window, cx)?;
                Ok(self.control_state(cx))
            }
            "readit_unpin" => {
                self.pinned = None;
                cx.notify();
                Ok(self.control_state(cx))
            }
            "readit_guide_events" => {
                self.validate_guide(cx);
                let after = args
                    .get("after")
                    .and_then(|v| v.as_u64())
                    .ok_or("after is required")?;
                Ok(
                    json!({"events":self.guide_events.iter().filter(|e|e["sequence"].as_u64().unwrap_or(0)>after).collect::<Vec<_>>(),
                    "latest_sequence":self.guide_sequence,"truncated":self.guide_events.first().is_some_and(|e|after.saturating_add(1)<e["sequence"].as_u64().unwrap_or(0))}),
                )
            }
            "readit_guide_load" => {
                self.sync_buffers(cx);
                self.validate_guide(cx);
                if args.get("event_sequence").and_then(|v|v.as_u64())!=Some(self.guide_sequence){return Err("read guide events before loading".into());}
                let id=args.get("id").and_then(|v|v.as_str()).filter(|s|!s.is_empty() && s.len()<=128).ok_or("id required")?.to_string();
                let steps=self.prepare_steps(args,false)?;
                let overview=args.get("overview").map(|v|GuideOverview::parse(v,&steps)).transpose()?;
                self.activate_guide(steps[0].clone(),window,cx)?;
                let show_overview=overview.is_some();
                self.guide_tour=Some(GuideTour{id,steps,index:0,visited:0,overview,seen:BTreeSet::new()});
                self.overview_visible=show_overview; self.overview_tab=show_overview;
                if show_overview { self.focus.focus(window); }
                else {let tour=self.guide_tour.as_mut().unwrap();tour.seen.insert(tour.steps[0].id.clone());}
                Ok(self.control_state(cx))
            }
            "readit_guide_revise" => {
                self.sync_buffers(cx);
                self.validate_guide(cx);
                if self.dialog.is_some() || self.pending.is_some(){return Err("finish the editor dialog first".into());}
                if args.get("event_sequence").and_then(|v|v.as_u64())!=Some(self.guide_sequence){return Err("navigation changed; read state and regenerate the unread steps".into());}
                let steps=self.prepare_steps(args,true)?;
                let tour=self.guide_tour.as_ref().ok_or("tour ended")?;
                if args.get("id").and_then(|v|v.as_str())!=Some(tour.id.as_str()){return Err("tour changed".into());}
                let question=args.get("question_sequence").and_then(|v|v.as_u64()).ok_or("question_sequence required")?;
                let answer=args.get("answer").and_then(|v|v.as_str()).filter(|s|!s.trim().is_empty() && s.chars().count()<=4000).ok_or("answer required, max 4000 characters")?.to_string();
                let mut updated=tour.steps.clone();
                if let Some(guide)=&self.guide{updated[tour.index]=guide.clone();}
                let target=updated.iter().position(|g|g.pending_question==Some(question)).ok_or("question no longer pending")?;
                if self.control_text(&updated[target].path)?!=updated[target].source{return Err("question source changed".into());}
                let prefix=tour.visited+1;
                if prefix+steps.len()>32{return Err("tour exceeds 32 steps".into());}
                let mut ids=updated[..prefix].iter().map(|g|g.id.clone()).collect::<BTreeSet<_>>();
                for step in &steps {if !ids.insert(step.id.clone()){return Err("step id duplicates retained history".into());}}
                updated[target].answer=Some(answer);updated[target].pending_question=None;
                updated.truncate(prefix);updated.extend(steps);
                let overview=match args.get("overview") {
                    Some(value)=>Some(GuideOverview::parse(value,&updated)?),
                    None if tour.overview.is_some()=>return Err("include updated overview when revising a chaptered tour".into()),
                    None=>None,
                };
                let index=tour.index;
                if self.guide.is_some(){self.guide=Some(updated[index].clone());}
                let tour=self.guide_tour.as_mut().unwrap();
                tour.seen.retain(|id|updated.iter().any(|g|&g.id==id));
                tour.steps=updated; tour.overview=overview;
                cx.notify();
                Ok(self.control_state(cx))
            }
            "readit_guide_show" => {
                self.validate_guide(cx);
                let sequence = args
                    .get("event_sequence")
                    .and_then(|v| v.as_u64())
                    .ok_or("event_sequence is required")?;
                if sequence != self.guide_sequence {
                    return Err(
                        "user responded or moved; read guide events before continuing".into(),
                    );
                }
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish the editor dialog first".into());
                }
                let guide=self.prepare_guide(args)?;
                self.activate_guide(guide,window,cx)?;
                self.guide_tour=None; self.overview_visible=false; self.overview_tab=false;
                Ok(self.control_state(cx))
            }
            "readit_guide_answer" => {
                self.validate_guide(cx);
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish the editor dialog first".into());
                }
                let guide = self.guide.as_mut().ok_or("guide ended or source changed")?;
                let sequence = args
                    .get("question_sequence")
                    .and_then(|v| v.as_u64())
                    .ok_or("question_sequence is required")?;
                if args.get("id").and_then(|v| v.as_str()) != Some(guide.id.as_str())
                    || guide.pending_question != Some(sequence)
                {
                    return Err("question is no longer pending; read guide events".into());
                }
                let answer = args
                    .get("body")
                    .and_then(|v| v.as_str())
                    .ok_or("body is required")?;
                if answer.trim().is_empty() || answer.chars().count() > 4000 {
                    return Err("answer must contain 1..4000 characters".into());
                }
                guide.answer = Some(answer.to_string());
                guide.pending_question = None;
                self.guide_question
                    .update(cx, |input, cx| input.set_value("", window, cx));
                cx.notify();
                Ok(self.control_state(cx))
            }
            "readit_guide_clear" => {
                self.guide_response("cleared", cx);
                Ok(self.control_state(cx))
            }

            "readit_files" => {
                let filter = args
                    .get("filter")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_lowercase();
                let offset = args.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                let limit = number("limit", 200)?.min(500) as usize;
                let files = self
                    .workspace
                    .documents
                    .iter()
                    .filter(|d| {
                        !self.external.contains(&d.path)
                            && !self.untitled.contains(&d.path)
                            && d.path.to_lowercase().contains(&filter)
                    })
                    .collect::<Vec<_>>();
                Ok(
                    json!({"total":files.len(),"files":files.iter().skip(offset).take(limit).map(|d|json!({"path":d.path,"dirty":d.dirty(),"language":language(&d.path)})).collect::<Vec<_>>(),"next_offset":if offset.saturating_add(limit)<files.len(){Some(offset+limit)}else{None}}),
                )
            }
            "readit_read" => {
                let path = self.control_path(path_arg()?)?;
                let text = self.control_text(&path)?;
                let start = number("start_line", 1)? as usize;
                let count = number("line_count", 120)?.min(400) as usize;
                let lines = text.split('\n').collect::<Vec<_>>();
                if start > lines.len() {
                    return Err("start_line is outside the file".into());
                }
                let end = (start - 1 + count).min(lines.len());
                let content = lines[start - 1..end].join("\n");
                if content.len() > 200_000 {
                    return Err("requested lines are too large; request fewer lines".into());
                }
                Ok(
                    json!({"path":self.workspace.root.join(&path),"start_line":start,"end_line":end,"total_lines":lines.len(),"text":content,"unsaved":self.workspace.index_of(&path).is_some_and(|i|self.workspace.documents[i].dirty())}),
                )
            }
            "readit_search" => {
                let query = args
                    .get("query")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .ok_or("query must not be empty")?;
                let limit = number("limit", 100)?.min(300) as usize;
                let mut matches = vec![];
                let mut more = false;
                for doc in &self.workspace.documents {
                    if self.external.contains(&doc.path) {
                        continue;
                    }
                    for (line, text) in doc.text.lines().enumerate() {
                        for (column, _) in text.match_indices(query) {
                            if matches.len() == limit {
                                more = true;
                                break;
                            }
                            matches.push(json!({"path":doc.path,"line":line+1,"column":text[..column].encode_utf16().count()+1,"text":text.chars().take(500).collect::<String>()}));
                        }
                        if more {
                            break;
                        }
                    }
                    if more {
                        break;
                    }
                }
                Ok(json!({"matches":matches,"truncated":more,"kind":"literal text search"}))
            }
            "readit_open" => {
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish or dismiss the current editor dialog first".into());
                }
                let path = self.control_path(path_arg()?)?;
                let text = self.control_text(&path)?;
                let line = number("line", 1)?;
                let column = number("column", 1)?;
                let start = readit::control::offset_at(&text, line, column)?;
                let end_line = number("end_line", line)?;
                let end_column = number("end_column", column)?;
                let end = readit::control::offset_at(&text, end_line, end_column)?;
                if end < start {
                    return Err("selection end must follow its start".into());
                }
                if self.workspace.index_of(&path).is_none() {
                    self.workspace.documents.push(Document {
                        path: path.clone(),
                        text: text.clone(),
                        disk: text.clone(),
                        before: Some(text.clone()),
                    });
                    self.external.insert(path.clone());
                }
                self.open(&path, Some((line - 1) as usize), true, window, cx);
                self.pending_reveal = None;
                let editor = self.editor().ok_or("editor could not open the file")?;
                let end_position = ls::position_at(&text, end);
                editor.update(cx, |input, cx| {
                    input.set_cursor_position(
                        Position::new(end_position.line, end_position.character),
                        window,
                        cx,
                    );
                    input.select_to(start, cx);
                    input.reveal_offset(start, cx);
                    input.focus(window, cx);
                });
                let reader = cx.entity().downgrade();
                let selected = path.clone();
                window.on_next_frame(move |window, cx| {
                    let _ = reader.update(cx, |this, cx| {
                        if this.selected.as_ref() != Some(&selected) {
                            return;
                        }
                        editor.update(cx, |input, cx| {
                            if input.value().as_str() == text
                                && input.selection_range() == (start..end)
                            {
                                input.set_cursor_position(
                                    Position::new(end_position.line, end_position.character),
                                    window,
                                    cx,
                                );
                                input.select_to(start, cx);
                                input.reveal_offset(start, cx);
                            }
                        });
                    });
                });
                cx.notify();
                Ok(self.control_state(cx))
            }
            "readit_history" => {
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish the editor dialog first".into());
                }
                let forward = match args.get("direction").and_then(|v| v.as_str()) {
                    Some("back") => false,
                    Some("forward") => true,
                    _ => return Err("direction must be back or forward".into()),
                };
                self.navigate(forward, window, cx);
                Ok(self.control_state(cx))
            }
            "readit_view" => {
                if self.dialog.is_some() || self.pending.is_some() {
                    return Err("finish the editor dialog first".into());
                }
                for field in ["diff", "file_tree", "wrap", "overview"] {
                    if args.get(field).is_some_and(|v| !v.is_boolean()) {
                        return Err(format!("{field} must be boolean"));
                    }
                }
                if let Some(value)=args.get("overview").and_then(|v|v.as_bool()) {
                    if value && self.guide_tour.as_ref().is_none_or(|t|t.overview.is_none()) {return Err("no overview loaded".into());}
                    if value {self.show_overview(window,cx);} else {self.overview_visible=false;}
                }
                if let Some(value) = args.get("file_tree").and_then(|v| v.as_bool()) {
                    self.sidebar = value;
                }
                if let Some(value) = args.get("wrap").and_then(|v| v.as_bool()) {
                    if self.wrap != value {
                        self.toggle_wrap(&ToggleWrap, window, cx);
                    }
                }
                if let Some(value) = args.get("diff").and_then(|v| v.as_bool()) {
                    if self.compare != value {
                        self.toggle_compare(&Compare, window, cx);
                    }
                }
                self.clear_pointer(cx);
                cx.notify();
                Ok(self.control_state(cx))
            }
            _ => Err("unknown editor operation".into()),
        }
    }
    fn control_symbol(
        &mut self,
        request: readit::control::Request,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let prepare = (|| -> Result<(Query, Snapshot, bool), String> {
            self.control_scope(&request.call.arguments)?;
            self.sync_buffers(cx);
            if self.dialog.is_some() || self.pending.is_some() || self.nav_busy {
                return Err("editor has an active dialog or navigation request".into());
            }
            let args = &request.call.arguments;
            let query = match args.get("kind").and_then(|v| v.as_str()) {
                Some("definition") => Query::Definition,
                Some("references") => Query::References,
                Some("type_definition") => Query::TypeDefinition,
                Some("implementation") => Query::Implementation,
                Some("symbols") => Query::Symbols,
                Some("hover") => Query::Hover,
                _ => return Err("invalid symbol query kind".into()),
            };
            let path = self.selected.as_ref().ok_or("open a file first")?;
            if self.untitled.contains(path) {
                return Err("save the file with an extension first".into());
            }
            let input = self.editor().ok_or("no active editor")?;
            let input = input.read(cx);
            let snapshot = Snapshot {
                root: self.workspace.root.clone(),
                path: self.workspace.root.join(path),
                position: ls::position_at(&input.value(), input.cursor()),
                documents: self
                    .workspace
                    .documents
                    .iter()
                    .filter(|d| !self.untitled.contains(&d.path))
                    .map(|d| (self.workspace.root.join(&d.path), d.text.clone()))
                    .collect(),
            };
            Ok((
                query,
                snapshot,
                args.get("show").and_then(|v| v.as_bool()).unwrap_or(true),
            ))
        })();
        let (query, snapshot, show) = match prepare {
            Ok(value) => value,
            Err(error) => {
                let _ = request.reply.send(Err(error));
                return;
            }
        };
        let navigation_serial = self.nav_serial;
        let service = self.service.clone();
        let source = snapshot.clone();
        let cancelled = request.cancelled.clone();
        let (sender, receiver) = futures_channel::oneshot::channel();
        std::thread::spawn(move || {
            let answer = service
                .lock()
                .map_err(|_| "language service is unavailable".to_string())
                .and_then(|mut s| {
                    if cancelled.load(std::sync::atomic::Ordering::Relaxed) {
                        return Err("request cancelled".into());
                    }
                    s.query(query, source)
                });
            let _ = sender.send(answer);
        });
        cx.spawn_in(window,async move |this,cx| {
            let answer=receiver.await.unwrap_or_else(|_|Err("language service closed".into()));
            let _=this.update_in(cx,|this,_,cx| {
                if !request.is_live() {return;}
                this.sync_buffers(cx);
                let result=answer.and_then(|answer| {
                    let current_position = this.editor().map(|input| {
                        let input = input.read(cx);
                        ls::position_at(&input.value(), input.cursor())
                    });
                    if !this.snapshot_current(&snapshot)
                        || this.selected.as_ref().map(|p|this.workspace.root.join(p)) != Some(snapshot.path.clone())
                        || current_position != Some(snapshot.position)
                        || this.nav_serial != navigation_serial
                        || this.dialog.is_some() || this.pending.is_some() {
                        return Err("editor changed during analysis; read its state again".into());
                    }
                    this.control_target_root=this.workspace.root.clone();this.control_targets=answer.targets.clone();
                    let result=serde_json::json!({"server":answer.server,"targets":answer.targets.iter().map(|t|serde_json::json!({"path":t.path,"line":t.start.line+1,"column":t.start.character+1,"end_line":t.end.line+1,"end_column":t.end.character+1,"name":t.name,"preview":t.preview})).collect::<Vec<_>>(),"information":answer.information});
                    if show {
                        this.nav_title=query.title().into();this.nav_targets=answer.targets;
                        this.nav_information=if answer.information.is_empty(){format!("{}件 · {}",this.nav_targets.len(),answer.server)}else{answer.information};
                        this.nav_snapshot=Some(snapshot);this.nav_visible=true;cx.notify();
                    }
                    Ok(result)
                });let _=request.reply.send(result);
            });
        }).detach();
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
        self.analyze_at(query, jump, None, window, cx);
    }
    fn analyze_at(
        &mut self,
        query: Query,
        jump: bool,
        at: Option<ls::Position>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clear_pointer(cx);
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
        let position = at.unwrap_or_else(|| {
            ls::position_at(editor.read(cx).value().as_str(), editor.read(cx).cursor())
        });
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
        if self.overview_visible {self.overview_visible=false;self.overview_tab=false; if let Some(editor)=self.editor(){editor.update(cx,|i,cx|i.focus(window,cx));}cx.notify();return;}
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
        let offset=usize::from(self.overview_tab);
        let count=self.tabs.len()+offset;
        let index=if self.overview_visible {0} else {self.selected.as_ref().and_then(|p|self.tabs.iter().position(|s|s==p)).unwrap_or(0)+offset};
        let next=if forward {(index+1)%count}else{(index+count-1)%count};
        if self.overview_tab && next==0 {self.show_overview(window,cx);}
        else {self.open(&self.tabs[next-offset].clone(),None,true,window,cx);}
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
    #[cfg_attr(feature = "performance", profiling::function)]
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
                self.tree_scroll.scroll_to_item(i, ScrollStrategy::Top);
            }
        }
        cx.stop_propagation();
        cx.notify();
    }
    #[cfg_attr(feature = "performance", profiling::function)]
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
            .w(px(self.sidebar_width))
            .relative()
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
                    .flex_1()
                    .min_h_0()
                    .when(self.reading_path, |tree|tree.overflow_y_scroll())
                    .when(!self.reading_path, |tree| {
                        tree.child(uniform_list("file-tree-rows", entries.len(), cx.processor(move |this, range: std::ops::Range<usize>, _, cx| {
                        range.map(|i| {
                            let entry=entries[i].clone();
                            let path = entry.path.clone();
                            let right_path = path.clone();
                            let full_path = this
                                .workspace
                                .root
                                .join(&path)
                                .to_string_lossy()
                                .into_owned();
                            let menu_focus = this.explorer_focus.clone();
                            let folder = entry.file.is_none();
                            let active = this.tree_target.as_deref() == Some(path.as_str());
                            let badge = if this.dirty(&path) {
                                "●"
                            } else if this
                                .workspace
                                .index_of(&path)
                                .is_some_and(|i| this.workspace.documents[i].changed())
                            {
                                "M"
                            } else {
                                ""
                            };
                            let icon = if folder {
                                if this.collapsed.contains(&path) {
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
                                .tooltip(move |_, cx| {
                                    cx.new(|_| {
                                        gpui_component::tooltip::Tooltip::new(full_path.clone())
                                    })
                                    .into()
                                })
                                .h(px(29.))
                                .flex_shrink_0()
                                .min_w_0()
                                .overflow_hidden()
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
                                        .w(px((this.sidebar_width
                                            - 72.
                                            - entry.depth as f32 * 14.)
                                            .max(0.)))
                                        .flex_shrink_0()
                                        .overflow_hidden()
                                        .line_clamp(1)
                                        .text_ellipsis()
                                        .text_size(px(12.))
                                        .child(entry.name),
                                )
                                .child(
                                    div()
                                        .flex_shrink_0()
                                        .whitespace_nowrap()
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
                        }).collect::<Vec<_>>()
                        })).track_scroll(self.tree_scroll.clone()).h_full())
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
            .child(
                div()
                    .id("explorer-resize")
                    .absolute()
                    .right(px(0.))
                    .top(px(0.))
                    .bottom(px(0.))
                    .w(px(5.))
                    .cursor_col_resize()
                    .hover(|style| style.bg(rgb(ACCENT)))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &MouseDownEvent, _, cx| {
                            this.sidebar_drag = Some((event.position.x, this.sidebar_width));
                            cx.stop_propagation();
                        }),
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
            .when(self.overview_tab, |strip|strip.child(div().id("overview-tab").h_full().px_3().flex().gap_3().items_center().bg(rgb(if self.overview_visible {BG}else{PANEL})).cursor_pointer()
                .on_click(cx.listener(|this,_,w,cx|this.show_overview(w,cx)))
                .child("概観")
                .child(button("overview-close","×").on_click(cx.listener(|this,_,w,cx|{cx.stop_propagation();this.overview_tab=false;this.overview_visible=false;if let Some(e)=this.editor(){e.update(cx,|i,cx|i.focus(w,cx));}cx.notify();})))))
            .children(self.tabs.iter().enumerate().map(|(i, path)| {
                let name = path.rsplit('/').next().unwrap_or(path).to_string();
                let open_path = path.clone();
                let close_path = path.clone();
                let middle_path = path.clone();
                let selected = !self.overview_visible && self.selected.as_ref() == Some(path);
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
    #[cfg_attr(feature = "performance", profiling::function)]
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.validate_guide(cx);
        if self
            .pinned
            .as_ref()
            .is_some_and(|p| p.root != self.workspace.root)
        {
            self.pinned = None;
        }
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
            .on_mouse_move(cx.listener(|this,event: &MouseMoveEvent,w,cx| {
                if let Some(guide)=this.guide.as_mut() {
                    if let Some((start,origin))=guide.drag {
                        if event.pressed_button==Some(MouseButton::Left) {
                            guide.position=Some(origin+event.position-start);
                            this.clear_pointer(cx);cx.notify();return;
                        }
                        guide.drag=None;
                    }
                }
                if let Some((start,width))=this.sidebar_drag {
                    if event.pressed_button==Some(MouseButton::Left) {
                        this.sidebar_width=(width+f32::from(event.position.x-start)).clamp(180.,(f32::from(w.viewport_size().width)-320.).clamp(180.,700.));
                        this.clear_pointer(cx);cx.notify();return;
                    }
                    this.sidebar_drag=None;
                }
                if event.pressed_button.is_some() { this.clear_pointer(cx); }
                else if !this.overview_visible { this.update_pointer(event.position,event.modifiers.secondary(),w,cx); }
            }))
            .on_mouse_up(MouseButton::Left,cx.listener(|this,_,_,_| { this.sidebar_drag=None; if let Some(guide)=this.guide.as_mut() {guide.drag=None;} }))
            .on_modifiers_changed(cx.listener(|this,event: &ModifiersChangedEvent,w,cx| {
                if event.modifiers.secondary() { this.update_pointer(w.mouse_position(),true,w,cx); }
                else { this.clear_pointer(cx); }
            }))
            .on_scroll_wheel(cx.listener(|this,_,w,cx| { if !this.pointer_popup_bounds.is_some_and(|b| b.contains(&w.mouse_position())) { this.clear_pointer(cx); } }))
            .capture_action(cx.listener(|this,_: &gpui_component::input::Escape,w,cx| {
                this.guide_response("end",cx);
                if this.pointer_preview.is_some() {
                    this.clear_pointer(cx);
                    if let Some(editor) = this.editor() { editor.update(cx,|input,cx|input.focus(w,cx)); }
                }
            }))
            .capture_key_down(cx.listener(|this,event: &KeyDownEvent,_,cx| { if event.keystroke.key == "escape" { this.guide_response("end",cx); } if matches!(event.keystroke.key.as_str(), "escape" | "up" | "down" | "left" | "right" | "pageup" | "pagedown" | "home" | "end") { this.clear_pointer(cx); } }))
            .on_action(cx.listener(|this, _: &PinCode,w,cx|this.pin_current(w,cx)))
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
                .when(self.guide_tour.as_ref().is_some_and(|t|t.overview.is_some()), |bar|bar.child(button("show-overview","概観に戻る").on_click(cx.listener(|this,_,w,cx|this.show_overview(w,cx)))))
                .child(button("quick-open", "ファイルを開く…  ⌘P").on_click(cx.listener(|this, _, w, cx| this.show(Dialog::Quick, "", w, cx))))
                .child(div().flex().gap_2()
                    .child(button("open-folder", "フォルダを開く").on_click(cx.listener(|this, _, w, cx| this.pick_path(true, w, cx))))
                    .child(button("commands", "コマンド  ⇧⌘P").on_click(cx.listener(|this, _, w, cx| this.show(Dialog::Commands, "", w, cx))))))
            .child(div().flex_1().min_h_0().flex()
                .when(self.sidebar, |row| row.child(self.explorer(cx)))
                .child(div().flex_1().min_w_0().h_full().flex().flex_col()
                    .child(self.tab_strip(cx))
                    .when(self.overview_visible, |column|column.child(self.overview_panel(cx)))
                    .when(!self.overview_visible, |column|column
                    .child(div().min_h(px(38.)).py_2().px_4().gap_3().flex_shrink_0().flex().items_center().justify_between().border_b_1().border_color(rgb(BORDER))
                        .child(div().id("file-full-path").flex_1().min_w_0().overflow_x_scroll()
                            .child(caption(if path.is_empty() { "ファイルを選択してください".into() } else { path.clone() }).whitespace_nowrap()))
                        .child(div().flex().gap_2().when(!path.is_empty(), |bar| bar
                            .child(button("save", "保存  ⌘S").on_click(cx.listener(|this, _, w, cx| this.save(&Save, w, cx))))
                            .child(button("compare", if self.compare { "編集に戻る" } else { "差分" }).on_click(cx.listener(|this, _, w, cx| this.toggle_compare(&Compare, w, cx)))))))
                    .child(div().h(px(33.)).px_3().flex_shrink_0().flex().gap_2().items_center().border_b_1().border_color(rgb(BORDER))
                        .child(button("nav-back", "←").on_click(cx.listener(|this,_,w,cx| this.navigate(false,w,cx))))
                        .child(button("nav-forward", "→").on_click(cx.listener(|this,_,w,cx| this.navigate(true,w,cx))))
                        .child(button("nav-definition", "定義 F12").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Definition,true,w,cx))))
                        .child(button("nav-references", "使用箇所 ⇧F12").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::References,false,w,cx))))
                        .child(button("nav-symbols", "シンボル ⇧⌘O").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Symbols,false,w,cx))))
                        .child(button("pin-code", "横に固定").on_click(cx.listener(|this,_,w,cx|this.pin_current(w,cx))))
                        .child(button("nav-hover", "型・説明").on_click(cx.listener(|this,_,w,cx| this.analyze(Query::Hover,false,w,cx))))
                        .when(self.external.contains(&path), |bar|bar.child(caption("外部定義 · 閲覧専用"))))
                    .child(div().flex_1().min_h_0().min_w_0().overflow_hidden()
                        .on_mouse_up(MouseButton::Left,cx.listener(|this,event: &MouseUpEvent,w,cx| { if event.modifiers.secondary() && !this.compare { if let Some((_,_,position)) = this.pointer_symbol(event.position,cx) { this.analyze_at(Query::Definition,true,Some(position),w,cx); } } }))
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
                        })).track_scroll(self.diff_scroll.clone()).h_full()))))
                )
                .when(self.pinned.is_some() && !self.overview_visible,|row|row.child(self.pinned_panel(cx))))
            .when(self.nav_visible, |root| root.child(self.navigation_panel(cx)))
            .child(div().h(px(29.)).flex_shrink_0().px_3().flex().items_center().justify_between().bg(rgb(PANEL)).border_t_1().border_color(rgb(BORDER))
                .child(caption(self.message.clone()))
                .child(caption(format!("Ln {}, Col {}  ·  {}  ·  UTF-8  ·  {}", position.line + 1, position.character + 1, language(&path), if self.wrap { "Wrap" } else { "No wrap" }))))
            .when(!overlay && !self.overview_visible && self.guide.is_none(), |root| root.child(self.pointer_overlay(window,cx)))
            .when(!overlay && !self.overview_visible && !self.compare, |root| root.child(self.guide_overlay(window,cx)))
            .when(overlay, |root| root.child(div().absolute().inset_0().bg(rgba(0x00000070)).flex().items_start().justify_center()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(self.overlay(cx))))
    }
}

#[cfg(test)]
mod pointer_tests {
    use super::guide_placement;
    use gpui::Bounds;
    use super::{Position, Reader, Target, Workspace, ls};
    use gpui::{AppContext, Modifiers, TestAppContext, point, px, size};

    #[test]
    fn guide_avoids_multiline_annotation_and_clamps_drag_position() {
        let viewport=size(px(1000.),px(800.));
        for (top,bottom) in [(200.,400.),(550.,740.),(20.,650.)] {
            let anchor=Bounds::from_corners(point(px(260.),px(top)),point(px(780.),px(bottom)));
            let (origin,extent)=guide_placement(anchor,viewport,px(250.),None);
            assert!(origin.y+extent.height <= anchor.top() || origin.y >= anchor.bottom());
            assert!(origin.y >= px(0.) && origin.y+extent.height <= viewport.height);
            let (moved,extent)=guide_placement(anchor,viewport,px(250.),Some(point(px(-90.),px(900.))));
            assert!(moved.x >= px(0.) && moved.y+extent.height <= viewport.height);
        }
    }

    #[test]
    fn manually_placed_guide_uses_actual_height_and_ignores_scrolling_anchor() {
        let viewport = size(px(1400.), px(1200.));
        let requested = point(px(320.), px(850.));
        for top in [-600., 20., 900.] {
            let anchor = Bounds::new(point(px(300.), px(top)), size(px(600.), px(100.)));
            let (origin, _) = guide_placement(anchor, viewport, px(240.), Some(requested));
            assert_eq!(origin, requested);
            let (bottom, extent) = guide_placement(anchor, viewport, px(240.), Some(point(px(320.), px(2000.))));
            assert_eq!(bottom.y + extent.height, viewport.height - px(12.));
        }
    }

    #[gpui::test]
    fn overview_preserves_tour_across_detours_and_validates_chapters(cx: &mut TestAppContext) {
        let directory=tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("sample.py"),"one = 1\ntwo = 2\n").unwrap();
        std::fs::write(directory.path().join("other.py"),"other = 3\n").unwrap();
        let workspace=Workspace::load(directory.path()).unwrap();
        let root=workspace.root.clone();
        cx.update(|cx|{gpui_component::init(cx);crate::commands::init(cx);});
        let mut reader=None;
        let (_,cx)=cx.add_window_view(|w,cx|{
            let view=cx.new(|cx|Reader::new(workspace,false,w,cx));reader=Some(view.clone());
            gpui_component::Root::new(view,w,cx)
        });
        let reader=reader.unwrap();
        cx.simulate_resize(size(px(1120.),px(700.)));
        cx.update(|w,cx|reader.update(cx,|this,cx|{
            let steps=serde_json::json!([
                {"id":"one","title":"代入","body":"最初の値", "path":"sample.py","line":1,"column":1,"expected_text":"one = 1"},
                {"id":"two","title":"次の値","body":"次の代入", "path":"sample.py","line":2,"column":1,"expected_text":"two = 2"}]);
            let overview=serde_json::json!({"title":"値の定義","summary":"二つの値を読む","relationships":"sample.py → 値の定義", "chapters":[
                {"title":"最初","summary":"最初の代入を確認","start_step":"one"},
                {"title":"次","summary":"次の代入を確認","start_step":"two"}]});
            let load=|overview|readit::control::Call{method:"readit_guide_load".into(),arguments:serde_json::json!({"workspace":root,"id":"overview-tour","event_sequence":0,"steps":steps,"overview":overview})};
            let mut bad=overview.clone();bad["chapters"][1]["start_step"]="missing".into();
            assert!(this.control_call(&load(bad),w,cx).is_err());
            assert!(this.guide_tour.is_none());
            let mut bad=overview.clone();bad["chapters"][0]["start_step"]="two".into();
            assert!(this.control_call(&load(bad),w,cx).is_err());
            this.control_call(&load(overview),w,cx).unwrap();
            assert!(this.overview_visible);
            this.guide_step(1,w,cx); // Jump directly into the second chapter.
            assert!(!this.overview_visible);
            assert_eq!(this.guide.as_ref().unwrap().id,"two");
            assert_eq!(this.guide_tour.as_ref().unwrap().seen.len(),1);
            this.open("other.py",None,true,w,cx);
            this.validate_guide(cx);
            assert!(this.guide.is_none());
            assert!(this.guide_tour.is_some());
            this.show_overview(w,cx);
            assert!(this.overview_visible);
            this.guide_step(0,w,cx); // Resume a paused chapter.
            assert_eq!(this.guide.as_ref().unwrap().id,"two");
            this.guide_step(1,w,cx); // Completing the tour keeps its overview.
            assert!(this.guide.is_none());
            assert!(this.guide_tour.is_some());
            this.show_overview(w,cx);
            this.guide_step(-1,w,cx);
            this.open_guide_question(w,cx);
            this.guide_question.update(cx,|i,cx|i.set_value("この値は？",w,cx));
            this.submit_guide_question(cx);
            let seq=this.guide_sequence;
            let mut revise=readit::control::Call{method:"readit_guide_revise".into(),arguments:serde_json::json!({"workspace":root,"id":"overview-tour","event_sequence":seq,"question_sequence":seq,"answer":"最初の値です","steps":[]})};
            assert!(this.control_call(&revise,w,cx).is_err());
            revise.arguments["overview"]=serde_json::to_value(this.guide_tour.as_ref().unwrap().overview.as_ref().unwrap()).unwrap();
            this.control_call(&revise,w,cx).unwrap();
            assert!(this.guide.as_ref().unwrap().answer.is_some());
            this.editor().unwrap().update(cx,|i,cx|i.set_value("changed",w,cx));
            this.show_overview(w,cx);
            this.guide_step(1,w,cx);
            assert!(this.overview_visible); // Stale target cannot replace the visible overview.
            assert!(this.guide.is_none());
            this.guide_response("cleared",cx);
            assert!(this.guide_tour.is_none());
            assert!(!this.overview_visible);
        }));
        cx.run_until_parked();
    }

    #[gpui::test]
    fn prepared_tour_navigates_offline_and_revises_unread_steps_atomically(cx: &mut TestAppContext) {
        let directory=tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("sample.py"),"one = 1\ntwo = 2\nthree = 3\n").unwrap();
        let workspace=Workspace::load(directory.path()).unwrap();
        let root=workspace.root.clone();
        cx.update(|cx|{gpui_component::init(cx);crate::commands::init(cx);});
        let mut reader=None;
        let (_,cx)=cx.add_window_view(|w,cx|{
            let view=cx.new(|cx|Reader::new(workspace,false,w,cx));reader=Some(view.clone());
            gpui_component::Root::new(view,w,cx)
        });
        let reader=reader.unwrap();
        cx.simulate_resize(size(px(1420.),px(900.)));
        cx.update(|w,cx|reader.update(cx,|this,cx|{
            let step=|id:&str,line:u64,text:&str|serde_json::json!({"id":id,"title":id,"body":"解説", "path":"sample.py","line":line,"column":1,"expected_text":text});
            let steps=serde_json::json!([step("one",1,"one = 1"),step("two",2,"two = 2"),step("three",3,"three = 3")]);
            let load=|steps|readit::control::Call{method:"readit_guide_load".into(),arguments:serde_json::json!({"workspace":root,"id":"tour","event_sequence":0,"steps":steps})};
            let mut invalid=steps.clone();invalid[2]["expected_text"]="stale".into();
            assert!(this.control_call(&load(invalid),w,cx).is_err());
            assert!(this.guide_tour.is_none());
            this.control_call(&load(steps),w,cx).unwrap();
            this.guide_step(1,w,cx);
            assert_eq!(this.guide.as_ref().unwrap().id,"two");
            assert!(this.guide.as_ref().unwrap().pending_next.is_none());
            this.open_guide_question(w,cx);
            this.guide_question.update(cx,|input,cx|input.set_value("なぜ2なの？",w,cx));
            this.submit_guide_question(cx);
            let question=this.guide_sequence;
            this.guide_step(-1,w,cx); // Pending generation does not prevent reading history.
            assert_eq!(this.guide.as_ref().unwrap().id,"one");
            let revise=|sequence,steps|readit::control::Call{method:"readit_guide_revise".into(),arguments:serde_json::json!({"workspace":root,"id":"tour","event_sequence":sequence,"question_sequence":question,"answer":"2はこの例で代入した値です。","steps":steps})};
            let replacement=serde_json::json!([step("revised",3,"three = 3")]);
            assert!(this.control_call(&revise(question,replacement.clone()),w,cx).is_err());
            let mut invalid=replacement.clone();invalid[0]["expected_text"]="stale".into();
            assert!(this.control_call(&revise(this.guide_sequence,invalid),w,cx).is_err());
            assert_eq!(this.guide_tour.as_ref().unwrap().steps[2].id,"three");
            this.control_call(&revise(this.guide_sequence,replacement.clone()),w,cx).unwrap();
            assert_eq!(this.guide_tour.as_ref().unwrap().index,0);
            this.guide_step(1,w,cx);
            assert!(this.guide.as_ref().unwrap().answer.is_some());
            this.guide_step(1,w,cx);
            assert_eq!(this.guide.as_ref().unwrap().id,"revised");
            this.guide_step(1,w,cx);
            assert!(this.guide.is_none() && this.guide_tour.is_none());
            assert!(this.control_call(&revise(this.guide_sequence,replacement),w,cx).is_err());
        }));
        cx.run_until_parked();
    }

    #[gpui::test]
    fn control_reveals_ranges_reads_unsaved_buffers_and_respects_user_context(
        cx: &mut TestAppContext,
    ) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(
            directory.path().join("sample.py"),
            "first = 1\nsecond = first + 1\n",
        )
        .unwrap();
        let workspace = Workspace::load(directory.path()).unwrap();
        let root = workspace.root.to_string_lossy().into_owned();
        cx.update(|cx| {
            gpui_component::init(cx);
            crate::commands::init(cx);
        });
        let mut reader = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let view = cx.new(|cx| Reader::new(workspace, false, window, cx));
            reader = Some(view.clone());
            gpui_component::Root::new(view, window, cx)
        });
        let reader = reader.unwrap();
        cx.simulate_resize(size(px(1420.), px(900.)));
        let call = |method: &str, arguments: serde_json::Value| readit::control::Call {
            method: method.into(),
            arguments,
        };
        cx.update(|window,cx|reader.update(cx,|this,cx| {
            let result=this.control_call(&call("readit_open",serde_json::json!({"workspace":root,"path":"sample.py","line":2,"column":10,"end_line":2,"end_column":15})),window,cx).unwrap();
            assert_eq!(result["selection"]["text"],"first");
            assert_eq!(result["cursor"]["line"],2);
            assert!(this.control_call(&call("readit_open",serde_json::json!({"workspace":"/wrong-project","path":"sample.py"})),window,cx).is_err());
            assert!(this.control_call(&call("readit_read",serde_json::json!({"workspace":root,"path":"/etc/passwd"})),window,cx).is_err());
        }));
        cx.run_until_parked();
        cx.update(|window,cx|reader.update(cx,|this,cx| {
            assert_eq!(this.control_state(cx)["selection"]["text"],"first");
            let editor=this.editor().unwrap();
            editor.update(cx,|input,cx|input.set_value("first = 1\nsecond = first + 2\n",window,cx));
            let result=this.control_call(&call("readit_read",serde_json::json!({"workspace":root,"path":"sample.py","start_line":2,"line_count":1})),window,cx).unwrap();
            assert_eq!(result["text"],"second = first + 2");
            assert_eq!(result["unsaved"],true);
            this.dialog=Some(super::Dialog::Quick);
            assert!(this.control_call(&call("readit_open",serde_json::json!({"workspace":root,"path":"sample.py"})),window,cx).is_err());
            assert!(this.dialog.is_some());
        }));
        assert_eq!(
            std::fs::read_to_string(directory.path().join("sample.py")).unwrap(),
            "first = 1\nsecond = first + 1\n"
        );
    }

    #[gpui::test]
    fn pin_preserves_navigation_and_tracks_unsaved_changes(cx: &mut TestAppContext) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("main.py"), "value = 1\n").unwrap();
        std::fs::write(
            directory.path().join("related.py"),
            "def related():\n    return 2\n",
        )
        .unwrap();
        let workspace = Workspace::load(directory.path()).unwrap();
        let root = workspace.root.clone();
        cx.update(|cx| {
            gpui_component::init(cx);
            crate::commands::init(cx);
        });
        let mut reader = None;
        let (_, cx) = cx.add_window_view(|w, cx| {
            let view = cx.new(|cx| Reader::new(workspace, false, w, cx));
            reader = Some(view.clone());
            gpui_component::Root::new(view, w, cx)
        });
        let reader = reader.unwrap();
        cx.simulate_resize(size(px(1420.), px(900.)));
        cx.update(|w, cx| {
            reader.update(cx, |this, cx| {
                this.open("main.py", None, true, w, cx);
                let selected = this.selected.clone();
                let cursor = this.position(cx);
                let call = |method: &str, path: &str| readit::control::Call {
                    method: method.into(),
                    arguments: serde_json::json!({"workspace":root,"path":path,"line":1}),
                };
                this.control_call(&call("readit_pin", "related.py"), w, cx)
                    .unwrap();
                assert_eq!(this.selected, selected);
                assert_eq!(this.position(cx), cursor);
                assert!(
                    this.control_call(&call("readit_pin", "/etc/passwd"), w, cx)
                        .is_err()
                );
                this.editor()
                    .unwrap()
                    .update(cx, |input, cx| input.set_value("value = 3\n", w, cx));
                this.control_call(&call("readit_pin", "main.py"), w, cx)
                    .unwrap();
                assert_eq!(this.pinned.as_ref().unwrap().source, "value = 3\n");
                this.editor()
                    .unwrap()
                    .update(cx, |input, cx| input.set_value("value = 4\n", w, cx));
                assert!(this.pinned_changed(cx));
                assert_eq!(
                    this.pinned
                        .as_ref()
                        .unwrap()
                        .input
                        .read(cx)
                        .value()
                        .as_str(),
                    "value = 3\n"
                );
                this.control_call(&call("readit_pin", "main.py"), w, cx)
                    .unwrap();
                assert!(!this.pinned_changed(cx));
                this.control_call(&call("readit_unpin", ""), w, cx).unwrap();
                assert!(this.pinned.is_none());
                assert_eq!(
                    this.editor().unwrap().read(cx).value().as_str(),
                    "value = 4\n"
                );
            })
        });
        cx.run_until_parked();
        assert_eq!(
            std::fs::read_to_string(directory.path().join("main.py")).unwrap(),
            "value = 1\n"
        );
    }

    #[gpui::test]
    fn control_reveals_distant_lines_after_initial_layout(cx: &mut TestAppContext) {
        let directory = tempfile::tempdir().unwrap();
        let text = (0..400)
            .map(|i| format!("value_{i} = {i}\n"))
            .collect::<String>();
        std::fs::write(directory.path().join("long.py"), text).unwrap();
        let workspace = Workspace::load(directory.path()).unwrap();
        let root = workspace.root.clone();
        cx.update(|cx| {
            gpui_component::init(cx);
            crate::commands::init(cx);
        });
        let mut reader = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let view = cx.new(|cx| Reader::new(workspace, false, window, cx));
            reader = Some(view.clone());
            gpui_component::Root::new(view, window, cx)
        });
        let reader = reader.unwrap();
        cx.simulate_resize(size(px(1420.), px(900.)));
        cx.update(|window,cx|reader.update(cx,|this,cx|{
            this.control_call(&readit::control::Call{method:"readit_open".into(),arguments:serde_json::json!({"workspace":root,"path":"long.py","line":300,"column":1,"end_line":300,"end_column":10})},window,cx).unwrap();
            this.pin_code("long.py".into(), 200, window, cx).unwrap();
        }));
        cx.run_until_parked();
        cx.update(|_, cx| {
            reader.update(cx, |this, cx| {
                let state = this.control_state(cx);
                let viewport = &state["selection"]["viewport"];
                assert!(viewport["start_line"].as_u64().unwrap() <= 300, "{state}");
                assert!(viewport["end_line"].as_u64().unwrap() >= 300, "{state}");
                assert_eq!(state["selection"]["text"], "value_299");
                let pinned = this.pinned.as_ref().unwrap();
                let visible = pinned.input.read(cx).visible_range().unwrap();
                let offset = readit::control::offset_at(&pinned.source, 200, 1).unwrap();
                assert!(visible.contains(&offset), "pinned viewport: {visible:?}, target: {offset}");
            })
        });
    }

    #[gpui::test]
    fn guide_checks_source_and_tracks_user_responses(cx: &mut TestAppContext) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("sample.py"), "value = 42\n").unwrap();
        let workspace = Workspace::load(directory.path()).unwrap();
        let root = workspace.root.clone();
        cx.update(|cx| {
            gpui_component::init(cx);
            crate::commands::init(cx);
        });
        let mut reader = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let view = cx.new(|cx| Reader::new(workspace, false, window, cx));
            reader = Some(view.clone());
            gpui_component::Root::new(view, window, cx)
        });
        let reader = reader.unwrap();
        cx.simulate_resize(size(px(1420.), px(900.)));
        cx.update(|window,cx| reader.update(cx,|this,cx| {
            let mut args=serde_json::json!({"workspace":root,"id":"step-1","title":"値の代入","body":"valueに42を代入します。","path":"sample.py","line":1,"column":1,"expected_text":"value = 42","event_sequence":0});
            let show=|arguments|readit::control::Call{method:"readit_guide_show".into(),arguments};
            this.control_call(&show(args.clone()),window,cx).unwrap();
            assert_eq!(this.control_state(cx)["selection"]["text"],"value = 42");
            this.open_guide_question(window,cx);
            this.submit_guide_question(cx);
            assert_eq!(this.guide_sequence,0); // Blank questions stay in the form.
            this.guide_question.update(cx,|input,cx|input.set_value("なぜ42なのですか？",window,cx));
            this.submit_guide_question(cx);
            this.submit_guide_question(cx); // A repeated click cannot submit twice.
            assert_eq!(this.guide_sequence,1);
            assert!(this.guide.is_some());
            assert!(this.control_call(&show(args.clone()),window,cx).is_err());
            let events=this.control_call(&readit::control::Call{method:"readit_guide_events".into(),arguments:serde_json::json!({"workspace":root,"after":0})},window,cx).unwrap();
            assert_eq!(events["events"][0]["action"],"question");
            assert_eq!(events["events"][0]["question"],"なぜ42なのですか？");
            assert_eq!(events["events"][0]["expected_text"],"value = 42");
            let answer=|sequence|readit::control::Call{method:"readit_guide_answer".into(),arguments:serde_json::json!({"workspace":root,"id":"step-1","question_sequence":sequence,"body":"このテストの例として置いた値です。"})};
            assert!(this.control_call(&answer(9),window,cx).is_err());
            this.control_call(&answer(1),window,cx).unwrap();
            assert_eq!(this.guide.as_ref().unwrap().question.as_deref(),Some("なぜ42なのですか？"));
            this.open_guide_question(window,cx);
            this.guide_question.update(cx,|input,cx|input.set_value("43にしても動きますか？",window,cx));
            this.submit_guide_question(cx);
            assert!(this.control_call(&answer(1),window,cx).is_err());
            assert_eq!(this.guide_events.last().unwrap()["previous_question"],"なぜ42なのですか？");
            this.control_call(&answer(2),window,cx).unwrap();
            this.guide_response("next",cx);
            assert!(this.guide.as_ref().unwrap().pending_next.is_some());
            let next_sequence=this.guide_sequence;
            this.guide_response("next",cx);
            assert_eq!(this.guide_sequence,next_sequence);
            this.open_guide_question(window,cx);
            assert!(!this.guide.as_ref().unwrap().question_open);
            assert!(this.control_call(&answer(2),window,cx).is_err());
            args["event_sequence"]=3.into();args["expected_text"]="wrong".into();
            assert!(this.control_call(&show(args.clone()),window,cx).is_err());
            args["expected_text"]="value = 42".into();
            this.control_call(&show(args),window,cx).unwrap();
            this.editor().unwrap().update(cx,|input,cx|input.set_value("value = 43\n",window,cx));
            this.validate_guide(cx);
            assert!(this.guide.is_none());
            assert_eq!(this.guide_events.last().unwrap()["action"],"interrupted");
            this.control_call(&show(serde_json::json!({"workspace":root,"id":"escape","title":"終了テスト","body":"Escで終了","path":"sample.py","line":1,"column":1,"expected_text":"value = 43","event_sequence":this.guide_sequence})),window,cx).unwrap();
        }));
        cx.run_until_parked();
        cx.simulate_keystrokes("escape");
        cx.update(|_, cx| {
            let this = reader.read(cx);
            assert!(this.guide.is_none());
            assert_eq!(this.guide_events.last().unwrap()["action"], "end");
        });

        assert_eq!(
            std::fs::read_to_string(directory.path().join("sample.py")).unwrap(),
            "value = 42\n"
        );
    }

    #[gpui::test]
    fn pointer_navigation_preserves_cursor_and_cancels_stale_previews(cx: &mut TestAppContext) {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(
            directory.path().join("source.py"),
            "def total(value):\n    return value\n\nresult = total(5)\n",
        )
        .unwrap();
        let external = tempfile::tempdir().unwrap();
        let external_path = external.path().join("builtins.pyi");
        std::fs::write(&external_path, "# fixture\nclass int:\n    pass\n").unwrap();
        let workspace = Workspace::load(directory.path()).unwrap();
        cx.update(|cx| {
            gpui_component::init(cx);
            crate::commands::init(cx);
        });
        let mut reader = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let view = cx.new(|cx| Reader::new(workspace, false, window, cx));
            reader = Some(view.clone());
            gpui_component::Root::new(view, window, cx)
        });
        let reader = reader.unwrap();
        cx.simulate_resize(size(px(1420.), px(900.)));
        cx.run_until_parked();
        let (position, original) = cx.update(|_, cx| {
            let this = reader.read(cx);
            let input = this.editor().unwrap();
            let input = input.read(cx);
            let text = input.value();
            let offset = text.rfind("total").unwrap();
            let bounds = input.range_to_bounds(&(offset..offset + 1)).unwrap();
            (
                point(bounds.left() + px(2.), bounds.top() + px(2.)),
                input.cursor(),
            )
        });
        cx.simulate_mouse_move(position, None, Modifiers::none());
        cx.update(|_, cx| {
            let this = reader.read(cx);
            assert!(!this.pointer_preview.as_ref().unwrap().definition);
            assert_eq!(this.editor().unwrap().read(cx).cursor(), original);
        });
        let command = Modifiers {
            platform: true,
            ..Modifiers::none()
        };
        cx.simulate_modifiers_change(command);
        let old_serial = cx.update(|_, cx| {
            let this = reader.read(cx);
            assert!(this.pointer_preview.as_ref().unwrap().definition);
            assert_eq!(this.editor().unwrap().read(cx).cursor(), original);
            this.pointer_serial
                .load(std::sync::atomic::Ordering::Relaxed)
        });
        cx.simulate_modifiers_change(Modifiers::none());
        cx.update(|_, cx| {
            let this = reader.read(cx);
            assert!(this.pointer_preview.is_none());
            assert!(
                this.pointer_serial
                    .load(std::sync::atomic::Ordering::Relaxed)
                    > old_serial
            );
        });
        cx.simulate_mouse_move(point(px(20.), position.y), None, command);
        cx.update(|_, cx| assert!(reader.read(cx).pointer_preview.is_none()));
        cx.simulate_mouse_move(position, None, command);
        cx.simulate_event(gpui::ScrollWheelEvent {
            position,
            delta: gpui::ScrollDelta::Pixels(point(px(0.), px(-10.))),
            ..Default::default()
        });
        cx.update(|_, cx| assert!(reader.read(cx).pointer_preview.is_none()));
        cx.simulate_mouse_move(position, None, command);
        cx.simulate_keystrokes("escape");
        cx.update(|_, cx| assert!(reader.read(cx).pointer_preview.is_none()));
        cx.simulate_mouse_move(position, None, command);
        cx.update(|_, cx| {
            reader.update(cx, |this, cx| {
                let preview = this.pointer_preview.as_mut().unwrap();
                preview.targets = vec![Target {
                    path: external_path.canonicalize().unwrap(),
                    start: ls::Position {
                        line: 1,
                        character: 6,
                    },
                    end: ls::Position {
                        line: 1,
                        character: 9,
                    },
                    name: "int".into(),
                    detail: String::new(),
                    preview: String::new(),
                }];
                preview.information = "class int".into();
                cx.notify();
            })
        });
        cx.run_until_parked();
        cx.simulate_click(position, command);
        cx.update(|_, cx| {
            let this = reader.read(cx);
            let path = this.selected.as_ref().unwrap();
            assert_eq!(
                path,
                &external_path.canonicalize().unwrap().to_string_lossy()
            );
            assert!(this.external.contains(path));
            assert_eq!(this.position(cx), Position::new(1, 6));
        });
    }
}

#[cfg(test)]
#[path = "ui_e2e_tests.rs"]
mod ui_e2e_tests;
