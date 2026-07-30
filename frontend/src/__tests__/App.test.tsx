import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor, act } from '@testing-library/react'
import App from '../App'
import type { SessionInfo, TranscriptEntry } from '../types'

// Mock the WS singleton so the stream-driven hooks (useListsStream,
// useTranscriptStream, useSessionActivityStream) never attempt a real
// WebSocket connection. The factory returns a SINGLE stable client (the
// hooks use `streamClient()` as a dep — a fresh object each call would
// re-trigger their effects every render and loop).
vi.mock('../lib/streamClient', () => {
  const unsub = () => {}
  const client = {
    status: 'closed',
    focus: () => {},
    onEntry: () => unsub,
    onActivity: () => unsub,
    onLists: () => unsub,
    onStatusChange: () => unsub,
    onAsk: () => unsub,
    onAskResolved: () => unsub,
    onAgentDefsChanged: () => unsub,
    onSkillsChanged: () => unsub,
    lastError: () => null,
  }
  return { streamClient: () => client }
})

// ── Mocks ──────────────────────────────────────────────────────────────────

// Capture fetch calls so tests can assert + supply responses.
type FetchCall = { url: string; init?: RequestInit }
const fetchCalls: FetchCall[] = []
let nextResponse: globalThis.Response = new globalThis.Response('{}', {
  status: 200,
  headers: { 'Content-Type': 'application/json' },
})

beforeEach(() => {
  fetchCalls.length = 0
  nextResponse = new globalThis.Response('{}', {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    fetchCalls.push({ url, init })
    return nextResponse
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  cleanup()
})

function setNextResponse(body: unknown, status = 200): void {
  nextResponse = new globalThis.Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// ── Helpers ────────────────────────────────────────────────────────────────

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's1',
    agent: null,
    runtime: 'session:anthropic',
    model: 'claude-sonnet-4-20250514',
    lastActive: new Date().toISOString(),
    createdAt: new Date('2024-01-01T00:00:00Z').toISOString(),
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    lastUserMessageAt: null,
    ...overrides,
  }
}

function makeEntry(overrides: Partial<TranscriptEntry> = {}): TranscriptEntry {
  return {
    id: 'e1',
    timestamp: '2024-06-01T12:00:00Z',
    direction: 'request',
    payload: JSON.stringify({ messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }] }),
    harness: null,
    model: 'claude-sonnet-4-20250514',
    channel: null,
    raw: '{}',
    ...overrides,
  }
}

/** Default fetch dispatcher: return empty arrays / sensible defaults per URL so
 *  the App renders against an empty-but-valid world. */
function defaultFetchDispatch(): void {
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    fetchCalls.push({ url, init })
    let body: unknown = {}
    if (url === '/api/agents') body = []
    else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
    else if (url === '/api/providers/anthropic/models') body = [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
    else if (url === '/api/sessions') body = []
    else if (url === '/api/sessions/archived') body = []
    else if (url === '/api/tabs') body = []
    else if (url === '/api/harnesses') body = []
    else if (url === '/api/harnesses/discover') body = []
    else if (url.includes('/questions')) body = []
    else if (url.includes('/transcript')) body = []
    return new globalThis.Response(JSON.stringify(body), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  }))
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('App — layout', () => {
  it('renders TopBar, Sidebar, ChatArea, and BottomBar chrome', () => {
    defaultFetchDispatch()
    render(<App />)
    // TopBar: brand appears (also as the default chat-agent name when nothing
    // is selected, so assert at least one occurrence) + the version pill.
    expect(screen.getAllByText('Seal Harness').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('v0.1.0')).toBeTruthy()
    // Sidebar: Active Tabs + Recent Sessions headers always render (even
    // when empty) so the + buttons are always reachable.
    expect(screen.getByText('Active Tabs')).toBeTruthy()
    expect(screen.getByText('Recent Sessions')).toBeTruthy()
    // ChatArea: empty-state message (no selection → ChatArea empty state).
    expect(screen.getByText(/No messages yet|Select a session/i)).toBeTruthy()
    // BottomBar: token label + idle indicator.
    expect(screen.getByText('Tokens')).toBeTruthy()
    expect(screen.getByText('Idle')).toBeTruthy()
  })

  it('does NOT render any reference product name', () => {
    defaultFetchDispatch()
    const { container } = render(<App />)
    expect(container.textContent).not.toMatch(/pureclaw/i)
  })
})

