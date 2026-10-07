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

const CHUNK_SIZE = 50

/** Cached transcript data including chunk-loading metadata. */
interface CachedTranscript {
  entries: TranscriptEntry[]
  hasMore: boolean
  totalCount: number
}

/** LRU cache of per-session transcript data. */
class TranscriptDataCache {
  private map: Map<string, CachedTranscript> = new Map()

  get(sessionId: string): CachedTranscript | undefined {
    const data = this.map.get(sessionId)
    if (data) {
      // Move to end (most recently used).
      this.map.delete(sessionId)
      this.map.set(sessionId, data)
    }
    return data
  }

  set(sessionId: string, data: CachedTranscript): void {
    this.map.set(sessionId, data)
    if (this.map.size > MAX_CACHED_TRANSCRIPTS) {
      const oldest = this.map.keys().next().value
      if (oldest) this.map.delete(oldest)
    }
  }

  /** Update cached entries for a session (preserving metadata).
   *  Called on every WS entry event so the cache stays fresh. */
  update(sessionId: string, entries: TranscriptEntry[]): void {
    const existing = this.map.get(sessionId)
    const prevLen = existing?.entries.length ?? 0
    this.set(sessionId, {
      entries,
      hasMore: existing?.hasMore ?? false,
      totalCount: entries.length > prevLen ? (existing?.totalCount ?? entries.length) + 1 : (existing?.totalCount ?? entries.length),
    })
  }
}

let globalDataCache: TranscriptDataCache | null = null

function getGlobalDataCache(): TranscriptDataCache {
  if (globalDataCache === null) globalDataCache = new TranscriptDataCache()
  return globalDataCache
}

/** Reset the global data cache. Test-only — clears all cached transcript
 *  data so tests start with a clean state. */
export function _resetDataCacheForTests(): void {
  globalDataCache = null
}

