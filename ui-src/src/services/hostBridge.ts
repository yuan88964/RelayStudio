import type {
  EffectiveTheme,
  GitCommitItem,
  HostInfraBundle,
  HostPushMessage,
  HostRpcMethod,
  HostRpcRequest,
  HostRpcResponse,
  PaneMemoryItem,
  SafeConnectionProfile,
  ThemeMode,
  WindowLayoutMemory,
} from '../types/contracts';

interface WebView2HostObject {
  postMessage: (message: unknown) => void;
  addEventListener: (type: 'message', listener: (event: MessageEvent) => void) => void;
  removeEventListener: (type: 'message', listener: (event: MessageEvent) => void) => void;
}

declare global {
  interface Window {
    chrome?: {
      webview?: WebView2HostObject;
    };
  }
}

interface PendingRpcEntry {
  resolve: (value: any) => void;
  reject: (reason?: any) => void;
  timer: number;
}

export type HostPushListener = (msg: HostPushMessage) => void;

const DEFAULT_RPC_TIMEOUT_MS = 25_000;
const DEV_STORAGE_LAYOUT_KEY = 'relaystudio.dev.layout';
const DEV_STORAGE_PROFILES_KEY = 'relaystudio.dev.profiles';
const DEV_STORAGE_ENGINE_KEY = 'relaystudio.dev.engine';

let rpcSeq = 0;
let listenerAttached = false;
let smokeNotified = false;
const pendingRpcs = new Map<string, PendingRpcEntry>();
const pushListeners = new Set<HostPushListener>();

export function isWebView2Runtime(): boolean {
  return Boolean(typeof window !== 'undefined' && window.chrome?.webview?.postMessage);
}

export function getSystemPrefersDark(): EffectiveTheme {
  if (typeof window === 'undefined' || !window.matchMedia) return 'light';
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function resolveEffectiveTheme(mode: ThemeMode, systemTheme: EffectiveTheme): EffectiveTheme {
  if (mode === 'light' || mode === 'dark') return mode;
  return systemTheme;
}

/**
 * Synchronizes theme state across:
 *   (a) <meta name="color-scheme"> ("light dark" | "light" | "dark")
 *   (b) localStorage ('color-scheme' removed when 'system', set when 'light' | 'dark')
 *   (c) document.documentElement.dataset.theme ('light' | 'dark')
 */
export function syncThemeDom(
  themeMode: ThemeMode,
  systemTheme: EffectiveTheme = getSystemPrefersDark(),
  explicitEffective?: EffectiveTheme
): EffectiveTheme {
  const effective = explicitEffective ?? resolveEffectiveTheme(themeMode, systemTheme);
  if (typeof document !== 'undefined') {
    const meta = document.querySelector('meta[name="color-scheme"]') as HTMLMetaElement | null;
    if (meta) {
      meta.content = themeMode === 'system' ? 'light dark' : themeMode;
    }
    document.documentElement.dataset.theme = effective;
  }
  if (typeof localStorage !== 'undefined') {
    try {
      if (themeMode === 'system') {
        localStorage.removeItem('color-scheme');
      } else {
        localStorage.setItem('color-scheme', themeMode);
      }
    } catch {
      // Ignore storage access errors in restricted contexts
    }
  }
  return effective;
}

export function readStoredThemeMode(): ThemeMode {
  if (typeof localStorage === 'undefined') return 'system';
  try {
    const raw = localStorage.getItem('color-scheme');
    if (raw === 'light' || raw === 'dark') return raw;
  } catch {
    // Ignore storage errors
  }
  return 'system';
}

function emitPush(msg: HostPushMessage): void {
  for (const fn of pushListeners) {
    try {
      fn(msg);
    } catch (err) {
      console.error('[HostBridge] push listener error:', err);
    }
  }
}

function ensureWebViewListener(): void {
  if (listenerAttached || !isWebView2Runtime()) return;
  const webview = window.chrome!.webview!;
  const onMessage = (event: MessageEvent) => {
    let payload: any = event.data;
    if (typeof payload === 'string') {
      try {
        payload = JSON.parse(payload);
      } catch {
        return;
      }
    }
    if (!payload || typeof payload !== 'object') return;

    if (payload.type === 'rpc_response' && typeof payload.id === 'string') {
      const resp = payload as HostRpcResponse;
      const entry = pendingRpcs.get(resp.id);
      if (!entry) return;
      pendingRpcs.delete(resp.id);
      window.clearTimeout(entry.timer);
      if (resp.ok) {
        entry.resolve(resp.result);
      } else {
        entry.reject(new Error(resp.error || `RPC failed (${resp.id})`));
      }
      return;
    }

    if (
      payload.type === 'lifecycle' ||
      payload.type === 'window_state' ||
      payload.type === 'theme_changed' ||
      payload.type === 'infra_updated' ||
      payload.type === 'toast' ||
      payload.type === 'discard_unsaved_edits'
    ) {
      emitPush(payload as HostPushMessage);
    }
  };
  webview.addEventListener('message', onMessage);
  listenerAttached = true;
}

export function subscribeHostMessages(listener: HostPushListener): () => void {
  ensureWebViewListener();
  pushListeners.add(listener);
  return () => {
    pushListeners.delete(listener);
  };
}

export function extractInfraBundle(candidate: any): HostInfraBundle | null {
  if (!candidate || typeof candidate !== 'object') return null;
  if (typeof candidate.shieldBaseUrl === 'string' && candidate.profiles) {
    return candidate as HostInfraBundle;
  }
  if (candidate.infra && typeof candidate.infra.shieldBaseUrl === 'string') {
    return candidate.infra as HostInfraBundle;
  }
  return null;
}

// ======================== BROWSER DEV FALLBACK STATE ========================

function readDevJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return fallback;
    return { ...fallback, ...JSON.parse(raw) };
  } catch {
    return fallback;
  }
}

