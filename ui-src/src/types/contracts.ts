/**
 * Shared RPC, SSE, and HTTP Contracts for RelayStudio WebView2 Workbench.
 * Single Source of Truth across:
 *   - C# / PowerShell HostBridge.ps1 (WebView2 postMessage RPC)
 *   - Python McpReadOnlyShield.py (:8766 HTTP + /studio/events SSE)
 *   - Preact Frontend (ui-src/src/**)
 */

export type PlatformId = 'chatgpt' | 'gemini' | 'claude';
export type ThemeMode = 'system' | 'light' | 'dark';
export type EffectiveTheme = 'light' | 'dark';
export type TargetMode = 'follow_window' | 'new_window';
export type AutoArchiveMode = 'immediate' | '1d' | '3d' | '7d' | 'off';
export type StartupMode = 'tray' | 'window' | 'off';

// ======================== HOST BRIDGE (WebView2 In-Memory RPC) ========================

export interface SafeConnectionProfile {
  Id: string;
  Name: string;
  Platform: PlatformId | string;
  Kind: 'openai_tunnel' | 'public_mcp_tunnel' | string;
  TunnelId: string;
  BaseUrl: string;
  ApiBaseUrl: string;
  KeyFile?: string;
  HasKey: boolean;
  MaskedKey: string;
  Enabled: boolean;
  IsActive: boolean;
}

export interface ProfilesBundle {
  ActiveProfileId: string;
  EnabledPlatforms: string[];
  ActiveProfileByPlatform: Record<string, string>;
  Profiles: SafeConnectionProfile[];
}

export interface PublicMcpTunnelState {
  Running: boolean;
  Url: string;
  PublicMcpUrl?: string;
  ProcessId: number;
  StartedAt: string;
  Status: string;
  Mode: string;
  ModeLabel: string;
  ProfileId: string;
  FallbackFrom: string;
  HealthPhase: 'Online' | 'Degraded' | 'Connecting' | 'Fault' | 'Offline' | string;
  PublicRttMs: number;
  VerifiedIngressIp: string;
  LastCheckedUtc: string;
}

export interface ConnectionDisplaySummary {
  Endpoint: string;
  Core: string;
  Tunnel: string;
  Session: string;
  SessionColor: string;
  IsFault: boolean;
  Running: boolean;
  UiUrl: string;
  RunningProfileId?: string;
  RunningTunnelId?: string;
}

export interface PaneMemoryItem {
  id: number;
  session_key: string;
  width_weight: number;
  show_summary?: boolean;
}

export interface WindowLayoutMemory {
  WinWidth: number;
  WinHeight: number;
  RailWidth: number;
  RailCollapsed: boolean;
  ShowArchived: boolean;
  ThemeMode: ThemeMode;
  HiddenRightPane: PaneMemoryItem | null;
  Panes: PaneMemoryItem[];
}

export interface CoreEngineConfig {
  CorePort: number;
  AcpDefaultProfile: string;
  AcpMaxConcurrentPrompts: number;
  BrowserEnabled: boolean;
  StartupMode: StartupMode | string;
  AutoArchiveCompletedMode: AutoArchiveMode | string;
  DefaultBrowserProfile: string;
}

export interface BrowserProfileOption {
  Id: string;
  Label: string;
  UserName: string;
  IsDefault: boolean;
}

export interface CliAgentOption {
  id: string;
  display_name: string;
  kind: string;
  command: string;
  args: string[];
  is_custom: boolean;
}

export interface GitCommitItem {
  Hash: string;
  ShortHash: string;
  Subject: string;
  TimeAgo: string;
  Author?: string;
}

export interface HostInfraBundle {
  shieldBaseUrl: string;      // e.g. "http://127.0.0.1:8766"
  studioToken: string;        // per-boot RELAYSTUDIO_LOCAL_TOKEN (or "" if unset)
  profiles: ProfilesBundle;
  publicTunnel: PublicMcpTunnelState;
  display: ConnectionDisplaySummary;
  layout: WindowLayoutMemory;
  engineConfig: CoreEngineConfig;
  browserProfiles: BrowserProfileOption[];
  cliAgents: CliAgentOption[];
  themeMode: ThemeMode;
  systemTheme: EffectiveTheme;
  effectiveTheme: EffectiveTheme;
  windowMaximized?: boolean;
}