async function fetchTranscriptSeed(sessionId: string): Promise<{ entries: TranscriptEntry[]; hasMore: boolean; totalCount: number }> {
  const done = perf.begin('transcript.seed')
  const ttfbDone = perf.begin('transcript.seed.ttfb')
  const textDone = perf.begin('transcript.seed.readBody')
  const parseDone = perf.begin('transcript.seed.jsonParse')
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/transcript?limit=${CHUNK_SIZE}`)
    await perf.recordFetch('transcript.seed', res)
    ttfbDone({ meta: { sessionId, status: res.status } })
    if (!res.ok) {
      done(); textDone(); parseDone()
      return { entries: [], hasMore: false, totalCount: 0 }
    }
    const text = await res.text()
    textDone({ meta: { sessionId, bytes: text.length } })
    const data = JSON.parse(text) as TranscriptEntry[]
    parseDone({ count: data.length, meta: { sessionId, bytes: text.length } })
    done({ count: data.length, meta: { sessionId, bytes: text.length } })
    const hasMore = res.headers.get('X-Has-More') === 'true'
    const totalCount = parseInt(res.headers.get('X-Total-Count') ?? '0', 10) || data.length
    return { entries: data, hasMore, totalCount }
  } catch {
    done(); ttfbDone(); textDone(); parseDone()
    return { entries: [], hasMore: false, totalCount: 0 }
  }
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

/** Prepend older chunk entries to the existing array, dedup by id.
 *  Older entries that already exist (e.g. delivered via live tail
 *  during the chunk request) are NOT re-added — the existing entry
 *  wins. Ascending order preserved: chunk is ascending, goes before
 *  existing. */
export function prependChunkEntries(
  existing: TranscriptEntry[],
  older: TranscriptEntry[],
): TranscriptEntry[] {
  const existingIds = new Set(existing.map(e => e.id))
  const deduped = older.filter(e => !existingIds.has(e.id))
  return [...deduped, ...existing]
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
  const [hasMore, setHasMore] = useState(false)
  const [totalCount, setTotalCount] = useState(0)
  const [loadingMore, setLoadingMore] = useState(false)
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
      setHasMore(false); setTotalCount(0); setLoadingMore(false)
      loadedSessionRef.current = null
      return
    }
    currentSessionRef.current = sessionId
    sc.focus(sessionId)
    let cancelled = false

    const dataCache = getGlobalDataCache()
    const cached = dataCache.get(sessionId)
    const isFirstLoad = loadedSessionRef.current !== sessionId

    if (cached !== undefined && cached.entries.length > 0 && isFirstLoad) {
      // Cache hit on session switch — instantly show cached data, no
      // loading spinner. Focus with `since` = last cached entry id so
      // the WS replay delivers only new entries. No background re-seed —
      // the WS `since` replay is the sole mechanism for catching entries
      // that arrived since the last visit. A background re-seed would
      // race with WS-delivered entries and cause flickering (the re-seed
      // overwrites newer WS entries with stale HTTP data).
      setEntries(cached.entries)
      setHasMore(cached.hasMore)
      setTotalCount(cached.totalCount)
      setLoading(false)
      loadedSessionRef.current = sessionId
      console.log(`[transcript] SEED cache-hit session=${sessionId} count=${cached.entries.length}`)
      const lastId = cached.entries[cached.entries.length - 1]!.id
      sc.focus(sessionId, lastId)
      fetchPendingQuestions(sessionId).then((qs) => {
        if (cancelled) return
        setPendingQuestions(qs)
      })
    } else {
      // First load (cache miss) or refresh — HTTP GET seed.
      if (isFirstLoad) {
        setLoading(true)
        setHasMore(false); setTotalCount(0); setLoadingMore(false)
      }
      fetchTranscriptSeed(sessionId).then((seed) => {
        if (cancelled) return
        if (isFirstLoad) {
          setEntries(seed.entries)
          setHasMore(seed.hasMore)
          setTotalCount(seed.totalCount)
          dataCache.set(sessionId, seed)
        } else {
          setEntries((prev) => {
            let merged = prev
            for (const e of seed.entries) merged = reconcileEntries(merged, e)
            return merged
          })
        }
        setLoading(false)
        loadedSessionRef.current = sessionId
        const lastId = seed.entries.length > 0 ? seed.entries[seed.entries.length - 1]!.id : undefined
        if (lastId !== undefined) sc.focus(sessionId, lastId)
        else sc.focus(sessionId)
      })
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

  // WS entries-chunk subscription (for chunked loading).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onEntriesChunk((chunkSid, chunk) => {
      // Only handle chunks for the currently-focused session.
      if (chunkSid !== currentSessionRef.current) return
      if (chunk.requestBefore === null || chunk.requestBefore === '__beginning__') {
        // Initial chunk (latest entries) or jump-to-beginning chunk (oldest entries).
        setEntries(chunk.entries)
        setHasMore(chunk.hasMore)
        setTotalCount(chunk.totalCount ?? chunk.entries.length)
        setLoading(false)
        setLoadingMore(false)
        loadedSessionRef.current = chunkSid
        getGlobalDataCache().set(chunkSid, {
          entries: chunk.entries,
          hasMore: chunk.hasMore,
          totalCount: chunk.totalCount ?? chunk.entries.length,
        })
        // Focus for live tail + replay.
        const lastId = chunk.entries.length > 0
          ? chunk.entries[chunk.entries.length - 1]!.id : undefined
        if (lastId !== undefined) sc.focus(chunkSid, lastId)
        else sc.focus(chunkSid)
      } else {
        // Load-older chunk (prepend).
        setEntries((prev) => prependChunkEntries(prev, chunk.entries))
        setHasMore(chunk.hasMore)
        setLoadingMore(false)
        // Update cache with merged entries.
        const sid = currentSessionRef.current
        if (sid !== null) {
          const cached = getGlobalDataCache().get(sid)
          if (cached) {
            const merged = prependChunkEntries(cached.entries, chunk.entries)
            getGlobalDataCache().set(sid, {
              entries: merged,
              hasMore: chunk.hasMore,
              totalCount: chunk.totalCount ?? cached.totalCount,
            })
          }
        }
        // Empty chunk with hasMore=true (shouldn't happen, but defensive).
        if (chunk.entries.length === 0 && chunk.hasMore) {
          setHasMore(false)
        }
      }
    })
    return unsub
  }, [sessionId, sc])

  // loadOlder: request the next chunk of older entries.
  const loadOlder = useCallback(() => {
    const sid = currentSessionRef.current
    if (sid === null || loadingMore || !hasMore) return
    const firstId = entries.length > 0 ? entries[0]!.id : null
    if (firstId === null) return
    setLoadingMore(true)
    sc.requestEntries(sid, firstId, CHUNK_SIZE)
  }, [loadingMore, hasMore, entries, sc])

  // loadFromBeginning: jump to the oldest entries (for "scroll to top" button).
  // Sends a WS requestEntries with before="__beginning__" which the backend
  // handles by returning the oldest N entries in one shot.
  const loadFromBeginning = useCallback(() => {
    const sid = currentSessionRef.current
    if (sid === null) return
    setLoading(true)
    setHasMore(false); setTotalCount(0); setLoadingMore(false)
    sc.requestEntries(sid, '__beginning__', CHUNK_SIZE)
  }, [sc])

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
      setPendingQuestions((prev) => prev.filter((q) => q.id !== ask.id))
    })
    return unsub
  }, [sessionId, sc])

  // Status + lastError subscriptions.
  useEffect(() => {
    const unsub = sc.onStatusChange((s) => {
      setStatus(s)
      setLastError(sc.lastError())
      // Reset loadingMore on disconnect (in-flight chunk request is lost).
      if (s === 'reconnecting' || s === 'closed') {
        setLoadingMore(false)
      }
      // On reconnect, re-request the initial chunk if still loading.
      if ((s === 'live' || s === 'replaying') && loading && entries.length === 0) {
        const sid = currentSessionRef.current
        if (sid !== null) sc.requestEntries(sid, null, CHUNK_SIZE)
      }
    })
    return unsub
  }, [sc, loading, entries.length])

  return {
    entries, status, lastError, pendingQuestions, loading, refresh,
    hasMore, totalCount, loadingMore, loadOlder, loadFromBeginning,
  }
}
