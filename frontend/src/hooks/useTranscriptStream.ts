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
 * Pure reconciler: insert `incoming` into `existing`, dedup by id, sort by
 * timestamp ascending. Replaces the entry with a matching id (always returns
 * a new array), or inserts new entries at the sorted position by timestamp.
 */
export function reconcileEntries(
  existing: TranscriptEntry[],
  incoming: TranscriptEntry,
): TranscriptEntry[] {
  const done = perf.begin('reconcileEntries')
  for (let i = 0; i < existing.length; i++) {
    if (existing[i]!.id === incoming.id) {
      // Replace in place (stable timestamp keeps sort order intact; streaming
      // entry-update entries carry their original timestamp throughout).
      const next = existing.slice()
      next[i] = incoming
      done({ count: existing.length, meta: { mode: 'replace' } })
      return next
    }
  }
  // Find insertion index that keeps the array sorted by timestamp ascending.
  let insertAt = existing.length
  for (let i = existing.length - 1; i >= 0; i--) {
    if (existing[i]!.timestamp.localeCompare(incoming.timestamp) <= 0) {
      insertAt = i + 1
      break
    }
    insertAt = i
  }
  const next = existing.slice()
  next.splice(insertAt, 0, incoming)
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

  const refresh = useCallback(() => setRefreshCount((c) => c + 1), [])

  // Initial HTTP GET seed + focus the session. Set live focus eagerly BEFORE
  // the seed fetch (so live events during the GET round-trip aren't dropped),
  // then upgrade to a `since`-replay focus once the seed lands. Also fetch
  // any pending questions (recovered on reconnect) so the user can answer
  // a question that arrived during a WS gap.
  useEffect(() => {
    if (sessionId === null) {
      setEntries([])
      setPendingQuestions([])
      setLoading(false)
      loadedSessionRef.current = null
      return
    }
    sc.focus(sessionId)
    let cancelled = false
    // Only show "Loading transcript..." on the FIRST load for a session —
    // NOT on refresh-after-send (which fires `refresh` via `useSendMessage`'s
    // `onComplete`). At refresh time the WS stream has already delivered the
    // new entries live, so setting `loading=true` would flash "Loading
    // transcript..." and clear the visible entries for the round-trip.
    const isFirstLoad = loadedSessionRef.current !== sessionId
    if (isFirstLoad) setLoading(true)
    fetchTranscriptSeed(sessionId).then((seed) => {
      if (cancelled) return
      setEntries(seed)
      setLoading(false)
      loadedSessionRef.current = sessionId
      const lastId = seed.length > 0 ? seed[seed.length - 1]!.id : undefined
      if (lastId !== undefined) {
        sc.focus(sessionId, lastId)
      }
    })
    fetchPendingQuestions(sessionId).then((qs) => {
      if (cancelled) return
      setPendingQuestions(qs)
    })
    return () => {
      cancelled = true
    }
  }, [sessionId, sc, refreshCount])

  // WS entry subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onEntry((e) => {
      setEntries((prev) => reconcileEntries(prev, e))
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