export type HostRpcMethod =
  | 'get_fast_bootstrap'
  | 'boot_init'
  | 'get_infra_bundle'
  | 'save_layout'
  | 'reset_layout'
  | 'set_theme_mode'
  | 'step_quick_theme'
  | 'profile_save'
  | 'profile_remove'
  | 'profile_select'
  | 'profile_toggle_enabled'
  | 'profile_get_secret'
  | 'capsule_add_platform'
  | 'capsule_remove_platform'
  | 'openai_tunnel_connect'
  | 'openai_tunnel_disconnect'
  | 'public_tunnel_connect'
  | 'public_tunnel_disconnect'
  | 'one_click_reconnect'
  | 'restart_core'
  | 'save_engine_config'
  | 'rescan_cli_agents'
  | 'pick_and_add_cli_agent'
  | 'open_session_web'
  | 'open_handover_window'
  | 'open_workspace_folder'
  | 'open_browser_bridge_dir'
  | 'open_external_url'
  | 'get_workspace_commits'
  | 'repair_priority'
  | 'copy_clipboard'
  | 'set_unsaved_edits'
  | 'show_balloon_tip'
  | 'window_ensure_min_width'
  | 'window_minimize'
  | 'window_toggle_maximize'
  | 'window_close_to_tray'
  | 'shutdown_all_services';

export interface HostRpcRequest {
  type: 'rpc_request';
  id: string;
  method: HostRpcMethod;
  params?: Record<string, unknown>;
}

export interface HostRpcResponse<T = any> {
  type: 'rpc_response';
  id: string;
  ok: boolean;
  result?: T;
  error?: string;
}

export type HostPushMessage =
  | { type: 'lifecycle'; visible: boolean; maximized?: boolean }
  | { type: 'window_state'; maximized: boolean; width?: number; height?: number }
  | { type: 'theme_changed'; themeMode: ThemeMode; systemTheme: EffectiveTheme; effectiveTheme: EffectiveTheme }
  | { type: 'infra_updated'; infra: HostInfraBundle; toast?: string }
  | { type: 'toast'; message: string; level?: 'info' | 'success' | 'warning' | 'error' }
  | { type: 'discard_unsaved_edits' };

// ======================== :8766 STUDIO HUB SNAPSHOT & SSE ========================

export interface TaskStepItem {
  id: string;
  title: string;
  status: 'pending' | 'in_progress' | 'completed' | 'quarantined' | string;
}

export interface QueuedMessageItem {
  id: string;
  session_key: string;
  status: 'pending' | 'claimed' | 'delivered' | 'cancelled' | 'unconfirmed' | string;
  mode: 'custom_message' | 'in_place_wakeup' | 'new_window_handover' | string;
  prompt?: string;
  text?: string;
  display_text?: string;
  created_at?: string;
  claimed_at?: string;
  delivered_at?: string;
  defer_until_stopped?: boolean;
  target_model?: string;
  reasoning_effort?: string;
  browser_profile?: string;
  provider?: string;
}

export interface SessionQueueSlice {
  PendingQueue: QueuedMessageItem[];
  SentWebMessages: QueuedMessageItem[];
  HasInFlightQueue?: boolean;
}

export interface ModelCatalogItem {
  id: string;
  slug?: string;
  title?: string;
  label?: string;
  group?: string;
  efforts?: string[];
  url_slug?: string;
}

