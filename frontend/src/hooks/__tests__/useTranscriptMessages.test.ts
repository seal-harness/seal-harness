import { describe, it, expect, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useTranscriptMessages, _resetRendererCacheForTests } from '../useTranscriptMessages'
import { transcriptToMessages } from '../../components/ChatArea'
import type { TranscriptEntry, Message } from '../../types'

/** Resolve rawJson provider functions to strings for deep-equal
 *  comparison. Functions can't be compared by toEqual, so we call them
 *  and replace with the string value. */
function resolveRawJson(msgs: Message[]): Message[] {
  return msgs.map((m) => ({
    ...m,
    rawJson: typeof m.rawJson === 'function' ? m.rawJson() : m.rawJson,
  }))
}

function makeEntry(overrides: Partial<TranscriptEntry> = {}): TranscriptEntry {
  return {
    id: 'e1',
    timestamp: '2024-06-01T12:00:00Z',
    direction: 'request',
    payload: '{}',
    harness: null,
    model: null,
    channel: null,
    internal: null,
    raw: '{}',
    ...overrides,
  }
}

/** A 3-entry transcript: user request, assistant response with a tool_use,
 *  then a user request carrying the matching tool_result. */
function threeEntryTranscript(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'e1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'claude-sonnet-4-20250514',
        system: 'You are a helpful assistant.',
        messages: [
          { role: 'user', content: [{ type: 'text', text: 'Hello, please list files.' }] },
        ],
      }),
      raw: JSON.stringify({ _te_id: 'e1' }),
    }),
    makeEntry({
      id: 'e2',
      direction: 'response',
      model: 'claude-sonnet-4-20250514',
      payload: JSON.stringify({
        model: 'claude-sonnet-4-20250514',
        content: [
          { type: 'text', text: 'Let me list the files.' },
          { type: 'tool_use', id: 'tool-1', name: 'shell', input: { command: 'ls' } },
        ],
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
      raw: JSON.stringify({ _te_id: 'e2' }),
    }),
    makeEntry({
      id: 'e3',
      direction: 'request',
      payload: JSON.stringify({
        model: 'claude-sonnet-4-20250514',
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'tool_result',
                tool_use_id: 'tool-1',
                content: 'file_a.txt\nfile_b.txt',
                is_error: false,
              },
            ],
          },
        ],
      }),
      raw: JSON.stringify({ _te_id: 'e3' }),
    }),
  ]
}

beforeEach(() => {
  _resetRendererCacheForTests()
})

