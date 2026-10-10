# Android real-wasm synthetic 229 deletion / save attempt

## Scope and scripts

Executed docs/verify-delete-tools-07f2afcd.mjs ONCE through pi-browser run on the owned public preview http://127.0.0.1:42843/. Script retained here for review; do NOT rerun: exclusive private receipt prevents repetition. New file .verify-preview-07f2afcd/verify-delete-tools.txt created with wx, UTF-8 日本語ABC\n (hex e697a5e69cace8aa9e4142430a). Existing edit.txt/user input untouched. No token value obtained/output. Only wasm.exports.has_unsaved accessed from bridge.

Initial ready/idle and has_unsaved=false checked, then one reload after new fixture creation and a second clean check. Opened drawer and selected new public file, confirmed selected tab and initial rendered text/disk. Synthetic Home/Right/Shift+Right controlled caret/selection; keydown229 plus explicit new InputEvent beforeinput used for each deletion.

## Passed on Android actual wasm

1. Backward delete at column 5: 日本語ABC -> 日本語BC.
2. Forward delete at resulting cursor: 日本語BC -> 日本語C.
3. Select first three characters via Home + three Shift+Right, backward delete: 日本語C -> C.

Each InputEvent was of correct interface/inputType and defaultPrevented=true. Each actual rendered document matched expectation, wasm.has_unsaved=true, Node fs disk bytes remained exactly original 日本語ABC\n. These are synthetic-event checks against actual phone wasm, NOT real Japanese IME conversion or finger gesture evidence.

## FAILED / stopped

At save-menu-pending, locator click of the ファイル menu timed out after 5000ms because the element was not visible. The underlying automation waited for visibility; no successful menu click or save command occurred. No external retry of run, edit or save; no direct fs write of edited bytes. Receipt records failure at save-menu-pending-failed and all prior completed stages. Exclusive original receipt remains .verify-runtime-07f2afcd/delete-tools-receipt.json.

Read-only postfailure inspection (docs/inspect-delete-tools-07f2afcd.mjs, run once) and pi-browser status:
- Matching owned URL, preview available/debugging=true.
- ready/idle=true, visibility=visible, selected own verify-delete-tools.txt.
- dirty=true, editor-input active.
- viewport 360x355; visual height 355.6667.
- menu element display inline-block but parent menubar display none, no menu box.
- disk bytes STILL e697a5e69cace8aa9e4142430a, exact initial fixture.
- inspection recorded exclusively in .verify-runtime-07f2afcd/delete-tools-inspection.json.

Static stylesheet contains a keyboard-height media rule hiding #topbar .menubar and #navbar. Observed reduced-height viewport and hidden parent explain unreachable File menu while editor input active. This is a newly reproduced practical save-access gap, not a save API failure. No source change in this pass after failure; no false save success claimed.

## Current state / next safe continuation

Preview and owned server left open with the public verification file C in memory, dirty=true; disk unchanged. Requested clean ending is NOT achieved because the failure-stop instruction was followed. No reload/discard/blur to hide the failure; no screenshot because requested after-save state was not reached. No keyboard/candidate/private capture. No commit/push.

Next pass must inspect this existing receipt/dirty/disk first. Do not recreate or repeat deletions. Decide a minimal reachable-menu fix for keyboard-height layout (with regression actually asserting save control availability, not weakening conditions), and/or explicitly authorized one-shot blur + save-only continuation. Then verify menu save once, exact disk 430a and has_unsaved=false, followed by public-file image read. Host mobile E2E 18, wiring 7 and Moon 28 successes remain distinct from this phone failure. Actual Japanese IME, native touch scrolling and unsaved cancellation remain unverified.
