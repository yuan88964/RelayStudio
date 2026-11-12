import { useRef, useState } from 'preact/hooks';
import type {
  AutoArchiveMode,
  CliAgentOption,
  EffectiveTheme,
  HostInfraBundle,
  ThemeMode,
} from '../types/contracts';
import { extractInfraBundle, hostRpc } from '../services/hostBridge';
import { postStudioAction } from '../services/studioHub';
import { AnchoredPopover } from './AnchoredPopover';

export interface GlobalSettingsPopoverProps {
  open: boolean;
  anchorEl: HTMLElement | null;
  infra: HostInfraBundle;
  themeMode: ThemeMode;
  systemTheme: EffectiveTheme;
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

export function GlobalSettingsPopover({
  open,
  anchorEl,
  infra,
  themeMode,
  systemTheme,
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

  const eng = infra.engineConfig || {
    CorePort: 8765,
    AcpDefaultProfile: 'codex',
    AcpMaxConcurrentPrompts: 4,
    BrowserEnabled: true,
    StartupMode: 'tray',
    AutoArchiveCompletedMode: '3d',
    DefaultBrowserProfile: 'Chrome:Default',
  };

  const coreText =
    infra.display?.Core || `运行中 (127.0.0.1:${eng.CorePort || 8765})`;
  const coreHealthy = !/未启动|离线|异常|失败|fault/i.test(coreText);

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

  const syncFreshInfra = async (maybeRes?: any) => {
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

  return (
    <AnchoredPopover
      open={open}
      anchorEl={anchorEl}
      align="end"
      width={460}
      className="global-settings-popover"
      onClose={onClose}
    >
      <div className="gs-root">
        {/* Header */}
        <div className="gs-header">
          <div className="gs-header-title">⚙ 通用与本地引擎设置</div>
          <button
            type="button"
            className="th-close-icon-btn"
            aria-label="关闭全局设置"
            title="关闭"
            onClick={onClose}
          >
            ×
          </button>
        </div>

        {/* Settings Card Body */}
        <div className="gs-body-box">
          {/* 1. 本地内核状态 */}
          <div className="gs-row gs-row-inline">
            <div className="gs-core-status">
              <span className={`gs-core-dot ${coreHealthy ? 'is-ok' : 'is-warn'}`} />
              <span className="gs-core-label">本地内核：{coreText}</span>
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

          {/* 2. 已完工任务自动归档 */}
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

          {/* 3. 新建任务默认载体 */}
          <div className="gs-row gs-row-inline">
            <label className="gs-label" htmlFor="gs-default-carrier-select">
              新建任务默认载体
            </label>
            <select
              id="gs-default-carrier-select"
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

          {/* 4. CLI 智能体并发上限 */}
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

          {/* 5. 默认 CLI 智能体 */}
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

          {/* 6. 浏览器控制 */}
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

          <div className="gs-divider" />

          {/* 7. 开机自动启动方式 */}
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

          {/* 8. 界面外观主题 (`Ctrl+Shift+D`) */}
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
        </div>

        {/* 9. 底部工具行 (3 Equal Buttons) */}
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
    </AnchoredPopover>
  );
}
