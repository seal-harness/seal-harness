/**
 * React hook: subscribe to a session's transcript via:
 *   1. an initial HTTP GET seed (existing /api/sessions/:id/transcript),
 *   2. a WS subscription that focuses the session and tails subsequent entries.
 *
 * The hook deduplicates by entry id and keeps the array sorted by timestamp
 * ascending. Status + lastError reflect the underlying stream client.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type { TranscriptEntry } from '../types'
import type { StreamClient, StreamStatus, UseTranscriptStream } from '../types/stream'
import { streamClient } from '../lib/streamClient'
import { fetchPendingQuestions, type PendingQuestion } from './useApi'
import * as perf from '../lib/perf'

// ── Module-level transcript data cache ──────────────────────────────────
//
// Transcripts are append-only and immutable (past entries never change
// except streaming placeholders). This cache stores the raw
// TranscriptEntry[] for each session so that switching back to a
// previously-viewed session is instantaneous — the cached data is shown
// immediately while only the delta (new entries since the last visit) is
// fetched via the WS `since` replay parameter.
//
// The cache is bounded (MAX_CACHED_TRANSCRIPTS). When full, the
// least-recently-used session's data is evicted.

const MAX_CACHED_TRANSCRIPTS = 8

/** LRU cache of per-session transcript data. */
class TranscriptDataCache {
  private map: Map<string, TranscriptEntry[]> = new Map()

  get(sessionId: string): TranscriptEntry[] | undefined {
    const data = this.map.get(sessionId)
    if (data) {
      // Move to end (most recently used).
      this.map.delete(sessionId)
      this.map.set(sessionId, data)
    }
    return data
  }

  set(sessionId: string, entries: TranscriptEntry[]): void {
    this.map.set(sessionId, entries)
    if (this.map.size > MAX_CACHED_TRANSCRIPTS) {
      const oldest = this.map.keys().next().value
      if (oldest) this.map.delete(oldest)
    }
  }

  /** Update cached data for a session — append new entries or replace
   *  existing ones. Called on every WS entry event so the cache stays
   *  fresh even when the user is viewing a different session. */
  update(sessionId: string, entries: TranscriptEntry[]): void {
    this.set(sessionId, entries)
  }
}

let globalDataCache: TranscriptDataCache | null = null

function getGlobalDataCache(): TranscriptDataCache {
  if (globalDataCache === null) globalDataCache = new TranscriptDataCache()
  return globalDataCache
}

/** Number of entries to fetch in the initial tail load. Covers the visible
 *  viewport (MIN_RENDERED=100 in useVirtualWindow) plus scroll headroom.
 *  The rest of the transcript is background-loaded after display. */
const TAIL_LIMIT = 200

/** Reset the global data cache. Test-only — clears all cached transcript
 *  data so tests start with a clean state. */
export function _resetDataCacheForTests(): void {
  globalDataCache = null
}

