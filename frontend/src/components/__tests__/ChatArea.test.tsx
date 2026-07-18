import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { ChatArea, transcriptToMessages, computeTokensUsed, providerFromRuntime } from '../ChatArea'
import type { Agent, Message, SessionInfo, ToolCallInfo, TranscriptEntry } from '../../types'

// ── Helpers ────────────────────────────────────────────────────────────────

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    id: 'agent-1',
    name: 'Seal',
    status: 'idle',
    tokenCount: '0',
    ...overrides,
  }
}

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
    payload: '{}',
    harness: null,
    model: null,
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
      raw: JSON.stringify({
        _te_id: 'e1',
        _te_direction: 'request',
        _te_payload: '…',
        _te_timestamp: '2024-06-01T12:00:00Z',
      }),
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
      raw: JSON.stringify({ _te_id: 'e2', _te_direction: 'response' }),
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
      raw: JSON.stringify({ _te_id: 'e3', _te_direction: 'request' }),
    }),
  ]
}

beforeEach(() => {
  cleanup()
  if (typeof window !== 'undefined' && window.location.hash !== '') {
    window.history.replaceState(null, '', window.location.pathname)
  }
})

// ── transcriptToMessages ────────────────────────────────────────────────────

describe('transcriptToMessages', () => {
  it('maps a TranscriptEntry[] to Message[] — text block, system prompt, tool call matched with result', () => {
    const msgs = transcriptToMessages(threeEntryTranscript())
    // Expect: System row, user row (e1), assistant row with tool call (e2), then
    // e3's request carries the tool_result but its last message is a user with
    // a tool_result content (no text) — so no user-text row for e3.
    const agents = msgs.map((m) => m.agentName)
    expect(agents).toContain('System')
    expect(agents).toContain('You')
    expect(agents).toContain('claude-sonnet-4-20250514')

    // The assistant row carries a tool_call block whose result is matched.
    const asst = msgs.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
    expect(asst).toBeTruthy()
    const tcBlock = asst.blocks.find((b) => b.toolCall !== undefined)
    expect(tcBlock).toBeTruthy()
    expect(tcBlock!.toolCall!.name).toBe('shell')
    expect(tcBlock!.toolCall!.result).toBe('file_a.txt\nfile_b.txt')
    expect(tcBlock!.toolCall!.resultIsError).toBe(false)
  })

  it('emits a Tools row from parsed.tools with names + count + full JSON', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 't1',
        direction: 'request',
        payload: JSON.stringify({
          system: 'sys',
          tools: [
            { name: 'shell', description: 'run a shell command', input_schema: { type: 'object' } },
            { name: 'read', description: 'read a file', input_schema: { type: 'object' } },
          ],
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const toolsRow = msgs.find((m) => m.agentName === 'Tools')
    expect(toolsRow).toBeTruthy()
    const block = toolsRow!.blocks.find((b) => b.toolDefs !== undefined)!
    expect(block).toBeTruthy()
    expect(block.toolDefs!.count).toBe(2)
    expect(block.toolDefs!.names).toEqual(['shell', 'read'])
    // Full JSON carries both tool definitions.
    const parsed = JSON.parse(block.toolDefs!.json)
    expect(Array.isArray(parsed)).toBe(true)
    expect(parsed).toHaveLength(2)
    expect(parsed[0]!.name).toBe('shell')
  })

  it('emits a Tools row from Anthropic wire shape ({name, input_schema})', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'a1',
        direction: 'request',
        payload: JSON.stringify({
          tools: [
            { name: 'shell', description: 'sh', input_schema: { type: 'object' } },
          ],
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const toolsRow = msgs.find((m) => m.agentName === 'Tools')
    expect(toolsRow).toBeTruthy()
    const block = toolsRow!.blocks.find((b) => b.toolDefs !== undefined)!
    expect(block.toolDefs!.names).toEqual(['shell'])
  })

  it('emits a Tools row from Ollama-style function wrappers', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'o1',
        direction: 'request',
        payload: JSON.stringify({
          tools: [
            { type: 'function', function: { name: 'web_search', description: 'search the web', parameters: { type: 'object' } } },
          ],
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const toolsRow = msgs.find((m) => m.agentName === 'Tools')
    expect(toolsRow).toBeTruthy()
    const block = toolsRow!.blocks.find((b) => b.toolDefs !== undefined)!
    expect(block.toolDefs!.names).toEqual(['web_search'])
  })

  it('emits a Tools row only once per unique tool set', () => {
    const tools = [{ name: 'shell', description: 'sh', input_schema: {} }]
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'd1',
        direction: 'request',
        payload: JSON.stringify({ tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }] }),
        raw: '{}',
      }),
      makeEntry({
        id: 'd2',
        direction: 'response',
        model: 'm',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }),
        raw: '{}',
      }),
      makeEntry({
        id: 'd3',
        direction: 'request',
        payload: JSON.stringify({ tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'second' }] }] }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const toolsRows = msgs.filter((m) => m.agentName === 'Tools')
    expect(toolsRows).toHaveLength(1)
  })

  it('omits a Tools row when tools array is empty or absent', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'e1',
        direction: 'request',
        payload: JSON.stringify({ messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }] }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.find((m) => m.agentName === 'Tools')).toBeUndefined()
  })

  it('emits a text block for a plain user message', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'u1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi there' }] }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const userRow = msgs.find((m) => m.agentName === 'You')
    expect(userRow).toBeTruthy()
    expect(userRow!.blocks[0]!.text).toBe('hi there')
  })

  it('carries the verbatim raw json through to the row', () => {
    const raw = '{"_te_id":"e1","_te_payload":"abc"}'
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'u1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
        }),
        raw,
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const userRow = msgs.find((m) => m.agentName === 'You')
    expect(userRow).toBeTruthy()
    expect(userRow!.rawJson).toBe(raw)
    expect(userRow!.entryId).toBe('u1')
  })

  it('flags streaming on response rows when the entry is streaming', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'r1',
        direction: 'response',
        model: 'claude-sonnet-4-20250514',
        streaming: true,
        payload: JSON.stringify({
          content: [{ type: 'text', text: 'partial' }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs[0]!.streaming).toBe(true)
  })

  it('matches tool calls with tool_results that appear in response entries (two-file reconstruct path)', () => {
    // In the two-file format, tool_results appear in the NEXT response entry's
    // reconstructed content (concatMap of assistant + result messages), not in
    // a separate request entry. This test verifies buildToolResultIndex scans
    // response entries too.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'e1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'list files' }] }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e2',
        direction: 'response',
        model: 'claude-sonnet-4-20250514',
        payload: JSON.stringify({
          content: [{ type: 'tool_use', id: 'tool-1', name: 'shell', input: { command: 'ls' } }],
        }),
        raw: '{}',
      }),
      // The next response entry's reconstructed content includes BOTH the
      // prior assistant's tool_use AND the user's tool_result (concatMap).
      makeEntry({
        id: 'e3',
        direction: 'response',
        model: 'claude-sonnet-4-20250514',
        payload: JSON.stringify({
          content: [
            { type: 'tool_use', id: 'tool-1', name: 'shell', input: { command: 'ls' } },
            { type: 'tool_result', tool_use_id: 'tool-1', content: [{ type: 'text', text: 'file_a.txt' }], is_error: false },
          ],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    // The assistant row from e2 should have its tool call matched with the
    // tool_result from e3.
    const asst = msgs.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
    expect(asst).toBeTruthy()
    const tcBlock = asst.blocks.find((b) => b.toolCall !== undefined)
    expect(tcBlock).toBeTruthy()
    expect(tcBlock!.toolCall!.result).toBe('file_a.txt')
    expect(tcBlock!.toolCall!.resultIsError).toBe(false)
  })

  it('parses exit code from tool result text and sets exitCode on ToolCallInfo', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'e1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'run cmd' }] }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e2',
        direction: 'response',
        model: 'claude-sonnet-4-20250514',
        payload: JSON.stringify({
          content: [{ type: 'tool_use', id: 'tool-1', name: 'shell', input: { command: 'false' } }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e3',
        direction: 'response',
        model: 'claude-sonnet-4-20250514',
        payload: JSON.stringify({
          content: [
            { type: 'tool_use', id: 'tool-1', name: 'shell', input: { command: 'false' } },
            { type: 'tool_result', tool_use_id: 'tool-1', content: [{ type: 'text', text: 'error output\n[exit code: 1]' }], is_error: false },
          ],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const asst = msgs.find((m) => m.agentName === 'claude-sonnet-4-20250514')!
    const tcBlock = asst.blocks.find((b) => b.toolCall !== undefined)!
    expect(tcBlock.toolCall!.exitCode).toBe(1)
    expect(tcBlock.toolCall!.result).toContain('[exit code: 1]')
  })

  it('matches tool calls with unique ids across multiple responses (no id collision)', () => {
    // Simulates the Ollama fix: each response gets globally unique tool_call
    // ids (call_0, call_1, ...) instead of restarting at call_0 each turn.
    // Without unique ids, the tool_result for call_0 in turn 2 would
    // overwrite the tool_result for call_0 in turn 1.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'e1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'list files' }] }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e2',
        direction: 'response',
        model: 'ollama',
        payload: JSON.stringify({
          content: [{ type: 'tool_use', id: 'call_0', name: 'shell', input: { command: 'ls' } }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e3',
        direction: 'response',
        model: 'ollama',
        payload: JSON.stringify({
          content: [
            { type: 'tool_use', id: 'call_0', name: 'shell', input: { command: 'ls' } },
            { type: 'tool_result', tool_use_id: 'call_0', content: [{ type: 'text', text: 'file_a.txt' }], is_error: false },
          ],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e4',
        direction: 'response',
        model: 'ollama',
        payload: JSON.stringify({
          content: [{ type: 'tool_use', id: 'call_1', name: 'shell', input: { command: 'uname' } }],
        }),
        raw: '{}',
      }),
      makeEntry({
        id: 'e5',
        direction: 'response',
        model: 'ollama',
        payload: JSON.stringify({
          content: [
            { type: 'tool_use', id: 'call_1', name: 'shell', input: { command: 'uname' } },
            { type: 'tool_result', tool_use_id: 'call_1', content: [{ type: 'text', text: 'Linux' }], is_error: false },
          ],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    // Find the tool call blocks for call_0 and call_1 across all messages.
    // With unique ids, call_0's result should be 'file_a.txt' and call_1's
    // result should be 'Linux' — no collision.
    const allToolCalls = msgs.flatMap((m) => m.blocks).filter((b) => b.toolCall !== undefined) as Array<{ toolCall: ToolCallInfo }>
    const call0 = allToolCalls.find((b) => b.toolCall.id === 'call_0')!
    const call1 = allToolCalls.find((b) => b.toolCall.id === 'call_1')!
    expect(call0).toBeTruthy()
    expect(call1).toBeTruthy()
    expect(call0.toolCall.result).toBe('file_a.txt')
    expect(call1.toolCall.result).toBe('Linux')
  })
})

// ── ChatArea rendering ──────────────────────────────────────────────────────

describe('ChatArea', () => {
  it('renders a 3-message transcript (user / assistant-with-tool-call / system)', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        agentName: 'System',
        agentStatus: 'idle',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', collapsedText: 'You are a helpful assistant.' }],
      },
      {
        id: 'm2',
        entryId: 'e1',
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:01',
        blocks: [{ id: 'b2', text: 'Hello, please list files.' }],
        rawJson: '{"_te_id":"e1"}',
      },
      {
        id: 'm3',
        entryId: 'e2',
        agentName: 'claude-sonnet-4-20250514',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:02',
        blocks: [
          { id: 'b3', text: 'Let me list the files.' },
          {
            id: 'b4',
            toolCall: {
              id: 'tool-1',
              name: 'shell',
              input: { command: 'ls' },
              result: 'file_a.txt',
              resultIsError: false,
            },
          },
        ],
        rawJson: '{"_te_id":"e2"}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
      />,
    )
    expect(screen.getByText('Hello, please list files.')).toBeTruthy()
    expect(screen.getByText('Let me list the files.')).toBeTruthy()
    // The tool call name appears in the collapsed header.
    expect(screen.getByText('shell')).toBeTruthy()
    // System row collapses by default but is present in the DOM.
    expect(document.querySelector('.addressable-block')).toBeTruthy()
  })

  it('shows an "exit 0" pill for a tool call with exit code 0', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'claude-sonnet-4-20250514',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{
          id: 'b1',
          toolCall: {
            id: 'tool-1',
            name: 'shell',
            input: { command: 'ls' },
            result: 'file_a.txt\n[exit code: 0]',
            resultIsError: false,
            exitCode: 0,
          },
        }],
        rawJson: '{}',
      },
    ]
    render(<ChatArea selectedAgent={makeAgent()} messages={messages} />)
    expect(screen.getByText('exit 0')).toBeTruthy()
  })

  it('shows an "exit N" error pill for a tool call with non-zero exit code', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'claude-sonnet-4-20250514',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{
          id: 'b1',
          toolCall: {
            id: 'tool-1',
            name: 'shell',
            input: { command: 'false' },
            result: 'error output\n[exit code: 1]',
            resultIsError: false,
            exitCode: 1,
          },
        }],
        rawJson: '{}',
      },
    ]
    render(<ChatArea selectedAgent={makeAgent()} messages={messages} />)
    expect(screen.getByText('exit 1')).toBeTruthy()
  })

  it('branch-from-here on a user row triggers the composer callback with the entry id', () => {
    const onBranch = vi.fn()
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', text: 'branch me' }],
        rawJson: '{}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        onBranch={onBranch}
      />,
    )
    const branchBtn = screen.getByLabelText('branch session from here')
    fireEvent.click(branchBtn)
    expect(onBranch).toHaveBeenCalledWith('e1')
  })

  it('raw JSON modal toggles open/closed', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', text: 'open the json modal' }],
        rawJson: '{"hello":"world"}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
      />,
    )
    // Modal not present initially.
    expect(screen.queryByTestId('raw-json-modal')).toBeNull()
    // Click the "View raw JSON (message)" button.
    fireEvent.click(screen.getByLabelText('View raw JSON (message)'))
    expect(screen.getByTestId('raw-json-modal')).toBeTruthy()
    expect(screen.getByTestId('raw-json-backdrop')).toBeTruthy()
    // Close via the close button.
    fireEvent.click(screen.getByLabelText('Close raw JSON view'))
    expect(screen.queryByTestId('raw-json-modal')).toBeNull()
  })

  it('slash bubble renders transiently with the "command output — not saved" label', () => {
    const messages: Message[] = [
      {
        id: 'slash-1',
        agentName: 'Seal',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        slashBubble: true,
        blocks: [{ id: 'b1', text: '/help output here' }],
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
      />,
    )
    expect(screen.getByTestId('slash-bubble')).toBeTruthy()
    // The em-dash in the source is rendered as the HTML entity &mdash; in the
    // markup; match against the visible text.
    expect(screen.getByText(/command output/)).toBeTruthy()
    expect(screen.getByText(/not saved/)).toBeTruthy()
  })

  it('per-session model dropdown change calls the provided onModelChange', () => {
    const onModelChange = vi.fn()
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', text: 'hi' }],
        rawJson: '{}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        currentModel="claude-sonnet-4-20250514"
        availableModels={['claude-sonnet-4-20250514', 'claude-opus-4-20250514']}
        onModelChange={onModelChange}
      />,
    )
    const select = screen.getByLabelText('session model')
    expect(select).toBeTruthy()
    fireEvent.change(select, { target: { value: 'claude-opus-4-20250514' } })
    expect(onModelChange).toHaveBeenCalledWith('claude-opus-4-20250514')
  })

  it('in-place description edit calls setSessionDescription', () => {
    const onSetDescription = vi.fn()
    const session = makeSession({ id: 's1', description: 'Old title' })
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'You',
        agentStatus: 'completed',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', text: 'hi' }],
        rawJson: '{}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        selectedSession={session}
        onSetDescription={onSetDescription}
        messages={messages}
      />,
    )
    // Click the title to enter edit mode.
    fireEvent.click(screen.getByTitle('Click to set a session title'))
    const input = screen.getByLabelText('Session title') as HTMLInputElement
    expect(input.value).toBe('Old title')
    // Type a new title + commit with Enter.
    fireEvent.change(input, { target: { value: 'New title' } })
    fireEvent.keyDown(input, { key: 'Enter', preventDefault: () => {} })
    expect(onSetDescription).toHaveBeenCalledWith('s1', 'New title')
  })

  it('TypingIndicator renders when a message isGenerating or streaming', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        entryId: 'e1',
        agentName: 'claude-sonnet-4-20250514',
        agentStatus: 'thinking',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', text: 'thinking…' }],
        isGenerating: true,
        streaming: true,
      },
    ]
    const { container } = render(
      <ChatArea
        selectedAgent={makeAgent({ status: 'thinking' })}
        messages={messages}
      />,
    )
    // The typing indicator renders three .typing-dot elements.
    const dots = container.querySelectorAll('.typing-dot')
    expect(dots.length).toBe(3)
  })

  it('renders the BottomBar with the supplied token stats', () => {
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        tokensUsed={5000}
        contextWindow={200000}
        sessionStart="2024-01-01T00:00:00Z"
      />,
    )
    // BottomBar shows the token count and the percentage.
    expect(screen.getByText(/5k/)).toBeTruthy()
    expect(screen.getByText(/200k/)).toBeTruthy()
  })

  it('renders a collapsed Tools row showing count + names, expandable to full JSON', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        agentName: 'Tools',
        agentStatus: 'idle',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{
          id: 'b1',
          toolDefs: {
            count: 2,
            names: ['shell', 'read'],
            json: JSON.stringify([
              { name: 'shell', description: 'sh', input_schema: {} },
              { name: 'read', description: 'rd', input_schema: {} },
            ], null, 2),
          },
        }],
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
      />,
    )
    // Collapsed header shows count + names.
    expect(screen.getByText(/2 tools:.*shell.*read/)).toBeTruthy()
    // The full JSON is NOT visible while collapsed.
    expect(screen.queryByText('"input_schema"')).toBeNull()
    // Click to expand.
    fireEvent.click(screen.getByText(/2 tools:/))
    // Now the full JSON renders inside a <pre>.
    const pre = document.querySelector('pre')
    expect(pre).toBeTruthy()
    expect(pre!.textContent).toContain('"input_schema"')
    expect(pre!.textContent).toContain('"shell"')
  })

  it('renders the empty-state message when there are no messages and no setup props', () => {
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
      />,
    )
    expect(screen.getByText(/No messages yet/)).toBeTruthy()
  })

  it('does NOT render any reference product name', () => {
    const { container } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
      />,
    )
    expect(container.textContent).not.toMatch(/pureclaw/i)
  })
})

