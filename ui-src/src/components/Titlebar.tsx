import type { HostInfraBundle, PlatformId } from '../types/contracts';
import { hostRpc, resolveBoundPublicTunnel } from '../services/hostBridge';
import { normalizePlatformId } from '../utils/formatters';

export type TunnelHubTab = 'chatgpt' | 'gemini' | 'claude' | 'add';

export interface TitlebarProps {
  infra: HostInfraBundle;
  railCollapsed: boolean;
  windowMaximized: boolean;
  activePopover: 'tunnel' | 'settings' | null;
  activeTunnelTab: TunnelHubTab;
  firstCapsuleRef?: { current: HTMLElement | null };
  settingsBtnRef?: { current: HTMLElement | null };
  capsuleRefsByPlat?: { current: Partial<Record<PlatformId, HTMLElement | null>> };
  onToggleRail: () => void;
  onQuickToggleTheme: () => void;
  onResetSystemTheme: () => void;
  onOpenTunnelHub: (tab: TunnelHubTab, anchorEl: HTMLElement) => void;
  onOpenSettings: (anchorEl: HTMLElement) => void;
}

const ORDERED_PLATFORMS: PlatformId[] = ['chatgpt', 'gemini', 'claude'];

export function Titlebar({
  infra,
  railCollapsed,
  windowMaximized,
  activePopover,
  activeTunnelTab,
  firstCapsuleRef,
  settingsBtnRef,
  capsuleRefsByPlat,
  onToggleRail,
  onQuickToggleTheme,
  onResetSystemTheme,
  onOpenTunnelHub,
  onOpenSettings,
}: TitlebarProps) {
  const rawEnabled = infra.profiles?.EnabledPlatforms || ['chatgpt'];
  const enabledSet = new Set<PlatformId>(
    rawEnabled.map((p) => normalizePlatformId(p))
  );
  if (enabledSet.size === 0) enabledSet.add('chatgpt');

  const enabledPlatforms = ORDERED_PLATFORMS.filter((p) => enabledSet.has(p));

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
  const targetChatgptId = infra.display?.Running
    ? infra.display?.RunningProfileId || selectedChatgptId
    : selectedChatgptId;
  const activeChatgptProfile =
    chatgptProfiles.find((p) => p.Id === targetChatgptId) || chatgptProfiles[0];
  const chatgptProfileName = activeChatgptProfile?.Name || '未配置';

  const effectiveTheme = infra.effectiveTheme || 'light';
  const themeMode = infra.themeMode || 'system';
  const currentThemeDesc =
    themeMode === 'system'
      ? `跟随系统（当前${effectiveTheme === 'dark' ? '深色' : '浅色'}）`
      : themeMode === 'dark'
        ? '深色模式'
        : '浅色模式';
  const targetThemeDesc = effectiveTheme === 'dark' ? '浅色模式' : '深色模式';
  const themeTooltip = `当前主题：${currentThemeDesc}\n左键点击（或 Ctrl+Shift+D）：一键切换为「${targetThemeDesc}」\n右键点击：恢复「跟随系统」`;

  const renderPlatformSegment = (plat: PlatformId, idx: number) => {
    const isSelected = activePopover === 'tunnel' && activeTunnelTab === plat;

    if (plat === 'chatgpt') {
      const running = Boolean(infra.display?.Running);
      const isFault = Boolean(infra.display?.IsFault);
      const dotColor = isFault ? '#DC2626' : running ? '#16A34A' : '#A1A1AA';

      return (
        <button
          key={plat}
          ref={(el) => {
            if (idx === 0 && firstCapsuleRef) {
              firstCapsuleRef.current = el;
            }
            if (capsuleRefsByPlat) {
              capsuleRefsByPlat.current[plat] = el;
            }
          }}
          type="button"
          className={`capsule-seg-btn ${isSelected ? 'active' : ''}`}
          aria-expanded={isSelected}
          title="点击打开「ChatGPT 隧道配置」切换隧道或管理 API Key"
          onClick={(e) => onOpenTunnelHub('chatgpt', e.currentTarget as HTMLElement)}
        >
          <span className="status-dot" style={{ backgroundColor: dotColor }} />
          <span>{`ChatGPT · ${chatgptProfileName} ▾`}</span>
        </button>
      );
    }

    const platName = plat === 'gemini' ? 'Gemini' : 'Claude';
    const { boundTun } = resolveBoundPublicTunnel(infra, plat);
    const pubRunning = Boolean(boundTun?.Running);
    const phase = (boundTun?.HealthPhase || '').toLowerCase();
    const dotColor = !pubRunning
      ? '#A1A1AA'
      : phase === 'fault'
        ? '#DC2626'
        : phase === 'degraded' || phase === 'connecting'
          ? '#D97706'
          : '#16A34A';

    const capsuleLabel = `${platName} · ${boundTun?.Name || '免费临时隧道'} ▾`;
    const rttMs = Math.round(Number(boundTun?.PublicRttMs) || 0);
    const pubRttTip = pubRunning
      ? rttMs > 0
        ? `运行中 (${rttMs}ms)`
        : '公网隧道运行中'
      : '公网隧道未启动';

    return (
      <button
        key={plat}
        ref={(el) => {
          if (idx === 0 && firstCapsuleRef) {
            firstCapsuleRef.current = el;
          }
          if (capsuleRefsByPlat) {
            capsuleRefsByPlat.current[plat] = el;
          }
        }}
        type="button"
        className={`capsule-seg-btn ${isSelected ? 'active' : ''}`}
        aria-expanded={isSelected}
        title={`点击打开「${platName} 隧道配置」 · ${pubRttTip}`}
        onClick={(e) => onOpenTunnelHub(plat, e.currentTarget as HTMLElement)}
      >
        <span className="status-dot" style={{ backgroundColor: dotColor }} />
        <span>{capsuleLabel}</span>
      </button>
    );
  };

  return (
    <header className="titlebar">
      <div className="titlebar-left">
        {/* 1. Brand Badge + Title */}
        <div className="brand-cluster">
          <span className="brand-badge" aria-hidden="true">
            R
          </span>
          <span className="brand-title">RelayStudio</span>
        </div>

        {/* 2. ToggleRailButton (`28x28` quiet icon button) */}
        <button
          type="button"
          className={`quiet-icon-btn ${railCollapsed ? '' : 'active'}`}
          aria-label="展开或收起左侧任务栏"
          title="展开 / 收起左侧任务栏（不改变窗口外框大小，也可向左拖拽竖线自动吸附隐藏）"
          onClick={onToggleRail}
        >
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <path d="M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z" />
            <path d="M9 4v16" />
          </svg>
        </button>

        {/* 3. ThemeToggleButton: Moon SVG in Light mode, Sun SVG in Dark mode (`#L1327-L1331`) */}
        <button
          type="button"
          className="quiet-icon-btn"
          aria-label="切换深浅色主题"
          title={themeTooltip}
          onClick={onQuickToggleTheme}
          onContextMenu={(e) => {
            e.preventDefault();
            onResetSystemTheme();
          }}
        >
          {effectiveTheme === 'dark' ? (
            <svg width="13.5" height="13.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="5" />
              <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
            </svg>
          ) : (
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
            </svg>
          )}
        </button>

        {/* 4. 14px Spacer + GlobalSettingsButton (`⚙`) */}
        <div className="titlebar-settings-spacer" />
        <button
          ref={(el) => {
            if (settingsBtnRef) {
              settingsBtnRef.current = el;
            }
          }}
          type="button"
          className={`quiet-icon-btn titlebar-settings-btn ${activePopover === 'settings' ? 'active' : ''}`}
          aria-label="设置"
          aria-expanded={activePopover === 'settings'}
          title="设置（常规设置、本地内核与公网隧道管理）"
          onClick={(e) => onOpenSettings(e.currentTarget as HTMLElement)}
        >
          <svg aria-hidden="true" width="13.5" height="13.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <path d="M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </button>

        {/* 5. Segmented TunnelCapsuleBorder (`border-radius: 8px`) */}
        <div className="capsule-bar">
          {enabledPlatforms.map((plat, idx) => (
            <span key={plat} style={{ display: 'inline-flex', alignItems: 'center' }}>
              {idx > 0 && <span className="capsule-divider" aria-hidden="true" />}
              {renderPlatformSegment(plat, idx)}
            </span>
          ))}
          {enabledPlatforms.length < 3 && (
            <>
              <span className="capsule-divider" aria-hidden="true" />
              <button
                type="button"
                className={`capsule-add-btn ${activePopover === 'tunnel' && activeTunnelTab === 'add' ? 'active' : ''}`}
                aria-label="添加或管理平台配置分栏"
                aria-expanded={activePopover === 'tunnel' && activeTunnelTab === 'add'}
                title="添加或管理平台配置分栏"
                onClick={(e) => onOpenTunnelHub('add', e.currentTarget as HTMLElement)}
              >
                ＋
              </button>
            </>
          )}
        </div>
      </div>

      {/* Center Native Window Drag Region */}
      <div className="titlebar-drag-spacer" />

      {/* Right Group: Fault-Only Alert Pill + Window Caption Buttons */}
      <div className="titlebar-right">
        {Boolean(infra.display?.IsFault) && (
          <button
            type="button"
            className="fault-heartbeat-pill"
            title="隧道或本地内核连接异常，点击打开配置面板排查"
            onClick={(e) =>
              onOpenTunnelHub(
                'chatgpt',
                firstCapsuleRef?.current || (e.currentTarget as HTMLElement)
              )
            }
          >
            <span
              className="status-dot"
              style={{ width: '6px', height: '6px', backgroundColor: '#EF4444' }}
            />
            <span>隧道告警: 请检查连接</span>
          </button>
        )}

        <button
          type="button"
          className="win-caption-btn"
          aria-label="最小化窗口"
          title="最小化窗口"
          onClick={() => void hostRpc('window_minimize')}
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M5 12h14" />
          </svg>
        </button>

        <button
          type="button"
          className="win-caption-btn"
          aria-label={windowMaximized ? '还原窗口' : '最大化窗口'}
          title="最大化 / 还原窗口"
          onClick={() => void hostRpc('window_toggle_maximize')}
        >
          {windowMaximized ? (
            <svg width="11.5" height="11.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <path d="M8 8h11v11H8z" />
              <path d="M5 16V5h11" />
            </svg>
          ) : (
            <svg width="11.5" height="11.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <path d="M5 5h14v14H5z" />
            </svg>
          )}
        </button>

        <button
          type="button"
          className="win-caption-btn close-btn"
          aria-label="最小化收进托盘"
          title="最小化收进右下角系统托盘（后台内核与隧道保持运行，右键托盘可彻底退出）"
          onClick={() => void hostRpc('window_close_to_tray')}
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M18 6L6 18M6 6l12 12" />
          </svg>
        </button>
      </div>
    </header>
  );
}
