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
