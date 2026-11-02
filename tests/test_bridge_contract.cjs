const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = require('node:path').join(__dirname, '..', 'browser-bridge');
const hookSource = fs.readFileSync(root + '\\bridge-page-hook.js', 'utf8');
const contentSource = fs.readFileSync(root + '\\bridge-content.js', 'utf8');
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
function makeEnv({simulateClickFetch=false,rejectPost=false,streamChunks=null,mainText='synthetic'}={}) {
  const store = new Map();
  const sent = [];
  const dataset = {};
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
    if(path.includes('/backend-api/models')) return mockResponse({models:baseCatalog});
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
  class FakeEvent {constructor(){}}
  ctx={
    window:{fetch:origFetch,Request,addEventListener(){},location:loc,history:{replaceState(){}},HTMLTextAreaElement:function(){},
      HTMLInputElement:function(){}},
    document:doc,localStorage:fakeStorage,URL,URLSearchParams,Request,TextDecoder,TextEncoder,
    navigator:{userAgent:'Chrome test fixture'},
    chrome:{runtime:{onMessage:{addListener(fn){listener=fn}},sendMessage(_msg, cb){if(cb)cb({shuttle_active:true})},lastError:null}},
    InputEvent:FakeEvent,Event:FakeEvent,KeyboardEvent:FakeEvent,
    clearTimeout(){},
    setTimeout(cb,delay){if(delay===700||delay===800||delay===1200||delay===3200)return 0;queueMicrotask(cb);return 0},
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

  console.log(JSON.stringify({assertions,network:'OFFLINE_FAKE_ONLY',result:'PASS'}));
}
main().catch(e=>{console.error(e.stack);process.exitCode=1});
