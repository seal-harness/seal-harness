import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { AccessView } from '../AccessView'

// ── Fake WebAuthn environment (same shape as the gate's tests) ───────────

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

function installWebAuthn() {
  Object.defineProperty(window, 'isSecureContext', { value: true, configurable: true })
  ;(globalThis as unknown as { PublicKeyCredential?: unknown }).PublicKeyCredential = FakeCredential
  Object.defineProperty(navigator, 'credentials', {
    value: { create: createFn, get: getFn },
    configurable: true,
  })
}

// ── Fake gateway ─────────────────────────────────────────────────────────

type Cred = {
  id: string
  label: string
  created_at: string
  sign_count: number
  rp_id: string
  current: boolean
  added_via?: string | null
}

let status: Record<string, unknown>
let creds: Cred[]
const calls: string[] = []

const ok = (data: unknown) => Promise.resolve({ ok: true, json: async () => data } as Response)
const fail = (code: string, error: string, http = 403) =>
  Promise.resolve({ ok: false, status: http, json: async () => ({ code, error }) } as Response)

function installFetch() {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)
    if (url.endsWith('/api/auth/status')) return ok(status)
    if (url.endsWith('/api/auth/credentials') && !url.includes('/api/auth/credentials/')) {
      return ok(creds)
    }
    if (url.endsWith('/api/auth/enroll/options')) {
      return ok({ challenge: 'AAAA', rpId: 'localhost', timeout: 120000, userVerification: 'required', allowCredentials: [] })
    }
    if (url.endsWith('/api/auth/enroll/verify')) {
      return ok({ ok: true, grant_token: 'grant123', grant_expires_at: '2026-10-31T00:02:00Z' })
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
      creds = [...creds, { ...creds[0]!, id: 'new', label: 'passkey', added_via: 'assertion' }]
      return ok({ ok: true })
    }
    if (url.includes('/api/auth/credentials/')) {
      const id = url.split('/').pop()!
      creds = creds.filter((c) => c.id !== id)
      return ok({ ok: true })
    }
    return fail('not_found', 'no such endpoint', 404)
  }))
}

beforeEach(() => {
  status = {
    state: 'passkey',
    authenticated: true,
    origin: 'http://localhost:8080',
    rp_id: 'localhost',
    rp_mismatch: false,
    setup_required: false,
    credentials: 2,
    enrollment_via: 'none',
    usable_credentials: 1,
    orphaned_credentials: 1,
  }
  creds = [
    {
      id: 'usable',
      label: 'laptop',
      created_at: '2026-10-30T14:00:00Z',
      sign_count: 3,
      rp_id: 'localhost',
      current: true,
      added_via: 'cli_token',
    },
    {
      id: 'orphan',
      label: 'old key',
      created_at: '2026-09-01T09:00:00Z',
      sign_count: 0,
      rp_id: 'old.example.com',
      current: false,
      added_via: 'legacy',
    },
  ]
  calls.length = 0
  createFn.mockClear()
  getFn.mockClear()
  installWebAuthn()
  installFetch()
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('AccessView', () => {
  it('renders added_via as human copy and marks orphans safe to remove', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    expect(screen.getByText(/added from the terminal/)).toBeInTheDocument()
    expect(screen.getByText(/migrated/)).toBeInTheDocument()
    expect(screen.getByText(/cannot sign you in here; safe to remove/)).toBeInTheDocument()
  })

  it('disables Remove on the last usable credential only', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    const buttons = screen.getAllByRole('button', { name: 'Remove' })
    expect(buttons[0]).toBeDisabled() // the only usable one
    expect(buttons[1]).toBeEnabled() // the orphan
  })

  it('adds a passkey by stepping up first, with two distinct prompts', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByRole('button', { name: 'Add a passkey' }))
    await waitFor(() => expect(createFn).toHaveBeenCalledTimes(1))
    // The step-up runs the get() ceremony before the create() ceremony.
    expect(getFn).toHaveBeenCalledTimes(1)
    expect(calls.some((u) => u.endsWith('/api/auth/enroll/options'))).toBe(true)
    expect(calls.some((u) => u.endsWith('/api/auth/credentials/options'))).toBe(true)
    expect(await screen.findByText(/Passkey added/)).toBeInTheDocument()
  })

  it('tells the operator where the token comes from when none is armed', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    expect(screen.getByText(/seal access-control enroll/)).toBeInTheDocument()
  })
})
