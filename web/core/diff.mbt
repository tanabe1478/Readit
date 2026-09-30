///|
pub(all) enum DiffKind {
  Context
  Added
  Removed
} derive(Eq, Debug)

///|
pub(all) struct DiffRow {
  old : Int?
  new : Int?
  text : String
  kind : DiffKind
} derive(Debug)

///|
/// Line rows of `after`, compared with `before` when `compare` is set.
pub fn diff_rows(
  before : String,
  after : String,
  compare : Bool,
) -> Array[DiffRow] {
  let new = lines(after)
  if !compare {
    if new.length() == 0 {
      return [{ old: None, new: Some(0), text: "", kind: Context, }]
    }
    return new.mapi((i, text) => {
      old: None,
      new: Some(i),
      text,
      kind: Context,
    })
  }
  let old = lines(before)
  // Bound memory; whole-file replacement is a valid fallback diff.
  let wide = (old.length() + 1) * (new.length() + 1) > 2_000_000
  let width = new.length() + 1
  let lcs : FixedArray[Int] = if wide {
    FixedArray::make(0, 0)
  } else {
    FixedArray::make((old.length() + 1) * width, 0)
  }
  if !wide {
    for i = old.length() - 1; i >= 0; i = i - 1 {
      for j = new.length() - 1; j >= 0; j = j - 1 {
        lcs[i * width + j] = if old[i] == new[j] {
          1 + lcs[(i + 1) * width + j + 1]
        } else {
          let down = lcs[(i + 1) * width + j]
          let right = lcs[i * width + j + 1]
          if down > right {
            down
          } else {
            right
          }
        }
      }
    }
  }
  let result = []
  let mut i = 0
  let mut j = 0
  while i < old.length() || j < new.length() {
    if i < old.length() && j < new.length() && old[i] == new[j] {
      result.push({ old: Some(i), new: Some(j), text: new[j], kind: Context, })
      i += 1
      j += 1
    } else if i < old.length() &&
      (
        j == new.length() ||
        wide ||
        lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]
      ) {
      result.push({ old: Some(i), new: None, text: old[i], kind: Removed, })
      i += 1
    } else {
      result.push({ old: None, new: Some(j), text: new[j], kind: Added, })
      j += 1
    }
  }
  result
}
