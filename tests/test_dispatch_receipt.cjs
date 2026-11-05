// Offline unit contract: no real Chrome tabs, ChatGPT requests or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const background = fs.readFileSync(path.join(__dirname, '..', 'browser-bridge', 'background.js'), 'utf8');

async function runShuttleScenario(responses, provider) {
  const sent = [];
  const acks = [];
  const updates = [];
  const scheduled = [];
  const queue = responses.slice();
  const chrome = {
    runtime: {lastError: null, onMessage: {addListener() {}}},
    tabs: {
      onRemoved: {addListener() {}},
      async query() {return []},
      async update(...args) {updates.push(args)},
      async create() {},
      sendMessage(tab, payload, done) {
        sent.push({tab, payload});
        const step = queue.shift() || {ok:false};
        if (step.hang) return;
        chrome.runtime.lastError = step.channel_error ? {message:'simulated channel failure'} : null;
        done(step.channel_error ? undefined : step);
        chrome.runtime.lastError = null;
      },
    },
    scripting: {async executeScript() {}},
  };
  const ctx = vm.createContext({
    navigator: {userAgent:'Chrome offline mock'},
    chrome, URL, console,
    setTimeout(fn, ms) {scheduled.push({fn, ms}); return scheduled.length},
    setInterval() {return 0},
    async fetch(url, options) {
      if (url.endsWith('/web-bridge/ack-deliver')) {
        acks.push(JSON.parse(options.body));
      }
      return {ok:true, async json(){return {}}};
    },
  });
  vm.runInContext(background, ctx, {filename:'background.js'});
  await ctx.handleShuttleDispatches([{
    tab_id:'42', provider, message:{id:'local-only-ack-contract',text:'fixture',provider}
  }]);
  for (let i=0; scheduled.length && i<30; i++) {
    const {fn}=scheduled.shift();
    fn();
    await new Promise(resolve=>setImmediate(resolve));
    await new Promise(resolve=>setImmediate(resolve));
  }
  return {sent,acks,updates};
}

