import type { ComponentChildren } from 'preact';
import { useCallback, useEffect, useId, useRef, useState } from 'preact/hooks';
import type {
  GitCommitItem,
  HostInfraBundle,
  QueuedMessageItem,
  StudioSessionCard,
} from '../types/contracts';
import { hostRpc } from '../services/hostBridge';
import { postStudioAction } from '../services/studioHub';
import { formatProviderBadge, formatShortCarrier } from '../utils/formatters';

/**
 * Coordinate-based light-dismiss fallback hook for `<dialog>` runtimes where
 * declarative `closedby="any"` (`HTMLDialogElement.prototype.closedBy`) is unavailable.
 */
function useDialogLightDismissFallback(dialogRef: { current: HTMLDialogElement | null }) {
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (typeof HTMLDialogElement === 'undefined' || 'closedBy' in HTMLDialogElement.prototype) {
      return;
    }

    const isOutsideRect = (e: PointerEvent, el: HTMLDialogElement): boolean => {
      const r = el.getBoundingClientRect();
      return (
        e.clientX < r.left ||
        e.clientX > r.right ||
        e.clientY < r.top ||
        e.clientY > r.bottom
      );
    };

    let pressedOutside = false;
    const onPointerDown = (e: PointerEvent) => {
      pressedOutside = dialog.open && isOutsideRect(e, dialog);
    };
    const onPointerUp = (e: PointerEvent) => {
      if (pressedOutside && dialog.open && isOutsideRect(e, dialog)) {
        dialog.close();
      }
      pressedOutside = false;
    };

    dialog.addEventListener('pointerdown', onPointerDown);
    dialog.addEventListener('pointerup', onPointerUp);
    return () => {
      dialog.removeEventListener('pointerdown', onPointerDown);
      dialog.removeEventListener('pointerup', onPointerUp);
    };
  }, [dialogRef]);
}

interface EditorialModalShellProps {
  open: boolean;
  sizeClass: 'sz-detail' | 'sz-archive' | 'sz-history';
  title: string;
  subtitle?: string;
  subtitleTitle?: string;
  headerRight?: ComponentChildren;
  closeLabel?: string;
  footer?: ComponentChildren;
  onClose: () => void;
  children: ComponentChildren;
}

/**
 * Reusable Native `<dialog>` Modal Wrapper strictly adhering to `modern-web-guidance`:
 * - Opened via `showModal()`, NEVER `role="dialog"` or `aria-modal`
 * - Declarative `closedby="any"` + coordinate fallback
 * - Resets `el.returnValue = ''` in `onClose`
 */
function EditorialModalShell({
  open,
  sizeClass,
  title,
  subtitle,
  subtitleTitle,
  headerRight,
  closeLabel = '× 关闭',
  footer,
  onClose,
  children,
}: EditorialModalShellProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const titleId = useId();

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open) {
      if (!dialog.open) {
        try {
          dialog.showModal();
        } catch {
          // Ignore if already open
        }
      }
    } else if (dialog.open) {
      dialog.close();
    }
  }, [open]);

  useDialogLightDismissFallback(dialogRef);

  return (
    <dialog
      ref={dialogRef}
      className={`studio-dialog ${sizeClass}`}
      aria-labelledby={titleId}
      {...({ closedby: 'any' } as any)}
      onClose={(e) => {
        const el = e.currentTarget as HTMLDialogElement;
        el.returnValue = '';
        onClose();
      }}
    >
      <div className="ed-modal-header">
        <div className="ed-modal-heading-wrap">
          <h2 id={titleId} className="ed-modal-title">
            {title}
          </h2>
          {subtitle && (
            <div className="ed-modal-subtitle" title={subtitleTitle || subtitle}>
              {subtitle}
            </div>
          )}
        </div>

        <div className="ed-modal-header-actions">
          {headerRight}
          <button
            type="button"
            autoFocus
            className="th-btn th-btn-secondary"
            onClick={() => dialogRef.current?.close()}
          >
            {closeLabel}
          </button>
        </div>
      </div>

      {open ? <div className="ed-modal-body">{children}</div> : null}

      {open && footer ? <div className="ed-modal-footer">{footer}</div> : null}
    </dialog>
  );
}

