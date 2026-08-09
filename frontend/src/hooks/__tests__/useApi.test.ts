import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

// Mock the WS singleton so hooks that subscribe to invalidation frames
// (useAgentDefs/useSkills/useRepos) never attempt a real WS connection,
// AND so the useRepos WS test can capture + invoke the repos-changed
// callback. The factory returns a SINGLE stable client (the hooks use
// `streamClient()` as a dep — a fresh object each call would re-trigger
// their effects every render and loop). The per-frame listener sets let
// a test fire a synthetic invalidation.
const reposChangedCbs = new Set<() => void>()
vi.mock('../../lib/streamClient', () => {
  const unsub = () => {}
  const client = {
    status: 'closed' as const,
    focus: () => {},
    onEntry: () => unsub,
    onActivity: () => unsub,
    onLists: () => unsub,
    onStatusChange: () => unsub,
    onAsk: () => unsub,
    onAskResolved: () => unsub,
    onAgentDefsChanged: () => unsub,
    onSkillsChanged: () => unsub,
    onReposChanged: (cb: () => void) => {
      reposChangedCbs.add(cb)
      return () => { reposChangedCbs.delete(cb) }
    },
    lastError: () => null,
  }
  return { streamClient: () => client }
})

import {
  useHarnesses,
  useRecentSessions,
  useTabs,
  useArchivedSessions,
  useListsPoll,
  useDiscoverableWindows,
  useTranscript,
  useSendMessage,
  useAgents,
  useSessionAgents,
  fetchSessionAgents,
  useConfiguredProviders,
  setSessionDescription,
  setSessionArchived,
  setSessionPrompt,
  createTab,
  closeTab,
  dismissTab,
  acknowledgeTab,
  releaseHarness,
  destroyHarness,
  adoptWindow,
  fetchProviderModels,
  fetchModelContext,
} from '../useApi'
import type { TabInfoWire } from '../useApi'
import { POLL_INTERVAL } from '../useApi'

/** Capture fetch calls so each test can assert the URL + method + body. */
type FetchCall = { url: string; init?: RequestInit }
const fetchCalls: FetchCall[] = []
let nextResponse: Response = new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } })

