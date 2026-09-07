mod commands;
mod ui;
use gpui::*;
use readit::workspace::Workspace;
use std::path::PathBuf;

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "--help") {
        println!(
            "Readit — code reading prototype\n\nreadit [repository-directory]\nreadit --demo\n\nNo AI service or code execution. Review notes are stored in <directory>/.readit/session.json."
        );
        return;
    }
    let demo = args.is_empty() || args[0] == "--demo";
    let root = if demo {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("demo")
    } else {
        PathBuf::from(&args[0])
    };
    let workspace = match Workspace::load(&root) {
        Ok(ws) => ws,
        Err(e) => {
            eprintln!("Readit: {e}");
            std::process::exit(1)
        }
    };
    for warning in &workspace.warnings {
        eprintln!("{warning}");
    }
    Application::new()
        .with_assets(gpui_component_assets::Assets)
        .run(move |cx: &mut App| {
            gpui_component::init(cx);
            gpui_component::Theme::change(gpui_component::ThemeMode::Dark, None, cx);
            commands::init(cx);
            let bounds = Bounds::centered(None, size(px(1420.), px(900.)), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(TitlebarOptions {
                        title: Some("Readit — コードを理解する".into()),
                        ..Default::default()
                    }),
                    window_min_size: Some(size(px(1120.), px(700.))),
                    ..Default::default()
                },
                |window, cx| {
                    let view = cx.new(|cx| ui::Reader::new(workspace, demo, window, cx));
                    let weak = view.downgrade();
                    window.on_window_should_close(cx, move |window, cx| {
                        weak.update(cx, |view, cx| view.request_quit(window, cx))
                            .ok();
                        false
                    });
                    cx.new(|cx| gpui_component::Root::new(view, window, cx))
                },
            )
            .expect("ウィンドウを開けませんでした");
            cx.activate(true);
        });
}
