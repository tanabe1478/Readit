# Android mobile first pass (07f2afcd)

## Isolation / baseline

- Workspace: `/data/user/0/io.github.tanabe1478.androidpi/files/work/Readit-mobile-07f2afcd`
- Confirmed absent before `git clone --depth 1 https://github.com/tanabe1478/Readit.git`.
- Baseline: `460b0c86e6aadc4fb3e6214f98a40cc2129ef124`
- Branch: `android/mobile-07f2afcd`; no commit/push/PR or remote writes.
- No AGENTS.md found in the clone. Read root/web README, package.json, mobile tests, input/dom glue, build/start scripts, related app main/keys and editor deletion implementation.
- No other checkout, authentication, conversations, baseline packages, private files, clipboard, keyboard candidates or other apps accessed/modified.

## Chosen gap and minimal change

`editor-input` is an empty insertion buffer after input. `keydown` with keyCode 229 is ignored, and the original `input` listener only forwards nonempty text. An Android-style `beforeinput(deleteContentBackward/Forward)` therefore never reaches the editor model. This is a reproducible **synthetic wiring gap**, not a claim about an observed physical keyboard sequence.

`web/www/glue/input.js` now forwards those two beforeinput intents to the existing `key` event (editor backspace/delete), clears the buffer and prevents native editing when handled. Composition/preedit deletions are left native. Desktop consumed keydown already prevents native beforeinput, so it remains on its existing route. No MoonBit/layout/auth changes.

Changed/added files:
- `web/www/glue/input.js`: deletion-intent bridge.
- `web/tests/unit/input.test.mjs`: actual wire() loaded via VM modules with explicit DOM/bridge stubs; only JS wiring assertions, not application success.
- `web/tests/e2e/mobile.spec.js`: public edit.txt fixture; synthetic 229 deletion regression asserts wasm-rendered text, selection deletion, unchanged disk before save and exact file bytes after touch-menu save.
- This log.

## Setup executed

Git 2.56.0, Node v26.4.0 available; moon not found. npm executable's existing shebang refers to unavailable `/data/data/com.termux/files/usr/bin/env`. Did NOT rewrite it. `node /data/user/0/io.github.tanabe1478.androidpi/files/usr/lib/node_modules/npm/bin/npm-cli.js --version` works (11.20.0).

In this checkout's web only, ran that npm CLI with `ci --ignore-scripts --no-audit --no-fund`: success, 23 local packages. No global installs/upgrades, lifecycle scripts or browser downloads. Lockfile/package.json unchanged.

## Verification actually executed

- `node --experimental-vm-modules --test <repo>/web/tests/unit/input.test.mjs`: before fix 3 passed / 4 failed; after fix 7 passed / 0 failed. Covers backward/forward delete with 229, noncancelable notification + input (one forwarding), composition exclusion, unrelated text input and desktop keydown. Uses synthetic events/stubs; no real IME evidence.
- `node --check` input.js and mobile.spec.js: success.
- `git diff --check`: success.
- `node <repo>/web/scripts/build.mjs`: FAILED, moon missing.
- `node node_modules/@playwright/test/cli.js test tests/e2e/mobile.spec.js --list` in web: FAILED, Unsupported platform: android. No browser launch attempted. Added E2E has NOT run.

## Blocked / still unverified

Clone has no www/app.wasm, dist/server.js, www/vendor or generated grammars. No actual Readit preview opened; pi-browser is available but there is no built application to serve. No moon test or E2E success claimed. Need isolated host build/test and returned assets before phone application verification.

Remaining acceptance: native finger scrolling, file drawer/menu/search with soft keyboard, real edits and saved bytes, unsaved close/cancel/save, real Japanese IME conversion/deletion/newline. Existing mobile layout tests alone do not establish these.

Composition duplication is NOT fixed here: compositionend sends e.data/value and clears input; a following noncomposing input with the same committed value can send it again. Need regression covering browser event orders before implementing suppression (must not swallow legitimate next repeated text). Newline with 229 likewise needs validation; input text newline is not necessarily the editor's existing autoindent newline command. Some WebViews/IMEs may omit beforeinput at an empty textarea; the current deletion fix must be checked with real keyboard events and may need further work. Do not capture candidate lists or private values.

## Next handoff

1. Copy baseline + these uncommitted changes into a NEW isolated host checkout, not the existing Mac Readit. Run moon test, node scripts/build.mjs and Playwright mobile tests on host. Do not commit/push unless separately authorized.
2. Return www/app.wasm, dist/server.js, www/vendor and www/grammars assets matching this checkout. Do not replace Android baseline packages.
3. Serve only a public fixture inside this workspace with --no-open; attach pi-browser to loopback foreground preview. Validate the new synthetic regression against real wasm, then separately ask for/manual-test physical Japanese IME conversion, delete, newline, save and unsaved cancellation. Record actual results and remaining gaps distinctly.
