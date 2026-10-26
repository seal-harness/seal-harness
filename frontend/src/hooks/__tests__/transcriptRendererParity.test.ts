/**
 * Transcript Renderer Parity Battery
 * ===================================
 *
 * The old renderer (`transcriptToMessages`) is a pure function: it takes
 * the full `TranscriptEntry[]` and produces `Message[]` in one pass. It
 * rendered every message into the DOM and kept them all there.
 *
 * The new efficient renderer (`useTranscriptMessages` + `useVirtualWindow`)
 * uses per-entry caching for incremental processing and DOM virtualization
 * to only render visible messages.
 *
 * The invariant: after the same transcript data and the same navigation
 * operations, both renderers display the exact same content. These tests
 * enforce that invariant by comparing `Message[]` output (data-layer
 * parity) and visible-window content after navigation (integration
 * parity).
 *
 * Any divergence between the two renderers is a bug in the new renderer.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useTranscriptMessages, _resetRendererCacheForTests } from '../useTranscriptMessages'
import { useVirtualWindow } from '../useVirtualWindow'
import { transcriptToMessages } from '../../components/ChatArea'
import type { TranscriptEntry, Message } from '../../types'

// ════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════

/** Resolve lazy rawJson provider functions to strings for deep-equal
 *  comparison. Functions can't be compared by toEqual. */
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

// ════════════════════════════════════════════════════════════════════════
// Parity assertion helpers
// ════════════════════════════════════════════════════════════════════════

/** Assert that useTranscriptMessages (incremental) produces the same
 *  Message[] as transcriptToMessages (pure function) when given the full
 *  transcript at once. */
function expectFullParity(entries: TranscriptEntry[], sessionId = 's1'): void {
  const expected = resolveRawJson(transcriptToMessages(entries))
  const { result } = renderHook(() => useTranscriptMessages(entries, sessionId))
  const actual = resolveRawJson(result.current)
  expect(actual).toEqual(expected)
}

/** Assert parity when entries arrive incrementally (one-by-one via WS).
 *  After each arrival, the intermediate output should match what the pure
 *  function produces for the partial transcript. */
function expectIncrementalParity(entries: TranscriptEntry[], sessionId = 's1'): void {
  if (entries.length === 0) {
    expectFullParity(entries, sessionId)
    return
  }

  const { result, rerender } = renderHook(
    ({ entries, sid }) => useTranscriptMessages(entries, sid),
    { initialProps: { entries: [entries[0]!], sid: sessionId } },
  )

  // Check parity at each intermediate step
  for (let i = 0; i < entries.length; i++) {
    if (i > 0) {
      rerender({ entries: entries.slice(0, i + 1), sid: sessionId })
    }
    const partial = entries.slice(0, i + 1)
    const expected = resolveRawJson(transcriptToMessages(partial))
    const actual = resolveRawJson(result.current)
    expect(actual).toEqual(expected)
  }
}

/** Assert parity when entries are re-fetched with new object references
 *  (same content, different identity). Simulates the real-world scenario
 *  where the frontend re-fetches the transcript seed via HTTP after
 *  sending a message. */
function expectRefetchParity(entries: TranscriptEntry[], sessionId = 's1'): void {
  const expected = resolveRawJson(transcriptToMessages(entries))

  // Initial render
  const { result, rerender } = renderHook(
    ({ entries, sid }) => useTranscriptMessages(entries, sid),
    { initialProps: { entries, sid: sessionId } },
  )

  // Re-fetch: same content, new object references
  const refetched = entries.map((e) => ({ ...e, payload: e.payload }))
  rerender({ entries: refetched, sid: sessionId })

  const actual = resolveRawJson(result.current)
  expect(actual).toEqual(expected)
}

// ════════════════════════════════════════════════════════════════════════
// Mock scroller for navigation tests
// ════════════════════════════════════════════════════════════════════════

type MockFn = ReturnType<typeof vi.fn>

function makeScroller(scrollHeight = 100000, clientHeight = 600, scrollTop = 0) {
  const addEventListenerMock: MockFn = vi.fn()
  const removeEventListenerMock: MockFn = vi.fn()
  const el = {
    scrollTop,
    scrollHeight,
    clientHeight,
    addEventListener: addEventListenerMock,
    removeEventListener: removeEventListenerMock,
  } as unknown as HTMLDivElement
  const ref = { current: el } as React.RefObject<HTMLDivElement>
  return { ref, el, addEventListenerMock, removeEventListenerMock }
}

