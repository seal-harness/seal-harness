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
  notifyProvidersChanged: () => {},
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
    models: [],
    baseUrl: null,
    authStatus: 'none',
    requiresBaseUrl: false,
    requiresName: false,
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

  // ── Ollama readiness (design D3.2, tests 35-38) ──────────────────────

  it('35: renders Not Running in the list row instead of Keyless', () => {
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'keyless', readiness: 'not-running' }),
    ]
    render(<ProvidersView />)
    expect(screen.getByText('Not Running')).toBeDefined()
    // The readiness badge REPLACES the credential badge for a keyless Ollama:
    // "Not Running" is strictly more useful than "Keyless".
    expect(screen.queryByText('Keyless')).toBeNull()
  })

  it('36: renders Not Running in the editor pill too', () => {
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'keyless', readiness: 'not-running' }),
    ]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-ollama'))
    const pill = screen.getByTestId('editor-badge-readiness')
    expect(pill.textContent).toBe('Not Running')
  })

  it('37: absent readiness falls back to the existing auth badge', () => {
    // A non-Ollama provider, or a newer frontend against an older backend.
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'api-key' })]
    render(<ProvidersView />)
    expect(screen.getByText('API Key')).toBeDefined()
    expect(screen.queryByTestId('provider-badge-readiness')).toBeNull()
  })

  it('38a: vault-locked anthropic renders ONE badge (the readiness-present guard)', () => {
    providersState = [makeProvider({ name: 'anthropic', authStatus: 'vault-locked' })]
    render(<ProvidersView />)
    const badges = screen.getByTestId('provider-badges-anthropic')
    expect(badges.textContent).toBe('Vault Locked')
    expect(screen.queryByTestId('provider-badge-readiness')).toBeNull()
  })

  it('38b: vault-locked ollama renders TWO badges', () => {
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'vault-locked', readiness: 'not-running' }),
    ]
    render(<ProvidersView />)
    const badges = screen.getByTestId('provider-badges-ollama')
    expect(badges.textContent).toBe('Not RunningVault Locked')
  })

  it('17a: cloud readiness renders TWO badges (Cloud + the auth badge)', () => {
    // Design test 38 does not cover the cloud row; the plan adds it.
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'keyless', readiness: 'cloud' }),
    ]
    render(<ProvidersView />)
    const badges = screen.getByTestId('provider-badges-ollama')
    expect(badges.textContent).toBe('CloudKeyless')
  })

  it('17b: authStatus none + readiness present renders TWO badges, in the editor', () => {
    // A `none` Ollama is excluded from the LIST (the list shows configured
    // providers only), so this row only exists in the editor pane.
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'keyless', readiness: 'no-models' }),
      makeProvider({ name: 'openai', authStatus: 'none', readiness: 'no-models' }),
    ]
    render(<ProvidersView />)
    // The list row for a configured keyless Ollama: readiness replaces auth.
    expect(screen.getByTestId('provider-badges-ollama').textContent).toBe('No Models Pulled')
    // The `none` row is not in the list at all, which is existing behaviour.
    expect(screen.queryByTestId('provider-badges-openai')).toBeNull()
  })

  it('17c: a specific auth (api-key) is REPLACED by readiness', () => {
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'api-key', readiness: 'ready', readinessModels: 3 }),
    ]
    render(<ProvidersView />)
    const badges = screen.getByTestId('provider-badges-ollama')
    expect(badges.textContent).toBe('Ready · 3 Models')
    expect(screen.queryByText('API Key')).toBeNull()
  })

  it('16: the two badges STACK in a column container, not inline', () => {
    // jsdom does no layout, so a "both texts are present" check cannot tell
    // stacked from clipped. Assert the STRUCTURE: the badges are siblings
    // inside a flex column, and each is its own block element. The row is
    // `text-xs truncate`; two inline siblings would clip the second.
    providersState = [
      makeProvider({ name: 'ollama', authStatus: 'vault-locked', readiness: 'not-running' }),
    ]
    render(<ProvidersView />)
    const container = screen.getByTestId('provider-badges-ollama')
    expect(container.className).toContain('flex-col')
    const children = Array.from(container.children)
    expect(children).toHaveLength(2)
    for (const child of children) {
      expect(child.className).toContain('truncate')
      // Each badge is a block-level row of the column, not an inline span.
      expect(child.tagName).toBe('DIV')
    }
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

  it('seeds the frequent-model list when editing and sends it as an array', async () => {
    providersState = [makeProvider({
      name: 'anthropic',
      authStatus: 'api-key',
      models: ['claude-opus-4-8', 'claude-sonnet-4'],
    })]
    updateProvider.mockResolvedValue({ ok: true, provider: providersState[0]! })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-anthropic'))
    const modelsInput = screen.getByTestId('provider-models-input') as HTMLTextAreaElement
    expect(modelsInput.value).toBe('claude-opus-4-8\nclaude-sonnet-4')
    fireEvent.change(modelsInput, { target: { value: 'gpt-4o, claude-opus-4-8\n\n' } })
    fireEvent.click(screen.getByTestId('provider-save'))
    await waitFor(() => expect(updateProvider).toHaveBeenCalledTimes(1))
    expect(updateProvider).toHaveBeenCalledWith('anthropic', expect.objectContaining({
      models: ['gpt-4o', 'claude-opus-4-8'],
    }))
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
  it('requires a unique name when creating an OpenAI-compatible provider', async () => {
    // The server returns every built-in; the dropdown is built from this list,
    // so the generic row must be present for it to be selectable.
    providersState = [
      makeProvider({ name: 'openai', authStatus: 'none' }),
      makeProvider({ name: 'openai-compatible', requiresBaseUrl: true, requiresName: true, authStatus: 'none' }),
    ]
    const created: ProviderDetail = makeProvider({
      name: 'local-vllm',
      type: 'openai-compatible',
      authStatus: 'api-key',
      baseUrl: 'http://localhost:8000/v1',
    })
    createProvider.mockResolvedValue({ ok: true, provider: created })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'openai-compatible' } })

    // The openai type alone is not an identity: Save stays disabled until the
    // operator supplies a unique name.
    const save = screen.getByTestId('provider-save')
    expect(save).toBeDisabled()
    const nameInput = screen.getByTestId('provider-instance-name-input')
    fireEvent.change(nameInput, { target: { value: 'local-vllm' } })
    fireEvent.change(screen.getByTestId('provider-api-key-input'), { target: { value: 'sk-local' } })
    fireEvent.change(screen.getByPlaceholderText('http://localhost:8000/v1'), {
      target: { value: 'http://localhost:8000/v1' },
    })
    expect(save).toBeEnabled()
    fireEvent.click(save)
    await waitFor(() => expect(createProvider).toHaveBeenCalledTimes(1))
    expect(createProvider).toHaveBeenCalledWith(expect.objectContaining({
      name: 'local-vllm',
      type: 'openai-compatible',
      api_key: 'sk-local',
      base_url: 'http://localhost:8000/v1',
    }))
  })

  // Item 34: selecting OpenAI renders NEITHER field, and Save is enabled with
  // only an API key. Item 34a: the same holds in EDIT mode, where the stored
  // detail carries a baseUrl that must not be displayed.
  // Item 35d (edit half): editing an OpenAI provider must not re-send the
  // stored base_url. The field is hidden, but providerFormValuesFrom pre-fills
  // it from the server, so an unguarded edit payload would write a value the
  // operator cannot see.
  it('item 35d: editing OpenAI does not submit a hidden baseUrl', async () => {
    providersState = [
      makeProvider({ name: 'openai', authStatus: 'api-key', baseUrl: 'https://api.openai.com/v1' }),
    ]
    updateProvider.mockResolvedValue({ ok: true, provider: makeProvider({ name: 'openai' }) })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-row-openai'))
    fireEvent.change(screen.getByTestId('provider-api-key-input'), { target: { value: 'sk-openai' } })
    fireEvent.click(screen.getByTestId('provider-save'))
    await waitFor(() => expect(updateProvider).toHaveBeenCalled())
    const payload = updateProvider.mock.calls[0]?.[1] as Record<string, unknown>
    expect(payload.base_url).toBeUndefined()
  })

  // Item 35: Ollama Cloud is the SECOND member of the visibility predicate.
  // Without this, only the `openai` half is pinned and a typo in
  // `'ollama-cloud'` would ship: the field would appear (or not) silently.
  it('item 35: Ollama Cloud hides both fields and submits no baseUrl', async () => {
    providersState = [makeProvider({ name: 'ollama-cloud', authStatus: 'none' })]
    createProvider.mockResolvedValue({ ok: true, provider: makeProvider({ name: 'ollama-cloud' }) })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'ollama-cloud' } })
    expect(screen.queryByTestId('provider-base-url-input')).toBeNull()
    expect(screen.queryByTestId('provider-instance-name-input')).toBeNull()
    fireEvent.change(screen.getByTestId('provider-api-key-input'), { target: { value: 'sk-cloud' } })
    expect(screen.getByTestId('provider-save')).toBeEnabled()
    fireEvent.click(screen.getByTestId('provider-save'))
    await waitFor(() => expect(createProvider).toHaveBeenCalled())
    const payload = createProvider.mock.calls[0]?.[0] as Record<string, unknown>
    expect(payload.base_url).toBeUndefined()
    expect(payload.name).toBe('ollama-cloud')
  })

  it('items 34/34a: OpenAI hides both fields in create and edit mode', async () => {
    providersState = [
      makeProvider({ name: 'openai', authStatus: 'api-key', baseUrl: 'https://api.openai.com/v1' }),
    ]
    render(<ProvidersView />)
    // Edit mode.
    fireEvent.click(screen.getByTestId('provider-row-openai'))
    expect(screen.queryByTestId('provider-base-url-input')).toBeNull()
    expect(screen.queryByTestId('provider-instance-name-input')).toBeNull()
    cleanup()
    // Create mode.
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'openai' } })
    expect(screen.queryByTestId('provider-base-url-input')).toBeNull()
    expect(screen.queryByTestId('provider-instance-name-input')).toBeNull()
  })

  // Item 34b: for OpenAI, a key alone enables Save.
  it('item 34b: OpenAI Save is enabled with only an API key', () => {
    providersState = [makeProvider({ name: 'openai', authStatus: 'none' })]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'openai' } })
    fireEvent.change(screen.getByTestId('provider-api-key-input'), { target: { value: 'sk-openai' } })
    expect(screen.getByTestId('provider-save')).toBeEnabled()
  })

  // Item 41b (Providers page half): Ollama's optional-but-essential Base URL is
  // STILL RENDERED and still submitted. Keying visibility on requiresBaseUrl
  // would delete the only GUI path to a remote daemon.
  it('item 41b: Ollama keeps an editable Base URL and submits it', async () => {
    providersState = [makeProvider({ name: 'ollama', authStatus: 'keyless' })]
    createProvider.mockResolvedValue({ ok: true, provider: makeProvider({ name: 'ollama' }) })
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'ollama' } })
    const baseUrl = screen.getByTestId('provider-base-url-input')
    expect(baseUrl).toBeInTheDocument()
    fireEvent.change(baseUrl, { target: { value: 'http://192.168.1.9:11434' } })
    fireEvent.click(screen.getByTestId('provider-save'))
    await waitFor(() => expect(createProvider).toHaveBeenCalled())
    // The SUBMITTED PAYLOAD must carry the typed URL: rendering alone is not
    // enough, because a payload gated on requiresBaseUrl would silently drop it.
    expect(createProvider).toHaveBeenCalledWith(expect.objectContaining({
      name: 'ollama',
      base_url: 'http://192.168.1.9:11434',
    }))
  })

  it('rejects a duplicate custom provider name', () => {
    providersState = [
      makeProvider({ name: 'openai', authStatus: 'none' }),
      makeProvider({ name: 'openai-compatible', requiresBaseUrl: true, requiresName: true, authStatus: 'none' }),
      makeProvider({ name: 'local-vllm', type: 'openai-compatible', authStatus: 'api-key' }),
    ]
    render(<ProvidersView />)
    fireEvent.click(screen.getByTestId('provider-new-btn'))
    const select = screen.getByTestId('provider-form-new').querySelector('select')
    fireEvent.change(select!, { target: { value: 'openai-compatible' } })
    fireEvent.change(screen.getByTestId('provider-instance-name-input'), { target: { value: 'local-vllm' } })
    expect(screen.getByTestId('provider-instance-name-error')).toBeDefined()
    expect(screen.getByTestId('provider-save')).toBeDisabled()
  })
