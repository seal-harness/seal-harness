import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { SkillsView } from '../SkillsView'
import type { SkillInfo } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createSkill = vi.fn(async (_input: unknown): Promise<SkillInfo | null> => null)
const updateSkill = vi.fn(async (_id: string, _input: unknown): Promise<SkillInfo | null> => null)
const deleteSkill = vi.fn(async (_id: string): Promise<boolean> => false)

let skillsState: SkillInfo[] = []
let skillsError = false
let skillsLoaded = true

vi.mock('../../hooks/useApi', () => ({
  createSkill: (input: unknown) => createSkill(input),
  updateSkill: (id: string, input: unknown) => updateSkill(id, input),
  deleteSkill: (id: string) => deleteSkill(id),
  useSkills: () => ({
    skills: skillsState,
    loaded: skillsLoaded,
    error: skillsError,
    refresh: vi.fn(),
  }),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeSkill(overrides: Partial<SkillInfo> = {}): SkillInfo {
  return {
    id: 'coding',
    description: 'Coding skill',
    body: '## Coding\n\nWrite code carefully.',
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    session: 'web',
    ...overrides,
  }
}

beforeEach(() => {
  skillsState = []
  skillsError = false
  skillsLoaded = true
  createSkill.mockReset()
  updateSkill.mockReset()
  deleteSkill.mockReset()
  createSkill.mockResolvedValue(null)
  updateSkill.mockResolvedValue(null)
  deleteSkill.mockResolvedValue(false)
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('SkillsView', () => {
  it('renders an empty state when no skills exist', () => {
    skillsState = []
    render(<SkillsView />)
    expect(screen.getByText(/No skills yet/i)).toBeTruthy()
    expect(screen.getByText(/Select a skill to edit/i)).toBeTruthy()
  })

  it('renders a row per skill', () => {
    skillsState = [
      makeSkill({ id: 'coding', description: 'Coding' }),
      makeSkill({ id: 'writer', description: 'Writer' }),
    ]
    render(<SkillsView />)
    expect(screen.getByTestId('skill-row-coding')).toBeTruthy()
    expect(screen.getByTestId('skill-row-writer')).toBeTruthy()
  })

  it('shows the load error banner when error=true', () => {
    skillsError = true
    render(<SkillsView />)
    expect(screen.getByTestId('skills-load-error')).toBeTruthy()
  })

  it('clicking + opens the New skill form', () => {
    skillsState = []
    render(<SkillsView />)
    fireEvent.click(screen.getByLabelText('New skill'))
    expect(screen.getByTestId('skill-form-new')).toBeTruthy()
    expect(screen.getByLabelText('Create skill')).toBeTruthy()
  })

  it('clicking a row opens the editor seeded with that skill (id editable)', () => {
    skillsState = [makeSkill({ id: 'coding', description: 'Coding', body: 'b' })]
    render(<SkillsView />)
    fireEvent.click(screen.getByTestId('skill-row-coding'))
    expect(screen.getByTestId('skill-form-coding')).toBeTruthy()
    const idEl = document.getElementById('skill-id') as HTMLInputElement
    expect(idEl.disabled).toBe(false)
    expect(idEl.value).toBe('coding')
    const bodyEl = document.getElementById('skill-body') as HTMLTextAreaElement
    expect(bodyEl.value).toBe('b')
  })

  it('create validates the id charset and surfaces an error for spaces', () => {
    skillsState = []
    render(<SkillsView />)
    fireEvent.click(screen.getByLabelText('New skill'))
    fireEvent.change(document.getElementById('skill-id') as HTMLInputElement, { target: { value: 'bad id!' } })
    fireEvent.click(screen.getByLabelText('Create skill'))
    expect(screen.getByTestId('skill-form-error')).toBeTruthy()
    expect(createSkill).not.toHaveBeenCalled()
  })

  it('create POSTs the form on a valid id', async () => {
    createSkill.mockResolvedValue(makeSkill({ id: 'coding' }))
    skillsState = []
    render(<SkillsView />)
    fireEvent.click(screen.getByLabelText('New skill'))
    fireEvent.change(document.getElementById('skill-id') as HTMLInputElement, { target: { value: 'coding' } })
    fireEvent.change(document.getElementById('skill-description') as HTMLInputElement, { target: { value: 'Coding' } })
    fireEvent.change(document.getElementById('skill-body') as HTMLTextAreaElement, { target: { value: '## Coding' } })
    fireEvent.click(screen.getByLabelText('Create skill'))
    await waitFor(() => expect(createSkill).toHaveBeenCalledTimes(1))
    const body = createSkill.mock.calls[0]![0] as { id?: string; description?: string; body?: string }
    expect(body.id).toBe('coding')
    expect(body.description).toBe('Coding')
    expect(body.body).toBe('## Coding')
  })

  it('Save on an existing skill PUTs /api/skills/:id (no id in the body)', async () => {
    updateSkill.mockResolvedValue(makeSkill({ id: 'coding', description: 'Coding 2' }))
    skillsState = [makeSkill({ id: 'coding', description: 'Coding' })]
    render(<SkillsView />)
    fireEvent.click(screen.getByTestId('skill-row-coding'))
    fireEvent.change(document.getElementById('skill-description') as HTMLInputElement, { target: { value: 'Coding 2' } })
    fireEvent.click(screen.getByLabelText('Save skill'))
    await waitFor(() => expect(updateSkill).toHaveBeenCalledTimes(1))
    expect(updateSkill.mock.calls[0]![0]).toBe('coding')
    const body = updateSkill.mock.calls[0]![1] as { id?: string; description?: string }
    expect(body.id).toBeUndefined()
    expect(body.description).toBe('Coding 2')
  })

  it('Delete opens a confirm step; confirming DELETEs the skill', async () => {
    deleteSkill.mockResolvedValue(true)
    skillsState = [makeSkill({ id: 'coding' })]
    render(<SkillsView />)
    fireEvent.click(screen.getByTestId('skill-row-coding'))
    fireEvent.click(screen.getByLabelText('Delete skill'))
    expect(screen.getByTestId('skill-delete-confirm')).toBeTruthy()
    fireEvent.click(screen.getByText('Confirm delete'))
    await waitFor(() => expect(deleteSkill).toHaveBeenCalledWith('coding'))
  })

  it('editing the id sends new_id on PUT (rename)', async () => {
    updateSkill.mockResolvedValue(makeSkill({ id: 'coding2', description: 'Coding' }))
    skillsState = [makeSkill({ id: 'coding', description: 'Coding' })]
    render(<SkillsView />)
    fireEvent.click(screen.getByTestId('skill-row-coding'))
    const idEl = document.getElementById('skill-id') as HTMLInputElement
    fireEvent.change(idEl, { target: { value: 'coding2' } })
    fireEvent.click(screen.getByLabelText('Save skill'))
    await waitFor(() => expect(updateSkill).toHaveBeenCalledTimes(1))
    expect(updateSkill.mock.calls[0]![0]).toBe('coding')
    const body = updateSkill.mock.calls[0]![1] as { id?: string; new_id?: string }
    expect(body.id).toBeUndefined()
    expect(body.new_id).toBe('coding2')
  })
})