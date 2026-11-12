import { useEffect, useRef, useState } from 'preact/hooks';
import type {
  HostInfraBundle,
  ModelCatalogItem,
  PlatformId,
  StudioSessionCard,
  StudioSnapshot,
  TargetMode,
} from '../types/contracts';
import { hostRpc } from '../services/hostBridge';
import { postStudioAction } from '../services/studioHub';
import {
  formatProviderBadge,
  formatShortCarrier,
  normalizeModelCatalogList,
  normalizePlatformId,
} from '../utils/formatters';
import {
  LiveHandoverConfirmDialog,
  type LiveHandoverDecision,
} from './Dialogs';

export interface TaskComposerProps {
  isLaunchpad: boolean;
  isNarrow?: boolean;
  sessionKey: string;
  card: StudioSessionCard | null;
  infra: HostInfraBundle;
  snapshot: StudioSnapshot | null;
  paneCount: number;
  draft: string;
  textareaRef?: { current: HTMLTextAreaElement | null };
  onDraftChange: (nextDraft: string) => void;
  onTargetSelectionChange?: (provider: PlatformId, carrier: string) => void;
  onTaskCreated: (newSessionKey: string) => void;
  onActionSettled: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

interface ComposerConfigState {
  targetMode: TargetMode;
  provider: PlatformId;
  carrier: string;
  targetModel: string;
  reasoningEffort: string;
  autoResendEnabled: boolean;
  stallSeconds: number;
  maxRetries: number;
}

interface OptimisticLockEntry {
  until: number;
  patch: Partial<ComposerConfigState>;
}

const OPTIMISTIC_LOCK_MS = 2_500;
const optimisticLocks = new Map<string, OptimisticLockEntry>();

const ORDERED_PLATFORMS: PlatformId[] = ['chatgpt', 'gemini', 'claude'];

const PLATFORM_LABELS: Record<PlatformId, string> = {
  chatgpt: 'ChatGPT',
  gemini: 'Gemini',
  claude: 'Claude',
};

const CHATGPT_MODELS_CACHE_KEY = 'relaystudio.chatgpt.models_cache';

const cleanCarrierLabel = (raw: string) =>
  String(raw || '')
    .replace(/^(?:💻|🌐|\uFFFD|\?)+[\s·]*/u, '')
    .replace(/\s*\(桌面客户端\)\s*$/u, '')
    .trim();

const CHATGPT_EFFORT_OPTIONS: Array<{
  value: string;
  label: string;
  shortLabel: string;
}> = [
  { value: 'standard', label: '🧠 默认 (standard)', shortLabel: '🧠 standard' },
  { value: 'none', label: '🧠 直答 (无思考)', shortLabel: '🧠 none' },
  { value: 'low', label: '🧠 低 (low)', shortLabel: '🧠 low' },
  { value: 'medium', label: '🧠 中 (medium)', shortLabel: '🧠 medium' },
  { value: 'high', label: '🧠 高 (high)', shortLabel: '🧠 high' },
  { value: 'xhigh', label: '🧠 超高 (xhigh)', shortLabel: '🧠 xhigh' },
];

const STALL_PRESETS = [
  { value: 30, label: '停顿 30 秒 (测试)', shortLabel: '30秒(测)' },
  { value: 180, label: '停顿 3 分钟', shortLabel: '停顿 3m' },
  { value: 300, label: '停顿 5 分钟', shortLabel: '停顿 5m' },
];

const RETRY_PRESETS = [
  { value: 1, label: '重试 1 次', shortLabel: '1次' },
  { value: 2, label: '重试 2 次', shortLabel: '2次' },
  { value: 3, label: '重试 3 次', shortLabel: '3次' },
];

function isDesktopCarrier(carrier: string | undefined): boolean {
  return Boolean(carrier && carrier.trim().toLowerCase().startsWith('desktop:'));
}

function normalizeChatgptEffort(raw: string | undefined): string {
  const s = (raw || '').trim().toLowerCase();
  if (!s || s === 'inherit' || s === 'auto' || s === '标准') return 'standard';
  if (s === 'max' || s === '极高' || s === '最高' || s === '超高') return 'xhigh';
  if (s === '即时' || s === 'instant' || s === '未开启思考') return 'none';
  return s;
}

export function TaskComposer({
  isLaunchpad,
  isNarrow = false,
  sessionKey,
  card,
  infra,
  snapshot,
  paneCount,
  draft,
  textareaRef,
  onDraftChange,
  onTargetSelectionChange,
  onTaskCreated,
  onActionSettled,
  onToast,
}: TaskComposerProps) {
  const effectiveBindingKey = isLaunchpad ? '__new_task__' : sessionKey;
  const [, setTick] = useState(0);
  const [sending, setSending] = useState(false);
  const [modelMenuOpen, setModelMenuOpen] = useState(false);
  const [collapsedGroups, setCollapsedGroups] = useState<Record<PlatformId, boolean>>({
    chatgpt: false,
    gemini: false,
    claude: false,
  });
  const [liveHandoverOpen, setLiveHandoverOpen] = useState(false);

  const unlockTimerRef = useRef<number | null>(null);
  const modelAnchorRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    return () => {
      if (unlockTimerRef.current !== null) {
        window.clearTimeout(unlockTimerRef.current);
      }
    };
  }, []);

  // Close custom grouped model disclosure on outside pointerdown or Escape (`viewport-aware-dropdowns`)
  useEffect(() => {
    if (!modelMenuOpen) return;
    const onPointerDown = (e: PointerEvent) => {
      const anchor = modelAnchorRef.current;
      if (anchor && !anchor.contains(e.target as Node)) {
        setModelMenuOpen(false);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setModelMenuOpen(false);
      }
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [modelMenuOpen]);

  const arCfg = snapshot?.web_bridge?.auto_resend_config;
  const launchpadBinding = snapshot?.web_bridge?.session_bindings?.['__new_task__'];

  const rawEnabledPlatforms =
    infra.profiles?.EnabledPlatforms && infra.profiles.EnabledPlatforms.length > 0
      ? infra.profiles.EnabledPlatforms
      : ['chatgpt'];
  const enabledPlatSet = new Set<PlatformId>(
    rawEnabledPlatforms.map((p) => normalizePlatformId(p))
  );
  if (enabledPlatSet.size === 0) enabledPlatSet.add('chatgpt');
  if (!isLaunchpad && card?.Provider) {
    enabledPlatSet.add(normalizePlatformId(card.Provider));
  }
  const visiblePlatforms = ORDERED_PLATFORMS.filter((p) => enabledPlatSet.has(p));

  const fallbackNonDesktopCarrier =
    infra.browserProfiles?.find((b) => !isDesktopCarrier(b.Id))?.Id || 'Chrome:Default';

  const resolveServerConfig = (): ComposerConfigState => {
    if (!isLaunchpad && card) {
      const prov = normalizePlatformId(card.Provider);
      let carr =
        card.Carrier ||
        card.BrowserProfile ||
        infra.engineConfig?.DefaultBrowserProfile ||
        fallbackNonDesktopCarrier;
      if (prov !== 'chatgpt' && isDesktopCarrier(carr)) {
        carr = card.CarrierByProvider?.[prov] || fallbackNonDesktopCarrier;
      }
      return {
        targetMode: card.TargetMode === 'new_window' ? 'new_window' : 'follow_window',
        provider: prov,
        carrier: carr,
        targetModel: card.TargetModel || 'inherit',
        reasoningEffort: card.ReasoningEffort || 'inherit',
        autoResendEnabled:
          card.AutoResendEnabled ?? card.AutoWakeupEnabled ?? arCfg?.enabled ?? true,
        stallSeconds:
          Number(card.StallSeconds) > 0
            ? Number(card.StallSeconds)
            : arCfg?.stall_seconds || 180,
        maxRetries:
          Number(card.MaxRetries) > 0
            ? Number(card.MaxRetries)
            : arCfg?.max_retries || 1,
      };
    }

    let prov = normalizePlatformId(launchpadBinding?.provider || 'chatgpt');
    if (!enabledPlatSet.has(prov)) {
      prov = visiblePlatforms[0] || 'chatgpt';
    }
    let carr =
      launchpadBinding?.carrier ||
      launchpadBinding?.browser_profile ||
      arCfg?.default_browser_profile ||
      infra.engineConfig?.DefaultBrowserProfile ||
      fallbackNonDesktopCarrier;
    if (prov !== 'chatgpt' && isDesktopCarrier(carr)) {
      carr = fallbackNonDesktopCarrier;
    }

    return {
      targetMode: launchpadBinding?.target_mode === 'new_window' ? 'new_window' : 'follow_window',
      provider: prov,
      carrier: carr,
      targetModel: launchpadBinding?.target_model || arCfg?.default_target_model || 'inherit',
      reasoningEffort:
        launchpadBinding?.reasoning_effort || arCfg?.default_reasoning_effort || 'inherit',
      autoResendEnabled: launchpadBinding?.auto_resend_enabled ?? arCfg?.enabled ?? true,
      stallSeconds: Number(launchpadBinding?.stall_seconds || arCfg?.stall_seconds || 180),
      maxRetries: Number(launchpadBinding?.max_retries || arCfg?.max_retries || 1),
    };
  };

  const serverCfg = resolveServerConfig();
  const activeLock = optimisticLocks.get(effectiveBindingKey);
  const cfg: ComposerConfigState =
    activeLock && Date.now() < activeLock.until
      ? { ...serverCfg, ...activeLock.patch }
      : serverCfg;

  useEffect(() => {
    onTargetSelectionChange?.(cfg.provider, cfg.carrier);
  }, [cfg.provider, cfg.carrier, onTargetSelectionChange]);

  const commitConfigPatch = (patch: Partial<ComposerConfigState>) => {
    const prevPatch =
      activeLock && Date.now() < activeLock.until ? activeLock.patch : {};
    const mergedPatch = { ...prevPatch, ...patch };
    const nextCfg: ComposerConfigState = { ...serverCfg, ...mergedPatch };

    optimisticLocks.set(effectiveBindingKey, {
      until: Date.now() + OPTIMISTIC_LOCK_MS,
      patch: mergedPatch,
    });
    setTick((t) => t + 1);

    if (unlockTimerRef.current !== null) {
      window.clearTimeout(unlockTimerRef.current);
    }
    unlockTimerRef.current = window.setTimeout(() => {
      setTick((t) => t + 1);
    }, OPTIMISTIC_LOCK_MS + 40);

    void postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
      action: 'set_task_composer_config',
      session_key: effectiveBindingKey,
      target_mode: nextCfg.targetMode,
      provider: nextCfg.provider,
      carrier: nextCfg.carrier,
      browser_profile: nextCfg.carrier,
      target_model: nextCfg.targetModel,
      reasoning_effort: nextCfg.reasoningEffort,
      auto_resend_enabled: nextCfg.autoResendEnabled,
      stall_seconds: nextCfg.stallSeconds,
      max_retries: nextCfg.maxRetries,
    }).catch((err) => {
      onToast(`保存配置失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    });
  };

  // Connected providers set
  const connectedRaw =
    card?.ConnectedProviders ?? snapshot?.web_bridge?.connected_providers ?? [];
  const connectedSet = new Set<PlatformId>(
    connectedRaw.map((p) => normalizePlatformId(p))
  );
  if (infra.display?.Running && !infra.display?.IsFault) {
    connectedSet.add('chatgpt');
  }
  if (infra.publicTunnel?.Running) {
    for (const ep of infra.profiles?.EnabledPlatforms || []) {
      connectedSet.add(normalizePlatformId(ep));
    }
  }

  // Dynamic models only + cached last non-empty ChatGPT catalog (ZERO hardcoded models)
  const resolveChatgptModels = (): ModelCatalogItem[] => {
    const step1 = normalizeModelCatalogList(
      card?.AvailableModelsByProvider?.chatgpt ??
        (card && normalizePlatformId(card.Provider) === 'chatgpt'
          ? card.AvailableModels
          : undefined),
      'chatgpt'
    );
    const step2 =
      step1.length > 0
        ? step1
        : normalizeModelCatalogList(
            snapshot?.web_bridge?.available_models_by_provider?.chatgpt ??
              snapshot?.web_bridge?.AvailableModelsByProvider?.chatgpt,
            'chatgpt'
          );
    const step3 =
      step2.length > 0
        ? step2
        : normalizeModelCatalogList(
            snapshot?.web_bridge?.available_models ??
              snapshot?.web_bridge?.AvailableModels,
            'chatgpt'
          );

    if (step3.length > 0) {
      try {
        localStorage.setItem(CHATGPT_MODELS_CACHE_KEY, JSON.stringify(step3));
      } catch {
        // Ignore storage errors
      }
      return step3;
    }

    try {
      const rawCached = localStorage.getItem(CHATGPT_MODELS_CACHE_KEY);
      if (rawCached) {
        return normalizeModelCatalogList(JSON.parse(rawCached), 'chatgpt');
      }
    } catch {
      // Ignore invalid cache
    }
    return [];
  };

  const resolvePublicModels = (plat: 'gemini' | 'claude'): ModelCatalogItem[] => {
    const fromCard = normalizeModelCatalogList(
      card?.AvailableModelsByProvider?.[plat] ??
        (card && normalizePlatformId(card.Provider) === plat
          ? card.AvailableModels
          : undefined),
      plat
    );
    if (fromCard.length > 0) return fromCard;
    return normalizeModelCatalogList(
      snapshot?.web_bridge?.available_models_by_provider?.[plat] ??
        snapshot?.web_bridge?.AvailableModelsByProvider?.[plat],
      plat
    );
  };

  const modelsByPlatform: Record<PlatformId, ModelCatalogItem[]> = {
    chatgpt: resolveChatgptModels(),
    gemini: resolvePublicModels('gemini'),
    claude: resolvePublicModels('claude'),
  };

  const selectedPlatform: PlatformId = cfg.provider;
  const rawTargetModel = (cfg.targetModel || 'inherit').trim();
  const activeDynamicModel =
    rawTargetModel && rawTargetModel !== 'inherit'
      ? modelsByPlatform[selectedPlatform].find((m) => m.id === rawTargetModel)
      : undefined;
  const selectedModel: string = activeDynamicModel ? activeDynamicModel.id : 'inherit';
  const activeModelLabel: string =
    selectedModel === 'inherit'
      ? '默认'
      : activeDynamicModel?.label || activeDynamicModel?.id || selectedModel;

  const modelTriggerDisplay = `${PLATFORM_LABELS[selectedPlatform]} · ${activeModelLabel}`;
  const modelTriggerTooltip =
    selectedModel === 'inherit'
      ? card &&
        normalizePlatformId(card.Provider) === selectedPlatform &&
        card.WebCurrentModel
        ? `${PLATFORM_LABELS[selectedPlatform]} · 默认（跟随网页当前模型：${card.WebCurrentModel}）`
        : `${PLATFORM_LABELS[selectedPlatform]} · 默认（跟随网页当前模型）`
      : `${PLATFORM_LABELS[selectedPlatform]} · ${activeModelLabel}`;

  const handleSelectModel = (nextProv: PlatformId, nextModelId: string, labelForToast: string) => {
    const patch: Partial<ComposerConfigState> = {
      provider: nextProv,
      targetModel: nextModelId,
    };

    if (nextProv !== 'chatgpt') {
      patch.reasoningEffort = 'inherit';
      if (isDesktopCarrier(cfg.carrier)) {
        const savedForPlat = card?.CarrierByProvider?.[nextProv];
        patch.carrier =
          savedForPlat && !isDesktopCarrier(savedForPlat)
            ? savedForPlat
            : fallbackNonDesktopCarrier;
      }
    } else if (nextModelId !== 'inherit' && /-instant$/i.test(nextModelId)) {
      patch.reasoningEffort = 'none';
    }

    setModelMenuOpen(false);
    commitConfigPatch(patch);
    onToast(`✓ 本任务模型已设为：${labelForToast}`, 'success');
  };

  // Bidirectional GPT Instant <-> Thinking linkage across live dynamic catalog
  const handleSelectEffort = (rawEffortVal: string) => {
    const nextEffort = rawEffortVal;
    const patch: Partial<ComposerConfigState> = {
      reasoningEffort: nextEffort === 'standard' ? 'standard' : nextEffort,
    };

    const effBaseModel = (
      selectedModel !== 'inherit' ? selectedModel : card?.WebCurrentModel || ''
    ).trim();

    if (effBaseModel && modelsByPlatform.chatgpt.length > 0) {
      if (
        ['low', 'medium', 'high', 'xhigh', 'standard'].includes(nextEffort) &&
        /-instant$/i.test(effBaseModel)
      ) {
        const candidateThinking = effBaseModel.replace(/-instant$/i, '-thinking');
        const matched = modelsByPlatform.chatgpt.find(
          (m) => m.id.toLowerCase() === candidateThinking.toLowerCase()
        );
        if (matched) patch.targetModel = matched.id;
      } else if (nextEffort === 'none' && /-thinking$/i.test(effBaseModel)) {
        const candidateInstant = effBaseModel.replace(/-thinking$/i, '-instant');
        const matched = modelsByPlatform.chatgpt.find(
          (m) => m.id.toLowerCase() === candidateInstant.toLowerCase()
        );
        if (matched) patch.targetModel = matched.id;
      }
    }

    commitConfigPatch(patch);
  };

  // Carrier options (filter Desktop:ChatGPT out whenever provider is gemini or claude!)
  const rawCarriers = [
    ...(infra.browserProfiles || []).map((b) => ({
      Id: b.Id,
      Label: b.Label || formatShortCarrier(b.Id),
    })),
  ];
  if (rawCarriers.length === 0) {
    rawCarriers.push({ Id: 'Chrome:Default', Label: 'Chrome 默认' });
  }
  if (
    cfg.provider === 'chatgpt' &&
    !rawCarriers.some((c) => c.Id.toLowerCase() === 'desktop:chatgpt')
  ) {
    rawCarriers.unshift({ Id: 'Desktop:ChatGPT', Label: 'ChatGPT 桌面端' });
  }
  const carrierOptions = rawCarriers.filter(
    (c) => cfg.provider === 'chatgpt' || !isDesktopCarrier(c.Id)
  );
  if (
    cfg.carrier &&
    (cfg.provider === 'chatgpt' || !isDesktopCarrier(cfg.carrier)) &&
    !carrierOptions.some((c) => c.Id.toLowerCase() === cfg.carrier.toLowerCase())
  ) {
    carrierOptions.push({ Id: cfg.carrier, Label: formatShortCarrier(cfg.carrier) });
  }

  // 4-State Send Button Matrix (`#L5593-L5645`)
  const hasText = draft.trim().length > 0;
  let sendStateClass = 'state-blue';
  let sendLabel = '🚀 在网页发起新任务 ↗';
  if (isLaunchpad) {
    sendStateClass = 'state-blue';
    sendLabel = '🚀 在网页发起新任务 ↗';
  } else if (cfg.targetMode === 'new_window') {
    sendStateClass = 'state-blue';
    sendLabel = hasText ? '🚀 新建交接并发送 ↗' : '🚀 新建网页交接 ↗';
  } else if (hasText) {
    sendStateClass = 'state-dark';
    sendLabel = '⚡ 发送消息 ↗';
  } else {
    sendStateClass = 'state-amber';
    sendLabel = '⚡ 发送“请继续” ↗';
  }

  const executeSend = async (opts?: {
    deferUntilStopped?: boolean;
    stopAndRetire?: boolean;
  }) => {
    if (sending) return;
    const trimmed = draft.trim();
    if (isLaunchpad && !trimmed) {
      onToast('请先输入新任务目标或首句指令', 'warning');
      return;
    }

    const deferUntilStopped = Boolean(opts?.deferUntilStopped);
    const stopAndRetire = Boolean(opts?.stopAndRetire);

    setSending(true);
    try {
      if (isLaunchpad) {
        const res = await postStudioAction<{
          ok: boolean;
          task_id?: string;
          session_key?: string;
          prompt?: string;
          Prompt?: string;
          message?: { prompt?: string };
        }>(infra.shieldBaseUrl, infra.studioToken, {
          action: 'create_task',
          user_text: trimmed,
          provider: cfg.provider,
          browser_profile: cfg.carrier,
          carrier: cfg.carrier,
          target_model: cfg.targetModel,
          reasoning_effort: cfg.reasoningEffort,
          open_browser: true,
          is_single_pane_replace: paneCount === 1,
        });

        const copiedPrompt = res?.message?.prompt || res?.prompt || res?.Prompt;
        if (copiedPrompt) {
          void hostRpc('copy_clipboard', { text: copiedPrompt });
        }

        onDraftChange('');
        const mintedKey = res.task_id || res.session_key || '';
        onToast('✓ 已立项并下发首条指令', 'success');
        if (mintedKey && mintedKey !== '__new_task__') {
          onTaskCreated(mintedKey);
        } else {
          onActionSettled();
        }
        return;
      }

      const mode =
        cfg.targetMode === 'new_window'
          ? 'new_window_handover'
          : trimmed
            ? 'custom_message'
            : 'in_place_wakeup';

      const res = await postStudioAction<{
        ok: boolean;
        prompt?: string;
        Prompt?: string;
        handover_url?: string;
        message?: { prompt?: string };
      }>(infra.shieldBaseUrl, infra.studioToken, {
        action: 'enqueue_message',
        session_key: sessionKey,
        wfr_id: card?.WfrId || sessionKey,
        target_title: card?.ShortTitle || card?.Title || '',
        mode,
        user_text: trimmed,
        command_count: card?.CommandCount || 0,
        progress_percent: card?.ProgressPercent || 0,
        provider: cfg.provider,
        browser_profile: cfg.carrier,
        carrier: cfg.carrier,
        target_model: cfg.targetModel,
        reasoning_effort: cfg.reasoningEffort,
        defer_until_stopped: deferUntilStopped,
        stop_and_retire: stopAndRetire,
        open_browser: mode === 'new_window_handover' && !deferUntilStopped,
        is_single_pane_replace: paneCount <= 1,
      });

      const copiedPrompt = res?.message?.prompt || res?.prompt || res?.Prompt;
      if (copiedPrompt) {
        void hostRpc('copy_clipboard', { text: copiedPrompt });
      }

      if (trimmed) {
        onDraftChange('');
      }

      if (mode === 'new_window_handover' && deferUntilStopped) {
        onToast('⏳ 已排队：原网页本轮停稳后将自动开启新窗接力', 'info');
      } else if (mode === 'new_window_handover') {
        onToast('🚀 已发起新窗口接力交接（交接单已复制）', 'success');
      } else if (mode === 'in_place_wakeup') {
        onToast('⚡ 已发送“请继续”唤醒指令', 'success');
      } else {
        onToast('✓ 消息已加入网页派发队列', 'success');
      }
      onActionSettled();
    } catch (err) {
      onToast(`派发失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setSending(false);
    }
  };

  const handleSendClick = () => {
    if (sending) return;
    if (isLaunchpad && !draft.trim()) {
      onToast('请先输入新任务目标或首句指令', 'warning');
      return;
    }

    const hasPendingHandover = Boolean(
      card?.PendingQueue?.some((q) => q.mode === 'new_window_handover')
    );

    if (
      !isLaunchpad &&
      cfg.targetMode === 'new_window' &&
      card?.VitalState === 'LIVE' &&
      !hasPendingHandover
    ) {
      setLiveHandoverOpen(true);
      return;
    }

    void executeSend();
  };

  const handleLiveHandoverDecision = (decision: LiveHandoverDecision) => {
    setLiveHandoverOpen(false);
    if (decision === 'cancel') {
      onToast('已取消新窗口交接（原网页继续运行，草稿已保留）', 'info');
      return;
    }
    if (decision === 'stop_and_retire') {
      void executeSend({ deferUntilStopped: false, stopAndRetire: true });
      return;
    }
    void executeSend({ deferUntilStopped: true, stopAndRetire: false });
  };

  const currentEffortValue = normalizeChatgptEffort(cfg.reasoningEffort);
  const effortLockedToWeb = cfg.provider === 'gemini' || cfg.provider === 'claude';

  const placeholderText = isLaunchpad
    ? '输入新任务目标或问题（按 Enter 立项并下发，Shift+Enter 换行） ...'
    : cfg.targetMode === 'new_window'
      ? '输入追加指令（留空点击右侧按钮直接携带本任务进度账本开启新窗口交接） ...'
      : `输入发往当前 ${formatProviderBadge(cfg.provider)} 网页的消息（留空点击右侧按钮直接发 “请继续” ） ...`;

  return (
    <div className={`composer-dock ${isLaunchpad ? 'zero-task' : ''}`.trim()}>
      <div className="composer-pod">
        {/* Top Area: Borderless Serif Textarea (`Message #4 item 1`) */}
        <textarea
          ref={(el) => {
            if (textareaRef) textareaRef.current = el;
          }}
          className="composer-textarea"
          placeholder={placeholderText}
          value={draft}
          onInput={(e) => onDraftChange((e.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              // Mandatory IME composition guard
              if (e.isComposing || (e as any).keyCode === 229) return;
              e.preventDefault();
              handleSendClick();
            }
          }}
        />

        {/* Middle Row: [跟随原窗口 | 新建网页交接] + [🤖 模型 ▾] + [🧠 思考强度 ▾] + [💻 宿主载体 ▾] */}
        <div className="composer-middle-row composer-toolbar">
          {!isLaunchpad && (
            <div className="segmented-toggle" role="group" aria-label="派发窗口模式">
              <button
                type="button"
                className={`seg-btn ${cfg.targetMode === 'follow_window' ? 'active' : ''}`}
                title="发往当前任务绑定的原网页窗口；留空发送“请继续”，输入文字则原样发送"
                onClick={() => commitConfigPatch({ targetMode: 'follow_window' })}
              >
                {isNarrow ? '原窗' : '跟随原窗口'}
              </button>
              <button
                type="button"
                className={`seg-btn ${cfg.targetMode === 'new_window' ? 'active handover' : ''}`}
                title="在选定载体中开启新窗口，并自动注入本任务的完整进度交接单"
                onClick={() => commitConfigPatch({ targetMode: 'new_window' })}
              >
                {isNarrow ? '新窗交接' : '新建网页交接'}
              </button>
            </div>
          )}

          {/* Custom Upward-Opening Grouped Model Disclosure (`viewport-aware-dropdowns`: button[aria-expanded] + div) */}
          <div className="composer-model-anchor" ref={modelAnchorRef}>
            <button
              type="button"
              className="composer-model-trigger"
              style={{ maxWidth: isNarrow ? '168px' : '228px' }}
              aria-expanded={modelMenuOpen}
              title={modelTriggerTooltip}
              onClick={() => setModelMenuOpen((prev) => !prev)}
            >
              <span className="truncate-1">{`🤖 ${modelTriggerDisplay}`}</span>
              <span aria-hidden="true" style={{ fontSize: '10px', opacity: 0.75 }}>
                ▾
              </span>
            </button>

            {modelMenuOpen && (
              <div className="composer-model-panel">
                {visiblePlatforms.map((plat) => {
                  const isFolded = Boolean(collapsedGroups[plat]);
                  const isOnline = connectedSet.has(plat);
                  const platModels = modelsByPlatform[plat];
                  const platTitle = PLATFORM_LABELS[plat];
                  const isDefaultSelected =
                    selectedPlatform === plat && selectedModel === 'inherit';

                  return (
                    <div key={plat}>
                      <button
                        type="button"
                        className="model-group-header-btn"
                        aria-expanded={!isFolded}
                        onClick={(e) => {
                          e.stopPropagation();
                          setCollapsedGroups((prev) => ({
                            ...prev,
                            [plat]: !prev[plat],
                          }));
                        }}
                      >
                        <span>{`${isFolded ? '▸' : '▾'} ${platTitle}`}</span>
                        {!isOnline && (
                          <span className="model-group-offline-tag">(未连接)</span>
                        )}
                      </button>

                      {!isFolded && (
                        <>
                          <button
                            type="button"
                            className={`model-option-btn ${isDefaultSelected ? 'selected' : ''}`}
                            onClick={() =>
                              handleSelectModel(
                                plat,
                                'inherit',
                                `${platTitle} · 默认`
                              )
                            }
                          >
                            <span className="truncate-1">默认 (跟随网页)</span>
                            {isDefaultSelected && <span aria-hidden="true">✓</span>}
                          </button>

                          {platModels.map((m) => {
                            const isSelected =
                              selectedPlatform === plat && selectedModel === m.id;
                            const mLabel = m.label || m.id;
                            return (
                              <button
                                key={`${plat}_${m.id}`}
                                type="button"
                                className={`model-option-btn ${isSelected ? 'selected' : ''}`}
                                onClick={() =>
                                  handleSelectModel(
                                    plat,
                                    m.id,
                                    `${platTitle} · ${mLabel}`
                                  )
                                }
                              >
                                <span className="truncate-1">{mLabel}</span>
                                {isSelected && <span aria-hidden="true">✓</span>}
                              </button>
                            );
                          })}
                        </>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Reasoning Effort Select (`#L6770-L6845`) */}
          {effortLockedToWeb ? (
            <select
              className="composer-pill-select"
              style={{ maxWidth: isNarrow ? '136px' : '168px', paddingRight: '24px' }}
              aria-label="思考强度"
              disabled
              value="inherit"
            >
              <option value="inherit">🧠 跟随网页设置</option>
            </select>
          ) : (
            <select
              className="composer-pill-select"
              style={{ maxWidth: isNarrow ? '136px' : '168px', paddingRight: '24px' }}
              aria-label="思考强度"
              title="选择模型思考强度（Instant 与 Thinking 模型支持自动双向联动）"
              value={currentEffortValue}
              onChange={(e) =>
                handleSelectEffort((e.currentTarget as HTMLSelectElement).value)
              }
            >
              {!CHATGPT_EFFORT_OPTIONS.some((o) => o.value === currentEffortValue) && (
                <option value={currentEffortValue}>{`🧠 ${currentEffortValue}`}</option>
              )}
              {CHATGPT_EFFORT_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>
                  {isNarrow ? opt.shortLabel : opt.label}
                </option>
              ))}
            </select>
          )}

          {/* Host Carrier Select */}
          <select
            className="composer-pill-select"
            style={{ maxWidth: isNarrow ? '180px' : '236px', paddingRight: '24px' }}
            aria-label="宿主载体"
            title="按任务独立绑定目标浏览器或 ChatGPT 桌面端"
            value={cfg.carrier}
            onChange={(e) =>
              commitConfigPatch({
                carrier: (e.currentTarget as HTMLSelectElement).value,
              })
            }
          >
            {carrierOptions.map((c) => {
              const isDesk =
                c.Id.trim().toLowerCase() === 'desktop:chatgpt' ||
                isDesktopCarrier(c.Id);
              const icon = isDesk ? '💻' : '🌐';
              const cleanLabel =
                c.Id.trim().toLowerCase() === 'desktop:chatgpt'
                  ? 'ChatGPT 桌面端'
                  : cleanCarrierLabel(c.Label) || formatShortCarrier(c.Id);
              return (
                <option key={c.Id} value={c.Id}>
                  {`${icon} ${cleanLabel}`}
                </option>
              );
            })}
          </select>
        </div>

        {/* Bottom Row: Left Auto-Resend Guard + Right 4-State Animated Send CTA */}
        <div className="composer-bottom-row composer-toolbar">
          <div className="auto-resend-row">
            <label
              className="composer-checkbox-label"
              title="按任务独立开启或关闭停顿自动重发守护"
            >
              <input
                type="checkbox"
                checked={cfg.autoResendEnabled}
                onChange={(e) =>
                  commitConfigPatch({
                    autoResendEnabled: (e.currentTarget as HTMLInputElement).checked,
                  })
                }
              />
              <span>{isNarrow ? '重发' : '自动重发'}</span>
            </label>

            <select
              className="composer-mini-select"
              aria-label="停顿阈值"
              title="选择停顿多久后自动触发重发（默认停顿 3 分钟）"
              value={String(cfg.stallSeconds)}
              disabled={!cfg.autoResendEnabled}
              onChange={(e) =>
                commitConfigPatch({
                  stallSeconds:
                    Number((e.currentTarget as HTMLSelectElement).value) || 180,
                })
              }
            >
              {!STALL_PRESETS.some((p) => p.value === cfg.stallSeconds) && (
                <option value={String(cfg.stallSeconds)}>
                  {cfg.stallSeconds < 60
                    ? `停顿 ${cfg.stallSeconds} 秒`
                    : `停顿 ${Math.round(cfg.stallSeconds / 60)} 分钟`}
                </option>
              )}
              {STALL_PRESETS.map((p) => (
                <option key={p.value} value={String(p.value)}>
                  {isNarrow ? p.shortLabel : p.label}
                </option>
              ))}
            </select>

            <select
              className="composer-mini-select"
              aria-label="最大自动重试次数"
              title="选择原窗口连续唤醒重试几次无果后自动切换新窗口交接（默认重试 1 次）"
              value={String(cfg.maxRetries)}
              disabled={!cfg.autoResendEnabled}
              onChange={(e) =>
                commitConfigPatch({
                  maxRetries: Number((e.currentTarget as HTMLSelectElement).value) || 1,
                })
              }
            >
              {!RETRY_PRESETS.some((r) => r.value === cfg.maxRetries) && (
                <option value={String(cfg.maxRetries)}>
                  {isNarrow ? `${cfg.maxRetries}次` : `重试 ${cfg.maxRetries} 次`}
                </option>
              )}
              {RETRY_PRESETS.map((r) => (
                <option key={r.value} value={String(r.value)}>
                  {isNarrow ? r.shortLabel : r.label}
                </option>
              ))}
            </select>
          </div>

          <button
            type="button"
            className={`composer-send-cta ${sendStateClass}`}
            disabled={sending || (isLaunchpad && !hasText)}
            onClick={handleSendClick}
          >
            <span>{sending ? '派发中…' : sendLabel}</span>
          </button>
        </div>
      </div>

      {/* Live Handover 3-Choice Safety Dialog (`#L4355-L4480`) */}
      <LiveHandoverConfirmDialog
        open={liveHandoverOpen}
        providerLabel={formatProviderBadge(cfg.provider)}
        onDecision={handleLiveHandoverDecision}
      />
    </div>
  );
}
