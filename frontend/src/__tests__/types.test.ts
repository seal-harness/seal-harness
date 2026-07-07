import { describe, it, expect } from 'vitest'
import type { SessionInfo, TabInfo } from '../types'
import {
  sessionDisplayTitle,
  shortenModel,
  sessionSubtitle,
  tabDisplayLabel,
  findSession,
} from '../types'

/** Build a fully-populated SessionInfo with sensible nulls, overridable. */
function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's-1',
    agent: null,
    runtime: 'session:provider',
    model: '',
    lastActive: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    ...overrides,
  }
}

/** A session-backed tab whose `session_id` matches the given session. The tab's
 *  own `label` is deliberately set to a DIFFERENT string so the test proves the
 *  rendered label comes from the session (via the join), not the tab field. */
function tabFor(session: SessionInfo): TabInfo {
  return {
    index: 0,
    kind: 'session:provider',
    label: 'STALE-TAB-LABEL-SHOULD-NEVER-WIN',
    status: 'idle',
    session_id: session.id,
  }
}

describe('sessionDisplayTitle', () => {
  it('uses the user-set description first', () => {
    expect(sessionDisplayTitle(makeSession({ description: 'Custom' }))).toBe('Custom')
  })

  it('falls back to autoSummary when no description', () => {
    expect(sessionDisplayTitle(makeSession({ autoSummary: 'summary' }))).toBe('summary')
  })

  it('falls back to firstMessageSnippet when no description/summary', () => {
    expect(sessionDisplayTitle(makeSession({ firstMessageSnippet: 'do the thing' }))).toBe('do the thing')
  })

  it('falls back to agent name when no description/summary/snippet', () => {
    expect(sessionDisplayTitle(makeSession({ agent: 'agent-arm' }))).toBe('agent-arm')
  })

  it('falls back to id prefix when nothing else', () => {
    expect(sessionDisplayTitle(makeSession({ id: 'abcdef1234567890' }))).toBe('abcdef123456')
  })

  it('falls back to "New session" when id is empty', () => {
    expect(sessionDisplayTitle(makeSession({ id: '' }))).toBe('New session')
  })
})

describe('shortenModel', () => {
  it('strips the anthropic date suffix and family prefix', () => {
    expect(shortenModel('claude-sonnet-4-20250514')).toBe('sonnet-4')
  })

  it('passes through unknown model ids unchanged', () => {
    expect(shortenModel('llama3')).toBe('llama3')
    expect(shortenModel('gpt-4o')).toBe('gpt-4o')
  })
})

describe('sessionSubtitle', () => {
  it('formats "agent · channel:userId" with the middle dot', () => {
    expect(sessionSubtitle({ agent: 'dev', channel: 'signal', channelUserId: '+1555' })).toBe('dev · signal:+1555')
  })

  it('shows just the agent when no channel user id', () => {
    expect(sessionSubtitle({ agent: 'dev', channel: 'cli', channelUserId: null })).toBe('dev')
  })

  it('shows just the channel:userId when no agent', () => {
    expect(sessionSubtitle({ agent: null, channel: 'signal', channelUserId: '+1555' })).toBe('signal:+1555')
  })

  it('returns empty string when both absent', () => {
    expect(sessionSubtitle({ agent: null, channel: null, channelUserId: null })).toBe('')
  })
})

describe('tabDisplayLabel', () => {
  it('resolves via the backing session, not the tab.label', () => {
    const s = makeSession({ description: 'session-title' })
    const t = tabFor(s)
    expect(tabDisplayLabel(t, s)).toBe('session-title')
    expect(tabDisplayLabel(t, s)).not.toBe(t.label)
  })

  it('falls back to tab.label when no session resolves', () => {
    const t: TabInfo = { index: 0, kind: 'harness', label: 'harness-label', status: 'idle', session_id: null }
    expect(tabDisplayLabel(t, null)).toBe('harness-label')
    expect(tabDisplayLabel(t, undefined)).toBe('harness-label')
  })

  it('falls back to ellipsis when no session and no label', () => {
    const t: TabInfo = { index: 0, kind: 'harness', label: null, status: 'idle', session_id: null }
    expect(tabDisplayLabel(t, null)).toBe('…')
  })
})

describe('findSession', () => {
  const a = makeSession({ id: 'a' })
  const b = makeSession({ id: 'b' })
  const c = makeSession({ id: 'c' })

  it('finds a session in the recents list', () => {
    expect(findSession('a', [a, b], [c], [])?.id).toBe('a')
  })

  it('finds a session in the archived list', () => {
    expect(findSession('c', [a, b], [c], [])?.id).toBe('c')
  })

  it('finds a session in the tabSessions list', () => {
    expect(findSession('c', [a, b], [], [c])?.id).toBe('c')
  })

  it('returns undefined for a null id', () => {
    expect(findSession(null, [a, b], [c], [])).toBeUndefined()
  })

  it('returns undefined for an unknown id', () => {
    expect(findSession('zzz', [a, b], [c], [])).toBeUndefined()
  })
})