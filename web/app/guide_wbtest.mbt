// Guide bubbles and prepared tours, driven the way the page and the MCP
// server drive them, without a browser.

///|
let sample : Map[String, String] = {
  "sample.py": "one = 1\ntwo = 2\nthree = 3\n",
  "store.py": "class Store:\n    cache = {}\n",
}

///|
fn three_steps() -> Array[Json] {
  [
    step_json("one", 1, "one = 1"),
    step_json(
      "guess",
      2,
      "two = 2",
      kind="prediction",
      prompt="two は何になる？",
    ),
    step_json("three", 3, "three = 3"),
  ]
}

///|
/// The steps after visited_through, for a revision that keeps the route.
fn unread_steps() -> Array[Json] {
  let tour = reader.tour.unwrap()
  three_steps()[tour.visited + 1:].to_owned()
}

///|
fn ask(question : String) -> Int {
  act("guide-ask")
  fake_set_value("guide-question", question)
  act("guide-send")
  event_sequence(last_event("question").unwrap())
}

///|
fn next_disabled() -> Bool {
  bubble().contains("data-act=\"guide-next\" disabled")
}

///|
test "a loaded tour with an overview opens the overview; chapters open bubbles" {
  fresh(sample)
  assert_eq(reader.selected, Some("sample.py"))
  let loaded = load_tour(
    three_steps(),
    overview=Some(overview_json(["one", "guess"])),
  )
  assert_true(loaded is Ok(_))
  assert_true(overview_visible())
  assert_false(bubble_visible())
  assert_true(fake_html("overview").contains("値の定義"))
  act("chapter", arg="1")
  assert_false(overview_visible())
  assert_true(bubble().contains("two は何になる？"))
  assert_eq(reader.tour.unwrap().index, 1)
  assert_eq(reader.tour.unwrap().visited, 1)
  act("overview")
  assert_true(overview_visible())
  assert_true(reader.guide is Some(_))
  act("chapter", arg="0")
  assert_true(bubble().contains("one の解説"))
  assert_eq(reader.tour.unwrap().index, 0)
  assert_eq(reader.tour.unwrap().visited, 1)
}

///|
test "next, back, prediction and end run locally and leave a trail of events" {
  fresh(sample)
  assert_true(
    load_tour(three_steps(), overview=Some(overview_json(["one"]))) is Ok(_),
  )
  act("chapter", arg="0")
  act("guide-next")
  assert_true(bubble().contains("two は何になる？"))
  assert_true(next_disabled())
  // Pressing the disabled button through the keyboard still waits.
  act("guide-next")
  assert_eq(reader.tour.unwrap().index, 1)
  assert_true(bubble().contains("予測を記録するか"))
  // An empty prediction is refused; a written one is kept and enables Next.
  act("prediction-record")
  assert_true(bubble().contains("予測を1〜2,000文字で入力するか"))
  fake_set_value("guide-prediction", "2 になる")
  act("prediction-record")
  assert_eq(reader.tour.unwrap().predictions.length(), 1)
  assert_false(next_disabled())
  act("guide-next")
  assert_true(bubble().contains("three の解説"))
  assert_true(bubble().contains("完了"))
  act("guide-back")
  assert_true(bubble().contains("「2 になる」"))
  assert_eq(reader.tour.unwrap().index, 1)
  assert_eq(reader.tour.unwrap().visited, 2)
  // A tour with an overview survives End; the overview is a button away.
  act("guide-end")
  assert_false(bubble_visible())
  assert_true(reader.guide is None)
  assert_true(reader.tour is Some(_))
  assert_false(overview_visible())
  act("overview")
  assert_true(overview_visible())
  let actions = reader.guide_events.map(e => {
    json_text(e, "action").unwrap_or("?")
  })
  assert_eq(actions, ["step", "step", "prediction", "step", "step", "end"])
  // The reader's words are reported as written, never graded.
  assert_eq(
    json_text(last_event("prediction").unwrap(), "answer"),
    Some("2 になる"),
  )
}

///|
test "finishing the last step returns to the overview" {
  fresh(sample)
  assert_true(
    load_tour(
      [step_json("one", 1, "one = 1"), step_json("three", 3, "three = 3")],
      overview=Some(overview_json(["one"])),
    )
    is Ok(_),
  )
  act("chapter", arg="0")
  act("guide-next")
  act("guide-next")
  assert_true(overview_visible())
  assert_true(reader.guide is None)
  assert_true(reader.tour is Some(_))
  assert_eq(json_text(last_event("end").unwrap(), "id"), Some("three"))
  // Without an overview the same press closes the tour.
  fresh(sample)
  assert_true(load_tour([step_json("one", 1, "one = 1")]) is Ok(_))
  assert_true(bubble().contains("one の解説"))
  act("guide-next")
  assert_true(reader.tour is None)
  assert_false(bubble_visible())
}

