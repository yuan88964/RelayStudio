import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import type {
  HostInfraBundle,
  PaneMemoryItem,
  PlatformId,
  StudioSessionCard,
  StudioSnapshot,
  TaskStepItem,
} from '../types/contracts';
import { hostRpc } from '../services/hostBridge';
import { postStudioAction } from '../services/studioHub';
import {
  buildChronologicalMilestones,
  formatProviderBadge,
  formatShortCarrier,
  type NormalizedMilestone,
} from '../utils/formatters';
import { TaskComposer } from './TaskComposer';

export interface TaskPaneProps {
  pane: PaneMemoryItem;
  paneIndex: number;
  paneCount: number;
  sessions: StudioSessionCard[];
  archivedSessions: StudioSessionCard[];
  infra: HostInfraBundle;
  snapshot: StudioSnapshot | null;
  draft: string;
  composerFocusSignal?: number;
  onDraftChange: (draftKey: string, nextDraft: string) => void;
  onUpdatePane: (paneId: number, patch: Partial<PaneMemoryItem>) => void;
  onSplitAfter: (paneIndex: number) => void;
  onClosePane: (paneId: number) => void;
  onOpenSessionWeb: (card: StudioSessionCard) => void;
  onOpenDetail: (card: StudioSessionCard) => void;
  onOpenSentHistory: (sessionKey: string) => void;
  onOpenArchiveDialog: () => void;
  onArchiveSession: (card: StudioSessionCard) => void;
  onRestoreAndOpen: (sessionKey: string, paneId: number) => void;
  onRequestDeferredPurge: (card: StudioSessionCard) => void;
  onRefreshSnapshot: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

const PLATFORM_HOME_URLS: Record<PlatformId, string> = {
  chatgpt: 'https://chatgpt.com/',
  gemini: 'https://gemini.google.com/app',
  claude: 'https://claude.ai/new',
};

function resolveStatusCapsuleMeta(card: StudioSessionCard): {
  tone: 'green' | 'amber' | 'blue' | 'neutral';
  dotColor: string;
  text: string;
} {
  const autoOn = Boolean(card.AutoResendEnabled ?? card.AutoWakeupEnabled);
  const stallSec =
    Number(card.StallSeconds) > 0 && Number(card.StallSeconds) < 60
      ? Number(card.StallSeconds)
      : Math.max(1, Math.round((Number(card.StallMinutes) || 3) * 60));
  const stallDisplayUnit =
    stallSec < 60 ? `${stallSec} 秒` : `${Math.max(1, Math.round(stallSec / 60))} 分钟`;
  const stallTriggerUnit =
    stallSec < 60
      ? `>${stallSec}秒静默触发`
      : `>${Math.max(1, Math.round(stallSec / 60))}分钟静默触发`;
  const guardPart = autoOn ? `自动重发守护已就绪 (${stallTriggerUnit})` : '自动重发已关闭';

  if (card.IsArchived) {
    return {
      tone: 'neutral',
      dotColor: '#A1A1AA',
      text: `已归档会话 · ${card.ArchiveReason || '手动归档'}`,
    };
  }

  const sub = (card.VitalSubstate || '').trim().toUpperCase();
  if (sub === 'PSEUDO_STOPPED') {
    return {
      tone: 'blue',
      dotColor: '#2563EB',
      text: `网页断流 · 本机工具活跃保护中 · ${guardPart}`,
    };
  }
  if (sub === 'WAITING_CONFIRM') {
    const cd = Math.ceil(Number(card.SilenceCountdownSec) || 0);
    const cdPart = !autoOn
      ? '网页生成已静默'
      : cd > 0
        ? `约 ${cd} 秒后自动催工`
        : '等待静默确认后自动催工';
    return {
      tone: 'amber',
      dotColor: '#D97706',
      text: `疑似中断 · ${cdPart} · ${guardPart}`,
    };
  }
  if (sub === 'NETWORK_HOLD') {
    return {
      tone: 'amber',
      dotColor: '#D97706',
      text: `代理/网络断连保号 · 等待恢复中 · ${guardPart}`,
    };
  }
  if (sub === 'DUAL_STREAM') {
    return {
      tone: 'blue',
      dotColor: '#7C3AED',
      text: `双流并发告警 · 已暂停自动派单 · ${guardPart}`,
    };
  }

  if (card.IsStalled) {
    const maxRetries = Math.max(1, Number(card.MaxRetries) || 1);
    const retryPart =
      !autoOn
        ? '自动重发已关闭'
        : card.BreakerMessage && !/闭环守护待命中|自动重发已关闭/.test(card.BreakerMessage)
          ? card.BreakerMessage
          : `已自动重发 ${card.RetryCount || 0}/${maxRetries} 次`;
    return {
      tone: 'amber',
      dotColor: '#D97706',
      text: `网页已停顿 ${stallDisplayUnit} · ${retryPart}`,
    };
  }

  if (card.VitalState === 'UNKNOWN') {
    return {
      tone: 'blue',
      dotColor: '#2563EB',
      text: `${card.VitalHintText || '正在核实网页运行状态'} · ${guardPart}`,
    };
  }

  return {
    tone: 'green',
    dotColor: '#16A34A',
    text: `${card.VitalHintText || '执行中'} · ${guardPart}`,
  };
}

export function TaskPane({
  pane,
  paneIndex,
  paneCount,
  sessions,
  archivedSessions,
  infra,
  snapshot,
  draft,
  composerFocusSignal,
  onDraftChange,
  onUpdatePane,
  onSplitAfter,
  onClosePane,
  onOpenSessionWeb,
  onOpenDetail,
  onOpenSentHistory,
  onOpenArchiveDialog,
  onArchiveSession,
  onRestoreAndOpen,
  onRequestDeferredPurge,
  onRefreshSnapshot,
  onToast,
}: TaskPaneProps) {
  const isNarrow = paneCount >= 2;
  const isPickerMode = pane.session_key === '__picker__';
  const isExplicitLaunchpad = pane.session_key === '__launchpad__';

  const resolvedCard: StudioSessionCard | null =
    !isPickerMode && !isExplicitLaunchpad && pane.session_key
      ? sessions.find((s) => s.SessionKey === pane.session_key) ||
        archivedSessions.find((s) => s.SessionKey === pane.session_key) ||
        null
      : null;

  const isZeroTask = !isPickerMode && (isExplicitLaunchpad || !resolvedCard);
  const draftKey = isZeroTask ? `__launchpad_${pane.id}__` : resolvedCard?.SessionKey || '__new_task__';

  const [prevSessionBeforePicker, setPrevSessionBeforePicker] = useState<string>('__launchpad__');
  const [olderExpanded, setOlderExpanded] = useState(false);
  const [expandedRawKeys, setExpandedRawKeys] = useState<Record<string, boolean>>({});
  const [flashedMilestoneKey, setFlashedMilestoneKey] = useState<string | null>(null);
  const [renameOpen, setRenameOpen] = useState(false);
  const [renameText, setRenameText] = useState('');
  const [renamingBusy, setRenamingBusy] = useState(false);
  const [distFromBottom, setDistFromBottom] = useState(0);
  const [launchpadTarget, setLaunchpadTarget] = useState<{
    provider: PlatformId;
    carrier: string;
  }>({
    provider: 'chatgpt',
    carrier: infra.engineConfig?.DefaultBrowserProfile || 'Desktop:ChatGPT',
  });

  const scrollBodyRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const stickToBottomRef = useRef(true);
  const milestoneDomMapRef = useRef<Map<string, HTMLDivElement>>(new Map());
  const flashTimerRef = useRef<number | null>(null);

  useEffect(() => {
    return () => {
      if (flashTimerRef.current !== null) {
        window.clearTimeout(flashTimerRef.current);
      }
    };
  }, []);

  // Reset per-session UI state on session switch
  useEffect(() => {
    setOlderExpanded(false);
    setExpandedRawKeys({});
    setRenameOpen(false);
    stickToBottomRef.current = true;
    setDistFromBottom(0);
    requestAnimationFrame(() => {
      const el = scrollBodyRef.current;
      if (el) {
        el.scrollTop = el.scrollHeight;
      }
    });
  }, [resolvedCard?.SessionKey]);

  // Focus launchpad textarea when requested (e.g. clicking rail `+`)
  useEffect(() => {
    if (composerFocusSignal && isZeroTask) {
      requestAnimationFrame(() => {
        textareaRef.current?.focus();
      });
    }
  }, [composerFocusSignal, isZeroTask]);

  const milestones = resolvedCard ? buildChronologicalMilestones(resolvedCard) : [];

  // Auto-stick to bottom when new milestones arrive if scrolled < 42px from bottom
  useEffect(() => {
    const el = scrollBodyRef.current;
    if (!el || !stickToBottomRef.current) return;
    requestAnimationFrame(() => {
      if (scrollBodyRef.current && stickToBottomRef.current) {
        scrollBodyRef.current.scrollTop = scrollBodyRef.current.scrollHeight;
        setDistFromBottom(0);
      }
    });
  }, [milestones.length, resolvedCard?.PendingQueueCount, resolvedCard?.SentWebMessages?.length]);

  const handleStreamScroll = () => {
    const el = scrollBodyRef.current;
    if (!el) return;
    const dist = Math.max(0, el.scrollHeight - el.scrollTop - el.clientHeight);
    stickToBottomRef.current = dist < 42;
    setDistFromBottom(dist);
  };

  const scrollToBottomSmooth = () => {
    const el = scrollBodyRef.current;
    if (!el) return;
    stickToBottomRef.current = true;
    el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
    setDistFromBottom(0);
  };

  const handleTargetSelectionChange = useCallback(
    (provider: PlatformId, carrier: string) => {
      setLaunchpadTarget((prev) =>
        prev.provider === provider && prev.carrier === carrier
          ? prev
          : { provider, carrier }
      );
    },
    []
  );

  const handleOpenHostHome = async () => {
    const url = PLATFORM_HOME_URLS[launchpadTarget.provider] || PLATFORM_HOME_URLS.chatgpt;
    const platTitle = formatProviderBadge(launchpadTarget.provider);
    const carrierLabel = formatShortCarrier(launchpadTarget.carrier);
    try {
      await hostRpc('open_handover_window', {
        url,
        carrier: launchpadTarget.carrier,
      });
      onToast(`↗ 已打开 ${platTitle}（${carrierLabel}）`, 'success');
    } catch (err) {
      onToast(`打开宿主窗口失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    }
  };

  const handleTogglePicker = () => {
    if (isPickerMode) {
      onUpdatePane(pane.id, { session_key: prevSessionBeforePicker || '__launchpad__' });
      return;
    }
    if (isZeroTask && sessions.length === 0 && archivedSessions.length === 0) {
      onToast('当前暂无其他会话可切换', 'info');
      return;
    }
    setPrevSessionBeforePicker(pane.session_key || '__launchpad__');
    onUpdatePane(pane.id, { session_key: '__picker__' });
  };

  const handleStepRowClick = (step: TaskStepItem) => {
    if (!resolvedCard) return;
    const normStepTitle = (step.title || '').trim().toLowerCase();
    const matched = milestones.find(
      (m) =>
        (step.id && m.stepId && m.stepId === step.id) ||
        (normStepTitle &&
          (m.title.toLowerCase().includes(normStepTitle) ||
            normStepTitle.includes(m.title.toLowerCase())))
    );

    if (!matched) {
      onOpenDetail(resolvedCard);
      return;
    }

    // If matched milestone is inside collapsed older items, expand first
    const idx = milestones.findIndex((m) => m.key === matched.key);
    if (milestones.length > 3 && idx >= 0 && idx < milestones.length - 3 && !olderExpanded) {
      setOlderExpanded(true);
    }

    requestAnimationFrame(() => {
      const domEl = milestoneDomMapRef.current.get(matched.key);
      if (domEl) {
        domEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
        setFlashedMilestoneKey(matched.key);
        if (flashTimerRef.current !== null) {
          window.clearTimeout(flashTimerRef.current);
        }
        flashTimerRef.current = window.setTimeout(() => {
          setFlashedMilestoneKey(null);
        }, 900);
      } else {
        onOpenDetail(resolvedCard);
      }
    });
  };

  const handleSaveAlias = async (clearToAuto: boolean) => {
    if (!resolvedCard || renamingBusy) return;
    setRenamingBusy(true);
    try {
      const nextTitle = clearToAuto ? '' : renameText.trim();
      await postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
        action: 'set_alias',
        session_key: resolvedCard.SessionKey,
        title: nextTitle,
      });
      setRenameOpen(false);
      onToast(nextTitle ? `✓ 已更新会话名称为「${nextTitle}」` : '✓ 已恢复自动会话名称', 'success');
      onRefreshSnapshot();
    } catch (err) {
      onToast(`保存名称失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setRenamingBusy(false);
    }
  };

  const handleCancelAllPending = async () => {
    if (!resolvedCard) return;
    try {
      await postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
        action: 'delete_queued_message',
        session_key: resolvedCard.SessionKey,
        cancel_all_pending: true,
      });
      onToast('已撤回本任务待发指令', 'info');
      onRefreshSnapshot();
    } catch (err) {
      onToast(`撤回失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    }
  };

  const renderMilestoneBlock = (ms: NormalizedMilestone) => {
    const rawDiffers = Boolean(ms.rawText && ms.rawText !== ms.prose);
    const rawOpen = Boolean(expandedRawKeys[ms.key]);
    const isFlashed = flashedMilestoneKey === ms.key;

    return (
      <div
        key={ms.key}
        ref={(el) => {
          if (el) milestoneDomMapRef.current.set(ms.key, el);
          else milestoneDomMapRef.current.delete(ms.key);
        }}
        className={`milestone-block ${isFlashed ? 'flash-highlight' : ''}`.trim()}
      >
        <div className="milestone-head">
          <span
            className="milestone-dot"
            style={{ backgroundColor: ms.isSuccess ? '#16A34A' : '#D97706' }}
          />
          <span className="milestone-title">{ms.title}</span>
          {ms.timeText && <span className="milestone-time">{ms.timeText}</span>}
          {rawDiffers && (
            <button
              type="button"
              className="milestone-raw-btn"
              onClick={() =>
                setExpandedRawKeys((prev) => ({ ...prev, [ms.key]: !prev[ms.key] }))
              }
            >
              {rawOpen ? '收起原文' : '原文'}
            </button>
          )}
        </div>

        {ms.prose && <div className="milestone-prose">{ms.prose}</div>}
        {ms.traceText && <div className="milestone-trace">{ms.traceText}</div>}
        {rawDiffers && rawOpen && <pre className="milestone-raw-box">{ms.rawText}</pre>}
      </div>
    );
  };

  // ======================== 1. IN-PANE TASK PICKER MODE (`'__picker__'`) ========================
  if (isPickerMode) {
    return (
      <div className="task-pane">
        <div className="pane-header">
          <div className="pane-header-left">
            <button
              type="button"
              className="pane-switcher-btn active"
              onClick={handleTogglePicker}
            >
              <span className="pane-switcher-title">选择任务</span>
              <span className="pane-switcher-cue">返回 ▴</span>
            </button>
          </div>
          <div className="pane-header-right">
            {paneCount < 4 && (
              <button
                type="button"
                className="pane-pill-btn"
                title="在此栏右侧新建分栏"
                onClick={() => onSplitAfter(paneIndex)}
              >
                ◫ 分栏
              </button>
            )}
            {paneCount > 1 && (
              <button
                type="button"
                className="quiet-icon-btn"
                style={{ width: '26px', height: '26px' }}
                aria-label="关闭此分栏"
                title="关闭此分栏"
                onClick={() => onClosePane(pane.id)}
              >
                ×
              </button>
            )}
          </div>
        </div>

        <div className="picker-scroll">
          <div className="picker-center">
            <h2 style={{ margin: 0, fontSize: '16px', fontWeight: 700 }}>
              选择要在此栏打开的任务
            </h2>

            <button
              type="button"
              className="btn btn-primary"
              style={{ alignSelf: 'flex-start', padding: '7px 14px', fontSize: '12.5px' }}
              onClick={() => onUpdatePane(pane.id, { session_key: '__launchpad__' })}
            >
              🚀 新建任务（输入首句需求直接立项）
            </button>

            <div>
              <div className="zero-recent-label" style={{ marginBottom: '8px' }}>
                {`进行中任务 (${sessions.length})`}
              </div>
              {sessions.length === 0 ? (
                <div className="milestone-empty-card" style={{ fontSize: '12.5px' }}>
                  当前暂无进行中的任务，点击上方按钮即可直接立项。
                </div>
              ) : (
                <div className="picker-grid">
                  {sessions.map((s) => (
                    <button
                      key={s.SessionKey}
                      type="button"
                      className="picker-card"
                      onClick={() => onUpdatePane(pane.id, { session_key: s.SessionKey })}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: '6px', minWidth: 0 }}>
                        <span
                          className="status-dot"
                          style={{
                            backgroundColor: s.IsStalled
                              ? '#D97706'
                              : s.VitalState === 'LIVE'
                                ? '#16A34A'
                                : '#2563EB',
                          }}
                        />
                        <span className="truncate-1" style={{ fontWeight: 700, fontSize: '12.5px' }}>
                          {s.ShortTitle || s.Title}
                        </span>
                      </div>
                      <div
                        style={{
                          display: 'flex',
                          justifyContent: 'space-between',
                          gap: '6px',
                          fontSize: '11px',
                          color: 'var(--text-subtle)',
                        }}
                      >
                        <span className="truncate-1">{s.StepCountText || s.RailSubtitle || '进行中'}</span>
                        <span style={{ color: s.IsStalled ? 'var(--amber-text)' : 'var(--green-text)', fontWeight: 600 }}>
                          {s.StatusBadge || '执行中'}
                        </span>
                      </div>
                    </button>
                  ))}
                </div>
              )}
            </div>

            {archivedSessions.length > 0 && (
              <div>
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    marginBottom: '8px',
                  }}
                >
                  <span className="zero-recent-label">
                    {`已归档任务 (${archivedSessions.length})`}
                  </span>
                  <button
                    type="button"
                    className="rail-subtle-link"
                    onClick={onOpenArchiveDialog}
                  >
                    管理全部归档 ▸
                  </button>
                </div>
                <div className="picker-grid">
                  {archivedSessions.slice(0, 8).map((ar) => (
                    <button
                      key={ar.SessionKey}
                      type="button"
                      className="picker-card archived"
                      onClick={() => onUpdatePane(pane.id, { session_key: ar.SessionKey })}
                    >
                      <span className="truncate-1" style={{ fontWeight: 600, fontSize: '12.5px' }}>
                        {`📦 ${ar.ShortTitle || ar.Title}`}
                      </span>
                      <span style={{ fontSize: '11px', color: 'var(--text-subtle)' }}>
                        已归档 · 点击直接打开
                      </span>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }

  // ======================== 2. ZERO-TASK LAUNCHPAD MODE (`launchpad-zero-task.png`) ========================
  if (isZeroTask) {
    const hasArch = archivedSessions.length > 0;

    return (
      <div className="task-pane">
        <div className="pane-header">
          <div className="pane-header-left">
            <button
              type="button"
              className="pane-switcher-btn"
              title="点击切换至此栏要打开的任务会话"
              onClick={handleTogglePicker}
            >
              <span className="pane-switcher-title">新建任务</span>
              <span className="pane-switcher-cue">切换 ▾</span>
            </button>
          </div>
          <div className="pane-header-right">
            {paneCount < 4 && (
              <button
                type="button"
                className="pane-pill-btn"
                title="在此栏右侧新建分栏"
                onClick={() => onSplitAfter(paneIndex)}
              >
                ◫ 分栏
              </button>
            )}
            {paneCount > 1 && (
              <button
                type="button"
                className="quiet-icon-btn"
                style={{ width: '26px', height: '26px' }}
                aria-label="关闭此分栏"
                title="关闭此分栏"
                onClick={() => onClosePane(pane.id)}
              >
                ×
              </button>
            )}
          </div>
        </div>

        <div className="zero-task-shell">
          <div style={{ flex: hasArch ? 0.36 : 0.56, minHeight: '20px' }} />

          <div className="zero-task-center">
            {/* Single horizontal Hero row directly above ComposerPod (`Message #4 item 2`) */}
            <div className="zero-hero-row">
              <h1 className="zero-hero-title">新建任务</h1>
              <button
                type="button"
                className="pane-pill-btn"
                style={{ borderRadius: '8px' }}
                title="打开下方当前选定的桌面端或网页宿主窗口"
                onClick={() => void handleOpenHostHome()}
              >
                🌐 打开宿主窗口 ↗
              </button>
            </div>

            <TaskComposer
              isLaunchpad={true}
              isNarrow={isNarrow}
              sessionKey="__new_task__"
              card={null}
              infra={infra}
              snapshot={snapshot}
              paneCount={paneCount}
              draft={draft}
              textareaRef={textareaRef}
              onDraftChange={(val) => onDraftChange(draftKey, val)}
              onTargetSelectionChange={handleTargetSelectionChange}
              onTaskCreated={(newSessionKey) => {
                onUpdatePane(pane.id, { session_key: newSessionKey });
                onRefreshSnapshot();
              }}
              onActionSettled={onRefreshSnapshot}
              onToast={onToast}
            />

            {hasArch && (
              <div className="zero-recent-archived">
                <div className="zero-recent-header">
                  <span className="zero-recent-label">
                    {`最近归档 (${archivedSessions.length})`}
                  </span>
                  <button
                    type="button"
                    className="rail-subtle-link"
                    onClick={onOpenArchiveDialog}
                  >
                    管理全部归档 ▸
                  </button>
                </div>

                {archivedSessions.slice(0, 3).map((ar) => (
                  <div key={ar.SessionKey} className="zero-arch-card">
                    <div style={{ minWidth: 0, flex: 1 }}>
                      <div className="truncate-1" style={{ fontSize: '13px', fontWeight: 600 }}>
                        {ar.ShortTitle || ar.Title}
                      </div>
                      <div className="truncate-1" style={{ fontSize: '11px', color: 'var(--text-subtle)' }}>
                        {`${ar.ArchiveReason || '已归档'}${ar.AgoText || ar.ArchivedAtText ? ` · ${ar.AgoText || ar.ArchivedAtText}` : ''}`}
                      </div>
                    </div>
                    <div style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', flexShrink: 0 }}>
                      <button
                        type="button"
                        className="btn btn-sm"
                        onClick={() => onOpenDetail(ar)}
                      >
                        查看详情
                      </button>
                      <button
                        type="button"
                        className="btn btn-sm btn-soft-accent"
                        onClick={() => onRestoreAndOpen(ar.SessionKey, pane.id)}
                      >
                        ↺ 还原
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div style={{ flex: hasArch ? 1.64 : 1.44, minHeight: '24px' }} />
        </div>
      </div>
    );
  }

  // ======================== 3. ACTIVE / ARCHIVED SESSION STREAM ========================
  const card = resolvedCard!;
  const latestCommit = card.RecentCommits?.[0];
  const shortSha =
    latestCommit?.ShortHash ||
    (latestCommit?.Hash ? latestCommit.Hash.slice(0, 7) : '');

  const totalSteps = Number(card.TotalStepCount) || card.Steps?.length || 0;
  const completedSteps = Number(card.CompletedStepCount) || 0;
  const progressPct =
    totalSteps > 0
      ? Math.max(0, Math.min(100, Number(card.ProgressPercent) || Math.round((completedSteps / totalSteps) * 100)))
      : 100;

  const statusCapsule = resolveStatusCapsuleMeta(card);

  const olderCount = milestones.length > 3 ? milestones.length - 3 : 0;
  const olderMilestones = olderCount > 0 ? milestones.slice(0, olderCount) : [];
  const recentMilestones = olderCount > 0 ? milestones.slice(olderCount) : milestones;

  const pendingQueue = card.PendingQueue || [];
  const sentMessages = card.SentWebMessages || [];
  const totalQueueAndSent = pendingQueue.length + sentMessages.length;
  const latestSent = sentMessages.length > 0 ? sentMessages[sentMessages.length - 1] : null;
  const latestSentTime =
    latestSent?.delivered_at || latestSent?.created_at
      ? new Date(latestSent.delivered_at || latestSent.created_at || '')
          .toTimeString()
          .slice(0, 8)
      : card.TimeText || '';

  const headerDotColor = card.IsArchived
    ? '#A1A1AA'
    : card.IsStalled
      ? '#D97706'
      : card.VitalState === 'LIVE'
        ? '#16A34A'
        : '#2563EB';

  return (
    <div className="task-pane">
      {/* 42px Pane Top Bar */}
      <div className="pane-header">
        <div className="pane-header-left">
          <button
            type="button"
            className="pane-switcher-btn"
            title="点击切换此栏打开的任务会话"
            onClick={handleTogglePicker}
          >
            <span className="status-dot" style={{ backgroundColor: headerDotColor }} />
            <span className="pane-switcher-title">
              {card.ShortTitle || card.Title}
            </span>
            <span className="pane-switcher-cue">切换 ▾</span>
          </button>

          {latestCommit && shortSha && (
            <button
              type="button"
              className="pane-git-inline"
              title={`${latestCommit.Subject || ''} (${latestCommit.TimeAgo || ''})\n点击复制提交号或打开工作区`}
              onClick={() => {
                if (card.WorkspaceRoot) {
                  void hostRpc('open_workspace_folder', { path: card.WorkspaceRoot });
                } else {
                  void hostRpc('copy_clipboard', {
                    text: latestCommit.Hash || latestCommit.ShortHash || shortSha,
                  });
                  onToast(`已复制提交 SHA: ${shortSha}`, 'info');
                }
              }}
            >
              <span>{isNarrow ? '· Git ' : '· 最近 Git 提交 '}</span>
              <span className="git-sha">{shortSha}</span>
            </button>
          )}
        </div>

        <div className="pane-header-right">
          {totalSteps > 0 && (
            <button
              type="button"
              className={`pane-pill-btn ${pane.show_summary ? 'active' : ''}`}
              aria-expanded={Boolean(pane.show_summary)}
              title="展开或收起执行步骤清单浮层"
              onClick={() =>
                onUpdatePane(pane.id, { show_summary: !pane.show_summary })
              }
            >
              {`步骤 ${completedSteps}/${totalSteps} ▾`}
            </button>
          )}

          {paneCount < 4 && (
            <button
              type="button"
              className="pane-pill-btn"
              title="在此栏右侧新建分栏"
              onClick={() => onSplitAfter(paneIndex)}
            >
              ◫ 分栏
            </button>
          )}

          {paneCount > 1 && (
            <button
              type="button"
              className="quiet-icon-btn"
              style={{ width: '26px', height: '26px' }}
              aria-label="关闭此分栏"
              title="关闭此分栏"
              onClick={() => onClosePane(pane.id)}
            >
              ×
            </button>
          )}
        </div>
      </div>

      {/* Floating CodexSummaryCard (`pane.show_summary`, `#L4529-L4653`) */}
      {Boolean(pane.show_summary) && (card.Steps?.length || 0) > 0 && (
        <div className="codex-summary-card">
          <div className="codex-summary-header">
            <span>{`执行步骤 ${completedSteps}/${totalSteps}`}</span>
            <button
              type="button"
              className="rail-quick-btn"
              aria-label="关闭步骤清单"
              onClick={() => onUpdatePane(pane.id, { show_summary: false })}
            >
              ✕
            </button>
          </div>
          <div className="codex-summary-list">
            {card.Steps.map((step, idx) => {
              const st = (step.status || '').toLowerCase();
              const isDone = st === 'completed';
              const isRunning = st === 'in_progress';
              const icon = isDone ? '✓' : isRunning ? '●' : '○';
              const iconColor = isDone ? '#16A34A' : isRunning ? '#2563EB' : '#A1A1AA';

              return (
                <button
                  key={step.id || idx}
                  type="button"
                  className={`codex-step-row ${isRunning ? 'in-progress' : ''}`}
                  title="点击定位至对应阶段记录（若尚未生成记录则打开详情报告）"
                  onClick={() => handleStepRowClick(step)}
                >
                  <span style={{ color: iconColor, fontWeight: 700, width: '14px', flexShrink: 0 }}>
                    {icon}
                  </span>
                  <span style={{ minWidth: 0, wordBreak: 'break-word' }}>{step.title}</span>
                </button>
              );
            })}
          </div>
        </div>
      )}

      {/* Editorial Stream Scroll Body */}
      <div
        ref={scrollBodyRef}
        className={`pane-scroll-body ${isNarrow ? 'narrow' : ''}`.trim()}
        onScroll={handleStreamScroll}
      >
        <div className="stream-editorial-column">
          {/* Inline RenameBar (`#L581-L596`) */}
          {renameOpen && (
            <div className="rename-bar">
              <span style={{ fontWeight: 600, color: 'var(--accent-text)' }}>
                对齐网页左栏名称：
              </span>
              <input
                type="text"
                className="rename-input"
                placeholder="输入与网页左栏一致的会话名称…"
                value={renameText}
                onInput={(e) => setRenameText((e.currentTarget as HTMLInputElement).value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    void handleSaveAlias(false);
                  } else if (e.key === 'Escape') {
                    setRenameOpen(false);
                  }
                }}
              />
              <button
                type="button"
                className="btn btn-sm btn-primary"
                disabled={renamingBusy}
                onClick={() => void handleSaveAlias(false)}
              >
                保存名称
              </button>
              <button
                type="button"
                className="btn btn-sm"
                disabled={renamingBusy}
                onClick={() => void handleSaveAlias(true)}
              >
                恢复自动
              </button>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => setRenameOpen(false)}
              >
                取消
              </button>
            </div>
          )}

          {/* Editorial Stream Hero Header (`#L5147-L5365`) */}
          <div className="hero-title-row">
            <h1
              className={`hero-stream-title ${isNarrow ? 'narrow' : ''}`.trim()}
              title={card.Title || card.ShortTitle}
            >
              {card.Title || card.ShortTitle}
            </h1>

            <div className="hero-actions-row">
              <button
                type="button"
                className="btn"
                title="一键激活并切换到对应网页标签页或桌面端会话"
                onClick={() => onOpenSessionWeb(card)}
              >
                {isNarrow ? '🌐 网页 ↗' : '🌐 打开网页 ↗'}
              </button>

              <button
                type="button"
                className="btn"
                style={{ color: 'var(--text-muted)' }}
                title="打开完整步骤与代码提交详情报告"
                onClick={() => onOpenDetail(card)}
              >
                详情
              </button>

              <button
                type="button"
                className="quiet-icon-btn"
                style={{ width: '26px', height: '26px' }}
                aria-label="修改本地会话名称"
                title="修改本地会话名称（对齐网页左栏）"
                onClick={() => {
                  setRenameText(card.Title || card.ShortTitle || '');
                  setRenameOpen((prev) => !prev);
                }}
              >
                <svg width="13.5" height="13.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M12 20h9" />
                  <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
                </svg>
              </button>

              {card.IsArchived ? (
                <>
                  <button
                    type="button"
                    className="btn btn-sm btn-soft-accent"
                    onClick={() => onRestoreAndOpen(card.SessionKey, pane.id)}
                  >
                    ↺ 还原
                  </button>
                  <button
                    type="button"
                    className="btn btn-sm btn-danger"
                    onClick={() => onRequestDeferredPurge(card)}
                  >
                    🗑 彻底删除
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  className="quiet-icon-btn"
                  style={{ width: '26px', height: '26px' }}
                  aria-label="归档此对话"
                  title="归档此对话"
                  onClick={() => onArchiveSession(card)}
                >
                  <svg width="13.5" height="13.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 8v13H3V8" />
                    <path d="M1 3h22v5H1z" />
                    <path d="M10 12h4" />
                  </svg>
                </button>
              )}
            </div>
          </div>

          {/* Full-Capsule Subtitle Pills (`border-radius: 999px`) */}
          <div className="hero-capsules-row">
            <div className="hero-step-capsule">
              <div className="mini-progress-track">
                <div
                  className="mini-progress-fill"
                  style={{ width: `${Math.max(8, progressPct)}%` }}
                />
              </div>
              <span>
                {totalSteps > 0
                  ? `已完成 ${completedSteps} / ${totalSteps} 步 (${progressPct}%)`
                  : card.StepCountText || `已执行 ${card.CommandCount || 0} 次命令`}
              </span>
            </div>

            <div className={`hero-status-capsule ${statusCapsule.tone}`}>
              <span
                className="status-dot"
                style={{ backgroundColor: statusCapsule.dotColor }}
              />
              <span>{statusCapsule.text}</span>
            </div>
          </div>

          <div className="hero-divider" />

          {/* Chronological Milestones with >3 Folding & Inline `原文` Toggle */}
          {milestones.length === 0 ? (
            <div className="milestone-empty-card">
              {card.HumanDiagnosis ||
                card.LatestSummary ||
                card.ActionText ||
                '已建立任务账本，正在等待模型回传首条阶段进展…'}
            </div>
          ) : (
            <div>
              {olderCount > 0 && (
                <>
                  <button
                    type="button"
                    className="older-milestones-btn"
                    aria-expanded={olderExpanded}
                    onClick={() => setOlderExpanded((prev) => !prev)}
                  >
                    {olderExpanded
                      ? `收起更早的 ${olderCount} 条阶段记录 ▴`
                      : `展开更早的 ${olderCount} 条阶段记录 ▾`}
                  </button>
                  {olderExpanded && olderMilestones.map(renderMilestoneBlock)}
                </>
              )}
              {recentMilestones.map(renderMilestoneBlock)}
            </div>
          )}

          {/* Single Unified Queue / Latest-Sent Banner (`#L3793-L3932`) */}
          {pendingQueue.length > 0 ? (
            <div className="unified-queue-banner pending">
              <div className="queue-banner-head">
                <span className="queue-banner-title">
                  {`⏳ 待发队列 (${pendingQueue.length} 条等待网页就绪自动填入)`}
                </span>
                <div style={{ display: 'inline-flex', alignItems: 'center', gap: '6px' }}>
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => void handleCancelAllPending()}
                  >
                    × 撤回待发
                  </button>
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => onOpenSentHistory(card.SessionKey)}
                  >
                    {`📜 发送与待发队列 (${totalQueueAndSent}) ↗`}
                  </button>
                </div>
              </div>
              <div className="queue-banner-preview">
                {`下一条待发：「${
                  pendingQueue[0]?.display_text ||
                  pendingQueue[0]?.text ||
                  pendingQueue[0]?.prompt ||
                  '请继续'
                }」`}
              </div>
            </div>
          ) : (
            latestSent && (
              <div className="unified-queue-banner">
                <div className="queue-banner-head">
                  <span className="queue-banner-title">
                    {`✓ 最新已发指令${latestSentTime ? ` · ${latestSentTime}` : ''} (已送达网页端)`}
                  </span>
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => onOpenSentHistory(card.SessionKey)}
                  >
                    {`📜 发送与待发队列 (${sentMessages.length}) ↗`}
                  </button>
                </div>
                <div className="queue-banner-preview">
                  {latestSent.display_text || latestSent.text || latestSent.prompt || '请继续'}
                </div>
                {card.VitalHintText && (
                  <div className="queue-banner-hint">{`↳ ${card.VitalHintText}`}</div>
                )}
              </div>
            )
          )}
        </div>
      </div>

      {/* Floating `↓ 回到最新进展` Dark Pill when scrolled up > 42px */}
      {distFromBottom > 42 && (
        <button
          type="button"
          className="jump-latest-pill"
          style={{ bottom: '118px' }}
          onClick={scrollToBottomSmooth}
        >
          ↓ 回到最新进展
        </button>
      )}

      {/* Docked Unified 3-Row ComposerPod */}
      <TaskComposer
        isLaunchpad={false}
        isNarrow={isNarrow}
        sessionKey={card.SessionKey}
        card={card}
        infra={infra}
        snapshot={snapshot}
        paneCount={paneCount}
        draft={draft}
        textareaRef={textareaRef}
        onDraftChange={(val) => onDraftChange(draftKey, val)}
        onTaskCreated={(newSessionKey) => {
          onUpdatePane(pane.id, { session_key: newSessionKey });
          onRefreshSnapshot();
        }}
        onActionSettled={onRefreshSnapshot}
        onToast={onToast}
      />
    </div>
  );
}