describe('App — sidebar selection', () => {
  it('clicking a session in the sidebar focuses the chat area on that session', async () => {
    defaultFetchDispatch()
    // Override /api/sessions to return one session.
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      let body: unknown = []
      if (url === '/api/sessions') body = [makeSession({ id: 'sess-A', description: 'Session A' })]
      else if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true }]
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // The session row renders in the sidebar's Recent Sessions.
    const row = await screen.findByText('Session A')
    fireEvent.click(row)
    // The chat-header title should now read the session's title (the
    // EditableSessionTitle shows it).
    expect(screen.getAllByText('Session A').length).toBeGreaterThanOrEqual(1)
  })

  it('clicking the New Tab button opens the composer', async () => {
    defaultFetchDispatch()
    render(<App />)
    fireEvent.click(screen.getByLabelText('New tab'))
    // The composer renders its kind pills + a "Start a new tab" header.
    expect(screen.getByText('Start a new tab')).toBeTruthy()
    expect(screen.getByRole('radio', { name: 'AI Provider' })).toBeTruthy()
  })
})

describe('App — harness tab', () => {
  it('selecting a harness tab shows the HarnessControls pane', async () => {
    // Provide a harness tab in /api/tabs and a backing session in /api/sessions.
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      let body: unknown = []
      if (url === '/api/tabs') {
        body = [{
          index: 0,
          kind: 'harness',
          label: 'cc-window',
          status: 'idle',
          session_id: 'sess-H',
          origin: 'spawned',
          attach_command: 'tmux attach -t cc',
        }]
      } else if (url === '/api/sessions') {
        body = [makeSession({ id: 'sess-H', description: 'Harness Sess', agent: 'claude-code' })]
      } else if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true }]
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // The harness tab appears in "Running Harnesses" AND its backing session
    // appears in "Recent Sessions" (both show the session title). Pick the
    // first match (the Running Harnesses row renders above Recent Sessions).
    await waitFor(() => {
      expect(screen.getAllByText('Harness Sess').length).toBeGreaterThanOrEqual(1)
    })
    fireEvent.click(screen.getAllByText('Harness Sess')[0]!)
    // HarnessControls renders the "Destroy harness" button + the Status field.
    await waitFor(() => {
      expect(screen.getByText('Destroy harness')).toBeTruthy()
      expect(screen.getByText('Status')).toBeTruthy()
    })
  })
})

