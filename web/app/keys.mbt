// Keyboard shortcuts. Descriptors look like "cmd-shift-p"; the glue builds them.

///|
/// Shortcuts that work anywhere in the window.
let global_keys : Map[String, String] = {
  "f12": "definition",
  "alt-f12": "peek-definition",
  "cmd-f12": "type-definition",
  "cmd-shift-f12": "implementation",
  "shift-f12": "references",
  "cmd-shift-o": "symbols",
  "cmd-q": "quit",
  "ctrl-q": "quit",
  "cmd-s": "save",
  "cmd-alt-s": "save-all",
  "cmd-shift-s": "save-as",
  "cmd-n": "new",
  "ctrl-n": "new",
  "cmd-o": "open",
  "cmd-w": "close",
  "ctrl-w": "close",
  "cmd-shift-t": "reopen",
  "ctrl-shift-t": "reopen",
  "ctrl-tab": "next-tab",
  "ctrl-shift-tab": "previous-tab",
  "cmd-shift-]": "next-tab",
  "cmd-shift-[": "previous-tab",
  "cmd-alt-right": "next-tab",
  "cmd-alt-left": "previous-tab",
  "cmd-p": "quick-open",
  "cmd-shift-p": "commands",
  "cmd-shift-f": "find-all",
  "ctrl-g": "goto",
  "cmd-f": "find",
  "cmd-alt-f": "replace",
  "cmd-b": "sidebar",
  "alt-z": "wrap",
  "cmd-shift-e": "focus-explorer",
  "cmd-r": "reload",
  "cmd-alt-d": "compare",
  "cmd-=": "zoom-in",
  "cmd-shift-=": "zoom-in",
  "cmd--": "zoom-out",
  "cmd-0": "reset-zoom",
  "ctrl--": "back",
  "ctrl-shift--": "forward",
}

///|
/// Second keys after ⌘K.
let chord_keys : Map[String, String] = {
  "cmd-p": "pin-code",
  "cmd-o": "open-folder",
  "cmd-w": "close-all",
  "cmd-i": "hover",
}

///|
fn run_key_command(command : String) -> Unit {
  match command {
    "quick-open" => show(Quick, "")
    "commands" => show(Commands, "")
    _ => run_command(command)
  }
}

///|
/// Handle a key press. True when handled, so the browser default is suppressed.
fn on_key(desc : String, target : String) -> Bool {
  // Any key hides the hover preview; Escape also ends a guide.
  if desc == "escape" {
    guide_response("end")
  }
  match desc {
    "escape"
    | "up"
    | "down"
    | "left"
    | "right"
    | "pageup"
    | "pagedown"
    | "home"
    | "end" => clear_pointer()
    _ => ()
  }
  if reader.menu is Some(_) || reader.context_menu is Some(_) {
    if desc == "escape" {
      reader.menu = None
      reader.context_menu = None
      return true
    }
  }
  if reader.pending is Some(_) {
    if desc == "escape" {
      dismiss()
    }
    return desc == "escape" || desc == "enter"
  }
  if reader.chord is Some(_) {
    reader.chord = None
    if chord_keys.get(desc) is Some(command) {
      run_key_command(command)
    }
    return true
  }
  if desc == "cmd-k" {
    reader.chord = Some(desc)
    return true
  }
  if reader.dialog is Some(dialog) && target == "dialog-query" {
    match desc {
      "escape" => {
        dismiss()
        return true
      }
      "enter" if dialog != Replace => {
        accept()
        return true
      }
      "up" | "down" if is_picker(dialog) => {
        let count = picks().length()
        reader.pick_index = if desc == "up" {
          (reader.pick_index - 1).max(0)
        } else {
          (reader.pick_index + 1).min((count - 1).max(0))
        }
        return true
      }
      _ => ()
    }
  }
  if reader.dialog is Some(_) && desc == "escape" {
    dismiss()
    return true
  }
  if global_keys.get(desc) is Some(command) {
    run_key_command(command)
    return true
  }
  match target {
    "guide-question" =>
      match desc {
        "enter" => {
          submit_guide_question()
          true
        }
        "escape" => {
          cancel_guide_question()
          true
        }
        _ => false
      }
    "search-input" =>
      match desc {
        "enter" => {
          search_step(true)
          true
        }
        "shift-enter" => {
          search_step(false)
          true
        }
        "escape" => {
          reader.search_open = false
          focus_editor()
          true
        }
        _ => false
      }
    "editor" => editor_key(desc)
    "explorer" => explorer_key(desc)
    _ =>
      match desc {
        "alt-left" => {
          navigate(false)
          true
        }
        "alt-right" => {
          navigate(true)
          true
        }
        "escape" => {
          dismiss()
          true
        }
        _ => false
      }
  }
}

///|
fn page_lines() -> Int {
  (js_client_height("editor-scroll") / line_height()).floor().to_int().max(1)
}

