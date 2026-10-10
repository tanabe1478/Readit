# Hardware capture / actual image-content read

Executed pi-browser screenshot ONCE to .verify-preview-07f2afcd/readit-mobile-vision-hardware-01.png. Capture returned that path successfully. Used standard read tool on that PNG and received actual image content. No canvas eval/toDataURL, source reading, DOM text inference or alternative image extraction.

The bottom-right light-blue marker is visible and its five characters read directly from the image are: R8L9C. Thus capture-to-standard-read-to-model vision path succeeded in this pass; no independent pixel check was performed by this agent.

Visual observations from image only: dark Readit header with hamburger / fixture name / 開く readable; Readit, ファイル, 編集, 表示, 移動 menus fit. README.md selected, drawer and menus closed. Public README heading and Japanese source lines readable with line numbers and wrapping. Body begins at line 1 in this image. Navigation row extends to right edge with a further partially clipped control; swipe reachability/page overflow not established from a static image. Bottom source line clipped at status boundary; light-blue test marker overlays part of lower-right body. Status 1:1 · markdown visible.

No screen change, reload, input/edit/save, IME operation or retry performed. No private/Pi/keyboard/toolbar/whole-window capture requested. Preview and owned server left open. No commit/push of PNG, runtime logs or other changes. Actual edit/save bytes, native touch scrolling and Japanese IME remain separate future verification; vision success does not establish those acceptance conditions.