describe('App — send + branch', () => {
  it('sending a message calls the send hook (POST /api/sessions/:id/send)', async () => {
    // Provide a session + its transcript + a 200 send response.
    setNextResponse({ response: 'ok', kind: 'assistant' })
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      if (url === '/api/sessions' && method === 'GET') {
        return new globalThis.Response(JSON.stringify([makeSession({ id: 'sess-send', description: 'Send Sess' })]), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url === '/api/sessions/sess-send/send' && method === 'POST') {
        return new globalThis.Response(JSON.stringify({ response: 'ok', kind: 'assistant' }), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url === '/api/sessions/sess-send/transcript' && method === 'GET') {
        return new globalThis.Response(JSON.stringify([]), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        })
      }
      const body: unknown = url === '/api/agents' ? []
        : url === '/api/providers' ? [{ name: 'anthropic', isDefault: true }]
        : url === '/api/providers/anthropic/models' ? [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
        : []
      return new globalThis.Response(JSON.stringify(body), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Select the session.
    const row = await screen.findByText('Send Sess')
    fireEvent.click(row)
    // Type a message + click Send.
    const textarea = screen.getByPlaceholderText(/Message/) as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'hello world' } })
    fireEvent.click(screen.getByText('Send').closest('button')!)
    await waitFor(() => {
      expect(fetchCalls.some((c) => c.url === '/api/sessions/sess-send/send')).toBe(true)
    })
  })

  it('branch-from-here opens the composer with branchFrom set', async () => {
    // Provide a provider session + a transcript with one user entry.
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      if (url === '/api/sessions' && method === 'GET') {
        return new globalThis.Response(JSON.stringify([makeSession({ id: 'sess-b', description: 'Branch Sess', runtime: 'session:anthropic' })]), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url === '/api/sessions/sess-b/transcript' && method === 'GET') {
        return new globalThis.Response(JSON.stringify([makeEntry({ id: 'be1' })]), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        })
      }
      const body: unknown = url === '/api/agents' ? []
        : url === '/api/providers' ? [{ name: 'anthropic', isDefault: true }]
        : url === '/api/providers/anthropic/models' ? [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
        : []
      return new globalThis.Response(JSON.stringify(body), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Select the provider session.
    const row = await screen.findByText('Branch Sess')
    fireEvent.click(row)
    // Wait for the transcript to render the user message ("hi"), then click the
    // branch button on that row.
    await screen.findByText('hi')
    fireEvent.click(screen.getByLabelText('branch session from here'))
    // The composer opens with the "Branch from here" header.
    expect(screen.getByText('Branch from here')).toBeTruthy()
  })

  it('W7 partition: a session in both tabs[].session_id AND recentSessions (buggy /api/lists) renders under Active Tabs only', async () => {
    // Simulate a backend that (incorrectly) returns the same session in both
    // the tabs list AND recentSessions. The Sidebar's defense-in-depth
    // filter must drop it from Recent Sessions so the sidebar shows it under
    // Active Tabs only (the W7 partition invariant). The backend's
    // partitionSessions guarantees mutual exclusion by construction; this
    // test pins the frontend safety net.
    const sess = makeSession({ id: 'dup-1', description: 'Dup Sess' })
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      let body: unknown = {}
      if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
      else if (url === '/api/lists') {
        // Buggy shape: the session appears in both tabs[].session_id AND
        // recentSessions (a backend bug or a stale frame).
        body = {
          tabs: [{ index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'dup-1', ext_modified: false, stale: false, attach_command: null }],
          recentSessions: [sess],
          archivedSessions: [],
          tabSessions: [],
        }
      } else if (url === '/api/tabs') body = []
      else if (url === '/api/sessions') body = []
      else if (url === '/api/sessions/archived') body = []
      else if (url === '/api/harnesses') body = []
      else if (url.includes('/transcript')) body = []
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Wait for /api/lists to populate. The session appears under Active Tabs.
    // The sidebar's defense-in-depth filter drops it from Recent Sessions,
    // so "Dup Sess" renders exactly once (under Active Tabs).
    await waitFor(() => {
      expect(screen.getAllByText('Dup Sess').length).toBe(1)
    })
  })
})

// ── Tab close preserves the focused session ─────────────────────────────
// When the user closes a tab ABOVE the focused tab, the backend compacts the
// remaining tab indices. The frontend must re-select the focused session's
// new tab index — NOT keep the stale tab number (which would either jump to a
// different session or show nothing). These tests pin that behavior.

describe('App — tab close preserves the focused session', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    // jsdom's window.location persists across tests in the file; reset so
    // each case starts from a clean root (no leftover /tab/<n> selection).
    window.history.replaceState(null, '', '/')
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('after closing a tab above the focused one, re-selects the same session at its new tab index', async () => {
    // Two tabs: index 0 = "Tab A", index 1 = "Tab B". User selects Tab B (the
    // lower one), then closes Tab A. After the backend compacts, Tab B becomes
    // index 0. The URL should reflect /tab/0 and the transcript for Tab B's
    // session stays on screen (no jump to Tab A's session).
    const tabASession = makeSession({ id: 'sess-A', description: 'Tab A' })
    const tabBSession = makeSession({ id: 'sess-B', description: 'Tab B' })
    let tabs = [
      { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null },
      { index: 1, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null },
    ]
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      let body: unknown = {}
      if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
      else if (url === '/api/providers/anthropic/models') body = [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
      else if (url === '/api/lists') {
        body = { tabs, recentSessions: [], archivedSessions: [], tabSessions: [tabASession, tabBSession] }
      } else if (url === '/api/tabs') body = tabs
      else if (url === '/api/sessions') body = []
      else if (url === '/api/sessions/archived') body = []
      else if (url === '/api/harnesses') body = []
      else if (url === '/api/harnesses/discover') body = []
      else if (url.includes('/transcript')) body = []
      else if (url === '/api/tabs/0/close' && method === 'POST') {
        // Compact: Tab A gone, Tab B slides to index 0.
        tabs = [{ index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null }]
        body = null
      }
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Wait for both tabs to render, then select Tab B (index 1).
    const tabBRow = await screen.findByText('Tab B')
    fireEvent.click(tabBRow)
    await waitFor(() => { expect(window.location.pathname).toBe('/tab/1') })
    // Close Tab A (index 0) via its row's Close button.
    const tabARowEl = screen.getByText('Tab A').closest('.agent-row')
    const tabAClose = tabARowEl!.querySelector('[aria-label="Close tab"]') as HTMLElement
    await act(async () => { fireEvent.click(tabAClose) })
    // Tick the /api/lists poll so the compacted tab list arrives.
    await act(async () => { vi.advanceTimersByTimeAsync(3000) })
    // After the backend compacts, the focused session (sess-B) re-selects at
    // its new tab index (0). The URL updates to /tab/0 and Tab B stays on
    // screen — no jump to Tab A or to the empty state.
    await waitFor(() => {
      expect(window.location.pathname).toBe('/tab/0')
    })
    // Tab B's row is still rendered (its label resolves via the tab).
    expect(document.querySelector('.agent-row span[title="Tab B"]')).toBeTruthy()
  })

  it('after closing the focused tab itself, falls back to the bare session so the transcript stays', async () => {
    // Two tabs: index 0 = "Tab A", index 1 = "Tab B". User selects Tab B, then
    // closes Tab B itself. The session survives in Recent Sessions, so the
    // frontend should switch to `session:<id>` and keep the transcript on
    // screen (rather than blanking to the empty state).
    const tabASession = makeSession({ id: 'sess-A', description: 'Tab A' })
    const tabBSession = makeSession({ id: 'sess-B', description: 'Tab B' })
    let tabs = [
      { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null },
      { index: 1, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null },
    ]
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      let body: unknown = {}
      if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
      else if (url === '/api/providers/anthropic/models') body = [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
      else if (url === '/api/lists') {
        // tabSessions empty so the sidebar resolves labels via recentSessions;
        // the defense-in-depth filter drops tab-backed rows from the Recent
        // Sessions list while they're tabs.
        body = { tabs, recentSessions: [tabASession, tabBSession], archivedSessions: [], tabSessions: [] }
      } else if (url === '/api/tabs') body = tabs
      else if (url === '/api/sessions') body = []
      else if (url === '/api/sessions/archived') body = []
      else if (url === '/api/harnesses') body = []
      else if (url === '/api/harnesses/discover') body = []
      else if (url.includes('/transcript')) body = []
      else if (url === '/api/tabs/1/close' && method === 'POST') {
        // Close Tab B → only Tab A remains at index 0.
        tabs = [{ index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null }]
        body = null
      }
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Select Tab B (the lower tab). It appears in Active Tabs.
    const tabBRow = await screen.findByText('Tab B')
    fireEvent.click(tabBRow)
    await waitFor(() => { expect(window.location.pathname).toBe('/tab/1') })
    // Close Tab B (the focused tab) via its row's Close button. Use the
    // title attribute to disambiguate the tab-row label from the chat header
    // (both render "Tab B" once the tab is selected).
    const tabBLabel = document.querySelector('.agent-row span[title="Tab B"]') as HTMLElement
    const tabBRowEl = tabBLabel.closest('.agent-row')!
    const tabBClose = tabBRowEl.querySelector('[aria-label="Close tab"]') as HTMLElement
    await act(async () => { fireEvent.click(tabBClose) })
    await act(async () => { vi.advanceTimersByTimeAsync(3000) })
    // The focused session survives in Recent Sessions → re-select it as a
    // bare session so its transcript stays on screen.
    await waitFor(() => {
      expect(window.location.pathname).toBe('/session/sess-B')
    })
  })

  it('does NOT re-fetch the transcript when closing the focused tab (session id is stable across the compact)', async () => {
    // Regression: closing the focused tab caused `currentSessionId` to
    // briefly become null (the stale `tab:<idx>` no longer resolved before
    // the re-selection effect ran), which cleared the transcript and
    // triggered a duplicate seed fetch + "Loading..." flash. The fix holds
    // the pinned session id in `currentSessionId` across that window.
    const tabASession = makeSession({ id: 'sess-A', description: 'Tab A' })
    const tabBSession = makeSession({ id: 'sess-B', description: 'Tab B' })
    let tabs = [
      { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null },
      { index: 1, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null },
    ]
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      let body: unknown = {}
      if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
      else if (url === '/api/providers/anthropic/models') body = [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
      else if (url === '/api/lists') {
        body = { tabs, recentSessions: [tabASession, tabBSession], archivedSessions: [], tabSessions: [] }
      } else if (url === '/api/tabs') body = tabs
      else if (url === '/api/sessions') body = []
      else if (url === '/api/sessions/archived') body = []
      else if (url === '/api/harnesses') body = []
      else if (url === '/api/harnesses/discover') body = []
      else if (url.includes('/transcript')) body = []
      else if (url === '/api/tabs/1/close' && method === 'POST') {
        tabs = [{ index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null }]
        body = null
      }
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Select Tab B (index 1) and let its transcript seed land.
    const tabBRow = await screen.findByText('Tab B')
    fireEvent.click(tabBRow)
    await waitFor(() => { expect(window.location.pathname).toBe('/tab/1') })
    // Drain any in-flight seed fetch for sess-B.
    await act(async () => { vi.advanceTimersByTimeAsync(3000) })
    // Snapshot the transcript fetches observed so far (the initial seed for
    // sess-B should be among them).
    const transcriptFetchesBefore = fetchCalls.filter(
      (c) => c.url.includes('/transcript') && (c.init?.method ?? 'GET') === 'GET',
    ).length
    expect(transcriptFetchesBefore).toBeGreaterThanOrEqual(1)
    // Close Tab B (the focused tab).
    const tabBLabel = document.querySelector('.agent-row span[title="Tab B"]') as HTMLElement
    const tabBRowEl = tabBLabel.closest('.agent-row')!
    const tabBClose = tabBRowEl.querySelector('[aria-label="Close tab"]') as HTMLElement
    await act(async () => { fireEvent.click(tabBClose) })
    await act(async () => { vi.advanceTimersByTimeAsync(3000) })
    // The session survived (now selected as a bare session). The transcript
    // must NOT have been re-fetched — the focused session id never changed.
    await waitFor(() => { expect(window.location.pathname).toBe('/session/sess-B') })
    const transcriptFetchesAfter = fetchCalls.filter(
      (c) => c.url.includes('/transcript') && (c.init?.method ?? 'GET') === 'GET',
    ).length
    expect(transcriptFetchesAfter).toBe(transcriptFetchesBefore)
  })

  it('after closing a tab above the focused one in a 3-tab list, follows the focused session to its new index (not the stale tab number)', async () => {
    // Three tabs: 0 = A, 1 = B, 2 = C. User selects tab 1 (B). Closes tab 0
    // (above the focused one). Backend compacts: B slides to 0, C slides to 1.
    // The frontend MUST follow the focused SESSION (B → /tab/0), NOT stay on
    // the stale tab number /tab/1 (which now points at C). This pins the
    // regression where the pin-tracker re-read the tab at the stale index
    // (now C) and overwrote the pin before the re-selector ran.
    const tabASession = makeSession({ id: 'sess-A', description: 'Tab A' })
    const tabBSession = makeSession({ id: 'sess-B', description: 'Tab B' })
    const tabCSession = makeSession({ id: 'sess-C', description: 'Tab C' })
    let tabs = [
      { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-A', ext_modified: false, stale: false, attach_command: null },
      { index: 1, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null },
      { index: 2, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-C', ext_modified: false, stale: false, attach_command: null },
    ]
    vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
      fetchCalls.push({ url, init })
      const method = init?.method ?? 'GET'
      let body: unknown = {}
      if (url === '/api/agents') body = []
      else if (url === '/api/providers') body = [{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4-20250514' }]
      else if (url === '/api/providers/anthropic/models') body = [{ name: 'claude-sonnet-4-20250514', contextWindow: 200000 }]
      else if (url === '/api/lists') {
        body = { tabs, recentSessions: [], archivedSessions: [], tabSessions: [tabASession, tabBSession, tabCSession] }
      } else if (url === '/api/tabs') body = tabs
      else if (url === '/api/sessions') body = []
      else if (url === '/api/sessions/archived') body = []
      else if (url === '/api/harnesses') body = []
      else if (url === '/api/harnesses/discover') body = []
      else if (url.includes('/transcript')) body = []
      else if (url === '/api/tabs/0/close' && method === 'POST') {
        // Compact: A gone. B → 0, C → 1.
        tabs = [
          { index: 0, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-B', ext_modified: false, stale: false, attach_command: null },
          { index: 1, kind: 'session:anthropic', label: null, status: 'idle', session_id: 'sess-C', ext_modified: false, stale: false, attach_command: null },
        ]
        body = null
      }
      return new globalThis.Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }))
    render(<App />)
    // Select tab 1 (Tab B).
    const tabBRow = await screen.findByText('Tab B')
    fireEvent.click(tabBRow)
    await waitFor(() => { expect(window.location.pathname).toBe('/tab/1') })
    // Close tab 0 (Tab A) — the tab above the focused one.
    const tabARowEl = screen.getByText('Tab A').closest('.agent-row')
    const tabAClose = tabARowEl!.querySelector('[aria-label="Close tab"]') as HTMLElement
    await act(async () => { fireEvent.click(tabAClose) })
    await act(async () => { vi.advanceTimersByTimeAsync(3000) })
    // The focused session (B) slides to index 0 → the URL must follow it to
    // /tab/0. Staying at /tab/1 would show Tab C's contents (the regression).
    await waitFor(() => {
      expect(window.location.pathname).toBe('/tab/0')
    })
    // Tab B is the selected row; Tab C is NOT on screen as the focused tab.
    expect(document.querySelector('.agent-row span[title="Tab B"]')).toBeTruthy()
    // The chat header reflects the focused session (Tab B), not Tab C.
    expect(document.querySelector('.editable-title-text')?.textContent).toBe('Tab B')
  })
})