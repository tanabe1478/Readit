// Floating layers: the ⌘ hover preview and the guide bubble.

///|
fn js_natural_height(id : String) -> Double = "dom" "natural_height"

///|
/// Keep automatic placement outside the whole annotation, not just its first line.
fn guide_placement(
  anchor : Rect,
  vw : Double,
  vh : Double,
  height : Double,
  manual : (Double, Double)?,
  beside? : Double = 0.0,
) -> (Double, Double, Double, Double) {
  let margin = 12.0
  let width = 430.0.min((vw - margin * 2.0).max(1.0))
  let height = height.min((vh - margin * 2.0).max(1.0))
  let left = anchor.left.max(margin).min((vw - width - margin).max(margin))
  if manual is Some((x, y)) {
    return (
      x.max(margin).min((vw - width - margin).max(margin)),
      y.max(margin).min((vh - height - margin).max(margin)),
      width,
      height,
    )
  }
  // Beside the code first, so the lines after the annotation stay readable:
  // to the right of the annotation and of the code block that follows it.
  let beside = anchor.right().max(beside) + 16.0
  if beside + width + margin <= vw {
    let top = anchor.top.max(margin)
    return (beside, top, width, height.min((vh - margin - top).max(1.0)))
  }
  let above = (anchor.top - margin - 8.0).max(0.0)
  let below = (vh - margin - anchor.bottom() - 8.0).max(0.0)
  if below >= height || below >= above {
    // Bottom right, so the lines right after the annotation stay visible.
    let h = height.min(below - 28.0).max(1.0)
    ((vw - width - margin).max(margin), vh - margin - 28.0 - h, width, h)
  } else {
    let h = height.min(above)
    (left, anchor.top - 8.0 - h, width, h)
  }
}

///|
/// Right edge of the code the reader looks at next: the annotated lines and
/// the dozen visible lines after them.
fn guide_block_right(guide : Guide) -> Double {
  guard current_editor() is Some(ed) else { return 0.0 }
  guard viewport_lines() is Some((first, last)) else { return 0.0 }
  let a = ed.line_of(guide.start.max(ed.line_start(first - 1)))
  let b = ed.line_of(@core.prev_char(ed.text, guide.end.min(ed.line_end(last - 1))))
  js_rows_right("editor", a, (b + 12).min(last - 1))
}

///|
/// Screen box of the visible part of the guide's range, if any is rendered.
fn guide_anchor(guide : Guide) -> Rect? {
  guard current_editor() is Some(ed) else { return None }
  guard viewport_lines() is Some((first, last)) else { return None }
  let start = guide.start.max(ed.line_start(first - 1))
  let end = guide.end.min(ed.line_end(last - 1))
  if start >= end {
    return None
  }
  let a = ed.line_of(start)
  let b = ed.line_of(@core.prev_char(ed.text, end))
  let first_box = Rect::parse(
    js_range_rect(
      "editor",
      a,
      start - ed.line_start(a),
      start - ed.line_start(a),
    ),
  )
  let last_char = @core.prev_char(ed.text, end)
  let last_box = Rect::parse(
    js_range_rect(
      "editor",
      b,
      last_char - ed.line_start(b),
      last_char - ed.line_start(b),
    ),
  )
  match (first_box, last_box) {
    (Some(f), Some(l)) => Some(f.union(l))
    (Some(f), None) => Some(f)
    (None, Some(l)) => Some(l)
    _ => None
  }
}

///|
priv struct GuideView {
  style : String
  main : String
  /// The prediction input; kept apart so redraws keep what the reader typed.
  predict : String
  form : String
  after : String
  key : String
}

