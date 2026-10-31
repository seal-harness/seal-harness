/**
 * Passkey access control — the client half.
 *
 * Everything here is deliberately small and dependency-free: the WebAuthn
 * options and credential JSON go to `navigator.credentials` verbatim (that is
 * why they stay camelCase, unlike the rest of the API), and every failure is
 * surfaced as a `{ code, error }` pair so the UI can branch on `code` rather
 * than on prose.
 */

export type AccessState = 'unconfigured' | 'open' | 'passkey'

export interface AuthStatus {
  state: AccessState
  authenticated: boolean
  origin: string | null
  rp_id: string | null
  rp_mismatch: boolean
  setup_required: boolean
  credentials: number
}

export interface CredentialInfo {
  id: string
  label: string
  created_at: string
  sign_count: number
  rp_id: string
  current: boolean
}

export type AuthResult<T = unknown> =
  | { ok: true; data: T }
  | { ok: false; code: string; error: string }

const SETUP_CODE_KEY = 'seal.setup-code'

// ── Setup code plumbing ──────────────────────────────────────────────────

/** Read `#setup=<code>` from the URL and strip it, so the code never ends up in
 *  history, a screenshot or a copied link. Falls back to a previously stored
 *  code (a reload before enrolling must not force retyping 32 characters). */
