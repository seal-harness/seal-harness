import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { CronView } from '../CronView'
import type {
  AgentDefInfo,
  CronJobDetail,
  CronJobSummary,
  CronMutationResult,
  ProviderInfo,
} from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createCronJob = vi.fn(async (_input: unknown): Promise<CronMutationResult> => ({ ok: false, error: 'network error' }))
const updateCronJob = vi.fn(async (_id: string, _input: unknown): Promise<CronMutationResult> => ({ ok: false, error: 'network error' }))
const deleteCronJob = vi.fn(async (_id: string): Promise<boolean> => false)
const fetchCronJob = vi.fn(async (_id: string): Promise<CronJobDetail | null> => null)

let cronJobsState: CronJobSummary[] = []
let cronJobsLoaded = true
let cronJobsError = false

let agentDefsState: AgentDefInfo[] = []
let agentDefsLoaded = true

let providersState: ProviderInfo[] = []
let providersLoaded = true
const fetchProviderModels = vi.fn(async (_name: string): Promise<{ name: string; contextWindow: number }[]> => [])

vi.mock('../../hooks/useApi', () => ({
  createCronJob: (input: unknown) => createCronJob(input),
  updateCronJob: (id: string, input: unknown) => updateCronJob(id, input),
  deleteCronJob: (id: string) => deleteCronJob(id),
  fetchCronJob: (id: string) => fetchCronJob(id),
  useCronJobs: () => ({
    jobs: cronJobsState,
    loaded: cronJobsLoaded,
    error: cronJobsError,
    refresh: vi.fn(),
  }),
  useAgentDefs: () => ({
    agents: agentDefsState,
    loaded: agentDefsLoaded,
    error: false,
    refresh: vi.fn(),
  }),
  useConfiguredProviders: () => ({
    providers: providersState,
    loaded: providersLoaded,
    refresh: vi.fn(),
  }),
  fetchProviderModels: (name: string) => fetchProviderModels(name),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeJob(overrides: Partial<CronJobSummary> = {}): CronJobSummary {
  return {
    id: 'daily',
    name: 'Daily',
    schedule: '0 9 * * *',
    timezone: null,
    prompt: 'summarize',
    agent_def_id: null,
    provider: null,
    model: null,
    enabled: false,
    one_shot: false,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    last_fire: null,
    run_count: 0,
    consecutive_failures: 0,
    ...overrides,
  }
}

function makeAgent(overrides: Partial<AgentDefInfo> = {}): AgentDefInfo {
  return {
    id: 'planner',
    name: 'planner',
    isDefault: false,
    displayName: 'Planner',
    provider: 'anthropic',
    model: 'claude-sonnet-4',
    system: null,
    tools: 'all',
    group: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    session: 'web',
    ...overrides,
  }
}

/** The agent picker is a <select> whose option values are the AgentDefIds
 *  (plus the empty "use the configured default" option). */
function agentSelect(): HTMLSelectElement {
  return document.getElementById('cron-agent') as HTMLSelectElement
}

function optionValues(sel: HTMLSelectElement): string[] {
  return Array.from(sel.options).map((o) => o.value)
}

beforeEach(() => {
  cronJobsState = []
  cronJobsLoaded = true
  cronJobsError = false
  agentDefsState = []
  agentDefsLoaded = true
  providersState = [
    { name: 'anthropic', isDefault: true, configured: true, defaultModel: 'claude-opus-4-8', models: ['claude-opus-4-8', 'claude-sonnet-4'] },
    { name: 'ollama', configured: true, defaultModel: 'llama3.2' },
  ]
  providersLoaded = true
  fetchProviderModels.mockReset()
  fetchProviderModels.mockResolvedValue([])
  createCronJob.mockReset()
  updateCronJob.mockReset()
  deleteCronJob.mockReset()
  fetchCronJob.mockReset()
  createCronJob.mockResolvedValue({ ok: true, job: { ...makeJob(), next_fire: null } })
  updateCronJob.mockResolvedValue({ ok: true, job: { ...makeJob(), next_fire: null } })
  deleteCronJob.mockResolvedValue(true)
  fetchCronJob.mockResolvedValue({ ...makeJob(), next_fire: null })
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('CronView agent picker', () => {
  it('renders the agent field as a dropdown, not a free-text input', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    const el = agentSelect()
    expect(el).toBeTruthy()
    expect(el.tagName).toBe('SELECT')
  })

  it('offers one option per known agent def plus the "use default" option', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner' }),
      makeAgent({ id: 'coder', displayName: 'Coder', group: 'core' }),
    ]
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    expect(optionValues(agentSelect())).toEqual(['', 'planner', 'coder'])
  })

  it('labels each option with the agent display name and flags the default', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', isDefault: true }),
      makeAgent({ id: 'coder', displayName: 'Coder' }),
    ]
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    const opts = Array.from(agentSelect().options)
    const byValue = (v: string) => opts.find((o) => o.value === v)!
    // The label is the display name, and only the configured default is marked.
    expect(byValue('planner').textContent).toBe('Planner (default)')
    expect(byValue('coder').textContent).toBe('Coder')
    // Within a group, agents are ordered by id (coder < planner) — the same
    // order the Agents view uses for its list pane.
    expect(opts.slice(1).map((o) => o.value)).toEqual(['coder', 'planner'])
  })

  it('sends the picked agent id as agent_def_id on create', async () => {
    agentDefsState = [makeAgent({ id: 'coder', displayName: 'Coder' })]
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(document.getElementById('cron-name') as HTMLInputElement, { target: { value: 'Daily' } })
    fireEvent.change(document.getElementById('cron-schedule') as HTMLInputElement, { target: { value: '0 9 * * *' } })
    fireEvent.change(document.getElementById('cron-prompt') as HTMLTextAreaElement, { target: { value: 'summarize' } })
    fireEvent.change(agentSelect(), { target: { value: 'coder' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { agent_def_id?: string }
    expect(body.agent_def_id).toBe('coder')
  })

  it('omits agent_def_id when the "use default" option is picked', async () => {
    agentDefsState = [makeAgent({ id: 'coder', displayName: 'Coder' })]
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(document.getElementById('cron-name') as HTMLInputElement, { target: { value: 'Daily' } })
    fireEvent.change(document.getElementById('cron-schedule') as HTMLInputElement, { target: { value: '0 9 * * *' } })
    fireEvent.change(document.getElementById('cron-prompt') as HTMLTextAreaElement, { target: { value: 'summarize' } })
    expect(agentSelect().value).toBe('')
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { agent_def_id?: string }
    expect(body.agent_def_id).toBeUndefined()
  })

  it('seeds the dropdown from the edited job', () => {
    agentDefsState = [makeAgent({ id: 'coder', displayName: 'Coder' })]
    cronJobsState = [makeJob({ id: 'daily', agent_def_id: 'coder' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    expect(agentSelect().value).toBe('coder')
  })

  it('keeps a job agent id that no longer exists selectable, so an edit cannot silently clear it', () => {
    agentDefsState = [makeAgent({ id: 'coder', displayName: 'Coder' })]
    cronJobsState = [makeJob({ id: 'daily', agent_def_id: 'retired-agent' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    const sel = agentSelect()
    expect(sel.value).toBe('retired-agent')
    expect(optionValues(sel)).toContain('retired-agent')
  })

  it('preserves the pinned agent id when an edit is saved unchanged', async () => {
    agentDefsState = [makeAgent({ id: 'coder', displayName: 'Coder' })]
    cronJobsState = [makeJob({ id: 'daily', agent_def_id: 'coder' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    fireEvent.click(screen.getByLabelText('Save cron job'))
    await waitFor(() => expect(updateCronJob).toHaveBeenCalledTimes(1))
    expect(updateCronJob.mock.calls[0]![0]).toBe('daily')
    const body = updateCronJob.mock.calls[0]![1] as { agent_def_id?: string }
    expect(body.agent_def_id).toBe('coder')
  })

  it('nests grouped agents under an optgroup, ungrouped ones under the select root', () => {
    agentDefsState = [
      makeAgent({ id: 'planner', displayName: 'Planner', group: null }),
      makeAgent({ id: 'coder', displayName: 'Coder', group: 'core' }),
    ]
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    const sel = agentSelect()
    const groups = Array.from(sel.querySelectorAll('optgroup'))
    expect(groups.map((g) => g.label)).toEqual(['core'])
    expect(groups[0]!.querySelector('option[value="coder"]')).toBeTruthy()
    // The ungrouped agent is a direct child of <select>, not wrapped in an
    // optgroup.
    const planner = sel.querySelector('option[value="planner"]')
    expect(planner).toBeTruthy()
    expect(planner!.closest('optgroup')).toBeNull()
  })
})

describe('CronView basics', () => {
  it('renders an empty state when no jobs exist', () => {
    render(<CronView />)
    expect(screen.getByText(/No cron jobs defined/i)).toBeTruthy()
    expect(screen.getByText(/Select a cron job or create a new one/i)).toBeTruthy()
  })

  it('renders a row per job with its schedule', () => {
    cronJobsState = [
      makeJob({ id: 'daily', name: 'Daily', schedule: '0 9 * * *' }),
      makeJob({ id: 'hourly', name: 'Hourly', schedule: '0 * * * *' }),
    ]
    render(<CronView />)
    expect(screen.getByText('Daily')).toBeTruthy()
    expect(screen.getByText('Hourly')).toBeTruthy()
    expect(screen.getByText('0 9 * * *')).toBeTruthy()
  })

  it('creates a job disabled by default', async () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(document.getElementById('cron-name') as HTMLInputElement, { target: { value: 'Daily' } })
    fireEvent.change(document.getElementById('cron-schedule') as HTMLInputElement, { target: { value: '0 9 * * *' } })
    fireEvent.change(document.getElementById('cron-prompt') as HTMLTextAreaElement, { target: { value: 'summarize' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { enabled?: boolean }
    expect(body.enabled).toBe(false)
  })

  it('surfaces the backend error message on a failed create', async () => {
    createCronJob.mockResolvedValue({ ok: false, error: 'schedule must have 5 fields' })
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(document.getElementById('cron-name') as HTMLInputElement, { target: { value: 'Daily' } })
    fireEvent.change(document.getElementById('cron-schedule') as HTMLInputElement, { target: { value: 'nope' } })
    fireEvent.change(document.getElementById('cron-prompt') as HTMLTextAreaElement, { target: { value: 'summarize' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(screen.getByText('schedule must have 5 fields')).toBeTruthy())
  })

  it('requires a confirmation before deleting', async () => {
    cronJobsState = [makeJob({ id: 'daily', name: 'Daily' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    fireEvent.click(screen.getByText('Delete'))
    expect(deleteCronJob).not.toHaveBeenCalled()
    fireEvent.click(screen.getByText('Yes, delete'))
    await waitFor(() => expect(deleteCronJob).toHaveBeenCalledWith('daily'))
  })
})

// ── Provider + model ────────────────────────────────────────────────────

function providerSelect(): HTMLSelectElement {
  return document.getElementById('cron-provider') as HTMLSelectElement
}

/** Fill the three required fields so the Create/Save button enables. */
function fillRequired() {
  fireEvent.change(document.getElementById('cron-name') as HTMLInputElement, { target: { value: 'Daily' } })
  fireEvent.change(document.getElementById('cron-schedule') as HTMLInputElement, { target: { value: '0 9 * * *' } })
  fireEvent.change(document.getElementById('cron-prompt') as HTMLTextAreaElement, { target: { value: 'summarize' } })
}

describe('CronView provider + model', () => {
  it('offers the configured providers plus a "use configured default" option', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    const sel = providerSelect()
    expect(sel.tagName).toBe('SELECT')
    expect(optionValues(sel)).toEqual(['', 'anthropic', 'ollama'])
    const opts = Array.from(sel.options)
    expect(opts[0]!.textContent).toBe('(use configured default)')
    // Only Seal's configured default carries the marker.
    expect(opts.find((o) => o.value === 'anthropic')!.textContent).toBe('Anthropic (default)')
    expect(opts.find((o) => o.value === 'ollama')!.textContent).toBe('Ollama')
  })

  it('shows a loading entry until the provider list arrives', () => {
    providersLoaded = false
    providersState = []
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    expect(providerSelect().disabled).toBe(true)
    expect(Array.from(providerSelect().options).map((o) => o.textContent)).toContain('Loading…')
  })

  it('disables the model control until a provider is chosen', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    const modelInput = document.getElementById('cron-model') as HTMLInputElement
    expect(modelInput.disabled).toBe(true)
    expect(modelInput.placeholder).toBe('(use configured default)')
  })

  it('enables the model combobox once a provider is picked, without filling it in', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(providerSelect(), { target: { value: 'anthropic' } })
    const modelInput = document.getElementById('cron-model') as HTMLInputElement
    expect(modelInput.disabled).toBe(false)
    // Selecting a provider must NOT pin a model the operator never typed.
    expect(modelInput.value).toBe('')
  })

  it('offers the picked provider configured models as suggestions', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(providerSelect(), { target: { value: 'anthropic' } })
    const input = document.getElementById('cron-model') as HTMLInputElement
    fireEvent.focus(input)
    const list = screen.getByTestId('cron-model-list')
    const opts = Array.from(list.querySelectorAll('[role="option"]')).map((o) => o.textContent)
    expect(opts).toEqual(['claude-opus-4-8', 'claude-sonnet-4'])
  })

  it('falls back to a live model fetch when the provider has no configured models', async () => {
    fetchProviderModels.mockResolvedValue([{ name: 'live-model', contextWindow: 4096 }])
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(providerSelect(), { target: { value: 'ollama' } })
    await waitFor(() => expect(fetchProviderModels).toHaveBeenCalledWith('ollama'))
    const input = document.getElementById('cron-model') as HTMLInputElement
    fireEvent.focus(input)
    const opts = Array.from(screen.getByTestId('cron-model-list').querySelectorAll('[role="option"]'))
      .map((o) => o.textContent)
    expect(opts).toEqual(['live-model'])
  })

  it('stays usable for free-text entry when the live fetch returns nothing', async () => {
    fetchProviderModels.mockResolvedValue([])
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(providerSelect(), { target: { value: 'ollama' } })
    await waitFor(() => expect(fetchProviderModels).toHaveBeenCalled())
    const input = document.getElementById('cron-model') as HTMLInputElement
    expect(input.disabled).toBe(false)
    fireEvent.change(input, { target: { value: 'my-own-model' } })
    expect((document.getElementById('cron-model') as HTMLInputElement).value).toBe('my-own-model')
  })

  it('clears the model when the provider is cleared', () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fireEvent.change(providerSelect(), { target: { value: 'anthropic' } })
    fireEvent.change(document.getElementById('cron-model') as HTMLInputElement, { target: { value: 'claude-sonnet-4' } })
    fireEvent.change(providerSelect(), { target: { value: '' } })
    expect((document.getElementById('cron-model') as HTMLInputElement).value).toBe('')
  })

  it('omits provider and model from the create body when no provider is chosen', async () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fillRequired()
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { provider?: unknown; model?: unknown }
    expect(body.provider).toBeUndefined()
    expect(body.model).toBeUndefined()
  })

  it('sends the chosen provider and a typed model', async () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fillRequired()
    fireEvent.change(providerSelect(), { target: { value: 'anthropic' } })
    fireEvent.change(document.getElementById('cron-model') as HTMLInputElement, { target: { value: 'claude-opus-4-8' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { provider?: unknown; model?: unknown }
    expect(body.provider).toBe('anthropic')
    expect(body.model).toBe('claude-opus-4-8')
  })

  it('omits the model key when a provider is chosen but no model typed', async () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fillRequired()
    fireEvent.change(providerSelect(), { target: { value: 'anthropic' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { provider?: unknown; model?: unknown }
    expect(body.provider).toBe('anthropic')
    // No model ⇒ the job follows Seal's configured default model.
    expect(body.model).toBeUndefined()
  })

  it('seeds both fields from the edited job', () => {
    cronJobsState = [makeJob({ id: 'daily', provider: 'ollama', model: 'llama3.2' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    expect(providerSelect().value).toBe('ollama')
    expect((document.getElementById('cron-model') as HTMLInputElement).value).toBe('llama3.2')
  })

  it('keeps a stored provider that no longer exists selectable', () => {
    cronJobsState = [makeJob({ id: 'daily', provider: 'retired-provider' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    const sel = providerSelect()
    expect(sel.value).toBe('retired-provider')
    expect(optionValues(sel)).toContain('retired-provider')
    expect(Array.from(sel.options).find((o) => o.value === 'retired-provider')!.textContent)
      .toBe('retired-provider (missing)')
  })

  it('resends the stored values when an edit is saved untouched', async () => {
    cronJobsState = [makeJob({ id: 'daily', provider: 'ollama', model: 'llama3.2' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    fireEvent.click(screen.getByLabelText('Save cron job'))
    await waitFor(() => expect(updateCronJob).toHaveBeenCalledTimes(1))
    const body = updateCronJob.mock.calls[0]![1] as { provider?: unknown; model?: unknown }
    expect(body.provider).toBe('ollama')
    expect(body.model).toBe('llama3.2')
  })

  // A job may carry a model with no provider (the backend stores the two
  // fields independently). The disabled control must still DISPLAY that
  // model, otherwise the form hides a value it is about to submit.
  it('displays a stored model even while no provider is selected', () => {
    cronJobsState = [makeJob({ id: 'daily', provider: null, model: 'claude-opus-4-8' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    const modelInput = document.getElementById('cron-model') as HTMLInputElement
    expect(modelInput.disabled).toBe(true)
    expect(modelInput.value).toBe('claude-opus-4-8')
  })

  it('omits the model key when creating with a provider but no model', async () => {
    render(<CronView />)
    fireEvent.click(screen.getByLabelText('New cron job'))
    fillRequired()
    fireEvent.change(providerSelect(), { target: { value: 'ollama' } })
    fireEvent.click(screen.getByLabelText('Create cron job'))
    await waitFor(() => expect(createCronJob).toHaveBeenCalledTimes(1))
    const body = createCronJob.mock.calls[0]![0] as { provider?: unknown; model?: unknown }
    expect(body.provider).toBe('ollama')
    expect(body.model).toBeUndefined()
  })

  it('sends an empty string to clear the provider on an existing job', async () => {
    cronJobsState = [makeJob({ id: 'daily', provider: 'ollama', model: 'llama3.2' })]
    render(<CronView />)
    fireEvent.click(screen.getByText('Daily'))
    fireEvent.change(providerSelect(), { target: { value: '' } })
    fireEvent.click(screen.getByLabelText('Save cron job'))
    await waitFor(() => expect(updateCronJob).toHaveBeenCalledTimes(1))
    const body = updateCronJob.mock.calls[0]![1] as { provider?: unknown; model?: unknown }
    // "" is the wire signal for "clear to the configured default".
    expect(body.provider).toBe('')
    expect(body.model).toBe('')
  })
})
