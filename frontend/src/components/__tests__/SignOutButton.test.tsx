import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { SignOutButton } from '../SignOutButton'
import { AUTH_CHANGED_EVENT } from '../../lib/unauthorized'

type Status = {
  state: 'unconfigured' | 'open' | 'passkey'
  authenticated: boolean
}

let status: Status
let logoutCalls = 0

function installFetch() {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    if (url.endsWith('/api/auth/status')) {
      return {
        ok: true,
        status: 200,
        json: async () => ({
          ...status,
          origin: 'http://localhost:8080',
          rp_id: 'localhost',
          rp_mismatch: false,
          setup_required: status.state === 'unconfigured',
          credentials: 1,
        }),
      } as Response
    }
    if (url.endsWith('/api/auth/logout')) {
      logoutCalls += 1
      // A real gateway drops the session cookie, so the next status read says
      // "not authenticated".
      status = { state: 'passkey', authenticated: false }
      return { ok: true, status: 200, json: async () => ({ ok: true }) } as Response
    }
    return { ok: false, status: 404, json: async () => ({ code: 'not_found' }) } as Response
  }))
}

beforeEach(() => {
  status = { state: 'passkey', authenticated: true }
  logoutCalls = 0
  installFetch()
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('SignOutButton', () => {
  it('renders when a passkey session is active', async () => {
    render(<SignOutButton />)
    expect(await screen.findByRole('button', { name: 'Sign out' })).toBeInTheDocument()
  })

  it('renders nothing when access control is open', async () => {
    status = { state: 'open', authenticated: true }
    render(<SignOutButton />)
    // Give the status fetch a chance to resolve.
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalled())
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument()
  })

  it('renders nothing when unconfigured, or when not signed in', async () => {
    status = { state: 'unconfigured', authenticated: false }
    const first = render(<SignOutButton />)
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalled())
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument()
    first.unmount()

    status = { state: 'passkey', authenticated: false }
    render(<SignOutButton />)
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalled())
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument()
  })

  it('calls the logout endpoint and raises the auth-changed event', async () => {
    const seen: Event[] = []
    const listener = (e: Event) => seen.push(e)
    window.addEventListener(AUTH_CHANGED_EVENT, listener)

    const reloadPage = vi.fn()
    render(<SignOutButton reloadPage={reloadPage} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))

    await waitFor(() => expect(logoutCalls).toBe(1))
    await waitFor(() => expect(seen.length).toBeGreaterThan(0))
    // The control disappears once the session is gone.
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument(),
    )

    // The page reload is what closes the live WebSocket and clears in-memory
    // transcripts, so it must happen.
    await waitFor(() => expect(reloadPage).toHaveBeenCalledTimes(1))

    window.removeEventListener(AUTH_CHANGED_EVENT, listener)
  })
})
