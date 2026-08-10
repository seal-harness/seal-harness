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
  | { kind: 'reply-delivered'; timestamp: string }

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
  /** Session ids the backend reports are currently in a @thinking@ turn
   *  (the broker's in-memory set). Used by the frontend to hydrate the
   *  sidebar on (re)connect/refresh so a mid-turn tab does not blank to
   *  Idle before the next harness-status event arrives. Tolerant of
   *  older servers that omit the field. */
  thinkingSessionIds?: string[]
}

/** A pending human-confirmation question from an Untrusted opcode (SHELL_EXEC,
 *  BIN_EXEC, etc.) under Supervised autonomy, or from ASK_HUMAN. The agent
 *  loop is blocked until the human answers via POST .../questions/:qid/answer
 *  or cancels via POST .../questions/:qid/cancel. */
export interface AskEvent {
  type: 'ask'
  sessionId: string
  ask: { id: string; question: string }
}

/** A pending question was answered or cancelled; the frontend should dismiss
 *  its prompt UI. `resolution` is "answered" or "cancelled". */
export interface AskResolvedEvent {
  type: 'ask_resolved'
  sessionId: string
  ask: { id: string; resolution: string }
}

export interface AgentDefsChangedEvent {
  type: 'agent-defs-changed'
}

export interface SkillsChangedEvent {
  type: 'skills-changed'
}

export interface ReposChangedEvent {
  type: 'repos-changed'
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
  | AskEvent
  | AskResolvedEvent
  | AgentDefsChangedEvent
  | SkillsChangedEvent
  | ReposChangedEvent

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
  thinkingSessionIds?: string[]
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
  /** Subscribe to pending human-confirmation questions (ASK_HUMAN / Untrusted opcode gate). */
  onAsk(cb: (sessionId: string, ask: { id: string; question: string }) => void): () => void
  /** Subscribe to question-resolved events (answer delivered or cancelled). */
  onAskResolved(cb: (sessionId: string, ask: { id: string; resolution: string }) => void): () => void
  /** Subscribe to agent-defs-changed invalidation signals (re-fetch /api/agents). */
  onAgentDefsChanged(cb: () => void): () => void
  /** Subscribe to skills-changed invalidation signals (re-fetch /api/skills). */
  onSkillsChanged(cb: () => void): () => void
  /** Subscribe to repos-changed invalidation signals (re-fetch /api/repos). */
  onReposChanged(cb: () => void): () => void
  /** Last error message, or null when no terminal error has occurred. */
  lastError(): string | null
}

export interface SessionActivityState {
  harness: HarnessActivity | null
  /** Count of entries since last focus or since mount. */
  unread: number
  /** ISO timestamp of most recent entry, or null. */
  lastEntryAt: string | null
  /** ISO timestamp the session was last "seen" by the user: either the
   *  user focused the session in the web UI, or the backend reported the
   *  last assistant reply was delivered to a subscribed chat channel
   *  (Signal/Telegram/CLI). The tab status indicator uses this to
   *  distinguish Idle Unread (LLM idle, last assistant entry newer than
   *  seenAt) from Idle Read. null until the first seen signal arrives. */
  seenAt: string | null
}

export interface UseTranscriptStream {
  entries: TranscriptEntry[]
  status: StreamStatus
  lastError: string | null
  /** Pending human-confirmation questions (Untrusted opcode gate or ASK_HUMAN). */
  pendingQuestions: import('../hooks/useApi').PendingQuestion[]
  /** True until the first HTTP seed fetch completes. The WS stream hook is
   *  now the SOLE source of transcript entries (the duplicate `useTranscript`
   *  fetch was removed to avoid two concurrent 257KB fetches on every tab
   *  click), so `loading` is derived from the seed-fetch state. */
  loading: boolean
  /** Force a re-seed. Bumps the internal `refreshCount` which re-runs the
   *  HTTP seed fetch. Used as `useSendMessage`'s `onComplete` callback —
   *  the WS stream usually delivers new entries live, but the re-seed
   *  acts as a consistency check. */
  refresh: () => void
}

export interface UseSessionActivityStream {
  sessions: Record<string, SessionActivityState>
  status: StreamStatus
  lastError: string | null
}