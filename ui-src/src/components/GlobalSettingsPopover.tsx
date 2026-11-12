import { useEffect, useRef, useState } from 'preact/hooks';
import type {
  AutoArchiveMode,
  CliAgentOption,
  EffectiveTheme,
  HostInfraBundle,
  PublicTunnelItem,
  ThemeMode,
} from '../types/contracts';
import {
  extractInfraBundle,
  formatMcpEndpoint,
  getEffectivePublicTunnels,
  hostRpc,
} from '../services/hostBridge';
import { postStudioAction } from '../services/studioHub';
import { normalizePlatformId } from '../utils/formatters';
import { AnchoredPopover } from './AnchoredPopover';

export type GlobalSettingsTab = 'general' | 'tunnels';

export interface GlobalSettingsPopoverProps {
  open: boolean;
  anchorEl: HTMLElement | null;
  infra: HostInfraBundle;
  themeMode: ThemeMode;
  systemTheme: EffectiveTheme;
  activeSettingsTab: GlobalSettingsTab;
  onChangeSettingsTab: (tab: GlobalSettingsTab) => void;
  highlightedTunnelId?: string | null;
  onNavigateToChatGptTunnel: () => void;
  discardSignal?: number;
  onClose: () => void;
  onSetThemeMode: (mode: ThemeMode) => void;
  onInfraUpdated: (nextInfra: HostInfraBundle) => void;
  onResetLayoutDone: (nextInfra?: HostInfraBundle) => void;
  onRefreshSnapshot: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

const AUTO_ARCHIVE_OPTIONS: Array<{ value: AutoArchiveMode; label: string; toastLabel: string }> = [
  { value: 'immediate', label: '立即', toastLabel: '立即归档' },
  { value: '1d', label: '1 天', toastLabel: '满 1 天自动归档' },
  { value: '3d', label: '3 天 (默认)', toastLabel: '满 3 天自动归档' },
  { value: '7d', label: '7 天', toastLabel: '满 7 天自动归档' },
  { value: 'off', label: '关闭', toastLabel: '关闭自动归档' },
];

const CLI_CONCURRENCY_OPTIONS: Array<{ value: number; label: string }> = [
  { value: 0, label: '关闭' },
  { value: 2, label: '2' },
  { value: 4, label: '4 (推荐)' },
  { value: 6, label: '6' },
];

const STARTUP_OPTIONS: Array<{
  value: 'window' | 'tray' | 'off';
  label: string;
  toast: string;
}> = [
  {
    value: 'window',
    label: '开机弹窗',
    toast: '已设为「开机弹窗」：登录 Windows 时自动打开工作台',
  },
  {
    value: 'tray',
    label: '静默托盘',
    toast: '已设为「静默托盘」：开机驻留右下角托盘并自动连好隧道',
  },
  {
    value: 'off',
    label: '不自启',
    toast: '已关闭开机自启',
  },
];

const FALLBACK_CLI_AGENTS: CliAgentOption[] = [
  { id: 'codex', display_name: 'Codex', kind: 'codex', command: 'codex', args: [], is_custom: false },
  { id: 'claude', display_name: 'Claude', kind: 'claude', command: 'claude', args: [], is_custom: false },
];

function normalizeStartupChoice(raw: string | undefined): 'window' | 'tray' | 'off' {
  const v = (raw || 'tray').trim().toLowerCase();
  if (v === 'window' || v === 'popup') return 'window';
  if (v === 'off' || v === 'none' || v === 'disabled') return 'off';
  return 'tray';
}

function normalizeAutoArchiveChoice(raw: string | undefined): AutoArchiveMode {
  const v = (raw || '3d').trim().toLowerCase();
  if (v === 'immediate' || v === '1d' || v === '3d' || v === '7d' || v === 'off') {
    return v;
  }
  return '3d';
}

function formatUsedByBadge(usedBy: string[] | undefined): string {
  if (!Array.isArray(usedBy) || usedBy.length === 0) return '';
  const labels: string[] = [];
  const lower = new Set(usedBy.map((p) => String(p || '').trim().toLowerCase()));
  if (lower.has('gemini')) labels.push('Gemini');
  if (lower.has('claude')) labels.push('Claude');
  for (const raw of usedBy) {
    const s = String(raw || '').trim();
    if (s && s.toLowerCase() !== 'gemini' && s.toLowerCase() !== 'claude') {
      labels.push(s);
    }
  }
  return labels.length > 0 ? `${labels.join(' · ')} 使用中` : '';
}

export function GlobalSettingsPopover({
  open,
  anchorEl,
  infra,
  themeMode,
  systemTheme,
  activeSettingsTab,
  onChangeSettingsTab,
  highlightedTunnelId,
  onNavigateToChatGptTunnel,
  discardSignal,
  onClose,
  onSetThemeMode,
  onInfraUpdated,
  onResetLayoutDone,
  onRefreshSnapshot,
  onToast,
}: GlobalSettingsPopoverProps) {
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [optimisticBrowser, setOptimisticBrowser] = useState<boolean | null>(null);
  const browserSyncSeqRef = useRef<number>(0);

  // Public Tunnel Add / Edit Inline Accordion State
  const [editingTunnelId, setEditingTunnelId] = useState<string | null>(null);
  const [confirmDeleteTunnelId, setConfirmDeleteTunnelId] = useState<string | null>(null);
  const [formTunnelName, setFormTunnelName] = useState<string>('');
  const [formTunnelBaseUrl, setFormTunnelBaseUrl] = useState<string>('');
  const [formTunnelKey, setFormTunnelKey] = useState<string>('');
  const [formClearKey, setFormClearKey] = useState<boolean>(false);

  // Revealed secrets & transient copy flags for public tunnel cards
  const [revealedPubSecrets, setRevealedPubSecrets] = useState<Record<string, string>>({});
  const [copiedFlags, setCopiedFlags] = useState<Record<string, boolean>>({});
  const copyTimersRef = useRef<Record<string, number>>({});
  const cardRefs = useRef<Record<string, HTMLDivElement | null>>({});
  const generalTabRef = useRef<HTMLButtonElement | null>(null);
  const tunnelsTabRef = useRef<HTMLButtonElement | null>(null);
  const prevDiscardRef = useRef<number | undefined>(discardSignal);

  const resetTunnelForm = () => {
    setEditingTunnelId(null);
    setConfirmDeleteTunnelId(null);
    setFormTunnelName('');
    setFormTunnelBaseUrl('');
    setFormTunnelKey('');
    setFormClearKey(false);
  };

  useEffect(() => {
    return () => {
      Object.values(copyTimersRef.current).forEach((tid) => window.clearTimeout(tid));
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    };
  }, []);

  useEffect(() => {
    if (!open) {
      resetTunnelForm();
      setRevealedPubSecrets({});
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    }
  }, [open]);

  useEffect(() => {
    if (discardSignal !== prevDiscardRef.current) {
      prevDiscardRef.current = discardSignal;
      resetTunnelForm();
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
    }
  }, [discardSignal]);

  useEffect(() => {
    if (open && activeSettingsTab === 'tunnels' && highlightedTunnelId) {
      const targetEl = cardRefs.current[highlightedTunnelId];
      targetEl?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [open, activeSettingsTab, highlightedTunnelId]);

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

  const eng = infra.engineConfig || {
    CorePort: 8765,
    AcpDefaultProfile: 'codex',
    AcpMaxConcurrentPrompts: 4,
    BrowserEnabled: true,
    StartupMode: 'tray',
    AutoArchiveCompletedMode: '3d',
    DefaultBrowserProfile: 'Chrome:Default',
  };

  const coreRawText =
    infra.display?.Core || `运行中 (127.0.0.1:${eng.CorePort || 8765})`;
  const coreHealthy = !/未启动|离线|异常|失败|fault/i.test(coreRawText);

  // ChatGPT Private Tunnel Overview Summary
  const allProfiles = infra.profiles?.Profiles || [];
  const activeByPlat = infra.profiles?.ActiveProfileByPlatform || {};
  const chatgptProfiles = allProfiles.filter(
    (p) => normalizePlatformId(String(p.Platform || 'chatgpt')) === 'chatgpt'
  );
  const selectedChatgptId =
    activeByPlat.chatgpt ||
    infra.profiles?.ActiveProfileId ||
    chatgptProfiles.find((p) => p.IsActive)?.Id ||
    chatgptProfiles[0]?.Id ||
    '';
  const chatgptRunning = Boolean(infra.display?.Running);
  const chatgptFault = Boolean(infra.display?.IsFault);
  const targetChatgptId = chatgptRunning
    ? infra.display?.RunningProfileId || selectedChatgptId
    : selectedChatgptId;
  const activeChatgptProfile =
    chatgptProfiles.find((p) => p.Id === targetChatgptId) || chatgptProfiles[0];
  const chatgptProfileName = activeChatgptProfile?.Name || '默认配置';

  const publicTunnels = getEffectivePublicTunnels(infra);
  const editingExistingTun =
    editingTunnelId && editingTunnelId !== '__new__'
      ? publicTunnels.find((t) => t.Id === editingTunnelId) || null
      : null;

  // Dirty edit tracking for public tunnel inline form
  const isTunnelFormDirty = (() => {
    if (!open || activeSettingsTab !== 'tunnels' || !editingTunnelId) return false;
    if (editingTunnelId === '__new__') {
      return (
        formTunnelBaseUrl.trim().length > 0 ||
        formTunnelKey.trim().length > 0
      );
    }
    if (!editingExistingTun) return false;
    if (formTunnelName.trim() !== (editingExistingTun.Name || '').trim()) return true;
    if (formTunnelBaseUrl.trim() !== (editingExistingTun.BaseUrl || '').trim()) return true;
    if (formTunnelKey.trim().length > 0) return true;
    if (formClearKey) return true;
    return false;
  })();

  useEffect(() => {
    void hostRpc('set_unsaved_edits', { dirty: Boolean(open && isTunnelFormDirty) }).catch(
      () => {}
    );
  }, [open, isTunnelFormDirty]);

  const autoArchiveVal = normalizeAutoArchiveChoice(eng.AutoArchiveCompletedMode);
  const startupVal = normalizeStartupChoice(eng.StartupMode);
  const concurrencyVal =
    typeof eng.AcpMaxConcurrentPrompts === 'number' && Number.isFinite(eng.AcpMaxConcurrentPrompts)
      ? eng.AcpMaxConcurrentPrompts
      : 4;
  const browserEnabled = Boolean(eng.BrowserEnabled);
  const effectiveBrowserEnabled =
    optimisticBrowser !== null ? optimisticBrowser : browserEnabled;
  const currentCliId = (eng.AcpDefaultProfile || 'codex').trim();

  const cliList: CliAgentOption[] =
    infra.cliAgents && infra.cliAgents.length > 0 ? infra.cliAgents : FALLBACK_CLI_AGENTS;

  const cleanSettingsCarrierLabel = (id: string, rawLabel: string): string => {
    if (id.trim().toLowerCase() === 'desktop:chatgpt') {
      return 'ChatGPT 桌面端';
    }
    const cleaned = String(rawLabel || '')
      .replace(/^(?:💻|🌐|\uFFFD|\?)+[\s·]*/u, '')
      .replace(/\s*\(桌面客户端\)\s*$/u, '')
      .trim();
    return cleaned || id;
  };

  const carrierOptions = (infra.browserProfiles || []).map((b) => ({
    Id: b.Id,
    Label: cleanSettingsCarrierLabel(b.Id, b.Label || b.Id),
  }));
  if (carrierOptions.length === 0) {
    carrierOptions.push({ Id: 'Chrome:Default', Label: 'Chrome · 默认配置' });
  }
  if (!carrierOptions.some((c) => c.Id.toLowerCase() === 'desktop:chatgpt')) {
    carrierOptions.push({ Id: 'Desktop:ChatGPT', Label: 'ChatGPT 桌面端' });
  }

  const syncFreshInfra = async (maybeRes?: any): Promise<HostInfraBundle | undefined> => {
    const direct = extractInfraBundle(maybeRes);
    if (direct) {
      onInfraUpdated(direct);
      return direct;
    }
    const fresh = await hostRpc<any>('get_infra_bundle');
    const freshBundle = extractInfraBundle(fresh);
    if (freshBundle) {
      onInfraUpdated(freshBundle);
      return freshBundle;
    }
    return undefined;
  };

  const runHostTask = async (
    key: string,
    fn: () => Promise<any>,
    doneToast?: string,
    level: 'info' | 'success' | 'warning' | 'error' = 'success'
  ) => {
    setBusyKey(key);
    try {
      const res = await fn();
      if (res && typeof res === 'object' && res.cancelled) {
        return;
      }
      await syncFreshInfra(res);
      if (doneToast) onToast(doneToast, level);
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleSetBrowserControl = async (nextVal: boolean) => {
    if (nextVal === effectiveBrowserEnabled) return;
    setOptimisticBrowser(nextVal);
    const seq = ++browserSyncSeqRef.current;
    try {
      await hostRpc('save_engine_config', {
        browserEnabled: nextVal,
        BrowserEnabled: nextVal,
      });
      const restartRes = await hostRpc('restart_core');
      if (seq !== browserSyncSeqRef.current) return;
      await syncFreshInfra(restartRes);
      setOptimisticBrowser(null);
      onToast(
        nextVal ? '已开启浏览器控制' : '已关闭浏览器控制',
        nextVal ? 'success' : 'info'
      );
    } catch (err) {
      if (seq !== browserSyncSeqRef.current) return;
      setOptimisticBrowser(null);
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  // ---------------- Public Tunnel Item Handlers ----------------

  const openAddTunnelForm = () => {
    if (editingTunnelId === '__new__') {
      resetTunnelForm();
      return;
    }
    const customCount = publicTunnels.filter((t) => !t.IsBuiltin).length;
    setConfirmDeleteTunnelId(null);
    setEditingTunnelId('__new__');
    setFormTunnelName(`专线隧道 #${customCount + 1}`);
    setFormTunnelBaseUrl('');
    setFormTunnelKey('');
    setFormClearKey(false);
  };

  const openEditTunnelForm = (tun: PublicTunnelItem) => {
    if (tun.IsBuiltin) return;
    if (editingTunnelId === tun.Id) {
      resetTunnelForm();
      return;
    }
    setConfirmDeleteTunnelId(null);
    setEditingTunnelId(tun.Id);
    setFormTunnelName(tun.Name || '');
    setFormTunnelBaseUrl(tun.BaseUrl || '');
    setFormTunnelKey('');
    setFormClearKey(false);
  };

  const handleDetectTailscale = async () => {
    if (busyKey) return;
    setBusyKey('detect_ts');
    try {
      const res = await hostRpc<{ ok: boolean; url: string; errorReason?: string }>(
        'public_tunnel_detect_tailscale',
        {}
      );
      const detectedUrl = String(res?.url || '').trim();
      const hint = String(res?.errorReason || '').trim();
      if (res?.ok && detectedUrl) {
        setFormTunnelBaseUrl(detectedUrl);
        if (hint) {
          onToast(hint, 'warning');
        } else {
          onToast('✓ 已填入本机 Tailscale 地址', 'success');
        }
      } else {
        onToast(hint || '未检测到本机可用的 Tailscale 地址', 'warning');
      }
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleSavePublicItem = async (e: Event) => {
    e.preventDefault();
    if (busyKey || !editingTunnelId) return;

    const isCreating = editingTunnelId === '__new__';
    const targetTun = isCreating ? null : editingExistingTun;
    const cleanName = formTunnelName.trim() || '自定义公网隧道';
    const cleanBaseUrl = formTunnelBaseUrl.trim();
    const cleanKey = formTunnelKey.trim();

    setBusyKey('pub_save');
    try {
      const res = await hostRpc('public_tunnel_item_save', {
        ...(isCreating ? {} : { tunnelId: targetTun?.Id || editingTunnelId }),
        name: cleanName,
        baseUrl: cleanBaseUrl,
        ...(cleanKey ? { startupKey: cleanKey } : {}),
        ...(formClearKey && !cleanKey ? { clearKey: true } : {}),
      });
      await syncFreshInfra(res);
      if (targetTun?.Id) {
        setRevealedPubSecrets((prev) => {
          const next = { ...prev };
          delete next[targetTun.Id];
          return next;
        });
      }
      resetTunnelForm();
      void hostRpc('set_unsaved_edits', { dirty: false }).catch(() => {});
      onToast(`✓ 已保存隧道配置「${cleanName}」`, 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleDeletePublicItem = async (tun: PublicTunnelItem) => {
    if (busyKey || tun.IsBuiltin) return;
    setConfirmDeleteTunnelId(null);
    resetTunnelForm();
    setBusyKey(`pub_rm_${tun.Id}`);
    try {
      const res = await hostRpc('public_tunnel_item_remove', { tunnelId: tun.Id });
      await syncFreshInfra(res);
      onToast(`已删除隧道「${tun.Name}」`, 'info');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleConnectPublicItem = async (tun: PublicTunnelItem) => {
    if (busyKey) return;
    setBusyKey(`pub_conn_${tun.Id}`);
    try {
      const res = await hostRpc('public_tunnel_item_connect', { tunnelId: tun.Id });
      const freshBundle = await syncFreshInfra(res);
      const afterTun = getEffectivePublicTunnels(freshBundle || infra).find(
        (t) => t.Id === tun.Id
      );
      if (afterTun?.Running === true) {
        onToast(`✓ 已连接「${afterTun.Name}」`, 'success');
      } else {
        onToast(
          afterTun?.ErrorReason || '隧道未能连通，请检查配置',
          'warning'
        );
      }
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleDisconnectPublicItem = async (tun: PublicTunnelItem) => {
    if (busyKey) return;
    setBusyKey(`pub_disc_${tun.Id}`);
    try {
      const res = await hostRpc('public_tunnel_item_disconnect', { tunnelId: tun.Id });
      await syncFreshInfra(res);
      onToast(`已断开「${tun.Name}」`, 'info');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handleCopyPubAddress = async (tun: PublicTunnelItem) => {
    const fullUrl = (
      tun.EffectiveUrl || (tun.BaseUrl ? formatMcpEndpoint(tun.BaseUrl) : '')
    ).trim();
    if (!fullUrl) {
      onToast('请先启动隧道以生成公网地址', 'warning');
      return;
    }
    try {
      await hostRpc('copy_clipboard', { text: fullUrl });
      markCopied(`pub_addr_${tun.Id}`);
      onToast('已复制公网 MCP 地址到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleToggleRevealPubKey = async (tun: PublicTunnelItem) => {
    if (revealedPubSecrets[tun.Id]) {
      setRevealedPubSecrets((prev) => {
        const next = { ...prev };
        delete next[tun.Id];
        return next;
      });
      return;
    }
    try {
      const res = await hostRpc<{ ok: boolean; secret: string }>(
        'public_tunnel_item_get_secret',
        { tunnelId: tun.Id }
      );
      const secret = String(res?.secret || '');
      if (!secret) {
        onToast('当前隧道未保存启动凭证 Key', 'warning');
        return;
      }
      setRevealedPubSecrets((prev) => ({ ...prev, [tun.Id]: secret }));
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleCopyPubKey = async (tun: PublicTunnelItem) => {
    try {
      const res = await hostRpc<{ ok: boolean; secret: string }>(
        'public_tunnel_item_get_secret',
        { tunnelId: tun.Id }
      );
      const secret = String(res?.secret || '');
      if (!secret) {
        onToast('当前隧道未保存启动凭证 Key', 'warning');
        return;
      }
      await hostRpc('copy_clipboard', { text: secret });
      markCopied(`pub_key_${tun.Id}`);
      onToast('已复制启动凭证 Key 到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const handleTabListKeyDown = (e: KeyboardEvent) => {
    if (
      e.key !== 'ArrowLeft' &&
      e.key !== 'ArrowRight' &&
      e.key !== 'Home' &&
      e.key !== 'End'
    ) {
      return;
    }
    e.preventDefault();
    let nextTab: GlobalSettingsTab = activeSettingsTab;
    if (e.key === 'Home') {
      nextTab = 'general';
    } else if (e.key === 'End') {
      nextTab = 'tunnels';
    } else {
      nextTab = activeSettingsTab === 'general' ? 'tunnels' : 'general';
    }
    if (nextTab !== activeSettingsTab) {
      onChangeSettingsTab(nextTab);
      window.requestAnimationFrame(() => {
        if (nextTab === 'general') {
          generalTabRef.current?.focus();
        } else {
          tunnelsTabRef.current?.focus();
        }
      });
    }
  };

  const renderInlinePublicTunnelForm = (targetTun: PublicTunnelItem | null) => {
    const idPrefix = targetTun ? `gs-pub-${targetTun.Id}` : 'gs-pub-new';
    const canDelete = Boolean(targetTun && !targetTun.IsBuiltin);
    const isDetectingTs = busyKey === 'detect_ts';

    return (
      <form
        className="th-inline-form gs-pub-form"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => void handleSavePublicItem(e)}
      >
        <div className="th-form-grid">
          <div className="th-field">
            <label className="th-field-label" htmlFor={`${idPrefix}-name`}>
              隧道名称
            </label>
            <input
              id={`${idPrefix}-name`}
              name="name"
              type="text"
              className="th-input"
              required
              placeholder="我的 Tailscale / Cloudflare 专线"
              value={formTunnelName}
              onInput={(e) => setFormTunnelName((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          <div className="th-field">
            <div className="gs-field-label-row">
              <label className="th-field-label" htmlFor={`${idPrefix}-url`}>
                公网网址（选填）
              </label>
              <button
                type="button"
                className="gs-link-action"
                disabled={Boolean(busyKey)}
                onClick={() => void handleDetectTailscale()}
              >
                {isDetectingTs ? '检测中…' : '填入本机 Tailscale'}
              </button>
            </div>
            <input
              id={`${idPrefix}-url`}
              name="baseUrl"
              type="text"
              className="th-input mono"
              autocorrect="off"
              autocapitalize="none"
              spellcheck={false}
              placeholder="留空使用免费临时隧道；或填 https://域名"
              value={formTunnelBaseUrl}
              onInput={(e) => setFormTunnelBaseUrl((e.currentTarget as HTMLInputElement).value)}
            />
          </div>

          <div className="th-field">
            <div className="gs-field-label-row">
              <label className="th-field-label" htmlFor={`${idPrefix}-key`}>
                启动凭证 Key（选填）
              </label>
              {targetTun?.HasKey && (
                formClearKey ? (
                  <span className="gs-key-clear-state">
                    <span>保存后将清空已存 Key</span>
                    <button
                      type="button"
                      className="gs-link-action"
                      onClick={() => setFormClearKey(false)}
                    >
                      撤销
                    </button>
                  </span>
                ) : (
                  <button
                    type="button"
                    className="gs-link-action is-muted"
                    onClick={() => {
                      setFormClearKey(true);
                      setFormTunnelKey('');
                    }}
                  >
                    清空已存 Key
                  </button>
                )
              )}
            </div>
            <input
              id={`${idPrefix}-key`}
              name="startupKey"
              type="password"
              className="th-input mono th-secret-input"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="none"
              spellcheck={false}
              placeholder={
                formClearKey
                  ? '已标记清空原 Key；也可粘贴新 Key 覆盖'
                  : targetTun?.HasKey
                    ? '已加密保存 Key，留空保持原凭证不变'
                    : '仅 Cloudflare 等需本软件拉起的专线填写；其余留空'
              }
              value={formTunnelKey}
              onInput={(e) => {
                const v = (e.currentTarget as HTMLInputElement).value;
                setFormTunnelKey(v);
                if (v.trim().length > 0 && formClearKey) {
                  setFormClearKey(false);
                }
              }}
            />
          </div>
        </div>

        <div className="th-form-actions">
          <div>
            {canDelete && targetTun && (
              confirmDeleteTunnelId === targetTun.Id ? (
                <button
                  type="button"
                  className="th-danger-link is-confirm"
                  disabled={Boolean(busyKey)}
                  onClick={() => void handleDeletePublicItem(targetTun)}
                >
                  确认删除此隧道?
                </button>
              ) : (
                <button
                  type="button"
                  className="th-danger-link"
                  disabled={Boolean(busyKey)}
                  onClick={() => setConfirmDeleteTunnelId(targetTun.Id)}
                >
                  删除此隧道
                </button>
              )
            )}
          </div>

          <div className="th-form-actions-right">
            <button
              type="button"
              className="th-btn th-btn-secondary"
              onClick={() => resetTunnelForm()}
            >
              取消
            </button>
            <button
              type="submit"
              className="th-btn th-btn-primary"
              disabled={Boolean(busyKey)}
            >
              {busyKey === 'pub_save' ? '保存中…' : '保存配置'}
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
      width={480}
      className="global-settings-popover"
      onClose={onClose}
    >
      <div className="gs-root">
        {/* Header: Title on left, Segmented 2-Tab Switcher, Close on right */}
        <div className="gs-header">
          <div className="gs-header-title">⚙ 设置</div>

          <div
            className="gs-seg-tablist"
            role="tablist"
            aria-label="设置分类"
            onKeyDown={handleTabListKeyDown}
          >
            <button
              ref={generalTabRef}
              id="gs-tab-general"
              type="button"
              role="tab"
              className="gs-seg-tab"
              aria-selected={activeSettingsTab === 'general'}
              tabIndex={activeSettingsTab === 'general' ? 0 : -1}
              onClick={() => onChangeSettingsTab('general')}
            >
              常规设置
            </button>
            <button
              ref={tunnelsTabRef}
              id="gs-tab-tunnels"
              type="button"
              role="tab"
              className="gs-seg-tab"
              aria-selected={activeSettingsTab === 'tunnels'}
              tabIndex={activeSettingsTab === 'tunnels' ? 0 : -1}
              onClick={() => onChangeSettingsTab('tunnels')}
            >
              隧道与连接
            </button>
          </div>

          <button
            type="button"
            className="th-close-icon-btn"
            aria-label="关闭设置"
            title="关闭"
            onClick={onClose}
          >
            ×
          </button>
        </div>

        {/* ==================== Tab 1: 常规设置 ==================== */}
        <div
          role="tabpanel"
          aria-labelledby="gs-tab-general"
          hidden={activeSettingsTab !== 'general'}
        >
          <div className="gs-panel-stack">
            {/* Group 1: 任务与网页接力 */}
            <div className="gs-section-card">
              <div className="gs-section-heading">任务与网页接力</div>

              {/* 新建任务默认载体 */}
              <div className="gs-row gs-row-inline">
                <label className="gs-label" htmlFor="gs-default-carrier-select">
                  新建任务默认载体
                </label>
                <select
                  id="gs-default-carrier-select"
                  name="defaultCarrier"
                  className="gs-carrier-select"
                  value={eng.DefaultBrowserProfile || carrierOptions[0]?.Id || 'Chrome:Default'}
                  onChange={(e) => {
                    const val = (e.currentTarget as HTMLSelectElement).value;
                    const label =
                      carrierOptions.find((c) => c.Id === val)?.Label || val;
                    void postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
                      action: 'set_global_settings',
                      default_browser_profile: val,
                      default_carrier: val,
                    })
                      .then(() => onRefreshSnapshot())
                      .catch(() => {});
                    void runHostTask(
                      'default_carrier',
                      () =>
                        hostRpc('save_engine_config', {
                          defaultBrowserProfile: val,
                          DefaultBrowserProfile: val,
                        }),
                      `新建任务默认载体已设为「${label}」`
                    );
                  }}
                >
                  {carrierOptions.map((c) => (
                    <option key={c.Id} value={c.Id}>
                      {c.Label}
                    </option>
                  ))}
                </select>
              </div>

              {/* 浏览器控制 */}
              <div className="gs-row gs-row-inline">
                <div className="gs-label-stack">
                  <span id="gs-browser-ctrl-label" className="gs-label">
                    浏览器控制
                  </span>
                  <span id="gs-browser-ctrl-desc" className="gs-label-desc">
                    允许 AI 自动打开浏览器查看网页（不影响消息接力）
                  </span>
                </div>
                <div
                  className="gs-pill-group gs-pill-compact"
                  role="group"
                  aria-labelledby="gs-browser-ctrl-label"
                  aria-describedby="gs-browser-ctrl-desc"
                >
                  <button
                    type="button"
                    className={`gs-pill-btn ${effectiveBrowserEnabled ? 'is-active' : ''}`}
                    aria-pressed={effectiveBrowserEnabled}
                    onClick={() => void handleSetBrowserControl(true)}
                  >
                    开启
                  </button>
                  <button
                    type="button"
                    className={`gs-pill-btn ${!effectiveBrowserEnabled ? 'is-active' : ''}`}
                    aria-pressed={!effectiveBrowserEnabled}
                    onClick={() => void handleSetBrowserControl(false)}
                  >
                    关闭
                  </button>
                </div>
              </div>

              {/* 已完工任务自动归档 */}
              <div className="gs-row">
                <div className="gs-label">已完工任务自动归档</div>
                <div className="gs-pill-group">
                  {AUTO_ARCHIVE_OPTIONS.map((opt) => {
                    const isActive = autoArchiveVal === opt.value;
                    return (
                      <button
                        key={opt.value}
                        type="button"
                        className={`gs-pill-btn ${isActive ? 'is-active' : ''}`}
                        disabled={Boolean(busyKey)}
                        onClick={() => {
                          if (isActive) return;
                          void postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
                            action: 'set_global_settings',
                            auto_archive_completed_mode: opt.value,
                          })
                            .then(() => onRefreshSnapshot())
                            .catch(() => {});
                          void runHostTask(
                            'auto_archive',
                            () =>
                              hostRpc('save_engine_config', {
                                autoArchiveCompletedMode: opt.value,
                                AutoArchiveCompletedMode: opt.value,
                              }),
                            `已将完工自动归档设为「${opt.toastLabel}」`
                          );
                        }}
                      >
                        {opt.label}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Group 2: 本地命令行智能体 */}
            <div className="gs-section-card">
              <div className="gs-section-heading">本地命令行智能体</div>

              {/* 默认 CLI 智能体 */}
              <div className="gs-row">
                <div className="gs-row-head">
                  <span className="gs-label">默认 CLI 智能体</span>
                  <div className="gs-mini-actions">
                    <button
                      type="button"
                      className="gs-link-action"
                      disabled={Boolean(busyKey)}
                      onClick={() =>
                        void runHostTask(
                          'pick_cli',
                          () => hostRpc('pick_and_add_cli_agent'),
                          '已添加并切换自定义 CLI 智能体'
                        )
                      }
                    >
                      + 添加...
                    </button>
                    <button
                      type="button"
                      className="gs-link-action"
                      disabled={Boolean(busyKey)}
                      onClick={() =>
                        void runHostTask(
                          'rescan_cli',
                          () => hostRpc('rescan_cli_agents'),
                          '已重新扫描本机安装的 CLI 智能体',
                          'info'
                        )
                      }
                    >
                      {busyKey === 'rescan_cli' ? '检测中…' : '↻ 重新检测'}
                    </button>
                  </div>
                </div>

                <div className="gs-pill-group gs-pill-wrap">
                  {cliList.map((ag) => {
                    const isActive = ag.id.toLowerCase() === currentCliId.toLowerCase();
                    return (
                      <button
                        key={ag.id}
                        type="button"
                        className={`gs-pill-btn ${isActive ? 'is-active' : ''}`}
                        title={ag.command ? `${ag.display_name} (${ag.command})` : ag.display_name}
                        disabled={Boolean(busyKey)}
                        onClick={() => {
                          if (isActive) return;
                          void runHostTask(
                            'cli_default',
                            () =>
                              hostRpc('save_engine_config', {
                                acpDefaultProfile: ag.id,
                                AcpDefaultProfile: ag.id,
                              }),
                            `默认 CLI 智能体已切换为「${ag.display_name}」`
                          );
                        }}
                      >
                        {ag.display_name}
                      </button>
                    );
                  })}
                </div>
              </div>

              {/* CLI 智能体并发上限 */}
              <div className="gs-row">
                <div className="gs-label">
                  CLI 智能体并发上限
                  <span className="gs-label-sub">
                    （当前：{concurrencyVal <= 0 ? '已关闭' : `${concurrencyVal} 并发`}）
                  </span>
                </div>
                <div className="gs-pill-group">
                  {CLI_CONCURRENCY_OPTIONS.map((opt) => {
                    const isActive = concurrencyVal === opt.value;
                    return (
                      <button
                        key={opt.value}
                        type="button"
                        className={`gs-pill-btn ${isActive ? 'is-active' : ''}`}
                        disabled={Boolean(busyKey)}
                        onClick={() => {
                          if (isActive) return;
                          void runHostTask(
                            'cli_concurrency',
                            () =>
                              hostRpc('save_engine_config', {
                                acpMaxConcurrentPrompts: opt.value,
                                AcpMaxConcurrentPrompts: opt.value,
                              }),
                            opt.value === 0
                              ? '已关闭本地 CLI 智能体并发派发'
                              : `已将 CLI 智能体并发上限设为 ${opt.value}`
                          );
                        }}
                      >
                        {opt.label}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Group 3: 界面与系统启动 */}
            <div className="gs-section-card">
              <div className="gs-section-heading">界面与系统启动</div>

              {/* 界面外观主题 (`Ctrl+Shift+D`) */}
              <div className="gs-row">
                <div className="gs-row-head">
                  <span className="gs-label">界面外观主题</span>
                  <span className="gs-shortcut-hint">Ctrl+Shift+D</span>
                </div>
                <div className="gs-pill-group">
                  <button
                    type="button"
                    className={`gs-pill-btn ${themeMode === 'system' ? 'is-active' : ''}`}
                    title={`当前系统外观：${systemTheme === 'dark' ? '深色' : '浅色'}`}
                    onClick={() => onSetThemeMode('system')}
                  >
                    跟随系统
                  </button>
                  <button
                    type="button"
                    className={`gs-pill-btn ${themeMode === 'light' ? 'is-active' : ''}`}
                    onClick={() => onSetThemeMode('light')}
                  >
                    ☀ 浅色
                  </button>
                  <button
                    type="button"
                    className={`gs-pill-btn ${themeMode === 'dark' ? 'is-active' : ''}`}
                    onClick={() => onSetThemeMode('dark')}
                  >
                    🌙 深色
                  </button>
                </div>
              </div>

              {/* 开机自动启动方式 */}
              <div className="gs-row">
                <div className="gs-label">开机自动启动方式</div>
                <div className="gs-pill-group">
                  {STARTUP_OPTIONS.map((opt) => {
                    const isActive = startupVal === opt.value;
                    return (
                      <button
                        key={opt.value}
                        type="button"
                        className={`gs-pill-btn ${isActive ? 'is-active' : ''}`}
                        disabled={Boolean(busyKey)}
                        onClick={() => {
                          if (isActive) return;
                          void runHostTask(
                            'startup_mode',
                            () =>
                              hostRpc('save_engine_config', {
                                startupMode: opt.value,
                                StartupMode: opt.value,
                              }),
                            opt.toast,
                            opt.value === 'off' ? 'info' : 'success'
                          );
                        }}
                      >
                        {opt.label}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Footer 3 Equal Buttons */}
            <div className="gs-footer-row">
              <button
                type="button"
                className="th-btn th-btn-secondary"
                disabled={Boolean(busyKey)}
                onClick={() => {
                  setBusyKey('reset_layout');
                  void hostRpc('reset_layout')
                    .then(async (res) => {
                      const freshBundle = await syncFreshInfra(res);
                      onResetLayoutDone(freshBundle);
                    })
                    .catch((err) => {
                      onToast(err instanceof Error ? err.message : String(err), 'error');
                    })
                    .finally(() => setBusyKey(null));
                }}
              >
                恢复默认尺寸
              </button>

              <button
                type="button"
                className="th-btn th-btn-secondary"
                disabled={Boolean(busyKey)}
                onClick={() => {
                  void hostRpc('open_workspace_folder', {}).catch((err) => {
                    onToast(err instanceof Error ? err.message : String(err), 'error');
                  });
                }}
              >
                打开本地
              </button>

              <button
                type="button"
                className="th-btn th-btn-secondary"
                disabled={Boolean(busyKey)}
                onClick={() => {
                  void (async () => {
                    try {
                      await hostRpc('open_browser_bridge_dir');
                      await hostRpc('copy_clipboard', { text: 'chrome://extensions' });
                      onToast('已打开扩展目录，并复制 chrome://extensions', 'info');
                    } catch (err) {
                      onToast(err instanceof Error ? err.message : String(err), 'error');
                    }
                  })();
                }}
              >
                浏览器扩展
              </button>
            </div>
          </div>
        </div>

        {/* ==================== Tab 2: 隧道与连接 ==================== */}
        <div
          role="tabpanel"
          aria-labelledby="gs-tab-tunnels"
          hidden={activeSettingsTab !== 'tunnels'}
        >
          <div className="gs-panel-stack">
            {/* Upper Section: 本机核心与专属通道 */}
            <div className="gs-section-card gs-overview-card">
              <div className="gs-section-heading">本机核心与专属通道</div>

              {/* Row 1: 本地引擎内核 */}
              <div className="gs-overview-row">
                <div className="gs-overview-left" title={coreRawText}>
                  <span
                    className={`gs-status-dot ${coreHealthy ? 'is-ok' : 'is-fault'}`}
                  />
                  <span className="gs-overview-title">本地引擎内核</span>
                  <span className={`gs-overview-meta ${coreHealthy ? 'is-ok' : 'is-fault'}`}>
                    {coreHealthy ? '运行中' : '未启动'}
                  </span>
                </div>
                <button
                  type="button"
                  className="th-btn th-btn-secondary gs-compact-btn"
                  disabled={Boolean(busyKey)}
                  onClick={() =>
                    void runHostTask(
                      'restart_core',
                      () => hostRpc('restart_core'),
                      '✓ 本地 RelayStudio 内核已重启并就绪'
                    )
                  }
                >
                  {busyKey === 'restart_core' ? '重启中…' : '↻ 重启内核'}
                </button>
              </div>

              <div className="gs-divider" />

              {/* Row 2: ChatGPT 专属隧道 */}
              <div className="gs-overview-row">
                <div className="gs-overview-left">
                  <span
                    className={`gs-status-dot ${
                      chatgptFault ? 'is-fault' : chatgptRunning ? 'is-ok' : 'is-off'
                    }`}
                  />
                  <span className="gs-overview-title">ChatGPT 专属隧道</span>
                  <span
                    className={`gs-overview-meta ${
                      chatgptFault ? 'is-fault' : chatgptRunning ? 'is-ok' : ''
                    }`}
                  >
                    {chatgptFault
                      ? `${chatgptProfileName} · 异常`
                      : chatgptRunning
                        ? `${chatgptProfileName} · 运行中`
                        : '未连接'}
                  </span>
                </div>
                <button
                  type="button"
                  className="gs-quiet-nav-btn"
                  onClick={onNavigateToChatGptTunnel}
                >
                  去配置 →
                </button>
              </div>
            </div>

            {/* Lower Section: 公网隧道（供 Gemini · Claude 共用） */}
            <div className="gs-section-card gs-pub-section">
              <div className="gs-pub-section-head">
                <div className="gs-pub-section-title-wrap">
                  <span className="gs-section-heading">
                    {`公网隧道 (${publicTunnels.length})`}
                  </span>
                  <span className="gs-pub-section-sub">供 Gemini · Claude 共用</span>
                </div>

                <button
                  type="button"
                  className={`th-add-prof-btn ${editingTunnelId === '__new__' ? 'is-open' : ''}`}
                  onClick={openAddTunnelForm}
                >
                  {editingTunnelId === '__new__' ? '取消新增' : '+ 新增隧道'}
                </button>
              </div>

              <div className="gs-pub-cards-list">
                {editingTunnelId === '__new__' && (
                  <div className="gs-pub-card is-editing">
                    <div className="gs-pub-card-top">
                      <div className="gs-pub-card-title-wrap">
                        <span className="gs-status-dot is-accent" />
                        <span className="gs-pub-card-name">新增公网隧道</span>
                        <span className="th-strip-badge is-selected">新建草稿</span>
                      </div>
                      <button
                        type="button"
                        className="th-inline-toggle-btn"
                        onClick={resetTunnelForm}
                      >
                        收起 ▴
                      </button>
                    </div>
                    {renderInlinePublicTunnelForm(null)}
                  </div>
                )}

                {publicTunnels.map((tun) => {
                  const isHighlighted = highlightedTunnelId === tun.Id;
                  const isEditingThis = editingTunnelId === tun.Id;
                  const isConnectingThis = busyKey === `pub_conn_${tun.Id}`;
                  const isDisconnectingThis = busyKey === `pub_disc_${tun.Id}`;
                  const phaseLower = (tun.HealthPhase || '').toLowerCase();
                  const hasError = Boolean(!tun.Running && tun.ErrorReason);

                  const dotClass = tun.Running
                    ? phaseLower === 'fault'
                      ? 'is-fault'
                      : phaseLower === 'degraded' || phaseLower === 'connecting'
                        ? 'is-warn'
                        : 'is-ok'
                    : hasError
                      ? 'is-fault'
                      : 'is-off';

                  const usedByBadge = formatUsedByBadge(tun.UsedByPlatforms);
                  const addrText =
                    tun.EffectiveUrl ||
                    (tun.BaseUrl
                      ? formatMcpEndpoint(tun.BaseUrl)
                      : '启动后自动分配免费临时地址');
                  const copyableUrl = (
                    tun.EffectiveUrl || (tun.BaseUrl ? formatMcpEndpoint(tun.BaseUrl) : '')
                  ).trim();
                  const addrCopied = Boolean(copiedFlags[`pub_addr_${tun.Id}`]);
                  const keyCopied = Boolean(copiedFlags[`pub_key_${tun.Id}`]);
                  const revealedKey = revealedPubSecrets[tun.Id];

                  return (
                    <div
                      key={tun.Id}
                      ref={(el) => {
                        cardRefs.current[tun.Id] = el;
                      }}
                      className={[
                        'gs-pub-card',
                        tun.Running ? 'is-running' : '',
                        hasError ? 'has-error' : '',
                        isHighlighted ? 'is-highlighted' : '',
                      ]
                        .filter(Boolean)
                        .join(' ')}
                    >
                      {/* Top Row */}
                      <div className="gs-pub-card-top">
                        <div className="gs-pub-card-title-wrap">
                          <span className={`gs-status-dot ${dotClass}`} />
                          <span className="gs-pub-card-name" title={tun.Name}>
                            {tun.Name}
                          </span>
                          <span
                            className={`th-strip-badge ${
                              tun.Running ? 'is-active' : 'is-muted'
                            }`}
                          >
                            {tun.Running ? '运行中' : '未启动'}
                          </span>
                          {usedByBadge && (
                            <span className="th-strip-badge is-usage">
                              {usedByBadge}
                            </span>
                          )}
                        </div>

                        <div className="gs-pub-card-actions">
                          {!tun.Running ? (
                            <button
                              type="button"
                              className="th-btn th-btn-primary gs-card-btn"
                              disabled={Boolean(busyKey)}
                              onClick={() => void handleConnectPublicItem(tun)}
                            >
                              {isConnectingThis ? '连接中…' : '启动'}
                            </button>
                          ) : (
                            <>
                              <button
                                type="button"
                                className="th-btn th-btn-secondary gs-card-btn"
                                disabled={Boolean(busyKey)}
                                onClick={() => void handleConnectPublicItem(tun)}
                              >
                                {isConnectingThis ? '连接中…' : '重连'}
                              </button>
                              <button
                                type="button"
                                className="th-btn th-btn-secondary gs-card-btn"
                                disabled={Boolean(busyKey)}
                                onClick={() => void handleDisconnectPublicItem(tun)}
                              >
                                {isDisconnectingThis ? '断开中…' : '断开'}
                              </button>
                            </>
                          )}

                          {!tun.IsBuiltin && (
                            <button
                              type="button"
                              className="th-inline-toggle-btn"
                              aria-expanded={isEditingThis}
                              onClick={() => openEditTunnelForm(tun)}
                            >
                              {isEditingThis ? '收起 ▴' : '✎ 编辑 ▾'}
                            </button>
                          )}
                        </div>
                      </div>

                      {/* Second Row: Address + Optional Startup Key */}
                      <div className="gs-pub-card-meta">
                        <span className="gs-pub-meta-seg gs-pub-addr-seg">
                          <span className="gs-pub-meta-prefix">地址:</span>
                          <span
                            className="gs-pub-addr-val truncate-1"
                            title={copyableUrl || addrText}
                          >
                            {addrText}
                          </span>
                          <button
                            type="button"
                            className={`th-link-btn ${addrCopied ? 'is-copied' : ''}`}
                            onClick={() => void handleCopyPubAddress(tun)}
                          >
                            {addrCopied ? '✓ 已复制' : '复制'}
                          </button>
                        </span>

                        {tun.HasKey && (
                          <>
                            <span className="th-meta-sep">·</span>
                            <span className="gs-pub-meta-seg">
                              <span className="th-key-val">
                                {`Key: ${revealedKey || tun.MaskedKey || '已配置'}`}
                              </span>
                              <button
                                type="button"
                                className="th-link-btn"
                                onClick={() => void handleToggleRevealPubKey(tun)}
                              >
                                {revealedKey ? '隐藏' : '显示完整'}
                              </button>
                              <button
                                type="button"
                                className={`th-link-btn ${keyCopied ? 'is-copied' : ''}`}
                                onClick={() => void handleCopyPubKey(tun)}
                              >
                                {keyCopied ? '✓ 已复制' : '复制'}
                              </button>
                            </span>
                          </>
                        )}
                      </div>

                      {/* Honest Inline Error Strip */}
                      {hasError && (
                        <div className="gs-pub-error-strip" role="alert">
                          <span className="gs-pub-error-icon" aria-hidden="true">
                            ⚠
                          </span>
                          <span className="gs-pub-error-text selectable-copy">
                            {tun.ErrorReason}
                          </span>
                        </div>
                      )}

                      {/* Inline Edit Form (Custom Tunnels Only) */}
                      {isEditingThis && !tun.IsBuiltin && renderInlinePublicTunnelForm(tun)}
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        </div>
      </div>
    </AnchoredPopover>
  );
}
