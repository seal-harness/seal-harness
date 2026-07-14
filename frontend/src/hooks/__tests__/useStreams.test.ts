import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useListsStream } from '../useListsStream'
import { useTranscriptStream, reconcileEntries } from '../useTranscriptStream'
import { useSessionActivityStream, applyActivity, clearUnread } from '../useSessionActivityStream'
import type { StreamClient, ListsSnapshot, ActivityEvent } from '../../types/stream'
import type { TranscriptEntry } from '../../types'

/** Build a fake StreamClient whose listeners we can drive from tests. */
function fakeClient(): StreamClient & {
  pushLists(s: ListsSnapshot): void
  pushEntry(e: TranscriptEntry): void
  pushActivity(sid: string, a: ActivityEvent): void
  pushAsk(sid: string, ask: { id: string; question: string }): void
  pushAskResolved(sid: string, ask: { id: string; resolution: string }): void
  setStatus(s: StreamClient['status']): void
  setError(e: string | null): void
} {
  const listsCbs = new Set<(s: ListsSnapshot) => void>()
  const entryCbs = new Set<(e: TranscriptEntry) => void>()
  const activityCbs = new Set<(sid: string, a: ActivityEvent) => void>()
  const statusCbs = new Set<(s: StreamClient['status']) => void>()
  const askCbs = new Set<(sid: string, ask: { id: string; question: string }) => void>()
  const askResolvedCbs = new Set<(sid: string, ask: { id: string; resolution: string }) => void>()
  let lastError: string | null = null
  return {
    status: 'live' as StreamClient['status'],
    focus: () => {},
    onEntry: (cb) => { entryCbs.add(cb); return () => { entryCbs.delete(cb) } },
    onActivity: (cb) => { activityCbs.add(cb); return () => { activityCbs.delete(cb) } },
    onLists: (cb) => { listsCbs.add(cb); return () => { listsCbs.delete(cb) } },
    onStatusChange: (cb) => { statusCbs.add(cb); return () => { statusCbs.delete(cb) } },
    onAsk: (cb) => { askCbs.add(cb); return () => { askCbs.delete(cb) } },
    onAskResolved: (cb) => { askResolvedCbs.add(cb); return () => { askResolvedCbs.delete(cb) } },
    lastError: () => lastError,
    // test drivers:
    pushLists: (s) => { for (const cb of listsCbs) cb(s) },
    pushEntry: (e) => { for (const cb of entryCbs) cb(e) },
    pushActivity: (sid, a) => { for (const cb of activityCbs) cb(sid, a) },
    pushAsk: (sid, ask) => { for (const cb of askCbs) cb(sid, ask) },
    pushAskResolved: (sid, ask) => { for (const cb of askResolvedCbs) cb(sid, ask) },
    setStatus: (s) => { for (const cb of statusCbs) cb(s); },
    setError: (e) => { lastError = e },
  } as StreamClient & {
    pushLists: (s: ListsSnapshot) => void
    pushEntry: (e: TranscriptEntry) => void
    pushActivity: (sid: string, a: ActivityEvent) => void
    pushAsk: (sid: string, ask: { id: string; question: string }) => void
    pushAskResolved: (sid: string, ask: { id: string; resolution: string }) => void
    setStatus: (s: StreamClient['status']) => void
    setError: (e: string | null) => void
  }
}

function makeEntry(id: string, ts: string, payload = 'hi'): TranscriptEntry {
  return { id, timestamp: ts, direction: 'response', payload, harness: null, model: 'm', raw: '{}' }
}

// ── useListsStream ───────────────────────────────────────────────────────

describe('useListsStream', () => {
  it('populates tabs + sessions from a lists snapshot', () => {
    const c = fakeClient()
    const { result } = renderHook(() => useListsStream(c))
    act(() => {
      c.pushLists({
        tabs: [{ index: 0, kind: 'session:anthropic', label: null, status: 'running', session_id: 's1' }],
        recentSessions: [{ id: 's2', agent: null, runtime: 'r', model: 'm', lastActive: 't', createdAt: 't', description: null, autoSummary: null, firstMessageSnippet: null, channel: null, channelUserId: null }],
        archivedSessions: [],
        tabSessions: [],
      })
    })
    expect(result.current.tabs).toHaveLength(1)
    expect(result.current.tabs[0]!.index).toBe(0)
    expect(result.current.recentSessions).toHaveLength(1)
    expect(result.current.recentSessions[0]!.id).toBe('s2')
  })

  it('maps snake_case tab wire fields to camelCase TabInfo', () => {
    const c = fakeClient()
    const { result } = renderHook(() => useListsStream(c))
    act(() => {
      c.pushLists({
        tabs: [{ index: 0, kind: 'harness', label: 'win', status: 'exited', session_id: null, ext_modified: true, stale: false, origin: 'adopted', attach_command: 'tmux attach -t w' }],
        recentSessions: [], archivedSessions: [], tabSessions: [],
      })
    })
    const t = result.current.tabs[0]!
    expect(t.extModified).toBe(true)
    expect(t.origin).toBe('adopted')
    expect(t.attachCommand).toBe('tmux attach -t w')
  })
})