///|
test "a question becomes an event, the answer returns to its bubble, and reopening the step keeps both" {
  fresh(sample)
  assert_true(
    load_tour(three_steps(), overview=Some(overview_json(["one"]))) is Ok(_),
  )
  act("chapter", arg="0")
  // Cancel closes the form without an event.
  act("guide-ask")
  assert_true(bubble().contains("id=\"guide-question\""))
  act("guide-cancel")
  assert_false(bubble().contains("id=\"guide-question\""))
  assert_true(last_event("question") is None)
  // An empty question is refused in place.
  act("guide-ask")
  act("guide-send")
  assert_true(
    bubble().contains("質問を1〜2,000文字で入力してください"),
  )
  fake_set_value("guide-question", "なぜ 1 なの？")
  act("guide-send")
  let question = last_event("question").unwrap()
  assert_eq(json_text(question, "question"), Some("なぜ 1 なの？"))
  assert_eq(json_text(question, "path"), Some("/proj/sample.py"))
  assert_eq(json_int(question, "line"), Some(1))
  assert_eq(json_int(question, "end_column"), Some(8))
  assert_eq(json_text(question, "expected_text"), Some("one = 1"))
  assert_eq(json_text(question, "explanation"), Some("one の解説"))
  assert_true(bubble().contains("質問: なぜ 1 なの？"))
  assert_true(bubble().contains("回答を待っています"))
  let sequence = event_sequence(question)
  // The answer must name the pending question.
  let stale = mcp(
    "readit_guide_answer",
    args({ "id": "one", "question_sequence": num(sequence - 1), "body": "x" }),
  )
  assert_true(stale is Err(_))
  let answered = mcp(
    "readit_guide_answer",
    args({
      "id": "one",
      "question_sequence": num(sequence),
      "body": "最初の値です",
    }),
  )
  assert_true(answered is Ok(_))
  assert_true(bubble().contains("最初の値です"))
  assert_true(reader.guide.unwrap().pending_question is None)
  // The overview covers the bubble; its chapter reopens the same step with the answer.
  act("overview")
  act("chapter", arg="0")
  assert_true(bubble().contains("最初の値です"))
  assert_true(bubble().contains("追加で質問"))
  // A question still pending survives the same round trip until the model revises.
  let second = ask("もう一つ")
  act("overview")
  act("chapter", arg="0")
  assert_true(bubble().contains("質問: もう一つ"))
  let s = state()
  let revised = mcp(
    "readit_guide_revise",
    args({
      "id": "tour",
      "event_sequence": num(json_int(s, "guide_event_sequence").unwrap()),
      "question_sequence": num(second),
      "answer": "二つめの答え",
      "steps": Json::array(unread_steps()),
      "overview": overview_json(["one"]),
    }),
  )
  assert_true(revised is Ok(_))
  assert_true(bubble().contains("二つめの答え"))
  assert_eq(json_text(question, "previous_question"), None)
  assert_eq(
    json_text(last_event("question").unwrap(), "previous_answer"),
    Some("最初の値です"),
  )
  act("guide-next")
  assert_true(bubble().contains("two は何になる？"))
}

///|
test "a revision keeps visited history and validates the new suffix" {
  fresh(sample)
  assert_true(
    load_tour(three_steps(), overview=Some(overview_json(["one"]))) is Ok(_),
  )
  act("chapter", arg="0")
  let question = ask("この先は？")
  let sequence = () => num(reader.guide_sequence)
  let revise = (steps : Array[Json], overview : Json) => {
    mcp(
      "readit_guide_revise",
      args({
        "id": "tour",
        "event_sequence": sequence(),
        "question_sequence": num(question),
        "answer": "こう続きます",
        "steps": Json::array(steps),
        "overview": overview,
      }),
    )
  }
  // Reusing a retained id, moving on with a stale sequence, or forgetting the overview fails atomically.
  assert_true(
    revise([step_json("one", 3, "three = 3")], overview_json(["one"])) is Err(_),
  )
  let stale = mcp(
    "readit_guide_revise",
    args({
      "id": "tour",
      "event_sequence": num(reader.guide_sequence + 1),
      "question_sequence": num(question),
      "answer": "x",
      "steps": Json::array([]),
      "overview": overview_json(["one"]),
    }),
  )
  assert_true(stale is Err(_))
  assert_true(
    mcp(
      "readit_guide_revise",
      args({
        "id": "tour",
        "event_sequence": sequence(),
        "question_sequence": num(question),
        "answer": "x",
        "steps": Json::array([]),
      }),
    )
    is Err(_),
  )
  assert_eq(reader.tour.unwrap().steps.length(), 3)
  assert_true(reader.guide.unwrap().pending_question is Some(_))
  // An empty suffix ends the route after what was read.
  assert_true(revise([], overview_json(["one"])) is Ok(_))
  assert_eq(reader.tour.unwrap().steps.length(), 1)
  assert_true(bubble().contains("こう続きます"))
  assert_true(bubble().contains("完了"))
  act("guide-next")
  assert_true(overview_visible())
}

