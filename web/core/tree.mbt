///|
pub(all) struct TreeEntry {
  path : String
  name : String
  depth : Int
  /// Index into the listed files, or None for a folder.
  file : Int?
} derive(Debug)

///|
/// Folder-first, case-insensitive tree rows. Collapsed folders hide descendants.
pub fn tree_entries(
  paths : Array[String],
  directories : Array[String],
  collapsed : Map[String, Unit],
) -> Array[TreeEntry] {
  let nodes : Map[String, Int?] = Map([])
  for path in directories {
    nodes[path] = None
  }
  for index, path in paths {
    let pieces = path.split("/").map(p => p.to_owned()).collect()
    for end in 1..<pieces.length() {
      let parent = pieces[0:end].to_owned().join("/")
      if !nodes.contains(parent) {
        nodes[parent] = None
      }
    }
    nodes[path] = Some(index)
  }
  // Build parent -> direct children once, instead of rescanning all nodes per folder.
  let by_parent : Map[String, Array[(String, Int?)]] = Map([])
  for path, file in nodes {
    let parent = parent_of(path)
    match by_parent.get(parent) {
      Some(children) => children.push((path, file))
      None => by_parent[parent] = [(path, file)]
    }
  }
  for _, children in by_parent {
    children.sort_by((a, b) => {
      let (pa, fa) = a
      let (pb, fb) = b
      let ka = if fa is Some(_) { 1 } else { 0 }
      let kb = if fb is Some(_) { 1 } else { 0 }
      if ka != kb {
        ka - kb
      } else {
        match lex_compare(lower(pa), lower(pb)) {
          0 => lex_compare(pa, pb)
          order => order
        }
      }
    })
  }
  let out = []
  fn visit(parent : String, depth : Int) {
    guard by_parent.get(parent) is Some(children) else { return }
    for child in children {
      let (path, file) = child
      out.push({ path, name: base_name(path), depth, file, })
      if file is None && !collapsed.contains(path) {
        visit(path, depth + 1)
      }
    }
  }

  visit("", 0)
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
