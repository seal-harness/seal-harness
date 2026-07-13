/**
 * Singleton WebSocket client for the Seal live-stream endpoint.
 *
 * Rebuilt against Seal's gateway (Seal.Gateway.Stream + StreamBroker). The
 * structure mirrors the reference client: auto-reconnect with exponential
 * backoff (250 ms → 5 s, jittered) and NO fixed attempt cap, a status union
 * with subscriber notifications, `lastError` to distinguish hard errors from
 * clean closes, and a focus-state machine that re-sends the last focus op
 * with the most recent entry id as `since` on reconnect so the server can
 * replay missed entries.
 *
 * Exposes `createStreamClient(url)` as a factory for tests so each test can
 * spin up a fresh instance; production uses the `streamClient()` singleton.
 */

import type {
  ActivityEvent,
  ClientOp,
  ListsSnapshot,
  ServerEvent,
  StreamClient,
  StreamStatus,
} from '../types/stream'
import type { TranscriptEntry } from '../types'

const RECONNECT_BASE_MS = 250
const RECONNECT_MAX_MS = 5000
// Exponent ceiling for the backoff calc. Past this the delay is already
// pinned at RECONNECT_MAX_MS, and it keeps `reconnectAttempt` from feeding
// an unbounded value into Math.pow during a very long outage.
const RECONNECT_MAX_EXPONENT = 8

type FocusState =
  | { kind: 'none' }
  | { kind: 'focused'; sessionId: string | null; since: string | undefined }

class StreamClientImpl implements StreamClient {
  private url: string
  private ws: WebSocket | null = null
  private _status: StreamStatus = 'connecting'
  private focusState: FocusState = { kind: 'none' }
  private lastEntryId: string | null = null
  private _lastServerStartedAt: string | null = null
  private reconnectAttempt = 0
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private closedByUser = false
  private _lastError: string | null = null
  private statusListeners = new Set<(s: StreamStatus) => void>()
  private entryListeners = new Set<(e: TranscriptEntry) => void>()
  private activityListeners = new Set<(sid: string, a: ActivityEvent) => void>()
  private listsListeners = new Set<(snapshot: ListsSnapshot) => void>()
  private askListeners = new Set<(sid: string, ask: { id: string; question: string }) => void>()
  private askResolvedListeners = new Set<(sid: string, ask: { id: string; resolution: string }) => void>()

  constructor(url: string) {
    this.url = url
    this.connect()
  }

  get status(): StreamStatus {
    return this._status
  }

  lastError(): string | null {
    return this._lastError
  }

  /** Most recent `serverStartedAt` from a `hello` frame, or null. */
  lastServerStartedAt(): string | null {
    return this._lastServerStartedAt
  }

  focus(sessionId: string | null, since?: string): void {
    this.focusState = { kind: 'focused', sessionId, since }
    if (sessionId === null) {
      this.lastEntryId = null
    }
    if (sessionId !== null && since !== undefined) {
      this.setStatus('replaying')
    }
    this.sendFocus()
  }

  onEntry(cb: (e: TranscriptEntry) => void): () => void {
    this.entryListeners.add(cb)
    return () => {
      this.entryListeners.delete(cb)
    }
  }

  onActivity(cb: (sid: string, a: ActivityEvent) => void): () => void {
    this.activityListeners.add(cb)
    return () => {
      this.activityListeners.delete(cb)
    }
  }

  onLists(cb: (snapshot: ListsSnapshot) => void): () => void {
    this.listsListeners.add(cb)
    return () => {
      this.listsListeners.delete(cb)
    }
  }

  onStatusChange(cb: (s: StreamStatus) => void): () => void {
    this.statusListeners.add(cb)
    return () => {
      this.statusListeners.delete(cb)
    }
  }

  onAsk(cb: (sid: string, ask: { id: string; question: string }) => void): () => void {
    this.askListeners.add(cb)
    return () => {
      this.askListeners.delete(cb)
    }
  }

  onAskResolved(cb: (sid: string, ask: { id: string; resolution: string }) => void): () => void {
    this.askResolvedListeners.add(cb)
    return () => {
      this.askResolvedListeners.delete(cb)
    }
  }