export interface StudioSessionCard {
  SessionKey: string;
  WfrId: string;
  TaskId: string;
  ShortId: string;
  Title: string;
  ShortTitle: string;
  RawTitle: string;
  HasCustomAlias: boolean;
  IsCustomTitle: boolean;
  WorkspaceName: string;
  WorkspaceRoot: string;
  IsUnregisteredSession: boolean;
  Goal: string;
  CleanGoal: string;
  CleanGoalSubtitle: string;
  CurrentStep: string;
  ActionText: string;
  RailSubtitle: string;
  LatestSummary: string;
  HumanDiagnosis: string;
  ProgressText: string;
  MetaText: string;
  StallAlertText: string;
  VitalState: 'LIVE' | 'THINKING' | 'STOPPED' | 'UNKNOWN' | string;
  VitalSubstate?: string;
  VitalHintText?: string;
  StoppedElapsedSeconds: number;
  StallSeconds: number;
  HasUserDraft: boolean;
  SseActive: boolean;
  IsDispatching: boolean;
  McpInFlight: boolean;
  TurnSeq: number;
  LastToolAgeSec: number;
  SilenceCountdownSec: number;
  DetectedUiError: string;
  NetworkHold: boolean;
  HasComposer: boolean;
  HasLoadError: boolean;
  PendingQueue: QueuedMessageItem[];
  PendingQueueCount: number;
  Steps: TaskStepItem[];
  CompletedStepCount: number;
  TotalStepCount: number;
  ProgressPercent: number;
  StepCountText: string;
  Milestones: any[];
  ReadableCheckpoints: any[];
  Checkpoints: any[];
  Conditions: string[];
  RecentCommits: GitCommitItem[];
  SentWebMessages: QueuedMessageItem[];
  BreakerStage: string;
  BreakerRetryCount: number;
  BreakerMaxRetries: number;
  BreakerMessage: string;
  BreakerTripped: boolean;
  RetryCount: number;
  MaxRetries: number;
  StallMinutes: number;
  AutoWakeupEnabled: boolean;
  AutoResendEnabled: boolean;
  TargetMode: TargetMode | string;
  Provider: PlatformId | string;
  Carrier: string;
  BrowserProfile: string;
  CarrierByProvider: Record<string, string>;
  BoundConvUuid: string;
  UserLockedBrowser: boolean;
  UserLockedCarrier: boolean;
  TargetModel: string;
  ReasoningEffort: string;
  WebCurrentModel: string;
  WebCurrentEffort: string;
  AvailableModels: Array<string | ModelCatalogItem>;
  AvailableModelsByProvider?: Record<string, Array<string | ModelCatalogItem>>;
  ConnectedProviders?: string[];
  TimeText: string;
  AgoText: string;
  ElapsedSeconds: number;
  LastActivityAt: string;
  StatusBadge: string;
  StatusFg: string;
  StatusBg: string;
  StatusBorder: string;
  CardBg: string;
  CardBorder: string;
  DotColor: string;
  Lifecycle: 'active' | 'completed' | 'archived' | string;
  IsCompleted: boolean;
  IsStalled: boolean;
  IsActive: boolean;
  IsArchived: boolean;
  ArchiveReason: string;
  ArchivedAtText: string;
  CommandCount: number;
  SubagentCount: number;
}

export interface AutoResendConfig {
  enabled: boolean;
  stall_seconds: number;
  stall_minutes: number;
  max_retries: number;
  target_mode: TargetMode | string;
  custom_prompt: string;
  default_browser_profile?: string;
  default_target_model?: string;
  default_reasoning_effort?: string;
  auto_archive_completed_mode?: AutoArchiveMode | string;
  updated_at?: string;
}

export interface StudioWebBridgeSummary {
  session_bindings: Record<string, any>;
  active_tabs_count: number;
  auto_resend_config: AutoResendConfig;
  available_models?: unknown[];
  AvailableModels?: Array<string | ModelCatalogItem>;
  available_models_by_provider: Record<string, Array<string | ModelCatalogItem>>;
  AvailableModelsByProvider?: Record<string, Array<string | ModelCatalogItem>>;
  connected_providers: string[];
  desktop_app_online: boolean;
  DesktopAppOnline?: boolean;
}

export interface StudioSnapshot {
  ok: boolean;
  not_modified?: boolean;
  rev: string;
  queue_rev: string;
  updated_at: string;
  session: string;
  session_color: string;
  is_fault: boolean;
  hidden_idle_count: number;
  recent_minute_count: number;
  command_count: number;
  subagent_call_count: number;
  in_flight_count: number;
  tunnel_network_hold: boolean;
  last_tunnel_drop_epoch: number;
  non_task_heartbeat: {
    count: number;
    ago_text: string;
  };
  sessions: StudioSessionCard[];
  archived_sessions: StudioSessionCard[];
  web_bridge: StudioWebBridgeSummary;
}

export interface StudioQueueDigest {
  ok: boolean;
  not_modified?: boolean;
  queue_rev: string;
  has_active_queue?: boolean;
  queues?: Record<string, SessionQueueSlice>;
}
