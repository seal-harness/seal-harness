/**
 * React hook: subscribe to a session's transcript via:
 *   1. an initial HTTP GET seed (existing /api/sessions/:id/transcript),
 *   2. a WS subscription that focuses the session and tails subsequent entries.
 *
 * All entry + window state lives in the pure reducer in
 * `lib/transcriptState.ts`. This hook only translates backend events into
 * reducer events and owns the per-session cache. `hasMore` and
 * `isViewingLatest` are DERIVED from the window extent, so a stale server
 * flag can never strand the scroll-to-top path.
 */

import { useCallback, useEffect, useReducer, useRef, useState } from 'react'
import type { TranscriptEntry } from '../types'
import type { LoadResult, StreamClient, StreamStatus, UseTranscriptStream } from '../types/stream'
import { streamClient } from '../lib/streamClient'
import { fetchPendingQuestions, type PendingQuestion } from './useApi'
import { rateLimitedLog, detectLoop, logMemoryNow } from '../lib/diag'
import * as perf from '../lib/perf'
import {
  INITIAL_TRANSCRIPT_STATE,
  hasOlder as extentHasOlder,
  isViewingLatest as extentIsViewingLatest,
  prependChunkEntries,
  reconcileEntries,
  reduceTranscript,
  type TranscriptEvent,
  type TranscriptState,
} from '../lib/transcriptState'

// Re-exported for existing callers/tests; the implementations now live in
// the pure reducer module.
export { prependChunkEntries, reconcileEntries }

export type { LoadResult }

// ── Module-level transcript data cache ──────────────────────────────────
//
// Transcripts are append-only and immutable (past entries never change
// except streaming placeholders). This cache stores the reducer state for
// each session so switching back to a previously-viewed session is
// instantaneous — the cached data is shown immediately while only the delta
// (new entries since the last visit) is fetched via the WS `since` replay.
//
// The cache is bounded (MAX_CACHED_TRANSCRIPTS). When full, the
// least-recently-used session's data is evicted.

const MAX_CACHED_TRANSCRIPTS = 8

const CHUNK_SIZE = 50

/** Cached transcript data including the window extent computed at arrival. */
interface CachedTranscript {
  state: TranscriptState
  totalCount: number
}

/** LRU cache of per-session transcript data. */
class TranscriptDataCache {
  private map: Map<string, CachedTranscript> = new Map()
  /** Pinned first/last chunks, never evicted by LRU. Keyed by session id.
    * The first chunk (from loadFromBeginning) and last chunk (from
    * loadLatest/initial seed) are small and frequently accessed, so they
    * are stored separately from the LRU cache to guarantee instant
    * scroll-to-top and scroll-to-bottom. */
  private pinnedFirst: Map<string, CachedTranscript> = new Map()
  private pinnedLast: Map<string, CachedTranscript> = new Map()

