import { describe, it, expect, vi, afterEach } from 'vitest'
import {
  b64urlToBytes,
  bytesToB64url,
  ceremonyCode,
  clearEnrollToken,
  getStoredEnrollToken,
  isSecureContextOk,
  normaliseToken,
  readEnrollTokenFromHash,
} from '../auth'
import {
  AUTH_CHANGED_EVENT,
  installUnauthorizedInterceptor,
  notifyAuthChanged,
} from '../unauthorized'

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

  it('normalises a pasted enrollment token', () => {
    expect(normaliseToken('  ABC123 ')).toBe('abc123')
    expect(normaliseToken('#enroll=abc123')).toBe('abc123')
    expect(normaliseToken('enroll=abc123')).toBe('abc123')
    // A pasted full URL contributes only its fragment (design §8.2).
    expect(normaliseToken('http://localhost:8080/#enroll=abc123')).toBe('abc123')
  })

  it('reads the token from the fragment and strips it from the URL', () => {
    window.history.replaceState(null, '', '/#enroll=deadbeef')
    expect(readEnrollTokenFromHash()).toBe('deadbeef')
    expect(window.location.hash).toBe('')
    // It survives a reload via sessionStorage.
    expect(readEnrollTokenFromHash()).toBe('deadbeef')
  })

  // The report behind this: `seal serve` prints a link, the operator opens it,
  // and the page still asks them to "paste the token printed in the terminal".
  // The token had in fact been captured — the field was simply empty and the
  // hint described a manual step that was not needed, so the link looked
  // broken. A captured token must be distinguishable from "type it yourself".
  describe('a token captured from the link', () => {
    it('is not mistaken for a typed token, and reports where it came from', () => {
      window.history.replaceState(null, '', '/#enroll=deadbeef')
      expect(readEnrollTokenFromHash()).toBe('deadbeef')
      // Captured, not typed: the UI keys its "no field needed" path off this.
      expect(getStoredEnrollToken()).toBe('deadbeef')
    })

    it('is dropped once the ceremony spent it', () => {
      window.history.replaceState(null, '', '/#enroll=deadbeef')
      expect(readEnrollTokenFromHash()).toBe('deadbeef')
      clearEnrollToken()
      expect(getStoredEnrollToken()).toBeNull()
      expect(readEnrollTokenFromHash()).toBeNull()
    })
  })

  // A link the operator has already used must not re-arm on every reload, or
  // the setup screen would keep reappearing for a spent token.
  it('does not resurrect a token that was cleared', () => {
    window.history.replaceState(null, '', '/')
    clearEnrollToken()
    expect(readEnrollTokenFromHash()).toBeNull()
    expect(window.sessionStorage.getItem('seal.enroll-token')).toBeNull()
  })

  it('returns null when there is no token anywhere', () => {
    window.history.replaceState(null, '', '/')
    expect(readEnrollTokenFromHash()).toBeNull()
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

describe('auth-change notifications', () => {
  it('dispatches seal-auth-changed on a 401 and passes the response through', async () => {
    const fakeFetch = vi.fn(async () => ({ status: 401, ok: false } as Response))
    vi.stubGlobal('fetch', fakeFetch)

    const seen: Event[] = []
    const listener = (e: Event) => seen.push(e)
    window.addEventListener(AUTH_CHANGED_EVENT, listener)

    installUnauthorizedInterceptor()
    const res = await window.fetch('/api/lists')
    expect(res.status).toBe(401)
    expect(seen).toHaveLength(1)

    window.removeEventListener(AUTH_CHANGED_EVENT, listener)
  })

  it('lets an explicit sign-out raise the same event', () => {
    const seen: Event[] = []
    const listener = (e: Event) => seen.push(e)
    window.addEventListener(AUTH_CHANGED_EVENT, listener)
    notifyAuthChanged()
    expect(seen).toHaveLength(1)
    window.removeEventListener(AUTH_CHANGED_EVENT, listener)
  })
})