function scrollTo(el: HTMLDivElement, addEventListenerMock: MockFn, scrollTop: number) {
  Object.defineProperty(el, 'scrollTop', { value: scrollTop, writable: true })
  const calls = addEventListenerMock.mock.calls
  const scrollCall = calls.find((c: unknown[]) => c[0] === 'scroll')
  if (scrollCall) {
    const listener = scrollCall[1] as () => void
    act(() => {
      listener()
      vi.advanceTimersByTime(16)
    })
  }
}

// ── Navigation operations ────────────────────────────────────────────────

interface NavState {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
  avgRowHeight: number
}

type NavOp =
  | { type: 'scrollToTop' }
  | { type: 'scrollToBottom' }
  | { type: 'arrowUp' }
  | { type: 'arrowDown' }
  | { type: 'pageUp' }
  | { type: 'pageDown' }
  | { type: 'scrollTo'; position: number }

function applyNavOp(state: NavState, op: NavOp): number {
  const maxScroll = state.scrollHeight - state.clientHeight
  switch (op.type) {
    case 'scrollToTop':
      return 0
    case 'scrollToBottom':
      return maxScroll
    case 'arrowUp':
      return Math.max(0, state.scrollTop - state.avgRowHeight)
    case 'arrowDown':
      return Math.min(maxScroll, state.scrollTop + state.avgRowHeight)
    case 'pageUp':
      return Math.max(0, state.scrollTop - state.clientHeight)
    case 'pageDown':
      return Math.min(maxScroll, state.scrollTop + state.clientHeight)
    case 'scrollTo':
      return Math.max(0, Math.min(maxScroll, op.position))
  }
}

// ════════════════════════════════════════════════════════════════════════
// Fixture builders
// ════════════════════════════════════════════════════════════════════════

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

/** A simple user → assistant conversation with N turns. */
function multiTurnConversation(turns: number): TranscriptEntry[] {
  const entries: TranscriptEntry[] = []
  for (let i = 0; i < turns; i++) {
    entries.push(
      makeEntry({
        id: `req-${i}`,
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          messages: [{ role: 'user', content: [{ type: 'text', text: `User message ${i}` }] }],
        }),
      }),
    )
    entries.push(
      makeEntry({
        id: `res-${i}`,
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({
          content: [{ type: 'text', text: `Assistant response ${i}` }],
          usage: { input_tokens: 100 + i, output_tokens: 50 + i },
        }),
      }),
    )
  }
  return entries
}

/** Conversation with a system prompt and tool definitions. */
function conversationWithSystemPromptAndTools(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 's1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'You are a coding assistant.',
        tools: [
          { name: 'shell', description: 'Run a shell command', input_schema: { type: 'object' } },
          { name: 'read', description: 'Read a file', input_schema: { type: 'object' } },
        ],
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      }),
    }),
    makeEntry({
      id: 's2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'Hello!' }] }),
    }),
  ]
}

/** Conversation with Ollama-style tool definitions. */
function conversationWithOllamaTools(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'o1',
      direction: 'request',
      payload: JSON.stringify({
        system: 'sys',
        tools: [
          { type: 'function', function: { name: 'web_search', description: 'Search the web', parameters: { type: 'object' } } },
        ],
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      }),
    }),
  ]
}

/** Conversation with multiple tool calls in a single response. */
function conversationWithMultipleToolCalls(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'm1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'read both files' }] }],
      }),
    }),
    makeEntry({
      id: 'm2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({
        content: [
          { type: 'text', text: 'Reading both files.' },
          { type: 'tool_use', id: 'tool-a', name: 'read', input: { path: 'a.txt' } },
          { type: 'tool_use', id: 'tool-b', name: 'read', input: { path: 'b.txt' } },
        ],
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
    }),
    makeEntry({
      id: 'm3',
      direction: 'request',
      payload: JSON.stringify({
        messages: [
          {
            role: 'user',
            content: [
              { type: 'tool_result', tool_use_id: 'tool-a', content: 'contents of a', is_error: false },
              { type: 'tool_result', tool_use_id: 'tool-b', content: 'contents of b', is_error: false },
            ],
          },
        ],
      }),
    }),
  ]
}

/** Conversation with a tool error result. */
function conversationWithToolError(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'err1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'run bad command' }] }],
      }),
    }),
    makeEntry({
      id: 'err2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({
        content: [
          { type: 'tool_use', id: 'tool-err', name: 'shell', input: { command: 'exit 1' } },
        ],
      }),
    }),
    makeEntry({
      id: 'err3',
      direction: 'request',
      payload: JSON.stringify({
        messages: [
          {
            role: 'user',
            content: [
              { type: 'tool_result', tool_use_id: 'tool-err', content: 'command failed [exit code: 1]', is_error: true },
            ],
          },
        ],
      }),
    }),
  ]
}