  get(sessionId: string): CachedTranscript | undefined {
    const data = this.map.get(sessionId)
    if (data) {
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

  /** Pin the first chunk (oldest entries) for a session. Called when a
   *  __beginning__ chunk arrives. Never evicted by LRU. */
  pinFirst(sessionId: string, data: CachedTranscript): void {
    this.pinnedFirst.set(sessionId, data)
  }

  /** Pin the last chunk (newest entries) for a session. Called when a
   *  latest chunk or initial HTTP seed arrives. Never evicted. */
  pinLast(sessionId: string, data: CachedTranscript): void {
    this.pinnedLast.set(sessionId, data)
  }

  getPinnedFirst(sessionId: string): CachedTranscript | undefined {
    return this.pinnedFirst.get(sessionId)
  }

  getPinnedLast(sessionId: string): CachedTranscript | undefined {
    return this.pinnedLast.get(sessionId)
  }

  /** Update the cached state for a session. Called on every live entry so
   *  the cache stays fresh. The caller computes the state with the same
   *  pure reducer, so the cache can never hold a different extent. */
  update(sessionId: string, state: TranscriptState, totalCount: number): void {
    this.set(sessionId, { state, totalCount })
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

export function useTranscriptStream(
  sessionId: string | null,
  client?: StreamClient,
): UseTranscriptStream {
  const sc = client ?? streamClient()
  const [state, dispatch] = useReducer(reduceTranscript, INITIAL_TRANSCRIPT_STATE)
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())
  // Consecutive failed connection attempts. Drives the escalation from the
  // connection banner to the "live updates unavailable" modal.
  const [reconnectAttempts, setReconnectAttempts] = useState<number>(sc.reconnectAttempts())
  const [pendingQuestions, setPendingQuestions] = useState<PendingQuestion[]>([])
  const [loading, setLoading] = useState(false)
  const [refreshCount, setRefreshCount] = useState(0)
  const [totalCount, setTotalCount] = useState(0)
  const [loadingMore, setLoadingMore] = useState(false)
  const loadedSessionRef = useRef<string | null>(null)
  const currentSessionRef = useRef<string | null>(null)
  // Latest reducer state, readable from event callbacks without adding
  // `state` to every dependency array. Kept in sync during render.
  const stateRef = useRef<TranscriptState>(state)
  stateRef.current = state
  // Latest total count, readable from callbacks without stale closures.
  const totalCountRef = useRef(totalCount)
  totalCountRef.current = totalCount
  const setTotal = useCallback((n: number) => {
    totalCountRef.current = n
    setTotalCount(n)
  }, [])

  const entries = state.entries
  const hasMore = extentHasOlder(state.extent)
  const isViewingLatest = extentIsViewingLatest(state.extent)

  const refresh = useCallback(() => setRefreshCount((c) => c + 1), [])

  /** Apply an event to the ref and dispatch it. Event callbacks that also
   *  update the cache need the resulting state synchronously; the reducer
   *  is pure so the pre-dispatch computation is identical to React's. */
  const apply = useCallback((event: TranscriptEvent): TranscriptState => {
    const next = reduceTranscript(stateRef.current, event)
    stateRef.current = next
    dispatch(event)
    return next
  }, [])

  // Re-seed when the focused session's turn COMPLETES.
  //
  // The backend forks the turn and returns from POST /send immediately, so
  // a re-seed fired on the POST response always raced the turn. The turn's
  // completion is signalled by the WS 'harness-status: idle' activity frame,
  // so re-seeding on that transition catches the turn's entries. This is a
  // CONSISTENCY CHECK, not the live path: the WS tail already delivers new
  // entries as they are broadcast.
  useEffect(() => {
    const unsub = sc.onActivity((sid, event) => {
      if (sid !== currentSessionRef.current) return
      if (event.kind !== 'harness-status' || event.status !== 'idle') return
      refresh()
    })
    return unsub
  }, [sc, refresh])

  // Session load effect: seed the transcript via HTTP GET, or serve from
  // the transcript data cache on session switch for instant display.
  useEffect(() => {
    if (sessionId === null) {
      // Do NOT clear entries when sessionId becomes null. During session
      // switches, currentSessionId can briefly be null (React batching edge
      // cases, tab-list mutations), and clearing entries causes the
      // transcript to flicker — messages disappear and reappear. The entries
      // are replaced when the new session's data loads (cache hit or HTTP
      // fetch). When sessionId is truly null (New Tab, dismiss tab), the
      // ChatArea is typically not visible (composer or harness controls are
      // shown), so stale entries are harmless.
      setPendingQuestions([])
      setLoading(false)
      setLoadingMore(false)
      loadedSessionRef.current = null
      return
    }
    currentSessionRef.current = sessionId
    sc.focus(sessionId)
    let cancelled = false

    const dataCache = getGlobalDataCache()
    const cached = dataCache.get(sessionId)
    const isFirstLoad = loadedSessionRef.current !== sessionId

    if (cached !== undefined && cached.state.entries.length > 0 && isFirstLoad) {
      // Cache hit on session switch — instantly show cached data, no loading
      // spinner. Focus with `since` = last cached entry id so the WS replay
      // delivers only new entries.
      logMemoryNow(`transcript.cache-hit sid=${sessionId} count=${cached.state.entries.length}`)
      apply({ type: 'hydrate', entries: cached.state.entries, extent: cached.state.extent })
      setTotalCount(cached.totalCount)
      setLoading(false)
      // A chunk request may have been in flight when we switched away; the
      // reply is dropped (different session), so clear the spinner/disabled
      // state here instead of waiting for a chunk that will never apply.
      setLoadingMore(false)
      loadedSessionRef.current = sessionId
      console.log(`[transcript] SEED cache-hit session=${sessionId} count=${cached.state.entries.length} totalCount=${cached.totalCount} atStart=${cached.state.extent.atStart} atEnd=${cached.state.extent.atEnd} firstId=${cached.state.entries[0]?.id} lastId=${cached.state.entries[cached.state.entries.length-1]?.id}`)
      const lastId = cached.state.entries[cached.state.entries.length - 1]!.id
      sc.focus(sessionId, lastId)
      fetchPendingQuestions(sessionId).then((qs) => {
        if (cancelled) return
        setPendingQuestions(qs)
      })
    } else {
      // First load (cache miss) or refresh — HTTP GET seed.
      if (isFirstLoad) {
        setLoading(true)
        setLoadingMore(false)
      }
      fetchTranscriptSeed(sessionId).then((seed) => {
        if (cancelled) return
        if (isFirstLoad) {
          const next = apply({ type: 'seed', entries: seed.entries, chunkHasMore: seed.hasMore })
          const cachedSeed = { state: next, totalCount: seed.totalCount }
          setTotalCount(seed.totalCount)
          dataCache.set(sessionId, cachedSeed)
          // Pin the last chunk (the HTTP seed is the latest entries).
          dataCache.pinLast(sessionId, cachedSeed)
          console.log(`[transcript] SEED http-fetch session=${sessionId} count=${seed.entries.length} totalCount=${seed.totalCount} hasMore=${seed.hasMore} firstId=${seed.entries[0]?.id} lastId=${seed.entries[seed.entries.length-1]?.id}`)
        } else {
          // Consistency re-seed: merge new tail entries into the current
          // window. The window edges do not move. Do not write the cache
          // here: the WS live tail is the cache's freshness path, and a
          // merged re-seed must not leak entries the WS has not delivered
          // into the pinned/cached view.
          apply({ type: 'merge-tail', entries: seed.entries })
        }
        setLoading(false)
        logMemoryNow(`transcript.http-seed sid=${sessionId} count=${seed.entries.length}`)
        rateLimitedLog('transcript.seed', 2000, () => `sid=${sessionId} count=${seed.entries.length}`)
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, sc, refreshCount])

  // WS entry subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    let wsEntryCount = 0
    const unsub = sc.onEntry((e) => {
      wsEntryCount++
      detectLoop('WS.entry', 200, 20)
      rateLimitedLog('WS.entry', 1000, (collapsed) =>
        `id=${e.id} total=${wsEntryCount} entries=${collapsed + 1}`,
      )
      const prevCount = stateRef.current.entries.length
      const next = apply({ type: 'entry', entry: e })
      const added = Math.max(0, next.entries.length - prevCount)
      if (added > 0) setTotal(totalCountRef.current + added)
      const sid = currentSessionRef.current
      if (sid !== null) getGlobalDataCache().update(sid, next, totalCountRef.current)
      if (next.entries.length !== prevCount) {
        console.log(`[transcript] WS-ENTRY session=${sid} entryId=${e.id} prevCount=${prevCount} nextCount=${next.entries.length}`)
      }
    })
    return unsub
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, sc, apply])

  // WS entries-chunk subscription (for chunked loading).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onEntriesChunk((chunkSid, chunk) => {
      // Only handle chunks for the currently-focused session. A late reply
      // for a session we switched away from must not corrupt this window,
      // and must not leave `loadingMore` stuck (which disables both header
      // scroll buttons).
      if (chunkSid !== currentSessionRef.current) {
        setLoadingMore(false)
        return
      }
      // The error frame omits hasMore/totalCount (backend catch handler).
      // Nothing about the window can be learned from it.
      if (chunk.hasMore === undefined) {
        apply({ type: 'chunk-error' })
        setLoadingMore(false)
        return
      }
      const chunkTotal = chunk.totalCount ?? chunk.entries.length
      if (chunk.requestBefore === null) {
        console.log(`[transcript] CHUNK latest session=${chunkSid} count=${chunk.entries.length} totalCount=${chunkTotal} hasMore=${chunk.hasMore} firstId=${chunk.entries[0]?.id} lastId=${chunk.entries[chunk.entries.length-1]?.id}`)
        const next = apply({ type: 'chunk-latest', entries: chunk.entries, chunkHasMore: chunk.hasMore })
        setTotal(chunkTotal)
        setLoading(false)
        setLoadingMore(false)
        loadedSessionRef.current = chunkSid
        const cached = { state: next, totalCount: chunkTotal }
        getGlobalDataCache().set(chunkSid, cached)
        // Pin the last chunk so scroll-to-bottom is always instant.
        getGlobalDataCache().pinLast(chunkSid, cached)
        const lastId = chunk.entries.length > 0
          ? chunk.entries[chunk.entries.length - 1]!.id : undefined
        if (lastId !== undefined) sc.focus(chunkSid, lastId)
        else sc.focus(chunkSid)
      } else if (chunk.requestBefore === '__beginning__') {
        console.log(`[transcript] CHUNK beginning session=${chunkSid} count=${chunk.entries.length} totalCount=${chunkTotal} hasMore=${chunk.hasMore} firstId=${chunk.entries[0]?.id} lastId=${chunk.entries[chunk.entries.length-1]?.id}`)
        const next = apply({ type: 'chunk-beginning', entries: chunk.entries, chunkHasMore: chunk.hasMore })
        setTotal(chunkTotal)
        setLoading(false)
        setLoadingMore(false)
        loadedSessionRef.current = chunkSid
        const cached = { state: next, totalCount: chunkTotal }
        getGlobalDataCache().set(chunkSid, cached)
        // Pin the first chunk so scroll-to-top is always instant.
        getGlobalDataCache().pinFirst(chunkSid, cached)
        // Focus without since — just subscribe to live tail, no replay.
        sc.focus(chunkSid)
      } else {
        console.log(`[transcript] CHUNK older session=${chunkSid} count=${chunk.entries.length} totalCount=${chunkTotal} hasMore=${chunk.hasMore} firstId=${chunk.entries[0]?.id} lastId=${chunk.entries[chunk.entries.length-1]?.id}`)
        const next = apply({ type: 'chunk-older', entries: chunk.entries, chunkHasMore: chunk.hasMore })
        setTotal(Math.max(totalCountRef.current, chunkTotal))
        setLoadingMore(false)
        const sid = currentSessionRef.current
        if (sid !== null) {
          const cached = getGlobalDataCache().get(sid)
          getGlobalDataCache().update(sid, next, cached?.totalCount ?? chunkTotal)
        }
      }
    })
    return unsub
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, sc, apply])

