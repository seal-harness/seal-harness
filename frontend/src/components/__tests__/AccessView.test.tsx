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
/** Enrollment-verify bodies, so a test can see the `force` flag. */
let enrollBodies: Record<string, unknown>[] = []
/** When true, `enroll/verify` refuses with `grant_outstanding`. */
let grantOutstanding = false

const ok = (data: unknown) => Promise.resolve({ ok: true, json: async () => data } as Response)
const fail = (code: string, error: string, http = 403) =>
  Promise.resolve({ ok: false, status: http, json: async () => ({ code, error }) } as Response)

function installFetch() {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
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
      enrollBodies.push(JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>)
      if (grantOutstanding) {
        return fail('grant_outstanding', 'an enrollment grant is already armed')
      }
      return ok({
        ok: true,
        grant_token: 'grant123',
        // A live deadline: the form disables "add on this computer" at zero.
        grant_expires_at: new Date(Date.now() + 300_000).toISOString(),
        enroll_url: 'http://localhost:8080/#enroll=grant123',
      })
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
      creds = [...creds, { ...creds[0]!, id: 'new2', label: 'passkey', added_via: 'assertion' }]
      return ok({ ok: true, credential: 'new2', added: true })
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
  enrollBodies = []
  grantOutstanding = false
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
  it('lists passkeys with human copy, the gateway mode, and the empty detail pane', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    expect(screen.getByText(/added from the terminal/)).toBeInTheDocument()
    expect(screen.getByText(/migrated/)).toBeInTheDocument()
    expect(screen.getByText(/cannot sign you in here — safe to remove/)).toBeInTheDocument()
    expect(screen.getByTestId('passkey-mode')).toHaveTextContent('passkey · http://localhost:8080')
    expect(screen.getByText(/Select a passkey to view it/)).toBeInTheDocument()
  })

  it('shows a selected passkey read-only and refuses to delete the last usable one', async () => {
    render(<AccessView />)
    fireEvent.click(await screen.findByText('laptop'))

    expect(screen.getByTestId('passkey-form-usable')).toBeInTheDocument()
    expect(screen.getByTestId('passkey-detail-id')).toHaveTextContent('usable')
    expect(screen.getByTestId('passkey-detail-sign-count')).toHaveTextContent('3×')
    expect(screen.getByText('2026-10-30')).toBeInTheDocument()
    expect(screen.getByTestId('passkey-delete')).toBeDisabled()
    expect(screen.getByTestId('passkey-last-usable-hint'))
      .toHaveTextContent(/last passkey that can sign in here/)

    fireEvent.click(screen.getByText('old key'))
    expect(screen.getByTestId('passkey-form-orphan')).toBeInTheDocument()
    expect(screen.getByTestId('passkey-delete')).toBeEnabled()
    expect(screen.queryByTestId('passkey-last-usable-hint')).not.toBeInTheDocument()
  })

  it('deletes a passkey through the confirm step', async () => {
    render(<AccessView />)
    fireEvent.click(await screen.findByText('old key'))
    fireEvent.click(screen.getByTestId('passkey-delete'))
    expect(screen.getByTestId('passkey-delete-confirm')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('passkey-delete-confirm-btn'))

    await waitFor(() =>
      expect(screen.queryByTestId('passkey-row-orphan')).not.toBeInTheDocument(),
    )
    expect(calls).toContain('/api/auth/credentials/orphan')
    expect(screen.getByText(/Select a passkey to view it/)).toBeInTheDocument()
  })

  it('arms a link from the new-passkey form, then adds the passkey here', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByTestId('passkey-new-btn'))

    // Opening the form must not fire a WebAuthn prompt: the link is minted by
    // an explicit Create, exactly like the other views' create forms.
    expect(screen.getByTestId('passkey-form-new')).toBeInTheDocument()
    expect(getFn).not.toHaveBeenCalled()
    expect(createFn).not.toHaveBeenCalled()
    expect(screen.getByLabelText('Enrollment link')).toHaveValue('')

    fireEvent.click(screen.getByTestId('passkey-create'))
    await waitFor(() => expect(getFn).toHaveBeenCalledTimes(1)) // the step-up
    expect(createFn).not.toHaveBeenCalled()
    expect(calls.some((u) => u.endsWith('/api/auth/enroll/options'))).toBe(true)
    expect(await screen.findByLabelText('Enrollment link'))
      .toHaveValue('http://localhost:8080/#enroll=grant123')

    fireEvent.click(screen.getByTestId('passkey-add-here'))
    // The new credential is selected — the create form closes like it does in
    // Providers/Skills/Repos.
    await waitFor(() => expect(screen.getByTestId('passkey-form-new2')).toBeInTheDocument())
    // The same portable token, not a second ceremony, carried the create().
    expect(createFn).toHaveBeenCalledTimes(1)
    expect(calls.some((u) => u.endsWith('/api/auth/credentials/options'))).toBe(true)
    expect(screen.getByTestId('access-notice')).toHaveTextContent('Passkey added.')
  })

  it('offers to replace a link that is already armed', async () => {
    grantOutstanding = true
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByTestId('passkey-new-btn'))
    fireEvent.click(screen.getByTestId('passkey-create'))

    expect(await screen.findByText(/already armed/)).toBeInTheDocument()
    expect(screen.getByTestId('passkey-create')).toHaveTextContent('Replace link')
    expect(enrollBodies[0]?.force).toBe(false)

    grantOutstanding = false
    fireEvent.click(screen.getByTestId('passkey-create'))
    expect(await screen.findByLabelText('Enrollment link'))
      .toHaveValue('http://localhost:8080/#enroll=grant123')
    // Replace mints over the standing grant rather than being refused by it.
    expect(enrollBodies[1]?.force).toBe(true)
  })

  it('explains that a link needs a passkey that already works here', async () => {
    status = { ...status, usable_credentials: 0 }
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByTestId('passkey-new-btn'))

    expect(screen.getByText(/seal access-control enroll/)).toBeInTheDocument()
    expect(screen.getByTestId('passkey-create')).toBeDisabled()
  })

  it('returns to the empty pane on Cancel', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByTestId('passkey-new-btn'))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.getByText(/Select a passkey to view it/)).toBeInTheDocument()
  })

  it('hides a cancelled link but says it stays armed', async () => {
    render(<AccessView />)
    await screen.findByText('laptop')
    fireEvent.click(screen.getByTestId('passkey-new-btn'))
    fireEvent.click(screen.getByTestId('passkey-create'))
    await screen.findByDisplayValue(/enroll=grant123/)

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByLabelText('Enrollment link')).not.toBeInTheDocument()
    expect(screen.getByTestId('access-notice'))
      .toHaveTextContent('Enrollment link hidden — it stays valid until it expires.')
  })

  it('carries the access-control-off and rp-mismatch states as banners', async () => {
    status = {
      ...status,
      state: 'open',
      authenticated: false,
      rp_mismatch: true,
      usable_credentials: 0,
    }
    render(<AccessView />)
    expect(await screen.findByTestId('access-open-banner'))
      .toHaveTextContent(/Access control is off/)
    expect(screen.getByTestId('access-rp-mismatch-banner'))
      .toHaveTextContent(/registered for a different address/)
    expect(screen.getByTestId('passkey-mode')).toHaveTextContent('open · http://localhost:8080')
  })
})
