import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import type {
  EffectiveTheme,
  HostInfraBundle,
  PaneMemoryItem,
  PlatformId,
  StudioSessionCard,
  StudioSnapshot,
  ThemeMode,
  WindowLayoutMemory,
} from './types/contracts';
import {
  extractInfraBundle,
  getSystemPrefersDark,
  hostRpc,
  notifySmokeReady,
  readStoredThemeMode,
  resolveEffectiveTheme,
  subscribeHostMessages,
  syncThemeDom,
} from './services/hostBridge';
import {
  fetchSnapshot,
  mergeQueueDigestIntoSnapshot,
  postStudioAction,
  StudioEventStream,
} from './services/studioHub';
import { Titlebar, type TunnelHubTab } from './components/Titlebar';
import { TaskRail, type PendingPurgeItem } from './components/TaskRail';
import { WorkspacePanes } from './components/WorkspacePanes';
import { TunnelHubPopover } from './components/TunnelHubPopover';
import {
  GlobalSettingsPopover,
  type GlobalSettingsTab,
} from './components/GlobalSettingsPopover';
import {
  ArchiveDialog,
  SentHistoryDialog,
  SessionDetailDialog,
} from './components/Dialogs';

interface QuickToastState {
  seq: number;
  message: string;
  level: 'info' | 'success' | 'warning' | 'error';
}

function buildBootstrapFallbackInfra(): HostInfraBundle {
  const themeMode = readStoredThemeMode();
  const systemTheme = getSystemPrefersDark();
  const effectiveTheme = resolveEffectiveTheme(themeMode, systemTheme);
  return {
    shieldBaseUrl: 'http://127.0.0.1:8766',
    studioToken: '',
    profiles: {
      ActiveProfileId: '',
      EnabledPlatforms: ['chatgpt'],
      ActiveProfileByPlatform: {},
      Profiles: [],
    },
    publicTunnel: {
      Running: false,
      Url: '',
      ProcessId: 0,
      StartedAt: '',
      Status: '初始化中…',
      Mode: '',
      ModeLabel: '公网 HTTPS 隧道',
      ProfileId: '',
      FallbackFrom: '',
      HealthPhase: 'Offline',
      PublicRttMs: 0,
      VerifiedIngressIp: '',
      LastCheckedUtc: '',
    },
    publicTunnels: [
      {
        Id: 'pub_builtin_quick',
        Name: '免费临时隧道',
        IsBuiltin: true,
        BaseUrl: '',
        EffectiveUrl: '',
        HasKey: false,
        MaskedKey: '',
        Mode: 'quick',
        ModeLabel: '免费临时隧道',
        Running: false,
        Status: '未启动',
        HealthPhase: 'Offline',
        PublicRttMs: 0,
        ErrorReason: '',
        ProcessId: 0,
        UsedByPlatforms: [],
      },
    ],
    selectedPublicTunnelByPlatform: {
      gemini: 'pub_builtin_quick',
      claude: 'pub_builtin_quick',
    },
    display: {
      Endpoint: 'http://127.0.0.1:8789/mcp',
      Core: 'http://127.0.0.1:8765/mcp',
      Tunnel: '检查中…',
      Session: '初始化中…',
      SessionColor: '#71717A',
      IsFault: false,
      Running: false,
      UiUrl: 'http://127.0.0.1:8789/ui',
    },
    layout: {
      WinWidth: 1320,
      WinHeight: 840,
      RailWidth: 260,
      RailCollapsed: false,
      ShowArchived: false,
      ThemeMode: themeMode,
      HiddenRightPane: null,
      Panes: [{ id: 1, session_key: '__launchpad__', width_weight: 1, show_summary: false }],
    },
    engineConfig: {
      CorePort: 8765,
      AcpDefaultProfile: 'codex',
      AcpMaxConcurrentPrompts: 4,
      BrowserEnabled: true,
      StartupMode: 'tray',
      AutoArchiveCompletedMode: '3d',
      DefaultBrowserProfile: 'Desktop:ChatGPT',
    },
    browserProfiles: [
      { Id: 'Desktop:ChatGPT', Label: 'ChatGPT 桌面端', UserName: 'Desktop', IsDefault: true },
      { Id: 'Chrome:Default', Label: 'Chrome 默认', UserName: 'Default', IsDefault: false },
    ],
    cliAgents: [],
    themeMode,
    systemTheme,
    effectiveTheme,
    windowMaximized: false,
  };
}

function normalizePanes(rawPanes: PaneMemoryItem[] | undefined): PaneMemoryItem[] {
  if (!Array.isArray(rawPanes) || rawPanes.length === 0) {
    return [{ id: 1, session_key: '__launchpad__', width_weight: 1, show_summary: false }];
  }
  return rawPanes.slice(0, 4).map((p, idx) => ({
    id: Number(p.id) > 0 ? Number(p.id) : idx + 1,
    session_key: String(p.session_key || '__launchpad__'),
    width_weight: Number(p.width_weight) > 0 ? Number(p.width_weight) : 1,
    show_summary: Boolean(p.show_summary),
  }));
}

