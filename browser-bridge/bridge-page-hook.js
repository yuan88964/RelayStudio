// RelayStudio Web Bridge - MAIN World Page Hook (bridge-page-hook.js)
// Runs in page MAIN world at document_start to:
// 1. Intercept GET /backend-api/models and cache the account's real model & effort catalog
// 2. Intercept GET /backend-api/conversation/<uuid> to capture active model & effort
// 3. Intercept POST /backend-api/(f/)?conversation(\/prepare)? to override model & thinking_effort directly in JSON body without any DOM menu clicking

(() => {
  // Never mutate third-party requests using ChatGPT's private API schema.
  try {if (!['chatgpt.com', 'chat.openai.com'].includes(new URL(window.location.href).hostname)) return;} catch (_) {return;}

  if (window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__) {
    return;
  }
  window.__RELAYSTUDIO_PAGE_HOOK_INSTALLED__ = true;

  const MODELS_CACHE_KEY = "__relaystudio_models_cache__";

  let latestModelsCatalog = [];
  let activeSseCount = 0;
  let acceptedPostSeq = 0;
  let completedTurnSeq = 0;

  function safeSetDataset(key, value) {
    try {
      if (document && document.documentElement) {
        if (value === undefined || value === null || value === "") {
          delete document.documentElement.dataset[key];
        } else {
          document.documentElement.dataset[key] = String(value);
        }
      }
    } catch {
      // ignore
    }
  }

  function safeGetDataset(key) {
    try {
      if (document && document.documentElement && document.documentElement.dataset) {
        return String(document.documentElement.dataset[key] || "").trim();
      }
    } catch {
      // ignore
    }
    return "";
  }

  // Spec v4.3: register task numbers (tsk_/wfr_) once, where they pass through the door (live stream, outgoing request,
  // loaded conversation). A tiny most-recent-first list lives in the page dataset; nobody has to scan page text any more.
  const taskHintList = [];
  function registerTaskHints(found) {
    if (!found || !found.length) return;
    let changed = false;
    for (const raw of found) {
      const h = String(raw || "").trim();
      if (!h) continue;
      const at = taskHintList.indexOf(h);
      if (at === 0) continue;
      if (at > 0) taskHintList.splice(at, 1);
      taskHintList.unshift(h);
      changed = true;
    }
    if (!changed) return;
    if (taskHintList.length > 16) taskHintList.length = 16;
    safeSetDataset("relayTaskHints", taskHintList.join(","));
  }

  function registerTaskHintsFromText(text) {
    const t = typeof text === "string" ? text : "";
    if (!t || (t.indexOf("tsk_") < 0 && t.indexOf("wfr_") < 0)) return;
    const hits = (t.match(/\btsk_[0-9a-fA-F_]{6,32}\b/g) || []).concat(t.match(/\bwfr_[0-9a-fA-F_]{8,40}\b/g) || []);
    registerTaskHints(hits);
  }

  function syncSseActiveDataset() {
    safeSetDataset("relaySseActive", activeSseCount > 0 ? "1" : "");
  }

  function markUserTurnAccepted() {
    acceptedPostSeq += 1;
    safeSetDataset("relayAcceptedPostSeq", String(acceptedPostSeq));
    // Spec v4.7 1.1: a newly accepted user turn starts with a clean closure verdict.
    safeSetDataset("relayStreamIncomplete", "");
    safeSetDataset("relayTurnIncomplete", "");
  }

  function markSseStreamCompleted(assistantCompletedCleanly = true) {
    activeSseCount = Math.max(0, activeSseCount - 1);
    if (assistantCompletedCleanly) {
      completedTurnSeq += 1;
    }
    syncSseActiveDataset();
    safeSetDataset("relayTurnSeq", String(completedTurnSeq));
    safeSetDataset("relayLastTurnDoneAt", String(Date.now()));
  }

  function normalizeEfforts(rawModel) {
    if (!rawModel || typeof rawModel !== "object") {
      return [];
    }
    const pf = rawModel.product_features && typeof rawModel.product_features === "object"
      ? rawModel.product_features
      : null;
    const pfRc = pf && pf.reasoning_config && typeof pf.reasoning_config === "object"
      ? pf.reasoning_config
      : null;
    const rc = rawModel.reasoning_config && typeof rawModel.reasoning_config === "object"
      ? rawModel.reasoning_config
      : null;
    const candidates =
      (pfRc && (pfRc.supported_efforts || pfRc.reasoning_effort_options || pfRc.supported_reasoning_efforts)) ||
      (pf && (pf.reasoning_effort_options || pf.supported_reasoning_efforts || pf.thinking_efforts)) ||
      (rc && (rc.supported_efforts || rc.reasoning_effort_options || rc.supported_reasoning_efforts)) ||
      rawModel.reasoning_effort_options ||
      rawModel.supported_reasoning_efforts ||
      rawModel.thinking_efforts ||
      rawModel.supported_efforts ||
      [];

    if (!Array.isArray(candidates)) {
      return [];
    }
    const seen = new Set();
    const result = [];
    for (const item of candidates) {
      let id = "";
      let label = "";
      let fullLabel = "";
      if (typeof item === "string") {
        id = item.trim().toLowerCase();
      } else if (item && typeof item === "object") {
        id = String(
          item.thinking_effort ||
            item.id ||
            item.slug ||
            item.reasoning_effort ||
            item.effort ||
            item.value ||
            item.name ||
            ""
        )
          .trim()
          .toLowerCase();
        label = String(
          item.short_label ||
            item.mobile_full_label ||
            item.title ||
            item.label ||
            item.display_name ||
            item.full_label ||
            ""
        ).trim();
        fullLabel = String(item.full_label || label || "").trim();
      }
      if (!id || seen.has(id)) {
        continue;
      }
      seen.add(id);
      const resolvedLabel = label || id;
      result.push({
        id,
        label: resolvedLabel,
        full_label: fullLabel || resolvedLabel,
      });
    }
    return result;
  }

  function findCatalogModelEfforts(modelSlug) {
    const target = String(modelSlug || "").trim().toLowerCase();
    if (!target) return [];
    let catalog = latestModelsCatalog;
    if (!Array.isArray(catalog) || catalog.length === 0) {
      try {
        const dsRaw = safeGetDataset("relayModelsCatalog");
        if (dsRaw) {
          const parsed = JSON.parse(dsRaw);
          if (Array.isArray(parsed)) catalog = parsed;
        }
      } catch {
        // ignore
      }
    }
    if (!Array.isArray(catalog)) return [];
    const hit = catalog.find(
      (m) => m && String(m.slug || m.id || "").trim().toLowerCase() === target
    );
    if (!hit || !Array.isArray(hit.efforts)) return [];
    return hit.efforts.map((e) => String(e || "").trim().toLowerCase()).filter(Boolean);
  }

  function resolveEffectiveThinkingEffort(effNorm, finalModelSlug, bodyObj) {
    const tierMap = {
      min: "minimal",
      minimal: "minimal",
      light: "low",
      low: "low",
      standard: "medium",
      medium: "medium",
      extended: "high",
      high: "high",
      deep: "high",
      max: "max",
      xhigh: "max",
      heavy: "max",
    };
    const tier = tierMap[effNorm] || "";
    const declaredEfforts = findCatalogModelEfforts(finalModelSlug);
    const bodyHasLmh =
      "reasoning_effort" in bodyObj ||
      /^(minimal|low|medium|high|xhigh)$/i.test(
        String(bodyObj.thinking_effort || bodyObj.reasoning_effort || "")
      );

    // Exact declared effort ID match (e.g. 'xhigh' vs 'max' on 5-tier models) wins immediately unless body uses legacy LMH schema without that ID.
    if (!bodyHasLmh && declaredEfforts.includes(effNorm)) {
      return effNorm;
    }

    if (bodyHasLmh) {
      if (!tier) return effNorm;
      const lmhDeclared = declaredEfforts.filter((e) =>
        ["minimal", "low", "medium", "high", "xhigh"].includes(e)
      );
      if (tier === "minimal") {
        return lmhDeclared.includes("minimal") ? "minimal" : "low";
      }
      if (tier === "low") return "low";
      if (tier === "medium") return "medium";
      if (tier === "high") {
        if (lmhDeclared.length > 0 && !lmhDeclared.includes("high")) {
          return lmhDeclared[lmhDeclared.length - 1];
        }
        return "high";
      }
      if (tier === "max") {
        if (declaredEfforts.includes("xhigh")) return "xhigh";
        if (lmhDeclared.length > 0) return lmhDeclared[lmhDeclared.length - 1];
        if (declaredEfforts.includes("max")) return "max";
        return "xhigh";
      }
    }

    if (declaredEfforts.length > 0 && tier) {
      const prefsByTier = {
        minimal: ["minimal", "min", "light", "low"],
        low: ["light", "low", "minimal", "standard", "medium"],
        medium: ["standard", "medium", "light", "low"],
        high: ["extended", "high", "max", "xhigh", "standard", "medium"],
        max: ["xhigh", "max", "high", "extended"],
      };
      const prefs = prefsByTier[tier] || [];
      for (const candidate of prefs) {
        if (declaredEfforts.includes(candidate)) {
          return candidate;
        }
      }
      return tier === "high" || tier === "max"
        ? declaredEfforts[declaredEfforts.length - 1]
        : declaredEfforts[0];
    }

    const fallbackLmh = /gpt-6.*thinking|gpt-6\.\d/i.test(String(finalModelSlug || ""));
    if (fallbackLmh) {
      const toLmhMap = {
        minimal: "low",
        low: "low",
        medium: "medium",
        high: "high",
        max: "xhigh",
      };
      return (tier && toLmhMap[tier]) || effNorm;
    }

    const toStandardMap = {
      minimal: "light",
      low: "light",
      medium: "standard",
      high: "extended",
      max: "max",
    };
    return (tier && toStandardMap[tier]) || effNorm;
  }

  function isFilteredNonChatModel(rawModel, slug) {
    const s = String(slug || "").trim().toLowerCase();
    if (!s) {
      return true;
    }
    if (
      s.endsWith("-wm") ||
      s.startsWith("chatgpt_alpha_model_external_access_reserved_gate_") ||
      s.startsWith("reserved_gate_")
    ) {
      return true;
    }
    if (rawModel && typeof rawModel === "object") {
      if (rawModel.is_work_mode_model === true || rawModel.is_hidden === true || rawModel.hidden === true) {
        return true;
      }
      if (String(rawModel.model_lane || "").trim().toLowerCase() === "thinking_plus_plus") {
        return true;
      }
      if (
        Array.isArray(rawModel.tags) &&
        rawModel.tags.some((t) => String(t || "").trim().toLowerCase() === "hidden")
      ) {
        return true;
      }
    }
    return false;
  }

  function extractModelsCatalog(payload) {
    if (!payload || typeof payload !== "object") {
      return [];
    }
    const rawList = Array.isArray(payload.models)
      ? payload.models
      : Array.isArray(payload.items)
        ? payload.items
        : Array.isArray(payload.data)
          ? payload.data
          : [];
    if (!rawList.length) {
      return [];
    }

    const seen = new Set();
    const catalog = [];
    for (const m of rawList) {
      if (!m || typeof m !== "object") {
        continue;
      }
      const slug = String(m.slug || m.id || "").trim();
      if (!slug || seen.has(slug) || isFilteredNonChatModel(m, slug)) {
        continue;
      }
      const title = String(m.title || m.display_name || m.name || slug).trim();
      const description = String(m.description || m.short_description || "").trim();
      const effortsObj = normalizeEfforts(m);
      const efforts = effortsObj.map((e) => e.id);
      const pf = m.product_features && typeof m.product_features === "object" ? m.product_features : null;
      const pfRc = pf && pf.reasoning_config && typeof pf.reasoning_config === "object" ? pf.reasoning_config : null;
      const rc = m.reasoning_config && typeof m.reasoning_config === "object" ? m.reasoning_config : null;
      const defaultEffort = String(
        m.default_thinking_effort ||
          (pfRc && (pfRc.default_effort || pfRc.default_thinking_effort)) ||
          (rc && (rc.default_effort || rc.default_thinking_effort)) ||
          ""
      )
        .trim()
        .toLowerCase();
      const configurableEffort =
        typeof m.configurable_thinking_effort === "boolean"
          ? m.configurable_thinking_effort
          : effortsObj.length > 0;
      seen.add(slug);
      catalog.push({
        slug,
        title,
        description,
        efforts,
        effort_items: effortsObj,
        default_effort: defaultEffort,
        configurable_effort: configurableEffort,
      });
    }
    return catalog;
  }

  function persistModelsCatalog(catalog) {
    if (!Array.isArray(catalog) || catalog.length === 0) {
      return;
    }
    latestModelsCatalog = catalog;
    try {
      const serialized = JSON.stringify({
        updated_at: Date.now(),
        models: catalog,
      });
      localStorage.setItem(MODELS_CACHE_KEY, serialized);
      safeSetDataset("relayModelsCatalog", JSON.stringify(catalog));
    } catch {
      // ignore storage errors
    }
  }

  function hydrateCachedCatalog() {
    try {
      const raw = localStorage.getItem(MODELS_CACHE_KEY);
      if (!raw) {
        return false;
      }
      const parsed = JSON.parse(raw);
      const rawModels = Array.isArray(parsed)
        ? parsed
        : parsed && Array.isArray(parsed.models)
          ? parsed.models
          : [];
      const models = rawModels.filter((m) => m && !isFilteredNonChatModel(m, m.slug || m.id));
      if (models.length > 0) {
        latestModelsCatalog = models;
        safeSetDataset("relayModelsCatalog", JSON.stringify(models));
        return true;
      }
    } catch {
      // ignore
    }
    return false;
  }

  function inspectConversationPayload(data, urlHint) {
    if (!data || typeof data !== "object") {
      return;
    }
    const convUuid = String(
      data.conversation_id ||
        (urlHint && (urlHint.match(/\/conversation\/([0-9a-f-]{36})/i) || [])[1]) ||
        ""
    ).trim();
    const defaultModel = String(
      data.default_model_slug || data.model_slug || data.model || ""
    ).trim();
    // Inspect latest assistant/user message metadata first for server-resolved model truth
    let latestNodeModel = "";
    let latestNodeEffort = "";
    if (data.mapping && typeof data.mapping === "object") {
      let latestCreateTime = -1;
      for (const node of Object.values(data.mapping)) {
        const msg = node && node.message;
        if (!msg || !msg.metadata) {
          continue;
        }
        const ct = Number(msg.create_time || 0);
        const mSlug = String(
          msg.metadata.resolved_model_slug ||
            msg.metadata.model_slug ||
            msg.metadata.default_model_slug ||
            ""
        ).trim();
        const tEffort = String(
          msg.metadata.thinking_effort || msg.metadata.reasoning_effort || ""
        ).trim();
        if (mSlug && ct >= latestCreateTime) {
          latestCreateTime = ct;
          latestNodeModel = mSlug;
          latestNodeEffort = tEffort;
        }
      }
    }
    const effectiveModel =
      latestNodeModel && !isFilteredNonChatModel(null, latestNodeModel)
        ? latestNodeModel
        : !isFilteredNonChatModel(null, defaultModel)
          ? defaultModel
          : "";
    if (effectiveModel) {
      safeSetDataset("relayActiveModel", effectiveModel);
      if (convUuid) {
        safeSetDataset("relayActiveConvUuid", convUuid);
      }
    }
    if (latestNodeEffort) {
      safeSetDataset("relayActiveEffort", latestNodeEffort);
      if (convUuid) {
        safeSetDataset("relayActiveConvUuid", convUuid);
      }
    } else if (
      effectiveModel &&
      /^(gpt-6|gpt-5-6|gpt-6-instant|gpt-5-6-instant|auto)$/i.test(effectiveModel)
    ) {
      safeSetDataset("relayActiveEffort", "none");
      if (convUuid) {
        safeSetDataset("relayActiveConvUuid", convUuid);
      }
    }
    if (convUuid) {
      if (data.is_archived === true) {
        safeSetDataset("relayArchivedConv", convUuid);
      } else if (data.is_archived === false && safeGetDataset("relayArchivedConv") === convUuid) {
        safeSetDataset("relayArchivedConv", "");
      }
    }
    try {
      const rawJsonStr = JSON.stringify(data);
      const tskHits = rawJsonStr.match(/\btsk_[0-9a-fA-F_]{6,32}\b/g) || [];
      const wfrHits = rawJsonStr.match(/\bwfr_[0-9a-fA-F_]{8,40}\b/g) || [];
      const combined = Array.from(new Set([...tskHits, ...wfrHits])).slice(0, 16);
      registerTaskHints(combined);
    } catch {
      // ignore
    }
  }

  const origFetch = window.fetch;
  if (typeof origFetch === "function") {
    window.fetch = async function (...args) {
      let [input, init] = args;
      const url =
        typeof input === "string"
          ? input
          : input && typeof input.url === "string"
            ? input.url
            : "";
      const method = String(
        (init && init.method) || (input && input.method) || "GET"
      ).toUpperCase();

      // Outgoing POST conversation request override (Mechanism 2)
      const isConversationPost =
        method === "POST" &&
        /\/backend-api\/(?:f\/)?conversation(?:\/prepare)?(?:\?|$)/.test(url);

      const isPrepare = /\/prepare(?:\?|$)/.test(url);
      const dispatchId = isConversationPost && !isPrepare ? safeGetDataset("relayDispatchId") : "";
      // Spec v4.7 1.1: Sentinel PoW / prepare happen before the real POST; when they fail (offline, 403/429/5xx) the
      // correlated dispatch must fail at once instead of letting waitForDispatchAcceptance wait for a POST that never comes.
      const isSentinel = /\/backend-api\/(?:f\/)?sentinel\//i.test(url);
      const isPreflightStage = isSentinel || (isConversationPost && isPrepare);
      const activeDispatchId = isConversationPost || isSentinel ? safeGetDataset("relayDispatchId") : "";
      const failPreflightDispatch = () => {
        if (isPreflightStage && activeDispatchId && safeGetDataset("relayDispatchId") === activeDispatchId) {
          safeSetDataset("relayDispatchStatus", "failed");
          safeSetDataset("relayTurnIncomplete", "1");
        }
      };
      let payloadVerified = false;
      let submittedModel = "";
      let submittedEffort = "";
      let submittedConvId = "";

      if (isConversationPost) {
        try {
          const RequestCtor = window.Request;
          const isRequest = typeof RequestCtor === "function" && input instanceof RequestCtor;
          // A browser may call fetch(new Request(...)), with no init.body.
          // Read only a clone so the original request remains usable.
          const bodyText = init && typeof init.body === "string"
            ? init.body
            : isRequest ? await input.clone().text() : "";
          if (bodyText) {
            registerTaskHintsFromText(bodyText.length > 40000 ? bodyText.slice(-40000) : bodyText);
            const bodyObj = JSON.parse(bodyText);
            const overrideModel = safeGetDataset("relayOverrideModel");
            const overrideEffort = safeGetDataset("relayOverrideEffort");
            let modified = false;

            let expectedModel =
              overrideModel && overrideModel !== "inherit" ? overrideModel : "";
            let appliedEffort = overrideEffort;
            if (expectedModel) {
              bodyObj.model = expectedModel;
              modified = true;
            }
            if (overrideEffort && overrideEffort !== "inherit") {
              const effNorm = overrideEffort.trim().toLowerCase();
              const curModelLower = String(bodyObj.model || "").trim().toLowerCase();
              if (effNorm === "instant" || effNorm === "none") {
                if (curModelLower === "gpt-6" || curModelLower === "gpt-6-thinking") {
                  bodyObj.model = "gpt-6-instant";
                  expectedModel = "gpt-6-instant";
                } else if (curModelLower === "gpt-5-6" || curModelLower === "gpt-5-6-thinking") {
                  bodyObj.model = "gpt-5-6-instant";
                  expectedModel = "gpt-5-6-instant";
                }
                delete bodyObj.thinking_effort;
                delete bodyObj.reasoning_effort;
                appliedEffort = undefined;
                modified = true;
              } else {
                if (curModelLower === "gpt-6" || curModelLower === "gpt-6-instant") {
                  bodyObj.model = "gpt-6-thinking";
                  expectedModel = "gpt-6-thinking";
                } else if (curModelLower === "gpt-5-6" || curModelLower === "gpt-5-6-instant") {
                  bodyObj.model = "gpt-5-6-thinking";
                  expectedModel = "gpt-5-6-thinking";
                }
                const finalModelLower = String(bodyObj.model || "").trim().toLowerCase();
                appliedEffort = resolveEffectiveThinkingEffort(effNorm, finalModelLower, bodyObj);
                bodyObj.thinking_effort = appliedEffort;
                if (
                  "reasoning_effort" in bodyObj ||
                  ["minimal", "low", "medium", "high", "xhigh"].includes(String(appliedEffort || ""))
                ) {
                  bodyObj.reasoning_effort = appliedEffort;
                }
                modified = true;
              }
            }

            if (modified) {
              const nextBody = JSON.stringify(bodyObj);
              if (init && typeof init.body === "string") {
                args[1] = Object.assign({}, init, { body: nextBody });
              } else if (isRequest) {
                args[0] = new RequestCtor(input, Object.assign({}, init || {}, { body: nextBody }));
              } else {
                throw new Error("Unsupported conversation request body");
              }
            }

            payloadVerified =
              (!expectedModel || bodyObj.model === expectedModel) &&
              (!overrideEffort || overrideEffort === "inherit" || bodyObj.thinking_effort === appliedEffort);
            submittedModel = String(bodyObj.model || "");
            submittedEffort = String(bodyObj.thinking_effort || "");
            submittedConvId = String(bodyObj.conversation_id || "");
          }
        } catch {
          // Do not acknowledge an uninspectable/unmodified conversation request.
        }

        if (!isPrepare) {
          safeSetDataset("relayOverrideModel", "");
          safeSetDataset("relayOverrideEffort", "");
          if (dispatchId && safeGetDataset("relayDispatchId") === dispatchId) {
            safeSetDataset("relayDispatchStatus", payloadVerified ? "inflight" : "failed");
          }
        }
      }

      const trackSseForTurn = Boolean(isConversationPost && !isPrepare);
      if (trackSseForTurn) {
        activeSseCount += 1;
        syncSseActiveDataset();
      }

      let response;
      try {
        response = await origFetch.apply(this, args);
      } catch (error) {
        if (trackSseForTurn) {
          activeSseCount = Math.max(0, activeSseCount - 1);
          syncSseActiveDataset();
        }
        if (dispatchId && safeGetDataset("relayDispatchId") === dispatchId) {
          safeSetDataset("relayDispatchStatus", "failed");
        }
        failPreflightDispatch();
        throw error;
      }

      if (!response || !response.ok) {
        failPreflightDispatch();
      }

      if (trackSseForTurn) {
        if (!response || !response.ok) {
          activeSseCount = Math.max(0, activeSseCount - 1);
          syncSseActiveDataset();
        } else {
          markUserTurnAccepted();
          let trackedStream = false;
          try {
            if (response.body && typeof response.clone === "function") {
              const cloned = response.clone();
              if (cloned && cloned.body && typeof cloned.body.getReader === "function") {
                const reader = cloned.body.getReader();
                trackedStream = true;
                (async () => {
                  let dec = null;
                  let carry = "";
                  let streamErrored = false;
                  // Spec v4.7 1.1: positive closure. Only a stream that carried real SSE frames must end with
                  // [DONE] / message_stream_complete; tiny synthetic bodies (offline fixtures) are not judged.
                  let sawRealSseFrame = false;
                  let sawSseDone = false;
                  let sawSseErrorEvent = false;
                  try {
                    dec = typeof TextDecoder === "function" ? new TextDecoder("utf-8") : null;
                  } catch {
                    dec = null;
                  }
                  try {
                    while (true) {
                      const step = await reader.read();
                      if (!step || step.done) break;
                      // Spec v4.3: peek at each small stream chunk once (plus a short carry for split tokens) to register task
                      // numbers that ChatGPT later folds into the collapsed "thinking" drawer. O(chunk), nothing is retained.
                      if (dec && step.value) {
                        try {
                          const piece = carry + dec.decode(step.value, { stream: true });
                          registerTaskHintsFromText(piece);
                          if (!sawRealSseFrame && /\b(?:event:\s*\w+|data:\s*\{)/.test(piece)) sawRealSseFrame = true;
                          if (!sawSseDone && /data:\s*\[DONE\]|"message_stream_complete"|"status"\s*:\s*"finished_successfully"/.test(piece)) {
                            sawSseDone = true;
                          }
                          if (!sawSseErrorEvent && /^event:\s*error\b|"error"\s*:\s*\{[^}]*"message"/m.test(piece)) {
                            sawSseErrorEvent = true;
                          }
                          carry = piece.slice(-48);
                        } catch {
                          carry = "";
                        }
                      }
                    }
                  } catch {
                    streamErrored = true;
                  } finally {
                    const incomplete = Boolean(streamErrored || sawSseErrorEvent || (sawRealSseFrame && !sawSseDone));
                    safeSetDataset("relayStreamIncomplete", incomplete ? "1" : "");
                    safeSetDataset("relayTurnIncomplete", incomplete ? "1" : "");
                    markSseStreamCompleted(!incomplete);
                  }
                })();
              }
            }
          } catch {
            // clone/getReader unavailable
          }
          if (!trackedStream) {
            markSseStreamCompleted(true);
          }
        }
      }

      if (isConversationPost && !isPrepare && response && response.ok && payloadVerified) {
        if (submittedModel) safeSetDataset("relayActiveModel", submittedModel);
        if (submittedEffort) safeSetDataset("relayActiveEffort", submittedEffort);
        if (submittedConvId) {
          safeSetDataset("relayActiveConvUuid", submittedConvId);
        } else {
          const locMatch = (window.location && window.location.pathname || "").match(/\/c\/([0-9a-f-]{36})/i);
          if (locMatch) safeSetDataset("relayActiveConvUuid", locMatch[1]);
        }
      }
      if (dispatchId && safeGetDataset("relayDispatchId") === dispatchId) {
        safeSetDataset("relayDispatchStatus", response && response.ok && payloadVerified ? "accepted" : "failed");
      }

      try {
        if (/\/backend-api\/models(?:\?|$)/.test(url) && response && response.ok) {
          response
            .clone()
            .json()
            .then((data) => {
              const catalog = extractModelsCatalog(data);
              if (catalog.length > 0) {
                persistModelsCatalog(catalog);
              }
            })
            .catch(() => {});
        } else if (
          method === "GET" &&
          /\/backend-api\/conversation\/[0-9a-fA-F-]{16,}/.test(url) &&
          response &&
          response.ok
        ) {
          response
            .clone()
            .json()
            .then((data) => {
              inspectConversationPayload(data, url);
            })
            .catch(() => {});
        }
      } catch {
        // ignore clone errors
      }

      return response;
    };
  }

  function hasMountedChatComposer() {
    try {
      if (!document || typeof document.querySelector !== "function") {
        return false;
      }
      return Boolean(
        document.querySelector(
          '#prompt-textarea, div.ProseMirror[contenteditable="true"], textarea[data-id="root"], form[data-chatgpt-composer]'
        )
      );
    } catch {
      return false;
    }
  }

  async function ensureModelsCatalogLoaded() {
    // Display cached choices immediately.
    hydrateCachedCatalog();
    // Spec v4.5: never fire proactive /api/auth/session or /backend-api/models probes on app: protocol,
    // when a cached catalog is already loaded, or before the real ChatGPT composer DOM has mounted
    // (e.g., while Cloudflare Turnstile / challenge screen is active).
    if (
      (typeof location !== "undefined" && location && location.protocol === "app:") ||
      (Array.isArray(latestModelsCatalog) && latestModelsCatalog.length > 0) ||
      !hasMountedChatComposer()
    ) {
      return;
    }
    try {
      const sessResp = await origFetch("/api/auth/session", {
        method: "GET",
        credentials: "include",
      });
      if (!sessResp || !sessResp.ok) {
        return;
      }
      const sess = await sessResp.json();
      const token = sess && sess.accessToken ? String(sess.accessToken).trim() : "";
      if (!token) {
        return;
      }
      const modelsResp = await origFetch("/backend-api/models", {
        method: "GET",
        credentials: "include",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      if (!modelsResp || !modelsResp.ok) {
        return;
      }
      const modelsData = await modelsResp.json();
      const catalog = extractModelsCatalog(modelsData);
      if (catalog.length > 0) {
        persistModelsCatalog(catalog);
      }
    } catch {
      // ignore network/auth errors
    }
  }

  window.addEventListener("relaystudio:fill-composer", (ev) => {
    try {
      const detail = (ev && ev.detail) || {};
      const text = String(detail.text || "");
      // Spec v4.7 1.1: {clear:true} empties a machine-injected ProseMirror draft (React state included).
      if (detail.clear === true) {
        const clearEl =
          document.querySelector("#prompt-textarea") ||
          document.querySelector('div.ProseMirror[contenteditable="true"]') ||
          document.querySelector('textarea[data-id="root"]');
        if (!clearEl) {
          return;
        }
        const clearView =
          (clearEl.pmViewDesc && clearEl.pmViewDesc.view) ||
          clearEl.__pmView ||
          (clearEl.firstChild && clearEl.firstChild.pmViewDesc && clearEl.firstChild.pmViewDesc.view);
        if (clearView && clearView.state && typeof clearView.dispatch === "function") {
          clearView.dispatch(clearView.state.tr.delete(0, clearView.state.doc.content.size));
        }
        return;
      }
      if (!text) {
        return;
      }
      const el =
        document.querySelector("#prompt-textarea") ||
        document.querySelector('div.ProseMirror[contenteditable="true"]') ||
        document.querySelector('textarea[data-id="root"]');
      if (!el) {
        return;
      }
      try {
        el.focus();
      } catch {}

      const pmView =
        (el.pmViewDesc && el.pmViewDesc.view) ||
        el.__pmView ||
        (el.firstChild && el.firstChild.pmViewDesc && el.firstChild.pmViewDesc.view);
      if (pmView && pmView.state && typeof pmView.dispatch === "function") {
        const tr = pmView.state.tr.insertText(text, 0, pmView.state.doc.content.size);
        pmView.dispatch(tr);
        if (document.documentElement && document.documentElement.dataset) {
          document.documentElement.dataset.relayComposerFilled = "1";
        }
      }

      if (((el.innerText || el.value || "").trim().length) < Math.min(2, text.trim().length)) {
        try {
          const sel = window.getSelection();
          const range = document.createRange();
          range.selectNodeContents(el);
          sel.removeAllRanges();
          sel.addRange(range);
          document.execCommand("insertText", false, text);
        } catch {}
      }

      if (((el.innerText || el.value || "").trim().length) < Math.min(2, text.trim().length)) {
        try {
          const dt = new DataTransfer();
          dt.setData("text/plain", text);
          el.dispatchEvent(
            new ClipboardEvent("paste", {
              bubbles: true,
              cancelable: true,
              clipboardData: dt,
            })
          );
        } catch {}
      }
    } catch {
      // ignore
    }
  });

  window.addEventListener("relaystudio:archive-conversation", async (ev) => {
    const detail = (ev && ev.detail) || {};
    const convUuid = String(detail.conv_uuid || "").trim();
    const operation = String(detail.operation || "archive").trim().toLowerCase();
    let patchOk = false;
    try {
      if (!convUuid || typeof origFetch !== "function") {
        return;
      }
      const sessResp = await origFetch("/api/auth/session", {
        method: "GET",
        credentials: "include",
      });
      if (!sessResp || !sessResp.ok) {
        return;
      }
      const sess = await sessResp.json();
      const token = sess && sess.accessToken ? String(sess.accessToken).trim() : "";
      if (!token) {
        return;
      }
      const patchBody =
        operation === "unarchive"
          ? { is_archived: false }
          : operation === "delete"
            ? { is_visible: false }
            : { is_archived: true };
      const patchResp = await origFetch(`/backend-api/conversation/${convUuid}`, {
        method: "PATCH",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify(patchBody),
      });
      patchOk = Boolean(patchResp && patchResp.ok);
    } catch {
      // ignore archive errors
    } finally {
      if (patchOk && convUuid && document.documentElement && document.documentElement.dataset) {
        document.documentElement.dataset.relayLastArchivedUuid = convUuid;
        document.documentElement.dataset.relayLastRetireOp = operation;
      }
      try {
        window.dispatchEvent(
          new CustomEvent("relaystudio:archive-conversation-done", {
            detail: { conv_uuid: convUuid, operation, ok: patchOk },
          })
        );
      } catch {}
    }
  });

  function syncLiveReactComposerState() {
    try {
      const forms = document.querySelectorAll
        ? Array.from(document.querySelectorAll("main form, form") || [])
        : [];
      for (const fm of forms) {
        if (!fm || (fm.closest && fm.closest('[data-codex-composer="true"]'))) continue;
        const fk = Object.keys(fm).find(
          (k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$")
        );
        if (!fk) continue;
        let cur = fm[fk];
        let steps = 0;
        let selModel = null;
        let selPower = null;
        while (cur && steps < 45) {
          steps += 1;
          const p = cur.memoizedProps;
          if (p && typeof p === "object") {
            if (!selModel && p.selectedModel && typeof p.selectedModel === "object") {
              selModel = p.selectedModel;
            }
            if (!selPower && p.selectedPowerSelection && typeof p.selectedPowerSelection === "object") {
              selPower = p.selectedPowerSelection;
            }
            if (selModel || selPower) break;
          }
          cur = cur.return;
        }
        if (selModel || selPower) {
          const liveSlug = String((selModel && selModel.slug) || (selPower && selPower.model) || "").trim();
          const liveEff = String(
            (selModel && selModel.thinkingEffort) || (selPower && selPower.reasoningEffort) || ""
          )
            .trim()
            .toLowerCase();
          safeSetDataset("relayLiveModelSlug", liveSlug);
          safeSetDataset("relayLiveEffortId", liveEff);
          return;
        }
      }
    } catch {
      // ignore fiber inspection errors
    }
  }

  window.addEventListener("relaystudio:sync-live-state", syncLiveReactComposerState);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      hydrateCachedCatalog();
      syncLiveReactComposerState();
      setTimeout(ensureModelsCatalogLoaded, 1200);
    });
  } else {
    hydrateCachedCatalog();
    syncLiveReactComposerState();
    setTimeout(ensureModelsCatalogLoaded, 800);
  }
})();