/** Conversation with a SETUP_REPO opcode entry. */
function conversationWithSetupRepo(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'repo1',
      direction: 'request',
      payload: JSON.stringify({
        messages: [],
        op: { name: 'SETUP_REPO' },
        input: { url: 'https://github.com/example/repo.git' },
        result: { status: 'cloned', target: 'repo' },
      }),
    }),
    makeEntry({
      id: 'repo2',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      }),
    }),
    makeEntry({
      id: 'repo3',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
    }),
  ]
}

/** Conversation with a SETUP_REPO that has a channel label. */
function conversationWithSetupRepoChannel(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'repo-ch',
      direction: 'request',
      channel: 'telegram',
      payload: JSON.stringify({
        messages: [],
        op: { name: 'SETUP_REPO' },
        input: { url: 'https://github.com/example/repo.git' },
        result: { status: 'noop', target: 'repo' },
      }),
    }),
  ]
}

/** Conversation with a SKILL_LOAD opcode entry (legacy). */
function conversationWithSkillLoad(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'sk1',
      direction: 'request',
      payload: JSON.stringify({
        messages: [],
        op: { name: 'SKILL_LOAD' },
        input: { id: 'my-skill' },
        result: { body: '# My Skill\nDo things.', description: 'A skill', id: 'my-skill' },
      }),
    }),
  ]
}

/** Conversation with a rejected approval entry. */
function conversationWithRejectedApproval(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'ap2',
      direction: 'request',
      payload: JSON.stringify({
        op: { name: 'FILE_WRITE' },
        approval: { scope: 'rejected' },
        messages: [],
      }),
    }),
  ]
}

/** Conversation with a streaming response entry. */
function conversationWithStreaming(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'st1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
      }),
    }),
    makeEntry({
      id: 'st2',
      direction: 'response',
      model: 'm',
      streaming: true,
      payload: JSON.stringify({ content: [{ type: 'text', text: 'partial' }] }),
    }),
  ]
}

/** Conversation with a non-JSON payload (harness send). */
function conversationWithNonJsonPayload(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'nj1',
      direction: 'request',
      payload: 'this is not json',
    }),
    makeEntry({
      id: 'nj2',
      direction: 'response',
      model: null,
      harness: 'my-harness',
      payload: 'raw response text',
    }),
  ]
}

/** Conversation with channel-labeled messages. */
function conversationWithChannelLabel(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'ch1',
      direction: 'request',
      channel: 'telegram',
      payload: JSON.stringify({
        model: 'm',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'from telegram' }] }],
      }),
    }),
    makeEntry({
      id: 'ch2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'reply' }] }),
    }),
  ]
}

/** Conversation with a preamble-only entry (system prompt + tools, no
 *  messages). The backend records this before the first user message. */
function conversationWithPreambleOnly(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'pre',
      direction: 'request',
      payload: JSON.stringify({
        system: 'sys',
        tools: [{ name: 'shell', description: 'sh', input_schema: {} }],
        messages: [],
      }),
    }),
    makeEntry({
      id: 'u1',
      direction: 'request',
      payload: JSON.stringify({
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
      }),
    }),
  ]
}

/** Conversation where the system prompt changes mid-session. The old
 *  renderer only renders the first system prompt; the new renderer
 *  should match. */
function conversationWithMidSessionSystemChange(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'msc1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys-A',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }],
      }),
    }),
    makeEntry({
      id: 'msc2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
    }),
    makeEntry({
      id: 'msc3',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys-B',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'second' }] }],
      }),
    }),
  ]
}

/** Conversation with an assistant role message in a request entry
 *  (reconstructed conversation history). */
function conversationWithAssistantInRequest(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'ar1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        system: 'sys',
        messages: [
          { role: 'user', content: [{ type: 'text', text: 'previous question' }] },
          { role: 'assistant', content: [{ type: 'text', text: 'previous answer' }] },
          { role: 'user', content: [{ type: 'text', text: 'new question' }] },
        ],
      }),
    }),
  ]
}

