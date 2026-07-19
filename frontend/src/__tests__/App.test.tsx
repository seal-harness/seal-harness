import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
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
})