export function App() {
  const [infra, setInfra] = useState<HostInfraBundle>(() => buildBootstrapFallbackInfra());
  const [snapshot, setSnapshot] = useState<StudioSnapshot | null>(null);
  const [windowMaximized, setWindowMaximized] = useState(false);

  const [railWidth, setRailWidth] = useState(260);
  const [railCollapsed, setRailCollapsed] = useState(false);
  const [panes, setPanes] = useState<PaneMemoryItem[]>([
    { id: 1, session_key: '__launchpad__', width_weight: 1, show_summary: false },
  ]);
  const [hiddenRightPane, setHiddenRightPane] = useState<PaneMemoryItem | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [composerFocusSignal, setComposerFocusSignal] = useState(0);

  // Popovers & Modals
  const [activePopover, setActivePopover] = useState<'tunnel' | 'settings' | null>(null);
  const [tunnelTab, setTunnelTab] = useState<TunnelHubTab>('chatgpt');
  const [settingsTab, setSettingsTab] = useState<GlobalSettingsTab>('general');
  const [highlightedTunnelId, setHighlightedTunnelId] = useState<string | null>(null);
  const [tunnelAnchorEl, setTunnelAnchorEl] = useState<HTMLElement | null>(null);
  const [settingsAnchorEl, setSettingsAnchorEl] = useState<HTMLElement | null>(null);
  const [discardSignal, setDiscardSignal] = useState(0);

  const [archiveDialogOpen, setArchiveDialogOpen] = useState(false);
  const [sentHistorySessionKey, setSentHistorySessionKey] = useState<string | null>(null);
  const [detailSessionKey, setDetailSessionKey] = useState<string | null>(null);

  // Top-Center Single QuickToast (`2200ms` auto-hide)
  const [toast, setToast] = useState<QuickToastState | null>(null);
  const toastSeqRef = useRef(0);
  const toastTimerRef = useRef<number | null>(null);

  // 8-Second Deferred Purge (`UndoDeleteBorder`)
  const [pendingPurge, setPendingPurge] = useState<PendingPurgeItem | null>(null);
  const pendingPurgeRef = useRef<PendingPurgeItem | null>(null);
  const purgeTimerRef = useRef<number | null>(null);

  // Refs for stream, visibility & stall balloon alerts
  const infraRef = useRef<HostInfraBundle>(infra);
  const streamRef = useRef<StudioEventStream | null>(null);
  const firstCapsuleRef = useRef<HTMLElement | null>(null);
  const settingsBtnRef = useRef<HTMLElement | null>(null);
  const capsuleRefsByPlat = useRef<Partial<Record<PlatformId, HTMLElement | null>>>({});
  const highlightTimerRef = useRef<number | null>(null);
  const windowVisibleRef = useRef<boolean>(true);
  const prevStalledKeysRef = useRef<Set<string>>(new Set());
  const initialStallSeededRef = useRef<boolean>(false);
  const initialPaneHydratedRef = useRef<boolean>(false);

  infraRef.current = infra;
  pendingPurgeRef.current = pendingPurge;

  const pushToast = useCallback(
    (
      message: string,
      level: 'info' | 'success' | 'warning' | 'error' = 'info'
    ) => {
      if (!message) return;
      if (toastTimerRef.current !== null) {
        window.clearTimeout(toastTimerRef.current);
      }
      const seq = ++toastSeqRef.current;
      setToast({ seq, message, level });
      toastTimerRef.current = window.setTimeout(() => {
        setToast((cur) => (cur && cur.seq === seq ? null : cur));
        toastTimerRef.current = null;
      }, 2200);
    },
    []
  );

  const applyThemeState = useCallback(
    (
      themeMode: ThemeMode,
      systemTheme: EffectiveTheme,
      effectiveOverride?: EffectiveTheme
    ) => {
      const eff = effectiveOverride || resolveEffectiveTheme(themeMode, systemTheme);
      syncThemeDom(themeMode, eff);
      setInfra((prev) => ({
        ...prev,
        themeMode,
        systemTheme,
        effectiveTheme: eff,
      }));
    },
    []
  );

  const persistLayoutToHost = useCallback(
    (patch: Partial<WindowLayoutMemory>) => {
      void hostRpc('save_layout', { layout: patch }).catch(() => {});
    },
    []
  );

  const applyIncomingSnapshot = useCallback((snap: StudioSnapshot) => {
    if (!snap || snap.not_modified || !Array.isArray(snap.sessions)) return;

    // Background Stall Tray Alert (`#L2.4`): notify when minimized to tray and a session newly stalls
    const nextStalled = new Set<string>();
    for (const s of snap.sessions) {
      if (s.IsStalled) {
        nextStalled.add(s.SessionKey);
        if (
          initialStallSeededRef.current &&
          !prevStalledKeysRef.current.has(s.SessionKey) &&
          !windowVisibleRef.current
        ) {
          void hostRpc('show_balloon_tip', {
            title: 'RelayStudio · 任务停顿提醒',
            message: `「${s.ShortTitle || s.Title}」已停顿，点击托盘可查看或自动重发`,
          }).catch(() => {});
        }
      }
    }
    prevStalledKeysRef.current = nextStalled;
    initialStallSeededRef.current = true;

    setSnapshot(snap);

    // Auto-bind initial single launchpad pane to first active session if no explicit session was saved
    setPanes((prevPanes) => {
      if (
        !initialPaneHydratedRef.current &&
        snap.sessions.length > 0 &&
        prevPanes.length === 1 &&
        (!prevPanes[0].session_key || prevPanes[0].session_key === '__launchpad__')
      ) {
        initialPaneHydratedRef.current = true;
        return [{ ...prevPanes[0], session_key: snap.sessions[0].SessionKey }];
      }
      if (snap.sessions.length > 0) {
        initialPaneHydratedRef.current = true;
      }
      return prevPanes;
    });
  }, []);

  const refreshSnapshotImmediate = useCallback(
    async (overrideUrl?: string, overrideToken?: string): Promise<boolean> => {
      const baseUrl = overrideUrl ?? infraRef.current.shieldBaseUrl;
      const token = overrideToken ?? infraRef.current.studioToken;
      try {
        const snap = await fetchSnapshot(baseUrl, token);
        if (snap && Array.isArray(snap.sessions)) {
          streamRef.current?.setLastRev(snap.rev);
          applyIncomingSnapshot(snap);
        }
        return true;
      } catch {
        return false;
      }
    },
    [applyIncomingSnapshot]
  );

  const applyInfraBundle = useCallback(
    (nextInfra: HostInfraBundle, applyLayout = false) => {
      setInfra(nextInfra);
      if (nextInfra.windowMaximized !== undefined) {
        setWindowMaximized(Boolean(nextInfra.windowMaximized));
      }
      applyThemeState(
        nextInfra.themeMode,
        nextInfra.systemTheme,
        nextInfra.effectiveTheme
      );
      if (applyLayout && nextInfra.layout) {
        setRailWidth(
          Math.max(200, Math.min(360, Number(nextInfra.layout.RailWidth) || 260))
        );
        setRailCollapsed(Boolean(nextInfra.layout.RailCollapsed));
        setHiddenRightPane(nextInfra.layout.HiddenRightPane || null);
        const restoredPanes = normalizePanes(nextInfra.layout.Panes);
        if (
          restoredPanes.some(
            (p) => p.session_key && p.session_key !== '__launchpad__' && p.session_key !== '__picker__'
          )
        ) {
          initialPaneHydratedRef.current = true;
        }
        setPanes(restoredPanes);
      }
      streamRef.current?.updateEndpoint(nextInfra.shieldBaseUrl, nextInfra.studioToken);
    },
    [applyThemeState]
  );

  // Two-Stage Non-Blocking Startup Hydration (`get_fast_bootstrap` -> immediate UI + SSE -> background `boot_init`)
  useEffect(() => {
    let cancelled = false;
    const t0 = performance.now();

    const stream = new StudioEventStream(
      infraRef.current.shieldBaseUrl,
      infraRef.current.studioToken,
      {
        onSnapshot: (snap) => {
          if (!cancelled) applyIncomingSnapshot(snap);
        },
        onQueueDigest: (digest) => {
          if (!cancelled) {
            setSnapshot((prev) => mergeQueueDigestIntoSnapshot(prev, digest));
          }
        },
      }
    );
    streamRef.current = stream;

    void (async () => {
      let fastInfra = buildBootstrapFallbackInfra();
      try {
        const fastRes = await hostRpc<any>('get_fast_bootstrap');
        const extracted = extractInfraBundle(fastRes);
        if (extracted) fastInfra = extracted;
      } catch {
        // Proceed with fallback infra
      }

      if (cancelled) return;
      applyInfraBundle(fastInfra, true);
      stream.updateEndpoint(fastInfra.shieldBaseUrl, fastInfra.studioToken);
      stream.start();

      // Stage 1b: Fire background `boot_init` concurrently without blocking first snapshot!
      void hostRpc<any>('boot_init')
        .then((fullRes) => {
          if (cancelled) return;
          const fullInfra = extractInfraBundle(fullRes);
          if (fullInfra) {
            applyInfraBundle(fullInfra, false);
            void refreshSnapshotImmediate(fullInfra.shieldBaseUrl, fullInfra.studioToken);
          }
        })
        .catch(() => {});

      // Stage 1a: Immediate snapshot + smoke_ready notification
      const snapshotSucceeded = await refreshSnapshotImmediate(
        fastInfra.shieldBaseUrl,
        fastInfra.studioToken
      );
      if (!cancelled) {
        notifySmokeReady({
          title: document.title,
          shieldBaseUrl: fastInfra.shieldBaseUrl,
          hubReachable: snapshotSucceeded,
          fastBootMs: Math.round(performance.now() - t0),
        });
      }
    })();

    return () => {
      cancelled = true;
      stream.dispose();
      streamRef.current = null;
      if (toastTimerRef.current !== null) {
        window.clearTimeout(toastTimerRef.current);
      }
      if (purgeTimerRef.current !== null) {
        window.clearTimeout(purgeTimerRef.current);
      }
      if (highlightTimerRef.current !== null) {
        window.clearTimeout(highlightTimerRef.current);
      }
    };
  }, [applyIncomingSnapshot, applyInfraBundle, refreshSnapshotImmediate]);

  // Host Push Listener (`lifecycle`, `window_state`, `theme_changed`, `infra_updated`, `toast`, `discard_unsaved_edits`)
  useEffect(() => {
    return subscribeHostMessages((msg) => {
      switch (msg.type) {
        case 'lifecycle': {
          windowVisibleRef.current = msg.visible;
          document.documentElement.dataset.suspended = msg.visible ? 'false' : 'true';
          if (msg.maximized !== undefined) {
            setWindowMaximized(Boolean(msg.maximized));
          }
          streamRef.current?.setVisible(msg.visible);
          break;
        }
        case 'window_state': {
          setWindowMaximized(Boolean(msg.maximized));
          break;
        }
        case 'theme_changed': {
          applyThemeState(msg.themeMode, msg.systemTheme, msg.effectiveTheme);
          break;
        }
        case 'infra_updated': {
          const nextInfra = extractInfraBundle(msg);
          if (nextInfra) {
            applyInfraBundle(nextInfra, false);
          }
          if (msg.toast) pushToast(msg.toast, 'info');
          break;
        }
        case 'toast': {
          pushToast(msg.message, msg.level || 'info');
          break;
        }
        case 'discard_unsaved_edits': {
          setDiscardSignal((n) => n + 1);
          setActivePopover(null);
          break;
        }
      }
    });
  }, [applyInfraBundle, applyThemeState, pushToast]);

  // OS dark-mode media query + cross-tab storage sync (`dark-mode` / `dark-mode-toggle`: NEVER clear localStorage in matchMedia!)
  useEffect(() => {
    const mql = window.matchMedia?.('(prefers-color-scheme: dark)');
    const onMediaChange = (e: MediaQueryListEvent) => {
      const nextSys: EffectiveTheme = e.matches ? 'dark' : 'light';
      const curMode = infraRef.current.themeMode;
      applyThemeState(curMode, nextSys);
    };
    const onStorage = (e: StorageEvent) => {
      if (e.key === 'color-scheme') {
        const nextMode: ThemeMode =
          e.newValue === 'dark' || e.newValue === 'light' ? e.newValue : 'system';
        applyThemeState(nextMode, getSystemPrefersDark());
      }
    };

    mql?.addEventListener('change', onMediaChange);
    window.addEventListener('storage', onStorage);
    return () => {
      mql?.removeEventListener('change', onMediaChange);
      window.removeEventListener('storage', onStorage);
    };
  }, [applyThemeState]);

  // Theme actions + Global Ctrl+Shift+D shortcut
  const handleSetThemeMode = useCallback(
    (mode: ThemeMode) => {
      const sys = getSystemPrefersDark();
      const eff = resolveEffectiveTheme(mode, sys);
      applyThemeState(mode, sys, eff);
      void hostRpc('set_theme_mode', { mode }).then((res) => {
        const next = extractInfraBundle(res);
        if (next) applyInfraBundle(next, false);
      }).catch(() => {});
    },
    [applyInfraBundle, applyThemeState]
  );

  const handleQuickToggleTheme = useCallback(() => {
    const curEff = infraRef.current.effectiveTheme || 'light';
    const nextMode: ThemeMode = curEff === 'dark' ? 'light' : 'dark';
    applyThemeState(nextMode, getSystemPrefersDark(), nextMode);
    pushToast(
      nextMode === 'dark' ? '🌙 已切换至深色模式' : '☀ 已切换至浅色模式',
      'info'
    );
    void hostRpc('step_quick_theme', { direction: 'invert' })
      .then((res) => {
        const next = extractInfraBundle(res);
        if (next) applyInfraBundle(next, false);
      })
      .catch(() => {});
  }, [applyInfraBundle, applyThemeState, pushToast]);

  const handleResetSystemTheme = useCallback(() => {
    handleSetThemeMode('system');
    pushToast('已恢复「跟随系统」外观主题', 'info');
  }, [handleSetThemeMode, pushToast]);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key.toLowerCase() === 'd') {
        e.preventDefault();
        handleQuickToggleTheme();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [handleQuickToggleTheme]);

  // 8-Second Deferred Purge (`UndoDeleteBorder`)
  const commitPurgeNow = useCallback(
    async (target: PendingPurgeItem) => {
      try {
        await postStudioAction(
          infraRef.current.shieldBaseUrl,
          infraRef.current.studioToken,
          {
            action: 'purge',
            session_key: target.sessionKey,
          }
        );
        await refreshSnapshotImmediate();
      } catch (err) {
        pushToast(
          `彻底删除失败: ${err instanceof Error ? err.message : String(err)}`,
          'error'
        );
      }
    },
    [pushToast, refreshSnapshotImmediate]
  );

  const handleRequestDeferredPurge = useCallback(
    (card: StudioSessionCard) => {
      // If another item is already waiting in the 8s window, commit it immediately first!
      if (purgeTimerRef.current !== null) {
        window.clearTimeout(purgeTimerRef.current);
        purgeTimerRef.current = null;
      }
      if (
        pendingPurgeRef.current &&
        pendingPurgeRef.current.sessionKey !== card.SessionKey
      ) {
        void commitPurgeNow(pendingPurgeRef.current);
      }

      const nextPending: PendingPurgeItem = {
        sessionKey: card.SessionKey,
        title: card.ShortTitle || card.Title || card.SessionKey,
      };
      setPendingPurge(nextPending);

      if (detailSessionKey === card.SessionKey) {
        setDetailSessionKey(null);
      }
      setPanes((prev) =>
        prev.map((p) =>
          p.session_key === card.SessionKey
            ? { ...p, session_key: '__launchpad__' }
            : p
        )
      );

      purgeTimerRef.current = window.setTimeout(() => {
        purgeTimerRef.current = null;
        setPendingPurge((cur) => {
          if (cur && cur.sessionKey === nextPending.sessionKey) {
            void commitPurgeNow(nextPending);
            return null;
          }
          return cur;
        });
      }, 8000);
    },
    [commitPurgeNow, detailSessionKey]
  );

  const handleUndoPurge = useCallback(() => {
    if (purgeTimerRef.current !== null) {
      window.clearTimeout(purgeTimerRef.current);
      purgeTimerRef.current = null;
    }
    setPendingPurge(null);
    pushToast('已撤销删除', 'info');
  }, [pushToast]);

  const handleDismissPurgeBanner = useCallback(() => {
    if (purgeTimerRef.current !== null) {
      window.clearTimeout(purgeTimerRef.current);
      purgeTimerRef.current = null;
    }
    const item = pendingPurgeRef.current;
    setPendingPurge(null);
    if (item) {
      void commitPurgeNow(item);
    }
  }, [commitPurgeNow]);

  // Pane & Rail Layout Orchestration
  const commitPanes = useCallback(
    (nextPanes: PaneMemoryItem[], nextHidden?: PaneMemoryItem | null) => {
      setPanes(nextPanes);
      const patch: Partial<WindowLayoutMemory> = { Panes: nextPanes };
      if (nextHidden !== undefined) {
        setHiddenRightPane(nextHidden);
        patch.HiddenRightPane = nextHidden;
      }
      persistLayoutToHost(patch);
    },
    [persistLayoutToHost]
  );

  const handleRailResizeChange = useCallback(
    (nextWidth: number, nextCollapsed: boolean, commit: boolean) => {
      setRailWidth(nextWidth);
      setRailCollapsed(nextCollapsed);
      if (commit) {
        persistLayoutToHost({
          RailWidth: nextWidth,
          RailCollapsed: nextCollapsed,
        });
      }
    },
    [persistLayoutToHost]
  );

  const handleToggleRail = useCallback(() => {
    const nextCollapsed = !railCollapsed;
    setRailCollapsed(nextCollapsed);
    persistLayoutToHost({
      RailWidth: railWidth,
      RailCollapsed: nextCollapsed,
    });
  }, [persistLayoutToHost, railCollapsed, railWidth]);

  const handleSplitAfter = useCallback(
    (paneIndex: number) => {
      if (panes.length >= 4) return;
      const nextCount = panes.length + 1;
      const usedIds = new Set(panes.map((p) => p.id));
      let nextId = 1;
      while (usedIds.has(nextId)) nextId++;

      let newPane: PaneMemoryItem;
      let nextHidden = hiddenRightPane;

      if (panes.length === 1 && hiddenRightPane && hiddenRightPane.session_key) {
        newPane = {
          id: nextId,
          session_key: hiddenRightPane.session_key,
          width_weight: 1,
          show_summary: Boolean(hiddenRightPane.show_summary),
        };
        nextHidden = null;
      } else {
        const openKeys = new Set(panes.map((p) => p.session_key));
        const candidate = (snapshot?.sessions || []).find(
          (s) => !openKeys.has(s.SessionKey)
        );
        newPane = {
          id: nextId,
          session_key: candidate ? candidate.SessionKey : '__launchpad__',
          width_weight: 1,
          show_summary: false,
        };
      }

      const nextPanes = [...panes];
      nextPanes.splice(paneIndex + 1, 0, newPane);
      const equalized = nextPanes.map((p) => ({ ...p, width_weight: 1 }));

      // Auto-fit on 3–4 Split (`Split-PaneAfter` `#L3162-L3182`)
      if (nextCount >= 3) {
        if (!railCollapsed) {
          setRailCollapsed(true);
          persistLayoutToHost({ RailCollapsed: true });
        }
        void hostRpc('window_ensure_min_width', {
          minWidth: nextCount * 355 + 24,
        }).catch(() => {});
      }

      commitPanes(equalized, nextHidden);
    },
    [commitPanes, hiddenRightPane, panes, persistLayoutToHost, railCollapsed, snapshot?.sessions]
  );

  const handleClosePane = useCallback(
    (paneId: number) => {
      if (panes.length <= 1) return;
      const closing = panes.find((p) => p.id === paneId) || null;
      const remaining = panes
        .filter((p) => p.id !== paneId)
        .map((p) => ({ ...p, width_weight: 1 }));
      const savedHidden =
        panes.length === 2 && closing ? closing : hiddenRightPane;
      commitPanes(remaining, savedHidden);
    },
    [commitPanes, hiddenRightPane, panes]
  );

  const handleUpdatePane = useCallback(
    (paneId: number, patch: Partial<PaneMemoryItem>) => {
      const next = panes.map((p) => (p.id === paneId ? { ...p, ...patch } : p));
      commitPanes(next);
    },
    [commitPanes, panes]
  );

  const handleResizePanes = useCallback(
    (nextWeights: number[], commit: boolean) => {
      const next = panes.map((p, i) => ({
        ...p,
        width_weight: nextWeights[i] ?? p.width_weight,
      }));
      setPanes(next);
      if (commit) {
        persistLayoutToHost({ Panes: next });
      }
    },
    [panes, persistLayoutToHost]
  );

  const handleSelectSession = useCallback(
    (sessionKey: string, openInNewSplit: boolean) => {
      const existingIdx = panes.findIndex((p) => p.session_key === sessionKey);
      if (existingIdx >= 0) {
        return;
      }

      if (openInNewSplit && panes.length < 4) {
        const nextCount = panes.length + 1;
        const usedIds = new Set(panes.map((p) => p.id));
        let nextId = 1;
        while (usedIds.has(nextId)) nextId++;
        const nextPanes = [
          ...panes.map((p) => ({ ...p, width_weight: 1 })),
          { id: nextId, session_key: sessionKey, width_weight: 1, show_summary: false },
        ];
        if (nextCount >= 3) {
          if (!railCollapsed) {
            setRailCollapsed(true);
            persistLayoutToHost({ RailCollapsed: true });
          }
          void hostRpc('window_ensure_min_width', {
            minWidth: nextCount * 355 + 24,
          }).catch(() => {});
        }
        commitPanes(nextPanes);
        return;
      }

      const next = panes.map((p, idx) =>
        idx === 0 ? { ...p, session_key: sessionKey } : p
      );
      commitPanes(next);
    },
    [commitPanes, panes, persistLayoutToHost, railCollapsed]
  );

  const handleCreateNewTask = useCallback(() => {
    const launchpadIdx = panes.findIndex((p) => p.session_key === '__launchpad__');
    if (launchpadIdx >= 0) {
      setComposerFocusSignal((n) => n + 1);
      return;
    }
    const next = panes.map((p, idx) =>
      idx === 0 ? { ...p, session_key: '__launchpad__' } : p
    );
    commitPanes(next);
    setComposerFocusSignal((n) => n + 1);
  }, [commitPanes, panes]);

  // Session Web Open / Archive / Restore Handlers
  const handleOpenSessionWeb = useCallback(
    async (card: StudioSessionCard) => {
      try {
        await hostRpc('open_session_web', {
          sessionKey: card.SessionKey,
          wfrId: card.WfrId || card.SessionKey,
          convUuid: card.BoundConvUuid || '',
          title: card.ShortTitle || card.Title || '',
          browserProfile: card.BrowserProfile || card.Carrier || '',
          provider: card.Provider || 'chatgpt',
        });
      } catch {
        try {
          await postStudioAction(
            infraRef.current.shieldBaseUrl,
            infraRef.current.studioToken,
            {
              action: 'open_tab',
              session_key: card.SessionKey,
              wfr_id: card.WfrId || card.SessionKey,
              conv_uuid: card.BoundConvUuid || '',
              title: card.ShortTitle || card.Title || '',
              browser_profile: card.BrowserProfile || card.Carrier || '',
            }
          );
        } catch (err) {
          pushToast(
            `打开网页失败: ${err instanceof Error ? err.message : String(err)}`,
            'error'
          );
        }
      }
    },
    [pushToast]
  );

  const archiveByKey = useCallback(
    async (sessionKey: string, titleForToast?: string) => {
      try {
        await postStudioAction(
          infraRef.current.shieldBaseUrl,
          infraRef.current.studioToken,
          {
            action: 'archive',
            session_key: sessionKey,
          }
        );
        pushToast(
          titleForToast ? `📦 已归档「${titleForToast}」` : '📦 会话已归档',
          'info'
        );
        const remainingActive = (snapshot?.sessions || []).filter(
          (s) => s.SessionKey !== sessionKey
        );
        setPanes((prev) => {
          const next = prev.map((p) =>
            p.session_key === sessionKey
              ? {
                  ...p,
                  session_key: remainingActive[0]?.SessionKey || '__launchpad__',
                }
              : p
          );
          persistLayoutToHost({ Panes: next });
          return next;
        });
        await refreshSnapshotImmediate();
      } catch (err) {
        pushToast(
          `归档失败: ${err instanceof Error ? err.message : String(err)}`,
          'error'
        );
      }
    },
    [persistLayoutToHost, pushToast, refreshSnapshotImmediate, snapshot?.sessions]
  );

  const handleArchiveCard = useCallback(
    (card: StudioSessionCard) => {
      void archiveByKey(card.SessionKey, card.ShortTitle || card.Title);
    },
    [archiveByKey]
  );

  const handleRestoreAndOpen = useCallback(
    (sessionKey: string, targetPaneId?: number) => {
      void (async () => {
        try {
          await postStudioAction(
            infraRef.current.shieldBaseUrl,
            infraRef.current.studioToken,
            {
              action: 'restore',
              session_key: sessionKey,
            }
          );
          await refreshSnapshotImmediate();
          setPanes((prev) => {
            const next = prev.map((p, idx) =>
              (targetPaneId !== undefined ? p.id === targetPaneId : idx === 0)
                ? { ...p, session_key: sessionKey }
                : p
            );
            persistLayoutToHost({ Panes: next });
            return next;
          });
          setArchiveDialogOpen(false);
          pushToast('↺ 已还原任务并在工作台打开', 'success');
        } catch (err) {
          pushToast(
            `还原失败: ${err instanceof Error ? err.message : String(err)}`,
            'error'
          );
        }
      })();
    },
    [persistLayoutToHost, pushToast, refreshSnapshotImmediate]
  );

  const handleResetLayoutDone = useCallback(
    (nextInfra?: HostInfraBundle) => {
      if (nextInfra) {
        applyInfraBundle(nextInfra, true);
      } else {
        setRailWidth(260);
        setRailCollapsed(false);
        setHiddenRightPane(null);
        const firstActive = snapshot?.sessions?.[0]?.SessionKey || '__launchpad__';
        setPanes([{ id: 1, session_key: firstActive, width_weight: 1, show_summary: false }]);
      }
      pushToast('已重置窗口与分栏布局', 'info');
    },
    [applyInfraBundle, pushToast, snapshot?.sessions]
  );

  const sessions = snapshot?.sessions || [];
  const rawArchived = snapshot?.archived_sessions || [];
  const visibleArchivedSessions = pendingPurge
    ? rawArchived.filter((s) => s.SessionKey !== pendingPurge.sessionKey)
    : rawArchived;

  const activeSessionKeys = new Set(
    panes
      .map((p) => p.session_key)
      .filter((k) => k && k !== '__launchpad__' && k !== '__picker__')
  );

  const detailCard: StudioSessionCard | null = detailSessionKey
    ? sessions.find((s) => s.SessionKey === detailSessionKey) ||
      visibleArchivedSessions.find((s) => s.SessionKey === detailSessionKey) ||
      null
    : null;

  const toastDotColor =
    toast?.level === 'error'
      ? '#EF4444'
      : toast?.level === 'warning'
        ? '#F59E0B'
        : '#22C55E';

  const handleManagePublicTunnels = useCallback((highlightId?: string) => {
    setSettingsTab('tunnels');
    if (highlightTimerRef.current !== null) {
      window.clearTimeout(highlightTimerRef.current);
      highlightTimerRef.current = null;
    }
    if (highlightId) {
      setHighlightedTunnelId(highlightId);
      highlightTimerRef.current = window.setTimeout(() => {
        setHighlightedTunnelId(null);
        highlightTimerRef.current = null;
      }, 2400);
    } else {
      setHighlightedTunnelId(null);
    }
    if (settingsBtnRef.current) {
      setSettingsAnchorEl(settingsBtnRef.current);
    }
    setActivePopover('settings');
  }, []);

  const handleNavigateToChatGptTunnel = useCallback(() => {
    setTunnelTab('chatgpt');
    const chatgptAnchor =
      capsuleRefsByPlat.current.chatgpt ||
      firstCapsuleRef.current ||
      settingsBtnRef.current;
    if (chatgptAnchor) {
      setTunnelAnchorEl(chatgptAnchor);
    }
    setActivePopover('tunnel');
  }, []);

  return (
    <>
      {/* 38px Seamless Top Titlebar */}
      <Titlebar
        infra={infra}
        railCollapsed={railCollapsed}
        windowMaximized={windowMaximized}
        activePopover={activePopover}
        activeTunnelTab={tunnelTab}
        firstCapsuleRef={firstCapsuleRef}
        settingsBtnRef={settingsBtnRef}
        capsuleRefsByPlat={capsuleRefsByPlat}
        onToggleRail={handleToggleRail}
        onQuickToggleTheme={handleQuickToggleTheme}
        onResetSystemTheme={handleResetSystemTheme}
        onOpenTunnelHub={(tab, anchor) => {
          if (activePopover === 'tunnel' && tunnelTab === tab) {
            setActivePopover(null);
            return;
          }
          setTunnelTab(tab);
          setTunnelAnchorEl(anchor);
          setActivePopover('tunnel');
        }}
        onOpenSettings={(anchor) => {
          if (activePopover === 'settings') {
            setActivePopover(null);
            return;
          }
          setSettingsAnchorEl(anchor);
          setActivePopover('settings');
        }}
      />

      {/* Main Two-Region Body: 260px Left Task Rail + Shared Elevated White Workspace Card */}
      <main className="workbench-body">
        <TaskRail
          collapsed={railCollapsed}
          width={railWidth}
          sessions={sessions}
          visibleArchivedCount={visibleArchivedSessions.length}
          subagentCallCount={snapshot?.subagent_call_count || 0}
          activeSessionKeys={activeSessionKeys}
          infra={infra}
          pendingPurge={pendingPurge}
          onResizeChange={handleRailResizeChange}
          onSelectSession={handleSelectSession}
          onCreateNewTask={handleCreateNewTask}
          onOpenArchiveDialog={() => setArchiveDialogOpen(true)}
          onOpenSessionWeb={(card) => void handleOpenSessionWeb(card)}
          onArchiveSession={handleArchiveCard}
          onUndoPurge={handleUndoPurge}
          onDismissPurgeBanner={handleDismissPurgeBanner}
          onOpenFaultTunnelHub={() => {
            setTunnelTab('chatgpt');
            setTunnelAnchorEl(
              capsuleRefsByPlat.current.chatgpt || firstCapsuleRef.current
            );
            setActivePopover('tunnel');
          }}
          onInfraUpdated={(next) => applyInfraBundle(next, false)}
          onToast={pushToast}
        />

        <WorkspacePanes
          railCollapsed={railCollapsed}
          panes={panes}
          sessions={sessions}
          archivedSessions={visibleArchivedSessions}
          infra={infra}
          snapshot={snapshot}
          drafts={drafts}
          composerFocusSignal={composerFocusSignal}
          onDraftChange={(key, val) =>
            setDrafts((prev) => ({ ...prev, [key]: val }))
          }
          onUpdatePane={handleUpdatePane}
          onResizePanes={handleResizePanes}
          onSplitAfter={handleSplitAfter}
          onClosePane={handleClosePane}
          onOpenSessionWeb={(card) => void handleOpenSessionWeb(card)}
          onOpenDetail={(card) => setDetailSessionKey(card.SessionKey)}
          onOpenSentHistory={(key) => setSentHistorySessionKey(key)}
          onOpenArchiveDialog={() => setArchiveDialogOpen(true)}
          onArchiveSession={handleArchiveCard}
          onRestoreAndOpen={(key, paneId) => handleRestoreAndOpen(key, paneId)}
          onRequestDeferredPurge={handleRequestDeferredPurge}
          onRefreshSnapshot={() => void refreshSnapshotImmediate()}
          onToast={pushToast}
        />
      </main>

      {/* Popovers */}
      <TunnelHubPopover
        open={activePopover === 'tunnel'}
        activeTab={tunnelTab}
        anchorEl={tunnelAnchorEl}
        infra={infra}
        discardSignal={discardSignal}
        onSelectTab={(nextTab) => {
          setTunnelTab(nextTab);
          if (nextTab !== 'add') {
            const nextAnchor = capsuleRefsByPlat.current[nextTab];
            if (nextAnchor) {
              setTunnelAnchorEl(nextAnchor);
            }
          }
        }}
        onManagePublicTunnels={handleManagePublicTunnels}
        onClose={() => setActivePopover(null)}
        onInfraUpdated={(next) => applyInfraBundle(next, false)}
        onToast={pushToast}
      />

      <GlobalSettingsPopover
        open={activePopover === 'settings'}
        anchorEl={settingsAnchorEl || settingsBtnRef.current}
        infra={infra}
        themeMode={infra.themeMode}
        systemTheme={infra.systemTheme}
        activeSettingsTab={settingsTab}
        onChangeSettingsTab={setSettingsTab}
        highlightedTunnelId={highlightedTunnelId}
        onNavigateToChatGptTunnel={handleNavigateToChatGptTunnel}
        discardSignal={discardSignal}
        onClose={() => setActivePopover(null)}
        onSetThemeMode={handleSetThemeMode}
        onInfraUpdated={(next) => applyInfraBundle(next, false)}
        onResetLayoutDone={handleResetLayoutDone}
        onRefreshSnapshot={() => void refreshSnapshotImmediate()}
        onToast={pushToast}
      />

      {/* Native <dialog> Editorial Modals (Worker 3B Frozen Prop Contracts) */}
      <ArchiveDialog
        open={archiveDialogOpen}
        archivedSessions={rawArchived}
        pendingPurgeKey={pendingPurge?.sessionKey ?? null}
        infra={infra}
        onClose={() => setArchiveDialogOpen(false)}
        onRestoreAndOpen={(key) => handleRestoreAndOpen(key)}
        onOpenDetail={(card) => setDetailSessionKey(card.SessionKey)}
        onRequestDeferredPurge={handleRequestDeferredPurge}
        onOpenSessionWeb={(card) => void handleOpenSessionWeb(card)}
        onRefreshSnapshot={() => void refreshSnapshotImmediate()}
        onToast={pushToast}
      />

      <SentHistoryDialog
        open={sentHistorySessionKey !== null}
        sessionKey={sentHistorySessionKey}
        sessions={sessions}
        archivedSessions={visibleArchivedSessions}
        infra={infra}
        onClose={() => setSentHistorySessionKey(null)}
        onJumpToSession={(key) => {
          setSentHistorySessionKey(null);
          handleSelectSession(key, false);
        }}
        onRefreshSnapshot={() => void refreshSnapshotImmediate()}
        onToast={pushToast}
      />

      <SessionDetailDialog
        open={detailCard !== null}
        card={detailCard}
        onClose={() => setDetailSessionKey(null)}
        onOpenSessionWeb={(card) => void handleOpenSessionWeb(card)}
        onOpenWorkspace={(rootPath) =>
          void hostRpc('open_workspace_folder', { path: rootPath })
        }
        onArchiveSession={(sessionKey) => archiveByKey(sessionKey)}
        onRefreshSnapshot={() => void refreshSnapshotImmediate()}
        onToast={pushToast}
      />

      {/* Single Top-Center Floating Pill QuickToast (`连接管理.ps1#L927-L932`) */}
      {toast && (
        <div key={toast.seq} className="quick-toast" role="status" aria-live="polite">
          <span
            className="quick-toast-dot"
            style={{ backgroundColor: toastDotColor }}
          />
          <span className="truncate-1">{toast.message}</span>
        </div>
      )}
    </>
  );
}