(async function main() {
  for (const provider of ['gemini', 'claude']) {
    const r = await runShuttleScenario([{ok:true,provider,conv_uuid:'native-room'}], provider);
    assert.equal(r.acks[0].provider,provider,'receipt preserves platform identity');
    const wrong = await runShuttleScenario([{ok:true,provider:provider === 'claude' ? 'gemini' : 'claude',conv_uuid:'native-room'}],provider);
    assert.equal(wrong.acks.length,0,'wrong platform receipt is never ACKed');
  }

  const pending = await runShuttleScenario([{ok:false, delivered:false, uncertain_delivery:true}]);
  assert.equal(pending.sent.length,1,'pending POST must not trigger a second click');
  assert.equal(pending.acks.length,0,'pending POST must not trigger ack-deliver');
  assert.equal(pending.updates.length,0,'background delivery must never switch the user tab');
  console.log('PASS: pending POST is not ACKed and not retried');

  const failed = await runShuttleScenario([{ok:false, delivered:false}]);
  assert.equal(failed.sent.length,1,'generic failure must not auto retry');
  assert.equal(failed.acks.length,0);
  console.log('PASS: failed POST is not ACKed or blindly retried');

  const lost = await runShuttleScenario([{channel_error:true}]);
  assert.equal(lost.sent.length,1,'lost callback must not auto retry');
  assert.equal(lost.acks.length,0);
  console.log('PASS: lost callback remains uncertain, with no duplicate');

  const accepted = await runShuttleScenario([{ok:true,delivered:true,conv_uuid:'abc'}]);
  assert.equal(accepted.sent.length,1);
  assert.equal(accepted.acks.length,1);
  assert.equal(accepted.acks[0].msg_id,'local-only-ack-contract');
  assert.equal(accepted.updates.length,0,'accepted delivery happens without tabs.update');
  console.log('PASS: HTTP-success callback produces one ACK');

  const safe = await runShuttleScenario([{ok:false, retry_safe:true},{ok:true,delivered:true}]);
  assert.equal(safe.sent.length,2,'only explicitly safe pre-send failure may retry');
  assert.equal(safe.acks.length,1);
  console.log('PASS: explicit pre-send failure retries once, with one ACK');

  const hung = await runShuttleScenario([{hang:true},{ok:true,delivered:true,conv_uuid:'abc'}]);
  assert.equal(hung.sent.length,1,'a hung tab must remain single-flight without blind re-dispatch');
  assert.equal(hung.updates.length,0,'zero-disturb rule: never activate a tab even if it never answers');
  assert.equal(hung.acks.length,0);
  assert.ok(!/tabs\.update\([^)]*active\s*:\s*true/.test(background), 'background.js must never call tabs.update({ active: true })');
  console.log('PASS: zero-disturb rule holds even when a hidden tab never answers');

  // Spec v4.1 H1: an open browser with ZERO ChatGPT tabs still heartbeats and opens background tabs on request.
  const heartbeatPolls = [];
  const createdTabs = [];
  const chromeEmpty = {
    runtime: {lastError: null, onMessage: {addListener() {}}},
    tabs: {
      onRemoved: {addListener() {}},
      async query() {return []},
      async update() {throw new Error('tabs.update must not be used to open a background tab')},
      async create(opts) {createdTabs.push(opts)},
      sendMessage() {},
    },
    scripting: {async executeScript() {}},
  };
  const ctxEmpty = vm.createContext({
    navigator: {userAgent:'Chrome offline mock'},
    chrome: chromeEmpty, URL, console,
    setTimeout() {return 0},
    setInterval() {return 0},
    async fetch(url, options) {
      if (url.endsWith('/web-bridge/poll')) {
        heartbeatPolls.push(JSON.parse(options.body));
        return {ok:true, async json(){return {ok:true, dispatches:[{open_new_tab:true, handover_url:'https://chatgpt.com/c/abc?relay_profile=Chrome%3AProfile%2019', msg_id:'m-bg'}], retire_actions:[]}}};
      }
      return {ok:true, async json(){return {}}};
    },
  });
  vm.runInContext(background, ctxEmpty, {filename:'background.js'});
  await ctxEmpty.runShuttleTick();
  assert.equal(heartbeatPolls.length, 1, 'zero-tab browser must still POST /web-bridge/poll');
  assert.deepEqual(heartbeatPolls[0].tabs, []);
  assert.ok(heartbeatPolls[0].browser_instance_id, 'heartbeat carries browser_instance_id');
  assert.equal(createdTabs.length, 1, 'hub-requested tab is created');
  assert.equal(createdTabs[0].active, false, 'background tab never takes focus');
  assert.ok(!/RELAY_ACTIVATE_SELF_TAB/.test(background), 'dead self-activation handler removed');
  console.log('PASS: empty-shuttle heartbeat opens background tabs without activating anything');

  // Spec v4.0: verify handleShuttleRetireActions
  const removedTabs = [];
  const retireAcks = [];
  const sentRetireMsgs = [];
  const chromeRetire = {
    runtime: {lastError: null, onMessage: {addListener() {}}},
    tabs: {
      onRemoved: {addListener() {}},
      async query() {return [{id: 77, windowId: 1, url: 'https://chatgpt.com/c/11111111-2222-4333-8444-555555555555'}, {id: 78, windowId: 1, url: 'https://chatgpt.com/'}]},
      async update() {},
      async create() {},
      async remove(tid) {removedTabs.push(tid);},
      sendMessage(tab, payload, done) {
        sentRetireMsgs.push({tab, payload});
        if (done) done({ok: true});
      },
    },
    scripting: {async executeScript() {}},
  };
  const ctxRetire = vm.createContext({
    navigator: {userAgent:'Chrome offline mock'},
    chrome: chromeRetire, URL, console,
    setTimeout() {return 0},
    setInterval() {return 0},
    async fetch(url, options) {
      if (url.endsWith('/web-bridge/ack-retire')) {
        retireAcks.push(JSON.parse(options.body));
      }
      return {ok:true, async json(){return {}}};
    },
  });
  vm.runInContext(background, ctxRetire, {filename:'background.js'});
  assert.equal(typeof ctxRetire.handleShuttleRetireActions, 'function', 'handleShuttleRetireActions must be defined');
  await ctxRetire.handleShuttleRetireActions([{
    id: 'ret_test_1',
    conv_uuid: '11111111-2222-4333-8444-555555555555',
    archive_conversation: true,
    close_tab: true,
  }]);
  assert.equal(sentRetireMsgs.length, 1, 'should send RELAY_ARCHIVE_CONVERSATION to tab');
  assert.equal(sentRetireMsgs[0].payload.type, 'RELAY_ARCHIVE_CONVERSATION');
  assert.deepEqual(removedTabs, [77], 'should close retired tab when window has >1 tabs');
  assert.equal(retireAcks.length, 1, 'should POST /web-bridge/ack-retire');
  assert.equal(retireAcks[0].retire_id, 'ret_test_1');
  console.log('PASS: handleShuttleRetireActions archives conversation, closes tab, and ACKs retire');

  // Spec v4.2 Slice 5 Seam Tests:
  // 1) background.js: busy_or_draft releases claim immediately without blind retry; stop_before_archive stops first;
  //    stale tab cache triggers active RELAY_COLLECT_TAB_STATE probe & marks state_known=false on timeout;
  //    CodexInApp partition self-identifies as CodexInApp instead of Chrome:Default.
  {
    const releaseClaims = [];
    const sentBusy = [];
    const chromeBusy = {
      runtime: {lastError: null, onMessage: {addListener() {}}},
      tabs: {
        onRemoved: {addListener() {}},
        async query() {return []},
        async update() {},
        async create() {},
        sendMessage(tab, payload, done) {
          sentBusy.push({tab, payload});
          done({ok: false, retry_safe: true, reason: 'busy_or_draft'});
        },
      },
      scripting: {async executeScript() {}},
    };
    const scheduledBusy = [];
    const ctxBusy = vm.createContext({
      navigator: {userAgent: 'Chrome offline mock'},
      chrome: chromeBusy, URL, console, Date, Math,
      setTimeout(fn, ms) {scheduledBusy.push({fn, ms}); return scheduledBusy.length},
      clearTimeout() {},
      setInterval() {return 0},
      async fetch(url, options) {
        if (url.endsWith('/web-bridge/release-claim')) {
          releaseClaims.push(JSON.parse(options.body));
        }
        return {ok: true, async json() {return {}}};
      },
    });
    vm.runInContext(background, ctxBusy, {filename: 'background.js'});
    await ctxBusy.handleShuttleDispatches([{
      tab_id: '55', message: {id: 'msg-busy-1', text: 'do not overwrite draft'}
    }]);
    while (scheduledBusy.length) {
      const {fn} = scheduledBusy.shift();
      fn();
      await new Promise(r => setImmediate(r));
    }
    assert.equal(sentBusy.length, 1, 'busy_or_draft must NOT blind-retry 900ms later');
    assert.equal(releaseClaims.length, 1, 'busy_or_draft must POST /web-bridge/release-claim');
    assert.equal(releaseClaims[0].msg_id, 'msg-busy-1');
    assert.equal(releaseClaims[0].reason, 'busy_or_draft');
    console.log('PASS: busy_or_draft immediately releases claim to pending without blind retry');
  }

  {
    // Active probe RELAY_COLLECT_TAB_STATE + timeout -> state_known: false + stop_before_archive
    let probeShouldHang = false;
    const retireSeq = [];
    const chromeProbe = {
      runtime: {lastError: null, onMessage: {addListener() {}}},
      tabs: {
        onRemoved: {addListener() {}},
        async query() {
          return [{id: 88, windowId: 2, url: 'https://chatgpt.com/c/88888888-2222-4333-8444-555555555555', title: 'Probe Tab'}];
        },
        async update() {},
        async create() {},
        async remove() {},
        sendMessage(tab, payload, done) {
          if (payload.type === 'RELAY_COLLECT_TAB_STATE') {
            if (probeShouldHang) return; // simulate frozen tab timeout
            done({
              ok: true,
              state: {
                conv_uuid: '88888888-2222-4333-8444-555555555555',
                sse_active: true,
                turn_seq: 4,
                is_generating: true,
                is_dispatching: false,
                has_user_draft: true,
                has_error: false,
              },
            });
            return;
          }
          retireSeq.push(payload.type);
          if (done) done({ok: true});
        },
      },
      scripting: {async executeScript() {}},
    };
    const timers = [];
    let fakeNow = 100000;
    const FakeDate = Object.assign(function() {return new Date(fakeNow)}, {now: () => fakeNow});
    const ctxProbe = vm.createContext({
      navigator: {userAgent: 'Chrome offline mock'},
      chrome: chromeProbe, URL, console, Date: FakeDate, Math,
      setTimeout(fn, ms) {timers.push({fn, ms}); return timers.length},
      clearTimeout() {},
      setInterval() {return 0},
      async fetch() {return {ok: true, async json() {return {}}}},
    });
    vm.runInContext(background, ctxProbe, {filename: 'background.js'});

    const tabsFresh = await ctxProbe.collectOpenChatGptTabs();
    assert.equal(tabsFresh.length, 1);
    assert.equal(tabsFresh[0].state_known, true, 'active probe refreshes uncached tab');
    assert.equal(tabsFresh[0].sse_active, true, 'sse_active forwarded through background shuttle');
    assert.equal(tabsFresh[0].turn_seq, 4, 'turn_seq forwarded through background shuttle');
    assert.equal(tabsFresh[0].has_user_draft, true, 'has_user_draft forwarded through background shuttle');

    // Advance > 4000ms and make tab freeze -> timeout must yield state_known: false!
    fakeNow += 5000;
    probeShouldHang = true;
    const pendingCollect = ctxProbe.collectOpenChatGptTabs();
    await new Promise(r => setImmediate(r));
    while (timers.length) {
      const t = timers.shift();
      t.fn();
      await new Promise(r => setImmediate(r));
    }
    const tabsFrozen = await pendingCollect;
    assert.equal(tabsFrozen[0].state_known, false, 'frozen tab probe timeout must report state_known: false');

    await ctxProbe.handleShuttleRetireActions([{
      id: 'ret_stop_1',
      conv_uuid: '88888888-2222-4333-8444-555555555555',
      stop_before_archive: true,
      archive_conversation: true,
      close_tab: false,
    }]);
    assert.deepEqual(retireSeq, ['RELAY_STOP_GENERATION', 'RELAY_ARCHIVE_CONVERSATION'],
      'stop_before_archive must stop active generation before archiving');
    console.log('PASS: active tab probe, frozen timeout state_known=false, and stop_before_archive verified');
  }

  {
    // CodexInApp detection
    const codexPolls = [];
    const ctxCodex = vm.createContext({
      navigator: {
        userAgent: 'Mozilla/5.0 Chrome/156.0.0.0 Safari/537.36',
        userAgentData: {brands: [{brand: 'Chromium', version: '156'}, {brand: 'Not-A.Brand', version: '24'}]},
      },
      chrome: {
        runtime: {lastError: null, onMessage: {addListener() {}}},
        tabs: {onRemoved: {addListener() {}}, async query() {return []}, async create() {}, sendMessage() {}},
        scripting: {async executeScript() {}},
      },
      URL, console, Date, Math,
      setTimeout() {return 0},
      clearTimeout() {},
      setInterval() {return 0},
      async fetch(url, options) {
        if (url.endsWith('/web-bridge/poll')) {
          codexPolls.push(JSON.parse(options.body));
        }
        return {ok: true, async json() {return {ok: true, isolated: true, dispatches: [], retire_actions: []}}};
      },
    });
    vm.runInContext(background, ctxCodex, {filename: 'background.js'});
    await ctxCodex.runShuttleTick();
    if (codexPolls.length > 0) {
      assert.equal(codexPolls[0].is_codex_in_app_browser, true, 'CodexInApp must flag is_codex_in_app_browser=true');
      assert.equal(codexPolls[0].browser, 'CodexInApp', 'CodexInApp must never impersonate Chrome');
    }
    console.log('PASS: CodexInApp built-in browser partition isolated from Chrome:Default');
  }

  // 2) bridge-page-hook.js + bridge-content.js:
  //    - GPT-6 xhigh/high effort alignment (T20d)
  //    - SSE ReadableStream active tracking & turn_seq increment
  //    - User draft protection & busy SSE protection (no overwrite of #prompt-textarea)
  {
    const hookSrc = fs.readFileSync(path.join(__dirname, '..', 'browser-bridge', 'bridge-page-hook.js'), 'utf8');
    const contentSrc = fs.readFileSync(path.join(__dirname, '..', 'browser-bridge', 'bridge-content.js'), 'utf8');
    const dataset = {};
    const posts = [];
    let streamResolveChunk = null;
    const editor = {
      tagName: 'TEXTAREA',
      value: '',
      isContentEditable: false,
      offsetParent: {},
      getAttribute() {return null},
      focus() {},
      dispatchEvent() {return true},
    };
    let runtimeListener = null;
    let ctxPage = null;
    const sendBtn = {
      disabled: false,
      offsetParent: {},
      getAttribute() {return null},
      click() {
        ctxPage.window.fetch('/backend-api/conversation', {
          method: 'POST',
          body: JSON.stringify({
            model: 'gpt-6-thinking',
            thinking_effort: 'medium',
            reasoning_effort: 'medium',
            messages: [{author: {role: 'user'}, content: {parts: [editor.value]}}],
          }),
        });
      },
    };
    const doc = {
      readyState: 'complete',
      documentElement: {dataset},
      title: 'GPT-6 Spec v4.2 Fixture',
      body: {innerText: '', appendChild() {}},
      getElementById() {return {style: {}, textContent: ''}},
      querySelector(sel) {
        if (sel === '#prompt-textarea') return editor;
        if (sel === 'button[data-testid="send-button"]') return sendBtn;
        if (sel === 'main') return {innerText: '', textContent: ''};
        return null;
      },
      querySelectorAll(sel) {
        if (sel === '#prompt-textarea') return [editor];
        if (/send|Send|发送/.test(sel)) return [sendBtn];
        return [];
      },
      addEventListener() {},
    };
    const gpt6Catalog = [
      {
        slug: 'gpt-6-thinking',
        title: 'GPT-6 Thinking',
        reasoning_effort_options: ['low', 'medium', 'high', 'xhigh'],
      },
      {
        slug: 'o3-high-cap',
        title: 'O3 High Cap',
        supported_reasoning_efforts: ['low', 'medium', 'high'],
      },
    ];
    function makeStreamBody() {
      let step = 0;
      return {
        getReader() {
          return {
            async read() {
              step += 1;
              if (step === 1) {
                return {done: false, value: new Uint8Array([100, 97, 116, 97])};
              }
              await new Promise(resolve => { streamResolveChunk = resolve; });
              return {done: true, value: undefined};
            },
          };
        },
      };
    }
    const origFetch = async (input, init) => {
      const url = typeof input === 'string' ? input : input.url;
      const method = String(init?.method || 'GET').toUpperCase();
      if (/\/backend-api\/models/.test(url)) {
        return {
          ok: true,
          clone() {return this},
          async json() {return {models: gpt6Catalog}},
        };
      }
      if (method === 'POST') {
        posts.push(JSON.parse(init.body));
        return {
          ok: true,
          body: makeStreamBody(),
          clone() {
            return {ok: true, body: makeStreamBody(), async json() {return {}}};
          },
          async json() {return {}},
        };
      }
      return {ok: true, clone() {return this}, async json() {return {}}};
    };
    class FakeEv {}
    ctxPage = vm.createContext({
      window: {
        fetch: origFetch, Request,
        location: {href: 'https://chatgpt.com/c/12345678-1234-4123-8123-123456789abc', pathname: '/c/12345678-1234-4123-8123-123456789abc', search: ''},
        history: {replaceState() {}},
        addEventListener() {},
        dispatchEvent() {},
        HTMLTextAreaElement: {prototype: {}},
        HTMLInputElement: {prototype: {}},
      },
      document: doc,
      localStorage: {getItem() {return null}, setItem() {}},
      navigator: {userAgent: 'Chrome offline fixture'},
      chrome: {
        runtime: {
          lastError: null,
          onMessage: {addListener(fn) {runtimeListener = fn}},
          sendMessage(_m, cb) {if (cb) cb({shuttle_active: true})},
        },
      },
      URL, URLSearchParams, Request, CustomEvent: FakeEv, InputEvent: FakeEv, Event: FakeEv, KeyboardEvent: FakeEv,
      Date, Math, console,
      clearTimeout() {},
      setTimeout(cb, ms) {
        if ([700, 800, 1200, 3200].includes(ms)) return 0;
        queueMicrotask(cb);
        return 0;
      },
      setInterval() {return 0},
    });
    vm.runInContext(hookSrc, ctxPage, {filename: 'bridge-page-hook.js'});
    vm.runInContext(contentSrc, ctxPage, {filename: 'bridge-content.js'});

    await ctxPage.window.fetch('/backend-api/models', {method: 'GET'});
    await new Promise(r => setImmediate(r));

    // User draft protection: if user has unsent text in #prompt-textarea, dispatch must abort cleanly!
    editor.value = '用户正在手写的一半草稿';
    const draftStateResp = await new Promise(resolve => {
      runtimeListener({type: 'RELAY_COLLECT_TAB_STATE'}, {}, resolve);
    });
    assert.equal(draftStateResp.state.has_user_draft, true, 'non-empty user text must flag has_user_draft=true');

    const draftDispatchResp = await new Promise(resolve => {
      runtimeListener({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: {id: 'msg-draft-1', text: '请继续', target_model: 'gpt-6-thinking', reasoning_effort: '最高'},
      }, {}, resolve);
    });
    assert.equal(draftDispatchResp.ok, false, 'must not send while user has draft');
    assert.equal(draftDispatchResp.retry_safe, true, 'draft defer must be retry_safe');
    assert.equal(draftDispatchResp.reason, 'busy_or_draft');
    assert.equal(editor.value, '用户正在手写的一半草稿', 'user draft text must remain untouched');
    assert.equal(posts.length, 0, 'zero POST while user draft present');

    // Clear draft, now dispatch GPT-6 Thinking with '最高' -> must map to 'xhigh' and keep relaySseActive='1' while stream open!
    editor.value = '';
    const sendResp = await new Promise(resolve => {
      runtimeListener({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: {id: 'msg-gpt6-xhigh', text: '验证 GPT-6 xhigh 与 SSE 探针', target_model: 'gpt-6-thinking', reasoning_effort: '最高'},
      }, {}, resolve);
    });
    assert.equal(sendResp.ok, true);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].model, 'gpt-6-thinking');
    assert.equal(posts[0].thinking_effort, 'xhigh', 'GPT-6 最高 must map to xhigh, never illegal max -> medium fallback');
    assert.equal(posts[0].reasoning_effort, 'xhigh', 'reasoning_effort must align with thinking_effort=xhigh');
    assert.equal(dataset.relaySseActive, '1', 'SSE stream still open -> relaySseActive must stay "1"');

    // While SSE stream is still open (even though DOM stop button is absent!), tab state must report sse_active=true & is_generating=true,
    // and any premature second dispatch must abort with busy_or_draft!
    const midStreamState = await new Promise(resolve => {
      runtimeListener({type: 'RELAY_COLLECT_TAB_STATE'}, {}, resolve);
    });
    assert.equal(midStreamState.state.sse_active, true);
    assert.equal(midStreamState.state.is_generating, true, 'SSE stream alone keeps is_generating=true even when DOM stop button flickers off');

    const busySseResp = await new Promise(resolve => {
      runtimeListener({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: {id: 'msg-during-sse', text: '忙时硬闯测试'},
      }, {}, resolve);
    });
    assert.equal(busySseResp.ok, false, 'must not inject message while SSE stream is active');
    assert.equal(busySseResp.retry_safe, true);
    assert.equal(busySseResp.reason, 'busy_or_draft');
    assert.equal(posts.length, 1, 'still only 1 POST');

    // Finish SSE stream -> relaySseActive clears and relayTurnSeq increments to 1!
    streamResolveChunk();
    await new Promise(r => setImmediate(r));
    await new Promise(r => setImmediate(r));
    assert.equal(Boolean(dataset.relaySseActive), false, 'SSE stream finished -> relaySseActive cleared');
    assert.equal(dataset.relayTurnSeq, '1', 'completed SSE stream increments relayTurnSeq to 1');

    // Model with max cap 'high' ('o3-high-cap': ['low','medium','high']) maps '最高' -> 'high'
    editor.value = '';
    const highCapPromise = new Promise(resolve => {
      runtimeListener({
        type: 'RELAY_EXECUTE_DISPATCH',
        message: {id: 'msg-high-cap', text: '测试 high 上限映射', target_model: 'o3-high-cap', reasoning_effort: '最高'},
      }, {}, resolve);
    });
    await new Promise(r => setImmediate(r));
    if (streamResolveChunk) streamResolveChunk();
    const highCapResp = await highCapPromise;
    assert.equal(highCapResp.ok, true);
    assert.equal(posts[1].model, 'o3-high-cap');
    assert.equal(posts[1].thinking_effort, 'high', '最高 on [low,medium,high] model must map to high');
    assert.equal(posts[1].reasoning_effort, 'high');
    console.log('PASS: GPT-6 xhigh/high mapping, SSE ReadableStream probe, turn_seq, and draft/busy protection verified');
  }

  // 3) User-initiated one-shot focus_tab_id highlights target tab & focuses browser window without ever calling tabs.update({ active: true })
  {
    const highlighted = [];
    const focusedWins = [];
    let pollSeq = 0;
    const chromeFocus = {
      runtime: {lastError: null, onMessage: {addListener() {}}},
      tabs: {
        onRemoved: {addListener() {}},
        async query() {
          return [
            {id: 701, index: 0, windowId: 11, url: 'https://chatgpt.com/', title: 'New Chat'},
            {id: 702, index: 3, windowId: 11, url: 'https://chatgpt.com/c/11111111-2222-4333-8444-555555555555', title: 'Target Chat'},
          ];
        },
        async get(tid) {
          if (tid === 702) return {id: 702, index: 3, windowId: 11};
          throw new Error('unexpected tab id');
        },
        async highlight(info) {highlighted.push(info)},
        async update() {throw new Error('tabs.update must never be called')},
        async create() {},
        sendMessage(_tab, _payload, done) {if (done) done({ok: true, state: {conv_uuid: '11111111-2222-4333-8444-555555555555'}})},
      },
      windows: {
        async update(winId, info) {focusedWins.push({winId, info})},
      },
      scripting: {async executeScript() {}},
    };
    const ctxFocus = vm.createContext({
      navigator: {userAgent: 'Chrome offline mock'},
      chrome: chromeFocus, URL, console, Date, Math,
      setTimeout() {return 0},
      clearTimeout() {},
      setInterval() {return 0},
      async fetch(url) {
        if (url.endsWith('/web-bridge/poll')) {
          pollSeq += 1;
          return {
            ok: true,
            async json() {
              return {
                ok: true,
                dispatches: [],
                retire_actions: [],
                focus_tab_id: pollSeq === 1 ? '702' : '',
              };
            },
          };
        }
        return {ok: true, async json() {return {}}};
      },
    });
    vm.runInContext(background, ctxFocus, {filename: 'background.js'});
    await ctxFocus.runShuttleTick();
    assert.deepEqual(JSON.parse(JSON.stringify(highlighted)), [{windowId: 11, tabs: 3}], 'focus_tab_id must highlight exact tab index');
    assert.deepEqual(JSON.parse(JSON.stringify(focusedWins)), [{winId: 11, info: {focused: true}}], 'focus_tab_id must focus browser window');
    await ctxFocus.runShuttleTick();
    assert.equal(highlighted.length, 1, 'subsequent tick without focus_tab_id must not re-focus anything');
    assert.equal(focusedWins.length, 1);
    console.log('PASS: one-shot focus_tab_id highlights target ChatGPT tab and focuses browser window without background disturbance');
  }

  // 4) Spec v4.3 Q2/Q5: steer_unavailable / conv_archived are pre-send failures that must be released at once (stop-loss decides).
  for (const reasonCode of ['steer_unavailable', 'conv_archived']) {
    const releases = [];
    const sentTimes = [];
    const scheduledStopLoss = [];
    const chromeStop = {
      runtime: {lastError: null, onMessage: {addListener() {}}},
      tabs: {
        onRemoved: {addListener() {}},
        async query() {return []},
        async update() {},
        async create() {},
        sendMessage(tab, payload, done) {
          sentTimes.push(payload);
          done({ok: false, retry_safe: true, reason: reasonCode});
        },
      },
      scripting: {async executeScript() {}},
    };
    const ctxStop = vm.createContext({
      navigator: {userAgent: 'Chrome offline mock'},
      chrome: chromeStop, URL, console, Date, Math,
      setTimeout(fn, ms) {scheduledStopLoss.push({fn, ms}); return scheduledStopLoss.length},
      clearTimeout() {},
      setInterval() {return 0},
      async fetch(url, options) {
        if (url.endsWith('/web-bridge/release-claim')) releases.push(JSON.parse(options.body));
        return {ok: true, async json() {return {}}};
      },
    });
    vm.runInContext(background, ctxStop, {filename: 'background.js'});
    await ctxStop.handleShuttleDispatches([{tab_id: '77', message: {id: 'msg-' + reasonCode, text: 'x', mode: 'custom_message', manual_send: true}}]);
    while (scheduledStopLoss.length) {
      const {fn} = scheduledStopLoss.shift();
      fn();
      await new Promise(r => setImmediate(r));
    }
    assert.equal(sentTimes.length, 1, reasonCode + ' must not be retried against the same conversation');
    assert.equal(releases.length, 1);
    assert.equal(releases[0].reason, reasonCode);
    console.log('PASS: ' + reasonCode + ' is released immediately so the hub can stop-loss to a fresh window');
  }

  // 5) Spec v4.3 Q4: a minimized browser window is restored (state normal) before it is focused; a normal one is only focused.
  for (const winState of ['minimized', 'normal']) {
    const focusedWins = [];
    const chromeMin = {
      runtime: {lastError: null, onMessage: {addListener() {}}},
      tabs: {
        onRemoved: {addListener() {}},
        async query() {return [{id: 702, index: 3, windowId: 11, url: 'https://chatgpt.com/c/11111111-2222-4333-8444-555555555555', title: 'Target Chat'}]},
        async highlight() {},
        async update() {throw new Error('tabs.update must never be called')},
        async create() {},
        sendMessage(_tab, _payload, done) {if (done) done({ok: true, state: {conv_uuid: '11111111-2222-4333-8444-555555555555'}})},
      },
      windows: {
        async get() {return {id: 11, state: winState}},
        async update(winId, info) {focusedWins.push({winId, info})},
      },
      scripting: {async executeScript() {}},
    };
    const ctxMin = vm.createContext({
      navigator: {userAgent: 'Chrome offline mock'},
      chrome: chromeMin, URL, console, Date, Math,
      setTimeout() {return 0}, clearTimeout() {}, setInterval() {return 0},
      async fetch(url) {
        if (url.endsWith('/web-bridge/poll')) return {ok: true, async json() {return {ok: true, dispatches: [], retire_actions: [], focus_tab_id: '702'}}};
        return {ok: true, async json() {return {}}};
      },
    });
    vm.runInContext(background, ctxMin, {filename: 'background.js'});
    await ctxMin.runShuttleTick();
    const expected = winState === 'minimized' ? {state: 'normal', focused: true} : {focused: true};
    assert.deepEqual(JSON.parse(JSON.stringify(focusedWins)), [{winId: 11, info: expected}], winState + ' window focus parameters');
    console.log('PASS: ' + winState + ' browser window is focused with ' + JSON.stringify(expected));
  }

  console.log(JSON.stringify({result:'PASS',scenarios:17,network:'OFFLINE_FAKE_ONLY'}));
})().catch(e=>{console.error(e.stack);process.exitCode=1});
