import { useState, useMemo } from 'react'
import type { SessionInfo, TabInfo } from '../types'
import { findSession, sessionDisplayTitle, sessionSubtitle, shortenModel, tabDisplayLabel } from '../types'
import type { SessionActivityState } from '../types/stream'
import { sortTabsForSidebar, formatAge } from '../lib/tabStatus'
import { ActiveTabs } from './ActiveTabs'
import { RunningHarnesses } from './RunningHarnesses'
import { ActivityDot } from './StatusDot'

/** A "Recent Sessions" section header — plain label, no action button.
 *  The "New Tab" button in Active Tabs is the single entry point for
 *  creating new sessions/tabs. */
function RecentSessionsHeader() {
  return (
    <div
      className="px-3 py-1.5 flex items-center"
      style={{ color: 'var(--text-primary)' }}
    >
      <span
        className="text-xs font-semibold uppercase"
        style={{ letterSpacing: '0.08em' }}
      >
        Recent Sessions
      </span>
    </div>
  )
}

function ArchiveButton({ onArchive }: { onArchive: () => void }) {
  return (
    <button
      className="session-archive"
      title="Archive (hide from Recent Sessions; transcript stays on disk)"
      aria-label="Archive session"
      onClick={(e) => { e.stopPropagation(); onArchive() }}
    >
      <svg
        width="11" height="11" viewBox="0 0 16 16" fill="none"
        stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
        aria-hidden="true"
      >
        <rect x="2" y="3" width="12" height="3" rx="0.5" />
        <path d="M3 6 v6 a1 1 0 0 0 1 1 h8 a1 1 0 0 0 1 -1 v-6" />
        <path d="M6.5 9 h3" />
      </svg>
    </button>
  )
}

function UnarchiveButton({ onUnarchive }: { onUnarchive: () => void }) {
  return (
    <button
      className="btn btn-ghost"
      style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
      aria-label="Unarchive"
      onClick={(e) => { e.stopPropagation(); onUnarchive() }}
    >
      Unarchive
    </button>
  )
}