/** Conversation with a tool result containing an exit code. */
function conversationWithToolResultExitCode(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'ec1',
      direction: 'request',
      payload: JSON.stringify({
        model: 'm',
        messages: [{ role: 'user', content: [{ type: 'text', text: 'run command' }] }],
      }),
    }),
    makeEntry({
      id: 'ec2',
      direction: 'response',
      model: 'm',
      payload: JSON.stringify({
        content: [
          { type: 'tool_use', id: 'ec-tool', name: 'shell', input: { command: 'echo hello' } },
        ],
      }),
    }),
    makeEntry({
      id: 'ec3',
      direction: 'request',
      payload: JSON.stringify({
        messages: [
          {
            role: 'user',
            content: [
              { type: 'tool_result', tool_use_id: 'ec-tool', content: 'hello\n[exit code: 0]', is_error: false },
            ],
          },
        ],
      }),
    }),
  ]
}

/** Conversation with a response entry that has harness name but no model. */
function conversationWithHarnessFallback(): TranscriptEntry[] {
  return [
    makeEntry({
      id: 'hf1',
      direction: 'response',
      model: null,
      harness: 'custom-harness',
      payload: JSON.stringify({ content: [{ type: 'text', text: 'harness output' }] }),
    }),
  ]
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

beforeEach(() => {
  _resetRendererCacheForTests()
})

// ── Data-layer parity ────────────────────────────────────────────────────

describe('data-layer parity: useTranscriptMessages vs transcriptToMessages', () => {
  describe('basic conversations', () => {
    it('channel-labeled messages', () => {
      expectFullParity(conversationWithChannelLabel())
    })

    it('harness name fallback when model is null', () => {
      expectFullParity(conversationWithHarnessFallback())
    })

    it('assistant role in request entry (reconstructed history)', () => {
      expectFullParity(conversationWithAssistantInRequest())
    })
  })

  describe('tool calls', () => {
    it('multiple tool calls in one response', () => {
      expectFullParity(conversationWithMultipleToolCalls())
    })

    it('tool error result', () => {
      expectFullParity(conversationWithToolError())
    })

    it('tool result with exit code annotation', () => {
      expectFullParity(conversationWithToolResultExitCode())
    })

    it('tool result with array content (TrpText shape)', () => {
      expectFullParity([
        makeEntry({
          id: 'tc1',
          direction: 'response',
          model: 'm',
          payload: JSON.stringify({
            content: [{ type: 'tool_use', id: 'tc-tool', name: 'shell', input: { command: 'ls' } }],
          }),
        }),
        makeEntry({
          id: 'tc2',
          direction: 'request',
          payload: JSON.stringify({
            messages: [{
              role: 'user',
              content: [{
                type: 'tool_result',
                tool_use_id: 'tc-tool',
                content: [{ tag: 'TrpText', contents: 'legacy haskell shape' }],
                is_error: false,
              }],
            }],
          }),
        }),
      ])
    })
  })

  describe('system prompt and tools', () => {
    it('Ollama-style function wrapper tools', () => {
      expectFullParity(conversationWithOllamaTools())
    })

    it('preamble-only entry (empty messages array)', () => {
      expectFullParity(conversationWithPreambleOnly())
    })

    it('mid-session system prompt change renders only first prompt', () => {
      expectFullParity(conversationWithMidSessionSystemChange())
    })

    it('empty tools array does not emit Tools row', () => {
      expectFullParity([
        makeEntry({
          id: 'et1',
          direction: 'request',
          payload: JSON.stringify({
            system: 'sys',
            tools: [],
            messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
          }),
        }),
      ])
    })
  })

  describe('opcode entries', () => {
    it('SETUP_REPO with cloned status', () => {
      expectFullParity(conversationWithSetupRepo())
    })

    it('SETUP_REPO with noop status and channel label', () => {
      expectFullParity(conversationWithSetupRepoChannel())
    })

    it('SETUP_REPO with failed status', () => {
      expectFullParity([
        makeEntry({
          id: 'rf1',
          direction: 'request',
          payload: JSON.stringify({
            messages: [],
            op: { name: 'SETUP_REPO' },
            input: { url: 'https://example.com/repo.git' },
            result: { status: 'failed', target: 'repo' },
          }),
        }),
      ])
    })

    it('SKILL_LOAD (legacy opcode)', () => {
      expectFullParity(conversationWithSkillLoad())
    })

  })

  describe('approval entries', () => {
    it('rejected approval', () => {
      expectFullParity(conversationWithRejectedApproval())
    })
  })

  describe('streaming', () => {
    it('streaming response entry', () => {
      expectFullParity(conversationWithStreaming())
    })

  })

  describe('edge cases', () => {
    it('empty transcript', () => {
      expectFullParity([])
    })

    it('null sessionId', () => {
      const { result } = renderHook(() => useTranscriptMessages([], null))
      expect(result.current).toEqual([])
    })

    it('non-JSON request payload', () => {
      expectFullParity([
        makeEntry({
          id: 'nj1',
          direction: 'request',
          payload: 'not json at all',
        }),
      ])
    })

    it('non-JSON response payload', () => {
      expectFullParity([
        makeEntry({
          id: 'nj2',
          direction: 'response',
          harness: 'h',
          payload: 'raw text response',
        }),
      ])
    })

    it('non-JSON request and response payloads in the same transcript', () => {
      expectFullParity(conversationWithNonJsonPayload())
    })

    it('response with only thinking blocks (no text)', () => {
      expectFullParity([
        makeEntry({
          id: 'ot1',
          direction: 'response',
          model: 'm',
          payload: JSON.stringify({
            content: [{ type: 'thinking', thinking: 'just thinking' }],
          }),
        }),
      ])
    })

    it('request with empty messages array', () => {
      expectFullParity([
        makeEntry({
          id: 'em1',
          direction: 'request',
          payload: JSON.stringify({ model: 'm', messages: [] }),
        }),
      ])
    })

    it('payload as object (not string) — reconstructed path', () => {
      expectFullParity([
        makeEntry({
          id: 'obj1',
          direction: 'request',
          payload: {
            model: 'm',
            system: 'sys',
            messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
          } as unknown as string,
        }),
        makeEntry({
          id: 'obj2',
          direction: 'response',
          model: 'm',
          payload: { content: [{ type: 'text', text: 'hello' }] } as unknown as string,
        }),
      ])
    })
  })

  describe('incremental arrival', () => {
    it('three-entry transcript arriving one-by-one', () => {
      expectIncrementalParity(threeEntryTranscript())
    })

    it('multi-turn conversation arriving one-by-one', () => {
      expectIncrementalParity(multiTurnConversation(5))
    })

    it('tool call then result arriving incrementally', () => {
      const entries = threeEntryTranscript()
      // Tool call arrives before the result — verify the tool call
      // initially has no result, then gets matched when the result arrives
      const { result, rerender } = renderHook(
        ({ entries }) => useTranscriptMessages(entries, 's1'),
        { initialProps: { entries: [entries[0]!, entries[1]!] } },
      )

      // Before e3 arrives, the tool call in e2 has no result
      let asstRow = result.current.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
      let tcBlock = asstRow.blocks.find((b) => b.toolCall !== undefined)!
      expect(tcBlock.toolCall!.result).toBeUndefined()

      // After e3 arrives, the tool call should be matched
      rerender({ entries })
      const expected = resolveRawJson(transcriptToMessages(entries))
      expect(resolveRawJson(result.current)).toEqual(expected)
    })

    it('re-fetch with new object references preserves output', () => {
      expectRefetchParity(threeEntryTranscript())
    })

    it('re-fetch with new object references for system prompt', () => {
      expectRefetchParity(conversationWithSystemPromptAndTools())
    })

    it('streaming entry replaced by finalized version', () => {
      const streaming = makeEntry({
        id: 'sr1',
        direction: 'response',
        model: 'm',
        streaming: true,
        payload: JSON.stringify({ content: [{ type: 'text', text: 'partial' }] }),
      })
      const finalized = makeEntry({
        id: 'sr1',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'final text' }] }),
      })

      const { result, rerender } = renderHook(
        ({ entries }) => useTranscriptMessages(entries, 's1'),
        { initialProps: { entries: [streaming] } },
      )
      expect(result.current[0]!.blocks[0]!.text).toBe('partial')
      expect(result.current[0]!.streaming).toBe(true)

      rerender({ entries: [finalized] })
      expect(result.current[0]!.blocks[0]!.text).toBe('final text')
      expect(result.current[0]!.streaming).toBeUndefined()

      // Parity with pure function
      const expected = resolveRawJson(transcriptToMessages([finalized]))
      expect(resolveRawJson(result.current)).toEqual(expected)
    })
  })

  describe('session switching', () => {
    it('switch to a new session', () => {
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
      expect(resolveRawJson(result.current)).toEqual(resolveRawJson(transcriptToMessages(session1)))

      rerender({ entries: session2, sid: 's2' })
      expect(resolveRawJson(result.current)).toEqual(resolveRawJson(transcriptToMessages(session2)))
    })

    it('switch back to a previous session', () => {
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

      const { result, rerender } = renderHook(
        ({ entries, sid }) => useTranscriptMessages(entries, sid),
        { initialProps: { entries: session1, sid: 's1' } },
      )
      const s1Expected = resolveRawJson(transcriptToMessages(session1))

      rerender({ entries: session2, sid: 's2' })
      expect(resolveRawJson(result.current)).toEqual(resolveRawJson(transcriptToMessages(session2)))

      // Switch back
      rerender({ entries: session1, sid: 's1' })
      expect(resolveRawJson(result.current)).toEqual(s1Expected)
    })

    it('session change detected by sessionId even when first entry ids match', () => {
      const session1 = threeEntryTranscript()
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
      rerender({ entries: session2, sid: 's2' })
      expect(resolveRawJson(result.current)).toEqual(resolveRawJson(transcriptToMessages(session2)))
    })
  })

})

