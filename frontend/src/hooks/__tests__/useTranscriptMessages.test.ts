import { describe, it, expect } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useTranscriptMessages } from '../useTranscriptMessages'
import { transcriptToMessages } from '../../components/ChatArea'
import type { TranscriptEntry } from '../../types'
import type { Message } from '../../types'

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

describe('useTranscriptMessages', () => {
  it('produces the same result as transcriptToMessages for a full transcript', () => {
    const entries = threeEntryTranscript()
    const expected = resolveRawJson(transcriptToMessages(entries))
    const { result } = renderHook(() => useTranscriptMessages(entries))
    expect(resolveRawJson(result.current)).toEqual(expected)
  })

  it('produces the same result when entries are added incrementally', () => {
    const entries = threeEntryTranscript()
    const expected = resolveRawJson(transcriptToMessages(entries))

    // Start with first entry only.
    const { result, rerender } = renderHook(
      ({ entries }) => useTranscriptMessages(entries),
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
      ({ entries }) => useTranscriptMessages(entries),
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
      ({ entries }) => useTranscriptMessages(entries),
      { initialProps: { entries: [e1] } },
    )
    expect(result.current[0]!.blocks[0]!.text).toBe('partial')
    expect(result.current[0]!.streaming).toBe(true)

    // Replace e1 with the finalized version (same id, different reference).
    rerender({ entries: [e1Final] })
    expect(result.current[0]!.blocks[0]!.text).toBe('final text')
    expect(result.current[0]!.streaming).toBeUndefined()
  })

  it('resets cache on session change (different first entry id)', () => {
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
      ({ entries }) => useTranscriptMessages(entries),
      { initialProps: { entries: session1 } },
    )
    expect(result.current).toHaveLength(transcriptToMessages(session1).length)

    rerender({ entries: session2 })
    const expected = resolveRawJson(transcriptToMessages(session2))
    expect(resolveRawJson(result.current)).toEqual(expected)
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
    const { result } = renderHook(() => useTranscriptMessages(entries))
    expect(result.current.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
    expect(result.current.filter((m) => m.agentName === 'Tools')).toHaveLength(1)
  })

  it('handles empty entries', () => {
    const { result } = renderHook(() => useTranscriptMessages([]))
    expect(result.current).toEqual([])
  })
})