///|
fn render_guide() -> GuideView? {
  guard reader.guide is Some(guide) else { return None }
  if reader.compare || reader.overview_visible || dialog_open() {
    return None
  }
  let anchor = guide_anchor(guide)
  // A manually placed bubble belongs to the viewport, including while its code
  // is offscreen. Automatic bubbles only follow visible source.
  if anchor is None && guide.position is None {
    return None
  }
  let anchor = anchor.unwrap_or({
    left: 12.0,
    top: 12.0,
    width: 1.0,
    height: 1.0,
  })
  let vw = js_viewport_width()
  let vh = js_viewport_height()
  let recorded = match (reader.tour, guide.kind) {
    (Some(t), "prediction") => tour_prediction(t, guide.id)
    (Some(t), "verification") =>
      match guide.verifies {
        Some(v) => tour_prediction(t, v)
        None => None
      }
    _ => None
  }
  let pending = match reader.tour {
    Some(t) => prediction_pending(t, guide)
    None => false
  }
  let recorded_key = match recorded {
    Some(r) => "\{r.status}:\{r.answer.unwrap_or("")}"
    None => ""
  }
  let key = "\{guide.id}|\{guide.kind}|\{recorded_key}|\{guide.prediction_error.unwrap_or("")}|\{guide.title}|\{guide.body}|\{guide.question.unwrap_or("")}|\{guide.answer.unwrap_or("")}|\{guide.question_open}|\{guide.question_error.unwrap_or("")}|\{guide.pending_question is Some(_)}|\{guide.pending_next is Some(_)}|\{vw}"
  let preferred = if reader.guide_height_key == key && reader.guide_height > 0.0 {
    reader.guide_height
  } else {
    (vh - 200.0).max(80.0)
  }
  let (left, top, width, _) = guide_placement(
    anchor,
    vw,
    vh,
    preferred,
    guide.position,
    beside=guide_block_right(guide),
  )
  let max_height = if guide.position is Some(_) {
    (vh - 24.0).max(1.0)
  } else if left >= anchor.right() {
    (vh - top - 20.0).max(1.0)
  } else if top >= anchor.bottom() {
    (vh - anchor.bottom() - 20.0).max(1.0)
  } else {
    (anchor.top - 20.0).max(1.0)
  }
  let out = StringBuilder()
  let progress = match reader.tour {
    Some(t) => "\{t.index + 1}/\{t.steps.length()} · "
    None => ""
  }
  out.write_string(
    "<div class=\"guide-handle\" data-drag=\"guide\">\{caption("\{progress}\{guide.title} · ドラッグで移動")}</div>",
  )
  let kind_label = match guide.kind {
    "hypothesis" => "仮説"
    "prediction" => "予測"
    "verification" => "検証"
    _ => ""
  }
  if kind_label != "" {
    out.write_string(
      "<span class=\"guide-kind kind-\{guide.kind}\">\{kind_label}</span>",
    )
  }
  // The reader's own words, shown as written. Readit never grades them.
  let prior = (title : String) => {
    let text = match recorded {
      Some({ answer: Some(a), .. }) => "「\{a}」"
      Some(_) => "わからない"
      None => "予測は記録されていません。"
    }
    "<div class=\"guide-prior\">\{caption(title)}<div class=\"guide-prior-text\">\{e(text)}</div></div>"
  }
  if guide.kind == "verification" {
    out.write_string(prior("あなたの予測"))
    out.write_string(caption("実際のコード"))
  }
  out.write_string("<div class=\"guide-body\">\{e(guide.body)}</div>")
  if guide.prompt is Some(prompt) {
    out.write_string("<div class=\"guide-prompt\">\{e(prompt)}</div>")
    if recorded is Some(_) {
      out.write_string(prior("あなたの予測"))
    }
  }
  if guide.prediction_error is Some(err) && pending {
    out.write_string(caption(err))
  }
  if !guide.question_open && guide.question_error is Some(err) {
    out.write_string(caption(err))
  }
  if guide.question is Some(q) {
    out.write_string("<div class=\"guide-question-text\">質問: \{e(q)}</div>")
  }
  if reader.tour is Some(t) && t.overview is Some(o) {
    let mut title = ""
    for c in o.chapters {
      for j, g in t.steps {
        if g.id == c.start_step && j <= t.index {
          title = c.title
        }
      }
    }
    if title != "" {
      out.write_string(caption("章: \{title}"))
    }
  }
  if guide.pending_next is Some(started) {
    out.write_string(
      caption(
        if js_now() - started >= 10000.0 {
          "応答が届いていません。AI側でガイドを再開してください。"
        } else {
          "次の解説を待っています…"
        },
      ),
    )
  }
  if guide.pending_question is Some(_) {
    out.write_string(
      caption(
        "回答を待っています… AIが接続していなければ、チャットで質問への対応を依頼してください。",
      ),
    )
  }
  if guide.answer is Some(a) {
    out.write_string("<div class=\"guide-answer\">\{e(a)}</div>")
  }
  let predict = match reader.tour {
    Some(t) if pending =>
      "<textarea id=\"guide-prediction\" class=\"input\" rows=\"3\" data-step=\"\{e(t.id)}/\{e(guide.id)}\" placeholder=\"自分の予測を書く（Enterで記録、⇧Enterで改行）\"></textarea><div class=\"row-buttons\">\{button("prediction-record", "予測を記録")}\{button("prediction-unknown", "わからない")}</div>"
    _ => ""
  }
  let form = if guide.question_open {
    "<textarea id=\"guide-question\" class=\"input\" rows=\"2\" placeholder=\"どの点が気になりますか？\"></textarea>"
  } else {
    ""
  }
  let after_form = StringBuilder()
  if guide.question_open {
    if guide.question_error is Some(err) {
      after_form.write_string(caption(err))
    }
    after_form.write_string(
      "<div class=\"row-buttons\">\{button("guide-send", "送信")}\{button("guide-cancel", "キャンセル")}</div>",
    )
  }
  let row = StringBuilder()
  row.write_string("<div class=\"row-buttons\">")
  if reader.tour is Some(t) && t.overview is Some(_) {
    row.write_string(button("overview", "概観"))
  }
  if reader.tour is Some(t) && t.index > 0 {
    row.write_string(button("guide-back", "戻る"))
  }
  let next_label = match reader.tour {
    Some(t) if t.index + 1 == t.steps.length() => "完了"
    _ => if guide.pending_next is Some(_) { "待機中…" } else { "次へ" }
  }
  row.write_string(
    button(
      "guide-next",
      next_label,
      disabled=if pending {
        "予測を記録するか「わからない」を選ぶと進めます"
      } else {
        ""
      },
    ),
  )
  row.write_string(
    button(
      "guide-ask",
      if guide.question is Some(_) {
        "追加で質問"
      } else {
        "質問"
      },
    ),
  )
  row.write_string(button("guide-end", "終了"))
  row.write_string("</div>")
  Some({
    style: "left:\{px(left)};top:\{px(top)};width:\{px(width)};max-height:\{px(max_height)}",
    main: out.to_string(),
    predict,
    form,
    after: after_form.to_string() + row.to_string(),
    key,
  })
}

