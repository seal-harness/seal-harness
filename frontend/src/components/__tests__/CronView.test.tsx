import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { CronView } from '../CronView'
import type {
  AgentDefInfo,
  CronJobDetail,
  CronJobSummary,
  CronMutationResult,
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
