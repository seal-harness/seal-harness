import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea, transcriptToMessages, computeTokensUsed } from './components/ChatArea'
import { HarnessControls } from './components/HarnessControls'
import { NewTabComposer } from './components/NewTabComposer'
import {
  useTranscript,
  useSendMessage,
  useAgents,
  useTabs,
  useRecentSessions,
  useArchivedSessions,
  setSessionArchived,
  setSessionDescription,
  setSessionAgent,
  closeTab,
  dismissTab,
  acknowledgeTab,
  releaseHarness,
  destroyHarness,
  answerQuestion,
  cancelQuestion,
  type SendResult,
  type NewTabResponse,
} from './hooks/useApi'
import { useListsStream } from './hooks/useListsStream'
import { useNewTabSpec } from './hooks/useNewTabSpec'
import { useTranscriptStream, reconcileEntries } from './hooks/useTranscriptStream'
import { useSessionActivityStream } from './hooks/useSessionActivityStream'
import { streamClient } from './lib/streamClient'
import type { Agent, AgentStatus, Message, SessionInfo, TabInfo, TranscriptEntry } from './types'
import { findSession, tabDisplayLabel } from './types'

// ── URL ↔ selectionId helpers ───────────────────────────────────────────

/** Parse the current URL path into a selectedId, or null for root.
 *  Accepts `/tab/<index>` and `/session/<id>` (and `/harness/<id>` for
 *  forward-compat). */
function selectedIdFromPath(): string | null {
  if (typeof window === 'undefined') return null
  const path = window.location.pathname
  const m = path.match(/^\/(harness|session|tab)\/(.+)$/)
  if (m) return `${m[1]}:${m[2]}`
  return null
}

/** Convert a selectedId back to a URL path. */
function pathFromSelectedId(selectedId: string | null): string {
  if (!selectedId) return '/'
  const [type, ...rest] = selectedId.split(':')
  return `/${type}/${rest.join(':')}`
}

/** Extract the focused session id from a selection. `session:<id>` → that
 *  id; `tab:<index>` → the tab's `session_id` (looked up in `tabs`). */
function sessionIdFromSelection(
  selectedId: string | null,
  tabs: TabInfo[],
): string | null {
  if (!selectedId) return null
  const [type, ...rest] = selectedId.split(':')
  if (type === 'session') return rest.join(':')
  if (type === 'tab') {
    const tabIndex = parseInt(rest.join(':'), 10)
    const tab = tabs.find((t) => t.index === tabIndex)
    return tab?.session_id ?? null
  }
  return null
}

// ── Display agent derivation ─────────────────────────────────────────────

/** Resolve a display agent for the ChatArea header from the current
 *  selection. A tab selection reads the backing session's title (parity with
 *  the sidebar); a session selection prefers the agent name, then the model
 *  id, then the session id. The status mirrors the tab/session liveness. */
function deriveAgent(
  selectedId: string,
  tabs: TabInfo[],
  sessions: SessionInfo[],
  archivedSessions: SessionInfo[],
  tabSessions: SessionInfo[],
): Agent | null {
  const [type, ...rest] = selectedId.split(':')
  const id = rest.join(':')

  if (type === 'tab') {
    const tabIndex = parseInt(id, 10)
    const tab = tabs.find((t) => t.index === tabIndex)
    if (!tab) return null
    const status: AgentStatus =
      tab.status === 'running' ? 'thinking'
      : tab.status === 'idle' ? 'idle'
      : 'completed'
    return {
      id: `tab:${tab.index}`,
      name: tabDisplayLabel(tab, findSession(tab.session_id, sessions, archivedSessions, tabSessions)),
      status,
      tokenCount: '',
    }
  }

  if (type === 'session') {
    const s = sessions.find((row) => row.id === id)
    if (!s) return null
    const displayName = s.agent ?? (s.model && s.model.length > 0 ? s.model : s.id)
    return {
      id: `session:${s.id}`,
      name: displayName,
      status: 'completed',
      tokenCount: '',
      description: s.model,
    }
  }

  return null
}

// ── Slash-bubble handling ────────────────────────────────────────────────

