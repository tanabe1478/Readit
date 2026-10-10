// Read-only inspection after the failed save-menu action. No blur/reload/retry.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
export default async ({ page }) => {
  if (page.url() !== 'http://127.0.0.1:42843/') throw Error('Wrong owned preview');
  const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const state = await page.evaluate(async () => {
    const { wasm } = await import('/glue/bridge.js');
    const el = document.querySelector('#topbar .menu-title[data-arg="ファイル"]');
    const bar = el?.parentElement;
    return { dirty: !!wasm.exports.has_unsaved(), ready: window.readitReady, idle: window.readitIdle(),
      visibility: document.visibilityState, activeElementId: document.activeElement?.id,
      viewport: { width: innerWidth, height: innerHeight, visualHeight: visualViewport?.height },
      menuDisplay: el ? getComputedStyle(el).display : null,
      menubarDisplay: bar ? getComputedStyle(bar).display : null,
      menuHasBox: !!el?.getClientRects().length,
      selectedOwnFixture: !!document.getElementById('tab-selected')?.textContent.includes('verify-delete-tools.txt'),
    };
  });
  const bytes = fs.readFileSync(path.join(repo,'.verify-preview-07f2afcd/verify-delete-tools.txt'));
  const result = { ...state, diskHex: bytes.toString('hex'), diskStillInitial: bytes.equals(Buffer.from('日本語ABC\n')) };
  fs.writeFileSync(path.join(repo,'.verify-runtime-07f2afcd/delete-tools-inspection.json'),JSON.stringify(result,null,2),{flag:'wx',mode:0o600});
  console.log(JSON.stringify(result));
};
