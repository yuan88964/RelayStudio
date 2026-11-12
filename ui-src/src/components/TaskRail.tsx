import { useRef, useState } from 'preact/hooks';
import type { HostInfraBundle, StudioSessionCard } from '../types/contracts';
import { extractInfraBundle, hostRpc } from '../services/hostBridge';
import {
  formatProviderBadge,
  formatRailTaskConfigBracket,
  formatShortCarrier,
} from '../utils/formatters';

export { formatProviderBadge, formatShortCarrier };

export interface PendingPurgeItem {
  sessionKey: string;
  title: string;
}

export interface TaskRailProps {
  collapsed: boolean;
  width: number;
  sessions: StudioSessionCard[];
  visibleArchivedCount: number;
  subagentCallCount: number;
  activeSessionKeys: Set<string>;
  infra: HostInfraBundle;
  pendingPurge: PendingPurgeItem | null;
  onResizeChange: (nextWidth: number, nextCollapsed: boolean, commit: boolean) => void;
  onSelectSession: (sessionKey: string, openInNewSplit: boolean) => void;
  onCreateNewTask: () => void;
  onOpenArchiveDialog: () => void;
  onOpenSessionWeb: (card: StudioSessionCard) => void;
  onArchiveSession: (card: StudioSessionCard) => void;
  onUndoPurge: () => void;
  onDismissPurgeBanner: () => void;
  onOpenFaultTunnelHub: () => void;
  onInfraUpdated: (nextInfra: HostInfraBundle) => void;
  onToast: (message: string, level?: 'info' | 'success' | 'warning' | 'error') => void;
}

const RAIL_MIN_W = 200;
const RAIL_MAX_W = 360;
const SNAP_COLLAPSE_PX = 95;
const SNAP_REOPEN_PX = 75;

function resolveCardDotColor(card: StudioSessionCard): string {
  const sub = (card.VitalSubstate || '').trim().toUpperCase();
  if (sub === 'PSEUDO_STOPPED') return '#2563EB';
  if (sub === 'WAITING_CONFIRM' || sub === 'NETWORK_HOLD' || card.IsStalled) return '#D97706';
  if (card.VitalState === 'LIVE' || card.VitalState === 'THINKING') return '#16A34A';
  if (card.DotColor) return card.DotColor;
  return '#2563EB';
}

function resolveRailStatusMeta(card: StudioSessionCard): { text: string; color: string } {
  const sub = (card.VitalSubstate || '').trim().toUpperCase();
  if (sub === 'PSEUDO_STOPPED') {
    return { text: '假停保护中', color: 'var(--accent-text)' };
  }
  if (sub === 'WAITING_CONFIRM') {
    return { text: '疑似中断', color: 'var(--amber-text)' };
  }
  if (sub === 'NETWORK_HOLD') {
    return { text: '断网保号中', color: 'var(--amber-text)' };
  }
  if (sub === 'DUAL_STREAM') {
    return { text: '双流告警', color: 'var(--accent-text)' };
  }
  if (card.IsStalled) {
    return { text: card.StatusBadge || '已停顿', color: 'var(--amber-text)' };
  }
  if (card.VitalState === 'LIVE' || card.VitalState === 'THINKING') {
    return { text: card.StatusBadge || '执行中', color: 'var(--green-text)' };
  }
  if (card.IsCompleted) {
    return { text: card.StatusBadge || '已完成', color: 'var(--green-text)' };
  }
  return {
    text: card.StatusBadge || '待命中',
    color: 'var(--accent-text)',
  };
}

