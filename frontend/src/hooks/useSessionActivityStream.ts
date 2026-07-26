/**
 * React hook: subscribe to per-session activity signals (entry-at,
 * harness-status, session-created) for ALL sessions.
 *
 * Used by the sidebar to render:
 *   - a thinking-spinner when `harness === 'thinking'`,
 *   - an unread badge when `unread > 0`,
 *   - "X seconds ago" from `lastEntryAt`.
 */

import { useEffect, useRef, useState } from 'react'
import type {
  ActivityEvent,
  SessionActivityState,
  StreamClient,
  StreamStatus,
  UseSessionActivityStream,
} from '../types/stream'
import { streamClient } from '../lib/streamClient'

const DEFAULT_STATE: SessionActivityState = {
  harness: null,
  unread: 0,
  lastEntryAt: null,
  seenAt: null,
}

export function applyActivity(
  current: Record<string, SessionActivityState>,
  sessionId: string,
  event: ActivityEvent,
): Record<string, SessionActivityState> {
  const prev = current[sessionId] ?? DEFAULT_STATE
  let next: SessionActivityState
  switch (event.kind) {
    case 'entry-at':
      next = {
        ...prev,
        unread: prev.unread + 1,
        lastEntryAt: event.timestamp,
      }
      break
    case 'harness-status':
      if (prev.harness === event.status) return current
      // A thinking → idle transition means a turn just finished and a new
      // assistant reply landed. The backend's `entry` frames are filtered
      // to the focused session's WS subscriber, so a non-focused tab never
      // receives the entries — and the backend does not emit `entry-at`
      // activity events. Without this signal, a non-focused tab would stay
      // Idle Read forever (lastEntryAt null/old), never transitioning to
      // Idle Unread when the thinking finishes. Treat the transition as an
      // implicit "new entry": stamp lastEntryAt at now and bump unread so
      // deriveTabStatusKind returns idle-unread. The focused-session clear
      // below zeros the unread bump for the tab the user is watching.
      if (prev.harness === 'thinking' && event.status === 'idle') {
        const now = new Date().toISOString()
        next = {
          ...prev,
          harness: event.status,
          unread: prev.unread + 1,
          lastEntryAt: now,
        }
      } else {
        next = { ...prev, harness: event.status }
      }
      break
    case 'reply-delivered':
      // A reply-delivered signal marks the session "seen" (the last
      // assistant reply was delivered to ≥1 chat channel the user is
      // expected to read). Advances seenAt only forward so a stale
      // out-of-order frame never regresses it.
      next = {
        ...prev,
        seenAt: maxIso(prev.seenAt, event.timestamp),
      }
      break
    case 'session-created':
      // session-created seeds an entry but otherwise leaves the counters alone
      // (the entry itself surfaces as entry-at later).
      if (current[sessionId] !== undefined) return current
      next = { ...DEFAULT_STATE }
      break
    default:
      return current
  }
  return { ...current, [sessionId]: next }
}

export function useSessionActivityStream(
  focusedSessionId: string | null,
  client?: StreamClient,
  /** The backend's current thinking-session set (from the lists snapshot),
   *  used to hydrate the sidebar on (re)connect/refresh so a mid-turn tab
   *  does not blank to Idle before the next harness-status event arrives.
   *  Pass `[]` (or omit) when the caller has no snapshot yet. */
  thinkingSessionIds: string[] = [],
): UseSessionActivityStream {
  const sc = client ?? streamClient()
  const [sessions, setSessions] = useState<Record<string, SessionActivityState>>({})
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())

  // Latest focused id, accessed inside the activity callback. Using a ref
  // avoids re-subscribing to the stream every time focus changes.
  const focusedRef = useRef<string | null>(focusedSessionId)
  useEffect(() => {
    focusedRef.current = focusedSessionId
  }, [focusedSessionId])

  // Hydrate from the lists snapshot's thinking set. Merges idempotently:
  // sessions IN the set get harness='thinking' (only if not already seen
  // newer); sessions NOT in the set are left alone (a live harness-status
  // event is authoritative; we only seed, never override). Runs whenever
  // the snapshot's thinking set changes (e.g. on (re)connect/refresh).
  useEffect(() => {
    if (thinkingSessionIds.length === 0) return
    setSessions((prev) => {
      let next = prev
      for (const sid of thinkingSessionIds) {
        const existing = next[sid]
        // Only seed thinking when there is no state yet OR the harness
        // field is null (we don't override a definitive idle from a live
        // event, and we don't touch the seen/unread counters).
        if (existing === undefined) {
          next = { ...next, [sid]: { ...DEFAULT_STATE, harness: 'thinking' } }
        } else if (existing.harness === null) {
          next = { ...next, [sid]: { ...existing, harness: 'thinking' } }
        }
      }
      return next
    })
  }, [thinkingSessionIds])

  useEffect(() => {
    const unsub = sc.onActivity((sid, event) => {
      setSessions((prev) => {
        const next = applyActivity(prev, sid, event)
        // Entries / thinking-finish signals arriving for the currently-viewed
        // session are not "unread" — the user is looking at them right now.
        const isFocused = focusedRef.current !== null && focusedRef.current === sid
        if (
          (event.kind === 'entry-at' ||
            (event.kind === 'harness-status' && event.status === 'idle')) &&
          isFocused
        ) {
          return clearUnread(next, sid)
        }
        return next
      })
    })
    return unsub
  }, [sc])

  // When the focus changes to a session, zero its accumulated unread —
  // by switching to it the user has caught up.
  useEffect(() => {
    if (focusedSessionId === null) return
    setSessions((prev) => clearUnread(prev, focusedSessionId))
  }, [focusedSessionId])

  useEffect(() => {
    const unsub = sc.onStatusChange((s) => {
      setStatus(s)
      setLastError(sc.lastError())
    })
    return unsub
  }, [sc])

  return { sessions, status, lastError }
}

/** Clear the unread counter for a session and mark it seen at the given
 *  timestamp (e.g. when the user selects it). `seenAt` advances only
 *  forward so an out-of-order focus never regresses it. */
export function clearUnread(
  current: Record<string, SessionActivityState>,
  sessionId: string,
  seenAt: string = new Date().toISOString(),
): Record<string, SessionActivityState> {
  const prev = current[sessionId]
  if (prev === undefined) {
    return { ...current, [sessionId]: { ...DEFAULT_STATE, seenAt } }
  }
  if (prev.unread === 0 && (prev.seenAt !== null && !isNewer(seenAt, prev.seenAt))) {
    return current
  }
  return {
    ...current,
    [sessionId]: {
      ...prev,
      unread: 0,
      seenAt: maxIso(prev.seenAt, seenAt),
    },
  }
}

/** Compare two ISO timestamps. Returns the newer one, or the non-null
 *  one when only one is present, or null when both are null. Treats an
 *  unparseable timestamp as older than anything (defensive against a
 *  malformed backend payload). */
function maxIso(a: string | null, b: string | null): string | null {
  if (a === null) return b
  if (b === null) return a
  return isNewer(b, a) ? b : a
}

/** True if `t` is strictly newer than `than`. Defensive: an unparseable
 *  `t` is treated as NOT newer (so a malformed frame never regresses
 *  `seenAt` forward). */
function isNewer(t: string, than: string): boolean {
  const tMs = parseIsoMs(t)
  const thanMs = parseIsoMs(than)
  if (tMs === null || thanMs === null) return false
  return tMs > thanMs
}

function parseIsoMs(t: string): number | null {
  const ms = Date.parse(t)
  return Number.isNaN(ms) ? null : ms
}