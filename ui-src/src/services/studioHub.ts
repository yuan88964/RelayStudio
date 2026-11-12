import type {
  SessionQueueSlice,
  StudioQueueDigest,
  StudioSessionCard,
  StudioSnapshot,
} from '../types/contracts';

function normalizeBaseUrl(baseUrl: string): string {
  const trimmed = (baseUrl || 'http://127.0.0.1:8766').trim().replace(/\/+$/, '');
  return trimmed || 'http://127.0.0.1:8766';
}

function buildAuthHeaders(token: string, jsonBody = false): Record<string, string> {
  const headers: Record<string, string> = {};
  if (jsonBody) {
    headers['Content-Type'] = 'application/json';
  }
  if (token && token.trim()) {
    headers['X-Studio-Token'] = token.trim();
  }
  return headers;
}

export async function fetchSnapshot(
  baseUrl: string,
  token: string,
  sinceSig?: string,
  signal?: AbortSignal
): Promise<StudioSnapshot> {
  const root = normalizeBaseUrl(baseUrl);
  const url = new URL(`${root}/studio/snapshot`);
  if (sinceSig && sinceSig.trim()) {
    url.searchParams.set('since_sig', sinceSig.trim());
  }
  const resp = await fetch(url.toString(), {
    method: 'GET',
    headers: buildAuthHeaders(token, false),
    cache: 'no-store',
    signal,
  });
  if (!resp.ok) {
    throw new Error(`Snapshot HTTP ${resp.status}`);
  }
  return (await resp.json()) as StudioSnapshot;
}

export async function postStudioAction<T = any>(
  baseUrl: string,
  token: string,
  payload: Record<string, unknown>
): Promise<T> {
  const root = normalizeBaseUrl(baseUrl);
  const resp = await fetch(`${root}/studio/action`, {
    method: 'POST',
    headers: buildAuthHeaders(token, true),
    body: JSON.stringify(payload),
  });
  const data = await resp.json().catch(() => ({ ok: false, error: `HTTP ${resp.status}` }));
  if (!resp.ok || data?.ok === false) {
    throw new Error(data?.error || `操作失败 (HTTP ${resp.status})`);
  }
  return data as T;
}

export function applyQueueSliceToSession(
  session: StudioSessionCard,
  slice: SessionQueueSlice
): StudioSessionCard {
  const pending = Array.isArray(slice.PendingQueue) ? slice.PendingQueue : session.PendingQueue;
  const sent = Array.isArray(slice.SentWebMessages) ? slice.SentWebMessages : session.SentWebMessages;
  return {
    ...session,
    PendingQueue: pending,
    PendingQueueCount: pending.length,
    SentWebMessages: sent,
  };
}

export function mergeQueueDigestIntoSnapshot(
  prev: StudioSnapshot | null,
  digest: StudioQueueDigest
): StudioSnapshot | null {
  if (!prev || digest.not_modified || !digest.queues) return prev;
  const qMap = digest.queues;
  let changed = prev.queue_rev !== digest.queue_rev;

  const updateList = (list: StudioSessionCard[]): StudioSessionCard[] => {
    if (!Array.isArray(list) || list.length === 0) return list;
    let listMutated = false;
    const next = list.map((card) => {
      const slice = qMap[card.SessionKey];
      if (!slice) return card;
      listMutated = true;
      return applyQueueSliceToSession(card, slice);
    });
    if (listMutated) changed = true;
    return listMutated ? next : list;
  };

  const nextSessions = updateList(prev.sessions);
  const nextArchived = updateList(prev.archived_sessions);
  if (!changed) return prev;

  return {
    ...prev,
    queue_rev: digest.queue_rev || prev.queue_rev,
    sessions: nextSessions,
    archived_sessions: nextArchived,
  };
}

export interface StudioStreamCallbacks {
  onSnapshot: (snap: StudioSnapshot) => void;
  onQueueDigest: (digest: StudioQueueDigest) => void;
  onConnectionChange?: (state: 'sse' | 'polling' | 'offline') => void;
}

/**
 * Real-time SSE client over `${baseUrl}/studio/events` with:
 * - 16ms `requestAnimationFrame` coalescing for burst immunity
 * - Automatic 3s `fetchSnapshot` fallback backoff loop when SSE errors or `:8766` restarts
 * - Complete zero-activity pause when `visible === false` (minimized to tray)
 */
export class StudioEventStream {
  private baseUrl: string;
  private token: string;
  private callbacks: StudioStreamCallbacks;
  private visible = true;
  private disposed = false;

  private es: EventSource | null = null;
  private fallbackTimer: number | null = null;
  private sseRetryTimer: number | null = null;
  private rafId: number | null = null;

  private pendingSnapshot: StudioSnapshot | null = null;
  private pendingDigest: StudioQueueDigest | null = null;
  private lastRev = '';

  constructor(baseUrl: string, token: string, callbacks: StudioStreamCallbacks) {
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.token = token || '';
    this.callbacks = callbacks;
  }

  public start(): void {
    if (this.disposed) return;
    if (this.visible) {
      this.connectSse();
    }
  }

  public updateEndpoint(baseUrl: string, token: string): void {
    const norm = normalizeBaseUrl(baseUrl);
    const tok = token || '';
    if (norm === this.baseUrl && tok === this.token) return;
    this.baseUrl = norm;
    this.token = tok;
    this.lastRev = '';
    this.teardownActiveTransport();
    if (this.visible && !this.disposed) {
      this.connectSse();
    }
  }

  public setLastRev(rev: string): void {
    if (rev) this.lastRev = rev;
  }

  public setVisible(visible: boolean): void {
    if (this.visible === visible) return;
    this.visible = visible;
    if (!visible) {
      this.teardownActiveTransport();
      return;
    }
    if (!this.disposed) {
      void this.pollOnce();
      this.connectSse();
    }
  }

