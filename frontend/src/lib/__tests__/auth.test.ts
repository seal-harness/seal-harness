import { describe, it, expect, vi, afterEach } from 'vitest'
import {
  b64urlToBytes,
  bytesToB64url,
  ceremonyCode,
  isSecureContextOk,
  normaliseCode,
  readSetupCodeFromHash,
} from '../auth'
import { installUnauthorizedInterceptor, UNAUTHORIZED_EVENT } from '../unauthorized'

afterEach(() => {
  vi.unstubAllGlobals()
  window.history.replaceState(null, '', '/')
  window.sessionStorage.clear()
})

describe('auth helpers', () => {
  it('round-trips bytes through base64url', () => {
    const bytes = new Uint8Array(32)
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = (i * 7) % 256
    const encoded = bytesToB64url(bytes.buffer)
    // URL-safe alphabet only, no padding.
    expect(encoded).toMatch(/^[A-Za-z0-9_-]+$/)
    const decoded = new Uint8Array(b64urlToBytes(encoded))
    expect(Array.from(decoded)).toEqual(Array.from(bytes))
  })

  it('normalises a pasted setup code', () => {
    expect(normaliseCode('  ABC123 ')).toBe('abc123')
    expect(normaliseCode('#setup=abc123')).toBe('abc123')
    expect(normaliseCode('setup=abc123')).toBe('abc123')
  })

  it('reads the setup code from the fragment and strips it from the URL', () => {
    window.history.replaceState(null, '', '/#setup=deadbeef')
    expect(readSetupCodeFromHash()).toBe('deadbeef')
    expect(window.location.hash).toBe('')
    // It survives a reload via sessionStorage.
    expect(readSetupCodeFromHash()).toBe('deadbeef')
  })

  it('returns null when there is no code anywhere', () => {
    window.history.replaceState(null, '', '/')
    expect(readSetupCodeFromHash()).toBeNull()
  })

  it('maps DOMException names onto the code vocabulary', () => {
    expect(ceremonyCode(new DOMException('x', 'NotAllowedError'))).toBe('not_allowed')
    expect(ceremonyCode(new DOMException('x', 'InvalidStateError'))).toBe('already_registered')
    expect(ceremonyCode(new DOMException('x', 'SecurityError'))).toBe('origin_mismatch')
    expect(ceremonyCode(new Error('boom'))).toBe('ceremony_failed')
  })

  it('reports the insecure-context state from the browser', () => {
    const original = Object.getOwnPropertyDescriptor(window, 'isSecureContext')
    Object.defineProperty(window, 'isSecureContext', { value: true, configurable: true })
    expect(isSecureContextOk()).toBe(true)
    Object.defineProperty(window, 'isSecureContext', { value: false, configurable: true })
    expect(isSecureContextOk()).toBe(false)
    if (original) Object.defineProperty(window, 'isSecureContext', original)
  })
})

describe('installUnauthorizedInterceptor', () => {
  it('dispatches seal-unauthorized on a 401 and passes the response through', async () => {
    const fakeFetch = vi.fn(async () => ({ status: 401, ok: false } as Response))
    vi.stubGlobal('fetch', fakeFetch)

    const seen: Event[] = []
    const listener = (e: Event) => seen.push(e)
    window.addEventListener(UNAUTHORIZED_EVENT, listener)

    installUnauthorizedInterceptor()
    const res = await window.fetch('/api/lists')
    expect(res.status).toBe(401)
    expect(seen).toHaveLength(1)

    window.removeEventListener(UNAUTHORIZED_EVENT, listener)
  })
})
