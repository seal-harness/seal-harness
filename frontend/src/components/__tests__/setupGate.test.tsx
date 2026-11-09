import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { SetupGate } from '../setup/SetupGate'

const setupPayload = {
  required_complete: false,
  steps: [
    { id: 'vault', required: true, status: 'pending', detail: 'Create a vault.', actions: ['create'] },
    { id: 'provider', required: true, status: 'pending', detail: 'Add a provider.', actions: ['configure'] },
  ],
  providers: [],
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

describe('SetupGate', () => {
  it('shows the wizard when required_complete is false', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, setupPayload))
    render(<SetupGate><div>the app</div></SetupGate>)
    await waitFor(() => expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Create your vault'))
    // The page says what it is, above the step (design review: a first-run
    // operator landing on a bare card had no idea which screen this was).
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Seal Harness Setup Wizard')
    expect(screen.queryByText('the app')).toBeNull()
  })

  it('renders the app when required_complete is true', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, {
      ...setupPayload,
      required_complete: true,
      steps: setupPayload.steps.map((s) => ({ ...s, status: 'ready' })),
    }))
    render(<SetupGate><div>the app</div></SetupGate>)
    await waitFor(() => expect(screen.getByText('the app')).toBeInTheDocument())
  })

  it('fails closed on a probe error, with Retry', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(500, { error: 'boom' }))
    render(<SetupGate><div>the app</div></SetupGate>)
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(/boom/i))
    expect(screen.queryByText('the app')).toBeNull()
    fetchMock.mockResolvedValueOnce(jsonResponse(200, setupPayload))
    fireEvent.click(screen.getByRole('button', { name: /retry/i }))
    await waitFor(() => expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Create your vault'))
  })

  it('does not reveal the app merely because the steps completed', async () => {
    // The e2e caught the first version of this gate revealing the app the
    // instant the server said required_complete — which made the completion
    // screen unreachable. Completion must wait for Start chatting.
    const incomplete = {
      ...setupPayload,
      steps: [
        { id: 'vault', required: true, status: 'blocked', detail: 'Reopen it.', actions: ['recheck'] },
        { id: 'provider', required: true, status: 'ready', detail: null, actions: [] },
      ],
    }
    const complete = {
      ...setupPayload,
      required_complete: true,
      steps: setupPayload.steps.map((s) => ({ ...s, status: 'ready' })),
    }
    fetchMock.mockResolvedValueOnce(jsonResponse(200, incomplete))
    render(<SetupGate><div>the app</div></SetupGate>)
    await waitFor(() => expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Create your vault'))

    // Re-check re-probes; the server now says everything is ready.
    fetchMock.mockResolvedValueOnce(jsonResponse(200, complete))
    fireEvent.click(screen.getByRole('button', { name: /re-check/i }))
    await waitFor(() => expect(screen.getByRole('heading', { level: 2, name: 'Setup complete' })).toBeInTheDocument())
    expect(screen.queryByText('the app')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: /start chatting/i }))
    await waitFor(() => expect(screen.getByText('the app')).toBeInTheDocument())
  })

  it('keeps an /api/sessions error from painting over the wizard', async () => {
    // The gate must only ever ask /api/setup: a failing /api/sessions (e.g.
    // the app's own startup probe) is the app's problem, not the wizard's.
    fetchMock.mockImplementation(async (url: string) => {
      if (url === '/api/setup') return jsonResponse(200, setupPayload)
      return jsonResponse(500, { error: 'sessions exploded' })
    })
    render(<SetupGate><div>the app</div></SetupGate>)
    await waitFor(() => expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Create your vault'))
    for (const [url] of fetchMock.mock.calls as [string][]) {
      expect(url).toBe('/api/setup')
    }
    expect(screen.queryByText(/sessions exploded/)).toBeNull()
  })
})
