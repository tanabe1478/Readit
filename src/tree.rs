use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug)]
pub struct Entry {
    pub path: String,
    pub name: String,
    pub depth: usize,
    pub file: Option<usize>,
}

pub fn entries(paths: &[String], collapsed: &BTreeSet<String>) -> Vec<Entry> {
    entries_with_directories(paths, &[], collapsed)
}

pub fn entries_with_directories(
    paths: &[String],
    directories: &[String],
    collapsed: &BTreeSet<String>,
) -> Vec<Entry> {
    let mut nodes = BTreeMap::<String, Option<usize>>::new();
    for path in directories {
        nodes.insert(path.clone(), None);
    }
    for (index, path) in paths.iter().enumerate() {
        let pieces: Vec<_> = path.split('/').collect();
        for end in 1..pieces.len() {
            nodes.entry(pieces[..end].join("/")).or_insert(None);
        }
        nodes.insert(path.clone(), Some(index));
    }
    // Build parent -> direct children once. Recursively rescanning all nodes costs
    // O(directory_count * node_count) on every editor redraw.
    let mut by_parent = BTreeMap::<&str, Vec<(&String, &Option<usize>)>>::new();
    for (path, file) in &nodes {
        by_parent.entry(path.rsplit_once('/').map_or("", |(p, _)|p)).or_default().push((path,file));
    }
    for children in by_parent.values_mut() {
        children.sort_by_key(|(path,file)|(file.is_some(),path.to_lowercase()));
    }
    fn visit(
        parent: &str,
        depth: usize,
        by_parent: &BTreeMap<&str, Vec<(&String, &Option<usize>)>>,
        collapsed: &BTreeSet<String>,
        out: &mut Vec<Entry>,
    ) {
        let Some(children)=by_parent.get(parent) else {return;};
        for &(path, file) in children {
            out.push(Entry {
                path: path.clone(),
                name: path.rsplit('/').next().unwrap().into(),
                depth,
                file: *file,
            });
            if file.is_none() && !collapsed.contains(path) {
                visit(path, depth + 1, by_parent, collapsed, out);
            }
        }
    }
    let mut out = Vec::new();
    visit("", 0, &by_parent, collapsed, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_directories_are_visible_and_collapsible() {
        let dirs = vec!["src".into(), "src/empty".into()];
        assert_eq!(
            entries_with_directories(&[], &dirs, &BTreeSet::new()).len(),
            2
        );
        assert_eq!(
            entries_with_directories(&[], &dirs, &BTreeSet::from(["src".into()])).len(),
            1
        );
    }
    #[test]
    fn preserves_hierarchy_sorts_folders_first_and_collapses_descendants() {
        let paths = vec![
            "z.rs".into(),
            "src/nested/b.rs".into(),
            "src/a.rs".into(),
            "README.md".into(),
        ];
        let open = entries(&paths, &BTreeSet::new());
        assert_eq!(
            open.iter().map(|e| e.path.as_str()).collect::<Vec<_>>(),
            [
                "src",
                "src/nested",
                "src/nested/b.rs",
                "src/a.rs",
                "README.md",
                "z.rs"
            ]
        );
        assert_eq!(open[2].depth, 2);
        assert_eq!(open[2].file, Some(1));
        let closed = entries(&paths, &BTreeSet::from(["src".into()]));
        assert_eq!(closed.len(), 3);
        assert_eq!(closed[0].file, None);
    }
}
