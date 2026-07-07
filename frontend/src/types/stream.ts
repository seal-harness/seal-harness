// Wire-protocol TypeScript types for the Seal live-stream WebSocket.
// Rebuilt against Seal's gateway (Seal.Gateway.Stream + StreamBroker).
//
// The server emits typed event envelopes (discriminated by `type`) so the
// client can dispatch reliably; the client emits `op`-discriminated frames.
// Keeping the two discriminants distinct guards against accidental
// cross-dispatch during refactors.

import type { HarnessActivity, SessionInfo, TranscriptEntry } from '../types'

// ── Server → Client ─────────────────────────────────────────────────────

export interface HelloEvent {
  type: 'hello'
  /** Protocol version marker; bump on breaking wire changes. */
  protocolVersion: 'v1'
  /** ISO-8601 timestamp; clients use changes here to detect server restarts. */
  serverStartedAt: string
}

export interface EntryEvent {
  type: 'entry'
  sessionId: string
  entry: TranscriptEntry
}

/** Emitted when a streaming entry's payload grows. The entry already exists in
 *  the transcript (same id); consumers should replace it in place. */
export interface EntryUpdateEvent {
  type: 'entry-update'
  sessionId: string
  entry: TranscriptEntry
}

/** `SessionMeta` shape as emitted by the Haskell backend's `ToJSON SessionMeta`
 *  (snake_case fields), carried on the activity stream. */
export interface StreamSessionMeta {
  id: string
  agent?: string
  runtime: string
  model: string
  channel: string
  created_at: string
  last_active: string
}

export type ActivityEvent =
  | { kind: 'entry-at'; timestamp: string }
  | { kind: 'harness-status'; status: HarnessActivity }
  | { kind: 'session-created'; session: StreamSessionMeta }

export interface ActivityEnvelope {
  type: 'activity'
  sessionId: string
  activity: ActivityEvent
}

export interface ReplayEndEvent {
  type: 'replay-end'
  sessionId: string
  lastReplayedEntryId: string | null
}

export interface OverflowEvent {
  type: 'overflow'
}

export type StreamErrorCode =
  | 'invalid-op'
  | 'invalid-frame'
  | 'session-not-found'
  | 'frame-too-large'
  | 'replay-failed'
  | 'replay-aborted'
  | 'internal'

export interface ErrorEvent {
  type: 'error'
  code: StreamErrorCode
  message: string
}

export interface ListsEvent {
  type: 'lists'
  tabs: unknown[]               // raw wire tabs (snake_case) — mapped at the useListsStream boundary
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  /** Sessions backing an open tab. Deduped out of `recentSessions` above. */
  tabSessions: SessionInfo[]
}

export type ServerEvent =
  | HelloEvent
  | EntryEvent
  | EntryUpdateEvent
  | ActivityEnvelope
  | ReplayEndEvent
  | OverflowEvent
  | ErrorEvent
  | ListsEvent

// ── Client → Server ────────────────────────────────────────────────────

export type ClientOp =
  | { op: 'focus'; sessionId: string | null }
  | { op: 'focus'; sessionId: string; since: string }

// ── Stream client + hook contracts ──────────────────────────────────────

export type StreamStatus =
  | 'connecting'
  | 'live'
  | 'reconnecting'
  | 'replaying'
  | 'closed'

export interface ListsSnapshot {
  tabs: unknown[]
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  tabSessions: SessionInfo[]
}

export interface StreamClient {
  /** Current connection status. */
  readonly status: StreamStatus
  /** Focus a session (optionally requesting replay from `since`). */
  focus(sessionId: string | null, since?: string): void
  /** Subscribe to entries for the currently-focused session. */
  onEntry(cb: (e: TranscriptEntry) => void): () => void
  /** Subscribe to activity events for ALL sessions. */
  onActivity(cb: (sessionId: string, a: ActivityEvent) => void): () => void
  /** Subscribe to sidebar list snapshots (tabs + sessions). */
  onLists(cb: (snapshot: ListsSnapshot) => void): () => void
  /** Subscribe to status changes. */
  onStatusChange(cb: (s: StreamStatus) => void): () => void
  /** Last error message, or null when no terminal error has occurred. */
  lastError(): string | null
}

export interface SessionActivityState {
  harness: HarnessActivity | null
  /** Count of entries since last focus or since mount. */
  unread: number
  /** ISO timestamp of most recent entry, or null. */
  lastEntryAt: string | null
}

export interface UseTranscriptStream {
  entries: TranscriptEntry[]
  status: StreamStatus
  lastError: string | null
}

export interface UseSessionActivityStream {
  sessions: Record<string, SessionActivityState>
  status: StreamStatus
  lastError: string | null
}