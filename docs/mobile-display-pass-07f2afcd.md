# Public Android preview display pass

Baseline/branch remain 460b0c86e6aadc4fb3e6214f98a40cc2129ef124 / android/mobile-07f2afcd. No commit, push, auth/history changes or desktop browser installation/launch.

## Host receipt

Read docs/android-build-receipt-07f2afcd.json. All 41 supplied artifact SHA-256 hashes and input.js hash match. MoonBit compiled on isolated macOS host, not phone. Host reported wiring 7, moon 28, existing mobile E2E 16 passed; new E2E 2 failed. No claim that the newly revised E2E passed.

## E2E correction

Playwright 1.63 injected dispatchEvent implementation switches on known event categories and falls back to new Event(type, eventInit). No InputEvent constructor case exists in that implementation. Generic Event drops InputEventInit.inputType. Confirmed on actual preview WebView by constructing, but NOT dispatching, Event/InputEvent: genericIsInputEvent=false, genericHasInputType=false; explicitIsInputEvent=true, explicitInputType=deleteContentBackward.

web/tests/e2e/mobile.spec.js now uses input.evaluate to construct and dispatch new InputEvent('beforeinput', ...). Adds explicit assertions for event interface, inputType and defaultPrevented. Original rendered wasm text and saved file content assertions unchanged. Awaiting isolated host rerun of both browser projects. Syntax and wiring tests locally checked, not E2E execution.

## Owned public fixture/server

Created previously absent .verify-preview-07f2afcd containing only generated public README.md (Japanese reading/scroll fixture), edit.txt = 日本語ABC + newline, src/sample.js (80 harmless sample lines). Separate .verify-runtime-07f2afcd directory mode 0700 holds launcher/check scripts and private PID/readiness record and stderr log (0600). Log is only this owned server's stderr and has not been dumped. No token/private DOM collected or displayed.

Launcher: node .verify-runtime-07f2afcd/start.mjs, detached Node child, stdin/stdout ignored, --web-root <repo>/web --port 0 <repo>/.verify-preview-07f2afcd. No browser opener used. Server ready first attempt, PID 32350, URL http://127.0.0.1:46793/. Exact executable/arguments and start time in private server-state.json identify the owned server for later shutdown; do not kill arbitrary listeners or restart without inspecting state.

## Actual display checks

- pi-browser open http://127.0.0.1:46793/ invoked ONCE. Response requested=true, keep app foreground.
- pi-browser status: available=true, debugging=true, matching loopback URL, preview PID 29841.
- check-display.mjs on owned URL: readitReady=true, readitIdle=true, document.visibilityState=visible; document.hasFocus=false (do not claim keyboard focus). Layout viewport 360x682, DPR 3; visual viewport 360x682.6667. Drawer initially hidden, toggle present, aria-expanded=false. Public README selected and rendered.
- check-drawer.mjs: opened via preview automation click, visible=true / expanded=true / public README row exists. Selecting that README closed drawer and kept public README rendered / idle=true / visibility=visible. These are automation clicks, NOT evidence of native finger gesture/IME interaction.
- No open/run timeout or failed display action. No retries. No snapshot/screenshot capture or image read in this pass (as requested).
- Preview and server deliberately left open for owner and next image-reading pass.

## Next short pass

Host rerun corrected E2E without weakening expectations. Next phone pass: screenshot THIS same public preview, read image, inspect visible layout and fix any observed issue. Then independently validate actual wasm edits and exact saved fixture bytes. Real Japanese IME conversion/deletion/newline and native touch scrolling remain separate unverified evidence; no candidate/clipboard/private-project capture.
