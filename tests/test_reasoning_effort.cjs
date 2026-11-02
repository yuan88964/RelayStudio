// Isolated thinking-effort contract: WPF labels -> content script -> page hook -> POST JSON.
// No real browser, network calls, or ChatGPT messages.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..', 'browser-bridge');
const hook = fs.readFileSync(path.join(root, 'bridge-page-hook.js'), 'utf8');
const content = fs.readFileSync(path.join(root, 'bridge-content.js'), 'utf8');
const convId = '12345678-1234-4123-8123-123456789abc';
const catalog = [
  {slug:'gpt-6',title:'GPT-6',description:'Latest flagship model'},
  {slug:'gpt-6-instant',title:'GPT-6 Instant',description:'Fastest model'},
  {slug:'gpt-6-thinking',title:'GPT-6 Thinking',product_features:{reasoning_config:{supported_efforts:['light','standard','extended','max']}}},
  {slug:'gpt-6-pro',title:'GPT-6 Pro',reasoning_config:{supported_efforts:['standard','max']}},
  {slug:'gpt-6.1-thinking-wm',title:'GPT-6.1 Thinking WM',is_work_mode_model:true,model_lane:'thinking_plus_plus'},
  {slug:'chatgpt_alpha_model_external_access_reserved_gate_13',title:'Reserved Gate 13',is_hidden:true},
];
let passed = 0;
function check(expr, label) {
  assert.ok(expr, label);
  passed++;
  console.log('PASS ' + label);
}
function fakeResponse(data, ok = true) {
  return {ok, clone(){return fakeResponse(data, ok)}, async json(){return data}};
}
function createFixture({legacy = false, request = false, noPost = false, statusOk = true, hangPost = false} = {}) {
  const dataset = {};
  const posts = [];
  const pending = [];
  const storage = new Map();
  let listener = null;
  let ctx;
  const editor = {
    tagName:'TEXTAREA', value:'', isContentEditable:false, offsetParent:{},
    getAttribute(){return null}, focus(){}, dispatchEvent(){return true}
  };
  const sendButton = {
    disabled:false, offsetParent:{}, getAttribute(){return null},
    click(){
      if (noPost) return;
      const payload = {model:'gpt-6-thinking', conversation_id:convId,
        thinking_effort:legacy?'medium':'standard',
        messages:[{author:{role:'user'},content:{parts:[editor.value]}}]};
      if (legacy) payload.reasoning_effort = 'medium';
      const body = JSON.stringify(payload);
      if (request) {
        const r = new Request('https://chatgpt.com/backend-api/conversation', {method:'POST',body});
        pending.push(ctx.window.fetch(r));
      } else {
        pending.push(ctx.window.fetch('/backend-api/conversation', {method:'POST',body}));
      }
    }
  };
  const toast = {style:{},textContent:'',_hideTimer:null};
  const doc = {
    readyState:'complete',
    documentElement:{dataset},
    title:'Offline fixture',
    body:{innerText:'synthetic',appendChild(){}},
    getElementById(id){return id==='relaystudio-bridge-toast'?toast:null},
    querySelector(selector){
      if(selector==='#prompt-textarea')return editor;
      if(selector==='button[data-testid="send-button"]')return sendButton;
      if(selector==='main')return {innerText:'synthetic'};
      return null;
    },
    querySelectorAll(selector){return /send|Send|发送/.test(selector)?[sendButton]:[]},
    addEventListener(){}
  };
  const loc={href:'https://chatgpt.com/c/'+convId,pathname:'/c/'+convId,search:''};
  const originalFetch = async(input, init) => {
    const url = typeof input==='string'?input:input.url;
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    if (/\/backend-api\/models/.test(url))return fakeResponse({models:catalog});
    if (method==='POST') {
      const raw = init?.body ?? (input instanceof Request?await input.clone().text():input?.body);
      posts.push({url, body:JSON.parse(raw)});
      if (hangPost) return new Promise(() => {});
      return fakeResponse({ok:statusOk},statusOk);
    }
    return fakeResponse({});
  };
  const Event = class { constructor(){} };
  ctx = {
    window:{fetch:originalFetch,Request,location:loc,history:{replaceState(){}},
      addEventListener(){},HTMLTextAreaElement:function(){},HTMLInputElement:function(){}},
    document:doc,
    localStorage:{getItem(k){return storage.get(k)||null},setItem(k,v){storage.set(k,v)}},
    URL,URLSearchParams,Request,Math,Date,
    navigator:{userAgent:'Chrome offline fixture'},
    chrome:{runtime:{onMessage:{addListener(fn){listener=fn}},sendMessage(_message,cb){if(cb)cb({shuttle_active:true})},lastError:null}},
    InputEvent:Event,Event,KeyboardEvent:Event,
    clearTimeout(){},
    setTimeout(cb,delay){if([700,800,1200,3200].includes(delay))return 0;queueMicrotask(cb);return 0},
    setInterval(){return 0},console
  };
  vm.createContext(ctx);
  vm.runInContext(hook,ctx,{filename:'bridge-page-hook.js'});
  vm.runInContext(content,ctx,{filename:'bridge-content.js'});
  return {ctx,dataset,posts,pending,getListener:()=>listener};
}
async function sendOne(test) {
  const fixture=createFixture(test);
  await fixture.ctx.window.fetch('/backend-api/models',{method:'GET'});
  await new Promise(resolve=>setImmediate(resolve));
  const models=JSON.parse(fixture.dataset.relayModelsCatalog||'[]');
  check(models.find(x=>x.slug==='gpt-6-pro')?.efforts.join(',')==='standard,max',
    test.label+': account catalog includes allowed efforts');
  check(!models.some(x=>x.slug.endsWith('-wm') || x.slug.includes('reserved_gate_')),
    test.label+': non-Chat WM and reserved_gate models are filtered out');
  const result=await new Promise((resolve,reject)=>{
    const accepted=fixture.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{
      id:'effort-'+passed, text:'仅本地测试', target_model:test.model || 'gpt-6-thinking',
      reasoning_effort:test.effort
    }},{},resolve);
    if(!accepted)reject(Error('bridge declined synthetic command'));
  });
  await Promise.all(fixture.pending);
  check(result.ok===true && fixture.posts.length===1,
    test.label+': one POST was acknowledged');
  const sent=fixture.posts[0].body;
  const expMod = test.expectedModel || test.model;
  check(sent.thinking_effort===test.expected && (!expMod || sent.model===expMod),
    test.label+': outgoing JSON contains expected model and thinking effort');
  if (test.legacy) {
    check(sent.reasoning_effort===test.expectedLegacy,
      test.label+': legacy reasoning_effort field is normalized too');
  }
  check(!fixture.dataset.relayOverrideEffort && !fixture.dataset.relayOverrideModel,
    test.label+': one-shot override is cleared');
}
(async()=>{
  for (const item of [
    {label:'raw light',effort:'light',expected:'light'},
    {label:'raw extended',effort:'extended',expected:'extended'},
    {label:'raw max on gpt-6 auto-upgrades to gpt-6-thinking',effort:'max',model:'gpt-6',expected:'max',expectedModel:'gpt-6-thinking'},
    {label:'raw none on gpt-6-thinking auto-switches to gpt-6-instant',effort:'none',model:'gpt-6-thinking',expected:undefined,expectedModel:'gpt-6-instant'},
    {label:'light / 轻度',effort:'轻度',expected:'light'},
    {label:'standard / 标准',effort:'标准',expected:'standard'},
    {label:'extended / 深度',effort:'深度',expected:'extended'},
    {label:'max / 最高',effort:'最高',model:'gpt-6-pro',expected:'max',expectedModel:'gpt-6-pro'},
    {label:'max / 极高 on gpt-6 auto-upgrades to gpt-6-thinking',effort:'极高',model:'gpt-6',expected:'max',expectedModel:'gpt-6-thinking'},
    {label:'instant / 即时 on gpt-6-thinking auto-switches to gpt-6-instant',effort:'即时',model:'gpt-6-thinking',expected:undefined,expectedModel:'gpt-6-instant'},
    {label:'inherit / 跟随网页',effort:'inherit',expected:'standard'},
    {label:'fetch(Request) deep',effort:'深度',request:true,expected:'extended'},
    {label:'legacy low-medium-high',effort:'深度',legacy:true,expected:'high',expectedLegacy:'high'}
  ])await sendOne(item);
  const failed=createFixture({noPost:true});
  const noPostReply=await new Promise(resolve=>{
    failed.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{
      id:'effort-no-post', text:'仅本地测试', target_model:'gpt-6-pro', reasoning_effort:'最高'
    }},{},resolve);
  });
  check(noPostReply.ok===false && failed.posts.length===0,
    'No POST must never count as successful thinking-effort send');
  const hung=createFixture({hangPost:true});
  const hungReply=await new Promise(resolve=>{
    hung.getListener()({type:'RELAY_EXECUTE_DISPATCH',message:{
      id:'effort-hanging-post', text:'仅本地测试', target_model:'gpt-6-pro', reasoning_effort:'最高'
    }},{},resolve);
  });
  check(hungReply.ok===false && hungReply.delivered===false &&
    hungReply.uncertain_delivery===true && hungReply.retry_safe===false && hung.posts.length===1,
    'Pending POST must remain unconfirmed and not invite an automatic retry');

  // Real OpenAI thinking_efforts schema (short_label / full_label / default_thinking_effort / configurable_thinking_effort)
  // + live composer DOM effort pill priority over stale relayActiveEffort.
  const richCatalog = [
    {
      slug: 'gpt-6-thinking',
      title: 'GPT-6',
      default_thinking_effort: 'min',
      configurable_thinking_effort: true,
      thinking_efforts: [
        { thinking_effort: 'min', short_label: '轻度', full_label: '快速思考' },
        { thinking_effort: 'standard', short_label: '标准', full_label: '思考中' },
        { thinking_effort: 'extended', short_label: '深度', full_label: '进阶思考' },
        { thinking_effort: 'max', short_label: '极高', full_label: '深度思考' },
      ],
    },
    {
      slug: 'gpt-6-5tier',
      title: 'GPT-6 FiveTier',
      default_thinking_effort: 'standard',
      configurable_thinking_effort: true,
      thinking_efforts: [
        { thinking_effort: 'min', short_label: '轻度', full_label: '快速思考' },
        { thinking_effort: 'standard', short_label: '标准', full_label: '思考中' },
        { thinking_effort: 'extended', short_label: '深度', full_label: '进阶思考' },
        { thinking_effort: 'xhigh', short_label: '极高', full_label: '极高 Thinking' },
        { thinking_effort: 'max', short_label: '深入', full_label: '深度思考' },
      ],
    },
    {
      slug: 'research',
      title: 'Deep Research',
      configurable_thinking_effort: false,
      thinking_efforts: [],
    },
  ];
  let liveEffortBtnText = '极高 ⌄';
  const richFixture = createFixture();
  const prevQueryAll = richFixture.ctx.document.querySelectorAll;
  richFixture.ctx.document.querySelectorAll = (sel) => {
    if (sel.includes('reasoning') || sel.includes('effort') || sel.includes('haspopup="menu"')) {
      return liveEffortBtnText ? [{ innerText: liveEffortBtnText, getAttribute() { return null; } }] : [];
    }
    return prevQueryAll(sel);
  };
  const origRichFetch = richFixture.ctx.window.fetch;
  // Inject richCatalog via GET /backend-api/models through the installed hook
  const savedCatalogCopy = catalog.splice(0, catalog.length, ...richCatalog);
  try {
    await origRichFetch('/backend-api/models', { method: 'GET' });
    await new Promise(resolve => setImmediate(resolve));
    const parsedRich = JSON.parse(richFixture.dataset.relayModelsCatalog || '[]');
    const m4 = parsedRich.find(x => x.slug === 'gpt-6-thinking');
    const m5 = parsedRich.find(x => x.slug === 'gpt-6-5tier');
    const mFixed = parsedRich.find(x => x.slug === 'research');
    check(m4 && m4.default_effort === 'min' && m4.configurable_effort === true &&
      m4.effort_items.map(i => `${i.id}:${i.label}`).join(',') === 'min:轻度,standard:标准,extended:深度,max:极高',
      'Catalog preserves real OpenAI short_label (极高 for max) and default_thinking_effort');
    check(m5 && m5.effort_items.map(i => `${i.id}:${i.label}`).join(',') === 'min:轻度,standard:标准,extended:深度,xhigh:极高,max:深入',
      'Catalog preserves distinct xhigh=极高 and max=深入 on 5-tier models');
    check(mFixed && mFixed.configurable_effort === false && mFixed.efforts.length === 0,
      'Catalog preserves configurable_thinking_effort=false without fabricating efforts');

    // Scheme A: Stale relayActiveEffort='min' yields to live webpage composer pill '极高 ⌄' -> raw English 'max'
    richFixture.dataset.relayActiveModel = 'gpt-6-thinking';
    richFixture.dataset.relayActiveEffort = 'min';
    richFixture.dataset.relayActiveConvUuid = convId;
    let tabStateResp = null;
    richFixture.getListener()({ type: 'RELAY_COLLECT_TAB_STATE' }, {}, (r) => { tabStateResp = r; });
    check(tabStateResp && tabStateResp.ok && tabStateResp.state.current_effort === 'max',
      'Live composer effort button (极高 ⌄) resolves to raw official English ID max');

    // Single-character frontend pill '高 ⌄' also resolves to raw official English ID 'extended'
    liveEffortBtnText = '高 ⌄';
    richFixture.getListener()({ type: 'RELAY_COLLECT_TAB_STATE' }, {}, (r) => { tabStateResp = r; });
    check(tabStateResp && tabStateResp.ok && tabStateResp.state.current_effort === 'extended',
      'Single-character composer effort button (高 ⌄) resolves to raw official English ID extended');

    // When DOM effort button is hidden, raw relayActiveEffort='min' remains pure raw English ID 'min'
    liveEffortBtnText = '';
    richFixture.getListener()({ type: 'RELAY_COLLECT_TAB_STATE' }, {}, (r) => { tabStateResp = r; });
    check(tabStateResp && tabStateResp.ok && tabStateResp.state.current_effort === 'min',
      'Fallback relayActiveEffort raw ID stays pure raw English ID min without translating to Chinese');

    // Dispatching '极高' vs '深入' on 5-tier model sends exact 'xhigh' vs 'max' IDs
    await new Promise((resolve) => {
      richFixture.getListener()({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: { id: 'effort-5tier-xhigh', text: '5档极高', target_model: 'gpt-6-5tier', reasoning_effort: '极高' },
      }, {}, resolve);
    });
    await Promise.all(richFixture.pending);
    check(richFixture.posts.at(-1).body.thinking_effort === 'xhigh',
      '5-tier model maps label 极高 to exact effort ID xhigh');

    await new Promise((resolve) => {
      richFixture.getListener()({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: { id: 'effort-5tier-max', text: '5档深入', target_model: 'gpt-6-5tier', reasoning_effort: '深入' },
      }, {}, resolve);
    });
    await Promise.all(richFixture.pending);
    check(richFixture.posts.at(-1).body.thinking_effort === 'max',
      '5-tier model maps label 深入 to exact effort ID max');
  } finally {
    catalog.splice(0, catalog.length, ...savedCatalogCopy);
  }

  console.log(JSON.stringify({result:'PASS',assertions:passed,network:'OFFLINE_FAKE_ONLY'}));
})().catch(error=>{console.error(error.stack);process.exitCode=1});
