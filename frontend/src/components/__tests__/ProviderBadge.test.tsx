import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import { ActiveTabs } from '../ActiveTabs'
import { DEFAULT_TAB_LINE_FIELDS } from '../../lib/tabLineConfig'
import type { TabInfo } from '../../types'

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
  // No mock setup needed — the backend proxy approach just sets an <img src>
  // to /api/providers/:name/icon. The browser never fetches in jsdom.
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('ProviderBadge favicon', () => {
  it('renders an img pointing at the backend proxy for an unknown provider', () => {
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

    const badge = screen.getByTestId('provider-badge-my-vllm')
    const img = badge.querySelector('img')
    expect(img).toBeTruthy()
    expect(img?.getAttribute('src')).toBe('/api/providers/my-vllm/icon')
  })

  it('uses the static icon for built-in providers (no backend proxy)', () => {
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
    // static SVG, NOT the backend proxy URL.
    const badge = screen.getByTestId('provider-badge-ollama')
    const img = badge.querySelector('img')
    expect(img).toBeTruthy()
    expect(img?.getAttribute('src')).not.toContain('/api/providers/')
  })

  it('falls back to the ? glyph when the backend proxy img fails to load', () => {
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

    const badge = screen.getByTestId('provider-badge-my-vllm')
    const img = badge.querySelector('img')
    expect(img).toBeTruthy()

    // Simulate the image failing to load (404 from backend).
    fireEvent.error(img!)

    // After the error, the img should be gone and the ? glyph should show.
    const badgeAfter = screen.getByTestId('provider-badge-my-vllm')
    const imgAfter = badgeAfter.querySelector('img')
    expect(imgAfter).toBeNull()
    expect(badgeAfter.textContent).toBe('?')
  })
})
