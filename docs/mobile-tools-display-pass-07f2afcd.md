# 0.7.4-tools phone CLI and display pass

Within the same isolated clone, ordinary `npm --version` and `npx --version` both returned 11.20.0 without the former fixed-shebang error. No package download/install, Node/npm/Moon upgrade or baseline rewrite performed by this agent.

`node --experimental-vm-modules --test web/tests/unit/input.test.mjs`: 7 passed, 0 failed on Android. This is JS wiring evidence, not real IME or wasm save verification. Owner-reported host tests remain distinct from phone results.

Checked owned old server-state.json PID 32350 with kill(pid,0): ESRCH/dead. server-tools-state.json absent. pi-browser status initially available=false/debugging=false. Old ownership and stderr records were not deleted or overwritten.

Created new private start-tools.mjs with exclusive wx, using the original launcher with a second old-PID guard and new server-tools-state.json / server-tools.stderr.log names. New state initial creation and stderr file use wx/0600 in existing 0700 runtime directory. Started detached Node child ONCE using existing generated web/dist/server.js, --web-root <clone>/web --port 0 and the SAME .verify-preview-07f2afcd public project. stdin/stdout ignored; stderr only to the new owned log, not dumped. New server readiness succeeded: PID 6944, http://127.0.0.1:42843/. Exact executable/args/start time retained in new private ownership record for later owned shutdown.

pi-browser open new URL invoked ONCE. status: available=true/debugging=true, preview PID 6985, matching loopback URL. New private check-display-tools.mjs checks owned URL and only selected public display facts:
- readitReady=true, readitIdle=true
- visibility=visible; documentHasFocus=false (not keyboard-focus proof)
- viewport 360x682, DPR 3, visual viewport 360x682.6667
- drawer hidden, toggle present, aria-expanded=false
- public README selected and its known public heading rendered

No timeout/failure/retry of start, open or run. No screenshot/read, reload, editing, saving or IME action in this pass. Therefore new hardware-surface capture path is NOT yet verified on device. Preview and new owned server deliberately left open. No secrets/private projects/clipboard/candidates/other apps read; no commit/push. Next pass must capture and read actual image with visual marker to test the capture improvement, separately from any later edits/save/real IME evidence.
