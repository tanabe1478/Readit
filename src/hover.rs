//! Symbol ranges for pointer navigation. Offsets are UTF-8 bytes, like InputState.
use std::ops::Range;

pub fn symbol_range(text: &str, offset: usize) -> Option<Range<usize>> {
    if !text.is_char_boundary(offset) {
        return None;
    }
    let symbol = |c: char| c.is_alphanumeric() || c == '_';
    if !symbol(text.get(offset..)?.chars().next()?) {
        return None;
    }
    let start = text[..offset]
        .char_indices()
        .rev()
        .find(|(_, c)| !symbol(*c))
        .map_or(0, |(i, c)| i + c.len_utf8());
    let end = text[offset..]
        .char_indices()
        .find(|(_, c)| !symbol(*c))
        .map_or(text.len(), |(i, _)| offset + i);
    Some(start..end)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identifies_the_pointed_symbol_not_the_editor_cursor() {
        let s = "first(foo.bar, second)";
        assert_eq!(symbol_range(s, 11), Some(10..13));
        assert_eq!(symbol_range(s, 15), Some(15..21));
        assert_eq!(symbol_range(s, 9), None);
        assert_eq!(symbol_range(s, 14), None);
        assert_eq!(symbol_range(s, s.len()), None);
    }
    #[test]
    fn unicode_offsets_remain_utf8_bytes() {
        let s = "😀 商品_total(x)";
        let start = s.find('商').unwrap();
        let end = s.find('(').unwrap();
        assert_eq!(symbol_range(s, start + 3), Some(start..end));
        assert_eq!(symbol_range(s, start + 1), None);
        assert_eq!(symbol_range(s, 0), None);
    }
}
