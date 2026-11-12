import { useEffect, useRef, useState } from 'preact/hooks';
import type {
  HostInfraBundle,
  PlatformId,
  SafeConnectionProfile,
} from '../types/contracts';
import { extractInfraBundle, hostRpc } from '../services/hostBridge';
import { AnchoredPopover } from './AnchoredPopover';

export type TunnelHubTab = 'chatgpt' | 'gemini' | 'claude' | 'add';

export interface TunnelHubPopoverProps {
  open: boolean;
  activeTab: TunnelHubTab;
  anchorEl: HTMLElement | null;
  infra: HostInfraBundle;
  discardSignal?: number;
  onSelectTab: (tab: TunnelHubTab) => void;
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
    desc: '通过 Tailscale Funnel 固定域名或 Cloudflare Tunnel 暴露安全 /mcp 端点',
  },
  {
    id: 'claude',
    label: 'Claude',
    title: 'Claude · 公网 HTTPS MCP',
    desc: '供 Claude Connectors 接入公网 HTTPS /mcp 端点并自动完成 OAuth 鉴权',
  },
];

// Module-level applied running profile & dirty edit tracking across popover open/close cycles
let appliedChatgptProfileId = '';
const appliedPublicProfileByPlat: Partial<Record<'gemini' | 'claude', string>> = {};
let persistedDirtyRunningIds: Record<string, boolean> = {};

function canonicalPlat(raw: string | undefined): PlatformId {
  const s = (raw || 'chatgpt').trim().toLowerCase();
  if (s === 'gemini' || s === 'gemini_api') return 'gemini';
  if (s === 'claude' || s === 'claude_api') return 'claude';
  return 'chatgpt';
}

function formatMcpEndpoint(rawUrl: string | undefined): string {
  const clean = (rawUrl || '').trim().replace(/\/+$/, '');
  if (!clean) return '';
  return clean.toLowerCase().endsWith('/mcp') ? clean : `${clean}/mcp`;
}