function SessionRow({
  session,
  selected,
  onSelect,
  onArchive,
  onUnarchive,
  activity,
}: {
  session: SessionInfo
  selected: boolean
  onSelect: () => void
  onArchive?: (id: string) => void
  onUnarchive?: (id: string) => void
  activity?: SessionActivityState
}) {
  const isThinking = activity?.harness === 'thinking'
  const unread = activity?.unread ?? 0

  const rowClasses = [
    'agent-row session-row px-3 py-2',
    selected ? 'selected' : '',
    isThinking ? 'shimmer' : '',
  ].filter(Boolean).join(' ')

  const displayName = sessionDisplayTitle(session)
  const ageBasis = activity?.lastEntryAt ?? session.lastActive
  const age = formatAge(ageBasis) || 'now'

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        {isThinking && <ActivityDot activity="thinking" />}
        <span
          className="text-sm truncate mr-auto"
          style={{ color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {displayName}
        </span>
        {unread > 0 && (
          <span
            className="pill"
            style={{
              background: 'var(--accent-primary)',
              color: 'var(--text-primary)',
              padding: '0 0.4em',
              fontSize: '0.7em',
            }}
            aria-label={`${unread} new entries`}
          >
            {unread}
          </span>
        )}
        {onArchive && <ArchiveButton onArchive={() => onArchive(session.id)} />}
        {onUnarchive && <UnarchiveButton onUnarchive={() => onUnarchive(session.id)} />}
        <span className="pill token-count">{age}</span>
      </div>
      {(() => {
        const subtitle = sessionSubtitle(session)
        if (!subtitle) return null
        return (
          <div
            className="text-xs ml-0 mt-0.5 truncate"
            style={{ color: 'var(--text-faint)', lineHeight: 'var(--leading-tight)' }}
            title={subtitle}
          >
            {subtitle}
          </div>
        )
      })()}
    </div>
  )
}

function ArchivedSection({
  sessions,
  selectedId,
  onSelectSession,
  onUnarchive,
}: {
  sessions: SessionInfo[]
  selectedId: string | null
  onSelectSession: (id: string) => void
  onUnarchive: (id: string) => void
}) {
  const [expanded, setExpanded] = useState(false)

  if (sessions.length === 0) return null

  return (
    <div
      data-testid="archived-section"
      className="shrink-0 flex flex-col"
      style={{
        borderTop: '1px solid var(--border)',
        maxHeight: '50%',
        ...(expanded ? {} : { height: 'var(--bottombar-height)', justifyContent: 'center' }),
      }}
    >
      <div
        className="px-3 py-1.5 flex items-center justify-between cursor-pointer shrink-0"
        style={{ color: 'var(--text-primary)' }}
        onClick={() => setExpanded(!expanded)}
      >
        <span
          className="text-xs font-semibold uppercase"
          style={{ letterSpacing: '0.08em' }}
        >
          Archived ({sessions.length})
        </span>
        <span data-testid="collapse-icon" style={{ fontSize: 12 }}>
          {expanded ? '▾' : '▸'}
        </span>
      </div>
      {expanded && (
        <div className="overflow-y-auto sidebar-scroll">
          {sessions.map((s) => (
            <SessionRow
              key={s.id}
              session={s}
              selected={selectedId === `session:${s.id}`}
              onSelect={() => onSelectSession(s.id)}
              onUnarchive={onUnarchive}
            />
          ))}
        </div>
      )}
    </div>
  )
}

export function Sidebar({
  tabs,
  sessions,
  archivedSessions,
  tabSessions = [],
  selectedId,
  sessionActivity,
  onSelectTab,
  onSelectSession,
  onNewTab,
  onUnarchiveSession,
  onCloseTab,
  onArchiveSession,
  onDismissTab,
  onAcknowledgeTab,
  onReleaseTab,
}: {
  tabs: TabInfo[]
  sessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  /** SessionInfo for sessions backing an OPEN tab (deduped out of `sessions`).
   *  Optional/defaulted so presentational tests can omit it; the live App
   *  always supplies it so active-tab labels resolve. */
  tabSessions?: SessionInfo[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  onSelectTab: (index: number) => void
  onSelectSession: (id: string) => void
  onNewTab: () => void
  onUnarchiveSession: (id: string) => void
  onArchiveSession: (id: string) => void
  onCloseTab: (index: number) => void
  onDismissTab: (index: number) => void
  onAcknowledgeTab: (index: number) => void
  onReleaseTab: (index: number) => void
}) {
  // Harnesses (the harness-registry rows, kind "harness") get their own
  // "Running Harnesses" section; everything else stays under "Active Tabs".
  const harnessTabs = tabs.filter((t) => t.kind === 'harness')
  const otherTabs = tabs.filter((t) => t.kind !== 'harness')
  // A tab's display label = its backing session's title (so it reads
  // identically to its Recent Sessions row), falling back to the harness
  // `label` then an ellipsis — never blank. Computed once here so both
  // ActiveTabs and RunningHarnesses share the SAME join.
  const tabLabel = (tab: TabInfo): string =>
    tabDisplayLabel(tab, findSession(tab.session_id, sessions, archivedSessions, tabSessions))

  // The shortened model id this tab's session was started with, or empty
  // string when no model is known (no backing session, or session with
  // no model). Centralized here so both ActiveTabs and RunningHarnesses
  // share the same session-join — mirrors the tabLabel pattern.
  const tabModel = (tab: TabInfo): string => {
    const session = findSession(tab.session_id, sessions, archivedSessions, tabSessions)
    if (!session || !session.model) return ''
    return shortenModel(session.model)
  }

  // Coarse age pill for a tab — mirrors the Recent Sessions age pill, which
  // uses activity.lastEntryAt ?? session.lastActive. Tabs without a backing
  // session (e.g. raw shell tabs) or any activity frame render no pill.
  const tabAgeText = (tab: TabInfo): string => {
    if (!tab.session_id) return ''
    const session = findSession(tab.session_id, sessions, archivedSessions, tabSessions)
    if (!session) return ''
    const activity = sessionActivity?.[tab.session_id]
    return formatAge(activity?.lastEntryAt ?? session.lastActive) || 'now'
  }

  // Active Tabs sort: Idle Unread → Idle Read → Thinking, oldest
  // last-user-message first within each bucket. The activity state comes
  // from the per-session stream; the sort key is the backing session's
  // lastUserMessageAt (falls back to lastActive/createdAt).
  const sortedOtherTabs = useMemo(
    () => sortTabsForSidebar(
      otherTabs.map((tab) => ({
        tab,
        session: findSession(tab.session_id, sessions, archivedSessions, tabSessions),
        activity: tab.session_id ? sessionActivity?.[tab.session_id] : undefined,
      })),
    ),
    [otherTabs, sessions, archivedSessions, tabSessions, sessionActivity],
  )

  // Defense-in-depth: the backend guarantees (via partitionSessions) no
  // tab-backed session is in `sessions`, but a buggy WS frame could violate
  // that — this filter drops any session that's also in `tabs[].session_id`
  // so the sidebar never shows a duplicate. The backend is the source of
  // truth; this is the safety net.
  const recentSessions = sessions.filter(
    (s) => !tabs.some((t) => t.session_id === s.id)
  )

  return (
    <div
      className="shrink-0 flex flex-col"
      style={{ width: 'var(--sidebar-width)', background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
    >
      <div className="flex-1 overflow-y-auto sidebar-scroll py-1 min-h-0">
        <ActiveTabs
          tabs={sortedOtherTabs}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          tabLabel={tabLabel}
          tabModel={tabModel}
          tabAgeText={tabAgeText}
          onSelectTab={onSelectTab}
          onNewTab={onNewTab}
          onCloseTab={onCloseTab}
          onDismiss={onDismissTab}
          onAcknowledge={onAcknowledgeTab}
          onRelease={onReleaseTab}
        />

        <RunningHarnesses
          tabs={harnessTabs}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          tabLabel={tabLabel}
          tabModel={tabModel}
          tabAgeText={tabAgeText}
          onSelectTab={onSelectTab}
          onCloseTab={onCloseTab}
          onDismiss={onDismissTab}
          onAcknowledge={onAcknowledgeTab}
          onRelease={onReleaseTab}
        />
        <RecentSessionsHeader/>
        {recentSessions.map((s) => (
          <SessionRow
            key={s.id}
            session={s}
            selected={selectedId === `session:${s.id}`}
            onSelect={() => onSelectSession(s.id)}
            onArchive={onArchiveSession}
            activity={sessionActivity?.[s.id]}
          />
        ))}
      </div>
      <ArchivedSection
        sessions={archivedSessions}
        selectedId={selectedId}
        onSelectSession={onSelectSession}
        onUnarchive={onUnarchiveSession}
      />
    </div>
  )
}