// ── useTranscriptStream ─────────────────────────────────────────────────

describe('reconcileEntries', () => {
  const e1 = makeEntry('e1', '2026-01-01T00:00:00Z')
  const e2 = makeEntry('e2', '2026-01-01T00:00:01Z')

  it('inserts a new entry at the sorted position (ascending by timestamp)', () => {
    expect(reconcileEntries([e2], e1)).toEqual([e1, e2])
    expect(reconcileEntries([e1], e2)).toEqual([e1, e2])
  })

  it('replaces an existing entry with a matching id in place', () => {
    const e1Update = { ...e1, payload: 'updated' }
    const result = reconcileEntries([e1, e2], e1Update)
    expect(result).toHaveLength(2)
    expect(result[0]!.payload).toBe('updated')
    expect(result[1]).toBe(e2)
  })

  it('appends to an empty list', () => {
    expect(reconcileEntries([], e1)).toEqual([e1])
  })
})

describe('useTranscriptStream', () => {
  it('returns empty entries when sessionId is null', () => {
    const c = fakeClient()
    const { result } = renderHook(() => useTranscriptStream(null, c))
    expect(result.current.entries).toEqual([])
  })

  it('streams entries for the focused session via onEntry', async () => {
    const c = fakeClient()
    // Stub fetch for the seed.
    vi.stubGlobal('fetch', vi.fn(async () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } })))
    const { result } = renderHook(() => useTranscriptStream('s1', c))
    // Let the seed fetch resolve first (so it doesn't overwrite the WS entry).
    await act(async () => { await Promise.resolve() })
    // Push a WS entry.
    await act(async () => {
      c.pushEntry(makeEntry('e1', '2026-01-01T00:00:00Z'))
    })
    expect(result.current.entries).toHaveLength(1)
    expect(result.current.entries[0]!.id).toBe('e1')
    vi.unstubAllGlobals()
  })
})

// ── useSessionActivityStream ────────────────────────────────────────────

describe('applyActivity', () => {
  it('increments unread + sets lastEntryAt on entry-at', () => {
    const result = applyActivity({}, 's1', { kind: 'entry-at', timestamp: 't1' })
    expect(result['s1']!.unread).toBe(1)
    expect(result['s1']!.lastEntryAt).toBe('t1')
  })

  it('sets harness on harness-status', () => {
    const result = applyActivity({}, 's1', { kind: 'harness-status', status: 'thinking' })
    expect(result['s1']!.harness).toBe('thinking')
  })

  it('is a no-op when harness-status carries the same value', () => {
    const before = { s1: { harness: 'idle' as const, unread: 0, lastEntryAt: null } }
    const result = applyActivity(before, 's1', { kind: 'harness-status', status: 'idle' })
    expect(result).toBe(before)
  })

  it('seeds a default state on session-created only when the session is new', () => {
    const result = applyActivity({}, 's1', { kind: 'session-created', session: { id: 's1', runtime: 'r', model: 'm', channel: 'cli', created_at: 't', last_active: 't' } })
    expect(result['s1']).toBeDefined()
    expect(result['s1']!.unread).toBe(0)
    // Second time → no-op.
    const result2 = applyActivity(result, 's1', { kind: 'session-created', session: { id: 's1', runtime: 'r', model: 'm', channel: 'cli', created_at: 't', last_active: 't' } })
    expect(result2).toBe(result)
  })
})

describe('clearUnread', () => {
  it('zeros the unread counter for a session', () => {
    const before = { s1: { harness: null, unread: 5, lastEntryAt: 't' } }
    const result = clearUnread(before, 's1')
    expect(result['s1']!.unread).toBe(0)
  })

  it('is a no-op when unread is already 0 or the session is unknown', () => {
    const before = { s1: { harness: null, unread: 0, lastEntryAt: null } }
    expect(clearUnread(before, 's1')).toBe(before)
    expect(clearUnread(before, 'unknown')).toBe(before)
  })
})

describe('useSessionActivityStream', () => {
  it('tracks per-session activity and clears unread for the focused session', async () => {
    const c = fakeClient()
    const { result, rerender } = renderHook(({ sid }: { sid: string | null }) => useSessionActivityStream(sid, c), { initialProps: { sid: null as string | null } })
    // An entry arrives for s1 while no session is focused → unread=1.
    await act(async () => { c.pushActivity('s1', { kind: 'entry-at', timestamp: 't1' }) })
    expect(result.current.sessions['s1']!.unread).toBe(1)
    // Now focus s1 → unread clears.
    rerender({ sid: 's1' })
    expect(result.current.sessions['s1']!.unread).toBe(0)
    // Another entry arrives for s1 while focused → unread stays 0.
    await act(async () => { c.pushActivity('s1', { kind: 'entry-at', timestamp: 't2' }) })
    expect(result.current.sessions['s1']!.unread).toBe(0)
    expect(result.current.sessions['s1']!.lastEntryAt).toBe('t2')
  })
})