function writeDevJson(key: string, val: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(val));
  } catch {
    // Ignore
  }
}

function getDefaultDevLayout(themeMode: ThemeMode): WindowLayoutMemory {
  return {
    WinWidth: 1320,
    WinHeight: 840,
    RailWidth: 260,
    RailCollapsed: false,
    ShowArchived: false,
    ThemeMode: themeMode,
    HiddenRightPane: null,
    Panes: [],
  };
}

function buildDevInfraBundle(): HostInfraBundle {
  const themeMode = readStoredThemeMode();
  const systemTheme = getSystemPrefersDark();
  const effectiveTheme = resolveEffectiveTheme(themeMode, systemTheme);

  const defaultProfiles: HostInfraBundle['profiles'] = {
    ActiveProfileId: 'prof_primary',
    EnabledPlatforms: ['chatgpt'],
    ActiveProfileByPlatform: { chatgpt: 'prof_primary' },
    Profiles: [
      {
        Id: 'prof_primary',
        Name: '主号',
        Platform: 'chatgpt',
        Kind: 'openai_tunnel',
        TunnelId: 'tunnel_local_dev',
        BaseUrl: 'https://api.openai.com/v1',
        ApiBaseUrl: 'https://api.openai.com/v1',
        HasKey: true,
        MaskedKey: 'sk-proj-••••dev',
        Enabled: true,
        IsActive: true,
      },
    ],
  };

  const profiles = readDevJson(DEV_STORAGE_PROFILES_KEY, defaultProfiles);
  const layout = readDevJson(DEV_STORAGE_LAYOUT_KEY, getDefaultDevLayout(themeMode));
  layout.ThemeMode = themeMode;

  const engineConfig = readDevJson(DEV_STORAGE_ENGINE_KEY, {
    CorePort: 8765,
    AcpDefaultProfile: 'codex',
    AcpMaxConcurrentPrompts: 4,
    BrowserEnabled: true,
    StartupMode: 'tray',
    AutoArchiveCompletedMode: '3d',
    DefaultBrowserProfile: 'Chrome:Default',
  });

  return {
    shieldBaseUrl: 'http://127.0.0.1:8766',
    studioToken: '',
    profiles,
    publicTunnel: {
      Running: false,
      Url: '',
      ProcessId: 0,
      StartedAt: '',
      Status: '浏览器预览模式 (未挂载宿主)',
      Mode: 'funnel',
      ModeLabel: 'Tailscale Funnel 固定域名',
      ProfileId: '',
      FallbackFrom: '',
      HealthPhase: 'Offline',
      PublicRttMs: 0,
      VerifiedIngressIp: '',
      LastCheckedUtc: '',
    },
    display: {
      Endpoint: 'http://127.0.0.1:8789/mcp',
      Core: '127.0.0.1:8765 (Dev)',
      Tunnel: '预览直连 :8766',
      Session: '就绪',
      SessionColor: '#16A34A',
      IsFault: false,
      Running: true,
      UiUrl: 'http://127.0.0.1:8766',
    },
    layout,
    engineConfig,
    browserProfiles: [
      { Id: 'Chrome:Default', Label: 'Chrome · 默认配置', UserName: 'Default', IsDefault: true },
      { Id: 'Edge:Default', Label: 'Edge · 默认配置', UserName: 'Default', IsDefault: false },
    ],
    cliAgents: [
      { id: 'codex', display_name: 'Codex CLI', kind: 'codex', command: 'codex', args: [], is_custom: false },
      { id: 'claude', display_name: 'Claude Code', kind: 'claude', command: 'claude', args: [], is_custom: false },
      { id: 'gemini', display_name: 'Gemini CLI', kind: 'gemini', command: 'gemini', args: [], is_custom: false },
    ],
    themeMode,
    systemTheme,
    effectiveTheme,
    windowMaximized: false,
  };
}

