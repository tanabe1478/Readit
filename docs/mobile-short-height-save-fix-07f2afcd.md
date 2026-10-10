# Minimal short-height CSS save access fix and Android continuation

## Source/test diff

web/www/style.css: in the existing max-width:599px / max-height:480px media rule, retain menubar; hide redundant #pathbar together with existing #navbar instead. This trades the duplicated path/diff row for menu access while preserving editor height. No MoonBit/wasm/JS input change, structural rewrite or target-size reduction. Full-height and landscape rules unchanged.

web/tests/e2e/mobile.spec.js: add a 360x355 regression opening public edit.txt, synthetic 229 + explicit InputEvent backward deletion, exact rendered 日本語BC, unchanged initial disk bytes, visible/in-viewport five menus with >=44px height, editor height >140, File menu in-viewport / overflow-y:auto / content overflow, >=44px Save target, Readit save to exact UTF-8 日本語BC\n and wasm.has_unsaved=false. Existing 18 test cases and their document/bytes assertions not weakened. This new case awaits isolated host Chromium/WebKit execution; no phone desktop browser launch/install.

## Live Android CSS update + save-only continuation

Executed docs/resume-save-tools-07f2afcd.mjs ONCE, exclusive private receipt .verify-runtime-07f2afcd/save-resume-tools-receipt.json. Read previous failed deletion receipt, current selected public file text C, dirty=true, ready/idle=true and exact disk original 日本語ABC\n before any continuation. Existing deletion script was NOT repeated. No reload or direct fs save substitute.

Changed only the existing stylesheet link to /style.css?verify-save-tools-07f2afcd-01, awaited load and visual layout frames. Verified SAME wasm.exports object, C preserved, dirty preserved and disk original preserved. At keyboard viewport 360x355:
- all five menu buttons visibly boxed, each height44, within width360;
- menubar display flex, pathbar none;
- editor rect x0/y145/width360/height182.6667.

One File menu click succeeded. It moved focus away from editor and keyboard closed; open menu was consequently measured at viewport360x682 (not355), x8/y101/width344/height573.6667, overflowY auto, scrollHeight686/clientHeight572. Do not represent this as phone evidence of an open menu at355; the fixed355 host regression is designed to cover that.

Save target box height44. Invoked Readit Save ONCE, then Node fs read-only verification: exact bytes 430a (C + newline). wasm.has_unsaved=false, rendered C, ready/idle=true. Receipt success/complete. No lost response/failure/retry in continuation. Old failure receipt/ownership/log untouched.

## Image evidence

pi-browser screenshot invoked ONCE to .verify-preview-07f2afcd/readit-mobile-saved-tools-01.png; standard read returned actual image content. Image shows selected verify-delete-tools.txt, line1 C, blank line2, bottom 保存しました · verify-delete-tools.txt, 1:1 · text. Menu/header readable, drawer/menu closed, no marker/keyboard in image. At full-height the pathbar/navbar are visible again; right edge of navigation still has a partial further control. Static image does not prove swipe reachability. No private/Pi/keyboard/other-app capture, canvas extraction or DOM substitute for image read.

## Status and limits

Android actual-wasm synthetic 229 backward/forward/selection deletions (prior pass) plus successful real menu/API/disk save continuation are now verified. Real IME hand conversion/deletion/newline, native finger scrolling and unsaved confirmation are NOT established by these synthetic tests. Preview/owned server left open on clean public verification file; no unsaved content remains according to wasm. No commit/push, no baseline/auth changes or installs. CSS/tests needed host rerun at the time of this phone pass; completed host results are appended below. Ordinary existing wiring tests, syntax and diff checks recorded separately.

## Subsequent host verification / stop point (owner-reported)

Owner synchronized the latest CSS and mobile.spec.js to an isolated host checkout:
- New keyboard-height regression against OLD CSS: expected menu-visibility failure reproduced on BOTH Chromium and WebKit.
- Fixed CSS: mobile E2E 20 passed, no failures.
- Related editing/files E2E: 37 passed, 1 existing WebKit clipboard skip, no failures.
- JS wiring: 7 passed again.
- Existing Mac Readit checkout remains clean main at baseline 460b0c8; not modified.

These are owner-reported HOST results, not additional phone browser/IME runs. Prior Moon 28 success remains host evidence as well. Android phone evidence remains: actual wasm synthetic 229 backward/forward/selection deletion, CSS-only hot application preserving dirty C, real Readit menu save to exact disk 43 0a and has_unsaved=false, followed by successful standard image-content read. Neither host E2E nor phone synthetic input proves physical Japanese IME conversion/deletion/newline or native finger gestures.

Owner independently read-only confirmed phone verify-delete-tools.txt bytes 43 0a and preservation of the pre-update 98 committed-entry digest. Current reported Android Pi state is 7 sessions / 170 entries, agent idle, auth/GitHub connected; later history growth is task continuation. This agent did not inspect history/auth to repeat that check. Owner reports Android Pi changes pushed to its origin/main as f63f330; that is NOT a Readit commit. Readit remains uncommitted/unpushed per scope.

Current Preview is reported NOT foreground. This doc-only pass did not open, reload, capture, edit, save or otherwise mutate browser/application state, and did not rerun tests. No source/test changes or commit/push performed in this stop pass. The prior owned server/Preview were not stopped by this agent; no new live-state check is claimed.

Remaining acceptance gaps: real Japanese IME conversion/deletion/newline, native finger scrolling and actual unsaved-confirmation flow on device. Stop here until separately authorized continuation; do not auto-open/reload/capture the background Preview.
