import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { AgentsView } from '../AgentsView'
import type { AgentDefInfo, ProviderInfo } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createAgentDef = vi.fn(async (_input: unknown): Promise<AgentDefInfo | null> => null)
const updateAgentDef = vi.fn(async (_id: string, _input: unknown): Promise<AgentDefInfo | null> => null)
const deleteAgentDef = vi.fn(async (_id: string): Promise<boolean> => false)
const fetchDefaultAgent = vi.fn(async (): Promise<string | null> => null)
const setDefaultAgent = vi.fn(async (_agent: string | null): Promise<boolean> => false)

let agentDefsState: AgentDefInfo[] = []
let providersState: ProviderInfo[] = [{ name: 'anthropic' }, { name: 'ollama' }]
let agentDefsError = false
let agentDefsLoaded = true
let defaultAgentIdState: string | null = null

vi.mock('../../hooks/useApi', () => ({
  createAgentDef: (input: unknown) => createAgentDef(input),
  updateAgentDef: (id: string, input: unknown) => updateAgentDef(id, input),
  deleteAgentDef: (id: string) => deleteAgentDef(id),
  fetchDefaultAgent: () => fetchDefaultAgent(),
  setDefaultAgent: (agent: string | null) => setDefaultAgent(agent),
  useAgentDefs: () => ({
    agents: agentDefsState,
    loaded: agentDefsLoaded,
    error: agentDefsError,
    refresh: vi.fn(),
  }),
  useConfiguredProviders: () => ({
    providers: providersState,
    loaded: true,
  }),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeAgent(overrides: Partial<AgentDefInfo> = {}): AgentDefInfo {
  return {
    id: 'planner',
    name: 'planner',
    isDefault: false,
    displayName: 'Planner',
    provider: 'anthropic',
    model: 'claude-sonnet-4',
    system: 'plan tasks',
    tools: 'all',
    group: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    session: 'web',
    ...overrides,
  }
}

beforeEach(() => {
  agentDefsState = []
  providersState = [{ name: 'anthropic' }, { name: 'ollama' }]
  agentDefsError = false
  agentDefsLoaded = true
  defaultAgentIdState = null
  createAgentDef.mockReset()
  updateAgentDef.mockReset()
  deleteAgentDef.mockReset()
  fetchDefaultAgent.mockReset()
  setDefaultAgent.mockReset()
  createAgentDef.mockResolvedValue(null)
  updateAgentDef.mockResolvedValue(null)
  deleteAgentDef.mockResolvedValue(false)
  // fetchDefaultAgent returns the current defaultAgentIdState; the component
  // calls it on mount + after every setDefaultAgent.
  fetchDefaultAgent.mockImplementation(async () => defaultAgentIdState)
  setDefaultAgent.mockResolvedValue(true)
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('AgentsView', () => {
  it('renders an empty state when no agents exist', () => {
    agentDefsState = []
    render(<AgentsView />)
    expect(screen.getByText(/No agents yet/i)).toBeTruthy()
    expect(screen.getByText(/Select an agent to edit/i)).toBeTruthy()
  })

  it('renders a row per agent with id + provider + model', async () => {
    defaultAgentIdState = 'coder'
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', provider: 'anthropic', model: 'claude-sonnet-4' }),
      makeAgent({ id: 'coder', displayName: 'Coder', provider: 'ollama', model: 'llama3.2' }),
    ]
    render(<AgentsView />)
    expect(screen.getByTestId('agent-row-planner')).toBeTruthy()
    expect(screen.getByTestId('agent-row-coder')).toBeTruthy()
    expect(screen.getByText('Planner')).toBeTruthy()
    expect(screen.getByText('Coder')).toBeTruthy()
    // the default pill (after the fetch resolves)
    await waitFor(() => expect(screen.getByText('default')).toBeTruthy())
  })

  it('shows the load error banner when error=true', () => {
    agentDefsError = true
    render(<AgentsView />)
    expect(screen.getByTestId('agents-load-error')).toBeTruthy()
  })

  // Test 42, the AgentsView half. This view HAND-ROLLS its own <select> and
  // never renders ProviderSelect, so the shared component's annotation does not
  // reach it — it needs its own.
  it('42: annotates Ollama with its readiness in the agent provider select', () => {
    providersState = [
      { name: 'anthropic' },
      { name: 'ollama', readiness: 'not-running' },
    ]
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const sel = document.getElementById('agent-provider') as HTMLSelectElement
    const opts = Array.from(sel.options)
    expect(opts.find((o) => o.value === 'ollama')!.textContent).toBe('Ollama (Not Running)')
    // Annotation, not gating: still selectable.
    expect(opts.find((o) => o.value === 'ollama')!.disabled).toBe(false)
    fireEvent.change(sel, { target: { value: 'ollama' } })
    expect(sel.value).toBe('ollama')
  })

  it('42b: a ready Ollama carries its model count here too', () => {
    providersState = [
      { name: 'ollama', readiness: 'ready', readiness_models: 2 },
    ]
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const opts = Array.from((document.getElementById('agent-provider') as HTMLSelectElement).options)
    expect(opts.find((o) => o.value === 'ollama')!.textContent).toBe('Ollama (Ready · 2 Models)')
  })

  it('42c: a non-Ollama provider carries no annotation', () => {
    providersState = [{ name: 'anthropic' }]
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const opts = Array.from((document.getElementById('agent-provider') as HTMLSelectElement).options)
    expect(opts.find((o) => o.value === 'anthropic')!.textContent).toBe('Anthropic')
  })

  it('clicking + opens the New agent form', () => {
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    expect(screen.getByTestId('agent-form-new')).toBeTruthy()
    expect(screen.getByLabelText('Create agent')).toBeTruthy()
  })

  it('clicking a row opens the editor seeded with that def (id editable)', () => {
    agentDefsState = [makeAgent({ id: 'planner', displayName: 'Planner', system: 'plan tasks' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    expect(screen.getByTestId('agent-form-planner')).toBeTruthy()
    // The id input is editable (renames the def on save); seeded with the
    // current id.
    const idEl = document.getElementById('agent-id') as HTMLInputElement
    expect(idEl.disabled).toBe(false)
    expect(idEl.value).toBe('planner')
    // The system prompt is seeded.
    const sysEl = document.getElementById('agent-system') as HTMLTextAreaElement
    expect(sysEl.value).toBe('plan tasks')
  })

  it('create validates the id charset and surfaces an error for spaces', () => {
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const idEl = document.getElementById('agent-id') as HTMLInputElement
    fireEvent.change(idEl, { target: { value: 'bad id!' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    expect(screen.getByTestId('agent-form-error')).toBeTruthy()
    expect(createAgentDef).not.toHaveBeenCalled()
  })

  it('create POSTs the form on a valid id and switches to edit mode', async () => {
    createAgentDef.mockResolvedValue(makeAgent({ id: 'coder', displayName: 'Coder' }))
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const idEl = document.getElementById('agent-id') as HTMLInputElement
    fireEvent.change(idEl, { target: { value: 'coder' } })
    const nameEl = document.getElementById('agent-name') as HTMLInputElement
    fireEvent.change(nameEl, { target: { value: 'Coder' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    await waitFor(() => expect(createAgentDef).toHaveBeenCalledTimes(1))
    const call = createAgentDef.mock.calls[0]![0] as { id?: string; name?: string; tools?: unknown }
    expect(call.id).toBe('coder')
    expect(call.name).toBe('Coder')
    // tools defaults to 'all'
    expect(call.tools).toBe('all')
  })

  it('create surfaces a failure message when the backend returns null', async () => {
    createAgentDef.mockResolvedValue(null)
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    const idEl = document.getElementById('agent-id') as HTMLInputElement
    fireEvent.change(idEl, { target: { value: 'coder' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    await waitFor(() => expect(createAgentDef).toHaveBeenCalled())
    expect(screen.getByTestId('agent-form-error')).toBeTruthy()
  })

  it('Save on an existing def PUTs /api/agents/:id (no id in the body)', async () => {
    updateAgentDef.mockResolvedValue(makeAgent({ id: 'planner', displayName: 'Planner 2' }))
    agentDefsState = [makeAgent({ id: 'planner', displayName: 'Planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    const nameEl = document.getElementById('agent-name') as HTMLInputElement
    fireEvent.change(nameEl, { target: { value: 'Planner 2' } })
    fireEvent.click(screen.getByLabelText('Save agent'))
    await waitFor(() => expect(updateAgentDef).toHaveBeenCalledTimes(1))
    expect(updateAgentDef.mock.calls[0]![0]).toBe('planner')
    const body = updateAgentDef.mock.calls[0]![1] as { id?: string; name?: string }
    expect(body.id).toBeUndefined()
    expect(body.name).toBe('Planner 2')
  })

  it('Delete opens a confirm step; confirming DELETEs the def', async () => {
    deleteAgentDef.mockResolvedValue(true)
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    fireEvent.click(screen.getByLabelText('Delete agent'))
    expect(screen.getByTestId('agent-delete-confirm')).toBeTruthy()
    fireEvent.click(screen.getByLabelText('Confirm delete') ?? screen.getByText('Confirm delete'))
    await waitFor(() => expect(deleteAgentDef).toHaveBeenCalledWith('planner'))
  })

  it('Cancel closes the editor and returns to the empty state', () => {
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    fireEvent.click(screen.getByText('Cancel'))
    expect(screen.getByText(/Select an agent to edit/i)).toBeTruthy()
  })

  it('encodes tools as an array when the textarea has opcode names', async () => {
    createAgentDef.mockResolvedValue(makeAgent({ id: 'coder', tools: ['FILE_READ'] }))
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    fireEvent.change(document.getElementById('agent-id') as HTMLInputElement, { target: { value: 'coder' } })
    const toolsEl = document.getElementById('agent-tools') as HTMLTextAreaElement
    fireEvent.change(toolsEl, { target: { value: 'FILE_READ\nASK_HUMAN' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    await waitFor(() => expect(createAgentDef).toHaveBeenCalled())
    const body = createAgentDef.mock.calls[0]![0] as { tools?: unknown }
    expect(body.tools).toEqual(['FILE_READ', 'ASK_HUMAN'])
  })

  it('editing the id sends new_id on PUT (rename); editing keeps id sends no new_id', async () => {
    updateAgentDef.mockResolvedValue(makeAgent({ id: 'planner2', displayName: 'Planner' }))
    agentDefsState = [makeAgent({ id: 'planner', displayName: 'Planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    const idEl = document.getElementById('agent-id') as HTMLInputElement
    fireEvent.change(idEl, { target: { value: 'planner2' } })
    fireEvent.click(screen.getByLabelText('Save agent'))
    await waitFor(() => expect(updateAgentDef).toHaveBeenCalledTimes(1))
    expect(updateAgentDef.mock.calls[0]![0]).toBe('planner')
    const body = updateAgentDef.mock.calls[0]![1] as { id?: string; new_id?: string }
    expect(body.id).toBeUndefined()
    expect(body.new_id).toBe('planner2')
  })

  it('saving an edit without changing the id sends no new_id', async () => {
    updateAgentDef.mockResolvedValue(makeAgent({ id: 'planner', displayName: 'Planner 2' }))
    agentDefsState = [makeAgent({ id: 'planner', displayName: 'Planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    fireEvent.change(document.getElementById('agent-name') as HTMLInputElement, { target: { value: 'Planner 2' } })
    fireEvent.click(screen.getByLabelText('Save agent'))
    await waitFor(() => expect(updateAgentDef).toHaveBeenCalledTimes(1))
    const body = updateAgentDef.mock.calls[0]![1] as { new_id?: string }
    expect(body.new_id).toBeUndefined()
  })

  // ── Default-agent control ────────────────────────────────────────────

  it('shows "Set as default" when the edited agent is not the default', () => {
    defaultAgentIdState = null
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    expect(screen.getByTestId('set-default-agent')).toBeTruthy()
    expect(screen.getByLabelText('Set as default agent')).toBeTruthy()
  })

  it('shows "Clear default" when the edited agent IS the default', async () => {
    defaultAgentIdState = 'planner'
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    await waitFor(() => expect(screen.getByTestId('clear-default-agent')).toBeTruthy())
    expect(screen.getByLabelText('Clear default agent')).toBeTruthy()
  })

  it('clicking "Set as default" PUTs the agent id', async () => {
    defaultAgentIdState = null
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    fireEvent.click(screen.getByLabelText('Set as default agent'))
    await waitFor(() => expect(setDefaultAgent).toHaveBeenCalledWith('planner'))
  })

  it('clicking "Clear default" PUTs null', async () => {
    defaultAgentIdState = 'planner'
    agentDefsState = [makeAgent({ id: 'planner' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    await waitFor(() => expect(screen.getByTestId('clear-default-agent')).toBeTruthy())
    fireEvent.click(screen.getByLabelText('Clear default agent'))
    await waitFor(() => expect(setDefaultAgent).toHaveBeenCalledWith(null))
  })

  it('renders a "default" pill on the row that is the configured default', async () => {
    defaultAgentIdState = 'planner'
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner' }),
      makeAgent({ id: 'coder', displayName: 'Coder' }),
    ]
    render(<AgentsView />)
    // Only one "default" pill in the list pane (after the fetch resolves).
    await waitFor(() => expect(screen.getAllByText('default')).toHaveLength(1))
  })

  // ── Grouping ─────────────────────────────────────────────────────────

  it('groups agents by their group field with ungrouped under "Agents"', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', group: 'core' }),
      makeAgent({ id: 'coder', displayName: 'Coder', group: null }),
      makeAgent({ id: 'reviewer', displayName: 'Reviewer', group: 'core' }),
    ]
    render(<AgentsView />)
    // Ungrouped agents appear under "Agents" header
    expect(screen.getByTestId('agent-group-header-Agents')).toBeTruthy()
    expect(screen.getByTestId('agent-group-header-core')).toBeTruthy()
    // Each row is present
    expect(screen.getByTestId('agent-row-planner')).toBeTruthy()
    expect(screen.getByTestId('agent-row-coder')).toBeTruthy()
    expect(screen.getByTestId('agent-row-reviewer')).toBeTruthy()
  })

  it('collapses and expands a group on header click', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', group: 'core' }),
      makeAgent({ id: 'coder', displayName: 'Coder', group: null }),
    ]
    render(<AgentsView />)
    // The "core" group starts expanded
    expect(screen.getByTestId('agent-group-collapse-core').textContent).toBe('▾')
    // Collapse it
    fireEvent.click(screen.getByTestId('agent-group-header-core'))
    expect(screen.getByTestId('agent-group-collapse-core').textContent).toBe('▸')
    // The "Agents" (ungrouped) group is still expanded
    expect(screen.getByTestId('agent-group-collapse-Agents').textContent).toBe('▾')
  })

  it('sends group in the create payload', async () => {
    createAgentDef.mockResolvedValue(makeAgent({ id: 'coder', displayName: 'Coder', group: 'core' }))
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    fireEvent.change(document.getElementById('agent-id') as HTMLInputElement, { target: { value: 'coder' } })
    fireEvent.change(document.getElementById('agent-group') as HTMLInputElement, { target: { value: 'core' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    await waitFor(() => expect(createAgentDef).toHaveBeenCalled())
    const body = createAgentDef.mock.calls[0]![0] as { group?: string | null }
    expect(body.group).toBe('core')
  })

  it('sends group: null when the group field is empty on create', async () => {
    createAgentDef.mockResolvedValue(makeAgent({ id: 'coder', displayName: 'Coder' }))
    agentDefsState = []
    render(<AgentsView />)
    fireEvent.click(screen.getByLabelText('New agent'))
    fireEvent.change(document.getElementById('agent-id') as HTMLInputElement, { target: { value: 'coder' } })
    fireEvent.click(screen.getByLabelText('Create agent'))
    await waitFor(() => expect(createAgentDef).toHaveBeenCalled())
    const body = createAgentDef.mock.calls[0]![0] as { group?: string | null }
    expect(body.group).toBeNull()
  })

  it('seeds the group field from the existing def on edit', () => {
    agentDefsState = [makeAgent({ id: 'planner', displayName: 'Planner', group: 'core' })]
    render(<AgentsView />)
    fireEvent.click(screen.getByTestId('agent-row-planner'))
    const groupEl = document.getElementById('agent-group') as HTMLInputElement
    expect(groupEl.value).toBe('core')
  })
})