function shortenTunnelDisplay(val: string, isPub: boolean): string {
  const trimmed = (val || '').trim();
  if (!trimmed) return isPub ? '未分配公网地址' : '未配置';
  if (isPub) {
    const noScheme = trimmed.replace(/^https?:\/\//i, '');
    return noScheme.length > 28 ? `${noScheme.slice(0, 18)}…${noScheme.slice(-8)}` : noScheme;
  }
  return trimmed.length > 22 ? `${trimmed.slice(0, 13)}…${trimmed.slice(-6)}` : trimmed;
}

export function TunnelHubPopover({
  open,
  activeTab,
  anchorEl,
  infra,
  discardSignal,
  onSelectTab,
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

  // Inline accordion form fields
  const [formName, setFormName] = useState<string>('');
  const [formTunnelId, setFormTunnelId] = useState<string>('');
  const [formBaseUrl, setFormBaseUrl] = useState<string>('');
  const [formApiKey, setFormApiKey] = useState<string>('');
  const [formApiBaseUrl, setFormApiBaseUrl] = useState<string>('https://api.openai.com/v1');

  // Per-profile revealed secret & transient copy checkmark badges
  const [revealedSecrets, setRevealedSecrets] = useState<Record<string, string>>({});
  const [copiedFlags, setCopiedFlags] = useState<Record<string, boolean>>({});
  const copyTimersRef = useRef<Record<string, number>>({});
  const prevDiscardRef = useRef<number | undefined>(discardSignal);
  const prevTabRef = useRef<TunnelHubTab>(activeTab);

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
    setFormBaseUrl('');
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
  const pubTunnel = infra.publicTunnel;

  // Sync module-level applied profile tracking against live tunnel running states
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

  const pubRunning = Boolean(pubTunnel?.Running);
  if (!pubRunning) {
    delete appliedPublicProfileByPlat.gemini;
    delete appliedPublicProfileByPlat.claude;
  } else {
    for (const pPlat of ['gemini', 'claude'] as const) {
      if (!appliedPublicProfileByPlat[pPlat]) {
        const pList = allProfiles.filter((p) => canonicalPlat(p.Platform) === pPlat);
        const matchedFromTunnel =
          pubTunnel?.ProfileId && pList.some((p) => p.Id === pubTunnel.ProfileId)
            ? pubTunnel.ProfileId
            : '';
        appliedPublicProfileByPlat[pPlat] =
          matchedFromTunnel ||
          activeByPlat[pPlat] ||
          pList.find((p) => p.IsActive)?.Id ||
          pList[0]?.Id ||
          '';
      }
    }
  }

  // Clear stale dirty flags if tunnel stopped
  useEffect(() => {
    if (!chatgptRunning && !pubRunning && Object.keys(persistedDirtyRunningIds).length > 0) {
      updateDirtyRunningIds(() => ({}));
    }
  }, [chatgptRunning, pubRunning]);

  const isChatGpt = activeTab === 'chatgpt';
  const isPub = activeTab === 'gemini' || activeTab === 'claude';

  const platProfiles =
    activeTab === 'add'
      ? []
      : allProfiles.filter((p) => canonicalPlat(p.Platform) === activeTab);

  const selectedProfileId =
    activeTab === 'add'
      ? ''
      : isChatGpt
        ? activeByPlat.chatgpt ||
          infra.profiles?.ActiveProfileId ||
          platProfiles.find((p) => p.IsActive)?.Id ||
          platProfiles[0]?.Id ||
          ''
        : activeByPlat[activeTab] ||
          platProfiles.find((p) => p.IsActive)?.Id ||
          platProfiles[0]?.Id ||
          '';

  const isRunningNow =
    activeTab === 'add'
      ? false
      : activeTab === 'chatgpt'
        ? Boolean(display?.Running)
        : Boolean(pubTunnel?.Running);

  const runningProfileId =
    activeTab === 'add' || !isRunningNow
      ? ''
      : activeTab === 'chatgpt'
        ? display?.RunningProfileId || appliedChatgptProfileId || infra.profiles?.ActiveProfileId || ''
        : appliedPublicProfileByPlat[activeTab] || '';

  const editingExisting =
    expandedId && expandedId !== '__new__'
      ? platProfiles.find((p) => p.Id === expandedId) || null
      : null;

  // Compute unsaved edits dirty flag & sync to host guard
  const isDirty = (() => {
    if (!open || !expandedId || activeTab === 'add') return false;
    if (expandedId === '__new__') {
      return (
        formTunnelId.trim().length > 0 ||
        formBaseUrl.trim().length > 0 ||
        formApiKey.trim().length > 0
      );
    }
    if (!editingExisting) return false;
    const baseName = (editingExisting.Name || '').trim();
    const baseTid = (editingExisting.TunnelId || '').trim();
    const basePubUrl = (editingExisting.BaseUrl || '').trim();
    const baseApiUrl = (
      editingExisting.ApiBaseUrl ||
      editingExisting.BaseUrl ||
      'https://api.openai.com/v1'
    ).trim();

    if (formName.trim() !== baseName) return true;
    if (formApiKey.trim().length > 0) return true;
    if (isChatGpt) {
      if (formTunnelId.trim() !== baseTid) return true;
      if ((formApiBaseUrl.trim() || 'https://api.openai.com/v1') !== baseApiUrl) return true;
    } else if (formBaseUrl.trim() !== basePubUrl) {
      return true;
    }
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

  const openInlineEdit = (p: SafeConnectionProfile) => {
    if (expandedId === p.Id) {
      resetFormState();
      return;
    }
    setConfirmDeleteId(null);
    setExpandedId(p.Id);
    setFormName(p.Name || '');
    setFormTunnelId(p.TunnelId || '');
    setFormBaseUrl(p.BaseUrl || '');
    setFormApiKey('');
    setFormApiBaseUrl(p.ApiBaseUrl || p.BaseUrl || 'https://api.openai.com/v1');
  };

  const openNewProfileForm = () => {
    if (expandedId === '__new__') {
      resetFormState();
      return;
    }
    const nextIdx = platProfiles.length + 1;
    const defaultLabel = isChatGpt
      ? `隧道配置 #${nextIdx}`
      : `${PLATFORM_LABELS[activeTab as PlatformId]} 配置 #${nextIdx}`;
    setConfirmDeleteId(null);
    setExpandedId('__new__');
    setFormName(defaultLabel);
    setFormTunnelId('');
    setFormBaseUrl('');
    setFormApiKey('');
    setFormApiBaseUrl('https://api.openai.com/v1');
  };

  // 1) Click Card (`handleSelectCard`): select ONLY, never restart or disconnect tunnel
  const handleSelectCard = async (p: SafeConnectionProfile) => {
    if (busyAction || activeTab === 'add') return;
    if (p.Id === selectedProfileId) return;
    setBusyAction(`sel_${p.Id}`);
    try {
      const res = await hostRpc('profile_select', {
        profileId: p.Id,
        ProfileId: p.Id,
        id: p.Id,
        platform: activeTab,
        Platform: activeTab,
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

  // 2) Inline Edit / New Form (`保存`): save ONLY (`connectNow: false`), never start/restart tunnel
  const handleSaveInlineProfile = async (e: Event) => {
    e.preventDefault();
    if (activeTab === 'add' || busyAction) return;

    const isCreating = expandedId === '__new__';
    const targetProf = isCreating ? null : editingExisting;

    if (isChatGpt) {
      if (!formTunnelId.trim()) {
        onToast('请填写隧道编号 (tunnel_...) 或连接链接', 'warning');
        return;
      }
      if (!formApiKey.trim() && !targetProf?.HasKey) {
        onToast('首次保存配置请粘贴 OpenAI API Key', 'warning');
        return;
      }
    }

    const cleanName =
      formName.trim() ||
      (isChatGpt ? '主号配置' : `${PLATFORM_LABELS[activeTab]} 默认配置`);

    setBusyAction('profile_save');
    try {
      const res = await hostRpc('profile_save', {
        profileId: isCreating ? '' : targetProf?.Id || '',
        ProfileId: isCreating ? '' : targetProf?.Id || '',
        name: cleanName,
        Name: cleanName,
        platform: activeTab,
        Platform: activeTab,
        kind: isChatGpt ? 'tunnel' : 'public_tunnel',
        Kind: isChatGpt ? 'tunnel' : 'public_tunnel',
        tunnelId: isChatGpt ? formTunnelId.trim() : '',
        TunnelId: isChatGpt ? formTunnelId.trim() : '',
        baseUrl: isChatGpt
          ? formApiBaseUrl.trim() || 'https://api.openai.com/v1'
          : formBaseUrl.trim(),
        BaseUrl: isChatGpt
          ? formApiBaseUrl.trim() || 'https://api.openai.com/v1'
          : formBaseUrl.trim(),
        apiBaseUrl: isChatGpt
          ? formApiBaseUrl.trim() || 'https://api.openai.com/v1'
          : '',
        ApiBaseUrl: isChatGpt
          ? formApiBaseUrl.trim() || 'https://api.openai.com/v1'
          : '',
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
        nextInfra?.profiles?.ActiveProfileByPlatform?.[activeTab] ||
        (isChatGpt ? nextInfra?.profiles?.ActiveProfileId : '') ||
        '';

      if (savedId) {
        setRevealedSecrets((prev) => {
          const next = { ...prev };
          delete next[savedId];
          return next;
        });
        if (runningProfileId && savedId === runningProfileId) {
          updateDirtyRunningIds((prev) => ({ ...prev, [savedId]: true }));
        }
      }

      resetFormState();
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
      onToast(
        isRunningNow
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

  // 3) Bottom-Right Group Connect & Disconnect Handlers
  const handleConnectGroup = async () => {
    if (busyAction || activeTab === 'add') return;
    if (isChatGpt && !selectedProfileId) {
      onToast('请先新增并保存一条隧道配置', 'warning');
      return;
    }

    setBusyAction('connect_tunnel');
    try {
      if (isChatGpt) {
        if (selectedProfileId) {
          await hostRpc('profile_select', {
            profileId: selectedProfileId,
            ProfileId: selectedProfileId,
            id: selectedProfileId,
            platform: 'chatgpt',
            Platform: 'chatgpt',
            reconnect: false,
            Reconnect: false,
          });
        }
        const res = await hostRpc('openai_tunnel_connect', {
          profileId: selectedProfileId,
          ProfileId: selectedProfileId,
        });
        appliedChatgptProfileId = selectedProfileId;
        updateDirtyRunningIds(() => ({}));
        await syncInfraFromRpcResult(res);
        onToast('已应用配置并连接 ChatGPT 隧道', 'success');
      } else {
        if (selectedProfileId) {
          await hostRpc('profile_select', {
            profileId: selectedProfileId,
            ProfileId: selectedProfileId,
            id: selectedProfileId,
            platform: activeTab,
            Platform: activeTab,
            reconnect: false,
            Reconnect: false,
          });
        }
        const res = await hostRpc('public_tunnel_connect', {
          platform: activeTab,
          Platform: activeTab,
          profileId: selectedProfileId,
          ProfileId: selectedProfileId,
          action: isRunningNow ? 'restart' : 'start',
        });
        appliedPublicProfileByPlat[activeTab] = selectedProfileId;
        updateDirtyRunningIds(() => ({}));
        await syncInfraFromRpcResult(res);
        onToast(`已应用配置并连接 ${PLATFORM_LABELS[activeTab]} 隧道`, 'success');
      }
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const handleDisconnectGroup = async () => {
    if (busyAction || activeTab === 'add') return;
    setBusyAction('disconnect_tunnel');
    try {
      if (isChatGpt) {
        const res = await hostRpc('openai_tunnel_disconnect');
        appliedChatgptProfileId = '';
        updateDirtyRunningIds(() => ({}));
        await syncInfraFromRpcResult(res);
        onToast('已断开 ChatGPT 隧道', 'info');
      } else {
        const res = await hostRpc('public_tunnel_disconnect');
        delete appliedPublicProfileByPlat.gemini;
        delete appliedPublicProfileByPlat.claude;
        updateDirtyRunningIds(() => ({}));
        await syncInfraFromRpcResult(res);
        onToast(`已断开 ${PLATFORM_LABELS[activeTab]} 隧道`, 'info');
      }
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyAction(null);
    }
  };

  const resolveEffectivePubUrl = (p: SafeConnectionProfile): string => {
    const customUrl = (p.TunnelId || p.BaseUrl || '').trim();
    const livePubUrl = (pubTunnel?.PublicMcpUrl || pubTunnel?.Url || '').trim();
    return formatMcpEndpoint(customUrl || livePubUrl);
  };

  const handleCopyTunnelEndpoint = async (p: SafeConnectionProfile) => {
    if (isPub) {
      const effectiveMcpUrl = resolveEffectivePubUrl(p);
      if (!effectiveMcpUrl) {
        onToast('当前未分配公网地址，请先启动隧道', 'warning');
        return;
      }
      try {
        await hostRpc('copy_clipboard', { text: effectiveMcpUrl });
        markCopied(`tid_${p.Id}`);
        onToast('已复制隧道地址到剪贴板', 'success');
      } catch (err) {
        onToast(err instanceof Error ? err.message : String(err), 'error');
      }
      return;
    }

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

  const isDefaultRelayCredential = (p: SafeConnectionProfile): boolean => {
    return isPub && (!p.HasKey || p.MaskedKey === '尚未保存密钥');
  };

  const handleToggleRevealSecret = async (p: SafeConnectionProfile) => {
    if (revealedSecrets[p.Id]) {
      setRevealedSecrets((prev) => {
        const next = { ...prev };
        delete next[p.Id];
        return next;
      });
      return;
    }
    if (isDefaultRelayCredential(p)) {
      setRevealedSecrets((prev) => ({ ...prev, [p.Id]: 'relaystudio' }));
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

  const handleCopySecret = async (p: SafeConnectionProfile) => {
    if (isDefaultRelayCredential(p)) {
      try {
        await hostRpc('copy_clipboard', { text: 'relaystudio' });
        markCopied(`key_${p.Id}`);
        onToast('已复制默认密钥 (relaystudio)', 'success');
      } catch (err) {
        onToast(err instanceof Error ? err.message : String(err), 'error');
      }
      return;
    }

    try {
      const res = await hostRpc<any>('profile_get_secret', {
        profileId: p.Id,
        ProfileId: p.Id,
      });
      const secret = String(res?.secret ?? res?.Secret ?? '');
      const isDefaultOAuth = Boolean(res?.isDefaultOAuth ?? res?.IsDefaultOAuth);
      if (!secret) {
        onToast('当前配置尚未保存密钥', 'warning');
        return;
      }
      await hostRpc('copy_clipboard', { text: secret });
      markCopied(`key_${p.Id}`);
      onToast(
        isDefaultOAuth ? '已复制默认密钥 (relaystudio)' : '已复制完整 Key 到剪贴板',
        'success'
      );
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const enabledSet = new Set<PlatformId>(
    (infra.profiles?.EnabledPlatforms || ['chatgpt']).map((p) => canonicalPlat(p))
  );
  if (enabledSet.size === 0) enabledSet.add('chatgpt');
  const enabledPlatforms = ORDERED_PLATFORMS.filter((p) => enabledSet.has(p));
  const missingPlatforms = PICKER_PLATFORMS.filter((pm) => !enabledSet.has(pm.id));

  const headerTitle =
    activeTab === 'add'
      ? '添加平台通道'
      : `${PLATFORM_LABELS[activeTab]} 隧道配置 (${platProfiles.length})`;

  const primaryConnectLabel = (() => {
    if (busyAction === 'connect_tunnel') return '连接中…';
    if (!isRunningNow) return '▶ 启动隧道';
    if (selectedProfileId && selectedProfileId !== runningProfileId) return '▶ 切换并连接';
    if (runningProfileId && dirtyRunningIds[runningProfileId]) return '↻ 应用并重连';
    return '↻ 重新连接';
  })();

  const renderInlineAccordionForm = (targetProf: SafeConnectionProfile | null) => {
    const canDelete = Boolean(targetProf && platProfiles.length > 1);
    return (
      <form
        className="th-inline-form"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => void handleSaveInlineProfile(e)}
      >
        <div className="th-form-grid">
          <div className="th-field">
            <label className="th-field-label">配置名称</label>
            <input
              type="text"
              className="th-input"
              required
              placeholder={isChatGpt ? '例如：主号 / Plus 专享号' : '例如：Tailscale 固定域名'}
              value={formName}
              onInput={(e) => setFormName((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          {isChatGpt ? (
            <div className="th-field">
              <label className="th-field-label">隧道编号或链接</label>
              <input
                type="text"
                className="th-input mono"
                required
                placeholder="粘贴 tunnel_... 编号或连接地址"
                value={formTunnelId}
                onInput={(e) => setFormTunnelId((e.currentTarget as HTMLInputElement).value)}
              />
            </div>
          ) : (
            <div className="th-field">
              <label className="th-field-label">固定公网域名（可选）</label>
              <input
                type="text"
                className="th-input mono"
                placeholder="留空自动使用 Tailscale Funnel / Cloudflare Tunnel"
                value={formBaseUrl}
                onInput={(e) => setFormBaseUrl((e.currentTarget as HTMLInputElement).value)}
              />
            </div>
          )}

          <div className="th-field">
            <label className="th-field-label">
              {isChatGpt ? 'OpenAI API Key' : 'OAuth 访问密钥（可选）'}
            </label>
            <input
              type="password"
              className="th-input mono th-secret-input"
              placeholder={
                isChatGpt
                  ? targetProf?.HasKey
                    ? '已通过 DPAPI 加密保存，留空保持原密钥不变'
                    : '粘贴 sk-... 密钥（仅加密保存在本机）'
                  : targetProf?.HasKey
                    ? '已保存自定义 OAuth 密钥，留空保持不变'
                    : '留空默认使用 relaystudio（Client ID 与 Secret 通用）'
              }
              value={formApiKey}
              onInput={(e) => setFormApiKey((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          {isChatGpt && (
            <details className="th-adv-details">
              <summary className="th-adv-summary">高级选项 ▾</summary>
              <div className="th-field" style={{ marginTop: '6px' }}>
                <label className="th-field-label">API Base URL</label>
                <input
                  type="url"
                  className="th-input mono"
                  placeholder="https://api.openai.com/v1"
                  value={formApiBaseUrl}
                  onInput={(e) => setFormApiBaseUrl((e.currentTarget as HTMLInputElement).value)}
                />
              </div>
            </details>
          )}
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

            {activeTab !== 'add' && (
              <button
                type="button"
                className={`th-add-prof-btn ${expandedId === '__new__' ? 'is-open' : ''}`}
                onClick={openNewProfileForm}
              >
                {expandedId === '__new__' ? '取消新增' : '+ 新增配置'}
              </button>
            )}

            <button
              type="button"
              className="th-close-icon-btn"
              aria-label="关闭配置面板"
              title="关闭"
              onClick={onClose}
            >
              ✕
            </button>
          </div>
        </div>

        {/* Picker Panel (`activeTab === 'add'`) */}
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
        ) : (
          <>
            {/* Profile Strip Cards + Inline Accordion Edit */}
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
                  {renderInlineAccordionForm(null)}
                </div>
              )}

              {platProfiles.length === 0 && expandedId !== '__new__' ? (
                <div className="th-empty-box">
                  尚未保存配置，点击右上角「+ 新增配置」添加首条连接凭据。
                </div>
              ) : (
                platProfiles.map((p) => {
                  const isRunning = Boolean(
                    isRunningNow && runningProfileId && p.Id === runningProfileId
                  );
                  const isSelected = p.Id === selectedProfileId;
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

                  const effectivePubMcpUrl = isPub ? resolveEffectivePubUrl(p) : '';
                  const shortTunnel = isPub
                    ? effectivePubMcpUrl
                      ? shortenTunnelDisplay(effectivePubMcpUrl, true)
                      : '未分配公网地址'
                    : shortenTunnelDisplay(p.TunnelId || '', false);

                  const defaultRelayCred = isDefaultRelayCredential(p);
                  const keyDisplay = revealedSecrets[p.Id]
                    ? revealedSecrets[p.Id]
                    : defaultRelayCred
                      ? 'relaystudio'
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
                      onClick={() => void handleSelectCard(p)}
                    >
                      {/* Line 1 */}
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
                              {isRunningNow ? '已选中 · 待连接' : '当前选中'}
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

                      {/* Line 2 (`10.5px` monospace) */}
                      <div
                        className="th-strip-line2 th-meta-row"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <span className="th-meta-seg">
                          <span>隧道: {shortTunnel}</span>
                          <button
                            type="button"
                            className={`th-link-btn ${tidCopied ? 'is-copied' : ''}`}
                            onClick={() => void handleCopyTunnelEndpoint(p)}
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
                            onClick={() => void handleToggleRevealSecret(p)}
                          >
                            {revealedSecrets[p.Id] ? '隐藏' : '显示完整'}
                          </button>
                          <button
                            type="button"
                            className={`th-link-btn ${keyCopied ? 'is-copied' : ''}`}
                            onClick={() => void handleCopySecret(p)}
                          >
                            {keyCopied ? '✓ 已复制' : '复制'}
                          </button>
                        </span>
                      </div>

                      {/* Inline Accordion Edit Form */}
                      {isExpanded && renderInlineAccordionForm(p)}
                    </div>
                  );
                })
              )}
            </div>

            {/* Popover Footer */}
            <div className="th-footer">
              <div className="th-footer-links">
                {isChatGpt && (
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
                )}

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
                          url: 'https://gemini.google.com/extensions',
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
                <button
                  type="button"
                  className="th-btn th-btn-primary"
                  disabled={Boolean(busyAction)}
                  onClick={() => void handleConnectGroup()}
                >
                  {primaryConnectLabel}
                </button>

                {isRunningNow && (
                  <button
                    type="button"
                    className="th-btn th-btn-secondary"
                    disabled={Boolean(busyAction)}
                    onClick={() => void handleDisconnectGroup()}
                  >
                    断开隧道
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
