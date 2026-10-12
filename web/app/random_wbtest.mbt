// A reader who presses the guide buttons in random order, with the model
// answering questions late. After every press the editor state and the bubble
// are compared with a model of what the tour should look like. The same walk
// runs in a browser in tests/e2e/pi-random.spec.js; here it runs thousands of
// presses in a second, so many more seeds are tried.

///|
/// mulberry32, so a failing walk is replayed by its seed.
fn random(seed : UInt) -> () -> Double {
  let state = Ref(seed)
  () => {
    state.val = state.val + 0x6D2B79F5
    let mut t = state.val
    t = (t ^ (t >> 15)) * (t | 1)
    t = t ^ (t + (t ^ (t >> 7)) * (t | 61))
    (t ^ (t >> 14)).to_uint64().to_double() / 4294967296.0
  }
}

///|
let walk_lines : Int = 6

///|
let walk_prediction : Int = 2

///|
let chapter_starts : Array[Int] = [0, 3]

///|
fn walk_files() -> Map[String, String] {
  let out = StringBuilder()
  for i in 0..<walk_lines {
    out.write_string("v\{i + 1} = \{i + 1}\n")
  }
  { "sample.py": out.to_string() }
}

///|
fn walk_steps() -> Array[Json] {
  Array::makei(walk_lines, i => {
    if i == walk_prediction {
      step_json(
        "s\{i + 1}",
        i + 1,
        "v\{i + 1} = \{i + 1}",
        kind="prediction",
        prompt="v\{i + 1} はいくつ？",
      )
    } else {
      step_json("s\{i + 1}", i + 1, "v\{i + 1} = \{i + 1}")
    }
  })
}

///|
fn walk_overview() -> Json {
  overview_json(chapter_starts.map(i => "s\{i + 1}"))
}

///|
/// What the tour should look like after the presses so far.
priv struct Model {
  mut guide : Int?
  mut overview : Bool
  mut visited : Int
  predicted : Map[Int, Unit]
  mut pending : (Int, String)?
  answers : Map[Int, String]
  mut asked : Int
  log : Array[String]
}

///|
fn shown(i : Int) -> String {
  if i == walk_prediction {
    "v\{i + 1} はいくつ？"
  } else {
    "s\{i + 1} の解説"
  }
}

///|
fn Model::check(self : Model, seed : UInt) -> Unit raise {
  let where_ = "seed \{seed} after: \{self.log.join(", ")}"
  let s = state()
  let tour = json_field(s, "guide_tour").unwrap_or(Json::null())
  assert_eq(json_text(tour, "id"), Some("tour"), msg=where_)
  assert_eq(
    json_field(s, "overview_visible"),
    Some(Json::boolean(self.overview)),
    msg=where_,
  )
  assert_eq(json_int(tour, "visited_through"), Some(self.visited), msg=where_)
  assert_eq(overview_visible(), self.overview, msg=where_)
  match self.guide {
    None => {
      assert_true(json_field(s, "guide") is Some(Null), msg=where_)
      assert_false(bubble_visible(), msg=where_)
    }
    Some(i) => {
      let guide = json_field(s, "guide").unwrap_or(Json::null())
      assert_eq(json_text(guide, "id"), Some("s\{i + 1}"), msg=where_)
      assert_eq(json_int(tour, "index"), Some(i), msg=where_)
      if self.overview {
        assert_false(bubble_visible(), msg=where_)
      } else {
        let html = bubble()
        assert_true(
          html.contains(shown(i)),
          msg="\{where_}: bubble lacks \{shown(i)}",
        )
        if self.answers.get(i) is Some(a) {
          assert_true(
            html.contains(a),
            msg="\{where_}: bubble lacks answer \{a}",
          )
        }
        if self.pending is Some((step, text)) && step == i {
          assert_true(
            html.contains(text),
            msg="\{where_}: bubble lacks question \{text}",
          )
        }
      }
    }
  }
}

///|
fn Model::enter(self : Model, index : Int) -> Unit {
  self.guide = Some(index)
  self.overview = false
  self.visited = self.visited.max(index)
}

