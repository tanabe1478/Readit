mod commands;
#[cfg(feature = "performance")]
mod performance;
mod ui;
use gpui::*;
use readit::workspace::Workspace;
use std::path::PathBuf;

fn main() {
    #[cfg(feature = "performance")]
    performance::init();
    let mut socket = None;
    let mut directory = None;
    let mut demo = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                println!(
                    "Readit — code reading editor\n\nreadit [repository-directory] [--control-socket /private/directory/control.sock]\nreadit --demo\n\nA local MCP client can guide the visible editor when --control-socket is set."
                );
                return;
            }
            "--control-socket" => {
                socket = Some(PathBuf::from(args.next().unwrap_or_else(|| {
                    eprintln!("--control-socket requires a path");
                    std::process::exit(2)
                })));
            }
            "--demo" => demo = true,
            value if !value.starts_with('-') && directory.is_none() => {
                directory = Some(PathBuf::from(value))
            }
            _ => {
                eprintln!("unknown argument: {arg}");
                std::process::exit(2);
            }
        }
    }
    if demo && directory.is_some() {
        eprintln!("choose --demo or a repository directory");
        std::process::exit(2);
    }
    demo = demo || directory.is_none();
    let root = directory.unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("demo"));
    let control = socket.map(|path| {
        let server = readit::control::Server::bind(&path).unwrap_or_else(|error| {
            eprintln!("Readit control: {error}");
            std::process::exit(2)
        });
        eprintln!("Readit control socket: {}", path.display());
        server
    });
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
                    let view = cx.new(|cx| {
                        let mut reader = ui::Reader::new(workspace, demo, window, cx);
                        if let Some(server) = control {
                            reader.attach_control(server, window, cx);
                        }
                        reader
                    });
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
