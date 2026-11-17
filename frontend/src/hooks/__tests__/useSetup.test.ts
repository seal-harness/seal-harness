import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useSetupState } from '../useSetup'

/**
 * Test 43 (design D2.5), the `useSetupState` half.
 *
 * No such test existed before: the plan requires focus-refetch coverage for
 * both hooks, and this file is where the wizard's hook is pinned.
 *
 * Why it matters: `/api/setup`'s cards carry Ollama readiness, and the hook
 * otherwise fetches on mount + mutation only. Without a focus refetch, an
 * operator who starts the daemon in another window keeps seeing "Not Running"
 * in the wizard until a page reload.
 */

function setupWire(ollamaReadiness: unknown) {
  return {
    required_complete: false,
    steps: [
      {
        id: 'provider',
        required: true,
        status: 'ready',
        detail: 'ollama · llama3.2',
        actions: [],
      },
    ],
    providers: [
      {
        id: 'ollama',
        label: 'Ollama',
        configured: true,
        isDefault: false,
        default_model: 'llama3.2',
        requires_base_url: false,
        requires_name: false,
        ...(ollamaReadiness === undefined ? {} : { readiness: ollamaReadiness }),
      },
    ],
  }
}

const fetchMock = vi.fn()

beforeEach(() => {
  fetchMock.mockReset()
  vi.stubGlobal('fetch', fetchMock)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

function ok(body: unknown) {
  return { status: 200, ok: true, json: async () => body } as Response
}

describe('useSetupState', () => {
  it('fetches GET /api/setup on mount and parses readiness', async () => {
    fetchMock.mockResolvedValue(ok(setupWire('not-running')))
    const { result } = renderHook(() => useSetupState())
    await waitFor(() => expect(result.current.state).not.toBeNull())
    expect(result.current.state?.providers[0]?.readiness).toBe('not-running')
  })

  it('43: re-fetches when the window regains focus', async () => {
    fetchMock.mockResolvedValue(ok(setupWire('not-running')))
    const { result } = renderHook(() => useSetupState())
    await waitFor(() => expect(result.current.state?.providers[0]?.readiness).toBe('not-running'))
    const callsAfterMount = fetchMock.mock.calls.length

    // The operator starts Ollama in another window; returning fires `focus`,
    // and the card must update without a reload.
    fetchMock.mockResolvedValue(ok(setupWire('ready')))
    act(() => { window.dispatchEvent(new Event('focus')) })

    await waitFor(() => expect(result.current.state?.providers[0]?.readiness).toBe('ready'))
    // A second request actually happened (not just a state reshuffle).
    expect(fetchMock.mock.calls.length).toBeGreaterThan(callsAfterMount)
  })

  it('leaves the card with no readiness when the server omits it', async () => {
    fetchMock.mockResolvedValue(ok(setupWire(undefined)))
    const { result } = renderHook(() => useSetupState())
    await waitFor(() => expect(result.current.state).not.toBeNull())
    expect(result.current.state?.providers[0]?.readiness).toBeUndefined()
  })
})
