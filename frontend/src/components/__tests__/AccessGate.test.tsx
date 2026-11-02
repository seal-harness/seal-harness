import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { AccessGate } from '../AccessGate'

// ── Fake WebAuthn environment ────────────────────────────────────────────
//
// The gate talks to the real `lib/auth` module, so these tests exercise the
// actual ceremony plumbing: fetch for the options/verify endpoints and
// `navigator.credentials` for the authenticator.

class FakeCredential {
  rawId: ArrayBuffer
  response: Record<string, ArrayBuffer>
  constructor() {
    this.rawId = new ArrayBuffer(16)
    this.response = {
      clientDataJSON: new ArrayBuffer(8),
      attestationObject: new ArrayBuffer(8),
      authenticatorData: new ArrayBuffer(8),
      signature: new ArrayBuffer(8),
    }
  }
}

const createFn = vi.fn(async () => new FakeCredential())
const getFn = vi.fn(async () => new FakeCredential())

function installWebAuthn({ secure = true, supported = true } = {}) {
  Object.defineProperty(window, 'isSecureContext', { value: secure, configurable: true })
  ;(globalThis as unknown as { PublicKeyCredential?: unknown }).PublicKeyCredential =
    supported ? FakeCredential : undefined
  Object.defineProperty(navigator, 'credentials', {
    value: { create: createFn, get: getFn },
    configurable: true,
  })
}

// ── Fake gateway ─────────────────────────────────────────────────────────

type Status = {
  state: 'unconfigured' | 'open' | 'passkey'
  authenticated: boolean
  origin: string | null
  rp_id: string | null
  rp_mismatch: boolean
  setup_required: boolean
  credentials: number
  enrollment_via: 'cli_token' | 'cli_window' | 'assertion' | 'none'
  usable_credentials: number
  orphaned_credentials: number
}

let status: Status
let statusCalls = 0
let verifyHeaders: Record<string, string> = {}

const ok = (data: unknown) => Promise.resolve({ ok: true, json: async () => data } as Response)
const fail = (code: string, error: string, http = 403) =>
  Promise.resolve({ ok: false, status: http, json: async () => ({ code, error }) } as Response)

function installFetch() {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const headers = (init?.headers as Record<string, string>) ?? {}
    if (url.endsWith('/api/auth/register/verify')) verifyHeaders = headers
    if (url.endsWith('/api/auth/credentials/verify')) verifyHeaders = headers
    if (url.endsWith('/api/auth/status')) {
      statusCalls += 1
      return ok(status)
    }
    if (url.endsWith('/api/auth/register/options')) {
      return ok({
        challenge: 'AAAA',
        rp: { id: 'localhost', name: 'Seal Harness' },
        user: { id: 'AAAA', name: 'operator', displayName: 'operator' },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        timeout: 120000,
        attestation: 'none',
        authenticatorSelection: { userVerification: 'required', residentKey: 'preferred' },
        excludeCredentials: [],
      })
    }
    if (url.endsWith('/api/auth/login/options')) {
      return ok({
        challenge: 'AAAA',
        rpId: 'localhost',
        timeout: 120000,
        userVerification: 'required',
        allowCredentials: [],
      })
    }
    if (url.endsWith('/api/auth/register/verify')) {
      status = { ...status, state: 'passkey', authenticated: true, setup_required: false }
      return ok({ ok: true })
    }
    if (url.endsWith('/api/auth/login/verify')) {
      status = { ...status, authenticated: true }
      return ok({ ok: true })
    }
    if (url.endsWith('/api/auth/credentials/options')) {
      return ok({
        challenge: 'BBBB',
        rp: { id: 'localhost', name: 'Seal Harness' },
        user: { id: 'BBBB', name: 'operator', displayName: 'operator' },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        timeout: 120000,
        attestation: 'none',
        authenticatorSelection: { userVerification: 'required', residentKey: 'preferred' },
        excludeCredentials: [],
      })
    }
    if (url.endsWith('/api/auth/credentials/verify')) {
      status = { ...status, credentials: status.credentials + 1 }
      return ok({ ok: true })
    }
    if (url.endsWith('/api/auth/logout')) {
      status = { ...status, authenticated: false }
      return ok({ ok: true })
    }
    return fail('not_found', 'no such endpoint', 404)
  }))
}