// ── Navigation-based integration parity ──────────────────────────────────

describe('navigation parity: visible content after scroll operations', () => {
  const AVG_ROW_HEIGHT = 120 // matches useVirtualWindow's ESTIMATED_ROW_HEIGHT
  const VIEWPORT_HEIGHT = 600
  const OVERSCAN = 50

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  /** Compute the expected visible range [startIndex, endIndex) for a
   *  given scroll position, matching useVirtualWindow's math. */
  function expectedVisibleRange(
    messageCount: number,
    scrollTop: number,
  ): [number, number] {
    const firstVisible = Math.max(0, Math.floor(scrollTop / AVG_ROW_HEIGHT) - OVERSCAN)
    const lastVisible = Math.min(
      messageCount,
      Math.ceil((scrollTop + VIEWPORT_HEIGHT) / AVG_ROW_HEIGHT) + OVERSCAN,
    )
    // Ensure at least MIN_RENDERED (100) messages
    const rangeSize = lastVisible - firstVisible
    const ensuredEnd = Math.min(messageCount, firstVisible + Math.max(rangeSize, 100))
    return [firstVisible, ensuredEnd]
  }

  /** Run a navigation sequence and verify that at each step, the visible
   *  messages from the incremental renderer match the pure function's
   *  messages at the same indices. */
  function expectNavigationParity(
    entries: TranscriptEntry[],
    navSequence: NavOp[],
    sessionId = 's1',
  ): void {
    // Get reference messages from the pure function
    const refMessages = resolveRawJson(transcriptToMessages(entries))

    // Get messages from the incremental renderer
    const { result: msgResult } = renderHook(() =>
      useTranscriptMessages(entries, sessionId),
    )
    const virtMessages = resolveRawJson(msgResult.current)

    // Data parity is a prerequisite
    expect(virtMessages).toEqual(refMessages)

    const messageCount = virtMessages.length
    const scrollHeight = messageCount * AVG_ROW_HEIGHT

    // Set up virtual window with mocked scroller
    const { ref: scrollerRef, el, addEventListenerMock } = makeScroller(
      scrollHeight, VIEWPORT_HEIGHT, scrollHeight - VIEWPORT_HEIGHT,
    )
    const { result: vwResult } = renderHook(() =>
      useVirtualWindow(messageCount, scrollerRef, sessionId),
    )

    let currentScroll = el.scrollTop

    for (const op of navSequence) {
      const state: NavState = {
        scrollTop: currentScroll,
        scrollHeight,
        clientHeight: VIEWPORT_HEIGHT,
        avgRowHeight: AVG_ROW_HEIGHT,
      }
      const newScrollTop = applyNavOp(state, op)
      currentScroll = newScrollTop

      // Apply the scroll to the mocked scroller
      scrollTo(el, addEventListenerMock, newScrollTop)

      // Get the virtual window's visible range
      const { startIndex, endIndex } = vwResult.current

      // Compute expected visible range
      const [expectedStart, expectedEnd] = expectedVisibleRange(messageCount, newScrollTop)

      // The virtual window should match the expected range
      // (Note: useVirtualWindow may have a slightly different range due
      // to measurement feedback, but in jsdom with no real offsetHeight,
      // avgRowHeight stays at 120 and the math is deterministic.)
      expect(startIndex).toBe(expectedStart)
      expect(endIndex).toBe(expectedEnd)

      // The visible messages from both renderers should match
      const refSlice = refMessages.slice(startIndex, endIndex)
      const virtSlice = virtMessages.slice(startIndex, endIndex)
      expect(virtSlice).toEqual(refSlice)

      // Verify message IDs are in the rendered set
      const visibleIds = virtSlice.map((m) => m.id)
      expect(visibleIds).toEqual(refMessages.slice(startIndex, endIndex).map((m) => m.id))
    }
  }

  it('navigation on small transcript (below virtualization threshold)', () => {
    // Small transcript — all messages should be rendered, no spacers
    const entries = multiTurnConversation(10) // 20 messages
    expectNavigationParity(entries, [
      { type: 'scrollToTop' },
      { type: 'scrollToBottom' },
    ])
  })

})