/** A transient slash-command output bubble. `kind:"slash"` send responses
 *  add NO transcript entry, so each bubble is held in App state (keyed + ordered
 *  by its send `seq`) and interleaved into the rendered messages. These never
 *  persist — they vanish on reload or session switch. */
interface SlashBubble {
  id: string
  text: string
  at: number
}

// ── App ──────────────────────────────────────────────────────────────────

const DEFAULT_AGENT: Agent = { id: 'seal', name: 'Seal Harness', status: 'idle', tokenCount: '0' }

export default function App() {
  // ── List streams ──────────────────────────────────────────────────────
  // The WS `lists` frame is the primary source; the polled hooks seed the
  // initial render before the first WS frame lands (or whenever the WS is
  // down). WS values take precedence whenever they are non-empty.
  const wsLists = useListsStream()
  const polledTabs = useTabs()
  const polledRecent = useRecentSessions()
  const polledArchived = useArchivedSessions()
  const tabs = wsLists.tabs.length > 0 ? wsLists.tabs : polledTabs.tabs
  const rawSessions = wsLists.recentSessions.length > 0 ? wsLists.recentSessions : polledRecent.sessions
  const archivedSessions = wsLists.archivedSessions.length > 0 ? wsLists.archivedSessions : polledArchived.sessions
  const tabSessions = wsLists.tabSessions
  const { agents } = useAgents()

  // ── Selection ─────────────────────────────────────────────────────────
  const [selectedId, setSelectedId] = useState<string | null>(selectedIdFromPath)
  const [selectedAgent, setSelectedAgent] = useState<string | null>(null)
  const [customPromptFile, setCustomPromptFile] = useState<{ name: string; content: string } | null>(null)

  // Optimistic strip: hide an archived session from the sidebar immediately.
  const [archivedOptimistically, setArchivedOptimistically] = useState<Set<string>>(() => new Set())
  const sessions = useMemo(
    () => rawSessions.filter((s) => !archivedOptimistically.has(s.id)),
    [rawSessions, archivedOptimistically],
  )

  // Optimistic description-edit overlay so the chat header doesn't flicker
  // back to the fallback while the next WS frame arrives.
  const [descriptionOverrides, setDescriptionOverrides] = useState<Map<string, string>>(() => new Map())

  // ── Composer state ────────────────────────────────────────────────────
  const [composerOpen, setComposerOpen] = useState(false)
  const [branchFrom, setBranchFrom] = useState<string | undefined>(undefined)
  // `newTabFocusTick` is no longer needed (composer is a standalone pane),
  // but kept for ChatArea's selectedId refocus effect.
  const [newTabFocusTick, setNewTabFocusTick] = useState(0)

  // ── Resolve focused session ────────────────────────────────────────────
  const currentSessionId = sessionIdFromSelection(selectedId, tabs)

  // ── Transcript: HTTP seed + live WS tail, merged ──────────────────────
  const { entries: httpEntries, loading, refresh } = useTranscript(currentSessionId)
  const { entries: streamEntries, pendingQuestions } = useTranscriptStream(currentSessionId)
  const { sessions: sessionActivity } = useSessionActivityStream(currentSessionId)
  const entries = useMemo(() => {
    if (streamEntries.length === 0) return httpEntries
    let merged: TranscriptEntry[] = httpEntries
    for (const e of streamEntries) merged = reconcileEntries(merged, e)
    return merged
  }, [httpEntries, streamEntries])

  const { send, sending } = useSendMessage(currentSessionId, refresh)

  // ── Pending optimistic message + slash bubbles ────────────────────────
  const [pendingMessage, setPendingMessage] = useState<string | null>(null)
  const [pendingMessageModel, setPendingMessageModel] = useState<string | null>(null)
  const entryCountAtSend = useRef(0)
  const [slashBubbles, setSlashBubbles] = useState<SlashBubble[]>([])
  const seqRef = useRef(0)

  // Clear slash bubbles on session switch so a prior session's command
  // output never bleeds into another's view.
  useEffect(() => { setSlashBubbles([]) }, [currentSessionId])

  // ── Per-session model override (frontend-only, never persisted) ────────
  const [modelOverride, setModelOverride] = useState<string | null>(null)
  useEffect(() => { setModelOverride(null) }, [currentSessionId])

  // Reset the selected agent whenever the focused session changes so the
  // SessionSetup dropdown re-resolves to the configured default agent (or
  // the session's bound agent) instead of inheriting the previous
  // session's selection. The default-agent effect below re-runs on the
  // next render once `agents` is available.
  useEffect(() => { setSelectedAgent(null) }, [currentSessionId])

  // Initialize selectedAgent from the default agent once agents load.
  useEffect(() => {
    if (selectedAgent === null && agents.length > 0) {
      const def = agents.find((a) => a.isDefault)
      setSelectedAgent(def?.name ?? agents[0]?.name ?? null)
    }
  }, [agents, selectedAgent])

  // Apply an agent change for the focused session: update local state AND
  // persist the binding to the backend so the next /send turn picks up the
  // new system prompt. Best-effort; a failure is logged but the local state
  // still updates so the UI stays responsive.
  const handleAgentChange = useCallback((agent: string) => {
    setSelectedAgent(agent)
    if (currentSessionId) void setSessionAgent(currentSessionId, agent || null)
  }, [currentSessionId])

  // ── Send routing ──────────────────────────────────────────────────────
  // A `kind:"slash"` send response adds no transcript entry: render a
  // transient bubble and clear the optimistic spinner. Any other kind
  // falls through to the transcript-driven clear path. Returns true when
  // the caller must NOT keep a pending spinner.
  const handleSendResult = useCallback((res: SendResult | null, seq: number): boolean => {
    if (res && res.kind === 'slash') {
      setSlashBubbles((b) => [...b, { id: `slash-${seq}`, text: res.response, at: seq }])
      setPendingMessage(null)
      setPendingMessageModel(null)
      return true
    }
    return false
  }, [])

  const transcriptMessages = useMemo(() => transcriptToMessages(entries), [entries])

  // The most-recent `_te_model` column in the loaded transcript — the
  // default for the per-session model dropdown.
  const lastTranscriptModel = useMemo(() => {
    for (let i = entries.length - 1; i >= 0; i--) {
      const m = entries[i]!.model
      if (m) return m
    }
    return null
  }, [entries])

  // Distinct `_te_model` values seen in the loaded transcript, newest first.
  const transcriptModels = useMemo(() => {
    const seen: string[] = []
    for (let i = entries.length - 1; i >= 0; i--) {
      const m = entries[i]!.model
      if (m && !seen.includes(m)) seen.push(m)
    }
    return seen
  }, [entries])

  // Is the focused session currently processing a request? Sourced from the
  // live activity stream. Drives the chat-area thinking indicator + sidebar
  // spinner.
  // The spinner shows when the agent is actively thinking (not blocked on
  // a pending approval). `sending` is true for the entire POST /send
  // round-trip (including confirmation prompts); `pendingQuestions` is
  // non-empty when the agent is blocked waiting for approval. So the
  // spinner shows when sending AND no pending questions, or when the
  // session activity stream reports 'thinking' (e.g. a harness turn).
  const sessionIsThinking = currentSessionId !== null
    && (sessionActivity?.[currentSessionId]?.harness === 'thinking'
        || (sending && pendingQuestions.length === 0))

  // Model id to display on the thinking indicator. Prefer the explicit
  // pending-thinking model captured at send-time; fall back to the most
  // recent assistant message's agentName; finally "Assistant".
  const thinkingAgentName = (() => {
    if (pendingMessageModel) return pendingMessageModel
    for (let i = transcriptMessages.length - 1; i >= 0; i--) {
      const m = transcriptMessages[i]!
      if (m.agentName && m.agentName !== 'You' && m.agentName !== 'Assistant') {
        return m.agentName
      }
    }
    return rawSessions.find((s) => s.id === currentSessionId)?.model ?? 'Assistant'
  })()

  const messages = useMemo(() => {
    const now = new Date().toISOString().replace('T', ' ').slice(0, 19) + 'Z'
    // Transient slash-command output rows, ordered by send seq.
    const slashRows: Message[] = [...slashBubbles]
      .sort((a, b) => a.at - b.at)
      .map((sb) => ({
        id: sb.id,
        agentName: 'Command output',
        agentStatus: 'idle' as const,
        timestamp: now,
        blocks: [{ id: sb.id + '-text', text: sb.text }],
        slashBubble: true,
      }))
    if (pendingMessage) {
      return [
        ...transcriptMessages,
        ...slashRows,
        {
          id: 'pending-user',
          agentName: 'You',
          agentStatus: 'completed' as const,
          timestamp: now,
          blocks: [{ text: pendingMessage }],
        },
        {
          id: 'pending-thinking',
          agentName: thinkingAgentName,
          agentStatus: 'thinking' as const,
          timestamp: now,
          blocks: [],
          isGenerating: true,
        },
      ]
    }
    if (sessionIsThinking) {
      return [
        ...transcriptMessages,
        ...slashRows,
        {
          id: 'remote-thinking',
          agentName: thinkingAgentName,
          agentStatus: 'thinking' as const,
          timestamp: now,
          blocks: [],
          isGenerating: true,
        },
      ]
    }
    return [...transcriptMessages, ...slashRows]
  }, [transcriptMessages, pendingMessage, sessionIsThinking, thinkingAgentName, slashBubbles])

  // Clear the optimistic pending pair once the transcript gains new entries.
  useEffect(() => {
    if (pendingMessage && entries.length > entryCountAtSend.current) {
      setPendingMessage(null)
      setPendingMessageModel(null)
    }
  }, [entries.length, pendingMessage])

  const handleSend = useCallback(async (message: string) => {
    if (!currentSessionId) return
    // Unarchive on send into an archived session (mirrors reference behavior).
    if (archivedSessions.some((s) => s.id === currentSessionId)) {
      void setSessionArchived(currentSessionId, false)
    }
    entryCountAtSend.current = entries.length
    // Capture the model so the pending-thinking block labels itself.
    const sessionModel = sessions.find((s) => s.id === currentSessionId)?.model
      ?? archivedSessions.find((s) => s.id === currentSessionId)?.model
      ?? null
    setPendingMessageModel(sessionModel)
    setPendingMessage(message)
    const seq = ++seqRef.current
    const r = await send(message, modelOverride ?? lastTranscriptModel)
    handleSendResult(r, seq)
  }, [send, entries.length, currentSessionId, archivedSessions, sessions, modelOverride, lastTranscriptModel, handleSendResult])

  // ── Selection handlers ────────────────────────────────────────────────
  const syncPath = useCallback((id: string | null) => {
    if (typeof window !== 'undefined') {
      window.history.pushState(null, '', pathFromSelectedId(id))
    }
  }, [])

  useEffect(() => {
    if (typeof window === 'undefined') return
    const onPopState = () => setSelectedId(selectedIdFromPath())
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  const handleSelectTab = useCallback((index: number) => {
    const id = `tab:${index}`
    setSelectedId(id)
    syncPath(id)
  }, [syncPath])

  const handleSelectSession = useCallback((id: string) => {
    const newId = `session:${id}`
    setSelectedId(newId)
    syncPath(newId)
  }, [syncPath])

  // ── New tab / branch ──────────────────────────────────────────────────
  const handleNewTab = useCallback(() => {
    setSelectedId(null)
    setNewTabFocusTick((n) => n + 1)
    syncPath(null)
    setCustomPromptFile(null)
    setBranchFrom(undefined)
    setComposerOpen(true)
  }, [syncPath])

  const handleBranch = useCallback((entryId: string) => {
    setBranchFrom(entryId)
    setComposerOpen(true)
    setSelectedId(null)
    setNewTabFocusTick((n) => n + 1)
    syncPath(null)
    setCustomPromptFile(null)
  }, [syncPath])

  // The NewTabComposer owns the createTab/adoptWindow call; App navigates to
  // the newly-created tab on success (so the chat input wires up to the new
  // session) and closes the composer. The WS `lists` broadcast populates the
  // sidebar with the new tab. For the attach kind, `res` is null (no
  // createTab response) — the composer just closes and the user lands back
  // on the previous selection.
  const handleComposerSubmit = useCallback((res: NewTabResponse | null) => {
    setComposerOpen(false)
    setBranchFrom(undefined)
    if (res) {
      // Prefer the session id when present — `session:<id>` resolves
      // `currentSessionId` directly without waiting for the tabs list to
      // refresh, so the chat input wires up immediately. Fall back to the
      // tab index for shell-like tabs that carry no session.
      const id = res.session_id ? `session:${res.session_id}` : `tab:${res.tab_index}`
      setSelectedId(id)
      syncPath(id)
      // Bind the configured default agent (if any) to the freshly-created
      // session so the SessionSetup screen's default dropdown selection
      // actually takes effect. The composer no longer sends body.agent, so
      // without this the session would start unbound and the agent's
      // system prompt would never be injected on the first turn. The
      // user can still override via the SessionSetup dropdown.
      if (res.session_id) {
        const def = agents.find((a) => a.isDefault)
        if (def) void setSessionAgent(res.session_id, def.name)
      }
    }
  }, [syncPath, agents])

  const handleComposerCancel = useCallback(() => {
    setComposerOpen(false)
    setBranchFrom(undefined)
  }, [])

  // ── Tab/session mutators ──────────────────────────────────────────────
  const handleArchiveSession = useCallback(async (id: string) => {
    setArchivedOptimistically((s) => { const n = new Set(s); n.add(id); return n })
    const ok = await setSessionArchived(id, true)
    if (!ok) {
      setArchivedOptimistically((s) => { const n = new Set(s); n.delete(id); return n })
    }
  }, [])

  const handleUnarchiveSession = useCallback(async (id: string) => {
    await setSessionArchived(id, false)
  }, [])

  const handleSetDescription = useCallback(async (id: string, description: string) => {
    const trimmed = description.trim()
    setDescriptionOverrides((m) => { const n = new Map(m); n.set(id, trimmed); return n })
    const ok = await setSessionDescription(id, trimmed.length > 0 ? trimmed : null)
    if (!ok) {
      setDescriptionOverrides((m) => { const n = new Map(m); n.delete(id); return n })
    }
  }, [])

  const handleCloseTab = useCallback(async (index: number) => {
    await closeTab(index)
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      syncPath(null)
    }
  }, [selectedId, syncPath])

  const handleArchiveTab = useCallback(async (index: number) => {
    const tab = tabs.find((t) => t.index === index)
    if (!tab) return
    await closeTab(index)
    if (tab.session_id) {
      await setSessionArchived(tab.session_id, true)
    }
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      syncPath(null)
    }
  }, [tabs, selectedId, syncPath])

  const handleDismissTab = useCallback(async (index: number) => {
    await dismissTab(index)
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      syncPath(null)
    }
  }, [selectedId, syncPath])

  const handleAcknowledgeTab = useCallback(async (index: number) => {
    await acknowledgeTab(index)
  }, [])

  const handleReleaseTab = useCallback(async (index: number) => {
    await releaseHarness(index)
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      syncPath(null)
    }
  }, [selectedId, syncPath])

  const handleDestroyHarness = useCallback(async (index: number, confirmAdopted: boolean) => {
    await destroyHarness(index, confirmAdopted)
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      syncPath(null)
    }
  }, [selectedId, syncPath])

  // ── Composer spec (always constructed; cheap when not in compose mode) ─
  const composerSpec = useNewTabSpec()

  // ── Derived view state ────────────────────────────────────────────────
  const selectedHarnessTab = useMemo(() => {
    if (!selectedId?.startsWith('tab:')) return null
    const idx = parseInt(selectedId.slice('tab:'.length), 10)
    const t = tabs.find((tab) => tab.index === idx)
    return t && t.kind === 'harness' ? t : null
  }, [selectedId, tabs])

  const displayAgent = selectedId
    ? deriveAgent(selectedId, tabs, sessions, archivedSessions, tabSessions)
    : null

  const taskTitle = displayAgent?.name ?? 'Seal Harness'

  const selectedSession = useMemo(() => {
    const base = sessions.find((s) => s.id === currentSessionId)
      ?? archivedSessions.find((s) => s.id === currentSessionId)
      ?? tabSessions.find((s) => s.id === currentSessionId)
      ?? null
    if (!base) return null
    const override = descriptionOverrides.get(base.id)
    return override === undefined
      ? base
      : { ...base, description: override.length > 0 ? override : null }
  }, [sessions, archivedSessions, tabSessions, currentSessionId, descriptionOverrides])

  // Value shown in the input-row model dropdown. For a provider session, the
  // default is the most-recent transcript `_te_model`; a user override takes
  // precedence. `null` ⇒ the dropdown is suppressed (harness sessions, a
  // model-less transcript, or compose mode).
  const modelDropdownValue: string | null = (() => {
    if (selectedSession?.runtime.startsWith('session:')) return modelOverride ?? lastTranscriptModel
    return null
  })()

  const tokensUsed = useMemo(() => computeTokensUsed(entries), [entries])

  // Eagerly focus the WS before any send so the server's _conn_focus matches
  // when the broker publishes the first entry. (No-op when WS is down.)
  useEffect(() => {
    if (currentSessionId) streamClient().focus(currentSessionId)
  }, [currentSessionId])

  // ── Render ────────────────────────────────────────────────────────────
  return (
    <>
      <TopBar taskTitle={taskTitle} />
      <div className="flex flex-1 min-h-0">
        <Sidebar
          tabs={tabs}
          sessions={sessions}
          archivedSessions={archivedSessions}
          tabSessions={tabSessions}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          onSelectTab={handleSelectTab}
          onSelectSession={handleSelectSession}
          onNewTab={handleNewTab}
          onArchiveSession={handleArchiveSession}
          onUnarchiveSession={handleUnarchiveSession}
          onCloseTab={handleCloseTab}
          onArchiveTab={handleArchiveTab}
          onDismissTab={handleDismissTab}
          onAcknowledgeTab={handleAcknowledgeTab}
          onReleaseTab={handleReleaseTab}
        />
        {composerOpen ? (
          <div className="flex-1 overflow-y-auto" style={{ background: 'var(--bg-base)' }}>
            <NewTabComposer
              spec={composerSpec}
              onSubmit={handleComposerSubmit}
              onCancel={handleComposerCancel}
              branchFrom={branchFrom}
            />
          </div>
        ) : selectedHarnessTab ? (
          <HarnessControls
            tab={selectedHarnessTab}
            session={
              sessions.find((s) => s.id === selectedHarnessTab.session_id)
              ?? archivedSessions.find((s) => s.id === selectedHarnessTab.session_id)
              ?? null
            }
            onOpenSession={handleSelectSession}
            onRelease={handleReleaseTab}
            onDestroy={handleDestroyHarness}
          />
        ) : (
          <ChatArea
            selectedAgent={displayAgent ?? DEFAULT_AGENT}
            selectedSession={selectedSession}
            onSetDescription={handleSetDescription}
            messages={messages}
            loading={loading}
            onSend={currentSessionId ? handleSend : undefined}
            sending={sending}
            tokensUsed={tokensUsed}
            sessionStart={selectedSession?.createdAt ?? null}
            agents={agents}
            currentAgent={selectedAgent}
            onAgentChange={handleAgentChange}
            customPromptFile={customPromptFile}
            onCustomPromptFile={setCustomPromptFile}
            newTabFocusTick={newTabFocusTick}
            selectedId={selectedId}
            onBranch={selectedSession?.runtime.startsWith('session:') ? handleBranch : undefined}
            currentModel={modelDropdownValue}
            availableModels={[...transcriptModels]}
            onModelChange={modelDropdownValue !== null ? setModelOverride : undefined}
            pendingQuestions={pendingQuestions}
            onAnswerQuestion={(qid, ans) => {
              if (currentSessionId) void answerQuestion(currentSessionId, qid, ans)
            }}
            onCancelQuestion={(qid) => {
              if (currentSessionId) void cancelQuestion(currentSessionId, qid)
            }}
          />
        )}
      </div>
    </>
  )
}