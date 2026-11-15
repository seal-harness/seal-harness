import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, cleanup } from '@testing-library/react'
import { ActiveTabs } from '../ActiveTabs'
import { DEFAULT_TAB_LINE_FIELDS } from '../../lib/tabLineConfig'
import { clearIconCache } from '../../lib/providerIcons'
import type { TabInfo } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

// Mock the provider base URL hook so ProviderBadge can resolve favicon URLs
// for custom (non-builtin) providers.
let mockBaseUrls = new Map<string, string>()

vi.mock('../../hooks/useProviderBaseUrls', () => ({
  useProviderBaseUrls: () => mockBaseUrls,
  getProviderBaseUrls: () => Promise.resolve(mockBaseUrls),
  refreshProviderBaseUrls: () => {},
}))

const originalFetch = globalThis.fetch

function makeTab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    index: 0,
    kind: 'session:my-vllm',
    label: 'My vLLM',
    status: 'idle',
    session_id: 's1',
    ...overrides,
  }
}

beforeEach(() => {
  clearIconCache()
  mockBaseUrls = new Map()
})

afterEach(() => {
  globalThis.fetch = originalFetch
  vi.restoreAllMocks()
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('ProviderBadge favicon', () => {
  it('renders a favicon img for an unknown provider with a base URL', async () => {
    mockBaseUrls = new Map([['my-vllm', 'https://api.example.com/v1']])

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

    render(
      <ActiveTabs
        tabs={[makeTab()]}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => 'my-vllm'}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )

    // The badge should eventually render an img with the resolved favicon URL.
    await waitFor(() => {
      const badge = screen.getByTestId('provider-badge-my-vllm')
      const img = badge.querySelector('img')
      expect(img).toBeTruthy()
      expect(img?.getAttribute('src')).toBe('https://api.example.com/favicon.ico')
    })
  })

  it('falls back to the ? glyph when no favicon is found', async () => {
    mockBaseUrls = new Map([['my-vllm', 'https://api.example.com/v1']])

    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response('<html><head></head></html>', { status: 200 }),
    )
    globalThis.fetch = fetchMock as unknown as typeof fetch

    render(
      <ActiveTabs
        tabs={[makeTab()]}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => 'my-vllm'}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )

    // No favicon found → the badge should show the ? glyph, not an img.
    await waitFor(() => {
      const badge = screen.getByTestId('provider-badge-my-vllm')
      const img = badge.querySelector('img')
      expect(img).toBeNull()
      expect(badge.textContent).toBe('?')
    })
  })

  it('uses the static icon for built-in providers (no fetch)', async () => {
    const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response('', { status: 200 }),
    )
    globalThis.fetch = fetchMock as unknown as typeof fetch

    render(
      <ActiveTabs
        tabs={[makeTab({ kind: 'session:ollama' })]}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => 'ollama'}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )

    // Ollama has a bundled icon — the badge should render an img with the
    // static SVG, and no fetch should have been made.
    const badge = screen.getByTestId('provider-badge-ollama')
    const img = badge.querySelector('img')
    expect(img).toBeTruthy()
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