  // loadOlder: request the next chunk of older entries.
  const loadOlder = useCallback(() => {
    const sid = currentSessionRef.current
    if (sid === null || loadingMore || !hasMore) return
    const firstId = stateRef.current.entries.length > 0
      ? stateRef.current.entries[0]!.id
      : null
    if (firstId === null) return
    console.log(`[transcript] REQ older session=${sid} before=${firstId} limit=${CHUNK_SIZE}`)
    setLoadingMore(true)
    sc.requestEntries(sid, firstId, CHUNK_SIZE)
  }, [loadingMore, hasMore, sc])

  // loadFromBeginning: jump to the oldest entries (for "scroll to top").
  // Sends a WS requestEntries with before="__beginning__" which the backend
  // handles by returning the oldest N entries in one shot.
  const loadFromBeginning = useCallback((): LoadResult => {
    const sid = currentSessionRef.current
    if (sid === null) return 'unavailable'
    const pinned = getGlobalDataCache().getPinnedFirst(sid)
    if (pinned) {
      if (pinned.state.entries === stateRef.current.entries) {
        console.log(`[transcript] PINNED-FIRST unchanged session=${sid}`)
        return 'unchanged'
      }
      console.log(`[transcript] PINNED-FIRST hit session=${sid} count=${pinned.state.entries.length}`)
      apply({ type: 'hydrate', entries: pinned.state.entries, extent: pinned.state.extent })
      setTotal(pinned.totalCount)
      setLoadingMore(false)
      getGlobalDataCache().set(sid, pinned)
      return 'applied'
    }
    console.log(`[transcript] REQ beginning session=${sid} limit=${CHUNK_SIZE}`)
    setLoadingMore(true)
    sc.requestEntries(sid, '__beginning__', CHUNK_SIZE)
    return 'requested'
  }, [sc, apply])

