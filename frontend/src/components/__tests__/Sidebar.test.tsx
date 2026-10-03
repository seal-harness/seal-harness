import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ActiveTabs, TabRow } from '../ActiveTabs'
import { RunningHarnesses } from '../RunningHarnesses'
import { Sidebar } from '../Sidebar'
import { DEFAULT_TAB_LINE_FIELDS } from '../../lib/tabLineConfig'
import type { SessionInfo, TabInfo } from '../../types'

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's1',
    agent: null,
    runtime: 'session:anthropic',
    model: 'm',
    repoUrl: null,
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

// Clear localStorage before each test so the Sidebar's tabLineFields state
// starts from the default, not a value left by a prior test.
beforeEach(() => {
  localStorage.clear()
})

// ── ActiveTabs ──────────────────────────────────────────────────────────

describe('ActiveTabs', () => {
  it('renders the section header + a row per tab', () => {
    const tabs = [makeTab({ index: 0, label: 'Tab 0' }), makeTab({ index: 1, label: 'Tab 1', session_id: 's2' })]
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        tabLabel={(t) => t.label ?? '…'}
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onNewTab={onNewTab}
        onCloseTab={() => {}}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={onSelectTab}
        onNewTab={() => {}}
        onCloseTab={() => {}}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
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
        tabModel={() => ''}
        tabAgeText={() => ''}
        tabRepoUrl={() => null}
        tabAgent={() => null}
        tabProvider={() => ''}
        tabChannel={() => null}
        fields={DEFAULT_TAB_LINE_FIELDS}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByText('Active Tabs')).toBeTruthy()
    expect(screen.getByText('Recent Sessions')).toBeTruthy()
    expect(screen.getByLabelText('New tab')).toBeTruthy()
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
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
      thinking: { harness: 'thinking' as const, unread: 0, lastEntryAt: null, seenAt: null, toolCall: null },
      unread: { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z', toolCall: null },
      read: { harness: 'idle' as const, unread: 0, lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z', toolCall: null },
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The second line now shows provider badge + model (no redundant
    // status text — the icon on line 1 already conveys thinking/idle/read).
    // The provider badge renders as "A" (anthropic) and the model is "m",
    // so the textContent is "A·m" for all three live tabs (the · separator
    // is now inserted between all configured fields).
    expect(screen.getByTestId('tab-status-label-0').textContent).toBe('A·m')
    expect(screen.getByTestId('tab-status-label-1').textContent).toBe('A·m')
    expect(screen.getByTestId('tab-status-label-2').textContent).toBe('A·m')
    // Thinking renders an animated ActivityDot (not the static glyph span).
    expect(document.querySelector('.dot-thinking')).toBeTruthy()
    expect(screen.getByTestId('tab-kind-idle-unread')).toBeTruthy()
    expect(screen.getByTestId('tab-kind-idle-read')).toBeTruthy()
  })

  it('sorts Active Tabs: Idle Unread → Idle Read → Thinking (newest user msg first within bucket)', () => {
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
      thinking:    { harness: 'thinking' as const, unread: 0, lastEntryAt: null, seenAt: null, toolCall: null },
      'unread-old': { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-02T00:00:00.000Z', seenAt: '2024-06-01T00:00:00.000Z', toolCall: null },
      'unread-new': { harness: 'idle' as const, unread: 1, lastEntryAt: '2024-06-04T00:00:00.000Z', seenAt: '2024-06-03T00:00:00.000Z', toolCall: null },
      read:        { harness: 'idle' as const, unread: 0, lastEntryAt: '2024-06-01T00:00:00.000Z', seenAt: '2024-06-02T00:00:00.000Z', toolCall: null },
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The status-label testids carry the tab index, so reading them in
    // document order yields the rendered sort.
    const labels = screen.getAllByTestId(/^tab-status-label-\d+$/).map((el) => el.textContent)
    // All four tabs share the same provider (anthropic → "A") and model
    // ("m"), so the second line is "A·m" for all. The sort is verified by
    // the index badges below, not by the label text.
    expect(labels).toEqual(['A·m', 'A·m', 'A·m', 'A·m'])
    // And the tab index badges (rendered first per row) follow the same order.
    const indexBadges = screen.getAllByTestId(/^tab-index-\d+$/).map((el) => el.textContent)
    // The Active Tabs section renders tab.index badges; verify the sorted
    // order: Unread new (2), Unread old (1), Read (0), Thinking (3).
    expect(indexBadges).toEqual(['2', '1', '0', '3'])
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByTestId('status-exited')).toBeTruthy()
    expect(screen.queryByTestId('tab-kind-idle-read')).toBeNull()
    // No backing session → no model suffix.
    expect(screen.getByTestId('tab-status-label-0').textContent).toBe('Exited')
  })
})

// ── Tab second-line info density ───────────────────────────────────────

describe('Sidebar — tab second-line info (repo · provider · model · agent)', () => {
  it('shows provider badge + model · repo-name — agent suppressed when repo is present', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
      agent: 'zoe',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The second line shows: "A" badge + "sonnet-4" + "·" + "seal-harness"
    // The agent ("zoe") is NOT shown — when a repo is present, the repo name
    // takes precedence over the agent for the limited space.
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toContain('sonnet-4')
    expect(label.textContent).toContain('seal-harness')
    expect(label.textContent).not.toContain('zoe')
    expect(screen.getByTestId('provider-badge-anthropic')).toBeTruthy()
  })

  it('shows provider badge + model only when no repo and no agent', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:ollama', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'llama3.2',
      runtime: 'session:ollama',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    const label = screen.getByTestId('tab-status-label-0')
    // Default config (provider · model · repo) — no repo data, so just
    // provider badge + model separated by "·".
    expect(label.textContent).toBe('O·llama3.2')
    expect(screen.getByTestId('provider-badge-ollama')).toBeTruthy()
  })

  it('shows provider badge + model + agent when no repo (agent fills the space)', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: null,
      agent: 'zoe',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Default config is provider · model · repo — agent is NOT shown
    // unless the user adds it via the config bar. So: "A" badge + "·" +
    // "sonnet-4" only.
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toBe('A·sonnet-4')
  })

  it('derives repo name from agent prefix when repoUrl is null (legacy session fallback)', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:ollama', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'glm-5.2:cloud',
      runtime: 'session:ollama',
      repoUrl: null,
      // A repo-bound agent has the "<repo>--<id>" prefix pattern
      agent: 'seal-harness--agents-md',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // repoUrl is null but agent has "--" prefix → repo name "seal-harness"
    // is extracted and shown instead of the full agent name.
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toContain('seal-harness')
    expect(label.textContent).not.toContain('agents-md')
  })
})