async function handleDevFallbackRpc<T = any>(
  method: HostRpcMethod,
  params: Record<string, unknown> = {}
): Promise<T> {
  const infra = buildDevInfraBundle();

  switch (method) {
    case 'get_fast_bootstrap':
    case 'boot_init':
    case 'get_infra_bundle':
    case 'rescan_cli_agents': {
      return infra as unknown as T;
    }

    case 'profile_get_secret': {
      const profId = String(params.profileId ?? params.ProfileId ?? '');
      const found = infra.profiles.Profiles.find((p) => p.Id === profId);
      const isPub = found && found.Platform !== 'chatgpt';
      return {
        ok: true,
        secret: found?.HasKey ? 'sk-proj-dev-preview-secret' : isPub ? 'relaystudio' : '',
        isDefaultOAuth: Boolean(!found?.HasKey && isPub),
      } as unknown as T;
    }

    case 'open_browser_bridge_dir': {
      return { ok: true, path: 'd:\\tool\\RelayStudio\\browser-bridge' } as unknown as T;
    }

    case 'open_external_url': {
      const url = String(params.url ?? params.Url ?? '');
      if (url && typeof window !== 'undefined') {
        window.open(url, '_blank', 'noopener,noreferrer');
      }
      return { ok: true } as unknown as T;
    }

    case 'set_unsaved_edits':
    case 'show_balloon_tip':
    case 'window_ensure_min_width': {
      return { ok: true } as unknown as T;
    }

    case 'save_layout': {
      const incoming = (params.layout as Partial<WindowLayoutMemory>) || (params as Partial<WindowLayoutMemory>);
      const merged: WindowLayoutMemory = {
        ...infra.layout,
        ...incoming,
        Panes: Array.isArray(incoming.Panes) ? (incoming.Panes as PaneMemoryItem[]) : infra.layout.Panes,
      };
      writeDevJson(DEV_STORAGE_LAYOUT_KEY, merged);
      return { ok: true, layout: merged } as unknown as T;
    }

    case 'reset_layout': {
      const fresh = getDefaultDevLayout(infra.themeMode);
      writeDevJson(DEV_STORAGE_LAYOUT_KEY, fresh);
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra, toast: '已重置窗口与分栏布局' });
      return nextInfra as unknown as T;
    }

    case 'set_theme_mode': {
      const rawMode = String(params.mode ?? params.themeMode ?? 'system').toLowerCase();
      const nextMode: ThemeMode = rawMode === 'light' || rawMode === 'dark' ? rawMode : 'system';
      const sys = getSystemPrefersDark();
      const eff = syncThemeDom(nextMode, sys);
      const savedLayout = readDevJson(DEV_STORAGE_LAYOUT_KEY, getDefaultDevLayout(nextMode));
      savedLayout.ThemeMode = nextMode;
      writeDevJson(DEV_STORAGE_LAYOUT_KEY, savedLayout);
      emitPush({ type: 'theme_changed', themeMode: nextMode, systemTheme: sys, effectiveTheme: eff });
      return { themeMode: nextMode, systemTheme: sys, effectiveTheme: eff } as unknown as T;
    }

    case 'step_quick_theme': {
      const sys = getSystemPrefersDark();
      const currentMode = readStoredThemeMode();
      const currentEff = resolveEffectiveTheme(currentMode, sys);
      const targetEff: EffectiveTheme = currentEff === 'dark' ? 'light' : 'dark';
      // Per modern-web-guidance dark-mode-toggle: if target matches system preference, unpin back to 'system'
      const nextMode: ThemeMode = targetEff === sys ? 'system' : targetEff;
      const eff = syncThemeDom(nextMode, sys, targetEff);
      const savedLayout = readDevJson(DEV_STORAGE_LAYOUT_KEY, getDefaultDevLayout(nextMode));
      savedLayout.ThemeMode = nextMode;
      writeDevJson(DEV_STORAGE_LAYOUT_KEY, savedLayout);
      emitPush({ type: 'theme_changed', themeMode: nextMode, systemTheme: sys, effectiveTheme: eff });
      return { themeMode: nextMode, systemTheme: sys, effectiveTheme: eff } as unknown as T;
    }

    case 'capsule_add_platform': {
      const plat = String(params.platform || '').toLowerCase();
      if (plat && !infra.profiles.EnabledPlatforms.includes(plat)) {
        infra.profiles.EnabledPlatforms = [...infra.profiles.EnabledPlatforms, plat];
        if (!infra.profiles.Profiles.some((p) => p.Platform === plat)) {
          const id = `prof_${plat}_default`;
          infra.profiles.Profiles.push({
            Id: id,
            Name: '默认',
            Platform: plat,
            Kind: plat === 'chatgpt' ? 'openai_tunnel' : 'public_mcp_tunnel',
            TunnelId: '',
            BaseUrl: '',
            ApiBaseUrl: '',
            HasKey: false,
            MaskedKey: '',
            Enabled: true,
            IsActive: true,
          });
          infra.profiles.ActiveProfileByPlatform[plat] = id;
        }
        writeDevJson(DEV_STORAGE_PROFILES_KEY, infra.profiles);
      }
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra });
      return nextInfra as unknown as T;
    }

    case 'capsule_remove_platform': {
      const plat = String(params.platform || '').toLowerCase();
      const nextList = infra.profiles.EnabledPlatforms.filter((p) => p.toLowerCase() !== plat);
      infra.profiles.EnabledPlatforms = nextList.length > 0 ? nextList : ['chatgpt'];
      writeDevJson(DEV_STORAGE_PROFILES_KEY, infra.profiles);
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra });
      return nextInfra as unknown as T;
    }

    case 'profile_save': {
      const plat = String(params.Platform ?? params.platform ?? 'chatgpt').toLowerCase();
      const profId = String(params.ProfileId ?? params.profileId ?? '') || `prof_${Date.now()}`;
      const name = String(params.Name ?? params.name ?? '默认配置').trim() || '默认配置';
      const tunnelId = String(params.TunnelId ?? params.tunnelId ?? '').trim();
      const apiKey = String(params.ApiKey ?? params.apiKey ?? '').trim();
      const baseUrl = String(params.ApiBaseUrl ?? params.BaseUrl ?? params.baseUrl ?? '').trim();
      const existingIdx = infra.profiles.Profiles.findIndex((p) => p.Id === profId);
      const entry: SafeConnectionProfile = {
        Id: profId,
        Name: name,
        Platform: plat,
        Kind: plat === 'chatgpt' ? 'openai_tunnel' : 'public_mcp_tunnel',
        TunnelId: tunnelId || (existingIdx >= 0 ? infra.profiles.Profiles[existingIdx].TunnelId : ''),
        BaseUrl: baseUrl,
        ApiBaseUrl: baseUrl,
        HasKey: Boolean(apiKey) || (existingIdx >= 0 ? infra.profiles.Profiles[existingIdx].HasKey : false),
        MaskedKey: apiKey
          ? `${apiKey.slice(0, 6)}••••${apiKey.slice(-4)}`
          : existingIdx >= 0
            ? infra.profiles.Profiles[existingIdx].MaskedKey
            : '',
        Enabled: true,
        IsActive: true,
      };
      if (existingIdx >= 0) {
        infra.profiles.Profiles[existingIdx] = entry;
      } else {
        infra.profiles.Profiles.push(entry);
      }
      if (plat === 'chatgpt') {
        infra.profiles.ActiveProfileId = profId;
      }
      infra.profiles.ActiveProfileByPlatform[plat] = profId;
      for (const p of infra.profiles.Profiles) {
        if (p.Platform === plat) p.IsActive = p.Id === profId;
      }
      writeDevJson(DEV_STORAGE_PROFILES_KEY, infra.profiles);
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra });
      return nextInfra as unknown as T;
    }

    case 'profile_select': {
      const profId = String(params.profileId ?? params.ProfileId ?? params.id ?? '');
      const found = infra.profiles.Profiles.find((p) => p.Id === profId);
      if (found) {
        const plat = String(found.Platform || 'chatgpt').toLowerCase();
        if (plat === 'chatgpt') infra.profiles.ActiveProfileId = profId;
        infra.profiles.ActiveProfileByPlatform[plat] = profId;
        for (const p of infra.profiles.Profiles) {
          if (String(p.Platform || 'chatgpt').toLowerCase() === plat) {
            p.IsActive = p.Id === profId;
          }
        }
        writeDevJson(DEV_STORAGE_PROFILES_KEY, infra.profiles);
      }
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra });
      return nextInfra as unknown as T;
    }

    case 'profile_remove': {
      const profId = String(params.profileId ?? params.ProfileId ?? params.id ?? '');
      infra.profiles.Profiles = infra.profiles.Profiles.filter((p) => p.Id !== profId);
      writeDevJson(DEV_STORAGE_PROFILES_KEY, infra.profiles);
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra, toast: '已删除凭据配置' });
      return nextInfra as unknown as T;
    }

    case 'save_engine_config': {
      const merged = {
        ...infra.engineConfig,
        ...(params.AcpDefaultProfile !== undefined ? { AcpDefaultProfile: String(params.AcpDefaultProfile) } : {}),
        ...(params.AcpMaxConcurrentPrompts !== undefined
          ? { AcpMaxConcurrentPrompts: Number(params.AcpMaxConcurrentPrompts) }
          : {}),
        ...(params.BrowserEnabled !== undefined ? { BrowserEnabled: Boolean(params.BrowserEnabled) } : {}),
        ...(params.StartupMode !== undefined ? { StartupMode: String(params.StartupMode) } : {}),
        ...(params.AutoArchiveCompletedMode !== undefined
          ? { AutoArchiveCompletedMode: String(params.AutoArchiveCompletedMode) }
          : {}),
        ...(params.DefaultBrowserProfile !== undefined
          ? { DefaultBrowserProfile: String(params.DefaultBrowserProfile) }
          : {}),
      };
      writeDevJson(DEV_STORAGE_ENGINE_KEY, merged);
      const nextInfra = buildDevInfraBundle();
      emitPush({ type: 'infra_updated', infra: nextInfra });
      return nextInfra as unknown as T;
    }

    case 'copy_clipboard': {
      const text = String(params.text ?? '');
      if (text && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
      }
      return { ok: true } as unknown as T;
    }

    case 'get_workspace_commits': {
      return ([] as GitCommitItem[]) as unknown as T;
    }

    default: {
      emitPush({
        type: 'toast',
        message: `浏览器预览模式：宿主指令 ${method} 已模拟执行`,
        level: 'info',
      });
      return { ok: true, simulated: true } as unknown as T;
    }
  }
}

