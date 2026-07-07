import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ActiveTabs, TabRow } from '../ActiveTabs'
import { RunningHarnesses } from '../RunningHarnesses'
import { Sidebar } from '../Sidebar'
import type { SessionInfo, TabInfo } from '../../types'

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's1',
    agent: null,
    runtime: 'session:anthropic',
    model: 'm',
    lastActive: new Date().toISOString(),
    createdAt: new Date().toISOString(),
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
    index: 0,
    kind: 'session:anthropic',
    label: null,
    status: 'idle',
    session_id: 's1',
    ...overrides,
  }
}

// ── ActiveTabs ──────────────────────────────────────────────────────────

describe('ActiveTabs', () => {
  it('renders the section header + a row per tab', () => {
    const tabs = [makeTab({ index: 0, label: 'Tab 0' }), makeTab({ index: 1, label: 'Tab 1', session_id: 's2' })]
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('Active Tabs')).toBeTruthy()
    expect(screen.getByText('Tab 0')).toBeTruthy()
    expect(screen.getByText('Tab 1')).toBeTruthy()
  })

  it('highlights the selected tab', () => {
    const tabs = [makeTab({ index: 0, label: 'Tab 0' })]
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId="tab:0"
        tabLabel={(t) => t.label ?? '…'}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const row = document.querySelector('.agent-row.selected')
    expect(row).toBeTruthy()
  })

  it('fires onNewTab when the + button is clicked', () => {
    const onNewTab = vi.fn()
    render(
      <ActiveTabs
        tabs={[]}
        selectedId={null}
        tabLabel={() => 'x'}
        onSelectTab={() => {}}
        onNewTab={onNewTab}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    fireEvent.click(screen.getByLabelText('New tab'))
    expect(onNewTab).toHaveBeenCalled()
  })

  it('fires onSelectTab when a row is clicked', () => {
    const onSelectTab = vi.fn()
    const tabs = [makeTab({ index: 0, label: 'Tab 0' })]
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        onSelectTab={onSelectTab}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    fireEvent.click(screen.getByText('Tab 0'))
    expect(onSelectTab).toHaveBeenCalledWith(0)
  })
})

// ── TabRow ──────────────────────────────────────────────────────────────

describe('TabRow', () => {
  it('renders the origin pill when origin is set', () => {
    render(
      <TabRow
        tab={makeTab({ origin: 'spawned' })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('spawned')).toBeTruthy()
  })

  it('renders the edited pill when extModified is true', () => {
    render(
      <TabRow
        tab={makeTab({ extModified: true })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText(/edited/)).toBeTruthy()
  })

  it('shows the Release button only for adopted harnesses', () => {
    const { rerender } = render(
      <TabRow
        tab={makeTab({ origin: 'adopted' })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByLabelText('Release tab')).toBeTruthy()
    // Re-render with a non-adopted origin → no release button.
    rerender(
      <TabRow
        tab={makeTab({ origin: 'spawned' })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.queryByLabelText('Release tab')).toBeNull()
  })

  it('shows the Dismiss button for exited/orphaned tabs', () => {
    const { rerender } = render(
      <TabRow
        tab={makeTab({ status: 'exited' })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByLabelText('Dismiss tab')).toBeTruthy()
    rerender(
      <TabRow
        tab={makeTab({ status: 'orphaned' })}
        label="L"
        selected={false}
        onSelect={() => {}}
        onClose={() => {}}
        onArchive={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByLabelText('Dismiss tab')).toBeTruthy()
  })
})

// ── RunningHarnesses ────────────────────────────────────────────────────

describe('RunningHarnesses', () => {
  it('renders nothing when there are no harness tabs', () => {
    const { container } = render(
      <RunningHarnesses
        tabs={[]}
        selectedId={null}
        tabLabel={() => 'x'}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(container.firstChild).toBeNull()
  })

  it('renders the section + harness rows when tabs exist', () => {
    const tabs = [makeTab({ index: 0, kind: 'harness', label: 'cc' })]
    render(
      <RunningHarnesses
        tabs={tabs}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByTestId('running-harnesses-section')).toBeTruthy()
    expect(screen.getByText('cc')).toBeTruthy()
  })

  it('collapses + expands via the header click', () => {
    const tabs = [makeTab({ index: 0, kind: 'harness', label: 'cc' })]
    render(
      <RunningHarnesses
        tabs={tabs}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('cc')).toBeTruthy()
    fireEvent.click(screen.getByTestId('running-harnesses-collapse-icon'))
    expect(screen.queryByText('cc')).toBeNull()
  })
})

// ── Sidebar ────────────────────────────────────────────────────────────

describe('Sidebar', () => {
  it('renders the empty-state message when there are no tabs/sessions/archived', () => {
    render(
      <Sidebar
        tabs={[]}
        sessions={[]}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByText('No tabs or sessions yet.')).toBeTruthy()
  })

  it('renders Active Tabs + Recent Sessions + Archived sections together', () => {
    const tabs = [makeTab({ index: 0, label: 'A tab' })]
    const sessions = [makeSession({ id: 's2', description: 'A session' })]
    const archived = [makeSession({ id: 'old', description: 'Old' })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={sessions}
        archivedSessions={archived}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByText('Active Tabs')).toBeTruthy()
    expect(screen.getByText('A tab')).toBeTruthy()
    expect(screen.getByText('Recent Sessions')).toBeTruthy()
    expect(screen.getByText('A session')).toBeTruthy()
    expect(screen.getByTestId('archived-section')).toBeTruthy()
  })

  it('renders the harness-kind tabs under Running Harnesses, not Active Tabs', () => {
    const tabs = [
      makeTab({ index: 0, kind: 'session:anthropic', label: 'provider tab' }),
      makeTab({ index: 1, kind: 'harness', label: 'harness tab' }),
    ]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByText('provider tab')).toBeTruthy()
    expect(screen.getByText('harness tab')).toBeTruthy()
    expect(screen.getByTestId('running-harnesses-section')).toBeTruthy()
  })

  it('fires onArchiveSession when the archive button on a session row is clicked', () => {
    const onArchiveSession = vi.fn()
    const sessions = [makeSession({ id: 's1', description: 'Sess' })]
    render(
      <Sidebar
        tabs={[]}
        sessions={sessions}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={onArchiveSession}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    fireEvent.click(screen.getByLabelText('Archive session'))
    expect(onArchiveSession).toHaveBeenCalledWith('s1')
  })

  it('shows the Unarchive button for archived sessions', () => {
    const archived = [makeSession({ id: 'old', description: 'Old' })]
    render(
      <Sidebar
        tabs={[]}
        sessions={[]}
        archivedSessions={archived}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Expand the archived section first.
    fireEvent.click(screen.getByTestId('collapse-icon'))
    expect(screen.getByText('Old')).toBeTruthy()
    expect(screen.getByLabelText('Unarchive')).toBeTruthy()
  })

  it('resolves a tab label via the backing session (parity with Recent Sessions)', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1', label: 'STALE-TAB-LABEL' })]
    const sessions = [makeSession({ id: 's1', description: 'session-desc' })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={sessions}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The tab label comes from the session's description, not the tab.label.
    expect(screen.getAllByText('session-desc').length).toBeGreaterThanOrEqual(1)
    expect(screen.queryByText('STALE-TAB-LABEL')).toBeNull()
    // The session row also shows the same description — parity. Both the tab
    // row and the Recent Sessions row render it (the headline parity invariant).
    const descEls = screen.getAllByText('session-desc')
    expect(descEls.length).toBeGreaterThanOrEqual(2)
  })
})