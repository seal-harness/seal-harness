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
  const authStatus = overrides.authStatus ?? 'none'
  return {
    name,
    displayName: LABELS[name] ?? name,
    type: name,
    typeDisplayName: LABELS[name] ?? name,
    problem: null,
    reconfiguring: false,
    configured: authStatus !== 'none',
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

  it('lists every instance, including unconfigured ones', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByTestId('provider-row-anthropic')).toBeDefined()
    expect(screen.getByTestId('provider-row-ollama')).toBeDefined()
    expect(screen.getByText('Providers (2)')).toBeDefined()
  })

  it('shows the all-unconfigured banner when nothing is configured', () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'none' })]
    render(<ProvidersView />)
    expect(screen.getByTestId('provider-row-ollama')).toBeDefined()
    expect(screen.getByText('No provider is configured yet — add one from the type picker.')).toBeDefined()
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

// ── Named provider instances (issue #273) ────────────────────────────────

describe('ProvidersView — instances', () => {
  it('prefills the name with the type id and validates it inline', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'none' }),
      makeProvider({ name: 'ollama', authStatus: 'none' }),
    ]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const typeSel = screen.getByTestId('provider-type-select') as HTMLSelectElement
    expect(typeSel.value).toBe('anthropic')
    const nameInput = () => screen.getByTestId('provider-name-input') as HTMLInputElement
    expect(nameInput().value).toBe('anthropic')
    // Choosing another type moves the prefilled name with it.
    fireEvent.change(typeSel, { target: { value: 'ollama' } })
    expect(nameInput().value).toBe('ollama')
    // Invalid grammar -> aria-invalid + describedby + an inline message.
    fireEvent.change(nameInput(), { target: { value: 'Bad_Name' } })
    expect(nameInput().getAttribute('aria-invalid')).toBe('true')
    expect(nameInput().getAttribute('aria-describedby')).toBe('provider-name-error')
    expect(screen.getByTestId('provider-name-error')).toBeDefined()
    // Reserved word.
    fireEvent.change(nameInput(), { target: { value: 'default' } })
    expect(screen.getByTestId('provider-name-error').textContent).toContain('reserved')
    // Another type's id (own type is ollama).
    fireEvent.change(nameInput(), { target: { value: 'anthropic' } })
    expect(screen.getByTestId('provider-name-error').textContent).toContain('provider type id')
  })

  it('shows a problem row delete-only and renders its problem', () => {
    providersState = [makeProvider({
      name: 'groq', type: null, typeDisplayName: null, authStatus: 'none',
      problem: 'has no type and its name is not a provider type',
    })]
    render(<ProvidersView />)
    expect(screen.getByText('has no type and its name is not a provider type')).toBeDefined()
    fireEvent.click(screen.getByTestId('provider-row-groq'))
    expect(screen.getByTestId('provider-form-groq')).toBeDefined()
    expect(screen.getByTestId('provider-problem')).toBeDefined()
    expect(screen.queryByTestId('provider-save')).toBeNull()
    expect(screen.queryByTestId('set-default-provider')).toBeNull()
    expect(screen.getByTestId('provider-delete')).toBeDefined()
  })

  it('shows name and type read-only when editing an explicit instance', () => {
    providersState = [makeProvider({
      name: 'work', type: 'anthropic', typeDisplayName: 'Anthropic',
      displayName: 'work', authStatus: 'api-key',
    })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-work'))
    const nameRo = screen.getByTestId('provider-name-readonly') as HTMLInputElement
    const typeRo = screen.getByTestId('provider-type-readonly') as HTMLInputElement
    expect(nameRo.value).toBe('work')
    expect(typeRo.value).toBe('Anthropic')
    expect(nameRo.readOnly).toBe(true)
    expect(typeRo.readOnly).toBe(true)
  })

  it('renders two instances of one type distinctly', () => {
    providersState = [
      makeProvider({ name: 'work', type: 'anthropic', typeDisplayName: 'Anthropic', displayName: 'work', authStatus: 'api-key' }),
      makeProvider({ name: 'personal', type: 'anthropic', typeDisplayName: 'Anthropic', displayName: 'personal', authStatus: 'api-key' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByText('work — Anthropic')).toBeDefined()
    expect(screen.getByText('personal — Anthropic')).toBeDefined()
  })

  it('names the vault key and the default clause in the delete confirmation', async () => {
    providersState = [makeProvider({
      name: 'work', type: 'anthropic', typeDisplayName: 'Anthropic',
      displayName: 'work', authStatus: 'api-key',
    })]
    defaultProviderState = 'work'
    render(<ProvidersView />)
    await screen.findByText('default')
    fireEvent.click(screen.getByTestId('provider-row-work'))
    fireEvent.click(screen.getByTestId('provider-delete'))
    const box = screen.getByTestId('provider-delete-confirm')
    expect(box.textContent).toContain('PROVIDER_APIKEY_WORK')
    expect(box.textContent).toContain('clears it as default')
  })

  it('labels the button Reconfigure (with a warning) for an existing instance', () => {
    providersState = [
      makeProvider({ name: 'work', type: 'anthropic', typeDisplayName: 'Anthropic', displayName: 'work', authStatus: 'api-key', reconfiguring: true }),
      makeProvider({ name: 'anthropic', authStatus: 'none' }),
    ]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    fireEvent.change(screen.getByTestId('provider-name-input'), { target: { value: 'work' } })
    expect(screen.getByTestId('provider-reconfigure-warning')).toBeDefined()
    expect(screen.getByTestId('provider-save').textContent).toBe('Reconfigure')
  })

  it('posts {type,name} on create', async () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'none' })]
    createProvider.mockResolvedValue({ ok: true, provider: makeProvider({ name: 'anthropic', authStatus: 'api-key' }) })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    fireEvent.click(screen.getByTestId('provider-save'))
    await waitFor(() => expect(createProvider).toHaveBeenCalled())
    const arg = createProvider.mock.calls[0]![0] as Record<string, unknown>
    expect(arg.type).toBe('anthropic')
    expect(arg.name).toBe('anthropic')
  })

  it('renders the three legacy type rows with no problem rows (upgrade payload)', () => {
    providersState = [
      makeProvider({ name: 'anthropic', authStatus: 'api-key' }),
      makeProvider({ name: 'ollama', authStatus: 'keyless' }),
      makeProvider({ name: 'openai-compat', authStatus: 'keyless', baseUrl: 'http://localhost:8000/v1' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByTestId('provider-row-anthropic')).toBeDefined()
    expect(screen.getByTestId('provider-row-ollama')).toBeDefined()
    expect(screen.getByTestId('provider-row-openai-compat')).toBeDefined()
    expect(screen.queryByTestId('provider-problem')).toBeNull()
  })
})
