import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { AgentsView } from '../AgentsView'
import type { AgentDefInfo } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createAgentDef = vi.fn(async (_input: unknown): Promise<AgentDefInfo | null> => null)
const updateAgentDef = vi.fn(async (_id: string, _input: unknown): Promise<AgentDefInfo | null> => null)
const deleteAgentDef = vi.fn(async (_id: string): Promise<boolean> => false)

let agentDefsState: AgentDefInfo[] = []
let agentDefsError = false
let agentDefsLoaded = true

vi.mock('../../hooks/useApi', () => ({
  createAgentDef: (input: unknown) => createAgentDef(input),
  updateAgentDef: (id: string, input: unknown) => updateAgentDef(id, input),
  deleteAgentDef: (id: string) => deleteAgentDef(id),
  useAgentDefs: () => ({
    agents: agentDefsState,
    loaded: agentDefsLoaded,
    error: agentDefsError,
    refresh: vi.fn(),
  }),
  useConfiguredProviders: () => ({
    providers: [{ name: 'anthropic' }, { name: 'ollama' }],
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
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    session: 'web',
    ...overrides,
  }
}

beforeEach(() => {
  agentDefsState = []
  agentDefsError = false
  agentDefsLoaded = true
  createAgentDef.mockReset()
  updateAgentDef.mockReset()
  deleteAgentDef.mockReset()
  createAgentDef.mockResolvedValue(null)
  updateAgentDef.mockResolvedValue(null)
  deleteAgentDef.mockResolvedValue(false)
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

  it('renders a row per agent with id + provider + model', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', provider: 'anthropic', model: 'claude-sonnet-4' }),
      makeAgent({ id: 'coder', displayName: 'Coder', provider: 'ollama', model: 'llama3.2', isDefault: true }),
    ]
    render(<AgentsView />)
    expect(screen.getByTestId('agent-row-planner')).toBeTruthy()
    expect(screen.getByTestId('agent-row-coder')).toBeTruthy()
    expect(screen.getByText('Planner')).toBeTruthy()
    expect(screen.getByText('Coder')).toBeTruthy()
    // the default pill
    expect(screen.getByText('default')).toBeTruthy()
  })

  it('shows the load error banner when error=true', () => {
    agentDefsError = true
    render(<AgentsView />)
    expect(screen.getByTestId('agents-load-error')).toBeTruthy()
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
})