export function TaskRail({
  collapsed,
  width,
  sessions,
  visibleArchivedCount,
  subagentCallCount,
  activeSessionKeys,
  infra,
  pendingPurge,
  onResizeChange,
  onSelectSession,
  onCreateNewTask,
  onOpenArchiveDialog,
  onOpenSessionWeb,
  onArchiveSession,
  onUndoPurge,
  onDismissPurgeBanner,
  onOpenFaultTunnelHub,
  onInfraUpdated,
  onToast,
}: TaskRailProps) {
  const [dragging, setDragging] = useState(false);
  const [snapHint, setSnapHint] = useState<{ text: string; left: number } | null>(null);
  const [disconnectDismissed, setDisconnectDismissed] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const preDragWidthRef = useRef(Math.max(RAIL_MIN_W, Math.min(RAIL_MAX_W, width || 260)));

  const clampedWidth = Math.max(RAIL_MIN_W, Math.min(RAIL_MAX_W, Math.round(width || 260)));

  const handleResizerPointerDown = (e: PointerEvent) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const target = e.currentTarget as HTMLElement;
    target.setPointerCapture(e.pointerId);

    const startedCollapsed = collapsed;
    const initialComfortW = clampedWidth;
    preDragWidthRef.current = initialComfortW;
    setDragging(true);

    let pendingSnapCollapse = false;
    let pendingReopen = false;
    let latestWidth = initialComfortW;

    const onMove = (ev: PointerEvent) => {
      const x = ev.clientX;
      if (startedCollapsed) {
        if (x > SNAP_REOPEN_PX) {
          pendingReopen = true;
          latestWidth = Math.max(RAIL_MIN_W, Math.min(RAIL_MAX_W, Math.round(x)));
          setSnapHint(null);
          onResizeChange(latestWidth, false, false);
        } else {
          pendingReopen = false;
          setSnapHint(
            x > 20 ? { text: '➡ 继续向右拖拽展开任务栏', left: Math.max(12, x + 10) } : null
          );
          onResizeChange(initialComfortW, true, false);
        }
        return;
      }

      if (x < SNAP_COLLAPSE_PX) {
        pendingSnapCollapse = true;
        setSnapHint({ text: '⬅ 松手自动隐藏左栏', left: Math.max(12, x + 10) });
      } else {
        pendingSnapCollapse = false;
        setSnapHint(null);
        latestWidth = Math.max(RAIL_MIN_W, Math.min(RAIL_MAX_W, Math.round(x)));
        onResizeChange(latestWidth, false, false);
      }
    };

    const onEnd = (ev: PointerEvent) => {
      target.removeEventListener('pointermove', onMove);
      target.removeEventListener('pointerup', onEnd);
      target.removeEventListener('pointercancel', onEnd);
      try {
        target.releasePointerCapture(ev.pointerId);
      } catch {
        // Ignore
      }
      setDragging(false);
      setSnapHint(null);

      if (startedCollapsed) {
        if (pendingReopen) {
          onResizeChange(latestWidth, false, true);
        } else {
          onResizeChange(initialComfortW, true, false);
        }
      } else if (pendingSnapCollapse) {
        onResizeChange(initialComfortW, true, true);
      } else {
        onResizeChange(latestWidth, false, true);
      }
    };

    target.addEventListener('pointermove', onMove);
    target.addEventListener('pointerup', onEnd);
    target.addEventListener('pointercancel', onEnd);
  };

  const handleQuickConnect = async () => {
    if (connecting) return;
    setConnecting(true);
    try {
      const res = await hostRpc('openai_tunnel_connect');
      const next = extractInfraBundle(res);
      if (next) onInfraUpdated(next);
      onToast('已启动本地隧道连接', 'success');
    } catch (err) {
      onToast(`连接启动失败: ${err instanceof Error ? err.message : String(err)}`, 'error');
    } finally {
      setConnecting(false);
    }
  };

  return (
    <>
      <aside
        className={`task-rail ${collapsed ? 'collapsed' : ''} ${dragging ? 'dragging' : ''}`.trim()}
        style={{ width: collapsed ? '0px' : `${clampedWidth}px` }}
        aria-hidden={collapsed}
      >
        {/* Rail Header (`#L491-L501`) */}
        <div className="rail-top">
          {Boolean(infra.display?.IsFault) && (
            <button
              type="button"
              className="rail-fault-banner"
              onClick={onOpenFaultTunnelHub}
            >
              ⚠ 通道故障告警：点击检查隧道配置
            </button>
          )}

          <div className="rail-header-row">
            <span className="rail-section-label">{`进行中任务 (${sessions.length})`}</span>
            <button
              type="button"
              className="rail-new-icon-btn"
              aria-label="新建任务"
              title="新建任务"
              onClick={onCreateNewTask}
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                <path d="M12 5v14M5 12h14" />
              </svg>
            </button>
          </div>

          <div className="rail-filter-caption truncate-1">
            {subagentCallCount > 0
              ? `已合并 ${subagentCallCount} 次子代理调用`
              : '仅显示网页主对话 · 停工 >15m 自动清理'}
          </div>
        </div>

        {/* Session List or EmptySessionBox */}
        <div className="rail-session-list">
          {sessions.length === 0 ? (
            <div className="rail-empty-box">
              <div className="rail-empty-title">当前暂无进行中的任务</div>
              <div className="rail-empty-desc">
                在右侧输入需求即可立项；ChatGPT 端直接发起的任务也会自动同步至此。
              </div>
              {Boolean(infra.display?.IsFault) && (
                <button
                  type="button"
                  className="rail-empty-fault-link"
                  onClick={onOpenFaultTunnelHub}
                >
                  点击左上角连接徽标配置密钥 →
                </button>
              )}
            </div>
          ) : (
            sessions.map((card) => {
              const isSelected = activeSessionKeys.has(card.SessionKey);
              const statusMeta = resolveRailStatusMeta(card);
              const dotColor = resolveCardDotColor(card);
              const titleText = card.ShortTitle || card.Title || card.SessionKey;
              const leftSub =
                card.StepCountText || card.RailSubtitle || card.ActionText || '等待进展';
              const bracketText = formatRailTaskConfigBracket(
                card,
                infra.profiles?.Profiles
              );

              return (
                <div
                  key={card.SessionKey}
                  className={`rail-card ${isSelected ? 'active' : ''}`}
                  tabIndex={0}
                  title={card.Title || titleText}
                  onClick={(e) =>
                    onSelectSession(card.SessionKey, Boolean(e.ctrlKey || e.metaKey))
                  }
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault();
                      onSelectSession(card.SessionKey, Boolean(e.ctrlKey || e.metaKey));
                    }
                  }}
                >
                  {/* Row 1: Dot + Single-line Title + Hover-Revealed Quick Actions */}
                  <div className="rail-card-row1">
                    <span
                      className="status-dot"
                      style={{ backgroundColor: dotColor }}
                    />
                    <span className="rail-card-title">{titleText}</span>
                    <div
                      className="rail-card-quick-actions"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <button
                        type="button"
                        className="rail-quick-btn"
                        aria-label="切换到对应网页标签页"
                        title="切换到对应网页或桌面端窗口 ↗"
                        onClick={() => onOpenSessionWeb(card)}
                      >
                        <svg width="12.5" height="12.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <path d="M7 17L17 7M9 7h8v8" />
                        </svg>
                      </button>
                      <button
                        type="button"
                        className="rail-quick-btn"
                        aria-label="归档此任务"
                        title="归档此对话"
                        onClick={() => onArchiveSession(card)}
                      >
                        <svg width="12.5" height="12.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                          <path d="M21 8v13H3V8" />
                          <path d="M1 3h22v5H1z" />
                          <path d="M10 12h4" />
                        </svg>
                      </button>
                    </div>
                  </div>

                  {/* Row 2: StepCount / Subtitle + Semantic Colored Status Text */}
                  <div className="rail-card-row2">
                    <span className="rail-card-subtitle">{leftSub}</span>
                    <span
                      className="rail-card-status"
                      style={{ color: statusMeta.color }}
                    >
                      {statusMeta.text}
                    </span>
                  </div>

                  {/* Row 3: Compact Task Configuration Bracket */}
                  <div className="rail-card-row3">{bracketText}</div>
                </div>
              );
            })
          )}
        </div>

        {/* Footer (`#L518-L553`, `#L8728-L8736`) */}
        <div className="rail-footer">
          {/* 1. 8-Second Deferred Purge Undo Banner */}
          {pendingPurge && (
            <div className="rail-undo-banner">
              <span className="truncate-1" title={pendingPurge.title}>
                {`已删除「${pendingPurge.title}」`}
              </span>
              <div style={{ display: 'inline-flex', alignItems: 'center', gap: '4px', flexShrink: 0 }}>
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={onUndoPurge}
                >
                  撤销
                </button>
                <button
                  type="button"
                  className="rail-quick-btn"
                  aria-label="关闭撤销提示"
                  onClick={onDismissPurgeBanner}
                >
                  ×
                </button>
              </div>
            </div>
          )}

          {/* 2. Disconnected FeedbackBox */}
          {!infra.display?.Running && !disconnectDismissed && (
            <div className="rail-disconnect-box">
              <span className="truncate-1">隧道当前未连接</span>
              <div style={{ display: 'inline-flex', alignItems: 'center', gap: '4px', flexShrink: 0 }}>
                <button
                  type="button"
                  className="btn btn-sm"
                  disabled={connecting}
                  onClick={() => void handleQuickConnect()}
                >
                  {connecting ? '连接中…' : '立即连接'}
                </button>
                <button
                  type="button"
                  className="rail-quick-btn"
                  aria-label="忽略提示"
                  onClick={() => setDisconnectDismissed(true)}
                >
                  ×
                </button>
              </div>
            </div>
          )}

          {/* 3. OpenArchiveDrawerButton */}
          <button
            type="button"
            className="rail-archive-drawer-btn rail-archive-bar"
            onClick={onOpenArchiveDialog}
          >
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '6px' }}>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                <path d="M21 8v13H3V8" />
                <path d="M1 3h22v5H1z" />
                <path d="M10 12h4" />
              </svg>
              <span>{`归档管理 (${visibleArchivedCount})`}</span>
            </span>
            <span className="rail-archive-right">管理 ▸</span>
          </button>
        </div>
      </aside>

      {/* Always-mounted 7px RailResizerBar so dragging right > 75px from left edge re-opens collapsed rail (`#L8373-L8384`) */}
      <div
        className={`rail-resizer ${dragging ? 'active' : ''}`}
        title={
          collapsed
            ? '向右拖拽 >75px 或双击展开左侧任务栏'
            : '左右拖拽调整左栏宽度（向左拖至边缘自动吸附隐藏）'
        }
        onPointerDown={handleResizerPointerDown}
        onDblClick={() => onResizeChange(clampedWidth, !collapsed, true)}
      >
        <span className="rail-resizer-grip" aria-hidden="true">
          ⋮
        </span>
      </div>

      {snapHint && (
        <div
          className="snap-floating-badge"
          style={{ left: `${snapHint.left}px` }}
        >
          {snapHint.text}
        </div>
      )}
    </>
  );
}
