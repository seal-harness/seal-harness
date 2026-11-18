import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { ProviderStep } from '../setup/ProviderStep'
import type { ProviderCard, SetupStep } from '../../lib/setupSteps'

function card(overrides: Partial<ProviderCard> = {}): ProviderCard {
  return {
    id: 'anthropic',
    label: 'Anthropic',
    configured: false,
    isDefault: false,
    default_model: null,
    requires_base_url: false,
    requires_name: false,
    ...overrides,
  }
}

function step(overrides: Partial<SetupStep> = {}): SetupStep {
  return {
    id: 'provider',
    required: true,
    status: 'pending',
    detail: 'Add an LLM provider: anthropic, openrouter, or ollama.',
    actions: ['configure'],
    ...overrides,
  }
}

const fetchMock = vi.fn()

beforeEach(() => {
  fetchMock.mockReset()
  vi.stubGlobal('fetch', fetchMock)
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function jsonResponse(status: number, body: unknown) {
  return { status, ok: status >= 200 && status < 300, json: async () => body } as Response
}

describe('ProviderStep', () => {
  it('renders from state.providers without calling /api/providers/all', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card(), card({ id: 'ollama', label: 'Ollama', configured: true })]}
        onDone={() => {}}
      />,
    )
    expect(screen.getByLabelText(/anthropic/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/ollama/i)).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('disables Test while dirty, enables it after save', async () => {
    fetchMock.mockImplementation(async (url: string) =>
      url === '/api/providers'
        ? jsonResponse(200, {})
        : jsonResponse(200, { ok: true, detail: 'reachable' }))
    render(<ProviderStep step={step()} providers={[card()]} onDone={() => {}} />)
    const testButton = screen.getByRole('button', { name: /test connection/i })
    expect(testButton).toBeEnabled()
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-test' } })
    expect(testButton).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: /save/i }))
    await waitFor(() => expect(testButton).toBeEnabled())
  })

  it('sends one POST and no default PUT on first run', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, {}))
    render(<ProviderStep step={step()} providers={[card()]} onDone={() => {}} />)
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-test' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith('/api/providers', expect.objectContaining({ method: 'POST' }))
    // No PUT /api/providers/default on first run: the single POST is enough.
    for (const [url] of fetchMock.mock.calls as [string][]) {
      expect(url).not.toMatch(/providers\/default/)
    }
  })

  // D7: requires_base_url means REQUIRED, not VISIBLE. Ollama's base URL is
  // optional but it is the only GUI path to a remote daemon, so the wizard
  // must render the field for it. Driving showBaseUrl off requires_base_url
  // hides it, which is the conflation D7 exists to forbid.
  it('item 41b (wizard): Ollama still shows an editable Base URL', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'ollama', label: 'Ollama', requires_base_url: false })]}
        onDone={() => {}}
      />,
    )
    // The list auto-selects the first provider, so this card drives the form.
    expect(screen.getByLabelText(/base url/i)).toBeInTheDocument()
  })

  // Rendering alone is NOT enough: a payload gated on requires_base_url would
  // render the field and then silently drop the typed URL, and only an
  // assertion on the SUBMITTED BODY can see that.
  it('item 41b (wizard): the typed Ollama base URL is SUBMITTED', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, {}))
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'ollama', label: 'Ollama', requires_base_url: false })]}
        onDone={() => {}}
      />,
    )
    fireEvent.change(screen.getByLabelText(/base url/i), {
      target: { value: 'http://192.168.1.9:11434' },
    })
    fireEvent.click(screen.getByRole('button', { name: /^save$/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const body = (fetchMock.mock.calls[0]?.[1] as RequestInit).body as string
    expect(body).toContain('192.168.1.9:11434')
  })

  // The counterpart: a built-in endpoint means the wizard must NOT ask.
  it('item 44 (wizard): an openai card renders no Base URL field', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'openai', label: 'OpenAI', requires_base_url: false, requires_name: false })]}
        onDone={() => {}}
      />,
    )
    expect(screen.queryByLabelText(/base url/i)).not.toBeInTheDocument()
  })

  it('renders loading, fetch-error and empty states', async () => {
    const { rerender } = render(<ProviderStep step={step()} providers={[]} onDone={() => {}} />)
    expect(screen.getByText(/no providers are available/i)).toBeInTheDocument()

    fetchMock.mockResolvedValue(jsonResponse(500, { error: 'vault is not open' }))
    rerender(<ProviderStep step={step()} providers={[card()]} onDone={() => {}} />)
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-test' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(/vault is not open/i))
  })

  it('lets an already-configured provider become the default', async () => {
    // A keyless local Ollama is `configured` on a fresh install, so there is
    // no credential to save. Before this, the step offered a permanently
    // disabled Save button and no way forward.
    const onDone = vi.fn()
    fetchMock.mockResolvedValue(jsonResponse(200, { default_provider: 'ollama' }))
    render(
      <ProviderStep
        step={step({ detail: 'Choose which provider new sessions should use.' })}
        providers={[
          card({ id: 'ollama', label: 'Ollama', configured: true }),
          card({ id: 'anthropic', configured: false }),
        ]}
        onDone={onDone}
      />,
    )
    const useBtn = screen.getByRole('button', { name: /use ollama/i })
    expect(useBtn).toBeEnabled()
    fireEvent.click(useBtn)
    await waitFor(() => expect(onDone).toHaveBeenCalled())
    expect(fetchMock).toHaveBeenCalledWith('/api/providers/default', expect.objectContaining({
      method: 'PUT',
      body: JSON.stringify({ provider: 'ollama' }),
    }))
  })

  // ── The provider list carries no status pills ────────────────────────
  //
  // The operator is choosing between names here. "configured" / "no
  // credential" / "Ready · 10 Models" are not decision inputs: readiness is
  // acted on at the point it matters — the CTA for the chosen provider — not
  // as decoration beside every name.

  it('renders no status pill beside any provider name', () => {
    render(
      <ProviderStep
        step={step({ detail: 'ollama · llama3.2' })}
        providers={[
          card({ id: 'ollama', label: 'Ollama', configured: true, readiness: 'ready', readiness_models: 10 }),
          card({ id: 'anthropic', configured: true }),
          card({ id: 'openrouter', configured: false }),
        ]}
        onDone={() => {}}
      />,
    )
    for (const id of ['ollama', 'anthropic', 'openrouter']) {
      expect(screen.queryByTestId(`setup-provider-pill-${id}`)).toBeNull()
      expect(screen.queryByTestId(`setup-provider-hint-${id}`)).toBeNull()
    }
    // The stale strings must not appear anywhere in the list either.
    expect(screen.queryByText('no credential')).toBeNull()
    expect(screen.queryByText('configured')).toBeNull()
    expect(screen.queryByText(/Ready · 10 Models/)).toBeNull()
  })

  it('still shows each provider name and the default marker', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[
          card({ id: 'anthropic', configured: true, isDefault: true }),
          card({ id: 'ollama', label: 'Ollama', configured: true, readiness: 'ready', readiness_models: 10 }),
        ]}
        onDone={() => {}}
      />,
    )
    expect(screen.getByText('Anthropic')).toBeDefined()
    expect(screen.getByText('Ollama')).toBeDefined()
    // `default` is the one badge that IS a decision input, so it stays.
    expect(screen.getByText('default')).toBeDefined()
  })

  // ── Unusable provider: disable the CTA, explain, and stay escapable ──

  it('disables `Use Ollama` when Ollama is not running', () => {
    render(
      <ProviderStep
        step={step({ detail: 'ollama · llama3.2' })}
        providers={[card({ id: 'ollama', label: 'Ollama', configured: true, readiness: 'not-running' })]}
        onDone={() => {}}
      />,
    )
    expect(screen.getByRole('button', { name: /use ollama/i })).toBeDisabled()
  })

  it('explains why, and names the remedy', () => {
    render(
      <ProviderStep
        step={step({ detail: 'ollama · llama3.2' })}
        providers={[card({ id: 'ollama', label: 'Ollama', configured: true, readiness: 'not-running' })]}
        onDone={() => {}}
      />,
    )
    const note = screen.getByTestId('setup-provider-blocked')
    expect(note.textContent).toContain('ollama serve')
  })

  it.each(['not-installed', 'not-running', 'no-models'] as const)(
    'blocks selection for %s',
    (readiness) => {
      render(
        <ProviderStep
          step={step({ detail: 'ollama · llama3.2' })}
          providers={[card({ id: 'ollama', label: 'Ollama', configured: true, readiness })]}
          onDone={() => {}}
        />,
      )
      expect(screen.getByRole('button', { name: /use ollama/i })).toBeDisabled()
      expect(screen.getByTestId('setup-provider-blocked')).toBeDefined()
    },
  )

  it.each(['pending', 'unknown', 'cloud', 'no-fitting-model'] as const)(
    'does NOT block selection for %s (not a claim of absence, or advisory)',
    (readiness) => {
      render(
        <ProviderStep
          step={step({ detail: 'ollama · llama3.2' })}
          providers={[card({ id: 'ollama', label: 'Ollama', configured: true, readiness })]}
          onDone={() => {}}
        />,
      )
      expect(screen.getByRole('button', { name: /use ollama/i })).toBeEnabled()
      expect(screen.queryByTestId('setup-provider-blocked')).toBeNull()
    },
  )

  it('a ready Ollama is selectable', () => {
    render(
      <ProviderStep
        step={step({ detail: 'ollama · llama3.2' })}
        providers={[card({
          id: 'ollama', label: 'Ollama', configured: true,
          readiness: 'ready', readiness_models: 10,
        })]}
        onDone={() => {}}
      />,
    )
    expect(screen.getByRole('button', { name: /use ollama/i })).toBeEnabled()
  })

  it('a card with no readiness at all stays selectable (non-Ollama)', () => {
    render(
      <ProviderStep step={step()} providers={[card({ id: 'anthropic', configured: true })]} onDone={() => {}} />,
    )
    expect(screen.getByRole('button', { name: /use anthropic/i })).toBeEnabled()
  })

  it('offers a two-step escape hatch so an unusable Ollama cannot hard-block setup', async () => {
    // Ollama's `configured` is true from config alone, so on a machine that
    // never installed it `required_complete` is already true and this wizard is
    // the only screen the operator sees. A disabled button with no way forward
    // would lock them out of the product.
    const onDone = vi.fn()
    render(
      <ProviderStep
        step={step({ detail: 'ollama · llama3.2' })}
        providers={[card({ id: 'ollama', label: 'Ollama', configured: true, readiness: 'not-running' })]}
        onDone={onDone}
      />,
    )
    fireEvent.click(screen.getByTestId('setup-provider-skip'))
    // Asks once, and says what the consequence is.
    expect(screen.getByTestId('setup-provider-skip-confirm')).toBeDefined()
    expect(screen.getByText(/messages will fail until/i)).toBeDefined()
    expect(onDone).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('setup-provider-skip-confirm'))
    expect(onDone).toHaveBeenCalled()
  })

  it('the escape hatch is absent when the provider is usable', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'anthropic', configured: true })]}
        onDone={() => {}}
      />,
    )
    expect(screen.queryByTestId('setup-provider-skip')).toBeNull()
  })

  it('requires a base URL and a unique name for the generic OpenAI-compatible provider', async () => {
    fetchMock.mockResolvedValue(jsonResponse(201, { name: 'openai' }))
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'openai-compatible', label: 'OpenAI-compatible', requires_base_url: true, requires_name: true })]}
        onDone={() => {}}
      />,
    )
    const save = screen.getByRole('button', { name: /^save$/i })
    // A key alone is not enough: this provider has no built-in endpoint.
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-local' } })
    expect(save).toBeDisabled()
    // ...and a non-URL is rejected before it reaches the server.
    fireEvent.change(screen.getByLabelText(/base url/i), { target: { value: 'localhost:8000' } })
    expect(save).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/base url/i), { target: { value: 'http://localhost:8000/v1' } })
    // The instance also needs a unique name before Save is enabled.
    expect(save).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/unique name/i), { target: { value: 'local-vllm' } })
    expect(save).toBeEnabled()
    fireEvent.click(save)
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(fetchMock).toHaveBeenCalledWith('/api/providers', expect.objectContaining({
      body: JSON.stringify({
        name: 'local-vllm',
        type: 'openai-compatible',
        api_key: 'sk-local',
        base_url: 'http://localhost:8000/v1',
        models: [],
      }),
    }))
  })

  it('sends the frequent-model list from the setup form', async () => {
    fetchMock.mockResolvedValue(jsonResponse(201, { name: 'anthropic' }))
    render(<ProviderStep step={step()} providers={[card()]} onDone={() => {}} />)
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-ant' } })
    fireEvent.change(screen.getByLabelText(/frequent models/i), {
      target: { value: 'claude-opus-4-8\nclaude-sonnet-4' },
    })
    fireEvent.click(screen.getByRole('button', { name: /^save$/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const body = JSON.parse((fetchMock.mock.calls[0]?.[1] as RequestInit).body as string)
    expect(body.models).toEqual(['claude-opus-4-8', 'claude-sonnet-4'])
  })

  it('seeds an existing frequent-model list from the provider card', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card({ models: ['claude-opus-4-8', 'claude-sonnet-4'] })]}
        onDone={() => {}}
      />,
    )
    const models = screen.getByLabelText(/frequent models/i) as HTMLTextAreaElement
    expect(models.value).toBe('claude-opus-4-8\nclaude-sonnet-4')
  })

  // D7's visibility table: anthropic's base URL is VISIBLE (today's behaviour)
  // even though it is not required, and an empty one is not sent. The old
  // version of this test asserted the field was absent, encoding the
  // over-broad "hidden for every built-in endpoint" rule that D7 replaces.
  it('sends no base_url for a provider whose field was left empty', async () => {
    fetchMock.mockResolvedValue(jsonResponse(201, { name: 'anthropic' }))
    render(<ProviderStep step={step()} providers={[card()]} onDone={() => {}} />)
    expect(screen.getByLabelText(/api endpoint/i)).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText(/api key/i), { target: { value: 'sk-ant' } })
    fireEvent.click(screen.getByRole('button', { name: /^save$/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    const body = (fetchMock.mock.calls[0]?.[1] as RequestInit).body as string
    expect(body).not.toContain('base_url')
  })

  it('offers no save action when the provider is already the default', () => {
    render(
      <ProviderStep
        step={step()}
        providers={[card({ id: 'ollama', label: 'Ollama', configured: true, isDefault: true })]}
        onDone={() => {}}
      />,
    )
    expect(screen.getByRole('button', { name: /is the default/i })).toBeDisabled()
  })

  it('renders an inline failure and the partial-default message', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { ok: false, error: 'invalid key' }))
    render(
      <ProviderStep
        step={step({ detail: 'Choose which provider new sessions should use.' })}
        providers={[card({ configured: true }), card({ id: 'ollama', label: 'Ollama', configured: true })]}
        onDone={() => {}}
      />,
    )
    // The server's "no default yet" copy is rendered verbatim.
    expect(screen.getByText(/choose which provider/i)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /test connection/i }))
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent(/connection failed: invalid key/i))
  })
})
