import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { ProvidersView } from '../ProvidersView'
import type { ProviderDetail } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createProvider = vi.fn(async (_input: unknown): Promise<{ ok: true; provider: ProviderDetail } | { ok: false; error: string; field?: string }> => ({ ok: false, error: 'fail' }))
const updateProvider = vi.fn(async (_name: string, _input: unknown): Promise<{ ok: true; provider: ProviderDetail } | { ok: false; error: string; field?: string }> => ({ ok: false, error: 'fail' }))
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

const LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  ollama: 'Ollama',
  'openai-compat': 'OpenAI-compatible',
}

function makeProvider(overrides: Partial<ProviderDetail> = {}): ProviderDetail {
  const name = overrides.name ?? 'anthropic'
  return {
    name,
    displayName: LABELS[name] ?? name,
    isDefault: false,
    defaultModel: null,
    baseUrl: 'https://api.anthropic.com',
    authStatus: 'none',
    baseUrlRequired: false,
    baseUrlEditable: false,
    defaultBaseUrl: null,
    keyOptional: false,
    defaultModelRequired: false,
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
    expect(screen.getByText('No providers configured.')).toBeDefined()
  })

  it('hides unconfigured providers from the list', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByTestId('provider-row-anthropic')).toBeDefined()
    expect(screen.queryByTestId('provider-row-ollama')).toBeNull()
    expect(screen.getByText('Providers (1)')).toBeDefined()
  })

  it('shows empty state when only unconfigured providers exist', () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'none' })]
    render(<ProvidersView />)
    expect(screen.getByText('No providers configured.')).toBeDefined()
    expect(screen.queryByTestId('provider-row-ollama')).toBeNull()
  })

  it('still offers unconfigured providers in the new-provider dropdown', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    expect(select).not.toBeNull()
    const options = Array.from(select!.querySelectorAll('option')).map((o) => o.textContent)
    expect(options).toContain('Ollama')
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
      makeProvider({ name: 'ollama', authStatus: 'none', defaultBaseUrl: 'http://localhost:11434',
                     baseUrlEditable: true }),
    ]
    const created: ProviderDetail = makeProvider({ name: 'ollama', authStatus: 'keyless',
                                                   baseUrl: 'http://localhost:11434',
                                                   defaultBaseUrl: 'http://localhost:11434' })
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

  it('shows the optional-key hint for a keyless provider', () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'keyless', keyOptional: true,
                                     baseUrl: 'http://localhost:11434', defaultBaseUrl: 'http://localhost:11434' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-ollama'))
    expect(screen.getByText('Optional — leave blank for a keyless endpoint.')).toBeDefined()
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

// ── Generic OpenAI-compatible provider (issue #271) ──────────────────────

describe('ProvidersView — required fields', () => {
  const compat = () =>
    makeProvider({
      name: 'openai-compat',
      displayName: 'OpenAI-compatible',
      authStatus: 'keyless',
      baseUrl: null,
      baseUrlRequired: true,
      baseUrlEditable: true,
      defaultBaseUrl: null,
      keyOptional: true,
      defaultModelRequired: true,
      defaultModel: null,
    })

  it('blocks Save until the required base URL and model are filled', () => {
    providersState = [compat()]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-openai-compat'))
    const save = screen.getByTestId('provider-save') as HTMLButtonElement
    expect(save.disabled).toBe(true)
    // The label is marked required and the field advertises it.
    expect(screen.getByText('Base URL *')).toBeDefined()
    expect(screen.getByText('Default model *')).toBeDefined()
    const baseInput = screen.getByTestId('provider-base-url-input') as HTMLInputElement
    expect(baseInput.getAttribute('aria-required')).toBe('true')
    expect(baseInput.placeholder).toBe('https://host/v1')
    fireEvent.change(baseInput, { target: { value: 'https://gw.example/v1' } })
    // base URL alone is not enough: the model is also required
    expect((screen.getByTestId('provider-save') as HTMLButtonElement).disabled).toBe(true)
    fireEvent.change(screen.getByTestId('provider-default-model-input'),
                     { target: { value: 'qwen2.5-7b' } })
    expect((screen.getByTestId('provider-save') as HTMLButtonElement).disabled).toBe(false)
  })

  it('does not block Save for a provider whose base URL is optional', () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'keyless', keyOptional: true,
                                     baseUrl: 'http://localhost:11434' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-ollama'))
    expect((screen.getByTestId('provider-save') as HTMLButtonElement).disabled).toBe(false)
  })

  it('renders a fixed endpoint read-only', () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    const baseInput = screen.getByTestId('provider-base-url-input') as HTMLInputElement
    expect(baseInput.readOnly).toBe(true)
    expect(baseInput.value).toBe('https://api.anthropic.com')
  })

  it('shows the model hint for a provider without a default model', () => {
    providersState = [compat()]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-openai-compat'))
    expect(screen.getByText('Required — the model id your endpoint serves.')).toBeDefined()
  })

  it('renders a server field error inline next to the field', async () => {
    providersState = [compat()]
    createProvider.mockResolvedValue({ ok: false, error: 'Base URL is not usable (host required)', field: 'base_url' })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')!
    fireEvent.change(select, { target: { value: 'openai-compat' } })
    fireEvent.change(screen.getByTestId('provider-base-url-input'),
                     { target: { value: 'https://host/v1' } })
    fireEvent.change(screen.getByTestId('provider-default-model-input'),
                     { target: { value: 'm1' } })
    fireEvent.click(screen.getByTestId('provider-save'))
    expect(await screen.findByText('Base URL is not usable (host required)')).toBeDefined()
    const baseInput = screen.getByTestId('provider-base-url-input') as HTMLInputElement
    expect(baseInput.getAttribute('aria-invalid')).toBe('true')
    // the generic error box is not used for a field-scoped error
    expect(screen.queryByTestId('provider-form-error')).toBeNull()
  })
})
