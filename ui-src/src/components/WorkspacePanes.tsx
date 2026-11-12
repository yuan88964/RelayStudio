import { useEffect, useRef, useState } from 'preact/hooks';
import type {
  HostInfraBundle,
  PaneMemoryItem,
  StudioSessionCard,
  StudioSnapshot,
} from '../types/contracts';
import { TaskPane } from './TaskPane';

export interface WorkspacePanesProps {
  railCollapsed: boolean;
  panes: PaneMemoryItem[];
  sessions: StudioSessionCard[];
  archivedSessions: StudioSessionCard[];
  infra: HostInfraBundle;
  snapshot: StudioSnapshot | null;
  drafts: Record<string, string>;
  composerFocusSignal: number;
  onDraftChange: (draftKey: string, nextDraft: string) => void;
  onUpdatePane: (paneId: number, patch: Partial<PaneMemoryItem>) => void;
  onResizePanes: (nextWeights: number[], commit: boolean) => void;
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

const SNAP_CLOSE_PANE_PX = 140;

export function WorkspacePanes({
  railCollapsed,
  panes,
  sessions,
  archivedSessions,
  infra,
  snapshot,
  drafts,
  composerFocusSignal,
  onDraftChange,
  onUpdatePane,
  onResizePanes,
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
}: WorkspacePanesProps) {
  const containerRef = useRef<HTMLElement>(null);
  const prevPaneIdsRef = useRef<Set<number>>(new Set(panes.map((p) => p.id)));
  const [recentSplitIds, setRecentSplitIds] = useState<Set<number>>(new Set());
  const [activeResizerIdx, setActiveResizerIdx] = useState<number | null>(null);
  const [snapCloseBadge, setSnapCloseBadge] = useState<{
    paneId: number;
    left: number;
  } | null>(null);

  useEffect(() => {
    const prev = prevPaneIdsRef.current;
    const added: number[] = [];
    for (const p of panes) {
      if (!prev.has(p.id)) added.push(p.id);
    }
    prevPaneIdsRef.current = new Set(panes.map((p) => p.id));
    if (added.length > 0) {
      setRecentSplitIds(new Set(added));
      const t = window.setTimeout(() => setRecentSplitIds(new Set()), 220);
      return () => window.clearTimeout(t);
    }
  }, [panes]);

  const handleResizerPointerDown = (dividerIdx: number, e: PointerEvent) => {
    if (e.button !== 0 || panes.length < 2) return;
    e.preventDefault();
    const container = containerRef.current;
    if (!container) return;

    const target = e.currentTarget as HTMLElement;
    target.setPointerCapture(e.pointerId);
    setActiveResizerIdx(dividerIdx);

    const slotNodes = Array.from(
      container.querySelectorAll<HTMLElement>('.workspace-pane-slot')
    );
    const startWidths = slotNodes.map((el) => el.getBoundingClientRect().width);
    const totalPx = startWidths.reduce((a, b) => a + b, 0) || container.clientWidth || 1;
    const startX = e.clientX;

    let snapCloseTargetId: number | null = null;
    let latestWeights = panes.map((p) => Math.max(0.15, Number(p.width_weight) || 1));

    const onMove = (ev: PointerEvent) => {
      const dx = ev.clientX - startX;
      const leftPx = startWidths[dividerIdx] + dx;
      const rightPx = startWidths[dividerIdx + 1] - dx;

      if (panes.length > 1 && leftPx < SNAP_CLOSE_PANE_PX) {
        snapCloseTargetId = panes[dividerIdx].id;
        setSnapCloseBadge({
          paneId: snapCloseTargetId,
          left: Math.max(24, ev.clientX - 60),
        });
      } else if (panes.length > 1 && rightPx < SNAP_CLOSE_PANE_PX) {
        snapCloseTargetId = panes[dividerIdx + 1].id;
        setSnapCloseBadge({
          paneId: snapCloseTargetId,
          left: Math.max(24, ev.clientX - 60),
        });
      } else {
        snapCloseTargetId = null;
        setSnapCloseBadge(null);
      }

      const clampedLeft = Math.max(110, Math.min(startWidths[dividerIdx] + startWidths[dividerIdx + 1] - 110, leftPx));
      const clampedRight = startWidths[dividerIdx] + startWidths[dividerIdx + 1] - clampedLeft;

      const nextPx = [...startWidths];
      nextPx[dividerIdx] = clampedLeft;
      nextPx[dividerIdx + 1] = clampedRight;

      latestWeights = nextPx.map((px) =>
        Math.max(0.15, Number(((px / totalPx) * panes.length).toFixed(4)))
      );
      onResizePanes(latestWeights, false);
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
      setActiveResizerIdx(null);
      setSnapCloseBadge(null);

      if (snapCloseTargetId !== null && panes.length > 1) {
        onClosePane(snapCloseTargetId);
      } else {
        onResizePanes(latestWeights, true);
      }
    };

    target.addEventListener('pointermove', onMove);
    target.addEventListener('pointerup', onEnd);
    target.addEventListener('pointercancel', onEnd);
  };

  return (
    <section
      ref={containerRef}
      className={`workspace-outer-border ${railCollapsed ? 'rail-collapsed' : ''}`.trim()}
    >
      {panes.map((pane, idx) => {
        const isZero =
          pane.session_key === '__launchpad__' ||
          (!pane.session_key ||
            (pane.session_key !== '__picker__' &&
              !sessions.some((s) => s.SessionKey === pane.session_key) &&
              !archivedSessions.some((s) => s.SessionKey === pane.session_key)));
        const draftKey = isZero
          ? `__launchpad_${pane.id}__`
          : pane.session_key || '__new_task__';
        const weight = Math.max(0.15, Number(pane.width_weight) || 1);

        return (
          <div
            key={pane.id}
            style={{ display: 'contents' }}
          >
            {idx > 0 && (
              <div
                className={`pane-resizer resizer ${activeResizerIdx === idx - 1 ? 'active' : ''}`}
                title="左右拖拽调整分栏宽度（拖窄至 <140px 松手可快速关闭分栏）"
                onPointerDown={(e) => handleResizerPointerDown(idx - 1, e)}
              >
                <span className="pane-resizer-grip" aria-hidden="true">
                  ⋮
                </span>
              </div>
            )}

            <div
              className={`workspace-pane-slot ${recentSplitIds.has(pane.id) ? 'split-enter' : ''}`.trim()}
              style={{ flex: `${weight} 1 0%` }}
            >
              <TaskPane
                pane={pane}
                paneIndex={idx}
                paneCount={panes.length}
                sessions={sessions}
                archivedSessions={archivedSessions}
                infra={infra}
                snapshot={snapshot}
                draft={drafts[draftKey] || ''}
                composerFocusSignal={idx === 0 ? composerFocusSignal : 0}
                onDraftChange={onDraftChange}
                onUpdatePane={onUpdatePane}
                onSplitAfter={onSplitAfter}
                onClosePane={onClosePane}
                onOpenSessionWeb={onOpenSessionWeb}
                onOpenDetail={onOpenDetail}
                onOpenSentHistory={onOpenSentHistory}
                onOpenArchiveDialog={onOpenArchiveDialog}
                onArchiveSession={onArchiveSession}
                onRestoreAndOpen={onRestoreAndOpen}
                onRequestDeferredPurge={onRequestDeferredPurge}
                onRefreshSnapshot={onRefreshSnapshot}
                onToast={onToast}
              />
            </div>
          </div>
        );
      })}

      {snapCloseBadge && (
        <div
          className="snap-floating-badge"
          style={{ left: `${snapCloseBadge.left}px` }}
        >
          松手关闭此分栏
        </div>
      )}
    </section>
  );
}
