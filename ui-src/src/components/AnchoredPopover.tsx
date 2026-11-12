import type { ComponentChildren } from 'preact';
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';

export interface AnchoredPopoverProps {
  open: boolean;
  onClose: () => void;
  anchorEl?: HTMLElement | null;
  anchorPoint?: { x: number; y: number } | null;
  align?: 'start' | 'end';
  width?: number;
  className?: string;
  children: ComponentChildren;
}

/**
 * 1:1 Original Viewport-Clamped Disclosure Popover (`Sync-PopoverAnchorAndAnimate` in `连接管理.ps1#L1514-L1579`).
 * - Plain disclosure `<div ref={panelRef}>` (never `role="menu"` / `role="menuitem"` per `modern-web-guidance`).
 * - Default top margin under titlebar: `top = Math.max(38, r.bottom + 4)` with `14px` horizontal clamp margin.
 * - Signature Enter + Horizontal Glide Animation:
 *   - Initial open: `opacity: 0 -> 1`, `translateY(-7px) -> 0`, `scale(0.975) -> 1` over `180ms cubic-bezier(0.165, 0.84, 0.44, 1)` (`transform-origin: 15% 0%`).
 *   - Switching anchor while open (e.g. `ChatGPT ▾` -> `Gemini ▾` -> `+`): smoothly glides `left` across the top capsule.
 */
export function AnchoredPopover({
  open,
  onClose,
  anchorEl,
  anchorPoint,
  align = 'start',
  width,
  className = '',
  children,
}: AnchoredPopoverProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const wasOpenRef = useRef<boolean>(false);
  const prevAnchorRef = useRef<HTMLElement | null | undefined>(undefined);
  const lastCoordsRef = useRef<{ top: number; left: number }>({ top: 38, left: 14 });
  const lastClosedAtRef = useRef<number>(0);

  const [coords, setCoords] = useState<{ top: number; left: number }>({ top: 38, left: 14 });
  const [isGliding, setIsGliding] = useState<boolean>(false);

  useLayoutEffect(() => {
    if (!open) {
      if (wasOpenRef.current) {
        lastClosedAtRef.current = performance.now();
      }
      wasOpenRef.current = false;
      prevAnchorRef.current = undefined;
      setIsGliding(false);
      return;
    }

    const computeTargetCoords = (): { top: number; left: number } => {
      const panel = panelRef.current;
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const panelRect = panel ? panel.getBoundingClientRect() : null;
      const pw = width || (panelRect && panelRect.width > 0 ? panelRect.width : 360);
      const ph = panelRect && panelRect.height > 0 ? panelRect.height : 240;
      const hMargin = 14;
      const vMargin = 12;

      let nextLeft = hMargin;
      let nextTop = 38;

      if (anchorPoint) {
        nextLeft = anchorPoint.x;
        nextTop = anchorPoint.y;
        if (nextLeft + pw > vw - hMargin) {
          nextLeft = Math.max(hMargin, anchorPoint.x - pw);
        }
        if (nextTop + ph > vh - vMargin) {
          nextTop = Math.max(vMargin, anchorPoint.y - ph);
        }
      } else if (anchorEl) {
        const r = anchorEl.getBoundingClientRect();
        nextLeft = align === 'end' ? r.right - pw : r.left;
        nextTop = Math.max(38, r.bottom + 4);
        if (nextTop + ph > vh - vMargin && r.top - 4 - ph >= vMargin) {
          nextTop = r.top - ph - 4;
        } else if (nextTop + ph > vh - vMargin) {
          nextTop = Math.max(vMargin, vh - ph - vMargin);
        }
      }

      nextLeft = Math.min(Math.max(hMargin, nextLeft), Math.max(hMargin, vw - pw - hMargin));
      nextTop = Math.min(Math.max(vMargin, nextTop), Math.max(vMargin, vh - ph - vMargin));

      return {
        top: Math.round(nextTop),
        left: Math.round(nextLeft),
      };
    };

    const next = computeTargetCoords();
    const reopenedImmediately =
      !wasOpenRef.current &&
      lastClosedAtRef.current > 0 &&
      performance.now() - lastClosedAtRef.current < 160;

    let rafId = 0;

    if (wasOpenRef.current) {
      if (anchorEl && prevAnchorRef.current && anchorEl !== prevAnchorRef.current) {
        const prevAnchor = prevAnchorRef.current;
        const sameParent =
          Boolean(
            prevAnchor.closest('.capsule-bar') &&
              prevAnchor.closest('.capsule-bar') === anchorEl.closest('.capsule-bar')
          ) || prevAnchor.parentElement === anchorEl.parentElement;
        setIsGliding(sameParent);
      }
      setCoords(next);
      lastCoordsRef.current = next;
    } else if (reopenedImmediately && Math.abs(lastCoordsRef.current.left - next.left) > 4) {
      // Seamless horizontal glide even if parent toggled false -> true across segment click
      setIsGliding(true);
      setCoords(lastCoordsRef.current);
      rafId = window.requestAnimationFrame(() => {
        setCoords(next);
        lastCoordsRef.current = next;
      });
    } else {
      setIsGliding(false);
      setCoords(next);
      lastCoordsRef.current = next;
    }

    wasOpenRef.current = true;
    prevAnchorRef.current = anchorEl;

    const syncOnViewportChange = () => {
      const updated = computeTargetCoords();
      setCoords(updated);
      lastCoordsRef.current = updated;
    };

    const ro =
      typeof ResizeObserver !== 'undefined' && panelRef.current
        ? new ResizeObserver(() => syncOnViewportChange())
        : null;
    if (ro && panelRef.current) {
      ro.observe(panelRef.current);
    }
    window.addEventListener('resize', syncOnViewportChange);
    window.addEventListener('scroll', syncOnViewportChange, true);

    return () => {
      if (rafId) window.cancelAnimationFrame(rafId);
      ro?.disconnect();
      window.removeEventListener('resize', syncOnViewportChange);
      window.removeEventListener('scroll', syncOnViewportChange, true);
    };
  }, [open, anchorEl, anchorPoint?.x, anchorPoint?.y, align, width]);

  useEffect(() => {
    if (!open) return;

    const onPointerDown = (ev: PointerEvent) => {
      const target = ev.target as Node | null;
      if (!target) return;
      if (panelRef.current?.contains(target)) return;
      if (anchorEl && anchorEl.contains(target)) return;

      // Preserve continuous mount & horizontal glide when clicking sibling buttons in the topbar tunnel capsule
      if (
        className.includes('tunnel-hub-popover') &&
        target instanceof Element &&
        Boolean(target.closest('button')) &&
        Boolean(
          (anchorEl?.closest('.capsule-bar') &&
            anchorEl.closest('.capsule-bar') === target.closest('.capsule-bar')) ||
            (anchorEl?.parentElement && anchorEl.parentElement.contains(target))
        )
      ) {
        return;
      }

      onClose();
    };

    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') {
        ev.stopPropagation();
        onClose();
      }
    };

    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('keydown', onKeyDown, true);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('keydown', onKeyDown, true);
    };
  }, [open, anchorEl, className, onClose]);

  if (!open) return null;

  const surfaceClasses = [
    'anchored-popover-surface',
    isGliding ? 'is-gliding' : '',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div
      ref={panelRef}
      className={surfaceClasses}
      style={{
        top: `${coords.top}px`,
        left: `${coords.left}px`,
        ...(width ? { width: `${width}px` } : {}),
      }}
    >
      {children}
    </div>
  );
}