// ── Configurable tab second-line fields ───────────────────────────────

describe('Sidebar — configurable tab second-line fields', () => {
  it('shows channel when the user adds it to the config', () => {
    localStorage.setItem('seal.tabLineFields', '["provider","model","channel"]')
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      channel: 'signal',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toContain('signal')
    expect(label.textContent).not.toContain('seal-harness')
  })

  it('shows agent when the user adds it to the config', () => {
    localStorage.setItem('seal.tabLineFields', '["provider","model","agent"]')
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
      agent: 'zoe',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Agent is shown because it's in the config, even though repo is present.
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toContain('zoe')
  })

  it('respects custom field order', () => {
    localStorage.setItem('seal.tabLineFields', '["repo","model","provider"]')
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
    })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Custom order: repo → model → provider. The "·" separator appears
    // between each pair of rendered fields.
    // "seal-harness·sonnet-4·A" (A is the provider badge text)
    const label = screen.getByTestId('tab-status-label-0')
    expect(label.textContent).toBe('seal-harness·sonnet-4·A')
  })

  it('renders the TabLineConfigBar at the bottom of the sidebar', () => {
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
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    expect(screen.getByTestId('tab-line-config-bar')).toBeTruthy()
    expect(screen.getByLabelText('Configure tab fields')).toBeTruthy()
  })
})

// ── Tab age pill ───────────────────────────────────────────────────────