// ── The single property test ─────────────────────────────────────────────
//
// This is the most important test in the battery. It generates random
// sequences of navigation actions, applies them to BOTH the pure-function
// renderer (transcriptToMessages) and the efficient renderer
// (useTranscriptMessages + useVirtualWindow), and asserts that after
// every single navigation step the visible content is identical.
//
// The invariant: for ANY sequence of navigation operations, the messages
// visible in the viewport are the same for both renderers — same IDs,
// same agent names, same block content, in the same order.

describe('property: visible content matches after any navigation sequence', () => {
  const AVG_ROW_HEIGHT = 120
  const VIEWPORT_HEIGHT = 600
  const OVERSCAN = 50
  const MIN_RENDERED = 100

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  /** Seeded linear congruential RNG — deterministic, reproducible. */
  function makeRng(seed: number): () => number {
    let s = seed
    return () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff
      return s / 0x7fffffff
    }
  }

  const NAV_OPS = ['scrollToTop', 'scrollToBottom', 'arrowUp', 'arrowDown', 'pageUp', 'pageDown', 'scrollTo'] as const

  function randomNavOp(rand: () => number, maxScroll: number): NavOp {
    const choice = NAV_OPS[Math.floor(rand() * NAV_OPS.length)]!
    if (choice === 'scrollTo') {
      return { type: 'scrollTo', position: Math.floor(rand() * maxScroll) }
    }
    return { type: choice }
  }

  /** Build a diverse transcript that exercises all renderer code paths:
   *  system prompt, tools, tool calls, thinking, multi-turn conversation,
   *  streaming, approvals, opcodes. */
  /** Build a diverse transcript that exercises all renderer code paths:
   *  system prompt, tools, tool calls, thinking, multi-turn conversation,
   *  streaming, approvals, opcodes, internal entries, max_tokens. */
  function diverseTranscript(count: number): TranscriptEntry[] {
    const entries: TranscriptEntry[] = []
    // System prompt + tools on the first entry
    entries.push(
      makeEntry({
        id: 'div-0',
        direction: 'request',
        payload: JSON.stringify({
          model: 'm',
          system: 'You are a helpful assistant.',
          tools: [
            { name: 'shell', description: 'Run a shell command', input_schema: { type: 'object' } },
            { name: 'read', description: 'Read a file', input_schema: { type: 'object' } },
          ],
          messages: [{ role: 'user', content: [{ type: 'text', text: 'start' }] }],
        }),
      }),
    )
    // First response with thinking + text + tool call
    entries.push(
      makeEntry({
        id: 'div-1',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({
          content: [
            { type: 'thinking', thinking: 'Let me think about this.' },
            { type: 'text', text: 'I will run a command.' },
            { type: 'tool_use', id: 'div-tool-1', name: 'shell', input: { command: 'ls' } },
          ],
          usage: { input_tokens: 10, output_tokens: 20 },
        }),
      }),
    )
    // Tool result
    entries.push(
      makeEntry({
        id: 'div-2',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{
            role: 'user',
            content: [{ type: 'tool_result', tool_use_id: 'div-tool-1', content: 'file.txt', is_error: false }],
          }],
        }),
      }),
    )
    // Internal (harness-synthetic) entry — old renderer skips, new doesn't
    entries.push(
      makeEntry({
        id: 'div-int',
        direction: 'request',
        internal: true,
        payload: JSON.stringify({
          model: 'm',
          messages: [{ role: 'user', content: [{ type: 'text', text: '[continuation]' }] }],
        }),
      }),
    )
    // SKILL_MANAGE with action=load — old renderer treats as skill load
    entries.push(
      makeEntry({
        id: 'div-skm',
        direction: 'request',
        payload: JSON.stringify({
          messages: [],
          op: { name: 'SKILL_MANAGE' },
          input: { action: 'load', id: 'skill-x' },
          result: { body: '# Skill X', description: 'A skill', id: 'skill-x' },
        }),
      }),
    )
    // Approval entry (approved)
    entries.push(
      makeEntry({
        id: 'div-appr',
        direction: 'request',
        payload: JSON.stringify({
          op: { name: 'SHELL_EXEC' },
          approval: { scope: 'session' },
          messages: [],
        }),
      }),
    )
    // Response with max_tokens stop reason and empty content
    entries.push(
      makeEntry({
        id: 'div-mt',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [], stop: 'max_tokens' }),
      }),
    )
    // Fill the rest with alternating user/assistant turns
    for (let i = 3; i < count; i++) {
      if (i % 2 === 1) {
        entries.push(
          makeEntry({
            id: `div-${i}`,
            direction: 'response',
            model: 'm',
            payload: JSON.stringify({
              content: [{ type: 'text', text: `Response ${Math.floor(i / 2)}` }],
              usage: { input_tokens: 100, output_tokens: 50 },
            }),
          }),
        )
      } else {
        entries.push(
          makeEntry({
            id: `div-${i}`,
            direction: 'request',
            payload: JSON.stringify({
              model: 'm',
              messages: [{ role: 'user', content: [{ type: 'text', text: `User message ${Math.floor(i / 2)}` }] }],
            }),
          }),
        )
      }
    }
    return entries
  }

  it('for any random navigation sequence, visible content is identical between renderers', () => {
    const rand = makeRng(42)
    const entries = diverseTranscript(2000)

    // ── Reference: pure function renderer ──
    const refMessages = resolveRawJson(transcriptToMessages(entries))

    // ── Efficient: incremental renderer + virtual window ──
    const { result: msgResult } = renderHook(() =>
      useTranscriptMessages(entries, 's1'),
    )
    const virtMessages = resolveRawJson(msgResult.current)

    // Data parity is a hard precondition — if the Message[] arrays
    // differ, every visible comparison is meaningless.
    expect(virtMessages).toEqual(refMessages)

    const messageCount = virtMessages.length
    const scrollHeight = messageCount * AVG_ROW_HEIGHT
    const maxScroll = scrollHeight - VIEWPORT_HEIGHT

    // Set up the virtual window with a mocked scroller at the bottom
    const { ref: scrollerRef, el, addEventListenerMock } = makeScroller(
      scrollHeight, VIEWPORT_HEIGHT, maxScroll,
    )
    const { result: vwResult } = renderHook(() =>
      useVirtualWindow(messageCount, scrollerRef, 's1'),
    )

    // ── Run many random navigation sequences ──
    const NUM_SEQUENCES = 300
    const MAX_STEPS_PER_SEQ = 25
    let currentScroll = maxScroll

    for (let seq = 0; seq < NUM_SEQUENCES; seq++) {
      const steps = Math.floor(rand() * MAX_STEPS_PER_SEQ) + 1
      for (let step = 0; step < steps; step++) {
        // Generate and apply a random navigation action
        const op = randomNavOp(rand, maxScroll)
        const state: NavState = {
          scrollTop: currentScroll,
          scrollHeight,
          clientHeight: VIEWPORT_HEIGHT,
          avgRowHeight: AVG_ROW_HEIGHT,
        }
        currentScroll = applyNavOp(state, op)
        scrollTo(el, addEventListenerMock, currentScroll)

        // ── Compute the "visible range": what the user actually sees ──
        // This is the ground truth — messages whose position falls
        // within [scrollTop, scrollTop + viewportHeight].
        const visibleStart = Math.max(0, Math.floor(currentScroll / AVG_ROW_HEIGHT))
        const visibleEnd = Math.min(
          messageCount,
          Math.ceil((currentScroll + VIEWPORT_HEIGHT) / AVG_ROW_HEIGHT),
        )

        // ── Virtual window's rendered range ──
        const { startIndex, endIndex } = vwResult.current

        // Property 1: the virtual window MUST cover the visible range.
        // If it doesn't, the user would see missing messages or
        // spacers where content should be.
        expect(startIndex).toBeLessThanOrEqual(visibleStart)
        expect(endIndex).toBeGreaterThanOrEqual(visibleEnd)

        // Property 1b: the window MUST also cover the overscan buffer
        // on both sides — that buffer is what keeps scrolling from
        // showing blank rows between a scroll event and the next
        // range update.
        expect(startIndex).toBeLessThanOrEqual(Math.max(0, visibleStart - OVERSCAN))
        expect(endIndex).toBeGreaterThanOrEqual(Math.min(messageCount, visibleEnd + OVERSCAN))

        // Property 2: the visible content from both renderers must be
        // identical — same messages at the same indices.
        for (let i = visibleStart; i < visibleEnd; i++) {
          expect(virtMessages[i]).toEqual(refMessages[i])
        }

        // Property 3: the virtual window's overscan is within bounds.
        expect(startIndex).toBeGreaterThanOrEqual(0)
        expect(endIndex).toBeLessThanOrEqual(messageCount)

        // Property 4: the window renders at least MIN_RENDERED
        // messages, bounded by what is left in the transcript.
        expect(endIndex - startIndex).toBeGreaterThanOrEqual(
          Math.min(MIN_RENDERED, messageCount - startIndex),
        )
      }
    }
  })
})