describe('useTranscriptMessages', () => {
  it('produces the same result as transcriptToMessages for a full transcript', () => {
    const entries = threeEntryTranscript()
    const expected = resolveRawJson(transcriptToMessages(entries))
    const { result } = renderHook(() => useTranscriptMessages(entries, 's1'))
    expect(resolveRawJson(result.current)).toEqual(expected)
  })

  it('produces the same result when entries are added incrementally', () => {
    const entries = threeEntryTranscript()
    const expected = resolveRawJson(transcriptToMessages(entries))

    // Start with first entry only.
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: [entries[0]!] } },
    )
    // Add second entry.
    rerender({ entries: [entries[0]!, entries[1]!] })
    // Add third entry (carries tool_result for e2's tool_use).
    rerender({ entries })

    expect(resolveRawJson(result.current)).toEqual(expected)
  })

  it('matches tool calls with tool_results that arrive in later entries', () => {
    const entries = threeEntryTranscript()
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: [entries[0]!, entries[1]!] } },
    )
    // Before e3 arrives, the tool call in e2 has no result.
    let asstRow = result.current.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
    let tcBlock = asstRow.blocks.find((b) => b.toolCall !== undefined)!
    expect(tcBlock.toolCall!.result).toBeUndefined()

    // After e3 arrives, the tool call should be matched with the result.
    rerender({ entries })
    asstRow = result.current.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
    tcBlock = asstRow.blocks.find((b) => b.toolCall !== undefined)!
    expect(tcBlock.toolCall!.result).toBe('file_a.txt\nfile_b.txt')
    expect(tcBlock.toolCall!.resultIsError).toBe(false)
  })

  it('re-processes entries on streaming update (entry replaced by id)', () => {
    const e1 = makeEntry({
      id: 'r1',
      direction: 'response',
      model: 'm',
      streaming: true,
      payload: JSON.stringify({ content: [{ type: 'text', text: 'partial' }] }),
    })
    const e1Final = makeEntry({
      id: 'r1',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'final text' }] }),
    })

    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: [e1] } },
    )
    expect(result.current[0]!.blocks[0]!.text).toBe('partial')
    expect(result.current[0]!.streaming).toBe(true)

    // Replace e1 with the finalized version (same id, different reference).
    rerender({ entries: [e1Final] })
    expect(result.current[0]!.blocks[0]!.text).toBe('final text')
    expect(result.current[0]!.streaming).toBeUndefined()
  })

  it('handles session change by using a separate renderer', () => {
    const session1 = threeEntryTranscript()
    const session2 = [
      makeEntry({
        id: 'x1',
        direction: 'request',
        payload: JSON.stringify({
          system: 'Different system prompt.',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'different session' }] }],
        }),
      }),
    ]

    const { result, rerender } = renderHook(
      ({ entries, sid }) => useTranscriptMessages(entries, sid),
      { initialProps: { entries: session1, sid: 's1' } },
    )
    expect(result.current).toHaveLength(transcriptToMessages(session1).length)

    rerender({ entries: session2, sid: 's2' })
    const expected = resolveRawJson(transcriptToMessages(session2))
    expect(resolveRawJson(result.current)).toEqual(expected)
  })

  it('reuses cached renderer when switching back to a previous session', () => {
    const session1 = threeEntryTranscript()
    const session2 = [
      makeEntry({
        id: 'x1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'session 2' }] }],
        }),
      }),
    ]

    // Load session 1.
    const { result, rerender } = renderHook(
      ({ entries, sid }) => useTranscriptMessages(entries, sid),
      { initialProps: { entries: session1, sid: 's1' } },
    )
    const s1Messages = result.current
    expect(s1Messages).toHaveLength(transcriptToMessages(session1).length)

    // Switch to session 2.
    rerender({ entries: session2, sid: 's2' })
    expect(result.current).toHaveLength(transcriptToMessages(session2).length)

    // Switch back to session 1 — should reuse cached renderer.
    rerender({ entries: session1, sid: 's1' })
    expect(result.current).toHaveLength(s1Messages.length)
    // The messages should be the same (cached, not re-processed).
    expect(resolveRawJson(result.current)).toEqual(resolveRawJson(s1Messages))
  })

  it('deduplicates System Prompt and Tools rows', () => {
    const tools = [{ name: 'shell', description: 'sh', input_schema: {} }]
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'd1',
        direction: 'request',
        payload: JSON.stringify({ system: 'sys', tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }] }),
      }),
      makeEntry({
        id: 'd2',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
      }),
      makeEntry({
        id: 'd3',
        direction: 'request',
        payload: JSON.stringify({ system: 'sys', tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'second' }] }] }),
      }),
    ]
    const { result } = renderHook(() => useTranscriptMessages(entries, 's1'))
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
    expect(result.current.filter((m) => m.agentName === 'Tools')).toHaveLength(1)
  })

  it('preserves System Prompt block when entries are re-fetched with new references', () => {
    // Simulates the real-world scenario: after sending a message, the
    // frontend re-fetches the transcript seed via HTTP. The seed creates
    // new entry objects (same content, different references). The
    // TranscriptRenderer must preserve the System Prompt block — not
    // lose it because seenSystem already contains the content from the
    // first render.
    const tools = [{ name: 'shell', description: 'sh', input_schema: {} }]
    const original: TranscriptEntry[] = [
      makeEntry({
        id: 'd1',
        direction: 'request',
        payload: JSON.stringify({ system: 'sys', tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }] }),
      }),
      makeEntry({
        id: 'd2',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
      }),
    ]
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: original } },
    )
    // System Prompt block is present on first render.
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
    // Re-fetch: same content but new object references (fresh parse).
    const refetched = original.map((e) => ({ ...e, payload: e.payload }))
    rerender({ entries: refetched })
    // System Prompt block must survive the re-render.
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
  })

  it('renders the System Prompt row once — a mid-session change adds no second row', () => {
    // Regression: the backend ships the system prompt on every request
    // entry where it CHANGED (the transcript's envelope-delta encoding).
    // The frontend rendered a "System Prompt" row for every distinct
    // value, so a mid-session change — the agent catalog growing, the
    // project's instructions being edited — made a second preamble group
    // pop up half-way down the session. At the bottom of a long session
    // that is exactly where the user had just typed their message: the
    // transcript showed a "System Prompt" section instead of the new
    // message and the response.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'p1',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          system: 'sys-A',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }],
        }),
      }),
      makeEntry({
        id: 'p2',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
      }),
      // The second request carries a CHANGED system prompt.
      makeEntry({
        id: 'p3',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          system: 'sys-B',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'second' }] }],
        }),
      }),
    ]
    const { result } = renderHook(() => useTranscriptMessages(entries, 's1'))
    const sysRows = result.current.filter((m) => m.agentName === 'System Prompt')
    // One row, carrying the FIRST request's system prompt.
    expect(sysRows).toHaveLength(1)
    expect(sysRows[0]!.blocks[0]!.collapsedText).toBe('sys-A')
  })

  it('anchors the preamble on the first LLM request, not on a preceding opcode entry', () => {
    // A session starts with a SETUP_REPO opcode entry — request-direction,
    // but not an LLM request. The preamble belongs to the first LLM
    // request that follows it.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'op1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [],
          op: { name: 'SETUP_REPO' },
          result: { status: 'cloned', target: 'repo' },
        }),
      }),
      makeEntry({
        id: 'llm1',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          system: 'sys',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
      }),
    ]
    const { result } = renderHook(() => useTranscriptMessages(entries, 's1'))
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
  })

  it('moves the preamble rows when older entries are prepended', () => {
    // The view grows upwards (the user scrolls to the top of the session):
    // the preamble anchor moves to the session's first LLM request, and
    // the entry that was the anchor before stops rendering the rows.
    const first: TranscriptEntry[] = [
      makeEntry({
        id: 'llm1',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          system: 'sys',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
      }),
    ]
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: first } },
    )
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)

    // A newer entry arrives that does NOT carry the system prompt: the
    // anchor stays on the first LLM request, so the row does not move.
    const second: TranscriptEntry = makeEntry({
      id: 'llm2',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys-CHANGED',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'again' }] }],
      }),
    })
    rerender({ entries: [...first, second] })
    const sysRows = result.current.filter((m) => m.agentName === 'System Prompt')
    expect(sysRows).toHaveLength(1)
    expect(sysRows[0]!.blocks[0]!.collapsedText).toBe('sys')
  })

  it('does not render a System Prompt row when a live entry carries a changed prompt', () => {
    // The reported symptom: the user is at the bottom of a long session
    // (the view holds the last N entries — no session start in sight) and
    // hits enter. The backend ships the new request entry with the
    // CHANGED system prompt, and the transcript used to render a
    // "System Prompt" section right where the user's message and the
    // response should have been.
    const view: TranscriptEntry[] = [
      makeEntry({
        id: 'w1',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'older' }] }],
        }),
      }),
      makeEntry({
        id: 'w2',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
      }),
    ]
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: view } },
    )
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(0)

    // The new turn's request entry carries the changed system prompt.
    const live: TranscriptEntry = makeEntry({
      id: 'w3',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys-CHANGED',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'the new message' }] }],
      }),
    })
    rerender({ entries: [...view, live] })
    // No "System Prompt" section pops up at the bottom of the session,
    // and the user's message still renders.
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(0)
    expect(result.current.some((m) => m.agentName.startsWith('You'))).toBe(true)
  })

  it('anchors the preamble when the first LLM request arrives after the opcode entries', () => {
    // A session that has not sent anything yet shows only the opcode
    // entries (SETUP_REPO). The first LLM request arrives later, appended
    // to the view — the preamble must anchor on it.
    const setup: TranscriptEntry[] = [
      makeEntry({
        id: 'op1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [],
          op: { name: 'SETUP_REPO' },
          result: { status: 'cloned', target: 'repo' },
        }),
      }),
    ]
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries, 's1'),
      { initialProps: { entries: setup } },
    )
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(0)

    const first: TranscriptEntry = makeEntry({
      id: 'llm1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      }),
    })
    rerender({ entries: [...setup, first] })
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
  })

  it('handles empty entries', () => {
    const { result } = renderHook(() => useTranscriptMessages([], 's1'))
    expect(result.current).toEqual([])
  })

  it('handles null sessionId', () => {
    const { result } = renderHook(() => useTranscriptMessages([], null))
    expect(result.current).toEqual([])
  })

  it('detects session change by sessionId even when first entry ids match', () => {
    // Regression: all sessions that clone the same repo share the same
    // first entry id (e.g., '1-setuprepo'). The renderer's session-change
    // detection used to compare firstEntryId, which failed to detect the
    // change. Fix: detect session changes by sessionId instead.
    const session1 = threeEntryTranscript()
    // Session 2 has the SAME first entry id as session 1 but different content.
    const session2: TranscriptEntry[] = [
      makeEntry({
        id: 'e1', // Same id as session1's first entry!
        direction: 'request',
        payload: JSON.stringify({
          system: 'Completely different system prompt.',
          messages: [{ role: 'user', content: [{ type: 'text', text: 'session 2 message' }] }],
        }),
      }),
      makeEntry({
        id: 'e2b',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'session 2 response' }] }),
      }),
    ]

    const { result, rerender } = renderHook(
      ({ entries, sid }) => useTranscriptMessages(entries, sid),
      { initialProps: { entries: session1, sid: 's1' } },
    )
    const s1Count = result.current.length
    expect(s1Count).toBeGreaterThan(0)

    // Switch to session 2 — same first entry id 'e1', but different session.
    // The renderer MUST detect the session change and reset its cache.
    rerender({ entries: session2, sid: 's2' })
    const expected = resolveRawJson(transcriptToMessages(session2))
    expect(resolveRawJson(result.current)).toEqual(expected)
  })
})