  /** Closes the connection permanently. No further reconnect attempts. */
  close(): void {
    this.closedByUser = true
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws !== null) {
      try {
        this.ws.close(1000, 'client closed')
      } catch {
        /* ignore */
      }
      this.ws = null
    }
    this.setStatus('closed')
  }

  // ── internals ──────────────────────────────────────────────────────────

  private connect(): void {
    let sock: WebSocket
    try {
      sock = new WebSocket(this.url)
    } catch (e) {
      // Browsers throw synchronously on some bad URLs. Treat as a fatal error.
      this._lastError = e instanceof Error ? e.message : 'WebSocket construction failed'
      this.setStatus('closed')
      return
    }
    this.ws = sock
    sock.onopen = () => this.handleOpen()
    sock.onmessage = (ev: MessageEvent) => this.handleMessage(ev)
    sock.onclose = (ev: CloseEvent) => this.handleClose(ev)
    sock.onerror = () => {
      // onerror always precedes onclose; we let close handle the bookkeeping.
    }
  }

  private handleOpen(): void {
    this.setStatus('live')
    if (this.focusState.kind === 'focused') {
      const since =
        this.lastEntryId !== null && this.focusState.sessionId !== null
          ? this.lastEntryId
          : this.focusState.since
      const stateToSend: FocusState = {
        kind: 'focused',
        sessionId: this.focusState.sessionId,
        since,
      }
      if (stateToSend.sessionId !== null && since !== undefined) {
        this.setStatus('replaying')
      }
      this.sendFocusFrame(stateToSend)
    }
  }

  private sendFocus(): void {
    if (this.focusState.kind !== 'focused') return
    if (this.ws !== null && this.ws.readyState === WebSocket.OPEN) {
      this.sendFocusFrame(this.focusState)
    }
  }

  private sendFocusFrame(fs: FocusState): void {
    if (fs.kind !== 'focused') return
    if (this.ws === null || this.ws.readyState !== WebSocket.OPEN) return
    const op: ClientOp =
      fs.sessionId === null
        ? { op: 'focus', sessionId: null }
        : fs.since !== undefined
          ? { op: 'focus', sessionId: fs.sessionId, since: fs.since }
          : { op: 'focus', sessionId: fs.sessionId }
    try {
      this.ws.send(JSON.stringify(op))
    } catch (e) {
      this._lastError = e instanceof Error ? e.message : 'send failed'
    }
  }

  private handleMessage(ev: MessageEvent): void {
    let parsed: unknown
    try {
      parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data))
    } catch {
      return
    }
    if (parsed === null || typeof parsed !== 'object' || !('type' in parsed)) return
    // First server frame after (re)connect is evidence the connection is healthy.
    this.reconnectAttempt = 0
    const event = parsed as ServerEvent
    switch (event.type) {
      case 'hello':
        this._lastServerStartedAt = event.serverStartedAt
        break
      case 'entry': {
        this.lastEntryId = event.entry.id
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId !== null &&
          this.focusState.sessionId === event.sessionId
        ) {
          for (const cb of this.entryListeners) cb(event.entry)
        }
        break
      }
      case 'entry-update': {
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId === event.sessionId
        ) {
          for (const cb of this.entryListeners) cb({ ...event.entry, streaming: true })
        }
        break
      }
      case 'activity':
        for (const cb of this.activityListeners) cb(event.sessionId, event.activity)
        break
      case 'lists':
        for (const cb of this.listsListeners) cb(event)
        break
      case 'ask':
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId === event.sessionId
        ) {
          for (const cb of this.askListeners) cb(event.sessionId, event.ask)
        }
        break
      case 'ask_resolved':
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId === event.sessionId
        ) {
          for (const cb of this.askResolvedListeners) cb(event.sessionId, event.ask)
        }
        break
      case 'replay-end':
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId === event.sessionId
        ) {
          if (event.lastReplayedEntryId !== null) {
            this.lastEntryId = event.lastReplayedEntryId
          }
          this.setStatus('live')
        }
        break
      case 'overflow':
        this._lastError = 'Server queue overflow — please refresh'
        break
      case 'error':
        this._lastError = `${event.code}: ${event.message}`
        break
      default:
        // Forward-compat: ignore unknown event types.
        break
    }
  }

  private handleClose(ev: CloseEvent): void {
    if (this.closedByUser) {
      this.setStatus('closed')
      return
    }
    if (!ev.wasClean) {
      if (ev.reason) {
        this._lastError = ev.reason
      } else if (this._lastError === null) {
        this._lastError = `connection closed (code ${ev.code})`
      }
    }
    this.ws = null
    this.setStatus('reconnecting')
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    const attempt = this.reconnectAttempt
    this.reconnectAttempt += 1
    const expo = Math.min(
      RECONNECT_BASE_MS * Math.pow(2, Math.min(attempt, RECONNECT_MAX_EXPONENT)),
      RECONNECT_MAX_MS,
    )
    const jitterFloor = expo * 0.5
    const delay = jitterFloor + Math.random() * (expo - jitterFloor)
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      if (this.closedByUser) return
      this.connect()
    }, delay)
  }

  private setStatus(s: StreamStatus): void {
    if (this._status === s) return
    this._status = s
    for (const cb of this.statusListeners) cb(s)
  }
}

/** Factory used by tests; production uses the shared `streamClient` singleton. */
export function createStreamClient(url: string): StreamClient & { close(): void } {
  return new StreamClientImpl(url)
}

/**
 * Build the default WS URL from the current page. Seal 7a runs the WS server
 * on a separate port from the REST + static WARP server (default 8081); the
 * port is read from `import.meta.env.VITE_WS_PORT` (falling back to 8081).
 * Uses `wss:` on https pages and `ws:` on http pages.
 */
function defaultStreamUrl(): string {
  const wsPort = import.meta.env.VITE_WS_PORT ?? '8081'
  if (typeof window === 'undefined') return `ws://localhost:${wsPort}/`
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  // The WS server is on a separate port; the host is the page host.
  return `${proto}//${window.location.hostname}:${wsPort}/`
}

let _instance: (StreamClient & { close(): void }) | null = null

/** Shared singleton — lazily constructed on first access. */
export function streamClient(): StreamClient {
  if (_instance === null) {
    _instance = new StreamClientImpl(defaultStreamUrl())
  }
  return _instance
}