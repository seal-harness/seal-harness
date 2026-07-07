import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createStreamClient } from '../streamClient'
import type { StreamClient } from '../../types/stream'

/**
 * Mock WebSocket implementation. We need:
 *   - control over open/close/error timing
 *   - capture of messages the client sends
 *   - the ability to inject messages from the "server"
 */
type MockSocketRef = { socket: MockSocket | null; instances: MockSocket[] }

class MockSocket {
  static OPEN = 1
  static CONNECTING = 0
  static CLOSING = 2
  static CLOSED = 3

  readyState: number = MockSocket.CONNECTING
  url: string
  sent: string[] = []
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null

  constructor(url: string) {
    this.url = url
  }

  send(data: string): void {
    if (this.readyState !== MockSocket.OPEN) {
      throw new Error('Cannot send: socket not open')
    }
    this.sent.push(data)
  }

  close(code?: number, reason?: string): void {
    this.readyState = MockSocket.CLOSED
    const ev = { code: code ?? 1000, reason: reason ?? '', wasClean: true } as CloseEvent
    queueMicrotask(() => this.onclose?.(ev))
  }

  // Test helpers (not part of the WebSocket API):
  simulateOpen(): void {
    this.readyState = MockSocket.OPEN
    this.onopen?.(new Event('open'))
  }
  simulateMessage(payload: unknown): void {
    const data = typeof payload === 'string' ? payload : JSON.stringify(payload)
    this.onmessage?.({ data } as MessageEvent)
  }
  simulateClose(code: number, reason: string, wasClean = true): void {
    this.readyState = MockSocket.CLOSED
    const ev = { code, reason, wasClean } as CloseEvent
    this.onclose?.(ev)
  }
}

function installMockSocket(): MockSocketRef {
  const ref: MockSocketRef = { socket: null, instances: [] }
  const ctor = function (this: MockSocket, url: string) {
    const s = new MockSocket(url)
    ref.socket = s
    ref.instances.push(s)
    return s
  } as unknown as typeof WebSocket
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).OPEN = MockSocket.OPEN
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CONNECTING = MockSocket.CONNECTING
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CLOSING = MockSocket.CLOSING
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CLOSED = MockSocket.CLOSED
  vi.stubGlobal('WebSocket', ctor)
  return ref
}

describe('streamClient', () => {
  let ref: MockSocketRef
  let client: StreamClient
  let cleanup: () => void

  beforeEach(() => {
    vi.useFakeTimers()
    ref = installMockSocket()
    const c = createStreamClient('ws://test.example/')
    client = c
    cleanup = () => c.close()
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('starts in connecting state', () => {
    expect(client.status).toBe('connecting')
  })

  it('transitions to live on socket open + receives hello', () => {
    ref.socket!.simulateOpen()
    expect(client.status).toBe('live')
    ref.socket!.simulateMessage({ type: 'hello', protocolVersion: 'v1', serverStartedAt: '2026-01-01T00:00:00Z' })
    expect((client as StreamClient & { lastServerStartedAt(): string | null }).lastServerStartedAt()).toBe('2026-01-01T00:00:00Z')
  })

  it('sends a focus op when focus() is called after open', () => {
    ref.socket!.simulateOpen()
    ref.socket!.sent.length = 0
    client.focus('sess-1')
    expect(ref.socket!.sent).toHaveLength(1)
    const op = JSON.parse(ref.socket!.sent[0]!)
    expect(op).toEqual({ op: 'focus', sessionId: 'sess-1' })
  })

  it('sends a focus op with since when a since is provided', () => {
    ref.socket!.simulateOpen()
    ref.socket!.sent.length = 0
    client.focus('sess-1', 'entry-5')
    expect(ref.socket!.sent).toHaveLength(1)
    const op = JSON.parse(ref.socket!.sent[0]!)
    expect(op).toEqual({ op: 'focus', sessionId: 'sess-1', since: 'entry-5' })
    expect(client.status).toBe('replaying')
  })

  it('delivers an entry event for the focused session to onEntry subscribers', () => {
    ref.socket!.simulateOpen()
    client.focus('sess-1')
    const received: unknown[] = []
    const unsub = client.onEntry((e) => received.push(e))
    const entry = { id: 'e1', timestamp: 't', direction: 'response', payload: 'hi', harness: null, model: 'm', raw: '{}' }
    ref.socket!.simulateMessage({ type: 'entry', sessionId: 'sess-1', entry })
    expect(received).toHaveLength(1)
    expect((received[0] as { id: string }).id).toBe('e1')
    unsub()
  })

  it('does NOT deliver an entry event for a non-focused session', () => {
    ref.socket!.simulateOpen()
    client.focus('sess-1')
    const received: unknown[] = []
    client.onEntry((e) => received.push(e))
    const entry = { id: 'e1', timestamp: 't', direction: 'response', payload: 'hi', harness: null, model: 'm', raw: '{}' }
    ref.socket!.simulateMessage({ type: 'entry', sessionId: 'other-session', entry })
    expect(received).toHaveLength(0)
  })

  it('delivers a lists event to onLists subscribers', () => {
    ref.socket!.simulateOpen()
    const received: unknown[] = []
    client.onLists((snap) => received.push(snap))
    ref.socket!.simulateMessage({ type: 'lists', tabs: [], recentSessions: [], archivedSessions: [], tabSessions: [] })
    expect(received).toHaveLength(1)
  })

  it('sets lastError on an error event from the server', () => {
    ref.socket!.simulateOpen()
    expect(client.lastError()).toBeNull()
    ref.socket!.simulateMessage({ type: 'error', code: 'invalid-op', message: 'bad focus' })
    expect(client.lastError()).toBe('invalid-op: bad focus')
  })

  it('ignores malformed (non-JSON) frames without closing or erroring', () => {
    ref.socket!.simulateOpen()
    client.focus('sess-1')
    const received: unknown[] = []
    client.onEntry((e) => received.push(e))
    ref.socket!.simulateMessage('not-json-at-all')
    expect(received).toHaveLength(0)
    expect(client.lastError()).toBeNull()
    // A subsequent well-formed frame still dispatches.
    const entry = { id: 'e1', timestamp: 't', direction: 'response', payload: 'hi', harness: null, model: 'm', raw: '{}' }
    ref.socket!.simulateMessage({ type: 'entry', sessionId: 'sess-1', entry })
    expect(received).toHaveLength(1)
  })

  it('reconnects with exponential backoff after an unclean close', () => {
    ref.socket!.simulateOpen()
    expect(ref.instances).toHaveLength(1)
    // Unclean close → reconnect.
    ref.socket!.simulateClose(1006, '', false)
    expect(client.status).toBe('reconnecting')
    // Advance fake timers past the first backoff slot (250ms base, jittered 125-250).
    vi.advanceTimersByTime(300)
    expect(ref.instances).toHaveLength(2)
    // The new socket starts CONNECTING; it goes live on open.
    ref.socket!.simulateOpen()
    expect(client.status).toBe('live')
  })

  it('does NOT reconnect after an explicit close()', () => {
    ref.socket!.simulateOpen()
    cleanup()
    expect(client.status).toBe('closed')
    vi.advanceTimersByTime(10000)
    expect(ref.instances).toHaveLength(1)
  })

  it('notifies status subscribers on transitions', () => {
    const statuses: string[] = []
    client.onStatusChange((s) => statuses.push(s))
    ref.socket!.simulateOpen()
    ref.socket!.simulateClose(1006, '', false)
    expect(statuses).toEqual(['live', 'reconnecting'])
  })
})