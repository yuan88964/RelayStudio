// Spec v4.7 Module 1 offline contract: Web Probe (bridge-page-hook.js + bridge-content.js), background shuttle
// whitelists (background.js) and the Desktop Bridge Agent state script (RelayCdp.py). No real Chrome / network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {execFileSync} = require('node:child_process');

const root = path.join(__dirname, '..');
const hookSource = fs.readFileSync(path.join(root, 'browser-bridge', 'bridge-page-hook.js'), 'utf8');
const contentSource = fs.readFileSync(path.join(root, 'browser-bridge', 'bridge-content.js'), 'utf8');
const bgSource = fs.readFileSync(path.join(root, 'browser-bridge', 'background.js'), 'utf8');
const convId = '12345678-1234-4123-8123-123456789abc';

let assertions = 0;
function check(ok, label) {
  assert.ok(ok, label);
  console.log('PASS ' + label);
  assertions++;
}
async function flush(n = 6) {for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r));}

function streamResponse(chunks, {failAfter = false} = {}) {
  const enc = new TextEncoder();
  const mk = () => {
    let i = 0;
    return {
      ok: true,
      body: {getReader() {return {async read() {
        if (i >= chunks.length) {
          if (failAfter) throw new Error('simulated EOF');
          return {done: true};
        }
        const c = chunks[i++];
        return {done: false, value: typeof c === 'string' ? enc.encode(c) : c};
      }}}},
      clone() {return mk()},
      async json() {return {}},
    };
  };
  return mk();
}

// Tiny fake DOM element: `excluded` simulates an ancestor matching .markdown/pre/code/user bubble;
// `parts` are child blocks ({kind:'text'|'code'|'pre'|'markdown', text}) used by cloneNode/querySelectorAll.
function fakeEl({parts = [], excluded = false, role = '', hidden = false} = {}) {
  const el = {
    _parts: parts.slice(),
    offsetParent: {},
    hidden,
    get innerText() {return this._parts.map(p => p.text).join(' ')},
    get textContent() {return this.innerText},
    getAttribute(name) {return name === 'data-message-author-role' ? role : null},
    hasAttribute() {return false},
    closest(sel) {
      if (/markdown|pre|code|user-message-bubble|author-role="user"|textarea|prompt-textarea/.test(sel)) return excluded ? {} : null;
      return null;
    },
    cloneNode() {
      const c = fakeEl({parts, excluded, role});
      return c;
    },
    querySelectorAll(sel) {
      const out = [];
      for (const p of this._parts) {
        if (p.kind !== 'text' && sel.includes(p.kind === 'markdown' ? '.markdown' : p.kind)) {
          const self = this;
          out.push({remove() {self._parts = self._parts.filter(x => x !== p)}});
        }
      }
      return out;
    },
  };
  return el;
}

