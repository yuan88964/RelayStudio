import type {
  ModelCatalogItem,
  PlatformId,
  SafeConnectionProfile,
  StudioSessionCard,
} from '../types/contracts';

export function normalizePlatformId(raw: string | undefined): PlatformId {
  const s = (raw || 'chatgpt').trim().toLowerCase();
  if (s === 'gemini' || s === 'gemini_api') return 'gemini';
  if (s === 'claude' || s === 'claude_api') return 'claude';
  return 'chatgpt';
}

export function formatProviderBadge(provider: string | undefined): string {
  const p = normalizePlatformId(provider);
  if (p === 'gemini') return 'Gemini';
  if (p === 'claude') return 'Claude';
  return 'ChatGPT';
}

function stripCarrierArtifacts(raw: string): string {
  return String(raw || '')
    .replace(/^(?:💻|🌐|\uFFFD|\?)+[\s·]*/u, '')
    .replace(/\s*\(桌面客户端\)\s*$/u, '')
    .trim();
}

export function formatShortCarrier(carrier: string | undefined): string {
  const raw = (carrier || '').trim();
  if (!raw) return '默认宿主';
  if (/^desktop:chatgpt$/i.test(raw)) return 'ChatGPT 桌面端';
  if (/^chrome:default$/i.test(raw)) return 'Chrome 默认';
  if (/^edge:default$/i.test(raw)) return 'Edge 默认';
  const cleaned = stripCarrierArtifacts(raw);
  if (/^desktop:chatgpt$/i.test(cleaned) || cleaned === 'ChatGPT 桌面端') {
    return 'ChatGPT 桌面端';
  }
  const idx = cleaned.indexOf(':');
  if (idx > 0) {
    const browser = cleaned.slice(0, idx);
    const prof = cleaned.slice(idx + 1);
    return `${browser} · ${prof}`;
  }
  return cleaned || '默认宿主';
}

export function formatRailCarrierTag(carrier: string | undefined): string {
  const raw = (carrier || '').trim();
  if (!raw) return '默认宿主';
  if (/^desktop:chatgpt$/i.test(raw)) return 'ChatGPT 桌面端';
  if (/^chrome:default$/i.test(raw)) return 'Chrome 默认';
  if (/^edge:default$/i.test(raw)) return 'Edge 默认';
  const cleaned = stripCarrierArtifacts(raw);
  if (/^desktop:chatgpt$/i.test(cleaned) || cleaned === 'ChatGPT 桌面端') {
    return 'ChatGPT 桌面端';
  }
  const idx = cleaned.indexOf(':');
  if (idx > 0) {
    return cleaned.slice(idx + 1) || cleaned;
  }
  return cleaned || '默认宿主';
}

export const formatBracketCarrier = formatRailCarrierTag;

export function formatShortModelTag(card: StudioSessionCard): string {
  const m = (
    card.TargetModel && card.TargetModel !== 'inherit'
      ? card.TargetModel
      : card.WebCurrentModel || ''
  ).trim();
  if (!m || m === 'inherit') return '跟随网页';
  if (/thinking/i.test(m)) return 'Thinking';
  if (/instant/i.test(m)) return 'Instant';
  if (/pro/i.test(m)) return 'Pro';
  if (/sonnet/i.test(m)) return 'Sonnet';
  if (/opus/i.test(m)) return 'Opus';
  if (/flash/i.test(m)) return 'Flash';
  return m.length > 14 ? m.slice(0, 14) : m;
}

/**
 * Formats Row 3 of the original left-rail session card (`连接管理.ps1#L7950-L7973`):
 * e.g. `[跟随原窗 | Thinking | yuan88964]` or `[新窗交接 | Thinking | 主力开发窗]`
 */
export function formatRailTaskConfigBracket(
  card: StudioSessionCard,
  profiles?: SafeConnectionProfile[]
): string {
  const modeLabel = card.TargetMode === 'new_window' ? '新窗交接' : '跟随原窗';
  const modelLabel = formatShortModelTag(card);

  const prov = normalizePlatformId(card.Provider);
  const rawCarrier = (card.BrowserProfile || card.Carrier || '').trim();
  const activeProf = (profiles || []).find(
    (p) => normalizePlatformId(String(p.Platform || 'chatgpt')) === prov && p.IsActive
  );
  const carrierOrProf = rawCarrier
    ? formatRailCarrierTag(rawCarrier)
    : activeProf?.Name || '默认宿主';

  return `[${modeLabel} | ${modelLabel} | ${carrierOrProf}]`;
}

