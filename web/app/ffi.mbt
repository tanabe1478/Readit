// Imports provided by www/glue.js. Strings cross as JS strings (js-string builtins).

///|
/// Replace a region's HTML. The glue skips unchanged regions.
fn js_set_html(id : String, html : String) = "dom" "set_html"

///|
fn js_set_style(id : String, property : String, value : String) = "dom" "set_style"

///|
fn js_set_class(id : String, name : String, on : Bool) = "dom" "set_class"

///|
fn js_focus(id : String) = "dom" "focus"

///|
fn js_has_focus(id : String) -> Bool = "dom" "has_focus"

///|
fn js_set_value(id : String, value : String) = "dom" "set_value"

///|
fn js_get_value(id : String) -> String = "dom" "get_value"

///|
fn js_select_input(id : String) = "dom" "select_input"

///|
fn js_scroll_top(id : String) -> Double = "dom" "scroll_top"

///|
fn js_set_scroll_top(id : String, value : Double) = "dom" "set_scroll_top"

///|
fn js_client_height(id : String) -> Double = "dom" "client_height"

///|
fn js_client_width(id : String) -> Double = "dom" "client_width"

///|
/// Bounding box of an element by id: "left,top,width,height", or "".
fn js_rect(id : String) -> String = "dom" "rect"

///|
/// Box of [start, end) on a rendered line of a code view, or "".
fn js_range_rect(view : String, line : Int, start : Int, end : Int) -> String = "dom" "range_rect"

///|
/// Keep the hidden input next to the caret for IME.
fn js_place_input() = "dom" "place_input"

///|
fn js_scroll_into_view(id : String) = "dom" "scroll_into_view"

///|
fn js_viewport_width() -> Double = "dom" "viewport_width"

///|
fn js_viewport_height() -> Double = "dom" "viewport_height"

///|
fn js_set_title(text : String) = "dom" "set_title"

///|
fn js_rpc(id : Int, op : String, body : String) = "app" "rpc"

///|
fn js_set_timer(id : Int, ms : Int) = "app" "set_timer"

///|
fn js_clear_timer(id : Int) = "app" "clear_timer"

///|
fn js_now() -> Double = "app" "now"

///|
fn js_log(text : String) = "app" "log"

///|
fn js_clipboard_write(text : String) = "app" "clipboard_write"

///|
/// Read the clipboard and deliver it as a "paste" event.
fn js_clipboard_read() = "app" "clipboard_read"

///|
/// All matches of a JavaScript regular expression as "start,end;..." or "!message".
fn js_regex_find(text : String, pattern : String, flags : String) -> String = "app" "regex_find"

///|
/// Parse (incrementally) a document for highlighting. False while the grammar loads.
fn js_ts_update(key : String, language : String, text : String) -> Bool = "app" "ts_update"

///|
/// Highlight spans for [from, to) lines: "line,start,end,class;...".
fn js_ts_tokens(key : String, from : Int, to : Int) -> String = "app" "ts_tokens"

///|
fn js_ts_drop(key : String) = "app" "ts_drop"

///|
fn js_confirm_leave(dirty : Bool) = "app" "confirm_leave"

///|
fn js_close_window() = "app" "close_window"