function makeEnv({clickFetch = false, streamChunks = null, streamFail = false, origOverride = null,
  site = null, rich = false, generating = false, acceptedText = null, sendButton = true, clock = null, holdSleep120 = false, errorNodes = [], messageNodes = []} = {}) {
  const dataset = {};
  const sent = [];
  const winListeners = new Map();
  const fillEvents = [];
  const sleeps120 = [];
  const textarea = {
    tagName: rich ? 'DIV' : 'TEXTAREA', offsetParent: {}, value: '', isContentEditable: rich,
    get innerText() {return this.value}, set innerText(v) {this.value=v},
    getAttribute() {return null}, focus() {},
    dispatchEvent(ev) {if (ev && ev.type === 'keydown' && textarea.onKeydown) textarea.onKeydown(); return true},
  };
  let clicks = 0;
  let listener = null;
  let ctx;
  const button = {disabled: false, offsetParent: {}, getAttribute() {return null}, click() {
    clicks++;
    if (acceptedText) {textarea.value = ""; messageNodes.push({textContent: acceptedText, innerText: acceptedText});}
    if (clickFetch) {
      ctx.window.fetch('/backend-api/conversation', {method: 'POST', body: JSON.stringify({model: 'gpt-6-thinking', conversation_id: convId})});
    }
  }};
  const doc = {
    execCommand(op, _ui, text) {if (op === 'insertText') textarea.value=text; else if(op === 'delete') textarea.value=''; return true},
    readyState: 'complete',
    documentElement: {dataset},
    title: 'v4.7 probe fixture',
    body: {innerText: '', appendChild() {}},
    getElementById(id) {return id === 'relaystudio-bridge-toast' ? {style: {}, textContent: ''} : null},
    querySelector(sel) {
      if (sel === (site === 'gemini' ? 'rich-textarea [contenteditable="true"]' : site === 'claude' ? 'div.ProseMirror[contenteditable="true"]' : '#prompt-textarea')) return textarea;
      if (sel === 'button[data-testid="send-button"]') return sendButton ? button : null;
      if (sel === 'main') return {innerText: '', textContent: ''};
      return null;
    },
    querySelectorAll(sel) {
      if (sel === (site === 'gemini' ? 'rich-textarea [contenteditable="true"]' : site === 'claude' ? 'div.ProseMirror[contenteditable="true"]' : '#prompt-textarea')) return [textarea];
      if (sel === 'user-query, [data-testid="user-query"]' || sel === '[data-testid="user-message"]') return messageNodes;
      if (generating && sel.includes('Stop response')) return [{disabled:false, getAttribute(){return null}, getBoundingClientRect(){return {width:20,height:20}}}];
      if (/conversation-error/.test(sel)) return errorNodes;
      if (sel === '[data-message-author-role]') return messageNodes;
      if (sendButton && (sel.includes('send') || sel.includes('Send') || sel.includes('发送'))) return [button];
      return [];
    },
    addEventListener() {},
  };
  const origFetch = origOverride || (async (input, init) => {
    const p = typeof input === 'string' ? input : input.url;
    const method = String(init?.method || 'GET').toUpperCase();
    sent.push({path: p, method});
    if (method === 'POST' && streamChunks && /\/backend-api\/(?:f\/)?conversation(?:\?|$)/.test(p)) {
      return streamResponse(streamChunks, {failAfter: streamFail});
    }
    return {ok: true, clone() {return this}, async json() {return {}}};
  });
  class FakeEvent {constructor(type, init) {this.type = type; this.detail = init && init.detail;}}
  const winObj = {
    fetch: origFetch, Request, location: site === 'gemini' ? {href: 'https://gemini.google.com/app/abc123xy', pathname: '/app/abc123xy', search: ''} : site === 'claude' ? {href:'https://claude.ai/chat/'+convId, pathname:'/chat/'+convId, search:''} : {href: 'https://chatgpt.com/c/' + convId, pathname: '/c/' + convId, search: ''},
    history: {replaceState() {}}, HTMLTextAreaElement: function () {}, HTMLInputElement: function () {}, CustomEvent: FakeEvent,
    addEventListener(type, fn) {if (!winListeners.has(type)) winListeners.set(type, new Set()); winListeners.get(type).add(fn);},
    removeEventListener(type, fn) {if (winListeners.has(type)) winListeners.get(type).delete(fn);},
    dispatchEvent(ev) {
      if (ev && ev.type === 'relaystudio:fill-composer') fillEvents.push(ev.detail);
      const set = winListeners.get(ev && ev.type);
      if (set) for (const fn of Array.from(set)) fn(ev);
      return true;
    },
  };
  const DateImpl = clock
    ? Object.assign(function (...a) {return a.length ? new Date(...a) : new Date(clock.now)}, {now: () => clock.now})
    : Date;
  ctx = {
    window: winObj, document: doc,
    localStorage: {getItem() {return null}, setItem() {}},
    URL, URLSearchParams, Request, TextDecoder, TextEncoder,
    navigator: {userAgent: 'Chrome v4.7 fixture'},
    chrome: {runtime: {onMessage: {addListener(fn) {listener = fn}}, sendMessage(_m, cb) {if (cb) cb({shuttle_active: true})}, lastError: null}},
    InputEvent: FakeEvent, Event: FakeEvent, KeyboardEvent: FakeEvent, CustomEvent: FakeEvent,
    clearTimeout() {},
    setTimeout(cb, delay) {
      if ([700, 800, 1200, 3200, 35000].includes(delay)) return 0;
      if (delay === 120) {
        sleeps120.push(cb);
        if (holdSleep120) return 0;
        if (clock) clock.now += clock.step || 0;
      }
      queueMicrotask(cb);
      return 0;
    },
    setInterval() {return 0}, console, Math, Date: DateImpl,
  };
  vm.createContext(ctx);
  vm.runInContext(hookSource, ctx, {filename: 'bridge-page-hook.js'});
  vm.runInContext(contentSource, ctx, {filename: 'bridge-content.js'});
  return {
    ctx, dataset, sent, textarea, fillEvents, sleeps120,
    get clicks() {return clicks},
    dispatch(message) {return new Promise(resolve => listener({type: 'RELAY_EXECUTE_DISPATCH', message}, {}, resolve))},
    collect() {return new Promise(resolve => listener({type: 'RELAY_COLLECT_TAB_STATE'}, {}, resolve)).then(r => r.state)},
  };
}

