# Real Samsung soft IME result — host GUI assistance / phone independent verification

## Scope and provenance

本人の指操作は未検証、host ADBからの実ソフトIME変換・confirmed deletion・newlines・menu Saveは検証済み。

Owner explicitly authorized inspection of this public Readit screen and keyboard/candidate area for host GUI assistance. Host operated real Samsung HoneyBoard by ADB touch injection, NOT direct Japanese text insertion via JS/CDP and NOT phone agent's own ADB actions. Only public verify-real-ime-next.txt was targeted. Earlier failed adb input text nihongo attempt is a separate historical result, not conversion evidence.

## Host-reported real IME operation/results

12-key flick input にほんご -> image-observed 日本語 candidate tap -> wasm 日本語 -> real Backspace-key tap -> 日本 -> real newline-key tap -> flick かくにん -> image-observed 確認 candidate tap -> real newline-key tap -> image-observed File/Save tap.

Before Save: wasm lines 日本 / 確認 / empty, composing=false, dirty=true; disk still original0bytes. After Save: dirty=false / readitIdle=true. Host image showed three lines, no dirty mark, 保存しました.

Observer saw real key229, trusted compositionstart/update, beforeinput/input insertCompositionText with dataLength changes (e.g.1 to4). compositionendがisTrusted=falseだったことを観測、発生元は未特定。 The earlier internal commit/fallback explanation was speculation: owner found no compositionend generation in the inspected Readit input.js. Do not infer its source from isTrusted=false. isTrusted alone does NOT determine human/IME provenance. Later-installed observers sometimes missed delete/newline events; event count0 is not proof of non-operation. Actual keyboard taps and wasm transitions establish those steps.

Preview became background during the attempt and initial に committed. Host checked owner/runtime/existing task before refocus; lock metadata showing=false/inputRestricted=false, no unlock bypass or timeout/security setting changes. Cause NOT established as autoLock. No open/reload to erase preedit; only the already committed self-input character was removed via real Delete before the new word. At expiry of a10-minute metadata/wake lease, host installed a separate5-minute continuation observer without destroying preedit. Temporary wake was scoped to active verification. Owner subsequently reports confirming post-save dirty=false/composing=false and explicitly stopping/releasing temporary screen wake and ALL observers from host. This is host-reported cleanup, not a new phone-agent action or independent runtime check.

New guard lesson: wasm.has_unsaved=false can coexist with native preedit. Before update/reload/open or another destructive action, also check composing/preedit state. After selecting a file, wait until target tab selected AND idle before editing. No source changes implementing this lesson in this record-only pass.

## Independently verified by this phone agent

1. Read ONLY public verify-real-ime-next.txt with Node fs:14bytes, hex e697a5e69cac0ae7a2bae8aa8d0a, exact UTF-8 日本\n確認\n.
2. pi-browser status: available=true/debugging=true, matching owned URL http://127.0.0.1:42843/, preview PID6985.
3. pi-browser screenshot invoked ONCE to .verify-preview-07f2afcd/real-soft-ime-saved-01.png. Success, no fallback/retry/open/reload.
4. Standard read tool returned actual Native WebView-only image content. Selected verify-real-ime-next.txt; line1 日本, line2 確認, line3 empty; no visible dirty indicator; bottom 保存しました · verify-real-ime-next.txt and 3:1 · text. Header/menu legible; drawer/menu closed. No keyboard/host-screen crop copied into history. Pixel image does not independently read wasm.has_unsaved; dirty=false/idle facts above remain host-reported.

Private preparation receipt updated with current imeConversionVerified=true, method/provenance, host vs phone evidence, manualOperationsPerformed=false and humanFingerOperationsVerified=false. Historical originalEmptyFixtureRestored=true refers ONLY to cleanup of earlier nihongo attempt, not current saved file. Prior report retained.

## Stop point

Only public disk read, status, one WebView screenshot/read, docs/receipt updates performed. No save replay, input, focus, reload/open, source/package changes, private/credential/clipboard/other-app access or commit/push. Preview/server not stopped. Saved public Japanese content remains displayed.

Remaining: user's own finger/keyboard operation, native finger scrolling and actual unsaved-confirmation flow. Host-assisted real soft IME acceptance is now supported, separate from earlier synthetic events and host E2E20 / editing-files37 pass+1skip / wiring7 / Moon28 results.
