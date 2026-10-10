# Same-preview image read pass

Host report received: corrected mobile E2E Chromium/WebKit 18 passed, wiring 7 and Moon 28 passed. These are host results, not Android editing/IME evidence.

Executed pi-browser screenshot ONCE to .verify-preview-07f2afcd/readit-mobile-vision-01.png; returned the file path successfully. Read that PNG directly with standard read tool; tool returned actual image content, not text/DOM extraction. No base64, canvas eval/toDataURL/source extraction, reload, navigation, editing, save or IME action performed. Preview and owned server left open. PNG/runtime logs not committed or pushed.

Visual observations based ONLY on the returned image:
- Dark Readit UI, header with hamburger, readit, fixture folder label and 開く button is legible.
- Menu row Readit / ファイル / 編集 / 表示 / 移動 fits visibly. README.md tab selected; no open menu or drawer shown.
- README source with line numbers is visible; Japanese public sample text and edit.txt / src/sample.js reference are readable and wrap. No code file selected in this capture.
- Navigation row (arrows, 定義, 使用箇所, シンボル, 固定) extends beyond the right edge; a further control is only partially visible. This image does not establish swipe reachability or full-page horizontal overflow.
- Body top is partway through line 3 and clipped at the navigation boundary; bottom line 13 is clipped at the status boundary. Cannot determine from a single unchanged capture whether normal scroll position or a layout defect caused it. Status shows 1:1 · markdown.
- IMPORTANT: no light-blue marker or five-character alphanumeric string is visible in the image returned by read, including the bottom-right region. Cannot transcribe the requested marker and will not infer it from DOM or prompt. Image capture/read succeeded for Readit, but marker-based vision challenge is NOT verified.

Next deficiency: owner should confirm marker is on the same foreground preview and included in screenshot capture; any further capture requires a separate pass, not an automatic retry. Need later public-fixture screenshot after authorized UI investigation, actual edits/save bytes, native scrolling and separately real Japanese IME evidence. No UI/code fix made in this capture-only pass.
