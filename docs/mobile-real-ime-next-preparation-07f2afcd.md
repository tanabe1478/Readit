# Real Japanese IME manual test preparation (no manual input yet)

Created previously absent .verify-preview-07f2afcd/verify-real-ime-next.txt with wx/0600 and ZERO bytes. Never wrote expected input in advance or changed existing fixture files. Exclusive private preparation receipt: .verify-runtime-07f2afcd/real-ime-next-preparation.json. Stage prepared-waiting-for-user; manualOperationsPerformed=false.

Read existing server-tools-state.json and verified recorded args include owned public fixture and clone web root. From agent runtime, kill(6944,0) succeeded (live); loopback HTTP returned200 (response body discarded, no token extraction). Did not access /proc/cmdline or classify EPERM/EACCES as dead. No server start/duplicate attempted. Existing URL http://127.0.0.1:42843/ reused.

Initial pi-browser status unavailable/debugging=false. One explicitly authorized open for this new manual test, then status available/debugging=true, preview PID6985 at owned URL. docs/prepare-real-ime-next-07f2afcd.mjs executed ONCE: ready/idle, owned public-project caption and wasm.has_unsaved=false checked before drawer/file selection. File row available without reload; reload count ZERO. Drawer selected verify-real-ime-next.txt. File empty on disk, dirty=false, activeElementId=app (NOT editor-input), document visibility visible. No editor auto-focus, typing, keyboard dispatch, save or screenshot performed. No previous edit/continuation script replayed.

## Native-only metadata collector

Installed observer only on existing editor-input, without altering/stopping handlers, global session __readitRealImeNext07f2afcd, id real-ime-next-07f2afcd-native-01. Receipt stores setup metadata/deadline; event metadata lives in page memory, not cookies/storage. Max128 events, automatic detach within20 minutes or at limit. On other selected files it collects nothing. Guard requires #tab-selected[data-tab] exactly verify-real-ime-next.txt and event.isTrusted=true, excluding synthetic-event tests.

Allowed fields: elapsedMs, event type; keyCode229 ONLY for qualifying keydown; inputType, isComposing, cancelable/defaultPrevented, dataLength, isTrusted. Observes compositionstart/update/end and beforeinput/input. NO actual key characters, event.data content, input.value, candidate/clipboard/private values, cookies/storage/secrets. Installed after preparation, recordedEvents=0. Expiry/page loss means missing evidence, not a failed/successful IME conclusion; do not repeat manual input automatically. Subsequent extraction must remain limited to this owned metadata session.

## User operations to perform on the public file

1. Tap editor body yourself (agent has not focused it).
2. Type にほんご using your Japanese soft keyboard, convert to 日本語 and commit.
3. One Backspace: expected 日本.
4. Newline.
5. Type かくにん, convert to 確認 and commit.
6. Newline.
7. File menu -> Save.

Expected final public UTF-8 content: 日本\n確認\n. This expectation is NOT current file content; file is still empty at preparation. Agent will inspect public document/disk bytes only AFTER user reports completing the specified input. Real IME results must be separate from host E2E and earlier phone synthetic229 evidence.

IMPORTANT: do not return to Pi, reload, update APK or close Preview while unsaved. If conversion/deletion/newline looks wrong or Save fails, STOP and report what step failed; don't reload or repeat the whole sequence. Keep Preview foreground for manual work. Collector lasts at most20 minutes; if expired, report that and arrange a new authorized metadata session without overwriting/replaying input.

At stop: empty public verification file selected, Preview and existing owned server open, no unsaved content per preflight/selection checks. No screenshot/save mutation/commit/push, package/baseline/auth modifications, private project/keyboard-candidate capture or desktop browser installation. Waiting for human, not claiming real IME acceptance success.

## Subsequent Android-injected attempt (owner-reported; record-only pass)

At the user's request to have the agent operate, host opened the same owned Readit once, selected only public verify-real-ime-next.txt, checked asynchronous selection state read-only and focused its editor. Original human collector was stopped; a separate metadata-only session __readitAndroidInjectedIme was used. This was NOT user hand input and must not be merged into the original manual session.

Android InputManager injection via `adb input text nihongo` reached the actual wasm document as nihongo. Metadata showed insertText events, composing=false, and ZERO compositionstart/update/end. Conversion key214 was sent once but did not enter composition or convert to Japanese. Therefore Japanese IME conversion was NOT verified, and no save was performed.

IMPORTANT correction to the collector's interpretation: event.isTrusted=true also occurs for Android-injected input. A trusted-only filter excludes ordinary JS-dispatched synthetic events, but DOES NOT prove human hand input, soft-keyboard IME conversion, or native finger gestures. Determine provenance from the actual operation method; require separate composition/conversion evidence rather than trusted status alone. The original collector implementation is left unchanged in this record-only pass, and its prior description is not a success claim.

After confirming the public document contained only the injected nihongo, host sent seven Android Backspaces to remove only its own text. Owner independently confirmed editor empty=true, wasm dirty=false and disk0bytes, restoring the original empty public fixture. Temporary observer and three-minute wake were stopped/released. No private keys, keyboard candidates, clipboard or keyboard image were obtained.

Private real-ime-next-preparation.json updated with manualOperationsPerformed=false retained, androidInjectedAttemptPerformed=true, imeConversionVerified=false and originalEmptyFixtureRestored=true. Attempt details and restoration facts are marked owner-reported, not independent phone-agent checks. Original manual-preparation stage and collector setup record remain historical; collector no longer running per owner report.

This phone pass only read/updated preparation receipt and this doc. No browser mutation/readiness check, additional input, capture, save, package/root-source change or commit/push. Stop here. At that stop point, remaining acceptance gaps included real Japanese IME conversion/deletion/newline, native finger scrolling and actual unsaved-confirmation flow.

## Subsequent successful host-assisted real soft IME pass

See mobile-real-soft-ime-result-07f2afcd.md for provenance, observer limitations and independent phone bytes/image checks. 本人の指操作は未検証、host ADBからの実ソフトIME変換・confirmed deletion・newlines・menu Saveは検証済み。 This used real Samsung HoneyBoard flick/candidate/key taps through ADB touch injection, not JS/CDP insertion of Japanese.

Phone agent independently read public disk14bytes, hex e697a5e69cac0ae7a2bae8aa8d0a, exact 日本\n確認\n, and captured the foreground public WebView ONCE then read actual image content with standard read. Image shows 日本 / 確認 / empty, no dirty mark and 保存しました. No save replay or browser mutation in this verification pass.

Receipt now separates historical failed nihongo injection/empty restoration from current successful saved Japanese content; manualOperationsPerformed remains false (no user's own finger input). Trusted native compositionstart/update support the real-IME path. compositionendがisTrusted=falseだったことを観測、発生元は未特定。 Earlier internal commit/fallback attribution was speculation; owner found no compositionend generation in inspected Readit input.js. Missing observer events do not imply missing taps. Never use isTrusted alone to infer human or IME provenance.

Future destructive-action guards must consider native composing/preedit in addition to wasm.has_unsaved; false dirty can coexist with preedit. Await selected target tab AND idle after file selection. Background cause was not established as autoLock; no security bypass/settings change reported. No source/package changes, commit/push; stop pending further authorization. Remaining own-finger operation, native finger scrolling and unsaved-confirmation checks are separate.

Owner subsequently reports verifying post-save dirty=false/composing=false and explicitly stopping/releasing temporary screen wake and ALL observers from host. Native public image independent-verification success and the real keyboard candidate/document-transition/saved-bytes evidence are unchanged. This correction pass modifies docs only: no new browser/input/save/capture/runtime check, source/package change or commit/push.
