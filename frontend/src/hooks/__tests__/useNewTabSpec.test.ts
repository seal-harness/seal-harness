import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useNewTabSpec } from '../useNewTabSpec'

// The persisted UI state to return from GET /api/ui/state. Tests can override
// via `setUiStateResponse`.
let uiStateResponse: unknown = { last_options: null, custom_models: [] }

beforeEach(() => {
  uiStateResponse = { last_options: null, custom_models: [] }
  vi.stubGlobal('fetch', vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/agents') return new Response(JSON.stringify([{ name: 'dev', isDefault: true }]), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/providers') return new Response(JSON.stringify([{ name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4' }]), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/providers/anthropic/models') return new Response(JSON.stringify([{ name: 'claude-sonnet-4', contextWindow: 200000 }]), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/harnesses/discover') return new Response(JSON.stringify([]), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/ui/state' && (!init || init.method === 'GET')) return new Response(JSON.stringify(uiStateResponse), { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/ui/state' && init?.method === 'PUT') return new Response('{"ok":true}', { status: 200, headers: { 'Content-Type': 'application/json' } })
    if (url === '/api/ui/custom-models' && init?.method === 'POST') return new Response('{"ok":true}', { status: 200, headers: { 'Content-Type': 'application/json' } })
    return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } })
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('useNewTabSpec', () => {
  it('defaults to kind=provider and auto-loads providers + models + agent', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    expect(result.current.kind).toBe('provider')
    await waitFor(() => expect(result.current.providersLoaded).toBe(true))
    await waitFor(() => expect(result.current.models.length).toBeGreaterThan(0))
    await waitFor(() => expect(result.current.agent).toBe('dev'))
    expect(result.current.provider).toBe('anthropic')
    expect(result.current.model).toBe('claude-sonnet-4')
    expect(result.current.validationError).toBeNull()
  })

  it('buildBody produces the flat CreateTabBody for kind=provider', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.model).toBe('claude-sonnet-4'))
    const body = result.current.buildBody()
    expect(body).toEqual({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4', agent: 'dev' })
  })

  it('buildBody produces {kind:"harness", harness_id:flavour} for kind=harness', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.providersLoaded).toBe(true))
    act(() => result.current.setKind('harness'))
    const body = result.current.buildBody()
    expect(body.kind).toBe('harness')
    expect(body.harness_id).toBe('claude-code')
  })

  it('buildBody encodes custom binary as custom:<binary> for kind=harness', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.providersLoaded).toBe(true))
    act(() => {
      result.current.setKind('harness')
      result.current.setFlavour('custom')
      result.current.setCustomBinary('my-tool')
    })
    const body = result.current.buildBody()
    expect(body.harness_id).toBe('custom:my-tool')
  })

  it('validationError fires for custom flavour with no binary', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.providersLoaded).toBe(true))
    act(() => {
      result.current.setKind('harness')
      result.current.setFlavour('custom')
    })
    expect(result.current.validationError).toBe('Binary name is required for custom flavour')
  })

  it('validationError fires for attach with no session', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.providersLoaded).toBe(true))
    act(() => result.current.setKind('attach'))
    expect(result.current.validationError).toBe('Pick or enter a session to attach to')
  })

  it('loads customModels from the persisted UI state', async () => {
    uiStateResponse = { last_options: null, custom_models: ['claude-3-opus', 'gpt-4o'] }
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.customModels).toEqual(['claude-3-opus', 'gpt-4o']))
  })

  it('persistOnSubmit PUTs last_options and records the custom model', async () => {
    const { result } = renderHook(() => useNewTabSpec())
    await waitFor(() => expect(result.current.model).toBe('claude-sonnet-4'))
    act(() => {
      result.current.handleModelSelectChange('__custom__')
      result.current.setModel('claude-3-opus-20240229')
    })
    act(() => result.current.persistOnSubmit())
    await waitFor(() => {
      const calls = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls
      const put = calls.find(([u, init]) => u === '/api/ui/state' && init?.method === 'PUT')
      const add = calls.find(([u, init]) => u === '/api/ui/custom-models' && init?.method === 'POST')
      expect(put).toBeTruthy()
      expect(add).toBeTruthy()
      if (put) {
        const body = JSON.parse((put[1]!.body as string))
        expect(body.model).toBe('claude-3-opus-20240229')
        expect(body.useCustomModel).toBe(true)
      }
      if (add) {
        const body = JSON.parse((add[1]!.body as string))
        expect(body.model).toBe('claude-3-opus-20240229')
      }
    })
    // The custom-model list is updated optimistically.
    expect(result.current.customModels).toContain('claude-3-opus-20240229')
  })
})