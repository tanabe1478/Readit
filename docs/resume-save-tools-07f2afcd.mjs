// One-shot CSS-only hot load and save continuation. NEVER rerun after failure.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const runtime = path.join(repo, '.verify-runtime-07f2afcd');
const file = path.join(repo, '.verify-preview-07f2afcd/verify-delete-tools.txt');
const initial = Buffer.from('日本語ABC\n'), final = Buffer.from('C\n');
export default async ({ page }) => {
  const receiptFile = path.join(runtime, 'save-resume-tools-receipt.json');
  const receipt = { status: 'running', stage: 'preflight', events: [] };
  fs.writeFileSync(receiptFile, JSON.stringify(receipt,null,2), {flag:'wx',mode:0o600});
  const record = (stage, details = {}) => {
    receipt.stage=stage; receipt.events.push({stage,at:new Date().toISOString(),...details});
    fs.writeFileSync(receiptFile, JSON.stringify(receipt,null,2), {mode:0o600});
  };
  const assert = (v,m) => { if(!v) throw Error(m); };
  const state = () => page.evaluate(async () => {
    const { wasm } = await import('/glue/bridge.js');
    const selectedOwnFile = document.getElementById('tab-selected')?.textContent.includes('verify-delete-tools.txt');
    if (!selectedOwnFile) throw Error('Not owned public verification file');
    const code=document.querySelector('#editor-content .row[data-line="0"] .code');
    const walker=document.createTreeWalker(code,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('.eol')?2:1});
    let text=''; for(let n=walker.nextNode();n;n=walker.nextNode()) text+=n.data;
    return {text,dirty:!!wasm.exports.has_unsaved(),ready:window.readitReady,idle:window.readitIdle()};
  });
  try {
    assert(page.url()==='http://127.0.0.1:42843/','Wrong owned URL');
    const previous=JSON.parse(fs.readFileSync(path.join(runtime,'delete-tools-receipt.json'),'utf8'));
    assert(previous.status==='failed' && previous.stage==='save-menu-pending-failed','Unexpected previous receipt');
    assert(previous.events.some(e=>e.stage==='selection-verified'&&e.observed==='C'),'No verified C edit');
    const before=await state();
    assert(before.text==='C'&&before.dirty&&before.ready&&before.idle,'Unexpected current wasm state');
    assert(fs.readFileSync(file).equals(initial),'Disk changed since failed save');
    record('preflight-verified',{...before,diskHex:initial.toString('hex'),previousStage:previous.stage});
    record('css-link-update-pending');
    const applied=await page.evaluate(async () => {
      const { wasm } = await import('/glue/bridge.js');
      const original=wasm.exports;
      const link=document.querySelector('link[rel="stylesheet"][href*="style.css"]');
      if(!link) throw Error('Stylesheet link missing');
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(Error('CSS load timeout')),10000);
        link.addEventListener('load',()=>{clearTimeout(timer);resolve();},{once:true});
        link.addEventListener('error',()=>{clearTimeout(timer);reject(Error('CSS load failed'));},{once:true});
        link.href='/style.css?verify-save-tools-07f2afcd-01';
      });
      await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      const rect=el=>{const r=el.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
      return {sameWasm:original===wasm.exports,dirty:!!wasm.exports.has_unsaved(),
        viewport:{width:innerWidth,height:innerHeight},editor:rect(document.getElementById('editor-scroll')),
        menus:[...document.querySelectorAll('#topbar .menu-title')].map(el=>({display:getComputedStyle(el).display,...rect(el)})),
        menubarDisplay:getComputedStyle(document.querySelector('#topbar .menubar')).display,
        pathbarDisplay:getComputedStyle(document.getElementById('pathbar')).display};
    });
    assert(applied.sameWasm&&applied.dirty,'Hot CSS lost wasm/dirty state');
    assert(applied.editor.height>140,'Insufficient editor height');
    for(const m of applied.menus) assert(m.height>=44&&m.x>=0&&m.x+m.width<=applied.viewport.width+1,'Menu target hidden/clipped');
    const after=await state(); assert(after.text==='C'&&after.dirty,'Hot CSS lost edited text');
    assert(fs.readFileSync(file).equals(initial),'Disk changed before save');
    record('css-applied-verified',applied);
    record('file-menu-pending');
    await page.locator('#topbar .menu-title[data-arg="ファイル"]').click({timeout:5000});
    const menu=await page.locator('#menu-layer .menu-list').evaluate(el=>{
      const r=el.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,
        viewportWidth:innerWidth,viewportHeight:innerHeight,overflowY:getComputedStyle(el).overflowY,
        scrollHeight:el.scrollHeight,clientHeight:el.clientHeight};
    });
    assert(menu.x>=0&&menu.y>=0&&menu.x+menu.width<=menu.viewportWidth+1&&menu.y+menu.height<=menu.viewportHeight+1,'Menu outside viewport');
    assert(menu.overflowY==='auto','Menu not scrollable');
    record('file-menu-opened',menu);
    const save=page.locator('.menu-item[data-arg="save"]');
    await save.scrollIntoViewIfNeeded();
    const saveBox=await save.boundingBox(); assert(saveBox&&saveBox.height>=44,'Save target inaccessible');
    record('save-pending',{saveBox});
    await save.click({timeout:5000}); // One save action, never replay.
    for(let i=0;i<100&&!fs.readFileSync(file).equals(final);i++) await new Promise(r=>setTimeout(r,100));
    assert(fs.readFileSync(file).equals(final),'Saved disk bytes mismatch');
    await page.waitForFunction(async()=>{
      const {wasm}=await import('/glue/bridge.js');return window.readitIdle()&&!wasm.exports.has_unsaved();
    },{timeout:10000});
    const end=await state(); assert(end.text==='C'&&!end.dirty,'Final document not clean C');
    record('save-verified',{...end,diskHex:fs.readFileSync(file).toString('hex')});
    receipt.status='success';record('complete');
    console.log(JSON.stringify({status:'success',sameWasm:applied.sameWasm,keyboardViewport:applied.viewport,
      editorHeight:applied.editor.height,finalHex:'430a',dirty:false}));
  } catch(error) {
    receipt.status='failed';receipt.error=String(error.message||error);record(receipt.stage+'-failed');
    console.log(JSON.stringify({status:'failed',stage:receipt.stage,error:receipt.error}));throw error;
  }
};
