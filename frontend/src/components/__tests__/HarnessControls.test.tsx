import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { HarnessControls } from '../HarnessControls'
import type { SessionInfo, TabInfo } from '../../types'

// ── Helpers ────────────────────────────────────────────────────────────────

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's1',
    agent: 'dev',
    runtime: 'session:anthropic',
    model: 'claude-sonnet-4-20250514',
    lastActive: new Date().toISOString(),
    createdAt: new Date('2024-01-01T00:00:00Z').toISOString(),
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    ...overrides,
  }
}

function makeTab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    index: 3,
    kind: 'harness',
    label: 'cc',
    status: 'running',
    session_id: 's1',
    origin: 'spawned',
    ...overrides,
  }
}

beforeEach(() => {
  cleanup()
})

// ── Tests ───────────────────────────────────────────────────────────────────

describe('HarnessControls', () => {
  it('renders the status glyph per TabStatus (running → thinking)', () => {
    const { rerender } = render(
      <HarnessControls
        tab={makeTab({ status: 'running' })}
        session={null}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByTestId('status-running')).toBeTruthy()
    expect(screen.getByText('Running')).toBeTruthy()
    rerender(
      <HarnessControls
        tab={makeTab({ status: 'idle' })}
        session={null}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByTestId('status-idle')).toBeTruthy()
    expect(screen.getByText('Idle')).toBeTruthy()
    rerender(
      <HarnessControls
        tab={makeTab({ status: 'exited' })}
        session={null}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByTestId('status-exited')).toBeTruthy()
    expect(screen.getByText('Exited')).toBeTruthy()
  })

  it('shows the Release button only for adopted harnesses (origin=adopted)', () => {
    const { rerender } = render(
      <HarnessControls
        tab={makeTab({ origin: 'adopted' })}
        session={null}
        onRelease={() => {}}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByText('Release (stop managing)')).toBeTruthy()
    // Re-render with spawned origin → no release button.
    rerender(
      <HarnessControls
        tab={makeTab({ origin: 'spawned' })}
        session={null}
        onRelease={() => {}}
        onDestroy={() => {}}
      />,
    )
    expect(screen.queryByText('Release (stop managing)')).toBeNull()
  })

  it('Destroy shows a confirmation step before calling onDestroy for adopted harnesses', () => {
    const onDestroy = vi.fn()
    render(
      <HarnessControls
        tab={makeTab({ origin: 'adopted' })}
        session={null}
        onDestroy={onDestroy}
      />,
    )
    // Click "Destroy harness" — should NOT immediately call onDestroy.
    fireEvent.click(screen.getByText('Destroy harness'))
    expect(onDestroy).not.toHaveBeenCalled()
    // Confirmation step appears.
    expect(screen.getByText('Confirm destroy')).toBeTruthy()
    // Confirm → onDestroy called with confirmAdopted=true.
    fireEvent.click(screen.getByText('Confirm destroy'))
    expect(onDestroy).toHaveBeenCalledWith(3, true)
  })

  it('Destroy for spawned harnesses calls onDestroy immediately with confirmAdopted=false', () => {
    const onDestroy = vi.fn()
    render(
      <HarnessControls
        tab={makeTab({ origin: 'spawned' })}
        session={null}
        onDestroy={onDestroy}
      />,
    )
    fireEvent.click(screen.getByText('Destroy harness'))
    expect(onDestroy).toHaveBeenCalledWith(3, false)
    // No confirmation step.
    expect(screen.queryByText('Confirm destroy')).toBeNull()
  })

  it('shows the backing session info (agent + model) when provided', () => {
    const session = makeSession({
      id: 'sess-xyz',
      agent: 'researcher',
      model: 'claude-sonnet-4-20250514',
      description: 'My harness session',
    })
    render(
      <HarnessControls
        tab={makeTab({ session_id: 'sess-xyz' })}
        session={session}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByText('researcher')).toBeTruthy()
    expect(screen.getByText('claude-sonnet-4-20250514')).toBeTruthy()
    expect(screen.getByText('sess-xyz')).toBeTruthy()
  })

  it('shows "No session associated yet." when there is no session_id', () => {
    render(
      <HarnessControls
        tab={makeTab({ session_id: null })}
        session={null}
        onDestroy={() => {}}
      />,
    )
    expect(screen.getByText('No session associated yet.')).toBeTruthy()
  })

  it('Release button calls onRelease with the tab index', () => {
    const onRelease = vi.fn()
    render(
      <HarnessControls
        tab={makeTab({ index: 7, origin: 'adopted' })}
        session={null}
        onRelease={onRelease}
        onDestroy={() => {}}
      />,
    )
    fireEvent.click(screen.getByText('Release (stop managing)'))
    expect(onRelease).toHaveBeenCalledWith(7)
  })

  it('does NOT render any reference product name', () => {
    const { container } = render(
      <HarnessControls
        tab={makeTab()}
        session={null}
        onDestroy={() => {}}
      />,
    )
    expect(container.textContent).not.toMatch(/pureclaw/i)
  })
})