///|
fn editor_key(desc : String) -> Bool {
  guard current_editor() is Some(ed) else { return false }
  let before = ed.version
  let handled = match desc {
    "left" => {
      ed.move_cursor(Left)
      true
    }
    "right" => {
      ed.move_cursor(Right)
      true
    }
    "up" => {
      ed.move_cursor(Up)
      true
    }
    "down" => {
      ed.move_cursor(Down)
      true
    }
    "shift-left" => {
      ed.move_cursor(Left, selecting=true)
      true
    }
    "shift-right" => {
      ed.move_cursor(Right, selecting=true)
      true
    }
    "shift-up" => {
      ed.move_cursor(Up, selecting=true)
      true
    }
    "shift-down" => {
      ed.move_cursor(Down, selecting=true)
      true
    }
    "alt-left" => {
      ed.move_cursor(WordLeft)
      true
    }
    "alt-right" => {
      ed.move_cursor(WordRight)
      true
    }
    "alt-shift-left" => {
      ed.move_cursor(WordLeft, selecting=true)
      true
    }
    "alt-shift-right" => {
      ed.move_cursor(WordRight, selecting=true)
      true
    }
    "cmd-left" | "home" | "ctrl-a" => {
      ed.move_cursor(LineStart)
      true
    }
    "cmd-right" | "end" | "ctrl-e" => {
      ed.move_cursor(LineEnd)
      true
    }
    "cmd-shift-left" | "shift-home" => {
      ed.move_cursor(LineStart, selecting=true)
      true
    }
    "cmd-shift-right" | "shift-end" => {
      ed.move_cursor(LineEnd, selecting=true)
      true
    }
    "cmd-up" | "cmd-home" => {
      ed.move_cursor(DocStart)
      true
    }
    "cmd-down" | "cmd-end" => {
      ed.move_cursor(DocEnd)
      true
    }
    "cmd-shift-up" => {
      ed.move_cursor(DocStart, selecting=true)
      true
    }
    "cmd-shift-down" => {
      ed.move_cursor(DocEnd, selecting=true)
      true
    }
    "pageup" => {
      ed.move_cursor(PageUp(page_lines()))
      true
    }
    "pagedown" => {
      ed.move_cursor(PageDown(page_lines()))
      true
    }
    "shift-pageup" => {
      ed.move_cursor(PageUp(page_lines()), selecting=true)
      true
    }
    "shift-pagedown" => {
      ed.move_cursor(PageDown(page_lines()), selecting=true)
      true
    }
    "enter" => {
      ignore(ed.newline())
      true
    }
    "backspace" | "shift-backspace" => {
      ignore(ed.backspace(Char))
      true
    }
    "alt-backspace" => {
      ignore(ed.backspace(Word))
      true
    }
    "cmd-backspace" => {
      ignore(ed.backspace(Line))
      true
    }
    "delete" => {
      ignore(ed.delete_forward(Char))
      true
    }
    "alt-delete" => {
      ignore(ed.delete_forward(Word))
      true
    }
    "cmd-delete" => {
      ignore(ed.delete_forward(Line))
      true
    }
    "tab" | "cmd-]" => {
      ignore(ed.indent())
      true
    }
    "shift-tab" | "cmd-[" => {
      ignore(ed.outdent())
      true
    }
    "cmd-a" => {
      ed.select_all()
      true
    }
    "cmd-z" => {
      ignore(ed.undo())
      true
    }
    "cmd-shift-z" | "cmd-y" => {
      ignore(ed.redo())
      true
    }
    _ => false
  }
  if handled {
    if ed.version != before {
      document_changed()
    }
    request_reveal(ed.line_of(ed.head), 0)
  }
  handled
}

///|
fn explorer_key(desc : String) -> Bool {
  match desc {
    "f2" => {
      run_command("rename")
      return true
    }
    "cmd-backspace" => {
      run_command("delete")
      return true
    }
    "cmd-shift-backspace" => {
      run_command("restore")
      return true
    }
    _ => ()
  }
  let entries = tree_entries()
  if entries.length() == 0 {
    return false
  }
  let mut index = 0
  if reader.tree_target is Some(t) {
    for i, entry in entries {
      if entry.path == t {
        index = i
        break
      }
    }
  }
  let target = entries[index]
  match desc {
    "up" => reader.tree_target = Some(entries[(index - 1).max(0)].path)
    "down" =>
      reader.tree_target = Some(
        entries[(index + 1).min(entries.length() - 1)].path,
      )
    "left" =>
      if target.file is None {
        reader.collapsed[target.path] = ()
      } else if @core.parent_of(target.path) != "" {
        reader.tree_target = Some(@core.parent_of(target.path))
      }
    "right" => if target.file is None { reader.collapsed.remove(target.path) }
    "enter" =>
      if target.file is Some(_) {
        open(target.path, None, true)
      } else if reader.collapsed.contains(target.path) {
        reader.collapsed.remove(target.path)
      } else {
        reader.collapsed[target.path] = ()
      }
    _ => return false
  }
  // Keep the target row in view.
  let list = tree_entries()
  if reader.tree_target is Some(t) {
    for i, entry in list {
      if entry.path == t {
        let y = i.to_double() * tree_row_height
        let top = js_scroll_top("tree-scroll")
        let h = js_client_height("tree-scroll")
        if y < top {
          js_set_scroll_top("tree-scroll", y)
        } else if y + tree_row_height > top + h {
          js_set_scroll_top("tree-scroll", y + tree_row_height - h)
        }
      }
    }
  }
  true
}
