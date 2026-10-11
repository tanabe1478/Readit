// Logical line bounds from actual rendered rows, including partial wrapped rows.
// Dataset line numbers are zero-based. Empty/hidden/spacer-only views have no bounds.
export function visibleRows(box, view, viewport) {
  if (!box || box.clientHeight <= 0) {
    return '';
  }
  const bounds = box.getBoundingClientRect();
  if (bounds.height <= 0) {
    return '';
  }
  const clientTop = bounds.top + box.clientTop;
  const top = Math.max(clientTop, viewport.offsetTop);
  const bottom = Math.min(clientTop + box.clientHeight, viewport.offsetTop + viewport.height);
  if (bottom <= top) {
    return '';
  }
  const lines = box.querySelector(`.lines[data-view="${view}"]`);
  if (!lines) {
    return '';
  }
  let first = null;
  let last = null;
  for (const row of lines.querySelectorAll('.row[data-line]')) {
    const line = Number(row.dataset.line);
    if (!Number.isSafeInteger(line) || line < 0 || row.dataset.line === '') {
      continue;
    }
    const rect = row.getBoundingClientRect();
    if (rect.height <= 0 || rect.bottom <= top || rect.top >= bottom) {
      continue;
    }
    first = first === null ? line : Math.min(first, line);
    last = last === null ? line : Math.max(last, line);
  }
  return first === null ? '' : `${first},${last}`;
}