beforeEach(() => {
  fetchCalls.length = 0
  reposChangedCbs.clear()
  nextResponse = new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    fetchCalls.push({ url, init })
    return nextResponse
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

function setNextResponse(body: unknown, status = 200): void {
  nextResponse = new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

describe('useHarnesses', () => {
  it('fetches GET /api/harnesses on mount and populates state', async () => {
    setNextResponse([{ name: 'claude-code', activity: 'idle' }])
    const { result } = renderHook(() => useHarnesses())
    await waitFor(() => expect(result.current.harnesses).toHaveLength(1))
    expect(result.current.harnesses[0]!.name).toBe('claude-code')
    expect(fetchCalls.some((c) => c.url === '/api/harnesses' && (c.init?.method ?? 'GET') === 'GET')).toBe(true)
  })

  it('sets error=true when the fetch fails', async () => {
    setNextResponse('err', 500)
    const { result } = renderHook(() => useHarnesses())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

describe('useRecentSessions', () => {
  it('fetches GET /api/sessions on mount', async () => {
    setNextResponse([{ id: 's1', agent: null, runtime: 'session:anthropic', model: 'm', lastActive: 't', createdAt: 't', description: null, autoSummary: null, firstMessageSnippet: null, channel: 'cli', channelUserId: null, lastUserMessageAt: null }])
    const { result } = renderHook(() => useRecentSessions())
    await waitFor(() => expect(result.current.sessions).toHaveLength(1))
    expect(result.current.sessions[0]!.id).toBe('s1')
  })
})

describe('useTabs', () => {
  it('fetches GET /api/tabs and maps snake_case wire → TabInfo', async () => {
    const wire: TabInfoWire = { index: 0, kind: 'session:anthropic', label: null, status: 'running', session_id: 's1', ext_modified: false, stale: false, origin: 'spawned', attach_command: null }
    setNextResponse([wire])
    const { result } = renderHook(() => useTabs())
    await waitFor(() => expect(result.current.tabs).toHaveLength(1))
    const t = result.current.tabs[0]!
    expect(t.index).toBe(0)
    expect(t.status).toBe('running')
    expect(t.origin).toBe('spawned')
    expect(t.extModified).toBe(false)
    expect(t.attachCommand).toBeNull()
  })
})

describe('useArchivedSessions', () => {
  it('fetches GET /api/sessions/archived on mount', async () => {
    setNextResponse([{ id: 'old', agent: null, runtime: 'session:anthropic', model: 'm', lastActive: 't', createdAt: 't', description: 'old', autoSummary: null, firstMessageSnippet: null, channel: 'signal', channelUserId: '+1' }])
    const { result } = renderHook(() => useArchivedSessions())
    await waitFor(() => expect(result.current.sessions).toHaveLength(1))
    expect(result.current.sessions[0]!.id).toBe('old')
  })
})

describe('useListsPoll', () => {
  it('fetches GET /api/lists on mount and returns the four arrays + error=false', async () => {
    const wire: TabInfoWire = { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 's1', ext_modified: false, stale: false, origin: undefined, attach_command: null }
    const sess = { id: 's2', agent: null, runtime: 'session:anthropic', model: 'm', lastActive: 't', createdAt: 't', description: null, autoSummary: null, firstMessageSnippet: null, channel: 'cli', channelUserId: null, lastUserMessageAt: null }
    setNextResponse({ tabs: [wire], recentSessions: [sess], archivedSessions: [], tabSessions: [] })
    const { result } = renderHook(() => useListsPoll())
    await waitFor(() => expect(result.current.tabs).toHaveLength(1))
    expect(result.current.tabs[0]!.index).toBe(0)
    expect(result.current.recentSessions).toHaveLength(1)
    expect(result.current.recentSessions[0]!.id).toBe('s2')
    expect(result.current.archivedSessions).toHaveLength(0)
    expect(result.current.tabSessions).toHaveLength(0)
    expect(result.current.error).toBe(false)
    expect(fetchCalls.some((c) => c.url === '/api/lists' && (c.init?.method ?? 'GET') === 'GET')).toBe(true)
  })

  it('maps TabInfoWire[] to TabInfo[] via mapTabInfo', async () => {
    const wire: TabInfoWire = { index: 1, kind: 'session:provider', label: 'work', status: 'running', session_id: 's9', ext_modified: true, stale: false, origin: 'spawned', attach_command: 'tmux attach -t 1' }
    setNextResponse({ tabs: [wire], recentSessions: [], archivedSessions: [], tabSessions: [] })
    const { result } = renderHook(() => useListsPoll())
    await waitFor(() => expect(result.current.tabs).toHaveLength(1))
    const t = result.current.tabs[0]!
    expect(t.index).toBe(1)
    expect(t.kind).toBe('session:provider')
    expect(t.label).toBe('work')
    expect(t.status).toBe('running')
    expect(t.session_id).toBe('s9')
    expect(t.extModified).toBe(true)
    expect(t.origin).toBe('spawned')
    expect(t.attachCommand).toBe('tmux attach -t 1')
  })

  it('on 404, sets error=true', async () => {
    setNextResponse('not found', 404)
    const { result } = renderHook(() => useListsPoll())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

describe('disabled polling hooks', () => {
  it('useListsPoll(disabled=true) does NOT fetch on mount', async () => {
    vi.useFakeTimers()
    setNextResponse({ tabs: [], recentSessions: [], archivedSessions: [], tabSessions: [] })
    renderHook(() => useListsPoll(true))
    // Advance past the poll interval — no fetch should fire.
    act(() => { vi.advanceTimersByTime(POLL_INTERVAL * 3) })
    expect(fetchCalls.filter((c) => c.url === '/api/lists')).toHaveLength(0)
    vi.useRealTimers()
  })

  it('useTabs(disabled=true) does NOT fetch on mount', async () => {
    vi.useFakeTimers()
    renderHook(() => useTabs(true))
    act(() => { vi.advanceTimersByTime(POLL_INTERVAL * 3) })
    expect(fetchCalls.filter((c) => c.url === '/api/tabs')).toHaveLength(0)
    vi.useRealTimers()
  })

  it('useRecentSessions(disabled=true) does NOT fetch on mount', async () => {
    vi.useFakeTimers()
    renderHook(() => useRecentSessions(true))
    act(() => { vi.advanceTimersByTime(POLL_INTERVAL * 3) })
    expect(fetchCalls.filter((c) => c.url === '/api/sessions')).toHaveLength(0)
    vi.useRealTimers()
  })

  it('useArchivedSessions(disabled=true) does NOT fetch on mount', async () => {
    vi.useFakeTimers()
    renderHook(() => useArchivedSessions(true))
    act(() => { vi.advanceTimersByTime(POLL_INTERVAL * 3) })
    expect(fetchCalls.filter((c) => c.url === '/api/sessions/archived')).toHaveLength(0)
    vi.useRealTimers()
  })

  it('useTabs(disabled=true) starts polling when re-rendered with disabled=false', async () => {
    const { rerender } = renderHook(({ d }: { d: boolean }) => useTabs(d), { initialProps: { d: true } })
    // No fetch while disabled
    expect(fetchCalls.filter((c) => c.url === '/api/tabs')).toHaveLength(0)
    const wire: TabInfoWire = { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 's1', ext_modified: false, stale: false, origin: undefined, attach_command: null }
    setNextResponse([wire])
    rerender({ d: false })
    await waitFor(() => expect(fetchCalls.filter((c) => c.url === '/api/tabs').length).toBeGreaterThan(0))
  })
})

describe('useDiscoverableWindows', () => {
  it('does NOT poll; scan() POSTs /api/harnesses/discover and maps the wire rows', async () => {
    setNextResponse([{ session: 's', window_name: 'win', window_index: 2, pane_pid: 123 }])
    const { result } = renderHook(() => useDiscoverableWindows())
    // No fetch on mount.
    expect(fetchCalls).toHaveLength(0)
    await act(async () => { await result.current.scan() })
    expect(fetchCalls.some((c) => c.url === '/api/harnesses/discover')).toBe(true)
    expect(result.current.windows).toHaveLength(1)
    expect(result.current.windows[0]!.windowName).toBe('win')
    expect(result.current.windows[0]!.windowIndex).toBe(2)
  })
})

describe('useTranscript', () => {
  it('fetches GET /api/sessions/:id/transcript when sessionId is set', async () => {
    setNextResponse([{ id: 'e1', timestamp: 't', direction: 'response', payload: 'hi', harness: null, model: 'm', channel: null, raw: '{}' }])
    const { result } = renderHook(() => useTranscript('s1'))
    await waitFor(() => expect(result.current.entries).toHaveLength(1))
    expect(fetchCalls.some((c) => c.url === '/api/sessions/s1/transcript')).toBe(true)
  })

  it('returns empty entries when sessionId is null', async () => {
    const { result } = renderHook(() => useTranscript(null))
    expect(result.current.entries).toEqual([])
    expect(fetchCalls).toHaveLength(0)
  })
})

describe('useSendMessage', () => {
  it('POSTs /api/sessions/:id/send with {message, model?} and returns the parsed body', async () => {
    setNextResponse({ kind: 'slash', response: '/help text' })
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('s1', onComplete))
    let res: { kind: string; response: string } | null = null
    await act(async () => { res = await result.current.send('/help') })
    expect(res).toEqual({ kind: 'slash', response: '/help text' })
    expect(fetchCalls.some((c) => c.url === '/api/sessions/s1/send')).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/sessions/s1/send')!
    expect(JSON.parse(call.init!.body as string)).toEqual({ message: '/help' })
    expect(onComplete).toHaveBeenCalled()
  })

  it('includes model in the body when provided', async () => {
    setNextResponse({ kind: 'assistant', response: '' })
    const { result } = renderHook(() => useSendMessage('s1', () => {}))
    await act(async () => { await result.current.send('hi', 'claude-sonnet-4') })
    const call = fetchCalls.find((c) => c.url === '/api/sessions/s1/send')!
    expect(JSON.parse(call.init!.body as string)).toEqual({ message: 'hi', model: 'claude-sonnet-4' })
  })

  it('returns null when sessionId is null', async () => {
    const { result } = renderHook(() => useSendMessage(null, () => {}))
    let res: unknown = 'uninit'
    await act(async () => { res = await result.current.send('hi') })
    expect(res).toBeNull()
  })

  it('resets sending to false when sessionId changes (no stale thinking indicator on the new tab)', async () => {
    // Simulate a slow POST /send that never resolves while the user switches
    // to a different session. The `sending` flag must reset so the idle tab
    // does not show a thinking indicator (the activity stream's harness state
    // drives the indicator for the original still-thinking session).
    let resolveSend: ((v: { kind: string }) => void) | null = null
    vi.stubGlobal('fetch', vi.fn((url: string) => {
      fetchCalls.push({ url })
      return new Promise<Response>((resolve) => {
        resolveSend = (v: { kind: string }) => resolve(new Response(JSON.stringify(v), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        }))
      })
    }))
    const { result, rerender } = renderHook(
      ({ sid }: { sid: string | null }) => useSendMessage(sid, () => {}),
      { initialProps: { sid: 's1' as string | null } },
    )
    // Kick off a send on s1 — the POST stays in flight (never resolves).
    await act(async () => { void result.current.send('hi') })
    await act(async () => { await Promise.resolve() })
    expect(result.current.sending).toBe(true)
    // Switch focus to s2 (an idle tab) → sending must reset to false.
    rerender({ sid: 's2' })
    expect(result.current.sending).toBe(false)
    // Resolve the in-flight POST so the test does not leak a pending promise.
    const rs = resolveSend as ((v: { kind: string }) => void) | null
    if (rs !== null) rs({ kind: 'assistant' })
  })
})

describe('session mutators', () => {
  it('setSessionDescription PUTs /api/sessions/:id/description with {description}', async () => {
    setNextResponse('{}')
    const ok = await setSessionDescription('s1', 'new desc')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/sessions/s1/description')!
    expect(call.init!.method).toBe('PUT')
    expect(JSON.parse(call.init!.body as string)).toEqual({ description: 'new desc' })
  })

  it('setSessionArchived PUTs /api/sessions/:id/archived with {archived: bool}', async () => {
    setNextResponse('{}')
    const ok = await setSessionArchived('s1', true)
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/sessions/s1/archived')!
    expect(call.init!.method).toBe('PUT')
    expect(JSON.parse(call.init!.body as string)).toEqual({ archived: true })
  })

  it('setSessionPrompt PUTs /api/sessions/:id/prompt with {prompt}', async () => {
    setNextResponse('{}')
    const ok = await setSessionPrompt('s1', 'be concise')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/sessions/s1/prompt')!
    expect(call.init!.method).toBe('PUT')
    expect(JSON.parse(call.init!.body as string)).toEqual({ prompt: 'be concise' })
  })
})

describe('tab mutators', () => {
  it('createTab POSTs /api/tabs/new with the flat {kind, provider?, model?, agent?} body', async () => {
    setNextResponse({ tab_index: 0, session_id: 's1', kind: 'session:anthropic' })
    const res = await createTab({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4' })
    expect(res).toEqual({ tab_index: 0, session_id: 's1', kind: 'session:anthropic' })
    const call = fetchCalls.find((c) => c.url === '/api/tabs/new')!
    expect(call.init!.method).toBe('POST')
    expect(JSON.parse(call.init!.body as string)).toEqual({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4' })
  })

  it('createTab includes branch_from when provided', async () => {
    setNextResponse({ tab_index: 1, session_id: 's2', kind: 'session:anthropic' })
    await createTab({ kind: 'provider', provider: 'anthropic', branch_from: 's1' })
    const call = fetchCalls.find((c) => c.url === '/api/tabs/new')!
    expect(JSON.parse(call.init!.body as string)).toEqual({ kind: 'provider', provider: 'anthropic', branch_from: 's1' })
  })

  it('closeTab POSTs /api/tabs/:index/close', async () => {
    setNextResponse('{}')
    const ok = await closeTab(2)
    expect(ok).toBe(true)
    expect(fetchCalls.some((c) => c.url === '/api/tabs/2/close' && c.init!.method === 'POST')).toBe(true)
  })

  it('dismissTab POSTs /api/tabs/:index/dismiss', async () => {
    setNextResponse('{}')
    await dismissTab(2)
    expect(fetchCalls.some((c) => c.url === '/api/tabs/2/dismiss' && c.init!.method === 'POST')).toBe(true)
  })

  it('acknowledgeTab POSTs /api/tabs/:index/acknowledge', async () => {
    setNextResponse('{}')
    await acknowledgeTab(2)
    expect(fetchCalls.some((c) => c.url === '/api/tabs/2/acknowledge' && c.init!.method === 'POST')).toBe(true)
  })

  it('releaseHarness POSTs /api/tabs/:index/release', async () => {
    setNextResponse('{}')
    await releaseHarness(2)
    expect(fetchCalls.some((c) => c.url === '/api/tabs/2/release' && c.init!.method === 'POST')).toBe(true)
  })

  it('destroyHarness POSTs /api/tabs/:index/destroy with {confirm_adopted}', async () => {
    setNextResponse('{}')
    await destroyHarness(2, true)
    const call = fetchCalls.find((c) => c.url === '/api/tabs/2/destroy')!
    expect(call.init!.method).toBe('POST')
    expect(JSON.parse(call.init!.body as string)).toEqual({ confirm_adopted: true })
  })
})

describe('adoptWindow', () => {
  it('POSTs /api/adopt with {session, window, consent_confirmed: true, window_index?} and returns the session_id', async () => {
    setNextResponse({ ok: true, session_id: 's-new' })
    const res = await adoptWindow('sess', 'win', 3)
    expect(res).toEqual({ ok: true, sessionId: 's-new' })
    const call = fetchCalls.find((c) => c.url === '/api/adopt')!
    expect(call.init!.method).toBe('POST')
    expect(JSON.parse(call.init!.body as string)).toEqual({ session: 'sess', window: 'win', consent_confirmed: true, window_index: 3 })
  })

  it('returns {ok:false, sessionId:null} on a non-ok response', async () => {
    setNextResponse('{}', 403)
    const res = await adoptWindow('sess', 'win')
    expect(res).toEqual({ ok: false, sessionId: null })
  })
})

describe('useAgents', () => {
  it('fetches GET /api/agents on mount', async () => {
    setNextResponse([{ name: 'dev', isDefault: true }])
    const { result } = renderHook(() => useAgents())
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    expect(result.current.agents[0]!.name).toBe('dev')
  })
})

describe('fetchSessionAgents', () => {
  it('GETs /api/sessions/:id/agents and returns the list', async () => {
    setNextResponse([{ name: 'agents-md', isDefault: true, displayName: 'Project (agents.md)' }])
    const res = await fetchSessionAgents('sess123')
    expect(fetchCalls.some((c) => c.url === '/api/sessions/sess123/agents')).toBe(true)
    expect(res).toEqual([{ name: 'agents-md', isDefault: true, displayName: 'Project (agents.md)' }])
  })

  it('returns null on a non-ok response', async () => {
    setNextResponse('not found', 404)
    const res = await fetchSessionAgents('nope')
    expect(res).toBeNull()
  })
})

describe('useSessionAgents', () => {
  it('fetches /api/sessions/:id/agents when sessionId is non-null', async () => {
    setNextResponse([{ name: 'foo-agent', isDefault: false }])
    const { result } = renderHook(() => useSessionAgents('sess-abc'))
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    expect(result.current.agents[0]!.name).toBe('foo-agent')
    expect(fetchCalls.some((c) => c.url === '/api/sessions/sess-abc/agents')).toBe(true)
  })

  it('fetches /api/agents when sessionId is null (global fallback)', async () => {
    setNextResponse([{ name: 'global-agent', isDefault: true }])
    const { result } = renderHook(() => useSessionAgents(null))
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    expect(result.current.agents[0]!.name).toBe('global-agent')
    expect(fetchCalls.some((c) => c.url === '/api/agents')).toBe(true)
  })
})

describe('useConfiguredProviders', () => {
  it('fetches GET /api/providers on mount', async () => {
    setNextResponse([{ name: 'anthropic' }])
    const { result } = renderHook(() => useConfiguredProviders())
    await waitFor(() => expect(result.current.providers).toHaveLength(1))
    expect(result.current.loaded).toBe(true)
  })
})

describe('fetchProviderModels', () => {
  it('GETs /api/providers/:p/models and returns {name, contextWindow}[]', async () => {
    setNextResponse([{ name: 'claude-sonnet-4', contextWindow: 200000 }])
    const res = await fetchProviderModels('anthropic')
    expect(res).toEqual([{ name: 'claude-sonnet-4', contextWindow: 200000 }])
    expect(fetchCalls.some((c) => c.url === '/api/providers/anthropic/models')).toBe(true)
  })
})

describe('fetchModelContext', () => {
  it('GETs /api/providers/:p/models/:m/context and returns the context window', async () => {
    setNextResponse({ contextWindow: 200000, maxOutputTokens: 64000 })
    const res = await fetchModelContext('anthropic', 'claude-sonnet-4')
    expect(res).toEqual({ contextWindow: 200000, maxOutputTokens: 64000 })
    expect(fetchCalls.some((c) => c.url === '/api/providers/anthropic/models/claude-sonnet-4/context')).toBe(true)
  })
})
// ── Agent CRUD ──────────────────────────────────────────────────────────

import {
  fetchAgentDefs,
  fetchAgentDef,
  createAgentDef,
  updateAgentDef,
  deleteAgentDef,
  fetchDefaultAgent,
  setDefaultAgent,
  useAgentDefs,
} from '../useApi'

describe('Agent CRUD', () => {
  it('fetchAgentDefs GETs /api/agents and returns the list', async () => {
    setNextResponse([
      {
        id: 'planner', name: 'planner', isDefault: true, displayName: 'Planner',
        provider: 'ollama', model: 'llama3.2', system: 'plan tasks',
        tools: 'all', created_at: 't', updated_at: 't', session: 'web',
      },
    ])
    const res = await fetchAgentDefs()
    expect(res).toHaveLength(1)
    expect(res![0]!.id).toBe('planner')
    expect(fetchCalls.some((c) => c.url === '/api/agents')).toBe(true)
  })

  it('fetchAgentDef GETs /api/agents/:id', async () => {
    setNextResponse({
      id: 'planner', name: 'planner', isDefault: false, displayName: 'Planner',
      provider: '', model: '', system: null, tools: 'all',
      created_at: 't', updated_at: 't', session: 'web',
    })
    const res = await fetchAgentDef('planner')
    expect(res?.id).toBe('planner')
    expect(fetchCalls.some((c) => c.url === '/api/agents/planner')).toBe(true)
  })

  it('createAgentDef POSTs /api/agents with the input body', async () => {
    setNextResponse({
      id: 'coder', name: 'coder', isDefault: false, displayName: 'Coder',
      provider: 'anthropic', model: 'claude-sonnet-4', system: 'be terse',
      tools: ['FILE_READ'], created_at: 't', updated_at: 't', session: 'web',
    }, 201)
    const res = await createAgentDef({ id: 'coder', system: 'be terse', tools: ['FILE_READ'] })
    expect(res?.id).toBe('coder')
    const call = fetchCalls.find((c) => c.url === '/api/agents' && c.init?.method === 'POST')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ id: 'coder', system: 'be terse', tools: ['FILE_READ'] })
  })

  it('createAgentDef returns null on a 400', async () => {
    setNextResponse({ error: 'bad id' }, 400)
    const res = await createAgentDef({ id: 'bad id!' })
    expect(res).toBeNull()
  })

  it('updateAgentDef PUTs /api/agents/:id (no id in the body)', async () => {
    setNextResponse({
      id: 'eddy', name: 'eddy', isDefault: false, displayName: 'Eddy 2',
      provider: 'anthropic', model: 'claude-sonnet-4', system: null, tools: 'all',
      created_at: 't', updated_at: 't', session: 'web',
    })
    const res = await updateAgentDef('eddy', { name: 'Eddy 2', provider: 'anthropic' })
    expect(res?.displayName).toBe('Eddy 2')
    const call = fetchCalls.find((c) => c.url === '/api/agents/eddy' && c.init?.method === 'PUT')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ name: 'Eddy 2', provider: 'anthropic' })
  })

  it('deleteAgentDef DELETEs /api/agents/:id and returns true on 204', async () => {
    // 204 No Content must have an empty body; use Response with null body.
    nextResponse = new Response(null, { status: 204 })
    const ok = await deleteAgentDef('gone')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/agents/gone' && c.init?.method === 'DELETE')
    expect(call).toBeTruthy()
  })

  it('deleteAgentDef returns false on a network error', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('network') }))
    const ok = await deleteAgentDef('gone')
    expect(ok).toBe(false)
  })
})

describe('Default agent', () => {
  it('fetchDefaultAgent GETs /api/agents/default and returns the id', async () => {
    setNextResponse({ agent: 'planner' })
    const res = await fetchDefaultAgent()
    expect(res).toBe('planner')
    expect(fetchCalls.some((c) => c.url === '/api/agents/default')).toBe(true)
  })

  it('fetchDefaultAgent returns null when agent is null', async () => {
    setNextResponse({ agent: null })
    const res = await fetchDefaultAgent()
    expect(res).toBeNull()
  })

  it('fetchDefaultAgent returns null on a non-ok response', async () => {
    setNextResponse({ error: 'nope' }, 500)
    const res = await fetchDefaultAgent()
    expect(res).toBeNull()
  })

  it('setDefaultAgent PUTs /api/agents/default with the agent body', async () => {
    setNextResponse({ agent: 'planner' })
    const ok = await setDefaultAgent('planner')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/agents/default' && c.init?.method === 'PUT')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ agent: 'planner' })
  })

  it('setDefaultAgent sends null when clearing', async () => {
    setNextResponse({ agent: null })
    const ok = await setDefaultAgent(null)
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/agents/default' && c.init?.method === 'PUT')
    expect(JSON.parse(call!.init!.body as string)).toEqual({ agent: null })
  })

  it('setDefaultAgent returns false on a 404 (agent not found)', async () => {
    setNextResponse({ error: 'agent not found' }, 404)
    const ok = await setDefaultAgent('ghost')
    expect(ok).toBe(false)
  })
})

describe('useAgentDefs', () => {
  it('fetches GET /api/agents on mount and populates state', async () => {
    setNextResponse([
      {
        id: 'planner', name: 'planner', isDefault: true, displayName: 'Planner',
        provider: 'ollama', model: 'llama3.2', system: null, tools: 'all',
        created_at: 't', updated_at: 't', session: 'web',
      },
    ])
    const { result } = renderHook(() => useAgentDefs())
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    expect(result.current.agents[0]!.id).toBe('planner')
    expect(result.current.loaded).toBe(true)
    expect(result.current.error).toBe(false)
  })

  it('sets error=true on a 500', async () => {
    setNextResponse('err', 500)
    const { result } = renderHook(() => useAgentDefs())
    await waitFor(() => expect(result.current.error).toBe(true))
  })

  it('refresh() triggers a re-fetch', async () => {
    setNextResponse([
      {
        id: 'a1', name: 'a1', isDefault: false, displayName: 'A1',
        provider: '', model: '', system: null, tools: 'all',
        created_at: 't', updated_at: 't', session: 'web',
      },
    ])
    const { result } = renderHook(() => useAgentDefs())
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    const initialCalls = fetchCalls.length
    act(() => result.current.refresh())
    await waitFor(() => expect(fetchCalls.length).toBeGreaterThan(initialCalls))
  })
})

// ── Skill CRUD ──────────────────────────────────────────────────────────

import {
  fetchSkills,
  fetchSkill,
  createSkill,
  updateSkill,
  deleteSkill,
  useSkills,
} from '../useApi'

describe('Skill CRUD', () => {
  it('fetchSkills GETs /api/skills', async () => {
    setNextResponse([
      { id: 'coding', description: 'Coding', body: 'body', created_at: 't', updated_at: 't', session: 'web' },
    ])
    const res = await fetchSkills()
    expect(res).toHaveLength(1)
    expect(res![0]!.id).toBe('coding')
  })

  it('fetchSkill GETs /api/skills/:id', async () => {
    setNextResponse({ id: 'coding', description: 'Coding', body: 'b', created_at: 't', updated_at: 't', session: 'web' })
    const res = await fetchSkill('coding')
    expect(res?.id).toBe('coding')
    expect(fetchCalls.some((c) => c.url === '/api/skills/coding')).toBe(true)
  })

  it('createSkill POSTs /api/skills with the input body', async () => {
    setNextResponse({ id: 'coding', description: 'Coding', body: 'b', created_at: 't', updated_at: 't', session: 'web' }, 201)
    const res = await createSkill({ id: 'coding', description: 'Coding', body: 'b' })
    expect(res?.id).toBe('coding')
    const call = fetchCalls.find((c) => c.url === '/api/skills' && c.init?.method === 'POST')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ id: 'coding', description: 'Coding', body: 'b' })
  })

  it('updateSkill PUTs /api/skills/:id (no id in the body)', async () => {
    setNextResponse({ id: 'writer', description: 'Writer 2', body: 'b2', created_at: 't', updated_at: 't', session: 'web' })
    const res = await updateSkill('writer', { description: 'Writer 2', body: 'b2' })
    expect(res?.description).toBe('Writer 2')
    const call = fetchCalls.find((c) => c.url === '/api/skills/writer' && c.init?.method === 'PUT')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ description: 'Writer 2', body: 'b2' })
  })

  it('deleteSkill DELETEs /api/skills/:id and returns true on 204', async () => {
    nextResponse = new Response(null, { status: 204 })
    const ok = await deleteSkill('gone')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/skills/gone' && c.init?.method === 'DELETE')
    expect(call).toBeTruthy()
  })
})

describe('useSkills', () => {
  it('fetches GET /api/skills on mount and populates state', async () => {
    setNextResponse([
      { id: 'coding', description: 'Coding', body: 'b', created_at: 't', updated_at: 't', session: 'web' },
    ])
    const { result } = renderHook(() => useSkills())
    await waitFor(() => expect(result.current.skills).toHaveLength(1))
    expect(result.current.skills[0]!.id).toBe('coding')
    expect(result.current.loaded).toBe(true)
  })

  it('sets error=true on a 500', async () => {
    setNextResponse('err', 500)
    const { result } = renderHook(() => useSkills())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

// ── Repo CRUD ───────────────────────────────────────────────────────────

import {
  fetchRepos,
  fetchRepo,
  createRepo,
  updateRepo,
  deleteRepo,
  useRepos,
} from '../useApi'

describe('Repo CRUD', () => {
  it('fetchRepos GETs /api/repos', async () => {
    setNextResponse([
      { id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } },
    ])
    const res = await fetchRepos()
    expect(res).toHaveLength(1)
    expect(res![0]!.id).toBe('myrepo')
    expect(res![0]!.credential.kind).toBe('pat')
  })

  it('fetchRepo GETs /api/repos/:id', async () => {
    setNextResponse({ id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    const res = await fetchRepo('myrepo')
    expect(res?.id).toBe('myrepo')
    expect(fetchCalls.some((c) => c.url === '/api/repos/myrepo')).toBe(true)
  })

  it('createRepo POSTs /api/repos with the input body', async () => {
    setNextResponse({ id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } }, 201)
    const res = await createRepo({ id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    expect(res.ok).toBe(true)
    if (res.ok) expect(res.repo.id).toBe('myrepo')
    const call = fetchCalls.find((c) => c.url === '/api/repos' && c.init?.method === 'POST')
    expect(call).toBeTruthy()
    expect(JSON.parse(call!.init!.body as string)).toEqual({ id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
  })

  it('createRepo surfaces the backend error on a 400', async () => {
    setNextResponse({ error: 'disallowed host: evil.example' }, 400)
    const res = await createRepo({ id: 'myrepo', url: 'git@evil.example/o.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.error).toBe('disallowed host: evil.example')
  })

  it('createRepo falls back to HTTP status when the body has no error', async () => {
    setNextResponse('oops', 500)
    const res = await createRepo({ id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.error).toBe('HTTP 500')
  })

  it('updateRepo PUTs /api/repos/:id (id from path; no new_id)', async () => {
    setNextResponse({ id: 'myrepo', url: 'git@github.com:owner/repo2.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    const res = await updateRepo('myrepo', { url: 'git@github.com:owner/repo2.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } })
    expect(res?.url).toBe('git@github.com:owner/repo2.git')
    const call = fetchCalls.find((c) => c.url === '/api/repos/myrepo' && c.init?.method === 'PUT')
    expect(call).toBeTruthy()
    const body = JSON.parse(call!.init!.body as string) as { id?: string; new_id?: string; url: string }
    expect(body.id).toBeUndefined()
    expect(body.new_id).toBeUndefined()
    expect(body.url).toBe('git@github.com:owner/repo2.git')
  })

  it('deleteRepo DELETEs /api/repos/:id and returns true on 204', async () => {
    nextResponse = new Response(null, { status: 204 })
    const ok = await deleteRepo('gone')
    expect(ok).toBe(true)
    const call = fetchCalls.find((c) => c.url === '/api/repos/gone' && c.init?.method === 'DELETE')
    expect(call).toBeTruthy()
  })

  it('deleteRepo returns false on a 500', async () => {
    setNextResponse('err', 500)
    const ok = await deleteRepo('bad')
    expect(ok).toBe(false)
  })
})

describe('useRepos', () => {
  it('fetches GET /api/repos on mount and populates state', async () => {
    setNextResponse([
      { id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } },
    ])
    const { result } = renderHook(() => useRepos())
    await waitFor(() => expect(result.current.repos).toHaveLength(1))
    expect(result.current.repos[0]!.id).toBe('myrepo')
    expect(result.current.loaded).toBe(true)
    expect(result.current.error).toBe(false)
  })

  it('sets error=true on a 500', async () => {
    setNextResponse('err', 500)
    const { result } = renderHook(() => useRepos())
    await waitFor(() => expect(result.current.error).toBe(true))
  })

  it('refresh() triggers a re-fetch', async () => {
    setNextResponse([
      { id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } },
    ])
    const { result } = renderHook(() => useRepos())
    await waitFor(() => expect(result.current.repos).toHaveLength(1))
    const initialCalls = fetchCalls.length
    act(() => result.current.refresh())
    await waitFor(() => expect(fetchCalls.length).toBeGreaterThan(initialCalls))
  })

  it('re-fetches when the repos-changed WS frame fires', async () => {
    // First response: one repo. Second response: two repos.
    setNextResponse([
      { id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } },
    ])
    const { result } = renderHook(() => useRepos())
    await waitFor(() => expect(result.current.repos).toHaveLength(1))
    const initialCalls = fetchCalls.length

    // Swap the response for the next fetch (the WS-triggered re-fetch).
    setNextResponse([
      { id: 'myrepo', url: 'git@github.com:owner/repo.git', vcs_kind: 'github', credential: { kind: 'pat', vault_key: 'GITHUB_PAT' } },
      { id: 'other', url: 'git@github.com:owner/other.git', vcs_kind: 'github', credential: { kind: 'deploy_key', vault_key: 'GH_DEPLOY' } },
    ])

    // Fire the repos-changed invalidation (mirrors the WS frame dispatch).
    act(() => {
      for (const cb of reposChangedCbs) cb()
    })
    await waitFor(() => expect(fetchCalls.length).toBeGreaterThan(initialCalls))
    await waitFor(() => expect(result.current.repos).toHaveLength(2))
  })
})