///|
fn render_pointer() -> String {
  reader.popup = None
  guard reader.pointer is Some(preview) else { return "" }
  if preview.information == "" && preview.targets.length() == 0 {
    return ""
  }
  if dialog_open() || reader.overview_visible || reader.guide is Some(_) {
    return ""
  }
  let vw = js_viewport_width()
  let vh = js_viewport_height()
  let width = 610.0.min(vw - 20.0)
  let left = preview.rect.left.max(10.0).min(vw - width - 10.0)
  let lines = @core.split_newlines(preview.information).length().max(1)
  let has_definition = preview.definition && preview.targets.length() > 0
  let desired = if has_definition {
    350.0
  } else {
    (lines.to_double() * 18.0 + 32.0).clamp(min=70.0, max=240.0)
  }
  let height = desired.min(vh - 40.0)
  let top = if preview.rect.bottom() + height < vh - 20.0 {
    preview.rect.bottom()
  } else {
    (preview.rect.top - height).max(10.0)
  }
  reader.popup = Some({ left, top, width, height, })
  let out = StringBuilder()
  if has_definition {
    let r = preview.rect
    out.write_string(
      "<div class=\"link-underline\" data-act=\"pointer-jump\" style=\"left:\{px(r.left)};top:\{px(r.top)};width:\{px(r.width)};height:\{px(r.height)}\"></div>",
    )
  }
  out.write_string(
    "<div class=\"pointer\" id=\"pointer\" style=\"left:\{px(left)};top:\{px(top)};width:\{px(width)};height:\{px(height)}\"><div class=\"pointer-content\"><div class=\"pointer-info\">\{e(preview.information)}</div>",
  )
  if has_definition {
    let target = preview.targets[0]
    let snippet = @core.split_newlines(target.preview)
      .map(line => @core.slice(line, 5, line.length()))
      .join("\n")
    out.write_string(
      "<div class=\"pointer-target\">\{caption("\{target.path}:\{target.line + 1}")}</div><div class=\"pointer-code\">\{snippet_html("pointer", @core.language(target.path), snippet)}</div>",
    )
    out.write_string(
      button(
        "pointer-jump",
        if preview.targets.length() == 1 {
          "定義へ移動  ⌘クリック"
        } else {
          "\{preview.targets.length()}件の定義を表示"
        },
      ),
    )
  }
  out.write_string("</div></div>")
  out.to_string()
}