beforeEach(() => {
  status = {
    state: 'unconfigured',
    authenticated: false,
    origin: 'http://localhost:8080',
    rp_id: 'localhost',
    rp_mismatch: false,
    setup_required: true,
    credentials: 0,
    enrollment_via: 'cli_token',
    usable_credentials: 0,
    orphaned_credentials: 0,
  }
  statusCalls = 0
  verifyHeaders = {}
  createFn.mockClear()
  getFn.mockClear()
  installWebAuthn()
  installFetch()
  window.history.replaceState(null, '', '/')
  window.sessionStorage.clear()
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function renderGate() {
  return render(<AccessGate><div>THE APP</div></AccessGate>)
}

describe('AccessGate', () => {
  it('shows the setup screen when unconfigured', async () => {
    renderGate()
    expect(await screen.findByText('Set up access control')).toBeInTheDocument()
    expect(screen.queryByText('THE APP')).not.toBeInTheDocument()
    // No setup code yet → the enroll button is disabled.
    expect(screen.getByRole('button', { name: /Register a passkey/ })).toBeDisabled()
  })

  it('enrolls a passkey and then renders the app', async () => {
    window.history.replaceState(null, '', '/#enroll=abc123')
    renderGate()
    await screen.findByText('Set up access control')
    // The token was captured from the fragment, so no typing is needed.
    expect(screen.getByLabelText('Enrollment token')).toHaveValue('')
    const button = screen.getByRole('button', { name: /Register a passkey/ })
    await waitFor(() => expect(button).toBeEnabled())
    fireEvent.click(button)
    expect(await screen.findByText('THE APP')).toBeInTheDocument()
    expect(createFn).toHaveBeenCalledTimes(1)
    // The token travelled in the documented header.
    expect(verifyHeaders['X-Seal-Enroll-Token']).toBe('abc123')
  })

  it('hides the token field and offers "Check again" when no grant is armed', async () => {
    status = { ...status, enrollment_via: 'none' }
    renderGate()
    await screen.findByText('Set up access control')
    expect(screen.queryByLabelText('Enrollment token')).not.toBeInTheDocument()
    expect(screen.getByText(/seal access-control enroll/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Register a passkey/ })).toBeDisabled()

    // The operator mints a token in the terminal; "Check again" re-reads.
    status = { ...status, enrollment_via: 'cli_token' }
    fireEvent.click(screen.getByRole('button', { name: /Check again/ }))
    expect(await screen.findByLabelText('Enrollment token')).toBeInTheDocument()
  })

  it('stops sending a token the server rejected, keeping the typed text', async () => {
    window.history.replaceState(null, '', '/')
    renderGate()
    await screen.findByText('Set up access control')
    fireEvent.change(screen.getByLabelText('Enrollment token'), { target: { value: 'deadbeef' } })
    // The options call refuses with grant_invalid.
    const realFetch = globalThis.fetch as unknown as (i: RequestInfo | URL, init?: RequestInit) => Promise<Response>
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith('/api/auth/register/options')) {
        return fail('grant_invalid', 'that enrollment token is not valid')
      }
      return realFetch(input, init)
    }))
    fireEvent.click(screen.getByRole('button', { name: /Register a passkey/ }))
    expect(await screen.findByText(/not valid/)).toBeInTheDocument()
    // The text is kept so it can be corrected...
    expect(screen.getByLabelText('Enrollment token')).toHaveValue('deadbeef')
    // ...but the stored token is gone, so a retry sends nothing.
    const stored = window.sessionStorage.getItem('seal.enroll-token')
    expect(stored === null || stored === '').toBe(true)
  })

  it('explains the step-up when an unauthenticated client cannot add a passkey', async () => {
    status = { ...status, state: 'passkey', authenticated: false, usable_credentials: 1, credentials: 1 }
    renderGate()
    await screen.findByText('Sign in to Seal Harness')
    // The token field is available: a token authorises enrollment from a
    // device that has no passkey yet.
    expect(screen.getByLabelText('Enrollment token')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Enroll a passkey on this device/ })).toBeDisabled()
  })

  it('shows the login screen and signs in', async () => {
    status = { ...status, state: 'passkey', authenticated: false, credentials: 1, usable_credentials: 1 }
    renderGate()
    expect(await screen.findByText('Sign in to Seal Harness')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Sign in with a passkey/ }))
    expect(await screen.findByText('THE APP')).toBeInTheDocument()
    expect(getFn).toHaveBeenCalledTimes(1)
  })

  it('renders the app directly when already authenticated', async () => {
    status = { ...status, state: 'passkey', authenticated: true, credentials: 1, usable_credentials: 1 }
    renderGate()
    expect(await screen.findByText('THE APP')).toBeInTheDocument()
  })

  it('disables passkey actions in an insecure context', async () => {
    const original = Object.getOwnPropertyDescriptor(window, 'isSecureContext')
    installWebAuthn({ secure: false })
    renderGate()
    await screen.findByText('Set up access control')
    expect(screen.getByText(/Passkeys need HTTPS or/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Register a passkey/ })).toBeDisabled()
    if (original) Object.defineProperty(window, 'isSecureContext', original)
  })

  it('explains an origin mismatch', async () => {
    status = { ...status, origin: 'http://seal.example.com' }
    renderGate()
    expect(await screen.findByText(/but this gateway verifies/)).toBeInTheDocument()
  })

  it('routes an orphaned-rpId boot to re-enrollment', async () => {
    status = {
      ...status,
      state: 'passkey',
      authenticated: false,
      rp_mismatch: true,
      credentials: 1,
      usable_credentials: 0,
      orphaned_credentials: 1,
    }
    renderGate()
    expect(await screen.findByText('Register a new passkey')).toBeInTheDocument()
    expect(screen.getByText(/registered for a different address/)).toBeInTheDocument()
  })

  it('re-fetches the status and re-applies the render table when the session changes', async () => {
    status = { ...status, state: 'passkey', authenticated: true, credentials: 1, usable_credentials: 1 }
    renderGate()
    await screen.findByText('THE APP')

    // The operator ran `seal access-control reset --yes` and restarted.
    status = {
      state: 'unconfigured',
      authenticated: false,
      origin: 'http://localhost:8080',
      rp_id: 'localhost',
      rp_mismatch: false,
      setup_required: true,
      credentials: 0,
      enrollment_via: 'cli_token',
      usable_credentials: 0,
      orphaned_credentials: 0,
    }
    const before = statusCalls
    window.dispatchEvent(new Event('seal-auth-changed'))
    expect(await screen.findByText('Set up access control')).toBeInTheDocument()
    expect(statusCalls).toBeGreaterThan(before)
  })
})
