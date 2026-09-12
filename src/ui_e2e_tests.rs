//! UI journey tests: real Reader layout, hit testing and platform input dispatch.
//! The test platform replaces the OS window; editor and guide are not mocked.
use super::{Reader, Workspace};
use gpui::{AppContext, Bounds, Modifiers, MouseButton, Pixels, Point, TestAppContext, VisualTestContext, point, px, size};

fn settle(cx: &mut VisualTestContext) {
    cx.run_until_parked();
    // Geometry measurement intentionally schedules a second layout frame.
    for _ in 0..4 {
        cx.update(|window, _| window.refresh());
        cx.run_until_parked();
    }
}

fn bubble(cx: &mut VisualTestContext) -> Bounds<Pixels> {
    settle(cx);
    cx.debug_bounds("reading-guide").expect("guide must be painted")
}

fn drag_to(cx: &mut VisualTestContext, destination: Point<Pixels>) {
    let handle = cx.debug_bounds("guide-drag-handle").expect("drag handle must be painted");
    let origin = bubble(cx).origin;
    let start = handle.center();
    let end = start + destination - origin;
    cx.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
    cx.simulate_mouse_move(end, MouseButton::Left, Modifiers::none());
    cx.simulate_mouse_up(end, MouseButton::Left, Modifiers::none());
    settle(cx);
}

#[gpui::test]
fn guide_scroll_then_drag_to_bottom_e2e(cx: &mut TestAppContext) {
    run_scroll_drag_journey(cx, false);
}

#[gpui::test]
fn guide_native_repro_journey_e2e(cx: &mut TestAppContext) {
    run_scroll_drag_journey(cx, true);
}

fn run_scroll_drag_journey(cx: &mut TestAppContext, native_repro: bool) {
    let directory = tempfile::tempdir().unwrap();
    let source: String = (1..=160).map(|n| format!("value_{n} = {n}\n")).collect();
    std::fs::write(directory.path().join("sample.py"), &source).unwrap();
    let workspace = Workspace::load(directory.path()).unwrap();
    let root = workspace.root.clone();
    cx.update(|cx| { gpui_component::init(cx); crate::commands::init(cx); });
    let mut reader = None;
    let (_, cx) = cx.add_window_view(|window, cx| {
        let view = cx.new(|cx| Reader::new(workspace, false, window, cx));
        reader = Some(view.clone());
        gpui_component::Root::new(view, window, cx)
    });
    let reader = reader.unwrap();
    cx.simulate_resize(size(px(1400.), px(1000.)));
    cx.update(|window, cx| reader.update(cx, |this, cx| {
        this.control_call(&readit::control::Call {
            method: "readit_guide_load".into(),
            arguments: serde_json::json!({"workspace":root,"id":"scroll-drag","event_sequence":0,
                "steps":[{"id":"one","path":"sample.py","line":40,"column":1,
                    "expected_text":"value_40 = 40\nvalue_41 = 41\nvalue_42 = 42",
                    "title":"Read these three assignments","body":"Each line binds a value.\n\nScroll the source, then drag this explanation."}]}),
        }, window, cx).unwrap();
    }));
    let initial = bubble(cx);
    assert!(initial.size.height < px(400.), "fixture must exercise a short bubble");
    if native_repro {
        // Native repro: place the bubble, scroll, move it up, then drag down.
        drag_to(cx, point(px(650.), px(700.)));
        let before = cx.update(|_, cx| reader.update(cx, |this, cx| this.control_state(cx))["selection"]["viewport"].clone());
        cx.simulate_event(gpui::ScrollWheelEvent {
            position: point(px(1250.), px(650.)),
            delta: gpui::ScrollDelta::Pixels(point(px(0.), px(-100.))),
            ..Default::default()
        });
        settle(cx);
        let after = cx.update(|_, cx| reader.update(cx, |this, cx| this.control_state(cx))["selection"]["viewport"].clone());
        assert_ne!(before, after, "native repro must scroll the editor");
    } else {
    // Reproduce the user's sequence: scroll before touching the bubble.
    cx.simulate_event(gpui::ScrollWheelEvent {
        position: point(px(1250.), px(650.)),
        delta: gpui::ScrollDelta::Pixels(point(px(0.), px(-150.))),
        ..Default::default()
    });
    let scrolled = bubble(cx);
    assert_ne!(initial.origin, scrolled.origin, "automatic guide must follow the scrolling annotation");
    }
    let viewport_before = cx.update(|_, cx| reader.update(cx, |this, cx| this.control_state(cx))["selection"]["viewport"].clone());
    drag_to(cx, point(px(650.), px(30.)));
    let pinned = bubble(cx);
    assert!((pinned.top() - px(30.)).abs() < px(3.), "title drag must actually move the bubble");
    cx.simulate_event(gpui::ScrollWheelEvent {
        position: point(px(1250.), px(650.)),
        delta: gpui::ScrollDelta::Pixels(point(px(0.), px(-100.))),
        ..Default::default()
    });
    let after_scroll = bubble(cx);
    let viewport_after = cx.update(|_, cx| reader.update(cx, |this, cx| this.control_state(cx))["selection"]["viewport"].clone());
    assert_ne!(viewport_before, viewport_after, "wheel input must scroll the real editor");
    assert_eq!(after_scroll.origin, pinned.origin, "scrolling must preserve manual position");
    let destination = point(px(650.), px(1000.) - after_scroll.size.height - px(30.));
    drag_to(cx, destination);
    let moved = bubble(cx);
    assert!((moved.top() - destination.y).abs() < px(3.),
        "short bubble must follow the pointer to the bottom: actual={moved:?}, requested={destination:?}");
    assert!(moved.bottom() <= px(1000.));
    cx.update(|_, cx| {
        let state = reader.update(cx, |this, cx| this.control_state(cx));
        assert_eq!(state["selection"]["text"], "value_40 = 40\nvalue_41 = 41\nvalue_42 = 42");
        assert!(state["tabs"].as_array().unwrap().iter().all(|t| t["dirty"] == false));
    });
    assert_eq!(std::fs::read_to_string(directory.path().join("sample.py")).unwrap(), source);
}
