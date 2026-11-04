const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = require('node:path').join(__dirname, '..', 'browser-bridge');
const hookSource = fs.readFileSync(root + '\\bridge-page-hook.js', 'utf8');
const contentSource = fs.readFileSync(root + '\\bridge-content.js', 'utf8');
const bgSource = fs.readFileSync(root + '\\background.js', 'utf8');
const convId = '12345678-1234-4123-8123-123456789abc';
const url = 'https://chatgpt.com/c/' + convId;
const baseCatalog = [
  {slug: 'gpt-6-thinking', title: 'GPT-6 Thinking', product_features: {reasoning_config: {supported_efforts: ['light', 'standard', 'extended', 'max']}}},
  {slug: 'gpt-6-pro', title: 'GPT-6 Pro', reasoning_config: {supported_efforts: ['standard','max']}},
];
let assertions = 0;
function check(ok, label) {
  assert.ok(ok, label);
  console.log('PASS ' + label);
  assertions++;
}
function mockResponse(data, ok=true) {
  return {ok, clone(){return mockResponse(data, ok)}, async json(){return data}};
}
function makeStreamResponse(chunks) {
  const enc = new TextEncoder();
  const mk = () => { let i = 0; return {ok:true, body:{getReader(){return {async read(){
    if (i >= chunks.length) return {done:true};
    return {done:false, value:enc.encode(chunks[i++])};
  }}}}, clone(){return mk()}}; };
  return mk();
}
function makeEnv({simulateClickFetch=false,rejectPost=false,rejectPatch=false,hangPatch=false,streamChunks=null,mainText='synthetic'}={}) {
  const store = new Map();
  const sent = [];
  const dataset = {};
  const winListeners = new Map();
  const textarea = {
    tagName: 'TEXTAREA',offsetParent:{}, value:'',isContentEditable:false,
    getAttribute(){return null}, focus(){}, dispatchEvent(){return true}
  };
  let clicks = 0;
  let listener = null;
  let sendAttempt = null;
  let ctx;
  const button = {disabled:false,offsetParent:{},getAttribute(){return null},click(){
    clicks++;
    if (simulateClickFetch) {
      sendAttempt = ctx.window.fetch('/backend-api/conversation',{
        method:'POST',body:JSON.stringify({model:'gpt-6-thinking',conversation_id:convId,
          messages:[{author:{role:'user'},content:{parts:[textarea.value]}}]})
      });
    }
  }};
  const toast = {style:{},textContent:'',_hideTimer:null};
  const doc = {
    readyState:'complete',
    documentElement:{dataset},
    title:'Synthetic local test',
    body:{innerText:'synthetic',appendChild(){}},
    getElementById(id){return id==='relaystudio-bridge-toast'?toast:null},
    querySelector(selector){
      if(selector==='#prompt-textarea') return textarea;
      if(selector==='button[data-testid="send-button"]') return button;
      if(selector==='main') return {innerText:mainText,textContent:mainText};
      return null;
    },
    querySelectorAll(selector){return selector.includes('send')||selector.includes('Send')||selector.includes('发送')? [button] : []},
    addEventListener(){},
  };
  const loc={href:url,pathname:'/c/'+convId,search:''};
  const origFetch=async (input,init)=>{
    const path = typeof input==='string'?input:input.url;
    const method = String(init?.method||input?.method||'GET').toUpperCase();
    const body = init?.body??(input instanceof Request ? await input.clone().text() : input?.body);
    sent.push({path,method,body:typeof body==='string'?body:null});
    if(path.includes('/api/auth/session')) return mockResponse({accessToken:'tok-test-123'});
    if(path.includes('/backend-api/models')) return mockResponse({models:baseCatalog});
    if(method==='PATCH' && path.includes('/backend-api/conversation/')) {
      if(hangPatch) return new Promise(()=>{});
      if(rejectPatch) return mockResponse({error:'simulated 500'},false);
      return mockResponse({success:true},true);
    }
    if(method==='POST' && streamChunks && /\/backend-api\/(?:f\/)?conversation(?:\?|$)/.test(path)) return makeStreamResponse(streamChunks);
    if(method==='POST' && rejectPost) return mockResponse({error:'simulated 400'},false);
    if(method==='GET'&&path.includes('/backend-api/conversation/')) return mockResponse({
      conversation_id:convId,default_model_slug:'gpt-6-thinking',
      mapping:{a:{message:{create_time:10,metadata:{thinking_effort:'extended',model_slug:'gpt-6-thinking'}}}}
    });
    return mockResponse({ok:true});
  };
  const fakeStorage={
    getItem(k){return store.has(k)?store.get(k):null},
    setItem(k,v){store.set(k,v)},
  };
  class FakeEvent {constructor(type,init){this.type=type;this.detail=init&&init.detail;}}
  const winObj={
    fetch:origFetch,Request,location:loc,history:{replaceState(){}},HTMLTextAreaElement:function(){},
    HTMLInputElement:function(){},CustomEvent:FakeEvent,
    addEventListener(type,fn){
      if(!winListeners.has(type))winListeners.set(type,new Set());
      winListeners.get(type).add(fn);
    },
    removeEventListener(type,fn){
      if(winListeners.has(type))winListeners.get(type).delete(fn);
    },
    dispatchEvent(ev){
      const set=winListeners.get(ev&&ev.type);
      if(set){for(const fn of Array.from(set))fn(ev);}
      return true;
    },
  };
  ctx={
    window:winObj,
    document:doc,localStorage:fakeStorage,URL,URLSearchParams,Request,TextDecoder,TextEncoder,
    navigator:{userAgent:'Chrome test fixture'},
    chrome:{runtime:{onMessage:{addListener(fn){listener=fn}},sendMessage(_msg, cb){if(cb)cb({shuttle_active:true})},lastError:null}},
    InputEvent:FakeEvent,Event:FakeEvent,KeyboardEvent:FakeEvent,CustomEvent:FakeEvent,
    clearTimeout(){},
    setTimeout(cb,delay){if(delay===700||delay===800||delay===1200||delay===3200)return 0;if(delay===2500){setImmediate(cb);return 0;}queueMicrotask(cb);return 0},
    setInterval(){return 0},console,Math,Date,
  };
  vm.createContext(ctx);
  vm.runInContext(hookSource,ctx,{filename:'bridge-page-hook.js'});
  vm.runInContext(contentSource,ctx,{filename:'bridge-content.js'});
  return {ctx,dataset,sent,store,textarea,get clicks(){return clicks},get sendAttempt(){return sendAttempt},
    getListener(){return listener}};
}
async function flush(){await new Promise(resolve=>setImmediate(resolve))}
async function main(){
  const e=makeEnv();
  check(typeof e.ctx.window.fetch==='function','MAIN-world fetch hook installed');
  await e.ctx.window.fetch('/backend-api/models',{method:'GET'});
  await flush();
  const cat=JSON.parse(e.dataset.relayModelsCatalog||'[]');
  check(cat.length===2&&cat[1].slug==='gpt-6-pro','Account model catalog captured');
  check(JSON.stringify(cat[1].efforts)==='["standard","max"]','Per-model effort options parsed');
  check(e.store.has('__relaystudio_models_cache__'),'Account model catalog cached');
  await e.ctx.window.fetch('/backend-api/conversation/'+convId,{method:'GET'});
  await flush();
  check(e.dataset.relayActiveModel==='gpt-6-thinking','Current conversation model captured');
  check(e.dataset.relayActiveEffort==='extended','Current conversation effort captured');
  e.dataset.relayOverrideModel='gpt-6-pro';
  e.dataset.relayOverrideEffort='max';
  await e.ctx.window.fetch('/backend-api/conversation',{method:'POST',body:JSON.stringify({model:'gpt-6-thinking',conversation_id:convId})});
  const first=JSON.parse(e.sent.at(-1).body);
  check(first.model==='gpt-6-pro'&&first.thinking_effort==='max','Outgoing POST receives model and effort');
  check(!e.dataset.relayOverrideModel&&!e.dataset.relayOverrideEffort,'Overrides cleared after one POST');
  await e.ctx.window.fetch('/backend-api/conversation',{method:'POST',body:JSON.stringify({model:'gpt-6-thinking'})});
  check(JSON.parse(e.sent.at(-1).body).model==='gpt-6-thinking','Next message does not inherit stale override');
  e.dataset.relayOverrideModel='gpt-6-pro';
  e.dataset.relayOverrideEffort='max';
  await e.ctx.window.fetch('/backend-api/f/conversation/prepare',{method:'POST',body:'{}'});
  check(e.dataset.relayOverrideModel==='gpt-6-pro','Prepare request retains override for final POST');
  await e.ctx.window.fetch('/backend-api/f/conversation',{method:'POST',body:'{}'});
  check(JSON.parse(e.sent.at(-1).body).thinking_effort==='max','Prefixed conversation endpoint overridden');

  const sentViaRequest=new Request('https://chatgpt.com/backend-api/conversation',{method:'POST',body:JSON.stringify({model:'gpt-6-thinking'})});
  e.dataset.relayOverrideModel='gpt-6-pro';
  e.dataset.relayOverrideEffort='max';
  await e.ctx.window.fetch(sentViaRequest);
  const bypass=JSON.parse(e.sent.at(-1).body);
  check(bypass.model==='gpt-6-pro'&&bypass.thinking_effort==='max','Request-object input is overridden with model and effort');
  e.dataset.relayOverrideModel='';
  e.dataset.relayOverrideEffort='';

  const f=makeEnv({simulateClickFetch:true});
  await f.ctx.window.fetch('/backend-api/models',{method:'GET'});
  await flush();
  const callbackResult=await new Promise((resolve,reject)=>{
    const accepted=f.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{
      id:'test-msg1', text:'离线测试文字',target_model:'gpt-6-pro',reasoning_effort:'最高'
    }},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  if(f.sendAttempt)await f.sendAttempt;
  check(f.clicks===1&&callbackResult.ok===true,'Content script clicks mock Send button and replies success');
  check(JSON.parse(f.sent.at(-1).body).model==='gpt-6-pro'&&JSON.parse(f.sent.at(-1).body).thinking_effort==='max','Full mock content->hook->fetch override applies');

  const g=makeEnv({simulateClickFetch:false});
  const falseAck=await new Promise((resolve,reject)=>{
    const accepted=g.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'test-msg2',text:'Offline no network'}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  check(falseAck.ok===false&&g.clicks===1&&g.sent.filter(x=>x.method==='POST').length===0,
    'Click without outgoing POST must NOT acknowledge delivery');

  const h=makeEnv({simulateClickFetch:true,rejectPost:true});
  const rejected=await new Promise((resolve,reject)=>{
    const accepted=h.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'test-msg3',text:'Simulated HTTP rejection',target_model:'gpt-6-pro',reasoning_effort:'最高'}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  check(rejected.ok===false&&h.sent.some(x=>x.method==='POST'),
    'Rejected HTTP POST must NOT acknowledge delivery');

  // ---- Spec v4.3: register task numbers once at the door, never scan the page text ------------------------------------
  const k=makeEnv({streamChunks:['data: {"t":"tool result tsk_a1b2','c3d4e5f6a7b8 saved"}\n\n','data: [DONE]\n\n'],mainText:'整页旧内容 tsk_deadbeef00112233 不应扫描'});
  await k.ctx.window.fetch('/backend-api/conversation',{method:'POST',body:JSON.stringify({model:'gpt-6-thinking',conversation_id:convId,messages:[{content:{parts:['接力 wfr_0123456789abcdef 开始']}}]})});
  for(let i=0;i<8;i++)await flush();
  const hintList=String(k.dataset.relayTaskHints||'').split(',');
  check(hintList.includes('tsk_a1b2c3d4e5f6a7b8'),'Stream chunk registers a task number even when it is split across two chunks');
  check(hintList.includes('wfr_0123456789abcdef'),'Outgoing request registers a handover wfr number');
  const tabState=await new Promise((resolve,reject)=>{
    const accepted=k.getListener()({type:'RELAY_COLLECT_TAB_STATE'},{},resolve);
    if(accepted===undefined)resolve(null);
  });
  check(tabState&&tabState.state&&tabState.state.page_hints.includes('tsk_a1b2c3d4e5f6a7b8'),'Tab state reports the registered task number as a page hint');
  check(!tabState.state.page_hints.includes('tsk_deadbeef00112233'),'Page text is NOT scanned for task numbers any more');
  check(tabState.state.is_archived===false&&typeof tabState.state.can_steer_live==='boolean','Tab state exposes is_archived and can_steer_live');

  // ---- Spec v4.3: live steering of a running turn by a manual follow-window instruction -------------------------------
  const sa=makeEnv({simulateClickFetch:true});
  sa.dataset.relaySseActive='1';
  const steered=await new Promise((resolve,reject)=>{
    const accepted=sa.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'steer-1',text:'实时引导',mode:'custom_message',manual_send:true}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  if(sa.sendAttempt)await sa.sendAttempt;
  check(steered.ok===true&&sa.clicks===1,'Manual instruction steers a running turn and is accepted');

  const sb=makeEnv({simulateClickFetch:true});
  sb.dataset.relaySseActive='1';
  const autoBusy=await new Promise((resolve,reject)=>{
    const accepted=sb.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'auto-1',text:'请继续',mode:'in_place_wakeup'}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  check(autoBusy.ok===false&&autoBusy.retry_safe===true&&autoBusy.reason==='busy_or_draft'&&sb.clicks===0,'Automatic wakeups still never type into a running turn');

  const sc=makeEnv({simulateClickFetch:false});
  sc.dataset.relaySseActive='1';
  const notTaken=await new Promise((resolve,reject)=>{
    const accepted=sc.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'steer-2',text:'塞不进去',mode:'custom_message',manual_send:true}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  check(notTaken.ok===false&&notTaken.retry_safe===true&&notTaken.reason==='steer_unavailable'&&sc.textarea.value==='',
    'Steering the page does not take -> steer_unavailable, composer cleaned, stop-loss can start');

  const sd=makeEnv({simulateClickFetch:true});
  sd.dataset.relayArchivedConv=convId;
  const archivedRes=await new Promise((resolve,reject)=>{
    const accepted=sd.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{id:'arch-1',text:'发给已归档',mode:'custom_message',manual_send:true}},{},resolve);
    if(!accepted)reject(Error('dispatch listener declined'));
  });
  check(archivedRes.ok===false&&archivedRes.retry_safe===true&&archivedRes.reason==='conv_archived'&&sd.clicks===0,
    'Archived conversation is judged on arrival (0 s): conv_archived, nothing typed');

  // ---- Spec True Receipt Gate: archive / unarchive / delete & HTTP 200 verification -----------------------------------
  const r1=makeEnv();
  const archOk=await new Promise((resolve,reject)=>{
    const accepted=r1.getListener()({type:'RELAY_ARCHIVE_CONVERSATION',conv_uuid:convId,operation:'archive'},{},resolve);
    if(!accepted)reject(Error('archive listener declined'));
  });
  const patch1=r1.sent.find(x=>x.method==='PATCH');
  check(archOk.ok===true&&archOk.operation==='archive'&&patch1&&JSON.parse(patch1.body).is_archived===true&&r1.dataset.relayLastArchivedUuid===convId&&r1.dataset.relayLastRetireOp==='archive',
    'Archive sends PATCH {is_archived: true} and resolves ok:true on HTTP 200');

  const r2=makeEnv();
  const unarchOk=await new Promise((resolve,reject)=>{
    const accepted=r2.getListener()({type:'RELAY_ARCHIVE_CONVERSATION',conv_uuid:convId,operation:'unarchive'},{},resolve);
    if(!accepted)reject(Error('unarchive listener declined'));
  });
  const patch2=r2.sent.find(x=>x.method==='PATCH');
  check(unarchOk.ok===true&&unarchOk.operation==='unarchive'&&patch2&&JSON.parse(patch2.body).is_archived===false&&r2.dataset.relayLastRetireOp==='unarchive',
    'Unarchive sends PATCH {is_archived: false} and resolves ok:true on HTTP 200');

  const r3=makeEnv();
  const delOk=await new Promise((resolve,reject)=>{
    const accepted=r3.getListener()({type:'RELAY_ARCHIVE_CONVERSATION',conv_uuid:convId,operation:'delete'},{},resolve);
    if(!accepted)reject(Error('delete listener declined'));
  });
  const patch3=r3.sent.find(x=>x.method==='PATCH');
  check(delOk.ok===true&&delOk.operation==='delete'&&patch3&&JSON.parse(patch3.body).is_visible===false&&r3.dataset.relayLastRetireOp==='delete',
    'Delete sends PATCH {is_visible: false} and resolves ok:true on HTTP 200');

  const rFail=makeEnv({rejectPatch:true});
  const archFail=await new Promise((resolve,reject)=>{
    const accepted=rFail.getListener()({type:'RELAY_ARCHIVE_CONVERSATION',conv_uuid:convId,operation:'archive'},{},resolve);
    if(!accepted)reject(Error('archive fail listener declined'));
  });
  check(archFail.ok===false&&!rFail.dataset.relayLastArchivedUuid,
    'True Receipt Gate: HTTP 500 on PATCH resolves ok:false and does NOT set relayLastArchivedUuid');

  const rTimeout=makeEnv({hangPatch:true});
  const archTimeout=await new Promise((resolve,reject)=>{
    const accepted=rTimeout.getListener()({type:'RELAY_ARCHIVE_CONVERSATION',conv_uuid:convId,operation:'archive'},{},resolve);
    if(!accepted)reject(Error('archive timeout listener declined'));
  });
  check(archTimeout.ok===false&&!rTimeout.dataset.relayLastArchivedUuid,
    'True Receipt Gate: 2500ms timeout resolves ok:false (never defaults to true)');

  // ---- Background shuttle retire_actions True Receipt Gate ------------------------------------------------------------
  function makeBgEnv({openTabs=[],archiveOk=true}={}) {
    const ackCalls=[];
    const removedTabs=[];
    const updatedTabs=[];
    const tabMessages=[];
    let currentArchiveOk=archiveOk;
    let currentTabs=openTabs;
    const bgCtx={
      navigator:{userAgent:'Mozilla/5.0 Chrome/125.0'},
      URL,console,Math,Date,
      setInterval(){return 0},
      setTimeout(){return 0},
      clearTimeout(){},
      fetch:async (u,init)=>{
        if(String(u).includes('/web-bridge/ack-retire')){
          ackCalls.push(JSON.parse(init.body));
        }
        return mockResponse({ok:true});
      },
      chrome:{
        sidePanel:{},
        storage:{local:{get(_k,cb){if(cb)cb({});},set(){}}},
        runtime:{onMessage:{addListener(){}},lastError:null},
        alarms:{create(){},onAlarm:{addListener(){}}},
        scripting:{async executeScript(){}},
        tabs:{
          onRemoved:{addListener(){}},
          async query(){return currentTabs;},
          async remove(id){removedTabs.push(id);},
          async update(id,props){updatedTabs.push({id,props});},
          sendMessage(tabId,msg,cb){
            tabMessages.push({tabId,msg});
            if(msg.type==='RELAY_STOP_GENERATION'){
              if(cb)cb({ok:true,stopped:true});
              return;
            }
            if(msg.type==='RELAY_ARCHIVE_CONVERSATION'){
              if(cb)cb({ok:currentArchiveOk,conv_uuid:msg.conv_uuid,operation:msg.operation});
              return;
            }
            if(cb)cb({ok:true});
          },
        },
      },
    };
    vm.createContext(bgCtx);
    vm.runInContext(bgSource,bgCtx,{filename:'background.js'});
    return {
      bgCtx,ackCalls,removedTabs,updatedTabs,tabMessages,
      setArchiveOk(v){currentArchiveOk=v;},
      setTabs(t){currentTabs=t;},
    };
  }

  const bgNoTabs=makeBgEnv({openTabs:[]});
  await bgNoTabs.bgCtx.handleShuttleRetireActions([{id:'ret_1',conv_uuid:convId,operation:'archive',close_tab:true}]);
  check(bgNoTabs.ackCalls.length===0&&bgNoTabs.removedTabs.length===0,
    'Background shuttle with 0 open tabs leaves retire action pending without ack-retire');

  const bgGate=makeBgEnv({
    openTabs:[
      {id:101,windowId:1,url:'https://chatgpt.com/c/'+convId},
      {id:102,windowId:1,url:'https://chatgpt.com/'},
    ],
    archiveOk:false,
  });
  await bgGate.bgCtx.handleShuttleRetireActions([{id:'ret_2',conv_uuid:convId,operation:'delete',stop_before_action:true,close_tab:true}]);
  check(bgGate.ackCalls.length===0&&bgGate.removedTabs.length===0,
    'Background shuttle does NOT close tab or ack-retire when cloud PATCH returns ok:false');

  bgGate.setArchiveOk(true);
  await bgGate.bgCtx.handleShuttleRetireActions([{id:'ret_2',conv_uuid:convId,operation:'delete',stop_before_action:true,close_tab:true}]);
  check(bgGate.ackCalls.length===1&&bgGate.ackCalls[0].retire_id==='ret_2'&&bgGate.ackCalls[0].operation==='delete'&&bgGate.ackCalls[0].ok===true&&bgGate.removedTabs.includes(101),
    'Background shuttle retries failed retire_id on next tick, closes tab and acks once cloud PATCH returns ok:true');

  const bgUnarch=makeBgEnv({
    openTabs:[
      {id:201,windowId:1,url:'https://chatgpt.com/c/'+convId},
      {id:202,windowId:1,url:'https://chatgpt.com/'},
    ],
    archiveOk:true,
  });
  await bgUnarch.bgCtx.handleShuttleRetireActions([{id:'ret_3',conv_uuid:convId,operation:'unarchive',close_tab:false}]);
  check(bgUnarch.ackCalls.length===1&&bgUnarch.ackCalls[0].operation==='unarchive'&&bgUnarch.removedTabs.length===0,
    'Background shuttle unarchive acks without closing tab');

  // ---- RelayCdp script_archive (app: protocol virtualized sidebar fallback) & FakeChatGptPage seam --------------------
  const { execFileSync } = require('node:child_process');
  const pyOut = execFileSync('python', ['-c', `
import json, sys
sys.path.insert(0, r'd:\\tool\\RelayStudio')
import RelayCdp
from tests.fake_chatgpt_page import FakeChatGptPage

scripts = {
    op: RelayCdp.script_archive('${convId}', op)
    for op in ('archive', 'unarchive', 'delete')
}

page = FakeChatGptPage(archive_fail_uuids={'fail-uuid-999'})
sess = RelayCdp.ChatGptDesktopSession(page.evaluate)
done = sess.execute_retire_actions([
    {'conv_uuid': 'uuid-arch-1', 'operation': 'archive'},
    {'conv_uuid': 'uuid-unarch-2', 'operation': 'unarchive'},
    {'conv_uuid': 'uuid-del-3', 'operation': 'delete'},
    {'conv_uuid': 'fail-uuid-999', 'operation': 'archive'},
])
print(json.dumps({
    'scripts': scripts,
    'done': done,
    'archived': page.archived_conversations,
    'unarchived': page.unarchived_conversations,
    'deleted': page.deleted_conversations,
}))
`], { encoding: 'utf8' });
  const pyData = JSON.parse(pyOut.trim());
  check(
    pyData.done.length === 3 &&
      pyData.archived.includes('uuid-arch-1') &&
      !pyData.archived.includes('fail-uuid-999') &&
      pyData.unarchived.includes('uuid-unarch-2') &&
      pyData.deleted.includes('uuid-del-3'),
    'ChatGptDesktopSession.execute_retire_actions & FakeChatGptPage support archive/unarchive/delete and True Receipt Gate'
  );

  async function evalCdpArchiveScript(scriptSrc, { ok = true } = {}) {
    const patchCalls = [];
    const cdpCtx = {
      location: { protocol: 'app:', href: 'app://-/index.html' },
      document: { querySelectorAll() { return []; } },
      fetch: async (u, init) => {
        if (String(u).includes('/api/auth/session')) {
          return mockResponse({ accessToken: 'cdp-tok' }, true);
        }
        patchCalls.push({ url: u, method: init.method, body: JSON.parse(init.body) });
        return mockResponse({ success: ok }, ok);
      },
    };
    vm.createContext(cdpCtx);
    const res = await vm.runInContext(scriptSrc, cdpCtx);
    return { res, patchCalls };
  }

  const cdpArch = await evalCdpArchiveScript(pyData.scripts.archive, { ok: true });
  check(cdpArch.res.ok === true && cdpArch.patchCalls.length === 1 && cdpArch.patchCalls[0].body.is_archived === true,
    'RelayCdp.script_archive(archive) falls back to PATCH {is_archived: true} even on app: protocol when sidebar row is virtualized');

  const cdpUnarch = await evalCdpArchiveScript(pyData.scripts.unarchive, { ok: true });
  check(cdpUnarch.res.ok === true && cdpUnarch.patchCalls.length === 1 && cdpUnarch.patchCalls[0].body.is_archived === false,
    'RelayCdp.script_archive(unarchive) sends PATCH {is_archived: false}');

  const cdpDel = await evalCdpArchiveScript(pyData.scripts.delete, { ok: true });
  check(cdpDel.res.ok === true && cdpDel.patchCalls.length === 1 && cdpDel.patchCalls[0].body.is_visible === false,
    'RelayCdp.script_archive(delete) sends PATCH {is_visible: false}');

  const cdpFail = await evalCdpArchiveScript(pyData.scripts.archive, { ok: false });
  check(cdpFail.res.ok === false,
    'RelayCdp.script_archive returns ok:false when PATCH fails (HTTP 500)');

  console.log(JSON.stringify({assertions,network:'OFFLINE_FAKE_ONLY',result:'PASS'}));
}
main().catch(e=>{console.error(e.stack);process.exitCode=1});