  // loadLatest: jump to the newest entries (for "scroll to bottom").
  const loadLatest = useCallback((): LoadResult => {
    const sid = currentSessionRef.current
    if (sid === null) return 'unavailable'
    const pinned = getGlobalDataCache().getPinnedLast(sid)
    if (pinned && pinned.state.extent.atEnd) {
      if (pinned.state.entries === stateRef.current.entries) {
        console.log(`[transcript] PINNED-LAST unchanged session=${sid}`)
        return 'unchanged'
      }
      console.log(`[transcript] PINNED-LAST hit session=${sid} count=${pinned.state.entries.length}`)
      apply({ type: 'hydrate', entries: pinned.state.entries, extent: pinned.state.extent })
      setTotal(pinned.totalCount)
      setLoadingMore(false)
      getGlobalDataCache().set(sid, pinned)
      // Re-focus for live tail to catch any new entries since the pin.
      const lastId = pinned.state.entries.length > 0
        ? pinned.state.entries[pinned.state.entries.length - 1]!.id
        : undefined
      if (lastId !== undefined) sc.focus(sid, lastId)
      else sc.focus(sid)
      return 'applied'
    }
    console.log(`[transcript] REQ latest session=${sid} limit=${CHUNK_SIZE}`)
    setLoadingMore(true)
    sc.requestEntries(sid, null, CHUNK_SIZE)
    return 'requested'
  }, [sc, apply])

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
      setReconnectAttempts(sc.reconnectAttempts())
      // Reset loadingMore on disconnect (in-flight chunk request is lost).
      if (s === 'reconnecting' || s === 'closed') {
        setLoadingMore(false)
      }
      // On reconnect, re-request the initial chunk if still loading.
      if ((s === 'live' || s === 'replaying') && loading && stateRef.current.entries.length === 0) {
        const sid = currentSessionRef.current
        if (sid !== null) sc.requestEntries(sid, null, CHUNK_SIZE)
      }
    })
    return unsub
  }, [sc, loading])

  return {
    entries, status, lastError, pendingQuestions, loading, refresh,
    hasMore, totalCount, loadingMore, loadOlder, loadFromBeginning, loadLatest, isViewingLatest,
    reconnectAttempts,
    reconnectNow: () => sc.reconnectNow(),
  }
}