export function hostRpc<T = any>(
  method: HostRpcMethod,
  params?: Record<string, unknown>,
  timeoutMs: number = DEFAULT_RPC_TIMEOUT_MS
): Promise<T> {
  if (!isWebView2Runtime()) {
    return handleDevFallbackRpc<T>(method, params);
  }

  ensureWebViewListener();
  const id = `rpc_${++rpcSeq}_${Date.now()}`;
  const req: HostRpcRequest = {
    type: 'rpc_request',
    id,
    method,
    params: params ?? {},
  };

  return new Promise<T>((resolve, reject) => {
    const timer = window.setTimeout(() => {
      if (pendingRpcs.has(id)) {
        pendingRpcs.delete(id);
        reject(new Error(`宿主调用超时 (${method}, ${Math.round(timeoutMs / 1000)}s)`));
      }
    }, timeoutMs);

    pendingRpcs.set(id, { resolve, reject, timer });
    try {
      window.chrome!.webview!.postMessage(req);
    } catch (err) {
      pendingRpcs.delete(id);
      window.clearTimeout(timer);
      reject(err);
    }
  });
}

/**
 * Posts `{ type: 'smoke_ready', ...payload }` to WebView2 host once boot_init + initial snapshot settle.
 * Used by `RelayStudio.exe --smoke-test`.
 */
export function notifySmokeReady(payload: Record<string, unknown> = {}): void {
  if (smokeNotified) return;
  smokeNotified = true;
  if (!isWebView2Runtime()) return;
  try {
    window.chrome!.webview!.postMessage({
      type: 'smoke_ready',
      ...payload,
    });
  } catch (err) {
    console.warn('[HostBridge] notifySmokeReady failed:', err);
  }
}
