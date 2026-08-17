import { describe, it, expect } from 'vitest'
import { deriveTabStatusKind, tabSortTimestamp, compareTabs, sortTabsForSidebar, formatAge } from '../tabStatus'
import type { SessionInfo, TabInfo } from '../../types'
import type { SessionActivityState } from '../../types/stream'

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's1',
    agent: null,
    runtime: 'session:provider',
    model: '',
    lastActive: '2024-01-01T00:00:00.000Z',
    createdAt: '2024-01-01T00:00:00.000Z',
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    lastUserMessageAt: null, repoId: null,
    ...overrides,
  }
}

function makeTab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    index: 0,
    kind: 'session:provider',
    label: null,
    status: 'idle',
    session_id: 's1',
    ...overrides,
  }
}

function activity(overrides: Partial<SessionActivityState> = {}): SessionActivityState {
  return { harness: null, unread: 0, lastEntryAt: null, seenAt: null, ...overrides }
}

// ── deriveTabStatusKind ────────────────────────────────────────────────

describe('deriveTabStatusKind', () => {
  it('returns thinking when harness is thinking', () => {
    expect(deriveTabStatusKind(activity({ harness: 'thinking' }))).toBe('thinking')
  })

  it('returns idle-read when there is no lastEntryAt (no activity / no entries)', () => {
    expect(deriveTabStatusKind(undefined)).toBe('idle-read')
    expect(deriveTabStatusKind(activity())).toBe('idle-read')
  })

  it('returns idle-unread when lastEntryAt is newer than seenAt', () => {
    expect(deriveTabStatusKind(activity({
      lastEntryAt: '2024-06-02T00:00:00.000Z',
      seenAt: '2024-06-01T00:00:00.000Z',
    }))).toBe('idle-unread')
  })

  it('returns idle-read when seenAt is at-or-after lastEntryAt', () => {
    expect(deriveTabStatusKind(activity({
      lastEntryAt: '2024-06-01T00:00:00.000Z',
      seenAt: '2024-06-01T00:00:00.000Z',
    }))).toBe('idle-read')
    expect(deriveTabStatusKind(activity({
      lastEntryAt: '2024-06-01T00:00:00.000Z',
      seenAt: '2024-06-02T00:00:00.000Z',
    }))).toBe('idle-read')
  })

  it('returns idle-unread when lastEntryAt exists but seenAt is null (never seen)', () => {
    expect(deriveTabStatusKind(activity({
      lastEntryAt: '2024-06-01T00:00:00.000Z',
      seenAt: null,
    }))).toBe('idle-unread')
  })

  it('treats thinking as taking precedence over unread evidence', () => {
    expect(deriveTabStatusKind(activity({
      harness: 'thinking',
      lastEntryAt: '2024-06-02T00:00:00.000Z',
      seenAt: '2024-06-01T00:00:00.000Z',
    }))).toBe('thinking')
  })
})

// ── tabSortTimestamp ───────────────────────────────────────────────────

describe('tabSortTimestamp', () => {
  it('uses lastUserMessageAt when present', () => {
    expect(tabSortTimestamp(makeSession({ lastUserMessageAt: '2024-06-05T00:00:00.000Z' })))
      .toBe(Date.parse('2024-06-05T00:00:00.000Z'))
  })

  it('falls back to lastActive when lastUserMessageAt is null', () => {
    expect(tabSortTimestamp(makeSession({ lastActive: '2024-06-03T00:00:00.000Z', lastUserMessageAt: null })))
      .toBe(Date.parse('2024-06-03T00:00:00.000Z'))
  })

  it('falls back to createdAt when both lastUserMessageAt and lastActive are null', () => {
    expect(tabSortTimestamp(makeSession({ lastActive: null as never, createdAt: '2024-01-01T00:00:00.000Z', lastUserMessageAt: null })))
      .toBe(Date.parse('2024-01-01T00:00:00.000Z'))
  })

  it('returns 0 when session is missing entirely', () => {
    expect(tabSortTimestamp(null)).toBe(0)
    expect(tabSortTimestamp(undefined)).toBe(0)
  })

  it('returns 0 on a malformed timestamp (defensive)', () => {
    expect(tabSortTimestamp(makeSession({ lastUserMessageAt: 'not-a-date' }))).toBe(0)
  })
})

// ── compareTabs / sortTabsForSidebar ───────────────────────────────────