///|
test "loading validates steps, chapters and links before anything changes" {
  fresh(sample)
  let steps = three_steps()
  // Chapters start at the first step, in order.
  assert_true(
    load_tour(steps, overview=Some(overview_json(["guess"]))) is Err(_),
  )
  assert_true(
    load_tour(steps, overview=Some(overview_json(["one", "three", "guess"])))
    is Err(_),
  )
  // Verification links point back at a prediction.
  let bad_link = [
    step_json("one", 1, "one = 1"),
    step_json("v", 2, "two = 2", kind="verification", verifies="one"),
  ]
  assert_true(load_tour(bad_link) is Err(_))
  let forward = [
    step_json("v", 1, "one = 1", kind="verification", verifies="p"),
    step_json("p", 2, "two = 2", kind="prediction", prompt="?"),
  ]
  assert_true(load_tour(forward) is Err(_))
  assert_true(
    load_tour([step_json("a", 1, "one = 1"), step_json("a", 2, "two = 2")])
    is Err(_),
  )
  // Text that is not in the file is rejected and names the step.
  match load_tour([step_json("one", 1, "one = 2")]) {
    Err(message) => {
      assert_true(message.contains("step one"))
      assert_true(message.contains("expected_text does not match"))
    }
    Ok(_) => fail("stale text was accepted")
  }
  // The event sequence must be current.
  let behind = mcp(
    "readit_guide_load",
    args({
      "id": "tour",
      "event_sequence": num(reader.guide_sequence + 5),
      "steps": Json::array(steps),
    }),
  )
  assert_true(behind is Err(_))
  assert_true(reader.tour is None)
  // A miscounted column is corrected when the text appears once on its line.
  let shifted : Array[Json] = [
    {
      "id": "eq",
      "title": "eq",
      "body": "b",
      "path": "sample.py",
      "line": 1,
      "column": 1,
      "expected_text": "= 1",
    },
  ]
  assert_true(load_tour(shifted) is Ok(_))
  assert_eq(
    json_text(json_field(state(), "selection").unwrap(), "text"),
    Some("= 1"),
  )
  assert_eq(
    json_int(json_field(state(), "selection").unwrap(), "start_column"),
    Some(5),
  )
}

///|
test "steps follow unique text through edits and stop when it becomes ambiguous" {
  fresh(sample)
  assert_true(load_tour(three_steps()) is Ok(_))
  assert_true(bubble().contains("one の解説"))
  // The step's text is selected and typing would replace it. From the top of
  // the file, a new line shifts everything down.
  press_key("cmd-up")
  type_text("# header\n")
  assert_true(bubble().contains("one の解説"))
  act("guide-next")
  assert_true(bubble().contains("two は何になる？"))
  let selection = json_field(state(), "selection").unwrap()
  assert_eq(json_text(selection, "text"), Some("two = 2"))
  assert_eq(json_int(selection, "start_line"), Some(3))
  act("guide-back")
  assert_eq(json_int(json_field(state(), "selection").unwrap(), "start_line"), Some(2))
  // A second copy of the step's text makes its anchor ambiguous: the guide is interrupted.
  press_key("cmd-up")
  type_text("one = 1\n")
  assert_true(reader.guide is None)
  assert_eq(json_text(last_event("interrupted").unwrap(), "id"), Some("one"))
}


