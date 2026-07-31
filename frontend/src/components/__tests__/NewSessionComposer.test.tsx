import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { NewSessionComposer } from '../NewSessionComposer'
import { createBareSession, setupRepo } from '../../hooks/useApi'
import type { NewTabSpec } from '../../hooks/useNewTabSpec'
import type { ProviderInfo } from '../../types'

vi.mock('../../hooks/useApi', () => ({
  createBareSession: vi.fn(async () => ({ session_id: 's-new-1' })),
  setupRepo: vi.fn(async () => ({ ok: false, target: '', status: 'failed', error: 'clone failed: SSH unavailable' })),
}))

// ── Helpers ────────────────────────────────────────────────────────────

function makeProvider(overrides: Partial<ProviderInfo> = {}): ProviderInfo {
  return { name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4', ...overrides }
}

function makeSpec(overrides: Partial<NewTabSpec> = {}): NewTabSpec {
  const base: NewTabSpec = {
    kind: 'provider',
    setKind: vi.fn(),
    configuredProviders: [makeProvider()],
    providersLoaded: true,
    provider: 'anthropic',
    setProvider: vi.fn(),
    model: 'claude-sonnet-4',
    setModel: vi.fn(),
    models: [{ name: 'claude-sonnet-4', contextWindow: 200000 }],
    modelsLoading: false,
    useCustomModel: false,
    handleModelSelectChange: vi.fn(),
    customModels: [],
    repo: '',
    setRepo: vi.fn(),
    repoHistory: [],
    flavour: 'claude-code',
    setFlavour: vi.fn(),
    customBinary: '',
    setCustomBinary: vi.fn(),
    attachSession: '',
    setAttachSession: vi.fn(),
    attachWindow: '',
    setAttachWindow: vi.fn(),
    attachWindowIndex: null,
    setAttachWindowIndex: vi.fn(),
    attachManual: false,
    setAttachManual: vi.fn(),
    discoverableWindows: [],
    discoveryError: false,
    scanDiscoverable: vi.fn(async () => {}),
    validationError: null,
    buildBody: vi.fn(() => ({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4' })),
    persistOnSubmit: vi.fn(),
  }
  return { ...base, ...overrides }
}

beforeEach(() => {
  cleanup()
  vi.clearAllMocks()
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ── Tests ──────────────────────────────────────────────────────────────

describe('NewSessionComposer', () => {
  it('renders the provider + model dropdowns (no kind pills, no harness section)', () => {
    render(<NewSessionComposer spec={makeSpec()} onSubmit={() => {}} onCancel={() => {}} />)
    expect(screen.getByText('Start a new session')).toBeTruthy()
    expect(screen.getByLabelText('Provider')).toBeTruthy()
    expect(screen.getByLabelText('Model')).toBeTruthy()
    // No kind pills (New session only has the AI Provider section).
    expect(screen.queryByText('AI Provider')).toBeNull()
    expect(screen.queryByText('New Harness')).toBeNull()
    expect(screen.queryByText('Existing Harness')).toBeNull()
  })

  it('fires onSubmit with the createBareSession response on submit', async () => {
    const onSubmit = vi.fn()
    render(<NewSessionComposer spec={makeSpec()} onSubmit={onSubmit} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new session'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith({ session_id: 's-new-1' }))
    expect(createBareSession).toHaveBeenCalledWith({ provider: 'anthropic', model: 'claude-sonnet-4' })
  })

  it('persists the form selection on submit', async () => {
    const persistOnSubmit = vi.fn()
    const spec = makeSpec({ persistOnSubmit })
    render(<NewSessionComposer spec={spec} onSubmit={() => {}} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new session'))
    await waitFor(() => expect(persistOnSubmit).toHaveBeenCalled())
  })

  it('disables submit when validationError is set', () => {
    const spec = makeSpec({ validationError: 'Pick a model' })
    render(<NewSessionComposer spec={spec} onSubmit={() => {}} onCancel={() => {}} />)
    const btn = screen.getByLabelText('Submit new session') as HTMLButtonElement
    expect(btn.disabled).toBe(true)
  })

  it('fires onCancel when the Cancel button is clicked', () => {
    const onCancel = vi.fn()
    render(<NewSessionComposer spec={makeSpec()} onSubmit={() => {}} onCancel={onCancel} />)
    fireEvent.click(screen.getByText('Cancel'))
    expect(onCancel).toHaveBeenCalled()
  })

  it('renders the "Set up repo" combo box', () => {
    render(<NewSessionComposer spec={makeSpec()} onSubmit={() => {}} onCancel={() => {}} />)
    expect(screen.getByText('Set up repo')).toBeTruthy()
    expect(screen.getByPlaceholderText(/git URL/)).toBeTruthy()
  })

  it('does not call setupRepo when the repo field is empty', async () => {
    const onSubmit = vi.fn()
    render(<NewSessionComposer spec={makeSpec({ repo: '' })} onSubmit={onSubmit} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new session'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    expect(setupRepo).not.toHaveBeenCalled()
  })

  it('calls setupRepo with the new session id + repo URL when a repo is entered', async () => {
    const onSubmit = vi.fn()
    const setRepo = vi.fn()
    render(<NewSessionComposer spec={makeSpec({ repo: 'https://github.com/foo/bar', setRepo })} onSubmit={onSubmit} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new session'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith({ session_id: 's-new-1' }))
    expect(setupRepo).toHaveBeenCalledWith('s-new-1', 'https://github.com/foo/bar')
  })

  it('surfaces a repo warning banner when setupRepo fails (and still submits)', async () => {
    const onSubmit = vi.fn()
    render(<NewSessionComposer spec={makeSpec({ repo: 'git@github.com:foo/bar' })} onSubmit={onSubmit} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new session'))
    await waitFor(() => expect(screen.getByTestId('composer-repo-warning')).toBeTruthy())
    // The session still starts (the warning does not block onSubmit).
    expect(onSubmit).toHaveBeenCalledWith({ session_id: 's-new-1' })
    expect(screen.getByTestId('composer-repo-warning').textContent).toContain('Could not set up repo')
  })
})