# Readit local patch

Source: crates.io gpui-component 0.5.1 (Apache-2.0).
Only `src/input/state.rs` is modified:

- `index_for_mouse_position` and `range_to_bounds` are public for non-mutating definition hover hit testing with the actual editor layout.
- `select_to` is public for selecting a source range via the control API.
- `selection_range` and `visible_range` expose UTF-8 byte ranges for state inspection.

The original license is retained in LICENSE-APACHE. The patch does not copy Zed's editor or language engine.

- `reveal_offset`: reveal a UTF-8 offset after layout while preserving the selection, for MCP navigation in long files.

`reveal_offset` queues initial navigation until line heights and viewport bounds are available. `input/element.rs` consumes that request before computing visible lines. Subsequent navigation uses the existing layout.

`reveal_at_top` places a guide anchor two text rows below the editor top during prepaint, using the current line layout. It preserves selection and leaves room for the explanation below the selected code.