describe('sortTabsForSidebar', () => {
  it('orders buckets: idle-unread → idle-read → thinking', () => {
    const unreadTab = makeTab({ index: 1, session_id: 'unread' })
    const readTab = makeTab({ index: 2, session_id: 'read' })
    const thinkingTab = makeTab({ index: 3, session_id: 'thinking' })
    const result = sortTabsForSidebar([
      { tab: thinkingTab, session: makeSession({ id: 'thinking' }), activity: activity({ harness: 'thinking' }) },
      { tab: readTab,     session: makeSession({ id: 'read' }),     activity: activity({ lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z' }) },
      { tab: unreadTab,   session: makeSession({ id: 'unread' }),   activity: activity({ lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z' }) },
    ])
    expect(result.map((t) => t.index)).toEqual([1, 2, 3])
  })

  it('within a bucket, sorts oldest last-user-message first', () => {
    const oldTab = makeTab({ index: 1, session_id: 'old' })
    const midTab = makeTab({ index: 2, session_id: 'mid' })
    const newTab = makeTab({ index: 3, session_id: 'new' })
    // All three idle-read.
    const readActivity = activity({ lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z' })
    const result = sortTabsForSidebar([
      { tab: newTab, session: makeSession({ id: 'new', lastUserMessageAt: '2024-06-05T00:00:00.000Z' }), activity: readActivity },
      { tab: oldTab, session: makeSession({ id: 'old', lastUserMessageAt: '2024-06-01T00:00:00.000Z' }), activity: readActivity },
      { tab: midTab, session: makeSession({ id: 'mid', lastUserMessageAt: '2024-06-03T00:00:00.000Z' }), activity: readActivity },
    ])
    expect(result.map((t) => t.index)).toEqual([1, 2, 3])
  })

  it('preserves source order on full ties (stable)', () => {
    const a = makeTab({ index: 1, session_id: 'a' })
    const b = makeTab({ index: 2, session_id: 'b' })
    // Same bucket (idle-read), same sort timestamp.
    const sess = makeSession({ lastUserMessageAt: '2024-06-01T00:00:00.000Z' })
    const readActivity = activity({ lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z' })
    const result = sortTabsForSidebar([
      { tab: a, session: sess, activity: readActivity },
      { tab: b, session: sess, activity: readActivity },
    ])
    expect(result.map((t) => t.index)).toEqual([1, 2])
  })

  it('does not mutate the input array', () => {
    const input = [
      { tab: makeTab({ index: 2, session_id: 'b' }), session: makeSession({ id: 'b' }), activity: activity({ harness: 'thinking' }) },
      { tab: makeTab({ index: 1, session_id: 'a' }), session: makeSession({ id: 'a' }), activity: activity() },
    ]
    const snapshot = input.map((e) => e.tab.index)
    sortTabsForSidebar(input)
    expect(input.map((e) => e.tab.index)).toEqual(snapshot)
  })
})

// ── formatAge ─────────────────────────────────────────────────────────

describe('formatAge', () => {
  it('returns "now" for a timestamp within the last minute', () => {
    expect(formatAge(new Date().toISOString())).toBe('now')
  })

  it('returns "Nm" for minutes under an hour', () => {
    const fiveMinAgo = new Date(Date.now() - 5 * 60000).toISOString()
    expect(formatAge(fiveMinAgo)).toBe('5m')
  })

  it('returns "Nh" for hours under a day', () => {
    const threeHourAgo = new Date(Date.now() - 3 * 3600000).toISOString()
    expect(formatAge(threeHourAgo)).toBe('3h')
  })

  it('returns "Nd" for days', () => {
    const twoDaysAgo = new Date(Date.now() - 2 * 86400000).toISOString()
    expect(formatAge(twoDaysAgo)).toBe('2d')
  })

  it('returns "" for a missing or unparseable timestamp', () => {
    expect(formatAge(null)).toBe('')
    expect(formatAge(undefined)).toBe('')
    expect(formatAge('')).toBe('')
    expect(formatAge('not-a-date')).toBe('')
  })
})

// ── compareTabs (direct) ───────────────────────────────────────────────

describe('compareTabs', () => {
  it('returns negative when a sorts before b', () => {
    const a = { tab: makeTab({ index: 1 }), session: makeSession(), activity: activity({ lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z' }) }
    const b = { tab: makeTab({ index: 2 }), session: makeSession(), activity: activity({ harness: 'thinking' }) }
    expect(compareTabs(a, b)).toBeLessThan(0)
  })
})