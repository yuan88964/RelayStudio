import { useEffect, useRef, useState } from 'preact/hooks';
import type {
  HostInfraBundle,
  PlatformId,
  PublicTunnelItem,
  SafeConnectionProfile,
} from '../types/contracts';
import {
  extractInfraBundle,
  getEffectivePublicTunnels,
  hostRpc,
  resolveBoundPublicTunnel,
} from '../services/hostBridge';
import { AnchoredPopover } from './AnchoredPopover';

export type TunnelHubTab = 'chatgpt' | 'gemini' | 'claude' | 'add';

export interface TunnelHubPopoverProps {
  open: boolean;
  activeTab: TunnelHubTab;
  anchorEl: HTMLElement | null;
  infra: HostInfraBundle;
  discardSignal?: number;
  onSelectTab: (tab: TunnelHubTab) => void;
  onManagePublicTunnels: (highlightTunnelId?: string) => void;
  onClose: () => void;
  onInfraUpdated: (nextInfra: HostInfraBundle) => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

const ORDERED_PLATFORMS: PlatformId[] = ['chatgpt', 'gemini', 'claude'];

const PLATFORM_LABELS: Record<PlatformId, string> = {
  chatgpt: 'ChatGPT',
  gemini: 'Gemini',
  claude: 'Claude',
};

const PICKER_PLATFORMS: Array<{
  id: PlatformId;
  title: string;
  desc: string;
  label: string;
}> = [
  {
    id: 'chatgpt',
    label: 'ChatGPT',
    title: 'ChatGPT · OpenAI 反向隧道',
    desc: '连接本地 :8789 OpenAI 反向隧道守护进程，支持多账号 DPAPI 凭据秒级切换',
  },
  {
    id: 'gemini',
    label: 'Gemini',
    title: 'Gemini · 公网 HTTPS MCP',
    desc: '复用「设置 → 隧道与连接」中的公网隧道，暴露安全 HTTPS /mcp 端点',
  },
  {
    id: 'claude',
    label: 'Claude',
    title: 'Claude · 公网 HTTPS MCP',
    desc: '复用「设置 → 隧道与连接」中的公网隧道，供 Claude Connectors 接入并完成 OAuth 鉴权',
  },
];

// Module-level applied running profile & dirty edit tracking for ChatGPT across popover open/close cycles
let appliedChatgptProfileId = '';
let persistedDirtyRunningIds: Record<string, boolean> = {};

function canonicalPlat(raw: string | undefined): PlatformId {
  const s = (raw || 'chatgpt').trim().toLowerCase();
  if (s === 'gemini' || s === 'gemini_api') return 'gemini';
  if (s === 'claude' || s === 'claude_api') return 'claude';
  return 'chatgpt';
}

function shortenChatgptTunnelId(val: string): string {
  const trimmed = (val || '').trim();
  if (!trimmed) return '未配置';
  return trimmed.length > 22 ? `${trimmed.slice(0, 13)}…${trimmed.slice(-6)}` : trimmed;
}

function truncateMiddle(rawUrl: string, maxLen = 30): string {
  const clean = (rawUrl || '').trim().replace(/^https?:\/\//i, '');
  if (!clean) return '';
  if (clean.length <= maxLen) return clean;
  const head = Math.ceil((maxLen - 1) * 0.62);
  const tail = Math.max(6, maxLen - 1 - head);
  return `${clean.slice(0, head)}…${clean.slice(-tail)}`;
}

export function TunnelHubPopover({
  open,
  activeTab,
  anchorEl,
  infra,
  discardSignal,
  onSelectTab,
  onManagePublicTunnels,
  onClose,
  onInfraUpdated,
  onToast,
}: TunnelHubPopoverProps) {
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const [dirtyRunningIds, setDirtyRunningIds] = useState<Record<string, boolean>>(
    () => ({ ...persistedDirtyRunningIds })
  );

  // ChatGPT inline accordion form fields
  const [formName, setFormName] = useState<string>('');
  const [formTunnelId, setFormTunnelId] = useState<string>('');
  const [formApiKey, setFormApiKey] = useState<string>('');
  const [formApiBaseUrl, setFormApiBaseUrl] = useState<string>('https://api.openai.com/v1');

  // Decoupled local caller selection for Gemini / Claude public tunnels
  const publicTunnels = getEffectivePublicTunnels(infra);
  const geminiBound = resolveBoundPublicTunnel(infra, 'gemini');
  const claudeBound = resolveBoundPublicTunnel(infra, 'claude');

  const [pickedPubIdByPlat, setPickedPubIdByPlat] = useState<Record<'gemini' | 'claude', string>>(
    () => ({
      gemini: geminiBound.boundId,
      claude: claudeBound.boundId,
    })
  );

  const wasOpenRef = useRef<boolean>(open);
  const prevBoundRef = useRef<Record<'gemini' | 'claude', string>>({
    gemini: geminiBound.boundId,
    claude: claudeBound.boundId,
  });

  // Per-profile revealed secret & transient copy checkmark badges
  const [revealedSecrets, setRevealedSecrets] = useState<Record<string, string>>({});
  const [copiedFlags, setCopiedFlags] = useState<Record<string, boolean>>({});
  const copyTimersRef = useRef<Record<string, number>>({});
  const prevDiscardRef = useRef<number | undefined>(discardSignal);
  const prevTabRef = useRef<TunnelHubTab>(activeTab);

  // Sync local `pickedPubIdByPlat` to `boundId` when opening or when `boundId` changes externally
  useEffect(() => {
    const justOpened = open && !wasOpenRef.current;
    wasOpenRef.current = open;

    const geminiChanged = prevBoundRef.current.gemini !== geminiBound.boundId;
    const claudeChanged = prevBoundRef.current.claude !== claudeBound.boundId;
    prevBoundRef.current = {
      gemini: geminiBound.boundId,
      claude: claudeBound.boundId,
    };

    setPickedPubIdByPlat((prev) => {
      const hasGeminiPicked = publicTunnels.some((t) => t.Id === prev.gemini);
      const hasClaudePicked = publicTunnels.some((t) => t.Id === prev.claude);

      const nextGemini =
        justOpened || geminiChanged || !hasGeminiPicked
          ? geminiBound.boundId
          : prev.gemini;
      const nextClaude =
        justOpened || claudeChanged || !hasClaudePicked
          ? claudeBound.boundId
          : prev.claude;

      if (nextGemini === prev.gemini && nextClaude === prev.claude) {
        return prev;
      }
      return { gemini: nextGemini, claude: nextClaude };
    });
  }, [open, geminiBound.boundId, claudeBound.boundId, publicTunnels]);

  const updateDirtyRunningIds = (
    updater: (prev: Record<string, boolean>) => Record<string, boolean>
  ) => {
    setDirtyRunningIds((prev) => {
      const next = updater(prev);
      persistedDirtyRunningIds = next;
      return next;
    });
  };

  const markCopied = (flagKey: string) => {
    if (copyTimersRef.current[flagKey]) {
      window.clearTimeout(copyTimersRef.current[flagKey]);
    }
    setCopiedFlags((prev) => ({ ...prev, [flagKey]: true }));
    copyTimersRef.current[flagKey] = window.setTimeout(() => {
      setCopiedFlags((prev) => {
        const next = { ...prev };
        delete next[flagKey];
        return next;
      });
      delete copyTimersRef.current[flagKey];
    }, 1800);
  };

  useEffect(() => {
    return () => {
      Object.values(copyTimersRef.current).forEach((tid) => window.clearTimeout(tid));
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    };
  }, []);

  const resetFormState = () => {
    setExpandedId(null);
    setConfirmDeleteId(null);
    setFormName('');
    setFormTunnelId('');
    setFormApiKey('');
    setFormApiBaseUrl('https://api.openai.com/v1');
  };

  // Reset inline edits when popover closes or host broadcasts discardSignal
  useEffect(() => {
    if (!open) {
      resetFormState();
      setRevealedSecrets({});
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    }
  }, [open]);

  useEffect(() => {
    if (discardSignal !== prevDiscardRef.current) {
      prevDiscardRef.current = discardSignal;
      resetFormState();
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    }
  }, [discardSignal]);

  // Collapse inline form cleanly when switching segments
  useEffect(() => {
    if (prevTabRef.current !== activeTab) {
      prevTabRef.current = activeTab;
      resetFormState();
    }
  }, [activeTab]);

  const allProfiles = infra.profiles?.Profiles || [];
  const activeByPlat = infra.profiles?.ActiveProfileByPlatform || {};
  const display = infra.display;

  // Sync module-level applied ChatGPT profile tracking against live tunnel running state
  const chatgptRunning = Boolean(display?.Running);
  if (!chatgptRunning) {
    appliedChatgptProfileId = '';
  } else if (display?.RunningProfileId) {
    appliedChatgptProfileId = display.RunningProfileId;
  } else if (!appliedChatgptProfileId) {
    const cProfs = allProfiles.filter((p) => canonicalPlat(p.Platform) === 'chatgpt');
    appliedChatgptProfileId =
      activeByPlat.chatgpt ||
      infra.profiles?.ActiveProfileId ||
      cProfs.find((p) => p.IsActive)?.Id ||
      cProfs[0]?.Id ||
      '';
  }

  useEffect(() => {
    if (!chatgptRunning && Object.keys(persistedDirtyRunningIds).length > 0) {
      updateDirtyRunningIds(() => ({}));
    }
  }, [chatgptRunning]);

  const isChatGpt = activeTab === 'chatgpt';
  const isPubCaller = activeTab === 'gemini' || activeTab === 'claude';

  const chatgptProfiles = allProfiles.filter((p) => canonicalPlat(p.Platform) === 'chatgpt');

  const selectedChatgptProfileId =
    activeByPlat.chatgpt ||
    infra.profiles?.ActiveProfileId ||
    chatgptProfiles.find((p) => p.IsActive)?.Id ||
    chatgptProfiles[0]?.Id ||
    '';

  const runningChatgptProfileId = !chatgptRunning
    ? ''
    : display?.RunningProfileId || appliedChatgptProfileId || infra.profiles?.ActiveProfileId || '';

  const editingExisting =
    isChatGpt && expandedId && expandedId !== '__new__'
      ? chatgptProfiles.find((p) => p.Id === expandedId) || null
      : null;

  // Compute unsaved edits dirty flag for ChatGPT inline form & sync to host guard
  const isDirty = (() => {
    if (!open || !isChatGpt || !expandedId) return false;
    if (expandedId === '__new__') {
      return formTunnelId.trim().length > 0 || formApiKey.trim().length > 0;
    }
    if (!editingExisting) return false;
    const baseName = (editingExisting.Name || '').trim();
    const baseTid = (editingExisting.TunnelId || '').trim();
    const baseApiUrl = (
      editingExisting.ApiBaseUrl ||
      editingExisting.BaseUrl ||
      'https://api.openai.com/v1'
    ).trim();

    if (formName.trim() !== baseName) return true;
    if (formApiKey.trim().length > 0) return true;
    if (formTunnelId.trim() !== baseTid) return true;
    if ((formApiBaseUrl.trim() || 'https://api.openai.com/v1') !== baseApiUrl) return true;
    return false;
  })();

  useEffect(() => {
    void hostRpc('set_unsaved_edits', { dirty: Boolean(open && isDirty) }).catch(() => {});
  }, [open, isDirty]);

  const syncInfraFromRpcResult = async (res: any): Promise<HostInfraBundle | null> => {
    const maybeInfra = extractInfraBundle(res);
    if (maybeInfra) {
      onInfraUpdated(maybeInfra);
      return maybeInfra;
    }
    const fresh = await hostRpc<any>('get_infra_bundle');
    const freshBundle = extractInfraBundle(fresh);
    if (freshBundle) {
      onInfraUpdated(freshBundle);
      return freshBundle;
    }
    return null;
  };

  // ---------------- ChatGPT Private Tunnel Handlers (100% Preserved) ----------------

  const openInlineEdit = (p: SafeConnectionProfile) => {
    if (expandedId === p.Id) {
      resetFormState();
      return;
    }
    setConfirmDeleteId(null);
    setExpandedId(p.Id);
    setFormName(p.Name || '');
    setFormTunnelId(p.TunnelId || '');
    setFormApiKey('');
    setFormApiBaseUrl(p.ApiBaseUrl || p.BaseUrl || 'https://api.openai.com/v1');
  };

  const openNewProfileForm = () => {
    if (expandedId === '__new__') {
      resetFormState();
      return;
    }
    const nextIdx = chatgptProfiles.length + 1;
    setConfirmDeleteId(null);
    setExpandedId('__new__');
    setFormName(`隧道配置 #${nextIdx}`);
    setFormTunnelId('');
    setFormApiKey('');
    setFormApiBaseUrl('https://api.openai.com/v1');
  };

  const handleSelectChatgptCard = async (p: SafeConnectionProfile) => {
    if (busyAction || !isChatGpt) return;
    if (p.Id === selectedChatgptProfileId) return;
    setBusyAction(`sel_${p.Id}`);
    try {
      const res = await hostRpc('profile_select', {
        profileId: p.Id,
        ProfileId: p.Id,
        id: p.Id,
        platform: 'chatgpt',
        Platform: 'chatgpt',
        reconnect: false,
        Reconnect: false,
      });
      await syncInfraFromRpcResult(res);
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const handleSaveInlineProfile = async (e: Event) => {
    e.preventDefault();
    if (!isChatGpt || busyAction) return;

    const isCreating = expandedId === '__new__';
    const targetProf = isCreating ? null : editingExisting;

    if (!formTunnelId.trim()) {
      onToast('请填写隧道编号 (tunnel_...) 或连接链接', 'warning');
      return;
    }
    if (!formApiKey.trim() && !targetProf?.HasKey) {
      onToast('首次保存配置请粘贴 OpenAI API Key', 'warning');
      return;
    }

    const cleanName = formName.trim() || '主号配置';

    setBusyAction('profile_save');
    try {
      const res = await hostRpc('profile_save', {
        profileId: isCreating ? '' : targetProf?.Id || '',
        ProfileId: isCreating ? '' : targetProf?.Id || '',
        name: cleanName,
        Name: cleanName,
        platform: 'chatgpt',
        Platform: 'chatgpt',
        kind: 'tunnel',
        Kind: 'tunnel',
        tunnelId: formTunnelId.trim(),
        TunnelId: formTunnelId.trim(),
        baseUrl: formApiBaseUrl.trim() || 'https://api.openai.com/v1',
        BaseUrl: formApiBaseUrl.trim() || 'https://api.openai.com/v1',
        apiBaseUrl: formApiBaseUrl.trim() || 'https://api.openai.com/v1',
        ApiBaseUrl: formApiBaseUrl.trim() || 'https://api.openai.com/v1',
        apiKey: formApiKey.trim(),
        ApiKey: formApiKey.trim(),
        enabled: true,
        Enabled: true,
        setActive: true,
        SetActive: true,
        connectNow: false,
        ConnectNow: false,
      });

      const nextInfra = await syncInfraFromRpcResult(res);
      const savedId =
        targetProf?.Id ||
        nextInfra?.profiles?.ActiveProfileByPlatform?.chatgpt ||
        nextInfra?.profiles?.ActiveProfileId ||
        '';

      if (savedId) {
        setRevealedSecrets((prev) => {
          const next = { ...prev };
          delete next[savedId];
          return next;
        });
        if (runningChatgptProfileId && savedId === runningChatgptProfileId) {
          updateDirtyRunningIds((prev) => ({ ...prev, [savedId]: true }));
        }
      }

      resetFormState();
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
      onToast(
        chatgptRunning
          ? '已保存配置（点击右下角连接生效）'
          : '已保存配置',
        'success'
      );
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const handleConnectChatgpt = async () => {
    if (busyAction || !isChatGpt) return;
    if (!selectedChatgptProfileId) {
      onToast('请先新增并保存一条隧道配置', 'warning');
      return;
    }

    setBusyAction('connect_tunnel');
    try {
      await hostRpc('profile_select', {
        profileId: selectedChatgptProfileId,
        ProfileId: selectedChatgptProfileId,
        id: selectedChatgptProfileId,
        platform: 'chatgpt',
        Platform: 'chatgpt',
        reconnect: false,
        Reconnect: false,
      });
      const res = await hostRpc('openai_tunnel_connect', {
        profileId: selectedChatgptProfileId,
        ProfileId: selectedChatgptProfileId,
      });
      appliedChatgptProfileId = selectedChatgptProfileId;
      updateDirtyRunningIds(() => ({}));
      await syncInfraFromRpcResult(res);
      onToast('已应用配置并连接 ChatGPT 隧道', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const handleDisconnectChatgpt = async () => {
    if (busyAction || !isChatGpt) return;
    setBusyAction('disconnect_tunnel');
    try {
      const res = await hostRpc('openai_tunnel_disconnect');
      appliedChatgptProfileId = '';
      updateDirtyRunningIds(() => ({}));
      await syncInfraFromRpcResult(res);
      onToast('已断开 ChatGPT 隧道', 'info');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const handleCopyChatgptTunnelId = async (p: SafeConnectionProfile) => {
    const fullVal = (p.TunnelId || '').trim();
    if (!fullVal) {
      onToast('当前配置未填写隧道编号', 'warning');
      return;
    }
    try {
      await hostRpc('copy_clipboard', { text: fullVal });
      markCopied(`tid_${p.Id}`);
      onToast('已复制隧道编号到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleToggleRevealChatgptSecret = async (p: SafeConnectionProfile) => {
    if (revealedSecrets[p.Id]) {
      setRevealedSecrets((prev) => {
        const next = { ...prev };
        delete next[p.Id];
        return next;
      });
      return;
    }
    try {
      const res = await hostRpc<any>('profile_get_secret', {
        profileId: p.Id,
        ProfileId: p.Id,
      });
      const secret = String(res?.secret ?? res?.Secret ?? '');
      if (!secret) {
        onToast('当前配置尚未保存密钥', 'warning');
        return;
      }
      setRevealedSecrets((prev) => ({ ...prev, [p.Id]: secret }));
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleCopyChatgptSecret = async (p: SafeConnectionProfile) => {
    try {
      const res = await hostRpc<any>('profile_get_secret', {
        profileId: p.Id,
        ProfileId: p.Id,
      });
      const secret = String(res?.secret ?? res?.Secret ?? '');
      if (!secret) {
        onToast('当前配置尚未保存密钥', 'warning');
        return;
      }
      await hostRpc('copy_clipboard', { text: secret });
      markCopied(`key_${p.Id}`);
      onToast('已复制完整 Key 到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  // ---------------- Gemini / Claude Pure Caller Handlers ----------------

  const handleCopyCallerTunnelUrl = async (tun: PublicTunnelItem) => {
    const effective = (tun.EffectiveUrl || '').trim();
    if (!effective) {
      onToast('该隧道尚未启动，请先点击右下角「启动隧道」', 'warning');
      return;
    }
    try {
      await hostRpc('copy_clipboard', { text: effective });
      markCopied(`pub_tid_${tun.Id}`);
      onToast('已复制隧道地址到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleToggleRevealOAuthHelper = (tun: PublicTunnelItem) => {
    const flagKey = `pub_oauth_${tun.Id}`;
    setRevealedSecrets((prev) => {
      const next = { ...prev };
      if (next[flagKey]) {
        delete next[flagKey];
      } else {
        next[flagKey] = 'relaystudio (Client ID / Secret 通用)';
      }
      return next;
    });
  };

  const handleCopyOAuthHelper = async (tun: PublicTunnelItem) => {
    try {
      await hostRpc('copy_clipboard', { text: 'relaystudio' });
      markCopied(`pub_oauth_cp_${tun.Id}`);
      onToast('已复制默认密钥 (relaystudio)', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleBindPublicTunnel = async (
    plat: 'gemini' | 'claude',
    tun: PublicTunnelItem
  ) => {
    if (busyAction) return;
    setBusyAction('bind_pub_tunnel');
    try {
      const res = await hostRpc('platform_bind_public_tunnel', {
        platform: plat,
        tunnelId: tun.Id,
      });
      await syncInfraFromRpcResult(res);
      onToast(`✓ 已将 ${PLATFORM_LABELS[plat]} 切换至「${tun.Name}」`, 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const enabledSet = new Set<PlatformId>(
    (infra.profiles?.EnabledPlatforms || ['chatgpt']).map((p) => canonicalPlat(p))
  );
  if (enabledSet.size === 0) enabledSet.add('chatgpt');
  const enabledPlatforms = ORDERED_PLATFORMS.filter((p) => enabledSet.has(p));
  const missingPlatforms = PICKER_PLATFORMS.filter((pm) => !enabledSet.has(pm.id));

  // Caller view state for Gemini / Claude
  const callerBoundId =
    activeTab === 'gemini'
      ? geminiBound.boundId
      : activeTab === 'claude'
        ? claudeBound.boundId
        : 'pub_builtin_quick';
  const rawPickedId =
    activeTab === 'gemini' || activeTab === 'claude'
      ? pickedPubIdByPlat[activeTab]
      : callerBoundId;
  const callerPickedTun =
    publicTunnels.find((t) => t.Id === rawPickedId) ||
    publicTunnels.find((t) => t.Id === callerBoundId) ||
    publicTunnels[0];
  const callerPickedId = callerPickedTun?.Id || callerBoundId;

  const headerTitle =
    activeTab === 'add'
      ? '添加平台通道'
      : isChatGpt
        ? `ChatGPT 隧道配置 (${chatgptProfiles.length})`
        : `${PLATFORM_LABELS[activeTab]} 隧道配置 (${publicTunnels.length})`;

  const chatgptPrimaryConnectLabel = (() => {
    if (busyAction === 'connect_tunnel') return '连接中…';
    if (!chatgptRunning) return '▶ 启动隧道';
    if (selectedChatgptProfileId && selectedChatgptProfileId !== runningChatgptProfileId) {
      return '▶ 切换并连接';
    }
    if (runningChatgptProfileId && dirtyRunningIds[runningChatgptProfileId]) {
      return '↻ 应用并重连';
    }
    return '↻ 重新连接';
  })();

  const renderChatgptInlineForm = (targetProf: SafeConnectionProfile | null) => {
    const canDelete = Boolean(targetProf && chatgptProfiles.length > 1);
    const idPrefix = targetProf ? `th-cgpt-${targetProf.Id}` : 'th-cgpt-new';

    return (
      <form
        className="th-inline-form"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => void handleSaveInlineProfile(e)}
      >
        <div className="th-form-grid">
          <div className="th-field">
            <label className="th-field-label" htmlFor={`${idPrefix}-name`}>
              配置名称
            </label>
            <input
              id={`${idPrefix}-name`}
              name="name"
              type="text"
              className="th-input"
              required
              placeholder="例如：主号 / Plus 专享号"
              value={formName}
              onInput={(e) => setFormName((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          <div className="th-field">
            <label className="th-field-label" htmlFor={`${idPrefix}-tid`}>
              隧道编号或链接
            </label>
            <input
              id={`${idPrefix}-tid`}
              name="tunnelId"
              type="text"
              className="th-input mono"
              required
              autocorrect="off"
              autocapitalize="none"
              spellcheck={false}
              placeholder="粘贴 tunnel_... 编号或连接地址"
              value={formTunnelId}
              onInput={(e) => setFormTunnelId((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          <div className="th-field">
            <label className="th-field-label" htmlFor={`${idPrefix}-key`}>
              OpenAI API Key
            </label>
            <input
              id={`${idPrefix}-key`}
              name="apiKey"
              type="password"
              className="th-input mono th-secret-input"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="none"
              spellcheck={false}
              placeholder={
                targetProf?.HasKey
                  ? '已通过 DPAPI 加密保存，留空保持原密钥不变'
                  : '粘贴 sk-... 密钥（仅加密保存在本机）'
              }
              value={formApiKey}
              onInput={(e) => setFormApiKey((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          <details className="th-adv-details">
            <summary className="th-adv-summary">高级选项 ▾</summary>
            <div className="th-field" style={{ marginTop: '6px' }}>
              <label className="th-field-label" htmlFor={`${idPrefix}-api-url`}>
                API Base URL
              </label>
              <input
                id={`${idPrefix}-api-url`}
                name="apiBaseUrl"
                type="url"
                className="th-input mono"
                autocorrect="off"
                autocapitalize="none"
                spellcheck={false}
                placeholder="https://api.openai.com/v1"
                value={formApiBaseUrl}
                onInput={(e) => setFormApiBaseUrl((e.currentTarget as HTMLInputElement).value)}
              />
            </div>
          </details>
        </div>

        <div className="th-form-actions">
          <div>
            {canDelete && targetProf && (
              confirmDeleteId === targetProf.Id ? (
                <button
                  type="button"
                  className="th-danger-link is-confirm"
                  disabled={Boolean(busyAction)}
                  onClick={() => {
                    const delId = targetProf.Id;
                    const delName = targetProf.Name;
                    setConfirmDeleteId(null);
                    resetFormState();
                    setBusyAction(`del_${delId}`);
                    void hostRpc('profile_remove', {
                      profileId: delId,
                      ProfileId: delId,
                      id: delId,
                    })
                      .then(async (res) => {
                        await syncInfraFromRpcResult(res);
                        onToast(`已删除配置「${delName}」`, 'info');
                      })
                      .catch((err) => {
                        onToast(err instanceof Error ? err.message : String(err), 'error');
                      })
                      .finally(() => setBusyAction(null));
                  }}
                >
                  确认删除此配置?
                </button>
              ) : (
                <button
                  type="button"
                  className="th-danger-link"
                  disabled={Boolean(busyAction)}
                  onClick={() => setConfirmDeleteId(targetProf.Id)}
                >
                  删除此配置
                </button>
              )
            )}
          </div>

          <div className="th-form-actions-right">
            <button
              type="button"
              className="th-btn th-btn-secondary"
              onClick={() => resetFormState()}
            >
              取消
            </button>
            <button
              type="submit"
              className="th-btn th-btn-primary"
              disabled={Boolean(busyAction)}
            >
              {busyAction === 'profile_save' ? '保存中…' : '保存'}
            </button>
          </div>
        </div>
      </form>
    );
  };

  return (
    <AnchoredPopover
      open={open}
      anchorEl={anchorEl}
      align="start"
      width={460}
      className="tunnel-hub-popover"
      onClose={onClose}
    >
      <div className="th-root">
        {/* Header (`13.5px` Bold serif) */}
        <div className="th-header">
          <div className="th-header-title">{headerTitle}</div>

          <div className="th-header-actions">
            {activeTab !== 'add' && enabledPlatforms.length > 1 && (
              <button
                type="button"
                className="th-subtle-remove-btn"
                disabled={Boolean(busyAction)}
                onClick={() => {
                  const targetPlat = activeTab;
                  const label = PLATFORM_LABELS[targetPlat];
                  const fallbackTab =
                    enabledPlatforms.find((p) => p !== targetPlat) || 'chatgpt';
                  setBusyAction(`rm_plat_${targetPlat}`);
                  void hostRpc('capsule_remove_platform', { platform: targetPlat })
                    .then(async (res) => {
                      await syncInfraFromRpcResult(res);
                      onToast(`已从顶栏移除 ${label} 通道`, 'info');
                      onSelectTab(fallbackTab);
                    })
                    .catch((err) => {
                      onToast(err instanceof Error ? err.message : String(err), 'error');
                    })
                    .finally(() => setBusyAction(null));
                }}
              >
                移除此栏
              </button>
            )}

            {isChatGpt && (
              <button
                type="button"
                className={`th-add-prof-btn ${expandedId === '__new__' ? 'is-open' : ''}`}
                onClick={openNewProfileForm}
              >
                {expandedId === '__new__' ? '取消新增' : '+ 新增配置'}
              </button>
            )}

            {isPubCaller && (
              <button
                type="button"
                className="th-add-prof-btn"
                onClick={() => onManagePublicTunnels(callerPickedId)}
              >
                管理公网隧道 →
              </button>
            )}

            <button
              type="button"
              className="th-close-icon-btn"
              aria-label="关闭配置面板"
              title="关闭"
              onClick={onClose}
            >
              ×
            </button>
          </div>
        </div>

        {/* ==================== Picker Panel (`activeTab === 'add'`) ==================== */}
        {activeTab === 'add' ? (
          <div className="th-picker-list">
            <div className="th-picker-hint">
              点击下方平台卡片即可在顶栏胶囊中启用对应 MCP 隧道栏：
            </div>

            {missingPlatforms.length === 0 ? (
              <div className="th-empty-box">
                <div>全部 AI 平台通道（ChatGPT / Gemini / Claude）均已在顶栏启用。</div>
                <div className="th-picker-jump-row">
                  {PICKER_PLATFORMS.map((pm) => (
                    <button
                      key={pm.id}
                      type="button"
                      className="th-btn th-btn-secondary"
                      onClick={() => onSelectTab(pm.id)}
                    >
                      查看 {pm.label}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              missingPlatforms.map((pm) => (
                <button
                  key={pm.id}
                  type="button"
                  className="th-picker-card"
                  disabled={Boolean(busyAction)}
                  onClick={() => {
                    setBusyAction(`add_plat_${pm.id}`);
                    void hostRpc('capsule_add_platform', { platform: pm.id })
                      .then(async (res) => {
                        await syncInfraFromRpcResult(res);
                        onToast(`已在顶栏添加 ${pm.label} 通道`, 'success');
                        onSelectTab(pm.id);
                      })
                      .catch((err) => {
                        onToast(err instanceof Error ? err.message : String(err), 'error');
                      })
                      .finally(() => setBusyAction(null));
                  }}
                >
                  <div className="th-picker-card-main">
                    <div className="th-picker-card-title">{pm.title}</div>
                    <div className="th-picker-card-desc">{pm.desc}</div>
                  </div>
                  <span className="th-picker-card-cta">+ 启用</span>
                </button>
              ))
            )}
          </div>
        ) : isChatGpt ? (
          /* ==================== ChatGPT Private Tunnel View ==================== */
          <>
            <div className="th-strips-scroll">
              {expandedId === '__new__' && (
                <div className="th-profile-strip is-selected">
                  <div className="th-strip-line1">
                    <div className="th-strip-title-wrap">
                      <span className="th-strip-dot is-selected" />
                      <span className="th-strip-name">新增连接凭据</span>
                      <span className="th-strip-badge is-selected">新建草稿</span>
                    </div>
                    <button
                      type="button"
                      className="th-inline-toggle-btn"
                      onClick={(e) => {
                        e.stopPropagation();
                        resetFormState();
                      }}
                    >
                      收起 ▴
                    </button>
                  </div>
                  {renderChatgptInlineForm(null)}
                </div>
              )}

              {chatgptProfiles.length === 0 && expandedId !== '__new__' ? (
                <div className="th-empty-box">
                  尚未保存配置，点击右上角「+ 新增配置」添加首条连接凭据。
                </div>
              ) : (
                chatgptProfiles.map((p) => {
                  const isRunning = Boolean(
                    chatgptRunning && runningChatgptProfileId && p.Id === runningChatgptProfileId
                  );
                  const isSelected = p.Id === selectedChatgptProfileId;
                  const isExpanded = expandedId === p.Id;
                  const isDirtyRunning = Boolean(dirtyRunningIds[p.Id]);

                  const stripStateClass =
                    isRunning && isSelected
                      ? 'is-active'
                      : !isRunning && isSelected
                        ? 'is-selected'
                        : '';

                  const dotStateClass =
                    isRunning && isSelected
                      ? 'is-running'
                      : isRunning && !isSelected
                        ? 'is-running-subtle'
                        : !isRunning && isSelected
                          ? 'is-selected'
                          : '';

                  const shortTunnel = shortenChatgptTunnelId(p.TunnelId || '');
                  const keyDisplay = revealedSecrets[p.Id]
                    ? revealedSecrets[p.Id]
                    : p.MaskedKey && p.MaskedKey !== '尚未保存密钥'
                      ? p.MaskedKey
                      : p.HasKey
                        ? 'sk-••••••••'
                        : '未配置';

                  const tidCopied = Boolean(copiedFlags[`tid_${p.Id}`]);
                  const keyCopied = Boolean(copiedFlags[`key_${p.Id}`]);

                  return (
                    <div
                      key={p.Id}
                      className={`th-profile-strip ${stripStateClass}`.trim()}
                      onClick={() => void handleSelectChatgptCard(p)}
                    >
                      <div className="th-strip-line1">
                        <div className="th-strip-title-wrap">
                          <span className={`th-strip-dot ${dotStateClass}`.trim()} />
                          <span className="th-strip-name">{p.Name}</span>

                          {isRunning && isSelected && (
                            isDirtyRunning ? (
                              <span className="th-strip-badge is-dirty">
                                已保存修改 · 待重连生效
                              </span>
                            ) : (
                              <span className="th-strip-badge is-active">
                                当前生效 · 运行中
                              </span>
                            )
                          )}

                          {isRunning && !isSelected && (
                            <span className="th-strip-badge is-running-bg">后台运行中</span>
                          )}

                          {!isRunning && isSelected && (
                            <span className="th-strip-badge is-selected">
                              {chatgptRunning ? '已选中 · 待连接' : '当前选中'}
                            </span>
                          )}
                        </div>

                        <button
                          type="button"
                          className="th-inline-toggle-btn"
                          aria-expanded={isExpanded}
                          onClick={(e) => {
                            e.stopPropagation();
                            openInlineEdit(p);
                          }}
                        >
                          {isExpanded ? '收起 ▴' : '✎ 编辑 ▾'}
                        </button>
                      </div>

                      <div
                        className="th-strip-line2 th-meta-row"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <span className="th-meta-seg">
                          <span>隧道: {shortTunnel}</span>
                          <button
                            type="button"
                            className={`th-link-btn ${tidCopied ? 'is-copied' : ''}`}
                            onClick={() => void handleCopyChatgptTunnelId(p)}
                          >
                            {tidCopied ? '✓ 已复制' : '复制'}
                          </button>
                        </span>

                        <span className="th-meta-sep">·</span>

                        <span className="th-meta-seg">
                          <span className="th-key-val">Key: {keyDisplay}</span>
                          <button
                            type="button"
                            className="th-link-btn"
                            onClick={() => void handleToggleRevealChatgptSecret(p)}
                          >
                            {revealedSecrets[p.Id] ? '隐藏' : '显示完整'}
                          </button>
                          <button
                            type="button"
                            className={`th-link-btn ${keyCopied ? 'is-copied' : ''}`}
                            onClick={() => void handleCopyChatgptSecret(p)}
                          >
                            {keyCopied ? '✓ 已复制' : '复制'}
                          </button>
                        </span>
                      </div>

                      {isExpanded && renderChatgptInlineForm(p)}
                    </div>
                  );
                })
              )}
            </div>

            {/* ChatGPT Popover Footer */}
            <div className="th-footer">
              <div className="th-footer-links">
                <div className="th-links-grid-2x2">
                  <button
                    type="button"
                    className="th-ext-link"
                    onClick={() =>
                      void hostRpc('open_external_url', {
                        url: 'https://platform.openai.com/settings/organization/tunnels',
                      })
                    }
                  >
                    隧道设置 ↗
                  </button>
                  <button
                    type="button"
                    className="th-ext-link"
                    onClick={() =>
                      void hostRpc('open_external_url', {
                        url: display?.UiUrl || 'http://127.0.0.1:8789/ui',
                      })
                    }
                  >
                    隧道状态页 ↗
                  </button>
                  <button
                    type="button"
                    className="th-ext-link"
                    onClick={() =>
                      void hostRpc('open_external_url', {
                        url: 'https://platform.openai.com/settings/organization/api-keys',
                      })
                    }
                  >
                    获取 API Key ↗
                  </button>
                  <button
                    type="button"
                    className="th-ext-link"
                    onClick={() =>
                      void hostRpc('open_external_url', {
                        url: 'https://chatgpt.com/#settings/Connectors',
                      })
                    }
                  >
                    配置 MCP 工具 ↗
                  </button>
                </div>
              </div>

              <div className="th-footer-btns">
                <button
                  type="button"
                  className="th-btn th-btn-primary"
                  disabled={Boolean(busyAction)}
                  onClick={() => void handleConnectChatgpt()}
                >
                  {chatgptPrimaryConnectLabel}
                </button>

                {chatgptRunning && (
                  <button
                    type="button"
                    className="th-btn th-btn-secondary"
                    disabled={Boolean(busyAction)}
                    onClick={() => void handleDisconnectChatgpt()}
                  >
                    断开隧道
                  </button>
                )}
              </div>
            </div>
          </>
        ) : (
          /* ==================== Gemini & Claude Pure Caller View ==================== */
          <>
            <div className="th-strips-scroll">
              {publicTunnels.map((tun) => {
                const isBound = tun.Id === callerBoundId;
                const isPicked = tun.Id === callerPickedId;

                const stripStateClass =
                  isBound && tun.Running
                    ? 'is-active'
                    : isPicked
                      ? 'is-selected'
                      : '';

                const dotStateClass =
                  isBound && tun.Running
                    ? 'is-running'
                    : isPicked
                      ? 'is-selected'
                      : tun.Running
                        ? 'is-running-subtle'
                        : '';

                const effectiveUrl = (tun.EffectiveUrl || '').trim();
                const shortEndpoint = effectiveUrl
                  ? truncateMiddle(effectiveUrl)
                  : '未启动（启动后可用）';

                const tidCopied = Boolean(copiedFlags[`pub_tid_${tun.Id}`]);
                const oauthRevealed = revealedSecrets[`pub_oauth_${tun.Id}`];
                const oauthCopied = Boolean(copiedFlags[`pub_oauth_cp_${tun.Id}`]);

                return (
                  <div
                    key={tun.Id}
                    className={`th-profile-strip ${stripStateClass}`.trim()}
                    onClick={() => {
                      if (activeTab === 'gemini' || activeTab === 'claude') {
                        setPickedPubIdByPlat((prev) => ({
                          ...prev,
                          [activeTab]: tun.Id,
                        }));
                      }
                    }}
                  >
                    {/* Line 1: Dot + Name + Decoupled Badges (No Edit Button) */}
                    <div className="th-strip-line1">
                      <div className="th-strip-title-wrap">
                        <span className={`th-strip-dot ${dotStateClass}`.trim()} />
                        <span className="th-strip-name" title={tun.Name}>
                          {tun.Name}
                        </span>

                        {isBound && tun.Running && (
                          <span className="th-strip-badge is-active">
                            当前使用 · 运行中
                          </span>
                        )}

                        {isBound && !tun.Running && (
                          <span className="th-strip-badge is-muted">
                            当前使用 · 未启动
                          </span>
                        )}

                        {!isBound && tun.Running && (
                          <span className="th-strip-badge is-running-bg">运行中</span>
                        )}

                        {isPicked && !isBound && (
                          <span className="th-strip-badge is-selected">当前选中</span>
                        )}
                      </div>
                    </div>

                    {/* Line 2: Endpoint + Web MCP OAuth Helper */}
                    <div
                      className="th-strip-line2 th-meta-row"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <span className="th-meta-seg">
                        <span title={effectiveUrl || undefined}>
                          隧道: {shortEndpoint}
                        </span>
                        <button
                          type="button"
                          className={`th-link-btn ${tidCopied ? 'is-copied' : ''}`}
                          onClick={() => void handleCopyCallerTunnelUrl(tun)}
                        >
                          {tidCopied ? '✓ 已复制' : '复制'}
                        </button>
                      </span>

                      <span className="th-meta-sep">·</span>

                      <span className="th-meta-seg">
                        <span className="th-key-val">
                          Key: {oauthRevealed || 'relaystudio'}
                        </span>
                        <button
                          type="button"
                          className="th-link-btn"
                          onClick={() => handleToggleRevealOAuthHelper(tun)}
                        >
                          {oauthRevealed ? '隐藏' : '显示完整'}
                        </button>
                        <button
                          type="button"
                          className={`th-link-btn ${oauthCopied ? 'is-copied' : ''}`}
                          onClick={() => void handleCopyOAuthHelper(tun)}
                        >
                          {oauthCopied ? '✓ 已复制' : '复制'}
                        </button>
                      </span>
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Caller Popover Footer */}
            <div className="th-footer">
              <div className="th-footer-links">
                {activeTab === 'gemini' && (
                  <div className="th-links-row-1x2">
                    <button
                      type="button"
                      className="th-ext-link"
                      onClick={() =>
                        void hostRpc('open_external_url', {
                          url: 'https://gemini.google.com/app',
                        })
                      }
                    >
                      打开网页端 ↗
                    </button>
                    <button
                      type="button"
                      className="th-ext-link"
                      onClick={() =>
                        void hostRpc('open_external_url', {
                          url: 'https://gemini.google.com/devmode',
                        })
                      }
                    >
                      配置 MCP 工具 ↗
                    </button>
                  </div>
                )}

                {activeTab === 'claude' && (
                  <div className="th-links-row-1x2">
                    <button
                      type="button"
                      className="th-ext-link"
                      onClick={() =>
                        void hostRpc('open_external_url', {
                          url: 'https://claude.ai/new',
                        })
                      }
                    >
                      打开网页端 ↗
                    </button>
                    <button
                      type="button"
                      className="th-ext-link"
                      onClick={() =>
                        void hostRpc('open_external_url', {
                          url: 'https://claude.ai/settings/connectors',
                        })
                      }
                    >
                      配置 MCP 工具 ↗
                    </button>
                  </div>
                )}
              </div>

              <div className="th-footer-btns">
                {!callerPickedTun?.Running ? (
                  <button
                    type="button"
                    className="th-btn th-btn-primary"
                    disabled={Boolean(busyAction)}
                    onClick={() => {
                      onManagePublicTunnels(callerPickedTun?.Id);
                      onToast('请在「隧道与连接」中点击启动', 'info');
                    }}
                  >
                    启动隧道
                  </button>
                ) : callerPickedTun.Id !== callerBoundId ? (
                  <button
                    type="button"
                    className="th-btn th-btn-primary"
                    disabled={Boolean(busyAction)}
                    onClick={() => {
                      if (activeTab === 'gemini' || activeTab === 'claude') {
                        void handleBindPublicTunnel(activeTab, callerPickedTun);
                      }
                    }}
                  >
                    {busyAction === 'bind_pub_tunnel' ? '切换中…' : '切换隧道'}
                  </button>
                ) : (
                  <button
                    type="button"
                    className="th-btn th-btn-secondary"
                    disabled
                  >
                    当前使用中
                  </button>
                )}
              </div>
            </div>
          </>
        )}
      </div>
    </AnchoredPopover>
  );
}
