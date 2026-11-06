/** How transcript message bodies are displayed.
 *
 *    - `raw`      — the markdown source exactly as the model emitted it
 *                   (the historical behaviour; good for copying or spotting
 *                   the exact characters the model wrote)
 *    - `rendered` — the markdown parsed and rendered as HTML (tables, lists,
 *                   code blocks, headings) for reading
 *
 *  The choice is a per-browser preference persisted to localStorage so it
 *  survives reloads, and defaults to `raw` so the transcript never changes
 *  shape under a user who has not asked for it. */

export type TranscriptViewMode = 'raw' | 'rendered'

export const DEFAULT_TRANSCRIPT_VIEW_MODE: TranscriptViewMode = 'raw'

export const TRANSCRIPT_VIEW_MODE_STORAGE_KEY = 'seal.transcriptViewMode'

const VALID_MODES: readonly TranscriptViewMode[] = ['raw', 'rendered']

/** Coerce an arbitrary stored/unknown value to a valid mode. */
export function parseTranscriptViewMode(value: unknown): TranscriptViewMode {
  return typeof value === 'string' && (VALID_MODES as readonly string[]).includes(value)
    ? (value as TranscriptViewMode)
    : DEFAULT_TRANSCRIPT_VIEW_MODE
}

/** Load the persisted mode. Never throws: localStorage can be unavailable
 *  (SSR, privacy mode, disabled storage) or hold a stale value. */
export function loadTranscriptViewMode(): TranscriptViewMode {
  if (typeof localStorage === 'undefined') return DEFAULT_TRANSCRIPT_VIEW_MODE
  try {
    return parseTranscriptViewMode(localStorage.getItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY))
  } catch {
    return DEFAULT_TRANSCRIPT_VIEW_MODE
  }
}

/** Persist the mode. No-op when localStorage is unavailable. Never throws —
 *  a view preference is not worth breaking the page for. */
export function saveTranscriptViewMode(mode: TranscriptViewMode): void {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(TRANSCRIPT_VIEW_MODE_STORAGE_KEY, mode)
  } catch {
    // Ignore — see above.
  }
}
