// Geometry/wiring tests only. Actual wasm/browser coverage is in guide-viewport.spec.js.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { visibleRows } from '../../www/glue/viewport.js';

function row(line, top, height) {
  return {
    dataset: { line: String(line) },
    getBoundingClientRect() {
      return { top, bottom: top + height, height };
    }
  };
}

function box(rows, { top = 100, height = 400, border = 0, view = 'editor' } = {}) {
  return {
    clientTop: border,
    clientHeight: height,
    scrollTop: 16126,
    getBoundingClientRect() {
      return { top, height: height + border * 2 };
    },
    querySelector(selector) {
      if (selector !== `.lines[data-view="${view}"]`) {
        return null;
      }
      return {
        querySelectorAll(selector_) {
          assert.equal(selector_, '.row[data-line]');
          return rows;
        }
      };
    }
  };
}

const viewport = { offsetTop: 0, height: 900 };

test('wrapped long-file viewport follows logical rows, not scrollTop/line-height', () => {
  const rows = [
    row(519, 10, 90),
    row(520, 90, 80),
    row(521, 170, 200),
    row(522, 370, 50),
    row(532, 420, 100),
    row(533, 520, 100)
  ];
  const scroll = box(rows);
  assert.equal(visibleRows(scroll, 'editor', viewport), '520,532');
  scroll.scrollTop = 999999;
  assert.equal(visibleRows(scroll, 'editor', viewport), '520,532');
});

test('nonwrapped desktop rows use the same geometry with exact edge exclusion', () => {
  const rows = [row(99, 80, 20), row(100, 100, 20), row(101, 120, 20), row(102, 140, 20)];
  assert.equal(visibleRows(box(rows, { height: 40 }), 'editor', viewport), '100,101');
});

test('a partial wrapped row is included, including a single tall row spanning the viewport', () => {
  const rows = [row(522, -500, 2000)];
  assert.equal(visibleRows(box(rows), 'editor', viewport), '522,522');
});

test('keyboard-height and visual viewport clipping shrink actual row boundaries', () => {
  const rows = [row(1, 100, 100), row(2, 200, 100), row(3, 300, 100), row(4, 400, 100)];
  const scroll = box(rows);
  assert.equal(visibleRows(scroll, 'editor', { offsetTop: 0, height: 355 }), '1,3');
  assert.equal(visibleRows(scroll, 'editor', { offsetTop: 220, height: 100 }), '2,3');
  assert.equal(visibleRows(box(rows, { height: 120 }), 'editor', viewport), '1,2');
});

test('border and fractional row boundaries are measured without integer rounding', () => {
  const rows = [row(1, 100, 2), row(2, 101.5, 0.6), row(3, 140.5, 2), row(4, 142, 10)];
  assert.equal(visibleRows(box(rows, { border: 2, height: 40 }), 'editor', viewport), '2,3');
});

test('hidden, missing, offscreen and spacer-only views return no viewport', () => {
  assert.equal(visibleRows(null, 'editor', viewport), '');
  assert.equal(visibleRows(box([], { height: 0 }), 'editor', viewport), '');
  assert.equal(visibleRows(box([row(1, 1000, 20)]), 'editor', viewport), '');
  assert.equal(visibleRows(box([]), 'editor', viewport), '');
  assert.equal(visibleRows(box([row(1, 100, 20)]), 'pinned', viewport), '');
  assert.equal(visibleRows(box([], { top: 1000 }), 'editor', viewport), '');
});

test('invalid/zero-height rows are ignored and zero-based line zero is valid', () => {
  const rows = [
    row('', 100, 20),
    row('bad', 100, 20),
    row(-1, 100, 20),
    row(1.5, 100, 20),
    row(5, 100, 0),
    row(0, 100, 20)
  ];
  assert.equal(visibleRows(box(rows), 'editor', viewport), '0,0');
});

test('pinned rows remain separate from the editor bounds', () => {
  const rows = [row(100, 100, 20), row(101, 120, 20)];
  assert.equal(visibleRows(box(rows, { view: 'pinned' }), 'pinned', viewport), '100,101');
});

test('actual dom.visible_rows glue uses the matching scroller and visual viewport', async () => {
  const elements = new Map([
    ['editor-scroll', box([row(520, 90, 80), row(521, 170, 200), row(532, 420, 100)])],
    ['pinned-scroll', box([row(5, 100, 20)], { view: 'pinned' })]
  ]);
  const window = { innerHeight: 900, visualViewport: { offsetTop: 0, height: 355 } };
  const document = {
    createElement() {
      return {
        getContext() {
          return {};
        }
      };
    }
  };
  const context = vm.createContext({ window, document, console });
  const viewportModule = new vm.SourceTextModule(
    await fs.readFile(new URL('../../www/glue/viewport.js', import.meta.url), 'utf8'),
    { context }
  );
  const module = new vm.SourceTextModule(
    await fs.readFile(new URL('../../www/glue/dom.js', import.meta.url), 'utf8'),
    { context }
  );
  await module.link(async name => {
    if (name === './viewport.js') {
      return viewportModule;
    }
    const exports = name === './bridge.js'
      ? {
        $: id => {
          return elements.get(id);
        }
      }
      : {
        rangeRect() {
          return '';
        }
      };
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) {
        this.setExport(key, value);
      }
    }, { context });
  });
  await module.evaluate();
  const dom = module.namespace.dom;
  assert.equal(dom.visible_rows('editor'), '520,521');
  assert.equal(dom.visible_rows('pinned'), '5,5');
  window.visualViewport = null;
  assert.equal(dom.visible_rows('editor'), '520,532');
});

test('Moon FFI is wired to DOM bounds and rejects missing/out-of-document rows', async () => {
  const control = await fs.readFile(new URL('../../app/control.mbt', import.meta.url), 'utf8');
  const ffi = await fs.readFile(new URL('../../app/ffi.mbt', import.meta.url), 'utf8');
  const source = control.slice(
    control.indexOf('fn viewport_lines()'),
    control.indexOf('fn control_state')
  );
  assert.match(ffi, /fn js_visible_rows\(view : String\) -> String = "dom" "visible_rows"/);
  assert.match(source, /js_visible_rows\("editor"\)/);
  assert.match(source, /first > last \|\| last >= e\.line_count\(\)/);
  assert.match(source, /Some\(\(first \+ 1, last \+ 1\)\)/);
  assert.doesNotMatch(source, /js_scroll_top|line_height\(\)/);
});

test('source-range navigation retains narrow/desktop focus_document policy', async () => {
  const guide = await fs.readFile(new URL('../../app/guide.mbt', import.meta.url), 'utf8');
  const reader = await fs.readFile(new URL('../../app/reader.mbt', import.meta.url), 'utf8');
  const source = guide.slice(guide.indexOf('fn open_range('), guide.indexOf('fn relocate('));
  assert.match(source, /focus_document\(\)/);
  assert.doesNotMatch(source, /\n\s+focus_editor\(\)/);
  assert.match(
    reader,
    /fn focus_document\(\)[\s\S]*?narrow_layout\(\)[\s\S]*?reader\.focus = "body"/
  );
  assert.match(reader, /fn focus_document\(\)[\s\S]*?else \{\s+focus_editor\(\)/);
});