///|
test "a single explanation's Next asks the model for the next bubble" {
  fresh(sample)
  let show = (id : String, line : Int, expected : String) => {
    mcp(
      "readit_guide_show",
      args({
        "id": id,
        "title": id,
        "body": "\{id} の解説",
        "path": "sample.py",
        "line": num(line),
        "column": 1,
        "expected_text": expected,
        "event_sequence": num(reader.guide_sequence),
      }),
    )
  }
  assert_true(show("first", 1, "one = 1") is Ok(_))
  assert_true(bubble().contains("first の解説"))
  assert_true(reader.tour is None)
  act("guide-next")
  assert_eq(json_text(last_event("next").unwrap(), "id"), Some("first"))
  assert_true(bubble().contains("次の解説を待っています"))
  assert_true(bubble().contains("待機中…"))
  // Another Next while waiting is ignored.
  act("guide-next")
  assert_eq(reader.guide_events.length(), 1)
  elapse(10_001.0)
  assert_true(bubble().contains("応答が届いていません"))
  // The model must read the events first.
  assert_true(
    mcp(
      "readit_guide_show",
      args({
        "id": "second",
        "title": "second",
        "body": "b",
        "path": "sample.py",
        "line": 2,
        "column": 1,
        "expected_text": "two = 2",
        "event_sequence": 0,
      }),
    )
    is Err(_),
  )
  assert_true(show("second", 2, "two = 2") is Ok(_))
  assert_true(bubble().contains("second の解説"))
  assert_eq(
    json_text(json_field(state(), "selection").unwrap(), "text"),
    Some("two = 2"),
  )
  act("guide-end")
  assert_true(reader.guide is None)
  assert_eq(json_text(last_event("end").unwrap(), "id"), Some("second"))
  // Clearing from the model side is an event too.
  assert_true(show("third", 3, "three = 3") is Ok(_))
  assert_true(mcp("readit_guide_clear", args({})) is Ok(_))
  assert_eq(json_text(last_event("cleared").unwrap(), "id"), Some("third"))
}

///|
test "evidence opens as a detour and refuses once its source changed" {
  fresh(sample)
  let overview : Json = {
    "title": "値の定義",
    "summary": "三つの値",
    "relationships": "sample.py → store.py",
    "claims": [
      {
        "id": "store-owns",
        "statement": "Store がキャッシュを持つ",
        "confidence": "source_confirmed",
        "evidence": [
          {
            "label": "キャッシュの保持",
            "path": "store.py",
            "line": 2,
            "column": 5,
            "expected_text": "cache = {}",
          },
        ],
      },
    ],
    "chapters": [
      { "title": "最初", "summary": "最初の代入", "start_step": "one" },
    ],
    "reader_context": { "known": ["Python"], "focus": ["キャッシュ"] },
  }
  assert_true(load_tour(three_steps(), overview=Some(overview)) is Ok(_))
  let page = fake_html("overview")
  assert_true(page.contains("Store がキャッシュを持つ"))
  assert_true(page.contains("store.py:2"))
  // The reader's assumed context is folded until asked for.
  assert_true(page.contains("今回の前提"))
  assert_false(page.contains("Python"))
  act("toggle-context")
  assert_true(fake_html("overview").contains("Python"))
  act("evidence", arg="0")
  assert_eq(reader.selected, Some("store.py"))
  assert_eq(
    json_text(json_field(state(), "selection").unwrap(), "text"),
    Some("cache = {}"),
  )
  assert_false(overview_visible())
  assert_eq(reader.tour.unwrap().index, 0)
  // Editing the cited text makes the evidence stale.
  type_text("x")
  act("overview")
  assert_true(fake_html("overview").contains("変更"))
  act("evidence", arg="0")
  assert_true(status_text().contains("ソースが変更されています"))
  assert_true(overview_visible())
  // Bad confidence words and missing evidence are rejected.
  fresh(sample)
  let weak : Json = {
    "title": "t",
    "summary": "s",
    "relationships": "r",
    "claims": [
      { "id": "c", "statement": "s", "confidence": "certain", "evidence": [] },
    ],
    "chapters": [
      { "title": "最初", "summary": "最初の代入", "start_step": "one" },
    ],
  }
  assert_true(load_tour(three_steps(), overview=Some(weak)) is Err(_))
}

///|
test "guide events page by sequence and report truncation" {
  fresh(sample)
  assert_true(
    load_tour(three_steps(), overview=Some(overview_json(["one"]))) is Ok(_),
  )
  act("chapter", arg="0")
  fake_set_value("guide-prediction", "2")
  act("guide-next")
  act("prediction-record")
  for _ in 0..<70 {
    act("guide-next")
    act("guide-back")
  }
  let after_0 = mcp("readit_guide_events", args({ "after": 0 })).unwrap()
  assert_eq(json_field(after_0, "truncated"), Some(true))
  let latest = json_int(after_0, "latest_sequence").unwrap()
  assert_eq(latest, reader.guide_sequence)
  let recent = mcp("readit_guide_events", args({ "after": num(latest - 3) })).unwrap()
  assert_eq(json_field(recent, "truncated"), Some(false))
  guard json_field(recent, "events") is Some(Array(events)) else {
    fail("events missing")
  }
  assert_eq(events.length(), 3)
  assert_eq(json_int(events[0], "sequence"), Some(latest - 2))
  // Another workspace's call is refused before anything runs.
  let other = mcp("readit_guide_events", {
    "workspace": "/elsewhere",
    "after": 0,
  })
  assert_true(other is Err(_))
}
