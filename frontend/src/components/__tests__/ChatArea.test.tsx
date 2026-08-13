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
    lastUserMessageAt: null,
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
    expect(agents).toContain('System Prompt')
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

  it('emits a Tools row with names + descriptions + JSON separate from System', () => {
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
    const sysRow = msgs.find((m) => m.agentName === 'System Prompt')
    expect(sysRow).toBeTruthy()
    expect(sysRow!.blocks.find((b) => b.toolDefs !== undefined)).toBeUndefined()
    const toolsRow = msgs.find((m) => m.agentName === 'Tools')
    expect(toolsRow).toBeTruthy()
    const block = toolsRow!.blocks.find((b) => b.toolDefs !== undefined)!
    expect(block).toBeTruthy()
    expect(block.toolDefs!.count).toBe(2)
    expect(block.toolDefs!.names).toEqual(['shell', 'read'])
    expect(block.toolDefs!.descriptions).toEqual(['run a shell command', 'read a file'])
    // Full JSON carries both tool definitions (name + description, input_schema stripped by backend).
    const parsed = JSON.parse(block.toolDefs!.json)
    expect(Array.isArray(parsed)).toBe(true)
    expect(parsed).toHaveLength(2)
    expect(parsed[0]!.name).toBe('shell')
  })

  it('emits a Tools row from Anthropic wire shape', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'a1',
        direction: 'request',
        payload: JSON.stringify({
          system: 'sys',
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
    expect(block.toolDefs!.descriptions).toEqual(['sh'])
  })

  it('emits a Tools row from Ollama-style function wrappers', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'o1',
        direction: 'request',
        payload: JSON.stringify({
          system: 'sys',
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
    expect(block.toolDefs!.descriptions).toEqual(['search the web'])
  })

  it('emits System + Tools rows only once per unique (system, tools) pair', () => {
    const tools = [{ name: 'shell', description: 'sh', input_schema: {} }]
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'd1',
        direction: 'request',
        payload: JSON.stringify({ system: 'sys', tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'first' }] }] }),
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
        payload: JSON.stringify({ system: 'sys', tools, messages: [{ role: 'user', content: [{ type: 'text', text: 'second' }] }] }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.filter((m) => m.agentName === 'System Prompt')).toHaveLength(1)
    expect(msgs.filter((m) => m.agentName === 'Tools')).toHaveLength(1)
  })

  it('omits tool defs when tools array is empty or absent', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'e1',
        direction: 'request',
        payload: JSON.stringify({ messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }] }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.find((m) => m.agentName === 'System Prompt')).toBeUndefined()
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

  it('surfaces the originating channel in the user-message source label', () => {
    // A user message sent from a channel (e.g. Telegram) carries the
    // channel label as a top-level `channel` field on the TranscriptEntry
    // (stamped into the request entry's erMeta by runTurn's requestMeta).
    // transcriptToMessages should render the source label as
    // "You · <channel>" so the user can tell where the message came from.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'u-tg',
        direction: 'request',
        channel: 'telegram',
        payload: JSON.stringify({
          messages: [{ role: 'user', content: [{ type: 'text', text: 'hi from telegram' }] }],
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    const userRow = msgs.find((m) => m.agentName === 'You · telegram')
    expect(userRow).toBeTruthy()
    expect(userRow!.blocks[0]!.text).toBe('hi from telegram')
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

  it('renders a SKILL_LOAD harness result entry as a collapsible tool-call box', () => {
    // The backend's recordSkillLoadResult records a second EKHarness entry
    // after SKILL_LOAD runs, carrying op.name + input + result (with the
    // skill body) in the payload. transcriptToMessages should synthesize a
    // ToolCallBlock-shaped message from it so the frontend renders the
    // skill body in a collapsible box (collapsed by default showing
    // "SKILL_LOAD" + the skill id; expanded shows the body).
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'skillload-1',
        direction: 'request',
        payload: JSON.stringify({
          messages: [],
          harness: null,
          op: { name: 'SKILL_LOAD' },
          input: { id: 'greet' },
          result: { id: 'greet', description: 'greeting skill', body: 'say hello warmly' },
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    // One message with one toolCall block.
    expect(msgs.length).toBe(1)
    const tcBlock = msgs[0]!.blocks.find((b) => b.toolCall !== undefined)
    expect(tcBlock).toBeTruthy()
    expect(tcBlock!.toolCall!.name).toBe('SKILL_LOAD')
    expect(tcBlock!.toolCall!.input).toEqual({ id: 'greet' })
    expect(tcBlock!.toolCall!.result).toBe('say hello warmly')
    expect(tcBlock!.toolCall!.resultIsError).toBe(false)
    // No channel in the payload → the source label is just "Skill".
    expect(msgs[0]!.agentName).toBe('Skill')
  })

  it('surfaces the originating channel in the SKILL_LOAD source label', () => {
    // When a skill is loaded from a channel (e.g. Telegram), the backend
    // stamps the channel label into the entry's erMeta under "channel",
    // shipped as a top-level `channel` field on the TranscriptEntry.
    // transcriptToMessages should render the source label as
    // "Skill · <channel>" so the user can tell how/why the skill was loaded.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'skillload-tg',
        direction: 'request',
        channel: 'telegram',
        payload: JSON.stringify({
          messages: [],
          harness: null,
          op: { name: 'SKILL_LOAD' },
          input: { id: 'start' },
          result: { id: 'start', description: 'start skill', body: 'body text' },
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.length).toBe(1)
    expect(msgs[0]!.agentName).toBe('Skill · telegram')
  })

  it('renders a SETUP_REPO harness result entry (failed clone) as a tool-call box marked as error', () => {
    // A failed clone (e.g. git@ SSH auth failure) is recorded by the
    // backend's recordSetupRepoResult. transcriptToMessages should
    // synthesize a ToolCallBlock so the failure is visible in the chat
    // (not silent), with resultIsError=true so it renders as an error.
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'setuprepo-fail',
        direction: 'request',
        payload: JSON.stringify({
          messages: [],
          harness: null,
          op: { name: 'SETUP_REPO' },
          input: { url: 'git@github.com:foo/bar.git' },
          result: { status: 'failed', target: '' },
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.length).toBe(1)
    const tcBlock = msgs[0]!.blocks.find((b) => b.toolCall !== undefined)
    expect(tcBlock).toBeTruthy()
    expect(tcBlock!.toolCall!.name).toBe('SETUP_REPO')
    expect(tcBlock!.toolCall!.input).toEqual({ url: 'git@github.com:foo/bar.git' })
    expect(tcBlock!.toolCall!.result).toBe('Clone failed')
    expect(tcBlock!.toolCall!.resultIsError).toBe(true)
    expect(msgs[0]!.agentName).toBe('Repo')
  })

  it('renders a SETUP_REPO harness result entry (successful clone) as a tool-call box', () => {
    const entries: TranscriptEntry[] = [
      makeEntry({
        id: 'setuprepo-ok',
        direction: 'request',
        channel: 'web',
        payload: JSON.stringify({
          messages: [],
          harness: null,
          op: { name: 'SETUP_REPO' },
          input: { url: 'https://github.com/foo/bar.git' },
          result: { status: 'cloned', target: 'bar' },
        }),
        raw: '{}',
      }),
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.length).toBe(1)
    const tcBlock = msgs[0]!.blocks.find((b) => b.toolCall !== undefined)
    expect(tcBlock).toBeTruthy()
    expect(tcBlock!.toolCall!.name).toBe('SETUP_REPO')
    expect(tcBlock!.toolCall!.result).toBe('Cloned into bar')
    expect(tcBlock!.toolCall!.resultIsError).toBe(false)
    expect(msgs[0]!.agentName).toBe('Repo · web')
  })
})

// ── ChatArea rendering ──────────────────────────────────────────────────────

describe('ChatArea', () => {
  it('renders a 3-message transcript (user / assistant-with-tool-call / system)', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        agentName: 'System Prompt',
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

  it('System row with rawJson shows the "View raw JSON" button and opens the modal', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        agentName: 'System Prompt',
        agentStatus: 'idle',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{ id: 'b1', collapsedText: 'You are a helpful assistant.' }],
        rawJson: '{"system":"You are a helpful assistant.","tools":[{"name":"shell","input_schema":{}}]}',
      },
    ]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
      />,
    )
    // The "View raw JSON (message)" button is present on the System row.
    expect(screen.getByLabelText('View raw JSON (message)')).toBeTruthy()
    // Open the modal and verify the raw JSON (with input_schema) is shown.
    fireEvent.click(screen.getByLabelText('View raw JSON (message)'))
    expect(screen.getByTestId('raw-json-modal')).toBeTruthy()
    expect(screen.getByText('"input_schema"')).toBeTruthy()
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

  it('renders a collapsed System row and a separate collapsed Tools row, both expandable', () => {
    const messages: Message[] = [
      {
        id: 'm1',
        agentName: 'System Prompt',
        agentStatus: 'idle',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{
          id: 'b1',
          collapsedText: 'You are a helpful assistant.',
        }],
      },
      {
        id: 'm2',
        agentName: 'Tools',
        agentStatus: 'idle',
        timestamp: '2024-06-01 12:00:00',
        blocks: [{
          id: 'b2',
          toolDefs: {
            count: 2,
            names: ['shell', 'read'],
            descriptions: ['sh', 'rd'],
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
    // System row collapsed preview.
    expect(screen.getByText(/helpful assistant/)).toBeTruthy()
    // Tools row collapsed header shows the tool count + names.
    expect(screen.getByText(/2 tools: shell, read/)).toBeTruthy()
    // The full JSON is NOT visible while collapsed.
    expect(screen.queryByText('"input_schema"')).toBeNull()
    // Click the Tools row to expand it.
    fireEvent.click(screen.getByText(/2 tools/))
    // Now the tools JSON renders inside a <pre> with the tool definitions.
    const presAfter = document.querySelectorAll('pre')
    const toolsPre = Array.from(presAfter).find(p => p.textContent?.includes('"input_schema"'))
    expect(toolsPre).toBeTruthy()
    expect(toolsPre!.textContent).toContain('"input_schema"')
    expect(toolsPre!.textContent).toContain('"shell"')
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

describe('SessionSetup Agent dropdown', () => {
  // SessionSetup renders when messages=[] and onSend/agents/onAgentChange/
  // onCustomPromptFile are all provided (the "new session, pick an agent" view).
  function renderSessionSetup(agents: { name: string; isDefault: boolean; displayName?: string }[]) {
    return render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        onSend={() => {}}
        agents={agents}
        onAgentChange={() => {}}
        onCustomPromptFile={() => {}}
      />,
    )
  }

  it('renders repo-local agent displayNames when present (agents-md → "Project (agents.md)")', () => {
    renderSessionSetup([
      { name: 'vtag--agents-md', isDefault: true, displayName: 'vtag/Project (agents.md)' },
      { name: 'vtag--foo-agent', isDefault: false, displayName: 'vtag/Foo Agent' },
    ])
    // The dropdown renders displayName for the label; the synthetic prefixed
    // id never leaks to the UI.
    expect(screen.getByText('vtag/Project (agents.md) (default)')).toBeTruthy()
    expect(screen.getByText('vtag/Foo Agent')).toBeTruthy()
    expect(screen.queryByText('vtag--agents-md')).toBeNull()
  })

  it('falls back to name when displayName is absent', () => {
    renderSessionSetup([{ name: 'bare-agent', isDefault: false }])
    expect(screen.getByText('bare-agent')).toBeTruthy()
  })

  it('marks the isDefault entry with "(default)" in the label', () => {
    renderSessionSetup([
      { name: 'a', isDefault: false },
      { name: 'b', isDefault: true },
    ])
    expect(screen.getByText('b (default)')).toBeTruthy()
    expect(screen.getByText('a')).toBeTruthy()
  })
})

// ── AskHumanForm (W8) ─────────────────────────────────────────────────────

describe('AskHumanForm', () => {
  function makeAskMessage(opts: { label: string; description?: string }[], overrides: Partial<Message> = {}): Message {
    return {
      id: 'm1',
      entryId: 'e1',
      agentName: 'Seal',
      agentStatus: 'completed',
      timestamp: '2024-06-01 12:00:00',
      blocks: [{
        id: 'b1',
        toolCall: {
          id: 'tool-1',
          name: 'ASK_HUMAN',
          input: { question: 'which branch?', options: opts },
        },
      }],
      rawJson: '{}',
      ...overrides,
    }
  }

  function makePendingQuestion(opts: { label: string; description?: string }[], overrides: Partial<{ id: string; question: string; createdAt: string; options: { label: string; description?: string }[] }> = {}): {
    id: string; question: string; createdAt: string; options: { label: string; description?: string }[]
  } {
    return {
      id: 'q1',
      question: 'which branch?',
      createdAt: new Date().toISOString(),
      options: opts,
      ...overrides,
    }
  }

  it('renders one button per option + the Other textarea', () => {
    const messages = [makeAskMessage([
      { label: 'main', description: 'the default branch' },
      { label: 'develop', description: 'the integration branch' },
    ])]
    const pendingQuestions = [makePendingQuestion([
      { label: 'main', description: 'the default branch' },
      { label: 'develop', description: 'the integration branch' },
    ])]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={() => Promise.resolve(true)}
        onCancelQuestion={() => {}}
      />,
    )
    expect(screen.getByText('main')).toBeTruthy()
    expect(screen.getByText('develop')).toBeTruthy()
    expect(screen.getByText('the default branch')).toBeTruthy()
    expect(screen.getByPlaceholderText('Type your own answer…')).toBeTruthy()
  })

  it('clicking a stock button calls onAnswerQuestionText with the label', () => {
    const messages = [makeAskMessage([{ label: 'main', description: 'd' }])]
    const pendingQuestions = [makePendingQuestion([{ label: 'main', description: 'd' }])]
    const onAnswerText = vi.fn(() => Promise.resolve(true))
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={onAnswerText}
        onCancelQuestion={() => {}}
      />,
    )
    fireEvent.click(screen.getByText('main'))
    expect(onAnswerText).toHaveBeenCalledWith('q1', 'main')
  })

  it('typing + Enter submits the Other textarea', () => {
    const messages = [makeAskMessage([{ label: 'main', description: 'd' }])]
    const pendingQuestions = [makePendingQuestion([{ label: 'main', description: 'd' }])]
    const onAnswerText = vi.fn(() => Promise.resolve(true))
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={onAnswerText}
        onCancelQuestion={() => {}}
      />,
    )
    const ta = screen.getByPlaceholderText('Type your own answer…') as HTMLTextAreaElement
    fireEvent.change(ta, { target: { value: 'my custom answer' } })
    fireEvent.keyDown(ta, { key: 'Enter' })
    expect(onAnswerText).toHaveBeenCalledWith('q1', 'my custom answer')
  })

  it('Shift+Enter inserts a newline (does NOT submit)', () => {
    const messages = [makeAskMessage([{ label: 'main', description: 'd' }])]
    const pendingQuestions = [makePendingQuestion([{ label: 'main', description: 'd' }])]
    const onAnswerText = vi.fn(() => Promise.resolve(true))
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={onAnswerText}
        onCancelQuestion={() => {}}
      />,
    )
    const ta = screen.getByPlaceholderText('Type your own answer…') as HTMLTextAreaElement
    fireEvent.change(ta, { target: { value: 'line1' } })
    fireEvent.keyDown(ta, { key: 'Enter', shiftKey: true })
    expect(onAnswerText).not.toHaveBeenCalled()
  })

  it('Escape cancels (calls onCancelQuestion)', () => {
    const messages = [makeAskMessage([{ label: 'main', description: 'd' }])]
    const pendingQuestions = [makePendingQuestion([{ label: 'main', description: 'd' }])]
    const onCancel = vi.fn()
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={() => Promise.resolve(true)}
        onCancelQuestion={onCancel}
      />,
    )
    const ta = screen.getByPlaceholderText('Type your own answer…') as HTMLTextAreaElement
    fireEvent.keyDown(ta, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledWith('q1')
  })

  it('does NOT render the form for the confirmation gate (no options)', () => {
    // A confirmation-gate question: "Allow SHELL_EXEC {...}? [y/N] " — no options.
    const messages: Message[] = [{
      id: 'm1',
      entryId: 'e1',
      agentName: 'Seal',
      agentStatus: 'completed',
      timestamp: '2024-06-01 12:00:00',
      blocks: [{
        id: 'b1',
        toolCall: {
          id: 'tool-1',
          name: 'SHELL_EXEC',
          input: { command: 'ls' },
        },
      }],
      rawJson: '{}',
    }]
    const pendingQuestions = [{
      id: 'q1',
      question: 'Allow SHELL_EXEC {"command":"ls"}? [y/N] ',
      createdAt: new Date().toISOString(),
    }]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestion={() => {}}
        onCancelQuestion={() => {}}
        onAnswerQuestionText={() => Promise.resolve(true)}
      />,
    )
    // The inline-approval panel renders (not the AskHumanForm).
    expect(screen.getByTestId('inline-approval')).toBeTruthy()
    expect(screen.queryByTestId('ask-human-form')).toBeNull()
  })

  it('XSS: a label with HTML is rendered as literal text (no <img>)', () => {
    const xssLabel = '<img src=x onerror=alert(1)>'
    const messages = [makeAskMessage([{ label: xssLabel }])]
    const pendingQuestions = [makePendingQuestion([{ label: xssLabel }])]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={() => Promise.resolve(true)}
        onCancelQuestion={() => {}}
      />,
    )
    // The label is rendered as text, not as HTML — no <img> element.
    expect(screen.queryByRole('img')).toBeNull()
    expect(screen.getByText(xssLabel)).toBeTruthy()
  })

  // ── Open-ended ASK_HUMAN (no options) ──────────────────────────────────
  // Regression (session 20260812-001914-833): when the model calls ASK_HUMAN
  // WITHOUT an `options` array (an open-ended question), the frontend failed
  // to correlate the pending question with the tool call. `matchesToolCall`
  // only matched ASK_HUMAN when `pq.options.length > 0`, so the open-ended
  // case fell through to the "Allow <NAME> <JSON>?" confirmation-gate regex
  // (which didn't match), and no form rendered. The AskHumanForm must render
  // for open-ended questions too — with the textarea as the only input
  // (no option buttons).

  function makeOpenAskMessage(question: string, overrides: Partial<Message> = {}): Message {
    return {
      id: 'm1',
      entryId: 'e1',
      agentName: 'Seal',
      agentStatus: 'completed',
      timestamp: '2024-06-01 12:00:00',
      blocks: [{
        id: 'b1',
        toolCall: {
          id: 'tool-1',
          name: 'ASK_HUMAN',
          input: { question },
        },
      }],
      rawJson: '{}',
      ...overrides,
    }
  }

  function makeOpenPendingQuestion(question: string, overrides: Partial<{ id: string; question: string; createdAt: string; options: undefined; meta: undefined }> = {}): {
    id: string; question: string; createdAt: string; options: undefined; meta: undefined
  } {
    return {
      id: 'q1',
      question,
      createdAt: new Date().toISOString(),
      options: undefined,
      meta: undefined,
      ...overrides,
    }
  }

  it('renders the AskHumanForm for an open-ended ASK_HUMAN (no options)', () => {
    const messages = [makeOpenAskMessage('I am Zoe. Who are you?')]
    const pendingQuestions = [makeOpenPendingQuestion('I am Zoe. Who are you?')]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={() => Promise.resolve(true)}
        onCancelQuestion={() => {}}
      />,
    )
    // The AskHumanForm renders (the free-text textarea is the question UI).
    expect(screen.getByTestId('ask-human-form')).toBeTruthy()
    expect(screen.getByText('I am Zoe. Who are you?')).toBeTruthy()
    expect(screen.getByPlaceholderText('Type your own answer…')).toBeTruthy()
  })

  it('does NOT render the inline-approval panel for open-ended ASK_HUMAN', () => {
    const messages = [makeOpenAskMessage('I am Zoe. Who are you?')]
    const pendingQuestions = [makeOpenPendingQuestion('I am Zoe. Who are you?')]
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestion={() => {}}
        onCancelQuestion={() => {}}
        onAnswerQuestionText={() => Promise.resolve(true)}
      />,
    )
    // The inline-approval panel (Yes/Reject) is for the confirmation gate,
    // NOT for open-ended ASK_HUMAN.
    expect(screen.queryByTestId('inline-approval')).toBeNull()
    expect(screen.getByTestId('ask-human-form')).toBeTruthy()
  })

  it('typing + Enter submits the open-ended ASK_HUMAN answer', () => {
    const messages = [makeOpenAskMessage('What is your name?')]
    const pendingQuestions = [makeOpenPendingQuestion('What is your name?')]
    const onAnswerText = vi.fn(() => Promise.resolve(true))
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={onAnswerText}
        onCancelQuestion={() => {}}
      />,
    )
    const ta = screen.getByPlaceholderText('Type your own answer…') as HTMLTextAreaElement
    fireEvent.change(ta, { target: { value: 'Mighty' } })
    fireEvent.keyDown(ta, { key: 'Enter' })
    expect(onAnswerText).toHaveBeenCalledWith('q1', 'Mighty')
  })

  it('Escape cancels an open-ended ASK_HUMAN', () => {
    const messages = [makeOpenAskMessage('What is your name?')]
    const pendingQuestions = [makeOpenPendingQuestion('What is your name?')]
    const onCancel = vi.fn()
    render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={messages}
        pendingQuestions={pendingQuestions}
        onAnswerQuestionText={() => Promise.resolve(true)}
        onCancelQuestion={onCancel}
      />,
    )
    const ta = screen.getByPlaceholderText('Type your own answer…') as HTMLTextAreaElement
    fireEvent.keyDown(ta, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledWith('q1')
  })
})
