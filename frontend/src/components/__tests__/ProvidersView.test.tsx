import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { ProvidersView } from '../ProvidersView'
import type { ProviderDetail } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createProvider = vi.fn(async (_input: unknown): Promise<{ ok: true; provider: ProviderDetail } | { ok: false; error: string }> => ({ ok: false, error: 'fail' }))
const updateProvider = vi.fn(async (_name: string, _input: unknown): Promise<{ ok: true; provider: ProviderDetail } | { ok: false; error: string }> => ({ ok: false, error: 'fail' }))
const deleteProvider = vi.fn(async (_name: string): Promise<boolean> => false)
const fetchDefaultProvider = vi.fn(async (): Promise<string | null> => null)
const setDefaultProvider = vi.fn(async (_provider: string | null): Promise<boolean> => false)

let providersState: ProviderDetail[] = []
let providersError = false
let providersLoaded = true
let defaultProviderState: string | null = null

vi.mock('../../hooks/useApi', () => ({
  createProvider: (input: unknown) => createProvider(input),
  updateProvider: (name: string, input: unknown) => updateProvider(name, input),
  deleteProvider: (name: string) => deleteProvider(name),
  fetchDefaultProvider: () => fetchDefaultProvider(),
  setDefaultProvider: (provider: string | null) => setDefaultProvider(provider),
  useAllProviders: () => ({
    providers: providersState,
    loaded: providersLoaded,
    error: providersError,
    refresh: vi.fn(),
  }),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeProvider(overrides: Partial<ProviderDetail> = {}): ProviderDetail {
  return {
    name: 'anthropic',
    isDefault: false,
    defaultModel: null,
    baseUrl: null,
    authStatus: 'none',
    ...overrides,
  }
}

beforeEach(() => {
  providersState = []
  providersError = false
  providersLoaded = true
  defaultProviderState = null
  createProvider.mockReset()
  updateProvider.mockReset()
  deleteProvider.mockReset()
  fetchDefaultProvider.mockReset()
  setDefaultProvider.mockReset()
  createProvider.mockResolvedValue({ ok: false, error: 'fail' })
  updateProvider.mockResolvedValue({ ok: false, error: 'fail' })
  deleteProvider.mockResolvedValue(false)
  fetchDefaultProvider.mockImplementation(async () => defaultProviderState)
  setDefaultProvider.mockResolvedValue(true)
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('ProvidersView', () => {
  it('renders the list pane with providers', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'keyless' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByTestId('provider-row-anthropic')).toBeDefined()
    expect(screen.getByTestId('provider-row-ollama')).toBeDefined()
    expect(screen.getByText('Providers (2)')).toBeDefined()
  })

  it('shows empty state when no providers', () => {
    providersState = []
    render(<ProvidersView />)
    expect(screen.getByText('No providers found.')).toBeDefined()
  })

  it('shows error state on load failure', () => {
    providersError = true
    providersLoaded = true
    render(<ProvidersView />)
    expect(screen.getByText('Failed to load — the backend may be unreachable.')).toBeDefined()
  })

  it('clicking a provider shows the editor form', () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key', defaultModel: 'claude-sonnet-4' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    expect(screen.getByTestId('provider-form-anthropic')).toBeDefined()
    expect(screen.getAllByText('Anthropic').length).toBeGreaterThan(0)
  })

  it('clicking + opens the new provider form', () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    expect(screen.getByTestId('provider-form-new')).toBeDefined()
  })

  it('creating a provider calls createProvider', async () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    const created: ProviderDetail = makeProvider({ name: 'ollama', authStatus: 'keyless', baseUrl: 'http://localhost:11434' })
    createProvider.mockResolvedValue({ ok: true, provider: created })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    // Select ollama from the dropdown
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    expect(select).not.toBeNull()
    fireEvent.change(select!, { target: { value: 'ollama' } })
    // Fill base URL (wait for re-render after select change)
    const baseUrlInput = await screen.findByPlaceholderText('http://localhost:11434')
    fireEvent.change(baseUrlInput, { target: { value: 'http://localhost:11434' } })
    // Click Create
    const saveBtn = screen.getByTestId('provider-save')
    fireEvent.click(saveBtn)
    await waitFor(() => {
      expect(createProvider).toHaveBeenCalledTimes(1)
    })
  })

  it('editing a provider and saving calls updateProvider', async () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key', defaultModel: 'claude-opus-4-8' })]
    const updated: ProviderDetail = makeProvider({ name: 'anthropic', authStatus: 'api-key', defaultModel: 'claude-sonnet-4' })
    updateProvider.mockResolvedValue({ ok: true, provider: updated })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    // Change default model
    const modelInput = screen.getByPlaceholderText('e.g. claude-sonnet-4-20250514')
    fireEvent.change(modelInput, { target: { value: 'claude-sonnet-4' } })
    // Click Save
    const saveBtn = screen.getByTestId('provider-save')
    fireEvent.click(saveBtn)
    await waitFor(() => {
      expect(updateProvider).toHaveBeenCalledTimes(1)
    })
  })

  it('delete button shows confirmation, then calls deleteProvider', async () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key' })]
    deleteProvider.mockResolvedValue(true)
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    fireEvent.click(screen.getByTestId('provider-delete'))
    expect(screen.getByTestId('provider-delete-confirm')).toBeDefined()
    fireEvent.click(screen.getByTestId('provider-delete-confirm-btn'))
    await waitFor(() => {
      expect(deleteProvider).toHaveBeenCalledWith('anthropic')
    })
  })

  it('shows auth status badge in the list', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'keyless' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByText('API Key')).toBeDefined()
    expect(screen.getByText('Keyless')).toBeDefined()
  })

  it('shows default badge for the default provider', async () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key', isDefault: true })]
    defaultProviderState = 'anthropic'
    render(<ProvidersView />)
    const defaultBadge = await screen.findByText('default')
    expect(defaultBadge).toBeDefined()
  })

  it('disables API key field when vault is locked', () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'vault-locked' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    const apiKeyInput = screen.getByTestId('provider-api-key-input') as HTMLInputElement
    expect(apiKeyInput.disabled).toBe(true)
  })

  it('shows keyless hint for keyless providers', () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'keyless', baseUrl: 'http://localhost:11434' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-ollama'))
    expect(screen.getByText('This provider is keyless (local). No API key required.')).toBeDefined()
  })

  it('set as default button calls setDefaultProvider', async () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key' })]
    setDefaultProvider.mockResolvedValue(true)
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    fireEvent.click(screen.getByTestId('set-default-provider'))
    await waitFor(() => {
      expect(setDefaultProvider).toHaveBeenCalledWith('anthropic')
    })
  })

  it('displays form error when create fails', async () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    createProvider.mockResolvedValue({ ok: false, error: 'vault not configured' })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'ollama' } })
    const apiKeyInput = screen.getByPlaceholderText('Enter API key')
    fireEvent.change(apiKeyInput, { target: { value: 'test-key' } })
    fireEvent.click(screen.getByTestId('provider-save'))
    const errorEl = await screen.findByTestId('provider-form-error')
    expect(errorEl).toBeDefined()
    expect(screen.getByText('vault not configured')).toBeDefined()
  })
})