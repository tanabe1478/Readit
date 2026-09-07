#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Context,
    Added,
    Removed,
}
#[derive(Clone, Debug)]
pub struct Row {
    pub old: Option<usize>,
    pub new: Option<usize>,
    pub text: String,
    pub kind: Kind,
}

pub fn rows(before: &str, after: &str, compare: bool) -> Vec<Row> {
    let new: Vec<_> = after.lines().collect();
    if !compare {
        return if new.is_empty() {
            vec![Row {
                old: None,
                new: Some(0),
                text: String::new(),
                kind: Kind::Context,
            }]
        } else {
            new.iter()
                .enumerate()
                .map(|(i, text)| Row {
                    old: None,
                    new: Some(i),
                    text: text.to_string(),
                    kind: Kind::Context,
                })
                .collect()
        };
    }
    let old: Vec<_> = before.lines().collect();
    // Bound memory; whole-file replacement is a valid fallback diff.
    let wide = (old.len() + 1).saturating_mul(new.len() + 1) > 2_000_000;
    let mut lcs = if wide {
        vec![]
    } else {
        vec![0u32; (old.len() + 1) * (new.len() + 1)]
    };
    let width = new.len() + 1;
    if !wide {
        for i in (0..old.len()).rev() {
            for j in (0..new.len()).rev() {
                lcs[i * width + j] = if old[i] == new[j] {
                    1 + lcs[(i + 1) * width + j + 1]
                } else {
                    lcs[(i + 1) * width + j].max(lcs[i * width + j + 1])
                };
            }
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut result = Vec::new();
    while i < old.len() || j < new.len() {
        if i < old.len() && j < new.len() && old[i] == new[j] {
            result.push(Row {
                old: Some(i),
                new: Some(j),
                text: new[j].into(),
                kind: Kind::Context,
            });
            i += 1;
            j += 1;
        } else if i < old.len()
            && (j == new.len() || wide || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1])
        {
            result.push(Row {
                old: Some(i),
                new: None,
                text: old[i].into(),
                kind: Kind::Removed,
            });
            i += 1;
        } else {
            result.push(Row {
                old: None,
                new: Some(j),
                text: new[j].into(),
                kind: Kind::Added,
            });
            j += 1;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inserted_lines_keep_evidence_line_numbers_correct() {
        let r = rows("a\nb\n", "a\nnew\nb\n", true);
        assert_eq!(r[1].kind, Kind::Added);
        assert_eq!(r[1].new, Some(1));
        assert_eq!(r[2].old, Some(1));
        assert_eq!(r[2].new, Some(2));
    }
    #[test]
    fn removed_lines_have_no_edit_target() {
        let r = rows("a\nb\n", "b\n", true);
        assert_eq!(r[0].kind, Kind::Removed);
        assert_eq!(r[0].new, None);
        assert_eq!(r[1].new, Some(0));
    }
}