///|
/// Answer the pending question as the model would: in place when its bubble
/// is showing, otherwise by revising the unread route.
fn Model::answer(self : Model, rand : () -> Double) -> Unit raise {
  guard self.pending is Some((step, _)) else { return }
  let question = event_sequence(last_event("question").unwrap())
  let answer = "s\{step + 1} への答え \{self.asked}"
  let s = state()
  let showing = json_text(json_field(s, "guide").unwrap_or(Json::null()), "id") ==
    Some("s\{step + 1}")
  let result = if showing && rand() < 0.5 {
    self.log.push("answer")
    mcp(
      "readit_guide_answer",
      args({
        "id": "s\{step + 1}",
        "question_sequence": num(question),
        "body": answer,
      }),
    )
  } else {
    self.log.push("revise")
    let visited = json_int(
      json_field(s, "guide_tour").unwrap(),
      "visited_through",
    ).unwrap()
    mcp(
      "readit_guide_revise",
      args({
        "id": "tour",
        "event_sequence": num(json_int(s, "guide_event_sequence").unwrap()),
        "question_sequence": num(question),
        "answer": answer,
        "steps": Json::array(walk_steps()[visited + 1:].to_owned()),
        "overview": walk_overview(),
      }),
    )
  }
  match result {
    Ok(_) => ()
    Err(e) => fail("answering failed after \{self.log.join(", ")}: \{e}")
  }
  self.answers[step] = answer
  self.pending = None
}

///|
fn Model::press(
  self : Model,
  rand : () -> Double,
  allowed : Array[String],
) -> Unit raise {
  if self.guide is None || self.overview {
    if !self.overview {
      self.log.push("overview")
      act("overview")
      self.overview = true
      return
    }
    let k = (rand() * chapter_starts.length().to_double()).to_int()
    self.log.push("chapter \{k}")
    act("chapter", arg="\{k}")
    self.enter(chapter_starts[k])
    return
  }
  let index = self.guide.unwrap()
  let action = allowed[(rand() * allowed.length().to_double()).to_int()]
  self.log.push(action)
  match action {
    "next" => {
      if index == walk_prediction && !self.predicted.contains(index) {
        assert_true(next_disabled(), msg="Next waits for the prediction")
        let unknown = rand() < 0.3
        self.log.push(if unknown { "predict unknown" } else { "predict" })
        if !unknown {
          fake_set_value("guide-prediction", "\{index + 1} だと思う")
        }
        act(if unknown { "prediction-unknown" } else { "prediction-record" })
        self.predicted[index] = ()
        assert_false(next_disabled(), msg="Next opens after the prediction")
        return
      }
      act("guide-next")
      if index == walk_lines - 1 {
        self.guide = None
        self.overview = true
      } else {
        self.enter(index + 1)
      }
    }
    "back" => {
      // The first step offers no Back; pressing it anyway must not move.
      act("guide-back")
      if index > 0 {
        self.guide = Some(index - 1)
      }
    }
    "end" => {
      act("guide-end")
      self.guide = None
      self.overview = false
    }
    "overview" => {
      act("overview")
      self.overview = true
    }
    "ask" => {
      self.asked += 1
      let text = "質問\{self.asked}: s\{index + 1} はなぜ？"
      act("guide-ask")
      fake_set_value("guide-question", text)
      act("guide-send")
      self.pending = Some((index, text))
      // An impatient reader keeps pressing before the answer arrives.
      if rand() < 0.5 {
        let extra = 1 + (rand() * 2.0).to_int()
        for _ in 0..<extra {
          self.press(rand, ["next", "back", "end", "overview"])
        }
      }
      self.answer(rand)
    }
    _ => ()
  }
}

///|
test "random presses from the overview keep the tour, the bubble and the answers consistent" {
  let seeds = 40
  let presses = 300
  let mut questions = 0
  for seed in 1U..<=seeds.reinterpret_as_uint() {
    fresh(walk_files())
    assert_true(
      load_tour(walk_steps(), overview=Some(walk_overview())) is Ok(_),
    )
    let rand = random(seed)
    let m : Model = {
      guide: Some(0),
      overview: true,
      visited: 0,
      predicted: Map([]),
      pending: None,
      answers: Map([]),
      asked: 0,
      log: [],
    }
    m.check(seed)
    for _ in 0..<presses {
      m.press(rand, [
        "next", "next", "next", "back", "back", "ask", "ask", "end", "overview",
      ])
      m.check(seed)
    }
    assert_true(m.asked > 0)
    questions += m.asked
  }
  assert_true(questions > seeds * 10)
}