export interface NormalizedMilestone {
  key: string;
  title: string;
  prose: string;
  rawText: string;
  timeText: string;
  traceText: string;
  isSuccess: boolean;
  stepId: string;
}

/**
 * Normalizes newest-first `ReadableCheckpoints` / `Milestones` from `:8766`
 * into chronological order (oldest -> newest) matching `连接管理.ps1#L5384-L5385`.
 */
export function buildChronologicalMilestones(card: StudioSessionCard): NormalizedMilestone[] {
  const source =
    Array.isArray(card.ReadableCheckpoints) && card.ReadableCheckpoints.length > 0
      ? card.ReadableCheckpoints
      : Array.isArray(card.Milestones) && card.Milestones.length > 0
        ? card.Milestones
        : Array.isArray(card.Checkpoints) && card.Checkpoints.length > 0
          ? card.Checkpoints
          : [];

  if (source.length === 0) return [];

  // McpReadOnlyShield.py builds Milestones & ReadableCheckpoints newest-first (`reversed(raw_cps[-12:])`).
  const chronologicalRaw = [...source].reverse();

  return chronologicalRaw.map((item: any, idx: number) => {
    const title = String(
      item?.Title || item?.title || item?.Summary || item?.summary || `阶段记录 #${idx + 1}`
    ).trim();
    const prose = String(
      item?.Prose ?? item?.Body ?? item?.Detail ?? item?.Summary ?? item?.summary ?? ''
    ).trim();
    const rawText = String(item?.RawText ?? item?.RawSummary ?? item?.raw_text ?? '').trim();
    const timeText = String(item?.TimeText ?? item?.Time ?? item?.time ?? '').trim();
    const traceText = String(item?.TraceText ?? item?.trace_text ?? '').trim();
    const isWarning = Boolean(item?.IsWarning || item?.is_warning);
    const isSuccess = item?.IsSuccess !== undefined ? Boolean(item.IsSuccess) && !isWarning : !isWarning;
    const stepId = String(item?.StepId ?? item?.step_id ?? '').trim();

    return {
      key: `${idx}_${timeText}_${title.slice(0, 20)}`,
      title,
      prose,
      rawText,
      timeText,
      traceText,
      isSuccess,
      stepId,
    };
  });
}

export type ModelOptionItem = ModelCatalogItem;

export function normalizeModelCatalogList(
  raw: unknown,
  _provider?: PlatformId
): ModelOptionItem[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    return [];
  }

  const items: ModelOptionItem[] = [];
  const seen = new Set<string>(['inherit', '']);

  for (const entry of raw) {
    if (typeof entry === 'string') {
      const id = entry.trim();
      const lower = id.toLowerCase();
      if (!id || lower === 'inherit' || seen.has(lower)) continue;
      seen.add(lower);
      items.push({ id, label: formatFriendlyModelName(id) });
    } else if (entry && typeof entry === 'object') {
      const rec = entry as Record<string, any>;
      const id = String(rec.id || rec.slug || rec.model || rec.value || '').trim();
      const lower = id.toLowerCase();
      if (!id || lower === 'inherit' || seen.has(lower)) continue;
      const label = String(rec.label || rec.title || rec.name || id).trim();
      seen.add(lower);
      items.push({
        id,
        slug: typeof rec.slug === 'string' ? rec.slug : undefined,
        title: typeof rec.title === 'string' ? rec.title : undefined,
        label: label || id,
        group: typeof rec.group === 'string' ? rec.group : undefined,
        efforts: Array.isArray(rec.efforts)
          ? rec.efforts.map((x: unknown) => String(x))
          : undefined,
        url_slug:
          typeof rec.url_slug === 'string'
            ? rec.url_slug
            : typeof rec.slug === 'string'
              ? rec.slug
              : undefined,
      });
    }
  }

  return items;
}

export function formatFriendlyModelName(modelId: string | undefined): string {
  const raw = (modelId || '').trim();
  if (!raw || raw === 'inherit' || raw === 'auto') return '默认 (跟随网页)';
  return raw;
}