export function readSetupCodeFromHash(): string | null {
  if (typeof window === 'undefined') return null
  const hash = window.location.hash
  const m = hash.match(/^#setup=(.+)$/)
  if (m) {
    const code = normaliseCode(decodeURIComponent(m[1] ?? ''))
    window.history.replaceState(null, '', window.location.pathname + window.location.search)
    if (code) {
      storeSetupCode(code)
      return code
    }
  }
  return getStoredSetupCode()
}

export function normaliseCode(raw: string): string {
  return raw.trim().replace(/^#?setup=/, '').trim().toLowerCase()
}

export function storeSetupCode(code: string): void {
  try {
    window.sessionStorage.setItem(SETUP_CODE_KEY, code)
  } catch {
    /* sessionStorage can be unavailable (privacy mode); the code still works
       for this page's lifetime via component state. */
  }
}

export function getStoredSetupCode(): string | null {
  try {
    return window.sessionStorage.getItem(SETUP_CODE_KEY)
  } catch {
    return null
  }
}

export function clearSetupCode(): void {
  try {
    window.sessionStorage.removeItem(SETUP_CODE_KEY)
  } catch {
    /* ignore */
  }
}

// ── Environment checks ───────────────────────────────────────────────────

/** WebAuthn requires a secure context: https, or http on localhost. */
export function isSecureContextOk(): boolean {
  if (typeof window === 'undefined') return false
  return window.isSecureContext === true
}

export function hasWebAuthn(): boolean {
  return typeof window !== 'undefined' && typeof window.PublicKeyCredential !== 'undefined'
}

// ── HTTP ─────────────────────────────────────────────────────────────────

async function authRequest<T>(
  path: string,
  init: { method?: string; body?: unknown; setupCode?: string | null } = {},
): Promise<AuthResult<T>> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (init.setupCode) headers['X-Seal-Setup-Token'] = init.setupCode
  let res: Response
  try {
    res = await fetch(`/api/auth/${path}`, {
      method: init.method ?? 'POST',
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      credentials: 'same-origin',
    })
  } catch (e) {
    return { ok: false, code: 'network', error: e instanceof Error ? e.message : 'request failed' }
  }
  let parsed: unknown = null
  try {
    parsed = await res.json()
  } catch {
    parsed = null
  }
  if (!res.ok) {
    const err = parsed as { code?: string; error?: string } | null
    return {
      ok: false,
      code: err?.code ?? `http_${res.status}`,
      error: err?.error ?? `request failed (${res.status})`,
    }
  }
  return { ok: true, data: parsed as T }
}

export function fetchAuthStatus(): Promise<AuthResult<AuthStatus>> {
  return authRequest<AuthStatus>('status', { method: 'GET' })
}

// ── base64url helpers ────────────────────────────────────────────────────

export function bytesToB64url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Decode base64url into an ArrayBuffer (a valid `BufferSource` for WebAuthn). */
export function b64urlToBytes(value: string): ArrayBuffer {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/')
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
  const buffer = new ArrayBuffer(binary.length)
  const view = new Uint8Array(buffer)
  for (let i = 0; i < binary.length; i += 1) view[i] = binary.charCodeAt(i)
  return buffer
}

// ── Ceremonies ───────────────────────────────────────────────────────────

export interface CeremonyFailure {
  code: string
  error: string
}

/** Map a DOMException from `navigator.credentials` onto our code vocabulary. */
export function ceremonyCode(err: unknown): string {
  // A DOMException is not an Error subclass in every engine, so read `.name`
  // structurally rather than via `instanceof`.
  const name = (err as { name?: string } | null)?.name ?? ''
  switch (name) {
    case 'NotAllowedError':
      // Cancelled, timed out, or no such credential on this device.
      return 'not_allowed'
    case 'InvalidStateError':
      return 'already_registered'
    case 'SecurityError':
      return 'origin_mismatch'
    case 'NotSupportedError':
      return 'unsupported'
    default:
      return 'ceremony_failed'
  }
}

/**
 * `navigator.credentials.create()` — enroll a passkey.
 * Returns the JSON body for `/api/auth/register/verify`.
 */
export async function createPasskey(setupCode: string | null): Promise<AuthResult<unknown>> {
  const options = await authRequest<PublicKeyCredentialCreationOptionsJSON>(
    'register/options',
    { setupCode },
  )
  if (!options.ok) return options

  const opts = options.data
  let cred: Credential | null
  try {
    cred = await navigator.credentials.create({
      publicKey: {
        challenge: b64urlToBytes(opts.challenge),
        rp: { id: opts.rp.id, name: opts.rp.name },
        user: {
          id: b64urlToBytes(opts.user.id),
          name: opts.user.name,
          displayName: opts.user.displayName,
        },
        pubKeyCredParams: opts.pubKeyCredParams,
        timeout: opts.timeout,
        attestation: opts.attestation,
        authenticatorSelection: opts.authenticatorSelection,
        excludeCredentials: (opts.excludeCredentials ?? []).map((c) => ({
          type: c.type,
          id: b64urlToBytes(c.id),
        })),
      },
    })
  } catch (e) {
    return { ok: false, code: ceremonyCode(e), error: describe(e) }
  }
  if (!(cred instanceof PublicKeyCredential)) {
    return { ok: false, code: 'ceremony_failed', error: 'no credential was returned' }
  }
  const attestation = cred.response as AuthenticatorAttestationResponse
  return {
    ok: true,
    data: {
      clientDataJSON: bytesToB64url(attestation.clientDataJSON),
      attestationObject: bytesToB64url(attestation.attestationObject),
      rawId: bytesToB64url(cred.rawId),
    },
  }
}

/**
 * `navigator.credentials.get()` — sign in.
 * Returns the JSON body for `/api/auth/login/verify`.
 */
export async function getPasskey(): Promise<AuthResult<unknown>> {
  const options = await authRequest<PublicKeyCredentialRequestOptionsJSON>(
    'login/options',
    {},
  )
  if (!options.ok) return options

  const opts = options.data
  let cred: Credential | null
  try {
    cred = await navigator.credentials.get({
      publicKey: {
        challenge: b64urlToBytes(opts.challenge),
        rpId: opts.rpId,
        timeout: opts.timeout,
        userVerification: opts.userVerification,
        allowCredentials: (opts.allowCredentials ?? []).map((c) => ({
          type: c.type,
          id: b64urlToBytes(c.id),
        })),
      },
    })
  } catch (e) {
    return { ok: false, code: ceremonyCode(e), error: describe(e) }
  }
  if (!(cred instanceof PublicKeyCredential)) {
    return { ok: false, code: 'ceremony_failed', error: 'no credential was returned' }
  }
  const assertion = cred.response as AuthenticatorAssertionResponse
  return {
    ok: true,
    data: {
      clientDataJSON: bytesToB64url(assertion.clientDataJSON),
      authenticatorData: bytesToB64url(assertion.authenticatorData),
      signature: bytesToB64url(assertion.signature),
      rawId: bytesToB64url(cred.rawId),
    },
  }
}

function describe(err: unknown): string {
  const name = (err as { name?: string } | null)?.name ?? ''
  switch (name) {
    case 'NotAllowedError':
      return 'The passkey prompt was cancelled or timed out.'
    case 'SecurityError':
      return 'This address does not match the relying-party id in security.toml.'
    case 'InvalidStateError':
      return 'That passkey is already registered on this device.'
    case 'NotSupportedError':
      return 'This browser or device cannot use passkeys.'
    default:
      return err instanceof Error ? err.message : 'the passkey ceremony failed'
  }
}

// ── Endpoint convenience wrappers ────────────────────────────────────────

export function verifyRegistration(body: unknown, setupCode: string | null, add = false) {
  return authRequest(add ? 'credentials/verify' : 'register/verify', { body, setupCode })
}

export function verifyLogin(body: unknown) {
  return authRequest('login/verify', { body })
}

export function waive(setupCode: string | null) {
  return authRequest('waive', { setupCode })
}

export function logout() {
  return authRequest('logout', {})
}

export function listCredentials() {
  return authRequest<CredentialInfo[]>('credentials', { method: 'GET' })
}

export function removeCredential(id: string) {
  return authRequest(`credentials/${encodeURIComponent(id)}`, { method: 'DELETE' })
}

// ── JSON shapes sent to navigator.credentials (camelCase, verbatim) ──────

interface PublicKeyCredentialCreationOptionsJSON {
  challenge: string
  rp: { id: string; name: string }
  user: { id: string; name: string; displayName: string }
  pubKeyCredParams: PublicKeyCredentialParameters[]
  timeout: number
  attestation: AttestationConveyancePreference
  authenticatorSelection: AuthenticatorSelectionCriteria
  excludeCredentials?: { type: PublicKeyCredentialType; id: string }[]
}

interface PublicKeyCredentialRequestOptionsJSON {
  challenge: string
  rpId: string
  timeout: number
  userVerification: UserVerificationRequirement
  allowCredentials?: { type: PublicKeyCredentialType; id: string }[]
}
