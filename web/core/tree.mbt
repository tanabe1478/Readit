///|
pub(all) struct TreeEntry {
  path : String
  name : String
  depth : Int
  folder : Bool
} derive(Debug)

///|
/// One entry of a loaded folder.
pub(all) struct TreeChild {
  name : String
  dir : Bool
} derive(Debug)

///|
/// Folder-first, case-insensitive tree rows from the folders loaded so far
/// ("" is the root). Only expanded folders show their children; an expanded
/// folder that is not loaded yet shows none until it is.
pub fn tree_entries(
  listed : Map[String, Array[TreeChild]],
  expanded : Map[String, Unit],
) -> Array[TreeEntry] {
  let out = []
  fn visit(parent : String, depth : Int) {
    guard listed.get(parent) is Some(children) else { return }
    let sorted = children.copy()
    sorted.sort_by((a, b) => {
      let ka = if a.dir { 0 } else { 1 }
      let kb = if b.dir { 0 } else { 1 }
      if ka != kb {
        ka - kb
      } else {
        match lex_compare(lower(a.name), lower(b.name)) {
          0 => lex_compare(a.name, b.name)
          order => order
        }
      }
    })
    for child in sorted {
      let path = if parent == "" {
        child.name
      } else {
        parent + "/" + child.name
      }
      out.push({ path, name: child.name, depth, folder: child.dir, })
      if child.dir && expanded.contains(path) {
        visit(path, depth + 1)
      }
    }
  }

  visit("", 0)
  out
}

///|
/// Every folder above `path`, outermost first, without the root.
pub fn ancestors(path : String) -> Array[String] {
  let out = []
  let mut parent = parent_of(path)
  while parent != "" {
    out.insert(0, parent)
    parent = parent_of(parent)
  }
  out
}

///|
/// The folder part of a relative path, or "" at the top.
pub fn parent_of(path : String) -> String {
  for i = path.length() - 1; i >= 0; i = i - 1 {
    if path[i] == '/' {
      return path.unsafe_substring(start=0, end=i)
    }
  }
  ""
}

///|
/// The last path component.
pub fn base_name(path : String) -> String {
  for i = path.length() - 1; i >= 0; i = i - 1 {
    if path[i] == '/' {
      return path.unsafe_substring(start=i + 1, end=path.length())
    }
  }
  path
}

///|
/// The file extension without the dot, or "".
pub fn extension(path : String) -> String {
  let name = base_name(path)
  for i = name.length() - 1; i >= 0; i = i - 1 {
    if name[i] == '.' {
      return name.unsafe_substring(start=i + 1, end=name.length())
    }
  }
  ""
}

///|
/// Rewrite `path` when it is `from` or inside it, for renames.
pub fn remap_path(path : String, from : String, to : String) -> String {
  if path == from {
    to
  } else if starts_with(path, from + "/") {
    to + slice(path, from.length(), path.length())
  } else {
    path
  }
}

///|
/// Whether `path` is `folder` or inside it.
pub fn within(path : String, folder : String) -> Bool {
  path == folder || starts_with(path, folder + "/")
}

///|
/// Paths whose lowercase form contains the query's characters in order, those
/// containing the query outright first, then shorter paths, then listing order.
/// `lowered` holds each path in lowercase, in the same order; `query` must be
/// lowercase. Returns at most `limit` paths and how many matched.
pub fn fuzzy_paths(
  paths : Array[String],
  lowered : Array[String],
  query : String,
  limit : Int,
) -> (Array[String], Int) {
  let needles = query.iter().map(c => String::make(1, c)).collect()
  let found : Array[(Int, Int, Int)] = []
  for i, path in lowered {
    let mut at = 0
    let mut ok = true
    for needle in needles {
      let next = find_from(path, needle, at)
      if next < 0 {
        ok = false
        break
      }
      at = next + needle.length()
    }
    if ok {
      found.push((if contains(path, query) { 0 } else { 1 }, path.length(), i))
    }
  }
  found.sort_by((a, b) => {
    if a.0 != b.0 {
      a.0 - b.0
    } else if a.1 != b.1 {
      a.1 - b.1
    } else {
      a.2 - b.2
    }
  })
  let total = found.length()
  let shown = if total > limit { found[0:limit].to_owned() } else { found }
  (shown.map(f => paths[f.2]), total)
}
