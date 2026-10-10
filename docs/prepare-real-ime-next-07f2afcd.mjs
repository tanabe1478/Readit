// Prepare only. Never type/focus editor/save; do not replay after failure.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
export default async ({page}) => {
  const repo=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const receiptFile=path.join(repo,'.verify-runtime-07f2afcd/real-ime-next-preparation.json');
  const receipt=JSON.parse(fs.readFileSync(receiptFile,'utf8'));
  if(receipt.stage!=='empty-file-created')throw Error('STOP: preparation already attempted');
  const record=(stage,details={})=>{receipt.stage=stage;Object.assign(receipt,details);fs.writeFileSync(receiptFile,JSON.stringify(receipt,null,2),{mode:0o600});};
  const assert=(v,m)=>{if(!v)throw Error(m);};
  const guard=()=>page.evaluate(async()=>{
    const {wasm}=await import('/glue/bridge.js');
    return {dirty:!!wasm.exports.has_unsaved(),ownedProject:!!document.querySelector('.brand .caption')?.textContent.includes('.verify-preview-07f2afcd')};
  });
  try {
    record('preview-check-pending');
    assert(page.url()===receipt.url,'Unexpected URL');
    await page.waitForFunction(()=>window.readitReady===true&&window.readitIdle(),{timeout:10000});
    const before=await guard();assert(before.ownedProject&&!before.dirty,'STOP wrong project or dirty');
    record('clean-owned-preview',before);
    const toggle=page.locator('#topbar [data-act="sidebar"]');
    record('drawer-pending');
    if(await toggle.getAttribute('aria-expanded')!=='true')await toggle.click({timeout:5000});
    const row=page.locator('.tree-row[data-tree="verify-real-ime-next.txt"]');
    if(await row.count()===0){
      const safe=await guard();assert(safe.ownedProject&&!safe.dirty,'STOP unsafe reload');
      record('reload-pending');
      await page.reload({timeout:10000}); // At most once; never replay.
      await page.waitForFunction(()=>window.readitReady===true&&window.readitIdle(),{timeout:10000});
      const reloaded=await guard();assert(reloaded.ownedProject&&!reloaded.dirty,'STOP reloaded wrong/dirty');
      receipt.reloadedOnce=true;record('reloaded-clean');
      if(await toggle.getAttribute('aria-expanded')!=='true')await toggle.click({timeout:5000});
    }
    assert(await row.count()===1,'New public row not available');
    record('select-empty-file-pending');
    await row.click({timeout:5000});
    await page.waitForFunction(()=>window.readitIdle(),{timeout:10000});
    const selected=await page.evaluate(async()=>{
      const {wasm}=await import('/glue/bridge.js');
      return {selectedFile:document.querySelector('#tab-selected[data-tab]')?.dataset.tab,
        dirty:!!wasm.exports.has_unsaved(),activeElementId:document.activeElement?.id,visibility:document.visibilityState};
    });
    assert(selected.selectedFile==='verify-real-ime-next.txt'&&!selected.dirty,'Wrong selected/dirty file');
    assert(selected.activeElementId!=='editor-input','STOP unexpected automatic editor focus');
    assert(fs.statSync(path.join(repo,'.verify-preview-07f2afcd/verify-real-ime-next.txt')).size===0,'Fixture no longer empty');
    record('empty-file-selected',selected);
    record('collector-install-pending');
    const collector=await page.evaluate(()=>{
      const name='__readitRealImeNext07f2afcd';
      if(window[name])throw Error('Collector already installed; do not replace');
      const input=document.getElementById('editor-input');
      const session={id:'real-ime-next-07f2afcd-native-01',startedAt:Date.now(),deadline:Date.now()+20*60*1000,
        active:true,events:[],limit:128,stopReason:null};
      const types=['keydown','compositionstart','compositionupdate','compositionend','beforeinput','input'];
      let timer;
      const stop=reason=>{session.active=false;session.stopReason=reason;for(const type of types)input.removeEventListener(type,collect);clearTimeout(timer);};
      const collect=e=>{
        if(!session.active)return;
        if(Date.now()>=session.deadline){stop('expired');return;}
        if(document.querySelector('#tab-selected[data-tab]')?.dataset.tab!=='verify-real-ime-next.txt')return;
        if(!e.isTrusted)return; // Keep synthetic tests out of this native-only session.
        if(e.type==='keydown'&&e.keyCode!==229)return; // Never collect actual key characters.
        session.events.push({elapsedMs:Date.now()-session.startedAt,type:e.type,
          inputType:typeof e.inputType==='string'?e.inputType:null,isComposing:!!e.isComposing,
          cancelable:e.cancelable,defaultPrevented:e.defaultPrevented,
          dataLength:typeof e.data==='string'?e.data.length:0,
          ...(e.type==='keydown'?{keyCode:229}:{}),isTrusted:true});
        if(session.events.length>=session.limit)stop('limit');
      };
      for(const type of types)input.addEventListener(type,collect); // Passive observation after existing handlers.
      timer=setTimeout(()=>stop('expired'),20*60*1000);
      session.stop=()=>stop('manual');window[name]=session;
      return {sessionId:session.id,deadline:session.deadline,maxEvents:session.limit,trustedOnly:true,
        selectedFileOnly:'verify-real-ime-next.txt',recordedEvents:session.events.length};
    });
    record('prepared-waiting-for-user',{collector,manualOperationsPerformed:false});
    console.log(JSON.stringify({stage:receipt.stage,selected,collector,reloadedOnce:!!receipt.reloadedOnce}));
  }catch(error){record(receipt.stage+'-failed',{error:String(error.message||error)});throw error;}
};