// ── computeTokensUsed + providerFromRuntime ──────────────────────────────────

describe('computeTokensUsed', () => {
  it('returns real usage (last input_tokens + cumulative output_tokens) when present', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'r1',
        direction: 'response',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'hi' }], usage: { input_tokens: 100, output_tokens: 20 } }),
      }),
      makeEntry({
        id: 'r2',
        direction: 'response',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'hi2' }], usage: { input_tokens: 150, output_tokens: 30 } }),
      }),
    ]
    // last input (150) + cumulative output (20+30=50) = 200
    expect(computeTokensUsed(entries)).toBe(200)
  })

  it('falls back to a 4-char-per-token estimate when no usage is present', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'u1',
        direction: 'request',
        payload: 'a'.repeat(40), // 10 tokens
      }),
      makeEntry({
        id: 'r1',
        direction: 'response',
        payload: JSON.stringify({ content: [{ type: 'text', text: 'b'.repeat(40) }] }), // 10 tokens
      }),
    ]
    // Non-JSON request payload contributes ceil(40/4)=10 to estimatedTokens;
    // the response's text block contributes ceil(40/4)=10; the fallback then
    // adds the last-request-payload estimate (ceil(40/4)=10). Total = 30.
    expect(computeTokensUsed(entries)).toBe(30)
  })
})

describe('providerFromRuntime', () => {
  it('extracts the provider from a "session:<provider>" runtime string', () => {
    expect(providerFromRuntime('session:anthropic')).toBe('anthropic')
    expect(providerFromRuntime('session:openai')).toBe('openai')
  })
  it('returns null for a runtime string not in the expected shape', () => {
    expect(providerFromRuntime('harness')).toBeNull()
    expect(providerFromRuntime(undefined)).toBeNull()
  })
})