  public dispose(): void {
    this.disposed = true;
    this.teardownActiveTransport();
  }

  private teardownActiveTransport(): void {
    if (this.es) {
      try {
        this.es.close();
      } catch {
        // Ignore
      }
      this.es = null;
    }
    this.stopFallbackPolling();
    if (this.sseRetryTimer !== null) {
      window.clearTimeout(this.sseRetryTimer);
      this.sseRetryTimer = null;
    }
    if (this.rafId !== null) {
      window.cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.pendingSnapshot = null;
    this.pendingDigest = null;
  }

  private scheduleFlush(): void {
    if (!this.visible || this.disposed || this.rafId !== null) return;
    this.rafId = window.requestAnimationFrame(() => {
      this.rafId = null;
      if (!this.visible || this.disposed) return;
      const snap = this.pendingSnapshot;
      const digest = this.pendingDigest;
      this.pendingSnapshot = null;
      this.pendingDigest = null;

      if (snap && !snap.not_modified && Array.isArray(snap.sessions)) {
        if (snap.rev) this.lastRev = snap.rev;
        this.callbacks.onSnapshot(snap);
      }
      if (digest && !digest.not_modified && digest.queues) {
        this.callbacks.onQueueDigest(digest);
      }
    });
  }

  private connectSse(): void {
    if (!this.visible || this.disposed || typeof EventSource === 'undefined') {
      if (this.visible && !this.disposed) this.startFallbackPolling();
      return;
    }

    if (this.es) {
      try {
        this.es.close();
      } catch {
        // Ignore
      }
      this.es = null;
    }

    const url = new URL(`${this.baseUrl}/studio/events`);
    if (this.token.trim()) {
      url.searchParams.set('studio_token', this.token.trim());
    }

    let source: EventSource;
    try {
      source = new EventSource(url.toString());
    } catch {
      this.startFallbackPolling();
      return;
    }
    this.es = source;

    source.onopen = () => {
      if (this.es !== source) return;
      this.stopFallbackPolling();
      this.callbacks.onConnectionChange?.('sse');
    };

    source.addEventListener('snapshot', (ev: MessageEvent) => {
      if (!this.visible || this.disposed) return;
      try {
        const parsed = JSON.parse(ev.data) as StudioSnapshot;
        if (parsed && parsed.ok !== false) {
          this.stopFallbackPolling();
          this.callbacks.onConnectionChange?.('sse');
          this.pendingSnapshot = parsed;
          this.scheduleFlush();
        }
      } catch {
        // Ignore malformed frame
      }
    });

    source.addEventListener('queue_digest', (ev: MessageEvent) => {
      if (!this.visible || this.disposed) return;
      try {
        const parsed = JSON.parse(ev.data) as StudioQueueDigest;
        if (parsed && parsed.ok !== false) {
          this.stopFallbackPolling();
          this.pendingDigest = parsed;
          this.scheduleFlush();
        }
      } catch {
        // Ignore malformed frame
      }
    });

    source.onmessage = (ev: MessageEvent) => {
      if (!this.visible || this.disposed || !ev.data) return;
      try {
        const parsed = JSON.parse(ev.data);
        if (parsed && Array.isArray(parsed.sessions)) {
          this.pendingSnapshot = parsed as StudioSnapshot;
          this.scheduleFlush();
        } else if (parsed && parsed.queues) {
          this.pendingDigest = parsed as StudioQueueDigest;
          this.scheduleFlush();
        }
      } catch {
        // Heartbeat or comment payload
      }
    };

    source.onerror = () => {
      if (this.es !== source) return;
      // If EventSource closed permanently (e.g., HTTP 404/502 on older :8766 before restart),
      // close cleanly, run 3s fallback polling, and retry SSE periodically every 9s.
      if (source.readyState === EventSource.CLOSED) {
        try {
          source.close();
        } catch {
          // Ignore
        }
        this.es = null;
        this.scheduleSseReconnect(9_000);
      }
      if (this.visible && !this.disposed) {
        this.startFallbackPolling();
      }
    };
  }

  private scheduleSseReconnect(delayMs: number): void {
    if (this.sseRetryTimer !== null || !this.visible || this.disposed) return;
    this.sseRetryTimer = window.setTimeout(() => {
      this.sseRetryTimer = null;
      if (this.visible && !this.disposed && !this.es) {
        this.connectSse();
      }
    }, delayMs);
  }

  private startFallbackPolling(): void {
    if (this.fallbackTimer !== null || !this.visible || this.disposed) return;
    this.callbacks.onConnectionChange?.('polling');
    void this.pollOnce();
    this.fallbackTimer = window.setInterval(() => {
      if (!this.visible || this.disposed) {
        this.stopFallbackPolling();
        return;
      }
      void this.pollOnce();
    }, 3_000);
  }

  private stopFallbackPolling(): void {
    if (this.fallbackTimer !== null) {
      window.clearInterval(this.fallbackTimer);
      this.fallbackTimer = null;
    }
  }

  public async pollOnce(): Promise<void> {
    if (!this.visible || this.disposed) return;
    try {
      const snap = await fetchSnapshot(this.baseUrl, this.token, this.lastRev);
      if (!this.visible || this.disposed) return;
      if (snap && !snap.not_modified && Array.isArray(snap.sessions)) {
        this.pendingSnapshot = snap;
        this.scheduleFlush();
      }
      if (this.fallbackTimer !== null) {
        this.callbacks.onConnectionChange?.('polling');
      }
    } catch {
      if (this.visible && !this.disposed) {
        this.callbacks.onConnectionChange?.('offline');
      }
    }
  }
}
