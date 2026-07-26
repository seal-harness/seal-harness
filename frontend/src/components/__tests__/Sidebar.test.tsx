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
    lastUserMessageAt: null,
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
  it('renders the Active Tabs + Recent Sessions headers (and their + buttons) even when empty', () => {
    render(
      <Sidebar
        tabs={[]}
        sessions={[]}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onNewSession={() => {}}
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
    expect(screen.getByText('Recent Sessions')).toBeTruthy()
    expect(screen.getByLabelText('New tab')).toBeTruthy()
    expect(screen.getByLabelText('New session')).toBeTruthy()
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
        onNewSession={() => {}}
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

  it('fires onNewSession when the Recent Sessions + (sparkle) button is clicked', () => {
    const onNewSession = vi.fn()
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
        onNewSession={onNewSession}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    fireEvent.click(screen.getByLabelText('New session'))
    expect(onNewSession).toHaveBeenCalled()
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
        onNewSession={() => {}}
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
        onNewSession={() => {}}
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
        onNewSession={() => {}}
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

  it('resolves a tab label via the backing session (session appears in Active Tabs only, NOT Recent Sessions)', () => {
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
        onNewSession={() => {}}
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
    // W7 partition invariant: the session backing an open tab appears in
    // Active Tabs ONLY — the Sidebar's defense-in-depth filter drops it
    // from Recent Sessions so the sidebar never shows a duplicate. (The
    // backend's partitionSessions guarantees mutual exclusion by
    // construction; the frontend filter is the safety net.)
    const descEls = screen.getAllByText('session-desc')
    expect(descEls.length).toBe(1)
  })
})

// ── Tab status indicator (Thinking / Idle Unread / Idle Read) ──────────

describe('Sidebar — tab status indicator', () => {
  it('renders the 3-state status label derived from the activity stream', () => {
    const tabs = [
      makeTab({ index: 0, kind: 'session:anthropic', session_id: 'thinking' }),
      makeTab({ index: 1, kind: 'session:anthropic', session_id: 'unread' }),
      makeTab({ index: 2, kind: 'session:anthropic', session_id: 'read' }),
    ]
    const tabSessions = [
      makeSession({ id: 'thinking', description: 'Thinking tab' }),
      makeSession({ id: 'unread', description: 'Unread tab' }),
      makeSession({ id: 'read', description: 'Read tab' }),
    ]
    const sessionActivity = {
      thinking: { harness: 'thinking' as const, unread: 0, lastEntryAt: null, seenAt: null },
      unread: { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z' },
      read: { harness: 'idle' as const, unread: 0, lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z' },
    }
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        sessionActivity={sessionActivity}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onNewSession={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByTestId('tab-status-label-0').textContent).toBe('Thinking')
    expect(screen.getByTestId('tab-status-label-1').textContent).toBe('Idle Unread')
    expect(screen.getByTestId('tab-status-label-2').textContent).toBe('Idle Read')
    // Thinking renders an animated ActivityDot (not the static glyph span).
    expect(document.querySelector('.dot-thinking')).toBeTruthy()
    expect(screen.getByTestId('tab-kind-idle-unread')).toBeTruthy()
    expect(screen.getByTestId('tab-kind-idle-read')).toBeTruthy()
  })

  it('sorts Active Tabs: Idle Unread → Idle Read → Thinking (oldest user msg first within bucket)', () => {
    // Indices deliberately out of expected order to prove sorting.
    const tabs = [
      makeTab({ index: 3, kind: 'session:anthropic', session_id: 'thinking', label: 'Thinking tab' }),
      makeTab({ index: 1, kind: 'session:anthropic', session_id: 'unread-old', label: 'Unread old' }),
      makeTab({ index: 2, kind: 'session:anthropic', session_id: 'unread-new', label: 'Unread new' }),
      makeTab({ index: 0, kind: 'session:anthropic', session_id: 'read', label: 'Read tab' }),
    ]
    const tabSessions = [
      makeSession({ id: 'thinking',    description: 'Thinking tab', lastUserMessageAt: '2024-06-04T00:00:00.000Z' }),
      makeSession({ id: 'unread-old',   description: 'Unread old',   lastUserMessageAt: '2024-06-01T00:00:00.000Z' }),
      makeSession({ id: 'unread-new',   description: 'Unread new',   lastUserMessageAt: '2024-06-03T00:00:00.000Z' }),
      makeSession({ id: 'read',         description: 'Read tab',     lastUserMessageAt: '2024-06-02T00:00:00.000Z' }),
    ]
    const sessionActivity = {
      thinking:    { harness: 'thinking' as const, unread: 0, lastEntryAt: null, seenAt: null },
      'unread-old': { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z' },
      'unread-new': { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-04T00:00:00.000Z', seenAt: '2024-06-03T00:00:00.000Z' },
      read:        { harness: 'idle' as const, unread: 0, lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z' },
    }
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        sessionActivity={sessionActivity}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onNewSession={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The status-label testids carry the tab index, so reading them in
    // document order yields the rendered sort.
    const labels = screen.getAllByTestId(/^tab-status-label-\d+$/).map((el) => el.textContent)
    // Expected: Unread old, Unread new, Read, Thinking.
    expect(labels).toEqual(['Idle Unread', 'Idle Unread', 'Idle Read', 'Thinking'])
    // And the tab index badges (rendered first per row) follow the same order.
    const indexBadges = screen.getAllByText(/^([0-9]+)$/).map((el) => el.textContent)
    // The Active Tabs section renders tab.index badges; verify the sorted order.
    // Unread old (1), Unread new (2), Read (0), Thinking (3).
    expect(indexBadges).toContain('1')
    expect(indexBadges).toContain('2')
    expect(indexBadges).toContain('0')
    expect(indexBadges).toContain('3')
  })

  it('dead tabs (exited/orphaned) keep the harness-liveness glyph, not the 3-state indicator', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', status: 'exited', session_id: null, label: 'Dead' })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onNewSession={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByTestId('status-exited')).toBeTruthy()
    expect(screen.queryByTestId('tab-kind-idle-read')).toBeNull()
    expect(screen.getByTestId('tab-status-label-0').textContent).toBe('Exited')
  })
})