async function main() {
  for (const site of ['gemini', 'claude']) {
    const e = makeEnv({site, rich:site === 'claude', acceptedText: 'cross-site fixture'});
    const st = await e.collect();
    check(st.provider === site && st.conv_uuid === (site === 'gemini' ? 'abc123xy' : convId), site + ' reports provider and native room ID');
    check(!e.ctx.window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__, site + ' never installs ChatGPT API hook');
    const delivered = await e.dispatch({id:'cross-'+site, provider:site, text:'cross-site fixture'});
    check(delivered.ok && delivered.provider === site && e.clicks === 1, site + ' confirms a rendered outgoing turn after send');
    const wrong = await e.dispatch({id:'wrong',provider:site === 'gemini' ? 'claude' : 'gemini',text:'wrong site'});
    check(!wrong.ok && e.clicks === 1, site + ' refuses cross-provider dispatch');
    const busy = makeEnv({site,generating:true});
    check((await busy.collect()).is_generating, site + ' detects visible stop response');
    const busySend = await busy.dispatch({id:'busy',provider:site,text:'do not type'});
    check(!busySend.ok && busySend.retry_safe && busy.clicks === 0, site + ' never auto-types while generating');
    const pending = makeEnv({site});
    const uncertain = await pending.dispatch({id:'pending',provider:site,text:'not confirmed'});
    check(!uncertain.ok && uncertain.uncertain_delivery && pending.clicks === 1, site + ' does not ACK a mere click');
  }

  // ---- 1.1 Stream Hook: sentinel / prepare failures fail the correlated dispatch ------------------------------------
  for (const [label, url, mode] of [
    ['sentinel network error', '/backend-api/sentinel/chat-requirements', 'throw'],
    ['sentinel HTTP 403', '/backend-api/sentinel/chat-requirements', 'notok'],
    ['prefixed sentinel HTTP 524', '/backend-api/f/sentinel/chat-requirements/finalize', 'notok'],
    ['prepare HTTP 502', '/backend-api/f/conversation/prepare', 'notok'],
    ['prepare network error', '/backend-api/conversation/prepare', 'throw'],
  ]) {
    const e = makeEnv({origOverride: async () => {
      if (mode === 'throw') throw new Error('net::ERR_CONNECTION_CLOSED');
      return {ok: false, status: 403, clone() {return this}, async json() {return {}}};
    }});
    e.dataset.relayDispatchId = 'd-1';
    e.dataset.relayDispatchStatus = 'waiting';
    try {await e.ctx.window.fetch(url, {method: 'POST', body: '{}'});} catch (_) {}
    check(e.dataset.relayDispatchStatus === 'failed' && e.dataset.relayTurnIncomplete === '1',
      label + ' -> relayDispatchStatus=failed + relayTurnIncomplete=1');
  }
  {
    const e = makeEnv({origOverride: async () => ({ok: true, clone() {return this}, async json() {return {}}})});
    e.dataset.relayDispatchId = 'd-2';
    e.dataset.relayDispatchStatus = 'waiting';
    await e.ctx.window.fetch('/backend-api/sentinel/chat-requirements', {method: 'POST', body: '{}'});
    await e.ctx.window.fetch('/backend-api/f/conversation/prepare', {method: 'POST', body: '{}'});
    check(e.dataset.relayDispatchStatus === 'waiting', 'successful sentinel/prepare leave the dispatch waiting');
    const e2 = makeEnv({origOverride: async () => {throw new Error('offline')}});
    try {await e2.ctx.window.fetch('/backend-api/sentinel/chat-requirements', {method: 'POST', body: '{}'});} catch (_) {}
    check(!e2.dataset.relayDispatchStatus && !e2.dataset.relayTurnIncomplete, 'uncorrelated sentinel failure touches nothing');
  }

  // ---- 1.1 SSE positive closure ---------------------------------------------------------------------------------------
  async function runStream(chunks, opts = {}) {
    const e = makeEnv({streamChunks: chunks, streamFail: Boolean(opts.fail)});
    await e.ctx.window.fetch('/backend-api/conversation', {method: 'POST', body: JSON.stringify({model: 'gpt-6-thinking'})});
    await flush(10);
    return e;
  }
  {
    const e = await runStream(['data: {"message":{"content":"partial"}}\n\n']);
    check(e.dataset.relayStreamIncomplete === '1' && e.dataset.relayTurnIncomplete === '1' && e.dataset.relayTurnSeq === '0',
      'real SSE frame without [DONE] -> relayStreamIncomplete=1, turn not counted');
    const st = await e.collect();
    check(st.stream_incomplete === true && st.turn_incomplete === true && st.has_error === true,
      'tab state reports stream_incomplete / turn_incomplete / has_error');
  }
  {
    const e = await runStream(['data: {"message":{"content":"ok"}}\n\n', 'data: [DONE]\n\n']);
    check(!e.dataset.relayStreamIncomplete && !e.dataset.relayTurnIncomplete && e.dataset.relayTurnSeq === '1',
      'real SSE frame with [DONE] -> complete, relayTurnSeq=1');
  }
  {
    const e = await runStream(['event: delta\ndata: {"type":"message_stream_complete"}\n\n']);
    check(!e.dataset.relayStreamIncomplete && e.dataset.relayTurnSeq === '1', '"message_stream_complete" counts as closure');
  }
  {
    const e = await runStream([new Uint8Array([100, 97, 116, 97])]);
    check(!e.dataset.relayStreamIncomplete && e.dataset.relayTurnSeq === '1',
      '4-byte synthetic stream ("data") is not a real SSE frame -> unaffected, relayTurnSeq=1');
  }
  {
    const e = await runStream(['event: error\ndata: {"error":{"message":"Error in message stream"}}\n\n', 'data: [DONE]\n\n']);
    check(e.dataset.relayStreamIncomplete === '1', 'SSE error event -> incomplete even with [DONE]');
  }
  {
    const e = await runStream(['data: {"a":1}\n\n'], {fail: true});
    check(e.dataset.relayStreamIncomplete === '1' && e.dataset.relayTurnSeq === '0', 'reader EOF error -> incomplete');
  }
  {
    // markUserTurnAccepted clears stale flags before the new stream finishes.
    let release;
    const gate = new Promise(r => {release = r});
    const enc = new TextEncoder();
    const e = makeEnv({origOverride: async () => {
      const mk = () => {let i = 0; return {ok: true, clone() {return mk()}, body: {getReader() {return {async read() {
        i++;
        if (i === 1) {await gate; return {done: false, value: enc.encode('data: [DONE]\n\n')};}
        return {done: true};
      }}}}};};
      return mk();
    }});
    e.dataset.relayStreamIncomplete = '1';
    e.dataset.relayTurnIncomplete = '1';
    await e.ctx.window.fetch('/backend-api/conversation', {method: 'POST', body: '{}'});
    check(!e.dataset.relayStreamIncomplete && !e.dataset.relayTurnIncomplete && e.dataset.relaySseActive === '1',
      'accepted POST clears stale incomplete flags while the stream is open');
    release();
    await flush(10);
    check(e.dataset.relayTurnSeq === '1' && !e.dataset.relayStreamIncomplete, 'stream closes cleanly afterwards');
  }

  // ---- 1.1 fill-composer clear for ProseMirror -------------------------------------------------------------------------
  {
    const e = makeEnv();
    const calls = [];
    const pmEditor = {
      innerText: 'machine draft',
      focus() {},
      pmViewDesc: {view: {
        state: {doc: {content: {size: 13}}, get tr() {return {delete(a, b) {calls.push(['delete', a, b]); return this}, insertText() {calls.push(['insert']); return this}}}},
        dispatch(tr) {calls.push(['dispatch']); pmEditor.innerText = '';},
      }},
    };
    e.ctx.document.querySelector = sel => (sel === '#prompt-textarea' ? pmEditor : null);
    e.ctx.window.dispatchEvent(new e.ctx.CustomEvent('relaystudio:fill-composer', {detail: {clear: true, text: ''}}));
    check(calls.some(c => c[0] === 'delete' && c[1] === 0 && c[2] === 13) && calls.some(c => c[0] === 'dispatch') && pmEditor.innerText === '',
      'fill-composer {clear:true} deletes the whole ProseMirror document');
  }

  // ---- 1.2 extractUiErrorText excludes markdown / code / user bubbles ------------------------------------------------
  {
    const e = makeEnv({errorNodes: [
      fakeEl({parts: [{kind: 'text', text: 'network error 出现在正文示例里'}], excluded: true}),
      fakeEl({parts: [{kind: 'text', text: 'Something went wrong (user bubble)'}], excluded: true}),
    ]});
    const st = await e.collect();
    check(st.ui_error_text === '' && st.has_error === false, 'error-looking text inside .markdown/pre/code/user bubble is ignored');
  }
  {
    const e = makeEnv({errorNodes: [
      fakeEl({parts: [{kind: 'code', text: 'throw new Error("Error in message stream")'}]}),
      fakeEl({parts: [{kind: 'text', text: '传输超时，请重试'}, {kind: 'code', text: 'stack trace'}, {kind: 'markdown', text: 'md body'}]}),
    ]});
    const st = await e.collect();
    check(st.ui_error_text === '传输超时，请重试' && st.has_error === true,
      'outer error text is extracted after stripping inner .markdown/pre/code');
  }
  {
    const e = makeEnv({errorNodes: [fakeEl({parts: [{kind: 'text', text: 'x'.repeat(500)}]})]});
    const st = await e.collect();
    check(st.ui_error_text.length === 240, 'ui_error_text is truncated to 240 chars');
  }

  // ---- 1.2 checkTurnIncomplete -----------------------------------------------------------------------------------------
  {
    const e = makeEnv({messageNodes: [fakeEl({role: 'assistant'}), fakeEl({role: 'user'})]});
    const st = await e.collect();
    check(st.turn_incomplete === true && st.has_error === true, 'last visible message is a lone user bubble -> turn_incomplete');
    e.dataset.relaySseActive = '1';
    const st2 = await e.collect();
    check(st2.turn_incomplete === false, 'no turn_incomplete while SSE is active');
  }
  {
    const e = makeEnv({messageNodes: [fakeEl({role: 'user'}), fakeEl({role: 'assistant'})]});
    const st = await e.collect();
    check(st.turn_incomplete === false && st.has_error === false && st.stream_incomplete === false, 'answered turn -> not incomplete');
    const e0 = makeEnv();
    const s0 = await e0.collect();
    check(s0.turn_incomplete === false && s0.has_composer === true && s0.ui_error_text === '', 'empty DOM stub -> not incomplete, composer present');
  }

  // ---- 1.2 waitForDispatchAcceptance / waitForSteerAcceptance physical clock deadlines -----------------------------
  {
    const clock = {now: 1_000_000, step: 2000};
    const e = makeEnv({clock});
    const res = await e.dispatch({id: 'clk-1', text: '物理时钟测试'});
    check(res.ok === false && res.uncertain_delivery === true && e.sleeps120.length < 20,
      'waitForDispatchAcceptance exits by Date.now() deadline (25s) under throttled timers (' + e.sleeps120.length + ' sleeps)');
  }
  {
    const clock = {now: 1_000_000, step: 2000};
    const e = makeEnv({clock});
    e.dataset.relaySseActive = '1';
    const res = await e.dispatch({id: 'clk-2', text: '实时引导物理时钟', mode: 'custom_message', manual_send: true});
    check(res.reason === 'steer_unavailable' && e.sleeps120.length < 8,
      'waitForSteerAcceptance exits by Date.now() deadline (6.5s) (' + e.sleeps120.length + ' sleeps)');
  }

  // ---- 1.2 isBusySending auto-reset after 30 s -----------------------------------------------------------------------
  {
    const clock = {now: 5_000_000, step: 0};
    const e = makeEnv({clock, holdSleep120: true});
    e.dispatch({id: 'busy-1', text: '卡住的投递'});
    await flush(40);
    const s1 = await e.collect();
    check(s1.is_dispatching === true, 'is_dispatching true while a dispatch is waiting');
    clock.now += 31000;
    const s2 = await e.collect();
    check(s2.is_dispatching === false, 'isBusySending older than 30s is force-reset by buildLocalTabState');
  }

  // ---- 1.2 i===5 never refills a non-empty composer; failure cleanup only removes our own residue -----------------
  {
    const e = makeEnv({sendButton: false});
    const res = await e.dispatch({id: 'nb-1', text: '机器注入的催工单'});
    check(e.fillEvents.filter(d => d && d.text).length === 1, 'i===5 does not re-inject text into a non-empty composer');
    check(res.ok === false && e.textarea.value === '', 'unconfirmed send clears the residual machine-injected draft');
  }
  {
    const e = makeEnv({sendButton: false});
    e.textarea.onKeydown = () => {e.textarea.value = '用户自己改写的草稿';};
    const res = await e.dispatch({id: 'nb-2', text: '机器注入的催工单'});
    check(res.ok === false && e.textarea.value === '用户自己改写的草稿', 'a user-modified draft is never cleared');
  }
  {
    const e = makeEnv({clickFetch: true});
    const res = await e.dispatch({id: 'ok-1', text: '正常投递'});
    check(res.ok === true, 'normal accepted dispatch still succeeds');
  }

  // ---- 1.3 background.js double whitelist -----------------------------------------------------------------------------
  {
    const full = {
      conv_uuid: convId, is_archived: true, can_steer_live: true, has_composer: false, turn_incomplete: true,
      stream_incomplete: true, has_load_error: true, ui_error_text: '未收到 ChatGPT 的回复，请检查网络连接。',
    };
    let probeState = full;
    const bg = {
      navigator: {userAgent: 'Mozilla/5.0 Chrome/125.0'}, URL, console, Math, Date,
      setInterval() {return 0}, setTimeout() {return 0}, clearTimeout() {},
      fetch: async () => ({ok: true, async json() {return {}}}),
      chrome: {
        runtime: {onMessage: {addListener() {}}, lastError: null},
        scripting: {async executeScript() {}},
        tabs: {
          onRemoved: {addListener() {}},
          async query() {return [{id: 9, windowId: 1, url: 'https://chatgpt.com/c/' + convId, title: 'T'}]},
          sendMessage(_id, msg, cb) {if (msg.type === 'RELAY_COLLECT_TAB_STATE') cb({ok: true, state: probeState}); else if (cb) cb({ok: true});},
        },
      },
    };
    vm.createContext(bg);
    vm.runInContext(bgSource, bg, {filename: 'background.js'});
    const entry = bg.upsertTabStateCache('7', full, {});
    const keys = ['is_archived', 'can_steer_live', 'has_composer', 'turn_incomplete', 'stream_incomplete', 'has_load_error', 'ui_error_text'];
    check(keys.every(k => entry[k] === full[k]), 'upsertTabStateCache forwards all 7 v4.7 fields');
    const tabs = await bg.collectOpenChatGptTabs();
    check(tabs.length === 1 && keys.every(k => tabs[0][k] === full[k]), 'collectOpenChatGptTabs forwards all 7 v4.7 fields');
    for (const [provider, url, room] of [['gemini','https://gemini.google.com/app/native123','native123'], ['claude','https://claude.ai/chat/'+convId,convId]]) {
      bg.chrome.tabs.query = async opts => {
        check(opts.url.includes('https://gemini.google.com/*') && opts.url.includes('https://claude.ai/*'), 'background enumerates all platform scopes');
        return [{id:provider === 'gemini' ? 21 : 22,url,title:provider}];
      };
      probeState = {provider,conv_uuid:room,url};
      const nativeTabs = await bg.collectOpenChatGptTabs();
      check(nativeTabs[0].provider === provider && nativeTabs[0].conv_uuid === room, provider+' survives background tab aggregation');
    }
    const sparse = bg.upsertTabStateCache('8', {conv_uuid: convId}, {});
    check(sparse.has_composer === true && sparse.turn_incomplete === false && sparse.ui_error_text === '' && sparse.is_archived === false,
      'missing fields default safely (has_composer defaults true)');
  }

  // ---- 1.4 RelayCdp.script_state -------------------------------------------------------------------------------------
  {
    const scriptState = JSON.parse(execFileSync('python', ['-c',
      'import json,sys; sys.path.insert(0, sys.argv[1]); import RelayCdp; print(json.dumps(RelayCdp.script_state()))', root],
    {encoding: 'utf8'}).trim());
    function fiberChain(propsList) {
      let parent = null;
      for (let i = propsList.length - 1; i >= 0; i--) parent = {memoizedProps: propsList[i], return: parent};
      return parent;
    }
    function el(fiber, extra = {}) {
      return Object.assign({
        '__reactFiber$x': fiber, nodeType: 1, parentElement: null, style: {display: 'block'},
        hasAttribute() {return false}, getAttribute() {return null}, closest() {return null},
        getBoundingClientRect() {return {width: 10, height: 10}}, querySelector() {return null}, querySelectorAll() {return []},
      }, extra);
    }
    function runState({form = null, main = null, alertText = ''} = {}) {
      const doc = {
        documentElement: {dataset: {}}, title: 'Desktop', body: {},
        querySelectorAll(sel) {
          if (sel === 'form[data-chatgpt-composer]') return form ? [form] : [];
          if (main && /data-chatgpt-conversation-selection-target|main/.test(sel) && !/author-role|\[data-sidebar/.test(sel) && !/form/.test(sel)) return [main];
          return [];
        },
        querySelector(sel) {
          if (alertText && /role=\\?"alert/.test(sel)) return {innerText: alertText};
          return null;
        },
      };
      const c = vm.createContext({document: doc, location: {protocol: 'app:', pathname: '/', href: 'app://-/index.html'},
        window: {}, getComputedStyle: () => ({display: 'block'}), console});
      return vm.runInContext(scriptState, c);
    }
    const loadErr = runState({main: el(fiberChain([{}, {hasLoadError: true, errorMessage: '无法加载此 ChatGPT 对话', showComposer: false}]))});
    check(loadErr.has_composer === false && loadErr.has_load_error === true && loadErr.ui_error_text === '无法加载此 ChatGPT 对话',
      'composer unmounted: fallback Fiber crawl from main exposes has_load_error + ui_error_text');
    const pending = runState({form: el(fiberChain([{entries: [
      {role: 'user', status: 'complete'}, {role: 'assistant', status: 'complete'}, {role: 'assistant', status: 'in_progress'}]}]))});
    check(pending.turn_incomplete === true && pending.has_load_error === false && pending.has_composer === true,
      'idle last turn with status != complete -> turn_incomplete');
    const userOnly = runState({form: el(fiberChain([{entries: [{role: 'assistant'}, {type: 'user', message: {author: {role: 'user'}}}]}]))});
    check(userOnly.turn_incomplete === true, 'idle last turn with only a user message -> turn_incomplete');
    const done = runState({form: el(fiberChain([{entries: [{role: 'user'}, {role: 'assistant', status: 'complete'}]}]))});
    check(done.turn_incomplete === false && done.ui_error_text === '', 'completed turn -> not incomplete');
    const streaming = runState({form: el(fiberChain([{isStreaming: true, entries: [{role: 'user'}]}]))});
    check(streaming.turn_incomplete === false, 'streaming turn is never incomplete');
    const domErr = runState({form: el(fiberChain([{entries: []}])), alertText: 'Network error'});
    check(domErr.ui_error_text === 'Network error' && domErr.has_error === true, 'DOM error banner text falls back into ui_error_text');
  }

  console.log(JSON.stringify({assertions, network: 'OFFLINE_FAKE_ONLY', result: 'PASS'}));
}
main().catch(e => {console.error(e.stack); process.exitCode = 1;});
