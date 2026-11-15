import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  resolveProviderIcon,
  extractIconUrl,
  deriveRootUrl,
  resolveIconUrl,
  clearIconCache,
} from '../providerIcons'

// ── Pure helpers ────────────────────────────────────────────────────────

describe('deriveRootUrl', () => {
  it('strips /v1 from an OpenAI-compatible base URL', () => {
    expect(deriveRootUrl('https://api.openai.com/v1')).toBe('https://api.openai.com')
  })
  it('strips a trailing path segment after /v1', () => {
    expect(deriveRootUrl('https://api.example.com/v1/')).toBe('https://api.example.com')
  })
  it('strips /v1 from a localhost endpoint', () => {
    expect(deriveRootUrl('http://localhost:8000/v1')).toBe('http://localhost:8000')
  })
  it('returns the origin when there is no /v1 path', () => {
    expect(deriveRootUrl('https://api.example.com/api/v2')).toBe('https://api.example.com')
  })
  it('returns the origin for a bare origin URL', () => {
    expect(deriveRootUrl('https://api.example.com')).toBe('https://api.example.com')
  })
  it('handles a URL with a port', () => {
    expect(deriveRootUrl('http://localhost:11434')).toBe('http://localhost:11434')
  })
  it('returns null for an empty string', () => {
    expect(deriveRootUrl('')).toBeNull()
  })
  it('returns null for a non-URL string', () => {
    expect(deriveRootUrl('not a url')).toBeNull()
  })
})

describe('extractIconUrl', () => {
  it('extracts href from <link rel="icon">', () => {
    const html = '<html><head><link rel="icon" href="/favicon.ico"></head></html>'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/favicon.ico')
  })
  it('extracts href from <link rel="shortcut icon"> (case-insensitive)', () => {
    const html = '<html><head><LINK REL="Shortcut Icon" HREF="/favicon.png"></head></html>'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/favicon.png')
  })
  it('extracts the first icon link when multiple present', () => {
    const html = '<link rel="icon" href="/favicon.ico"><link rel="icon" href="/favicon.svg">'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/favicon.ico')
  })
  it('returns null when no icon link is present', () => {
    const html = '<html><head><link rel="stylesheet" href="/style.css"></head></html>'
    expect(extractIconUrl(html, 'https://api.example.com')).toBeNull()
  })
  it('returns null for empty HTML', () => {
    expect(extractIconUrl('', 'https://api.example.com')).toBeNull()
  })
  it('extracts href with type attribute present', () => {
    const html = '<link rel="icon" type="image/svg+xml" href="/icon.svg">'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/icon.svg')
  })
  it('extracts an apple-touch-icon as a fallback', () => {
    const html = '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/apple-touch-icon.png')
  })
  it('prefers rel="icon" over apple-touch-icon', () => {
    const html = '<link rel="apple-touch-icon" href="/apple.png"><link rel="icon" href="/favicon.ico">'
    expect(extractIconUrl(html, 'https://api.example.com')).toBe('/favicon.ico')
  })
})

describe('resolveIconUrl', () => {
  it('resolves an absolute href against the root URL', () => {
    expect(resolveIconUrl('/favicon.ico', 'https://api.example.com')).toBe(
      'https://api.example.com/favicon.ico',
    )
  })
  it('passes through an already-absolute URL', () => {
    expect(resolveIconUrl('https://cdn.example.com/icon.png', 'https://api.example.com')).toBe(
      'https://cdn.example.com/icon.png',
    )
  })
  it('resolves a protocol-relative URL', () => {
    expect(resolveIconUrl('//cdn.example.com/icon.png', 'https://api.example.com')).toBe(
      'https://cdn.example.com/icon.png',
    )
  })
  it('resolves a relative path without leading slash', () => {
    expect(resolveIconUrl('favicon.ico', 'https://api.example.com')).toBe(
      'https://api.example.com/favicon.ico',
    )
  })
  it('returns null for an empty href', () => {
    expect(resolveIconUrl('', 'https://api.example.com')).toBeNull()
  })
  it('returns null when rootUrl is null', () => {
    expect(resolveIconUrl('/favicon.ico', null)).toBeNull()
  })
})

// ── resolveProviderIcon (integration with mocked fetch) ─────────────────

describe('resolveProviderIcon', () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    clearIconCache()
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('fetches the root page, extracts the icon, and returns the absolute URL', async () => {
    const fetchMock = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => {
      const u = typeof url === 'string' ? url : url.toString()
      if (u === 'https://api.example.com') {
        return new Response('<html><head><link rel="icon" href="/favicon.ico"></head></html>', {
          status: 200,
          headers: { 'Content-Type': 'text/html' },
        })
      }
      return new Response('not found', { status: 404 })
    })
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const result = await resolveProviderIcon('https://api.example.com/v1')
    expect(result).toBe('https://api.example.com/favicon.ico')
  })

  it('returns null when the root page has no icon link', async () => {
    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response('<html><head></head></html>', { status: 200 }),
    )
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const result = await resolveProviderIcon('https://api.example.com/v1')
    expect(result).toBeNull()
  })

  it('returns null when the fetch fails', async () => {
    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => {
      throw new Error('network error')
    })
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const result = await resolveProviderIcon('https://api.example.com/v1')
    expect(result).toBeNull()
  })

  it('returns null when the root page returns a non-200 status', async () => {
    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response('error', { status: 500 }),
    )
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const result = await resolveProviderIcon('https://api.example.com/v1')
    expect(result).toBeNull()
  })

  it('returns null for an empty base URL', async () => {
    const result = await resolveProviderIcon('')
    expect(result).toBeNull()
  })

  it('returns null for a null base URL', async () => {
    const result = await resolveProviderIcon(null)
    expect(result).toBeNull()
  })

  it('caches results: a second call does not fetch again', async () => {
    const fetchMock = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => {
      const u = typeof url === 'string' ? url : url.toString()
      return new Response(
        u === 'https://api.example.com'
          ? '<link rel="icon" href="/favicon.ico">'
          : 'not found',
        { status: 200 },
      )
    })
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const r1 = await resolveProviderIcon('https://api.example.com/v1')
    const r2 = await resolveProviderIcon('https://api.example.com/v1')
    expect(r1).toBe('https://api.example.com/favicon.ico')
    expect(r2).toBe('https://api.example.com/favicon.ico')
    // Only one fetch call to the root page (the HTML fetch; the icon URL
    // is returned directly, not fetched).
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('deduplicates concurrent calls for the same base URL (in-flight cache)', async () => {
    const fetchMock = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => {
      const u = typeof url === 'string' ? url : url.toString()
      return new Response(
        u === 'https://api.example.com'
          ? '<link rel="icon" href="/favicon.ico">'
          : 'not found',
        { status: 200 },
      )
    })
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const [r1, r2] = await Promise.all([
      resolveProviderIcon('https://api.example.com/v1'),
      resolveProviderIcon('https://api.example.com/v1'),
    ])
    expect(r1).toBe('https://api.example.com/favicon.ico')
    expect(r2).toBe('https://api.example.com/favicon.ico')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})