async function fetchTranscriptSeed(sessionId: string): Promise<TranscriptEntry[]> {
  const done = perf.begin('transcript.seed')
  const ttfbDone = perf.begin('transcript.seed.ttfb')
  const textDone = perf.begin('transcript.seed.readBody')
  const parseDone = perf.begin('transcript.seed.jsonParse')
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/transcript`)
    await perf.recordFetch('transcript.seed', res)
    ttfbDone({ meta: { sessionId, status: res.status } })
    if (!res.ok) {
      done(); textDone(); parseDone()
      return []
    }
    const text = await res.text()
    textDone({ meta: { sessionId, bytes: text.length } })
    const data = JSON.parse(text) as TranscriptEntry[]
    parseDone({ count: data.length, meta: { sessionId, bytes: text.length } })
    done({ count: data.length, meta: { sessionId, bytes: text.length } })
    return data
  } catch {
    done(); ttfbDone(); textDone(); parseDone()
    return []
  }
}

/** Fetch only the last N transcript entries via @?tail=N@. Returns the
 *  entries and the total entry count (from the X-Transcript-Total header).
 *  Used for the initial display on cache-miss session loads — the tail is
 *  small enough to display instantly, then the full transcript is
 *  background-loaded by the caller. */
async function fetchTranscriptTail(
  sessionId: string,
  limit: number,
): Promise<{ entries: TranscriptEntry[]; totalCount: number }> {
  const done = perf.begin('transcript.tail')
  try {
    const res = await fetch(
      `/api/sessions/${encodeURIComponent(sessionId)}/transcript?tail=${limit}`,
    )
    await perf.recordFetch('transcript.tail', res)
    if (!res.ok) { done(); return { entries: [], totalCount: 0 } }
    const totalCount = parseInt(
      res.headers.get('X-Transcript-Total') ?? '0', 10,
    )
    const text = await res.text()
    const entries = JSON.parse(text) as TranscriptEntry[]
    done({ count: entries.length, meta: { sessionId, total: totalCount } })
    return { entries, totalCount }
  } catch {
    done()
    return { entries: [], totalCount: 0 }
  }
}

/** Merge a full transcript fetch with the current entries array. The full
 *  transcript is the base (all on-disk entries in order); any entries in
 *  `prev` that are NOT in `full` (WS-delivered additions, streaming
 *  placeholders not yet on disk) are appended at the end. Entries present
 *  in both use the `full` version (canonical, read from disk after the
 *  tail was shown). */
function mergeFullWithPrev(
  full: TranscriptEntry[],
  prev: TranscriptEntry[],
): TranscriptEntry[] {
  const fullIds = new Set(full.map((e) => e.id))
  const wsAdditions = prev.filter((e) => !fullIds.has(e.id))
  return [...full, ...wsAdditions]
}

/**
 * Pure reconciler: insert `incoming` into `existing`, dedup by id.
 * Append-only — new entries (by id) are always appended at the end; existing
 * entries (id match, e.g. streaming updates) are replaced in place. This
 * guarantees that nothing already rendered shifts position when a new entry
 * arrives — the transcript view is a pure append-only function of the
 * transcript.
 *
 * When `incoming` is a finalized entry (no `streaming` flag), any prior
 * `streaming: true` placeholder is evicted first — the streaming placeholder
 * (id `"streaming"`) uses a sentinel id that won't match the final entry's
 * positional id, so without eviction the streaming placeholder would linger
 * as a duplicate row alongside the real entry.
 *
 * The initial HTTP seed provides entries in their final on-disk order; WS
 * events arrive in append order. Append-only is correct because the backend
 * writes entries sequentially and the seed is already sorted.
 */
export function reconcileEntries(
  existing: TranscriptEntry[],
  incoming: TranscriptEntry,
): TranscriptEntry[] {
  const done = perf.begin('reconcileEntries')
  // When a finalized (non-streaming) entry arrives, replace any existing
  // streaming placeholder IN PLACE regardless of id. The streaming
  // placeholder always has the sentinel id "streaming" (assigned by the
  // backend's streamingEntryJson), while the finalized entry has the real
  // transcript entry id. Replacing in place — rather than evicting the
  // placeholder and appending the finalized entry — keeps the array
  // position stable, which prevents React key changes and the associated
  // unmount/mount flicker at the bottom of the transcript.
  let base = existing
  if (!incoming.streaming) {
    const streamingIdx = existing.findIndex((e) => e.streaming)
    if (streamingIdx !== -1) {
      // Replace the streaming placeholder in place with the finalized
      // entry, regardless of id. This keeps the array position stable
      // and prevents the flicker of evict-then-append.
      const next = existing.slice()
      next[streamingIdx] = incoming
      done({ count: existing.length, meta: { mode: 'replace-streaming' } })
      return next
    }
  }
  for (let i = 0; i < base.length; i++) {
    if (base[i]!.id === incoming.id) {
      // Replace in place (same id, non-streaming entry updated).
      const next = base.slice()
      next[i] = incoming
      done({ count: existing.length, meta: { mode: 'replace' } })
      return next
    }
  }
  // Append-only: new entries always go at the end.
  const next = base.slice()
  next.push(incoming)
  done({ count: existing.length, meta: { mode: 'insert' } })
  return next
}

export function useTranscriptStream(
  sessionId: string | null,
  client?: StreamClient,
): UseTranscriptStream {
  const sc = client ?? streamClient()
  const [entries, setEntries] = useState<TranscriptEntry[]>([])
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())
  const [pendingQuestions, setPendingQuestions] = useState<PendingQuestion[]>([])
  const [loading, setLoading] = useState(false)
  const [refreshCount, setRefreshCount] = useState(0)
  const loadedSessionRef = useRef<string | null>(null)
  const currentSessionRef = useRef<string | null>(null)

  const refresh = useCallback(() => setRefreshCount((c) => c + 1), [])

  // Session load effect: seed the transcript via HTTP GET, or serve from
  // the transcript data cache on session switch for instant display.
  // Uses the WS `since` parameter to replay only entries that arrived
  // since the last visit. On refresh-after-send, always re-fetches (the
  // refresh is a consistency check, not a session switch).
  useEffect(() => {
    if (sessionId === null) {
      // Do NOT clear entries when sessionId becomes null. During session
      // switches, currentSessionId can briefly be null (React batching
      // edge cases, tab-list mutations), and clearing entries causes the
      // transcript to flicker — messages disappear and reappear. The
      // entries will be replaced when the new session's data loads (cache
      // hit or HTTP fetch). When sessionId is truly null (New Tab, dismiss
      // tab), the ChatArea is typically not visible (composer or harness
      // controls are shown), so stale entries are harmless.
      setPendingQuestions([])
      setLoading(false)
      loadedSessionRef.current = null
      return
    }
    currentSessionRef.current = sessionId
    sc.focus(sessionId)
    let cancelled = false

    const dataCache = getGlobalDataCache()
    const cached = dataCache.get(sessionId)
    const isFirstLoad = loadedSessionRef.current !== sessionId

    if (cached !== undefined && cached.length > 0 && isFirstLoad) {
      // Cache hit on session switch — instantly show cached data, no
      // loading spinner. Focus with `since` = last cached entry id so
      // the WS replay delivers only new entries. No background re-seed —
      // the WS `since` replay is the sole mechanism for catching entries
      // that arrived since the last visit. A background re-seed would
      // race with WS-delivered entries and cause flickering (the re-seed
      // overwrites newer WS entries with stale HTTP data).
      setEntries(cached)
      setLoading(false)
      loadedSessionRef.current = sessionId
      console.log(`[transcript] SEED cache-hit session=${sessionId} count=${cached.length}`)
      const lastId = cached[cached.length - 1]!.id
      sc.focus(sessionId, lastId)
      fetchPendingQuestions(sessionId).then((qs) => {
        if (cancelled) return
        setPendingQuestions(qs)
      })
    } else {
      // Cache miss — either a first load or a refresh.
      //
      // First load (lazy transcript loading):
      //   Phase 1: fetch only the last TAIL_LIMIT entries (?tail=N) for
      //   instant display. The tail covers the visible viewport plus
      //   scroll headroom (useVirtualWindow renders ~100-200 messages).
      //   Phase 2: if the full transcript is larger than the tail,
      //   background-fetch the complete transcript and merge it in.
      //   The user sees content immediately; older history loads
      //   silently without blocking the UI.
      //
      // Refresh (after send): fetch the FULL transcript (not the tail)
      // and merge with current entries via reconcileEntries — this
      // preserves WS-delivered entries that arrived between the HTTP
      // request and response.
      if (isFirstLoad) setLoading(true)
      if (isFirstLoad) {
        // Phase 1: tail fetch for instant display.
        fetchTranscriptTail(sessionId, TAIL_LIMIT).then(({ entries: tail, totalCount }) => {
          if (cancelled) return
          setEntries(tail)
          setLoading(false)
          loadedSessionRef.current = sessionId
          dataCache.set(sessionId, tail)
          const lastId = tail.length > 0 ? tail[tail.length - 1]!.id : undefined
          if (lastId !== undefined) sc.focus(sessionId, lastId)
          else sc.focus(sessionId)
          console.log(`[transcript] SEED tail-fetch session=${sessionId} count=${tail.length} total=${totalCount}`)
          // Phase 2: background-load the full transcript if there are
          // older entries not included in the tail. The merge uses the
          // full transcript as the base and appends any WS-delivered
          // entries that arrived after the full fetch was initiated.
          if (totalCount > tail.length) {
            fetchTranscriptSeed(sessionId).then((full) => {
              if (cancelled) return
              setEntries((prev) => {
                const merged = mergeFullWithPrev(full, prev)
                // Update the cache so a future switch back to this
                // session is instant with the full transcript.
                dataCache.set(sessionId, merged)
                return merged
              })
              console.log(`[transcript] SEED bg-full session=${sessionId} fullCount=${full.length}`)
            })
          }
        })
      } else {
        // Refresh: fetch full seed and merge with current entries to
        // preserve WS-delivered entries. reconcileEntries handles dedup
        // by id — seed entries with matching ids replace in place, new
        // seed entries are appended, and WS-delivered entries that
        // aren't in the seed are retained.
        fetchTranscriptSeed(sessionId).then((seed) => {
          if (cancelled) return
          setEntries((prev) => {
            let merged = prev
            for (const e of seed) {
              merged = reconcileEntries(merged, e)
            }
            return merged
          })
          setLoading(false)
          loadedSessionRef.current = sessionId
          const cachedNow = dataCache.get(sessionId)
          const lastId = cachedNow && cachedNow.length > 0
            ? cachedNow[cachedNow.length - 1]!.id
            : seed.length > 0 ? seed[seed.length - 1]!.id : undefined
          if (lastId !== undefined) sc.focus(sessionId, lastId)
          else sc.focus(sessionId)
          console.log(`[transcript] SEED http-merge session=${sessionId} count=${seed.length} prevEntries=${dataCache.get(sessionId)?.length ?? 0}`)
        })
      }
      fetchPendingQuestions(sessionId).then((qs) => {
        if (cancelled) return
        setPendingQuestions(qs)
      })
    }
    return () => { cancelled = true }
  }, [sessionId, sc, refreshCount])

  // WS entry subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onEntry((e) => {
      setEntries((prev) => {
        const next = reconcileEntries(prev, e)
        // Update the data cache so it stays fresh for this session.
        const sid = currentSessionRef.current
        if (sid !== null) getGlobalDataCache().update(sid, next)
        return next
      })
    })
    return unsub
  }, [sessionId, sc])

  // WS ask subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onAsk((_sid, ask) => {
      setPendingQuestions((prev) => {
        if (prev.some((q) => q.id === ask.id)) return prev
        return [...prev, {
          id: ask.id,
          question: ask.question,
          createdAt: new Date().toISOString(),
          options: ask.options,
          meta: ask.meta,
        }]
      })
    })
    return unsub
  }, [sessionId, sc])

  // WS ask_resolved subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onAskResolved((_sid, ask) => {
      setPendingQuestions((prev) => prev.filter((q) => q.id === ask.id))
    })
    return unsub
  }, [sessionId, sc])

  // Status + lastError subscriptions.
  useEffect(() => {
    const unsub = sc.onStatusChange((s) => {
      setStatus(s)
      setLastError(sc.lastError())
    })
    return unsub
  }, [sc])

  return { entries, status, lastError, pendingQuestions, loading, refresh }
}