describe('Sidebar — tab age pill', () => {
  it('renders the age pill on an Active Tabs row from lastActive when there is no activity frame', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({ id: 's1', description: 'Tab Sess', lastActive: '2024-01-01T00:00:00.000Z' })]
    render(
      <Sidebar
        tabs={tabs}
        sessions={[]}
        archivedSessions={[]}
        tabSessions={tabSessions}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // The age pill is the .pill.token-count span on the tab row. lastActive
    // is 2024-01-01 (many days ago), so the pill renders "Nd".
    const tabRow = screen.getByText('Tab Sess').closest('.agent-row')
    expect(tabRow).toBeTruthy()
    const agePill = tabRow!.querySelector('.pill.token-count')
    expect(agePill).toBeTruthy()
    expect(agePill!.textContent).toMatch(/^\d+d$/)
  })

  it('prefers activity.lastEntryAt over session.lastActive for the age basis', () => {
    const tabs = [makeTab({ index: 0, kind: 'session:anthropic', session_id: 's1' })]
    const tabSessions = [makeSession({ id: 's1', description: 'Tab Sess', lastActive: '2024-01-01T00:00:00.000Z' })]
    const sessionActivity = {
      s1: {
        harness: 'idle' as const,
        unread: 0,
        // 5 minutes ago — should win over the days-old lastActive.
        lastEntryAt: new Date(Date.now() - 5 * 60000).toISOString(),
        seenAt: null, toolCall: null,
      },
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
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    const tabRow = screen.getByText('Tab Sess').closest('.agent-row')
    const agePill = tabRow!.querySelector('.pill.token-count')
    expect(agePill).toBeTruthy()
    expect(agePill!.textContent).toBe('5m')
  })

  it('renders no age pill when a tab has no backing session (raw shell tab)', () => {
    const tabs = [makeTab({ index: 0, kind: 'shell:bash', session_id: null, label: 'raw shell' })]
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
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    const tabRow = screen.getByText('raw shell').closest('.agent-row')
    const agePill = tabRow!.querySelector('.pill.token-count')
    expect(agePill).toBeNull()
  })
})

// ── Configurable second line for Recent Sessions + Archived ───────────

describe('Sidebar — session second-line configurable fields', () => {
  it('Recent Sessions rows show configurable second line with default fields', () => {
    const sessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
      agent: 'zoe',
    })]
    render(
      <Sidebar
        tabs={[]}
        sessions={sessions}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Default config: provider · model · repo.
    const label = screen.getByTestId('session-status-label-s1')
    expect(label.textContent).toContain('sonnet-4')
    expect(label.textContent).toContain('seal-harness')
    expect(screen.getByTestId('provider-badge-anthropic')).toBeTruthy()
  })

  it('Recent Sessions rows respect custom field config (channel shown)', () => {
    localStorage.setItem('seal.tabLineFields', '["provider","model","channel"]')
    const sessions = [makeSession({
      id: 's1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      channel: 'signal',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
    })]
    render(
      <Sidebar
        tabs={[]}
        sessions={sessions}
        archivedSessions={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onSelectSession={() => {}}
        onNewTab={() => {}}
        onArchiveSession={() => {}}
        onUnarchiveSession={() => {}}
        onCloseTab={() => {}}
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    const label = screen.getByTestId('session-status-label-s1')
    expect(label.textContent).toContain('signal')
    // Repo is NOT in the config, so it should not appear.
    expect(label.textContent).not.toContain('seal-harness')
  })

  it('Archived rows show configurable second line', () => {
    const archived = [makeSession({
      id: 'old1',
      model: 'llama3.2',
      runtime: 'session:ollama',
      repoUrl: null,
      agent: 'zoe',
    })]
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
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    // Expand the archived section.
    fireEvent.click(screen.getByTestId('collapse-icon'))
    // Default config: provider · model · repo. No repo → just provider + model.
    const label = screen.getByTestId('session-status-label-old1')
    expect(label.textContent).toContain('llama3.2')
    expect(screen.getByTestId('provider-badge-ollama')).toBeTruthy()
  })

  it('Archived rows respect custom field config (agent shown)', () => {
    localStorage.setItem('seal.tabLineFields', '["provider","model","agent"]')
    const archived = [makeSession({
      id: 'old1',
      model: 'claude-sonnet-4-20250514',
      runtime: 'session:anthropic',
      repoUrl: 'https://github.com/seal-harness/seal-harness.git',
      agent: 'zoe',
    })]
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
        onDismissTab={() => {}}
        onAcknowledgeTab={() => {}}
        onReleaseTab={() => {}}
      />,
    )
    fireEvent.click(screen.getByTestId('collapse-icon'))
    // Agent is in the config, so it should appear even though repo is present.
    const label = screen.getByTestId('session-status-label-old1')
    expect(label.textContent).toContain('zoe')
  })
})
