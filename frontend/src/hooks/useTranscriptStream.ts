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
  // Evict any streaming placeholder when a finalized entry arrives.
  let base = existing
  if (!incoming.streaming) {
    const streamingIdx = existing.findIndex((e) => e.streaming)
    if (streamingIdx !== -1) {
      base = existing.filter((_, i) => i !== streamingIdx)
    }
  }
  for (let i = 0; i < base.length; i++) {
    if (base[i]!.id === incoming.id) {
      // Replace in place (stable timestamp keeps sort order intact; streaming
      // entry-update entries carry their original timestamp throughout).
      const next = base.slice()
      next[i] = incoming
      done({ count: existing.length, meta: { mode: 'replace' } })
      return next
    }
  }
  // Append-only: new entries always go at the end. The HTTP seed provides
  // the initial sorted array; WS events arrive in append order.
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
      setEntries([])
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
      // the WS replay delivers only new entries.
      setEntries(cached); console.log("[transcript-stream] cache hit", { sessionId, entryCount: cached.length })
      setLoading(false)
      loadedSessionRef.current = sessionId
      const lastId = cached[cached.length - 1]!.id
      sc.focus(sessionId, lastId)
      fetchPendingQuestions(sessionId).then((qs) => {
        if (cancelled) return
        setPendingQuestions(qs)
      })
      // Background re-seed for consistency — only adopt if it has at
      // least as many entries as the current state (prevents a stale
      // re-seed from overwriting newer WS-delivered entries).
      fetchTranscriptSeed(sessionId).then((seed) => {
        if (cancelled || currentSessionRef.current !== sessionId) return
        setEntries((prev) => {
          if (seed.length >= prev.length) {
            dataCache.set(sessionId, seed)
            return seed
          }
          return prev
        })
      })
    } else {
      // Cache miss or refresh — full HTTP GET seed.
      if (isFirstLoad) setLoading(true)
      fetchTranscriptSeed(sessionId).then((seed) => {
        if (cancelled) return
        setEntries(seed); console.log("[transcript-stream] seed fetched", { sessionId, entryCount: seed.length })
        dataCache.set(sessionId, seed)
        setLoading(false)
        loadedSessionRef.current = sessionId
        const lastId = seed.length > 0 ? seed[seed.length - 1]!.id : undefined
        if (lastId !== undefined) sc.focus(sessionId, lastId)
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
    })
    return unsub
  }, [sc])

  return { entries, status, lastError, pendingQuestions, loading, refresh }
}