// ======================== 1. ARCHIVE DIALOG ========================

export interface ArchiveDialogProps {
  open: boolean;
  archivedSessions: StudioSessionCard[];
  pendingPurgeKey?: string | null;
  infra: HostInfraBundle;
  onClose: () => void;
  onRestoreAndOpen: (sessionKey: string) => void;
  onOpenDetail: (card: StudioSessionCard) => void;
  onRequestDeferredPurge: (card: StudioSessionCard) => void;
  onOpenSessionWeb: (card: StudioSessionCard) => void;
  onRefreshSnapshot: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

export function ArchiveDialog({
  open,
  archivedSessions,
  pendingPurgeKey,
  infra,
  onClose,
  onRestoreAndOpen,
  onOpenDetail,
  onRequestDeferredPurge,
  onRefreshSnapshot,
  onToast,
}: ArchiveDialogProps) {
  const [confirmPurgeAll, setConfirmPurgeAll] = useState<boolean>(false);
  const [busyKey, setBusyKey] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setConfirmPurgeAll(false);
    }
  }, [open]);

  // Immediately hide any session undergoing the 8-second UndoDeleteBorder deferred purge
  const visibleArchived = (archivedSessions || []).filter(
    (s) => !pendingPurgeKey || s.SessionKey !== pendingPurgeKey
  );

  const handleRestore = async (card: StudioSessionCard) => {
    setBusyKey(`restore_${card.SessionKey}`);
    try {
      await postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
        action: 'restore',
        session_key: card.SessionKey,
      });
      onRefreshSnapshot();
      onRestoreAndOpen(card.SessionKey);
      onToast(`已将「${card.Title || card.ShortTitle || card.SessionKey}」还原至工作台`, 'success');
    } catch (err) {
      onToast(`还原失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setBusyKey(null);
    }
  };

  const handlePurgeAll = async () => {
    setBusyKey('purge_all');
    try {
      await postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
        action: 'purge_all_archived',
      });
      setConfirmPurgeAll(false);
      onRefreshSnapshot();
      onToast('已一键清空全部归档记录', 'info');
    } catch (err) {
      onToast(`清空失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setBusyKey(null);
    }
  };

  return (
    <EditorialModalShell
      open={open}
      sizeClass="sz-archive"
      title={`📦 已归档会话管理 (${visibleArchived.length})`}
      closeLabel="× 关闭"
      headerRight={
        visibleArchived.length > 0 ? (
          confirmPurgeAll ? (
            <div className="ed-inline-confirm-group">
              <button
                type="button"
                className="th-btn ed-btn-danger"
                disabled={Boolean(busyKey)}
                onClick={() => void handlePurgeAll()}
              >
                {busyKey === 'purge_all' ? '清空中…' : `确认清空 (${visibleArchived.length})`}
              </button>
              <button
                type="button"
                className="th-btn th-btn-secondary"
                disabled={Boolean(busyKey)}
                onClick={() => setConfirmPurgeAll(false)}
              >
                取消
              </button>
            </div>
          ) : (
            <button
              type="button"
              className="th-btn ed-btn-danger-soft"
              disabled={Boolean(busyKey)}
              onClick={() => setConfirmPurgeAll(true)}
            >
              🗑 一键清空全部归档
            </button>
          )
        ) : null
      }
      onClose={onClose}
    >
      {visibleArchived.length === 0 ? (
        <div className="ed-empty-state">当前没有已归档的任务会话记录。</div>
      ) : (
        <div className="ed-list-stack">
          {visibleArchived.map((card) => {
            const titleText = card.Title || card.ShortTitle || card.SessionKey;
            const timePart = card.ArchivedAtText || card.AgoText || '近期归档';
            const summaryPart = card.ActionText || card.StepCountText || '';
            return (
              <div key={card.SessionKey} className="ed-archive-row">
                <div className="ed-archive-main">
                  <div className="ed-archive-line1">
                    <span className="ed-archive-title" title={titleText}>
                      {titleText}
                    </span>
                    <span className="ed-badge ed-badge-neutral">
                      {card.ArchiveReason || '已归档'}
                    </span>
                    <span className="ed-badge ed-badge-faint">
                      {formatProviderBadge(card.Provider)} ·{' '}
                      {formatShortCarrier(card.Carrier || card.BrowserProfile)}
                    </span>
                  </div>
                  <div className="ed-archive-line2">
                    {timePart}
                    {summaryPart ? ` · ${summaryPart}` : ''}
                  </div>
                </div>

                <div className="ed-archive-actions">
                  <button
                    type="button"
                    className="th-btn th-btn-secondary"
                    onClick={() => onOpenDetail(card)}
                  >
                    详情
                  </button>
                  <button
                    type="button"
                    className="th-btn th-btn-primary"
                    disabled={Boolean(busyKey)}
                    onClick={() => void handleRestore(card)}
                  >
                    ↺ 还原
                  </button>
                  <button
                    type="button"
                    className="ed-trash-icon-btn"
                    title="彻底删除（8 秒内可撤销）"
                    aria-label={`删除 ${titleText}`}
                    onClick={() => onRequestDeferredPurge(card)}
                  >
                    🗑
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </EditorialModalShell>
  );
}

// ======================== 2. SENT HISTORY DIALOG ========================

export interface SentHistoryDialogProps {
  open: boolean;
  sessionKey?: string | null;
  sessions: StudioSessionCard[];
  archivedSessions: StudioSessionCard[];
  infra: HostInfraBundle;
  onClose: () => void;
  onJumpToSession: (sessionKey: string) => void;
  onRefreshSnapshot: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

interface ScopedQueueEntry {
  msg: QueuedMessageItem;
  sessionKey: string;
  sessionTitle: string;
  isArchived: boolean;
  sortKey: string;
}

function formatMessageModeTag(msg: QueuedMessageItem): string {
  if (msg.mode === 'new_window_handover') {
    return msg.defer_until_stopped ? '新窗交接 · 等停稳后派发' : '新窗交接';
  }
  if (msg.mode === 'in_place_wakeup') {
    return '原地续推唤醒';
  }
  return msg.defer_until_stopped ? '排队追加 · 等停稳后派发' : '网页追加指令';
}

function formatIsoClock(raw?: string): string {
  const s = (raw || '').trim();
  if (!s) return '';
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(
    d.getMinutes()
  )}:${pad(d.getSeconds())}`;
}

export function SentHistoryDialog({
  open,
  sessionKey,
  sessions,
  archivedSessions,
  infra,
  onClose,
  onJumpToSession,
  onRefreshSnapshot,
  onToast,
}: SentHistoryDialogProps) {
  const [showAllSessions, setShowAllSessions] = useState<boolean>(false);
  const [busyMsgId, setBusyMsgId] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setShowAllSessions(false);
    }
  }, [open, sessionKey]);

  const allCards = [...(sessions || []), ...(archivedSessions || [])];
  const scopedKey = !showAllSessions && sessionKey ? sessionKey : null;
  const scopedCard = scopedKey
    ? allCards.find((c) => c.SessionKey === scopedKey) || null
    : null;

  const targetCards = scopedKey ? (scopedCard ? [scopedCard] : []) : allCards;

  const pendingRows: ScopedQueueEntry[] = [];
  const deliveredRows: ScopedQueueEntry[] = [];

  for (const c of targetCards) {
    const sTitle = c.Title || c.ShortTitle || c.SessionKey;
    const isArch = Boolean(c.IsArchived);
    for (const pm of c.PendingQueue || []) {
      if (pm.status === 'cancelled') continue;
      pendingRows.push({
        msg: pm,
        sessionKey: c.SessionKey,
        sessionTitle: sTitle,
        isArchived: isArch,
        sortKey: pm.created_at || pm.claimed_at || '',
      });
    }
    for (const dm of c.SentWebMessages || []) {
      deliveredRows.push({
        msg: dm,
        sessionKey: c.SessionKey,
        sessionTitle: sTitle,
        isArchived: isArch,
        sortKey: dm.delivered_at || dm.created_at || '',
      });
    }
  }

  // Delivered newest-first
  deliveredRows.sort((a, b) => b.sortKey.localeCompare(a.sortKey));

  const handleCancelPending = async (entry: ScopedQueueEntry) => {
    if (!entry.msg.id) return;
    setBusyMsgId(entry.msg.id);
    try {
      await postStudioAction(infra.shieldBaseUrl, infra.studioToken, {
        action: 'delete_queued_message',
        session_key: entry.sessionKey,
        msg_id: entry.msg.id,
        id: entry.msg.id,
      });
      onRefreshSnapshot();
      onToast('已撤回排队中的待发指令', 'info');
    } catch (err) {
      onToast(`撤回失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setBusyMsgId(null);
    }
  };

  const handleCopyFullPrompt = async (msg: QueuedMessageItem) => {
    const fullText = msg.prompt || msg.text || msg.display_text || '';
    if (!fullText) {
      onToast('该条记录无可复制正文', 'warning');
      return;
    }
    try {
      await hostRpc('copy_clipboard', { text: fullText });
      onToast('已复制完整指令到剪贴板', 'success');
    } catch (err) {
      onToast(err instanceof Error ? err.message : String(err), 'error');
    }
  };

  const modalTitle = scopedCard
    ? `📜 发送与待发队列 · ${scopedCard.Title || scopedCard.ShortTitle || scopedCard.SessionKey}`
    : scopedKey
      ? `📜 发送与待发队列 · ${scopedKey}`
      : '📜 发送与待发队列 · 全部会话';

  return (
    <EditorialModalShell
      open={open}
      sizeClass="sz-history"
      title={modalTitle}
      closeLabel="关闭"
      headerRight={
        sessionKey ? (
          <button
            type="button"
            className="th-btn th-btn-secondary"
            onClick={() => setShowAllSessions((v) => !v)}
          >
            {showAllSessions ? '仅看当前会话' : '查看全部会话'}
          </button>
        ) : null
      }
      onClose={onClose}
    >
      {pendingRows.length === 0 && deliveredRows.length === 0 ? (
        <div className="ed-empty-state">暂无待发排队或已送达网页端的历史指令记录。</div>
      ) : (
        <div className="ed-sections-stack">
          {/* Pending Queue Section */}
          {pendingRows.length > 0 && (
            <section className="ed-section">
              <div className="ed-section-title">
                待发排队队列（{pendingRows.length} 条）
              </div>
              <div className="ed-list-stack">
                {pendingRows.map((entry, idx) => {
                  const preview =
                    entry.msg.display_text || entry.msg.text || entry.msg.prompt || '';
                  const tsText = formatIsoClock(entry.msg.created_at || entry.msg.claimed_at);
                  return (
                    <div key={entry.msg.id || `pend_${idx}`} className="ed-msg-card is-pending">
                      <div className="ed-msg-head">
                        <div className="ed-msg-tags">
                          <span className="ed-badge ed-badge-amber">排队 #{idx + 1}</span>
                          <span className="ed-badge ed-badge-neutral">
                            {formatMessageModeTag(entry.msg)}
                          </span>
                          {entry.msg.status === 'claimed' && (
                            <span className="ed-badge ed-badge-blue">正在投递网页…</span>
                          )}
                          {!scopedKey && (
                            <button
                              type="button"
                              className="ed-session-jump-pill"
                              onClick={() => {
                                if (!entry.isArchived) {
                                  onClose();
                                  onJumpToSession(entry.sessionKey);
                                }
                              }}
                            >
                              {entry.sessionTitle}
                            </button>
                          )}
                        </div>

                        <div className="ed-msg-actions">
                          {tsText && <span className="ed-msg-time">{tsText}</span>}
                          <button
                            type="button"
                            className="th-btn th-btn-secondary"
                            onClick={() => void handleCopyFullPrompt(entry.msg)}
                          >
                            复制全文
                          </button>
                          {entry.msg.status === 'pending' && (
                            <button
                              type="button"
                              className="th-btn ed-btn-danger-soft"
                              disabled={busyMsgId === entry.msg.id}
                              onClick={() => void handleCancelPending(entry)}
                            >
                              × 撤回
                            </button>
                          )}
                        </div>
                      </div>

                      <div className="ed-msg-body selectable-copy">{preview}</div>
                    </div>
                  );
                })}
              </div>
            </section>
          )}

          {/* Delivered History Section */}
          {deliveredRows.length > 0 && (
            <section className="ed-section">
              <div className="ed-section-title">
                已发历史流水（{deliveredRows.length} 条）
              </div>
              <div className="ed-list-stack">
                {deliveredRows.slice(0, 120).map((entry, idx) => {
                  const preview =
                    entry.msg.display_text || entry.msg.text || entry.msg.prompt || '';
                  const tsText = formatIsoClock(
                    entry.msg.delivered_at || entry.msg.created_at
                  );
                  const isNewest = idx === 0;
                  return (
                    <div
                      key={entry.msg.id || `deliv_${idx}`}
                      className={`ed-msg-card ${isNewest ? 'is-newest' : ''}`}
                    >
                      <div className="ed-msg-head">
                        <div className="ed-msg-tags">
                          {isNewest && <span className="ed-badge ed-badge-blue">最新</span>}
                          <span className="ed-msg-delivered-label">✓ 已送达网页端</span>
                          <span className="ed-badge ed-badge-faint">
                            {formatMessageModeTag(entry.msg)}
                          </span>
                          {!scopedKey && (
                            <button
                              type="button"
                              className="ed-session-jump-pill"
                              onClick={() => {
                                if (!entry.isArchived) {
                                  onClose();
                                  onJumpToSession(entry.sessionKey);
                                }
                              }}
                            >
                              {entry.sessionTitle}
                            </button>
                          )}
                        </div>

                        <div className="ed-msg-actions">
                          {tsText && <span className="ed-msg-time">{tsText}</span>}
                          <button
                            type="button"
                            className="th-btn th-btn-secondary"
                            onClick={() => void handleCopyFullPrompt(entry.msg)}
                          >
                            复制全文
                          </button>
                        </div>
                      </div>

                      <div className="ed-msg-body selectable-copy">{preview}</div>
                    </div>
                  );
                })}
              </div>
            </section>
          )}
        </div>
      )}
    </EditorialModalShell>
  );
}

// ======================== 3. SESSION DETAIL DIALOG ========================

export interface SessionDetailDialogProps {
  open: boolean;
  card: StudioSessionCard | null;
  onClose: () => void;
  onOpenSessionWeb: (card: StudioSessionCard) => void;
  onOpenWorkspace: (workspaceRoot: string) => void;
  onArchiveSession: (sessionKey: string) => Promise<void>;
  onRefreshSnapshot?: () => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

interface NormalizedCheckpointRow {
  time: string;
  title: string;
  summary: string;
}

function normalizeCheckpointItems(card: StudioSessionCard): NormalizedCheckpointRow[] {
  const rawList =
    card.ReadableCheckpoints && card.ReadableCheckpoints.length > 0
      ? card.ReadableCheckpoints
      : card.Milestones && card.Milestones.length > 0
        ? card.Milestones
        : card.Checkpoints || [];

  const out: NormalizedCheckpointRow[] = [];
  for (const item of rawList) {
    if (!item) continue;
    if (typeof item === 'string') {
      out.push({ time: '', title: item, summary: '' });
      continue;
    }
    if (typeof item === 'object') {
      const time = String(
        item.TimeText || item.time_text || item.time || item.timestamp || item.created_at || ''
      ).trim();
      const title = String(
        item.Title || item.title || item.step_title || item.label || item.step_id || ''
      ).trim();
      const summary = String(
        item.Summary || item.summary || item.message || item.detail || item.text || ''
      ).trim();
      if (title || summary) {
        out.push({
          time: time.includes('T') ? formatIsoClock(time) : time,
          title: title || summary,
          summary: title && summary && summary !== title ? summary : '',
        });
      }
    }
  }
  return out;
}

function mergeWorkspaceCommits(
  liveCommits: GitCommitItem[],
  cardCommits: GitCommitItem[] | undefined
): GitCommitItem[] {
  const seen = new Set<string>();
  const merged: GitCommitItem[] = [];
  for (const c of [...liveCommits, ...(cardCommits || [])]) {
    if (!c) continue;
    const key = (c.Hash || c.ShortHash || `${c.Subject}_${c.TimeAgo}`).trim();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    merged.push(c);
  }
  return merged.slice(0, 12);
}

export function SessionDetailDialog({
  open,
  card,
  onClose,
  onOpenSessionWeb,
  onOpenWorkspace,
  onRefreshSnapshot,
  onToast,
}: SessionDetailDialogProps) {
  const [liveCommits, setLiveCommits] = useState<GitCommitItem[]>([]);
  const [refreshing, setRefreshing] = useState<boolean>(false);

  const fetchCommits = useCallback(async (target: StudioSessionCard | null) => {
    if (!target || (!target.WorkspaceRoot && !target.WorkspaceName)) {
      setLiveCommits([]);
      return;
    }
    try {
      const res = await hostRpc<any>('get_workspace_commits', {
        workspaceRoot: target.WorkspaceRoot || '',
        workspaceName: target.WorkspaceName || '',
      });
      const list = Array.isArray(res)
        ? res
        : Array.isArray(res?.commits)
          ? res.commits
          : [];
      setLiveCommits(list);
    } catch {
      // Fall back quietly to snapshot commits
    }
  }, []);

  useEffect(() => {
    if (!open || !card) {
      setLiveCommits([]);
      return;
    }
    void fetchCommits(card);
  }, [open, card?.SessionKey, card?.WorkspaceRoot, fetchCommits]);

  const fullGoalText = (card?.CleanGoal || card?.Goal || '未显式登记目标').trim();
  const oneLineGoal = `任务目标：${fullGoalText.replace(/\s+/g, ' ')}`;

  const progressPct = card
    ? Math.min(100, Math.max(0, Number(card.ProgressPercent) || 0))
    : 0;

  const mergedCommits = card ? mergeWorkspaceCommits(liveCommits, card.RecentCommits) : [];
  const checkpoints = card ? normalizeCheckpointItems(card) : [];

  const statusToneClass = card?.IsCompleted
    ? 'ed-badge-green'
    : card?.IsStalled || card?.BreakerTripped
      ? 'ed-badge-amber'
      : card?.VitalState === 'LIVE' || card?.VitalState === 'THINKING'
        ? 'ed-badge-blue'
        : 'ed-badge-neutral';

  return (
    <EditorialModalShell
      open={open && Boolean(card)}
      sizeClass="sz-detail"
      title={card ? card.Title || card.ShortTitle || card.SessionKey : '任务详情'}
      subtitle={card ? oneLineGoal : undefined}
      subtitleTitle={fullGoalText}
      closeLabel="关闭"
      headerRight={
        card ? (
          <>
            <span className={`ed-badge ${statusToneClass}`}>
              {card.StatusBadge || card.VitalState || '待命'}
            </span>
            <button
              type="button"
              className="th-btn th-btn-secondary"
              onClick={() => onOpenSessionWeb(card)}
            >
              🌐 打开网页 ↗
            </button>
          </>
        ) : null
      }
      footer={
        card ? (
          <div className="ed-detail-footer-row">
            <span className="ed-detail-sync-hint">
              每 2 秒自动同步最新任务进度与代码库提交
            </span>
            <button
              type="button"
              className="th-btn th-btn-secondary"
              disabled={refreshing}
              onClick={() => {
                setRefreshing(true);
                onRefreshSnapshot?.();
                void fetchCommits(card)
                  .then(() => onToast('已同步最新任务进度与代码提交', 'info'))
                  .finally(() => setRefreshing(false));
              }}
            >
              {refreshing ? '刷新中…' : '立即刷新'}
            </button>
          </div>
        ) : null
      }
      onClose={onClose}
    >
      {card && (
        <div className="ed-sections-stack">
          {/* Top Blue Diagnosis Summary Card */}
          <div className="ed-diagnosis-banner">
            <div className="ed-diagnosis-top">
              <div className="ed-diagnosis-text selectable-copy">
                {card.HumanDiagnosis ||
                  card.ProgressText ||
                  card.ActionText ||
                  '正在监听 MCP 工具调用与网页端实时体征…'}
              </div>
              <span className="ed-diagnosis-step-count">
                {card.StepCountText ||
                  (card.TotalStepCount > 0
                    ? `${card.CompletedStepCount}/${card.TotalStepCount} 步 (${progressPct}%)`
                    : card.ProgressText || '直连模式')}
              </span>
            </div>

            <div className="ed-progress-track">
              <div
                className="ed-progress-fill"
                style={{ width: `${card.TotalStepCount > 0 ? progressPct : card.IsCompleted ? 100 : 0}%` }}
              />
            </div>
          </div>

          {/* 一、阶段闯关进度（Steps） */}
          <section className="ed-section">
            <div className="ed-section-title">一、阶段闯关进度（Steps）</div>
            {!card.Steps || card.Steps.length === 0 ? (
              <div className="ed-muted-box">
                当前对话未创建分步契约（tsk_*.json），直接通过 MCP 转发工具指令。
              </div>
            ) : (
              <div className="ed-steps-list">
                {card.Steps.map((st, idx) => {
                  const rawStatus = (st.status || 'pending').toLowerCase();
                  const badgeInfo =
                    rawStatus === 'completed' || rawStatus === 'done'
                      ? { text: '✓ 已完成', cls: 'ed-badge-green' }
                      : rawStatus === 'in_progress' || rawStatus === 'active'
                        ? { text: '● 进行中', cls: 'ed-badge-blue' }
                        : rawStatus === 'quarantined' || rawStatus === 'blocked'
                          ? { text: '⚠ 已隔离', cls: 'ed-badge-amber' }
                          : { text: '○ 待执行', cls: 'ed-badge-neutral' };

                  const stepNo = st.id || String(idx + 1);
                  const stepLabel = /^步骤/.test(stepNo)
                    ? `${stepNo}：${st.title}`
                    : `步骤 ${stepNo}：${st.title}`;

                  return (
                    <div key={`${stepNo}_${idx}`} className="ed-step-row">
                      <span className={`ed-badge ${badgeInfo.cls}`}>{badgeInfo.text}</span>
                      <span className="ed-step-title selectable-copy">{stepLabel}</span>
                    </div>
                  );
                })}
              </div>
            )}
          </section>

          {/* 二、最新进展战报与代码库实时提交 */}
          <section className="ed-section">
            <div className="ed-section-head-row">
              <div className="ed-section-title">二、最新进展战报与代码库实时提交</div>
              {card.WorkspaceRoot && (
                <button
                  type="button"
                  className="th-btn th-btn-secondary gs-compact-btn"
                  title={card.WorkspaceRoot}
                  onClick={() => onOpenWorkspace(card.WorkspaceRoot)}
                >
                  📁 打开目录
                </button>
              )}
            </div>

            <div className="ed-summary-card selectable-copy">
              {card.LatestSummary || card.ActionText || '暂未收到阶段小结，正在等待模型回传最新动作。'}
            </div>

            {mergedCommits.length > 0 && (
              <div className="ed-commits-box">
                {mergedCommits.map((cm, idx) => (
                  <div key={cm.Hash || `${cm.ShortHash}_${idx}`} className="ed-commit-row">
                    <span className="ed-commit-hash selectable-copy">
                      {cm.ShortHash || (cm.Hash ? cm.Hash.slice(0, 7) : 'commit')}
                    </span>
                    <span className="ed-commit-subject selectable-copy" title={cm.Subject}>
                      {cm.Subject}
                    </span>
                    {cm.TimeAgo && <span className="ed-commit-time">{cm.TimeAgo}</span>}
                  </div>
                ))}
              </div>
            )}
          </section>

          {/* 三、近期里程碑时间线（Checkpoints） */}
          <section className="ed-section">
            <div className="ed-section-title">三、近期里程碑时间线（Checkpoints）</div>
            {checkpoints.length === 0 ? (
              <div className="ed-muted-box">暂无已登记的阶段里程碑记录。</div>
            ) : (
              <div className="ed-timeline-list">
                {checkpoints.map((cp, idx) => (
                  <div key={idx} className="ed-timeline-item">
                    <div className="ed-timeline-head">
                      <span className="ed-timeline-dot" />
                      <span className="ed-timeline-title selectable-copy">{cp.title}</span>
                      {cp.time && <span className="ed-timeline-time">{cp.time}</span>}
                    </div>
                    {cp.summary && (
                      <div className="ed-timeline-summary selectable-copy">{cp.summary}</div>
                    )}
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </EditorialModalShell>
  );
}

// ======================== 4. LIVE HANDOVER CONFIRM DIALOG ========================

export type LiveHandoverDecision = 'defer' | 'stop_and_retire' | 'cancel';

export interface LiveHandoverConfirmDialogProps {
  open: boolean;
  providerLabel?: string;
  onDecision: (decision: LiveHandoverDecision) => void;
}

export function LiveHandoverConfirmDialog({
  open,
  providerLabel,
  onDecision,
}: LiveHandoverConfirmDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const decidedRef = useRef<boolean>(false);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open) {
      decidedRef.current = false;
      if (!dialog.open) {
        try {
          dialog.showModal();
        } catch {
          // Ignore if already open
        }
      }
    } else if (dialog.open) {
      dialog.close();
    }
  }, [open]);

  useDialogLightDismissFallback(dialogRef);

  const choose = (decision: LiveHandoverDecision) => {
    if (decidedRef.current) return;
    decidedRef.current = true;
    dialogRef.current?.close();
    onDecision(decision);
  };

  const platName = (providerLabel || 'ChatGPT').trim() || 'ChatGPT';

  return (
    <dialog
      ref={dialogRef}
      className="studio-dialog sz-handover"
      aria-labelledby={titleId}
      {...({ closedby: 'any' } as any)}
      onClose={(e) => {
        const el = e.currentTarget as HTMLDialogElement;
        el.returnValue = '';
        if (!decidedRef.current) {
          decidedRef.current = true;
          onDecision('cancel');
        }
      }}
    >
      {open ? (
        <div className="ed-handover-body">
          <h2 id={titleId} className="ed-handover-title">
            检测到原 {platName} 网页当前仍在运行中
          </h2>
          <p className="ed-handover-desc">
            直接再开新窗口会导致两个会话同时跑同一份任务并双倍消耗额度。请选择交接方式：
          </p>

          <div className="ed-handover-stack">
            <button
              type="button"
              className="ed-handover-btn is-primary"
              autoFocus
              onClick={() => choose('defer')}
            >
              ⏳ 等原网页本轮停稳后自动换新窗接力（推荐）
            </button>

            <button
              type="button"
              className="ed-handover-btn is-danger"
              onClick={() => choose('stop_and_retire')}
            >
              ⏹ 立即停止原网页并换新窗
            </button>

            <button
              type="button"
              className="ed-handover-btn is-neutral"
              onClick={() => choose('cancel')}
            >
              取消（保留当前输入草稿）
            </button>
          </div>
        </div>
      ) : null}
    </dialog>
  );
}
